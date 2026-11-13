#!/bin/bash
# =====================================================================
#  amnezia-proto-amneziawg.sh
#  AmneziaWG 3.1 (основной VPN) как устанавливаемый протокол:
#  базовые пакеты, интерфейс awg1 с обфускацией, клиентские скрипты.
#  Используется в режиме 0 (конструктор) и для доустановки вручную.
#
#  Команды: install | remove | status
#  Переменные окружения (опционально):
#    ENDPOINT_HOST (домен/IP для клиентов), SERVER_NAME, AWG_PORT (585)
# =====================================================================
set -euo pipefail

NAME="amneziawg"
TITLE="AmneziaWG 3.1 (основной VPN)"
STATE_DIR="/etc/amnezia-protocols"
STATE_FILE="$STATE_DIR/$NAME.conf"
AWG_DIR="/etc/amnezia/amneziawg"
CASCADE_ENV="/etc/amnezia-cascade.env"

AWG_PORT="${AWG_PORT:-585}"
CLIENT_SUBNET="10.8.0"
CLIENT_SERVER_IP="10.8.0.1"
CLIENT_SUBNET6="fd00:10:8"
CLIENT_DNS="1.1.1.1, 1.0.0.1"
CLIENT_DNS6="2606:4700:4700::1111, 2606:4700:4700::1001"
CLIENT_MTU="1280"

MIRRORS=(
    "https://raw.githubusercontent.com/daff4ik/amneziawg-cascade-v3/main"
    "https://ghproxy.net/https://raw.githubusercontent.com/daff4ik/amneziawg-cascade-v3/main"
    "https://mirror.ghproxy.com/https://raw.githubusercontent.com/daff4ik/amneziawg-cascade-v3/main"
)

ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }
sed_escape() { printf '%s' "$1" | sed -e 's/[\/&|]/\\&/g'; }

[[ $EUID -ne 0 ]] && { err "Запускать от root (sudo $0)"; exit 1; }

download_repo() {
    # download_repo <относительный-путь> <куда>
    local rel=$1 dest=$2
    for m in "${MIRRORS[@]}"; do
        curl -fsSL --connect-timeout 5 --max-time 30 "$m/$rel" -o "$dest" && return 0
    done
    err "Не удалось скачать $rel"; return 1
}

