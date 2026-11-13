#!/bin/bash
# =====================================================================
#  amnezia-proto-amnezia-dns.sh
#  Собственный DNS-резолвер (unbound, рекурсивный, без логов).
#  Слушает только внутри VPN-подсети (10.8.0.1) — снаружи недоступен.
#  В каскаде исходящие запросы уходят через выходной узел, как трафик
#  клиентов: источник 10.8.0.1 маршрутизируется в туннель.
#
#  Команды: install | remove | status | use-for-clients | use-cloudflare
#  use-for-clients  — переключить клиентов AmneziaWG на этот DNS
#  use-cloudflare   — вернуть клиентам DNS 1.1.1.1 / 1.0.0.1
# =====================================================================
set -euo pipefail

NAME="amnezia-dns"
TITLE="Amnezia DNS (unbound)"
STATE_DIR="/etc/amnezia-protocols"
STATE_FILE="$STATE_DIR/$NAME.conf"
UNBOUND_CONF="/etc/unbound/unbound.conf.d/amnezia.conf"
ADBLOCK_CONF="/etc/unbound/unbound.conf.d/adblock.conf"
ADBLOCK_CRON="/etc/cron.d/amnezia-dns-adblock"
ADBLOCK_URL="https://big.oisd.nl/domainswild"

ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

[[ $EUID -ne 0 ]] && { err "Запускать от root (sudo $0)"; exit 1; }

CASCADE_ENV="/etc/amnezia-cascade.env"
[[ -f "$CASCADE_ENV" ]] && source "$CASCADE_ENV"
DNS_IP="${CLIENT_SERVER_IP:-10.8.0.1}"
SUBNET4="${CLIENT_SUBNET:-10.8.0}.0/24"
V6="${IPV6_ENABLED:-0}"
DNS_IP6="${CLIENT_SUBNET6:-fd00:10:8}::1"

do_install() {
    [[ -f "$STATE_FILE" ]] && { err "Уже установлен. Сначала удалите: $0 remove"; exit 1; }

    apt update -qq < /dev/null
    apt install -y -qq unbound < /dev/null

    V6_LINES=""
    if [[ "$V6" == "1" ]]; then
        V6_LINES="    interface: ${DNS_IP6}@53
    access-control: ${CLIENT_SUBNET6}::/64 allow"
    fi

    mkdir -p /etc/unbound/unbound.conf.d
    cat > "$UNBOUND_CONF" <<EOF
server:
    # Только внутри VPN-подсети — снаружи резолвер недоступен
    interface: ${DNS_IP}@53
$V6_LINES
    access-control: 127.0.0.0/8 allow
    access-control: ${SUBNET4} allow
    # Исходящие запросы — с адреса внутри VPN (в каскаде уйдут через выходной узел)
    outgoing-interface: ${DNS_IP}
    hide-identity: yes
    hide-version: yes
    harden-dnssec-stripped: yes
    qname-minimisation: yes
    cache-min-ttl: 300
    logfile: ""
    log-queries: no
    log-replies: no
EOF
    unbound-checkconf "$UNBOUND_CONF" >/dev/null
    systemctl enable unbound
    systemctl restart unbound
    sleep 1
    systemctl is-active --quiet unbound || { err "unbound не запустился: journalctl -u unbound"; exit 1; }

    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
    cat > "$STATE_FILE" <<EOF
TITLE="$TITLE"
PORT="53"
ADDRESS="$DNS_IP"
CLIENT_LINK=""
EOF
    chmod 600 "$STATE_FILE"

    ok "$TITLE установлен (слушает $DNS_IP:53, логи отключены)"
    echo ""
    echo "Переключить клиентов AmneziaWG на этот DNS:"
    echo "  $0 use-for-clients"
}

do_remove() {
    systemctl disable --now unbound 2>/dev/null || true
    rm -f "$UNBOUND_CONF" "$ADBLOCK_CONF" "$ADBLOCK_CRON" "$STATE_FILE"
    ok "$TITLE удалён (пакет unbound оставлен в системе)"
    echo "Не забудьте вернуть клиентам публичный DNS: $0 use-cloudflare"
}

# === Блокировка рекламы/трекеров (блок-лист oisd big) ===
_adblock_write() {
    echo "Скачивание блок-листа (oisd big)..."
    curl -fsSL -m 90 "$ADBLOCK_URL" -o /tmp/adblock.list || { err "Не удалось скачать блок-лист"; return 1; }
    {
        echo "server:"
        tr -d '\r' < /tmp/adblock.list | grep -vE '^\s*(#|$)' \
            | sed 's/^/    local-zone: "/; s/$/" always_nxdomain/'
    } > "$ADBLOCK_CONF"
    rm -f /tmp/adblock.list
    unbound-checkconf >/dev/null 2>&1 || { err "Ошибка в сгенерированном конфиге"; rm -f "$ADBLOCK_CONF"; return 1; }
    systemctl reload unbound 2>/dev/null || systemctl restart unbound
}

