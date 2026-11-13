#!/bin/bash
# =====================================================================
#  amnezia-proto-wireguard.sh
#  Классический WireGuard (без обфускации AmneziaWG) — интерфейс wg0
#  через уже установленный awg-quick. Конфиг подходит стандартным
#  клиентам WireGuard (iOS/Android/Windows/macOS/Linux) и AmneziaWG.
#
#  ВНИМАНИЕ: трафик без обфускации легко определяется DPI — используйте
#  только там, где блокировки WireGuard не актуальны.
#
#  Команды: install | remove | status
#  Переменные окружения (опционально):
#    WG_PORT (по умолчанию 51820), ENDPOINT_HOST (адрес для клиента)
# =====================================================================
set -euo pipefail

NAME="wireguard"
TITLE="WireGuard (классический)"
STATE_DIR="/etc/amnezia-protocols"
STATE_FILE="$STATE_DIR/$NAME.conf"
WORK_DIR="$STATE_DIR/$NAME"
AWG_DIR="/etc/amnezia/amneziawg"
WG_CONF="$AWG_DIR/wg0.conf"
CLIENT_FILE="$WORK_DIR/wg-client1.conf"
CLIENTS_FILE="$WORK_DIR/clients.txt"
WG_SUBNET="10.30.0"

ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

[[ $EUID -ne 0 ]] && { err "Запускать от root (sudo $0)"; exit 1; }
command -v awg >/dev/null || { err "Нужен AmneziaWG (выполняется deploy-установщиком)"; exit 1; }

endpoint_host() {
    if [[ -n "${ENDPOINT_HOST:-}" ]]; then echo "$ENDPOINT_HOST"; return; fi
    [[ -f /etc/amnezia-cascade.env ]] && source /etc/amnezia-cascade.env
    if [[ -n "${ENDPOINT_HOST:-}" ]]; then echo "$ENDPOINT_HOST"; return; fi
    curl -fsS -m 10 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}'
}

do_install() {
    PORT="${WG_PORT:-51820}"
    [[ -f "$STATE_FILE" ]] && { err "Уже установлен. Сначала удалите: $0 remove"; exit 1; }
    if ss -lun | awk '{print $4}' | grep -qE "[:.]${PORT}\$"; then
        err "Порт $PORT/udp занят. Выберите другой: WG_PORT=51821 $0 install"; exit 1
    fi

    IFACE=$(ip route get 8.8.8.8 | awk '{print $5}' | head -1)
    [[ -z "$IFACE" ]] && { err "Не удалось определить внешний интерфейс"; exit 1; }
    HOST=$(endpoint_host)

    mkdir -p "$AWG_DIR" "$WORK_DIR" && chmod 700 "$AWG_DIR" "$WORK_DIR"
    umask 077
    awg genkey > "$WORK_DIR/server.key"
    awg pubkey < "$WORK_DIR/server.key" > "$WORK_DIR/server.pub"
    awg genkey > "$WORK_DIR/client1.key"
    awg pubkey < "$WORK_DIR/client1.key" > "$WORK_DIR/client1.pub"

    cat > "$WG_CONF" <<EOF
[Interface]
PrivateKey = $(cat "$WORK_DIR/server.key")
Address = $WG_SUBNET.1/24
ListenPort = $PORT
PostUp = iptables -t nat -A POSTROUTING -s $WG_SUBNET.0/24 -o $IFACE -j MASQUERADE
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s $WG_SUBNET.0/24 -o $IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT

[Peer]
# Client: wg-client1
PublicKey = $(cat "$WORK_DIR/client1.pub")
AllowedIPs = $WG_SUBNET.2/32
EOF
    chmod 600 "$WG_CONF"

    systemctl enable awg-quick@wg0
    systemctl restart awg-quick@wg0
    sleep 1
    systemctl is-active --quiet awg-quick@wg0 || { err "wg0 не поднялся: journalctl -u awg-quick@wg0"; exit 1; }

    cat > "$CLIENT_FILE" <<EOF
[Interface]
PrivateKey = $(cat "$WORK_DIR/client1.key")
Address = $WG_SUBNET.2/32
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = $(cat "$WORK_DIR/server.pub")
Endpoint = $HOST:$PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    chmod 600 "$CLIENT_FILE"

    echo "client1 $(cat "$WORK_DIR/client1.pub") $WG_SUBNET.2" > "$CLIENTS_FILE"
    chmod 600 "$CLIENTS_FILE"

    cat > "$STATE_FILE" <<EOF
TITLE="$TITLE"
PORT="$PORT"
HOST="$HOST"
IFACE="$IFACE"
CLIENT_FILE="$CLIENT_FILE"
CLIENT_LINK=""
EOF
    chmod 600 "$STATE_FILE"

    ok "$TITLE установлен (порт $PORT/udp)"
    echo "Клиентский конфиг: $CLIENT_FILE"
    command -v qrencode >/dev/null 2>&1 && { echo ""; qrencode -t ansiutf8 < "$CLIENT_FILE"; }
}