do_install() {
    [[ -f "$STATE_FILE" || -f "$AWG_DIR/awg1.conf" ]] && { err "AmneziaWG уже установлен (возможно, установщиком deploy.sh)"; exit 1; }
    if ss -lun | awk '{print $4}' | grep -qE "[:.]${AWG_PORT}\$"; then
        err "Порт $AWG_PORT/udp занят. Выберите другой: AWG_PORT=586 $0 install"; exit 1
    fi

    RU_IP=$(curl -fsS -m 10 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
    HOST="${ENDPOINT_HOST:-$RU_IP}"
    SRV_NAME="${SERVER_NAME:-AmneziaVPN}"
    IFACE=$(ip route get 8.8.8.8 | awk '{print $5}' | head -1)
    [[ -z "$IFACE" ]] && { err "Не удалось определить внешний интерфейс"; exit 1; }

    # IPv6: включаем автоматически, если на сервере есть v6-маршрут
    IPV6=0
    ip -6 route show default 2>/dev/null | grep -q '^default' && IPV6=1

    # --- Базовые пакеты AmneziaWG ---
    echo "Установка базовых пакетов AmneziaWG..."
    download_repo "scripts/amnezia-server-install.sh" /tmp/amnezia-server-install.sh
    local flags=()
    [[ $IPV6 -eq 1 ]] && flags+=(--ipv6)
    bash /tmp/amnezia-server-install.sh "${flags[@]}" < /dev/null
    rm -f /tmp/amnezia-server-install.sh
    ok "Базовые пакеты установлены"

    # --- Параметры обфускации ---
    gen_ranges() {
        python3 - <<'PY'
import random
ranges = []
while len(ranges) < 4:
    start = random.randint(5, 2_000_000_000)
    end = start + random.randint(10_000_000, 100_000_000)
    if end > 2_147_483_647: continue
    if all(end < r[0] or start > r[1] for r in ranges):
        ranges.append((start, end))
print(" ".join(f"{s}-{e}" for s, e in ranges))
PY
    }
    local jmin=$((RANDOM % 40 + 10))
    local s1 s2
    while :; do
        s1=$((RANDOM % 50 + 12)); s2=$((RANDOM % 50 + 12))
        [[ $((s1 + 56)) -ne $s2 ]] && break
    done
    local HPK JC JMIN JMAX H1 H2 H3 H4
    HPK=$(awg genkey)
    JC=$((RANDOM % 6 + 3)); JMIN=$jmin; JMAX=$((jmin + RANDOM % 40 + 20))
    read -r H1 H2 H3 H4 <<< "$(gen_ranges)"

    # --- Ключи и конфиг awg1 ---
    mkdir -p "$AWG_DIR" && chmod 700 "$AWG_DIR"
    if [[ ! -f "$AWG_DIR/awg1_private.key" ]]; then
        umask 077
        awg genkey > "$AWG_DIR/awg1_private.key"
        awg pubkey < "$AWG_DIR/awg1_private.key" > "$AWG_DIR/awg1_public.key"
        chmod 600 "$AWG_DIR/awg1_private.key"; chmod 644 "$AWG_DIR/awg1_public.key"
    fi

    local MTU=1100 MSS=1000 V6_ADDR=""
    if [[ $IPV6 -eq 1 ]]; then
        MTU=1280; MSS=1220
        V6_ADDR="Address = ${CLIENT_SUBNET6}::1/64"
    fi

    cat > "$AWG_DIR/awg1.conf" <<EOF
[Interface]
PrivateKey = $(cat "$AWG_DIR/awg1_private.key")
Address = $CLIENT_SERVER_IP/24
$V6_ADDR
ListenPort = $AWG_PORT
MTU = $MTU
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $s1
S2 = $s2
S3 = $((RANDOM % 50 + 12))
S4 = $((RANDOM % 50 + 12))
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4
HeaderProtectionKey = $HPK
ContentPaddingAddition = 16
RekeyAfterTime = 100-120
RekeyTimeout = 3-7
RejectAfterTime = 150-180
KeepaliveTimeout = 5-15
MaxHandshakeAttempts = 15-20
RandomTrailers = on
DisableCookies = on
PostUp = iptables -A FORWARD -i awg1 -j ACCEPT
PostUp = iptables -A FORWARD -o awg1 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE
PostUp = while iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS 2>/dev/null; do :; done
PostUp = iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS
PostDown = iptables -D FORWARD -i awg1 -j ACCEPT
PostDown = iptables -D FORWARD -o awg1 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o $IFACE -j MASQUERADE
PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS 2>/dev/null || true
EOF
    chmod 600 "$AWG_DIR/awg1.conf"

    systemctl enable awg-quick@awg1
    systemctl restart awg-quick@awg1
    sleep 2
    systemctl is-active --quiet awg-quick@awg1 || { err "awg1 не поднялся: journalctl -u awg-quick@awg1"; exit 1; }

    # --- Клиентские скрипты ---
    local s
    for s in amnezia-add-client.sh amnezia-remove-client.sh amnezia-list-clients.sh amnezia-vpn-link.py; do
        download_repo "scripts/$s" "/tmp/$s"
        sed -e "s|__SERVER_ENDPOINT__|$(sed_escape "$HOST:$AWG_PORT")|g" \
            -e "s|__SERVER_NAME__|$(sed_escape "$SRV_NAME")|g" \
            -e "s|__CLIENT_MTU__|$CLIENT_MTU|g" \
            -e "s|__DNS_SERVERS__|$(sed_escape "$CLIENT_DNS")|g" \
            "/tmp/$s" > "/usr/local/bin/$s"
        chmod +x "/usr/local/bin/$s"
        rm -f "/tmp/$s"
    done
    mkdir -p /root/clients && chmod 700 /root/clients

    # --- Константы для панели и скриптов (не затираем существующие) ---
    [[ -f "$CASCADE_ENV" ]] && source "$CASCADE_ENV"
    cat > "$CASCADE_ENV" <<EOF
INSTALL_MODE="${INSTALL_MODE:-0}"
AWG_CLIENT_PORT="$AWG_PORT"
CLIENT_SUBNET="$CLIENT_SUBNET"
CLIENT_SERVER_IP="$CLIENT_SERVER_IP"
CLIENT_MTU="$CLIENT_MTU"
CLIENT_DNS="$CLIENT_DNS"
CLIENT_DNS6="$CLIENT_DNS6"
ENDPOINT_HOST="$HOST"
SERVER_NAME="$SRV_NAME"
IPV6_ENABLED="$IPV6"
CLIENT_SUBNET6="$CLIENT_SUBNET6"
MSS_CLAMP="$MSS"
EOF
    chmod 600 "$CASCADE_ENV"

    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
    cat > "$STATE_FILE" <<EOF
TITLE="$TITLE"
PORT="$AWG_PORT"
CLIENT_LINK=""
EOF
    chmod 600 "$STATE_FILE"

    ok "$TITLE установлен (порт $AWG_PORT/udp, IPv6 $([[ $IPV6 -eq 1 ]] && echo вкл || echo выкл))"
    echo "Клиенты: вкладка «Клиенты» в панели или sudo amnezia-add-client.sh <имя>"
}

do_remove() {
    # В режимах 1-3 AmneziaWG — базовая часть системы (ставит deploy.sh), удалять нельзя
    local MODE="0"
    [[ -f "$CASCADE_ENV" ]] && source "$CASCADE_ENV" && MODE="${INSTALL_MODE:-0}"
    [[ "$MODE" != "0" ]] && { err "AmneziaWG установлен как базовая часть системы (режим $MODE) — удаление не предусмотрено"; exit 1; }
    systemctl disable --now awg-quick@awg1 2>/dev/null || true
    rm -f "$AWG_DIR/awg1.conf" "$STATE_FILE"
    ok "$TITLE удалён (пакеты и конфиги клиентов в /root/clients сохранены)"
}

case "${1:-status}" in
    install) do_install ;;
    remove)  do_remove ;;
    status)
        # Установлен либо этой карточкой (state-файл), либо deploy.sh (есть awg1.conf)
        if [[ -f "$AWG_DIR/awg1.conf" ]]; then
            if systemctl is-active --quiet awg-quick@awg1; then STATE="работает"; else STATE="ОСТАНОВЛЕН"; fi
            PORT_SHOW=$(grep -oP '^ListenPort\s*=\s*\K\d+' "$AWG_DIR/awg1.conf" 2>/dev/null || echo "$AWG_PORT")
            echo "installed=1"
            echo "state=$STATE"
            echo "title=$TITLE"
            echo "port=$PORT_SHOW"
            echo "clients=$(grep -c '^# Client:' "$AWG_DIR/awg1.conf" 2>/dev/null || echo 0)"
        else
            echo "installed=0"
            echo "title=$TITLE"
        fi
        ;;
    *) echo "Использование: $0 install|remove|status"; exit 1 ;;
esac