do_adblock_on() {
    [[ -f "$STATE_FILE" ]] || { err "Сначала установите: $0 install"; exit 1; }
    _adblock_write || exit 1
    cat > "$ADBLOCK_CRON" <<EOF
23 5 * * 1 root /usr/local/bin/amnezia-proto-amnezia-dns.sh adblock-update
EOF
    chmod 644 "$ADBLOCK_CRON"
    sed -i '/^AD_BLOCK=/d' "$STATE_FILE"
    echo 'AD_BLOCK="1"' >> "$STATE_FILE"
    ok "Блокировка рекламы включена ($(grep -c local-zone "$ADBLOCK_CONF") доменов, обновление — еженедельно)"
}

do_adblock_update() {
    [[ -f "$STATE_FILE" ]] || exit 0
    source "$STATE_FILE"
    [[ "${AD_BLOCK:-0}" == "1" ]] || exit 0
    _adblock_write
}

do_adblock_off() {
    rm -f "$ADBLOCK_CONF" "$ADBLOCK_CRON"
    [[ -f "$STATE_FILE" ]] && { sed -i '/^AD_BLOCK=/d' "$STATE_FILE"; echo 'AD_BLOCK="0"' >> "$STATE_FILE"; }
    systemctl reload unbound 2>/dev/null || systemctl restart unbound 2>/dev/null || true
    ok "Блокировка рекламы выключена"
}

# Переключение DNS в клиентских конфигах AmneziaWG (+ обновление vpn:// ссылок)
switch_clients_dns() {
    local new_dns="$1"
    local dns_line="$new_dns"
    [[ "$V6" == "1" && "$new_dns" == "$DNS_IP" ]] && dns_line="$new_dns, $DNS_IP6"

    sed -i "s|^DNS_SERVERS=\".*\"|DNS_SERVERS=\"$new_dns\"|" /usr/local/bin/amnezia-add-client.sh

    local SERVER_NAME
    SERVER_NAME=$(grep -oP '^SERVER_NAME="\K[^"]+' /usr/local/bin/amnezia-add-client.sh | head -1 || echo "AmneziaVPN")
    SERVER_NAME="${SERVER_NAME:-AmneziaVPN}"

    local f base
    shopt -s nullglob
    for f in /root/clients/*.conf; do
        sed -i "s|^DNS = .*|DNS = $dns_line|" "$f"
        base="${f%.conf}"
        if [[ -f "${base}.vpn.txt" && -x /usr/local/bin/amnezia-vpn-link.py ]]; then
            /usr/local/bin/amnezia-vpn-link.py "$f" "$SERVER_NAME" > "${base}.vpn.txt" || true
            chmod 600 "${base}.vpn.txt"
        fi
    done
    shopt -u nullglob
    ok "DNS клиентов переключён на: $dns_line"
    echo "ВАЖНО: клиенты должны заново импортировать конфиг / vpn:// ссылку."
}

case "${1:-status}" in
    install) do_install ;;
    remove)  do_remove ;;
    adblock-on)  do_adblock_on ;;
    adblock-off) do_adblock_off ;;
    adblock-update) do_adblock_update ;;
    use-for-clients)
        [[ -f "$STATE_FILE" ]] || { err "Сначала установите: $0 install"; exit 1; }
        switch_clients_dns "$DNS_IP" ;;
    use-cloudflare)
        switch_clients_dns "1.1.1.1, 1.0.0.1" ;;
    status)
        if [[ -f "$STATE_FILE" ]]; then
            source "$STATE_FILE"
            if systemctl is-active --quiet unbound; then STATE="работает"; else STATE="ОСТАНОВЛЕН"; fi
            echo "installed=1"
            echo "state=$STATE"
            echo "title=$TITLE"
            echo "port=$PORT"
            echo "link=DNS для клиентов: $ADDRESS"
            echo "adblock=${AD_BLOCK:-0}"
            [[ "${AD_BLOCK:-0}" == "1" && -f "$ADBLOCK_CONF" ]] \
                && echo "adblock_domains=$(grep -c local-zone "$ADBLOCK_CONF")"
        else
            echo "installed=0"
            echo "title=$TITLE"
        fi
        ;;
    *) echo "Использование: $0 install|remove|status|use-for-clients|use-cloudflare|adblock-on|adblock-off"; exit 1 ;;
esac