# === Управление клиентами (пиры wg0) ===
_wg_sync_conf() {
    # Пересобирает [Peer]-секции wg0.conf из clients.txt и применяет без рестарта
    python3 - "$WG_CONF" "$CLIENTS_FILE" <<'PY'
import sys
conf, lst = sys.argv[1], sys.argv[2]
c = open(conf).read()
iface = c.split("[Peer]")[0].rstrip() + "\n"
peers = ""
try:
    for line in open(lst):
        line = line.strip()
        if not line: continue
        n, pub, ip = line.split()
        peers += f"\n[Peer]\n# Client: {n}\nPublicKey = {pub}\nAllowedIPs = {ip}/32\n"
except FileNotFoundError:
    pass
open(conf, "w").write(iface + peers)
PY
    awg syncconf wg0 <(awg-quick strip wg0)
}

_wg_client_conf() {
    # $1 = имя, $2 = приватный ключ, $3 = IP; пишет $WORK_DIR/<имя>.conf
    ( source "$STATE_FILE"
      cat > "$WORK_DIR/$1.conf" <<EOF
[Interface]
PrivateKey = $2
Address = $3/32
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = $(cat "$WORK_DIR/server.pub")
Endpoint = $HOST:$PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
      chmod 600 "$WORK_DIR/$1.conf" )
}

do_add_client() {
    local cname="$1"
    [[ -f "$STATE_FILE" ]] || { err "Сначала установите: $0 install"; exit 1; }
    [[ "$cname" =~ ^[a-zA-Z0-9_-]+$ ]] || { err "Имя: только латиница, цифры, _ -"; exit 1; }
    awk '{print $1}' "$CLIENTS_FILE" 2>/dev/null | grep -qx "$cname" && { err "Клиент '$cname' уже существует"; exit 1; }
    local last ip=""
    for last in $(seq 2 254); do
        awk '{print $3}' "$CLIENTS_FILE" 2>/dev/null | grep -qx "$WG_SUBNET.$last" || { ip="$WG_SUBNET.$last"; break; }
    done
    [[ -z "$ip" ]] && { err "Нет свободных IP"; exit 1; }
    ( umask 077; awg genkey > "$WORK_DIR/$cname.key" )
    awg pubkey < "$WORK_DIR/$cname.key" > "$WORK_DIR/$cname.pub"
    echo "$cname $(cat "$WORK_DIR/$cname.pub") $ip" >> "$CLIENTS_FILE"
    _wg_sync_conf
    _wg_client_conf "$cname" "$(cat "$WORK_DIR/$cname.key")" "$ip"
    ok "Клиент '$cname' создан: $WORK_DIR/$cname.conf"
}

do_remove_client() {
    local cname="$1"
    [[ "$cname" == "client1" ]] && { err "client1 — основной, его удаление сломает исходный конфиг"; exit 1; }
    grep -q "^$cname " "$CLIENTS_FILE" 2>/dev/null || { err "Клиент '$cname' не найден"; exit 1; }
    sed -i "/^$cname /d" "$CLIENTS_FILE"
    _wg_sync_conf
    rm -f "$WORK_DIR/$cname.conf" "$WORK_DIR/$cname.key" "$WORK_DIR/$cname.pub"
    ok "Клиент '$cname' удалён"
}

do_clients() {
    # Формат строки: имя<TAB>file:путь
    [[ -f "$CLIENTS_FILE" ]] || exit 0
    while read -r cname _pub _ip; do
        [[ -z "$cname" ]] && continue
        [[ -f "$WORK_DIR/$cname.conf" ]] && echo -e "$cname\tfile:$WORK_DIR/$cname.conf"
    done < "$CLIENTS_FILE"
}

do_remove() {
    systemctl disable --now awg-quick@wg0 2>/dev/null || true
    rm -f "$WG_CONF" "$STATE_FILE"
    rm -rf "$WORK_DIR"
    ok "$TITLE удалён"
}

case "${1:-status}" in
    install) do_install ;;
    remove)  do_remove ;;
    add-client)    [[ -n "${2:-}" ]] || { err "Укажите имя: $0 add-client <имя>"; exit 1; }; do_add_client "$2" ;;
    remove-client) [[ -n "${2:-}" ]] || { err "Укажите имя: $0 remove-client <имя>"; exit 1; }; do_remove_client "$2" ;;
    clients)  do_clients ;;
    status)
        if [[ -f "$STATE_FILE" ]]; then
            source "$STATE_FILE"
            if systemctl is-active --quiet awg-quick@wg0; then STATE="работает"; else STATE="ОСТАНОВЛЕН"; fi
            echo "installed=1"
            echo "state=$STATE"
            echo "title=$TITLE"
            echo "port=$PORT"
            echo "file=$CLIENT_FILE"
            echo "clients_api=1"
            echo "clients=$(grep -c . "$CLIENTS_FILE" 2>/dev/null || echo 0)"
        else
            echo "installed=0"
            echo "title=$TITLE"
        fi
        ;;
    *) echo "Использование: $0 install|remove|status|clients|add-client <имя>|remove-client <имя>"; exit 1 ;;
esac
