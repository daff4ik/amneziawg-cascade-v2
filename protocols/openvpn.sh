#!/bin/bash
# =====================================================================
#  amnezia-proto-openvpn.sh
#  OpenVPN (UDP, AES-256-GCM, tls-crypt). Один клиентский профиль .ovpn —
#  импортируется в AmneziaVPN («Добавить профиль → файл .ovpn»)
#  и в любой OpenVPN-клиент.
#
#  Команды: install | remove | status
#  Переменные окружения (опционально):
#    OVPN_PORT (по умолчанию 1194), ENDPOINT_HOST (адрес для клиента)
# =====================================================================
set -euo pipefail

NAME="openvpn"
TITLE="OpenVPN"
STATE_DIR="/etc/amnezia-protocols"
STATE_FILE="$STATE_DIR/$NAME.conf"
WORK_DIR="$STATE_DIR/$NAME"
OVPN_DIR="/etc/openvpn/amnezia"
CLIENT_FILE="$WORK_DIR/client.ovpn"

ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

[[ $EUID -ne 0 ]] && { err "Запускать от root (sudo $0)"; exit 1; }

endpoint_host() {
    if [[ -n "${ENDPOINT_HOST:-}" ]]; then echo "$ENDPOINT_HOST"; return; fi
    [[ -f /etc/amnezia-cascade.env ]] && source /etc/amnezia-cascade.env
    if [[ -n "${ENDPOINT_HOST:-}" ]]; then echo "$ENDPOINT_HOST"; return; fi
    curl -fsS -m 10 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}'
}

do_install() {
    PORT="${OVPN_PORT:-1194}"
    [[ -f "$STATE_FILE" ]] && { err "Уже установлен. Сначала удалите: $0 remove"; exit 1; }
    if ss -lun | awk '{print $4}' | grep -qE "[:.]${PORT}\$"; then
        err "Порт $PORT/udp занят. Выберите другой: OVPN_PORT=1294 $0 install"; exit 1
    fi

    apt update -qq < /dev/null
    apt install -y -qq openvpn < /dev/null

    IFACE=$(ip route get 8.8.8.8 | awk '{print $5}' | head -1)
    [[ -z "$IFACE" ]] && { err "Не удалось определить внешний интерфейс"; exit 1; }
    HOST=$(endpoint_host)

    # --- PKI: CA, сервер, клиент ---
    mkdir -p "$OVPN_DIR" "$WORK_DIR" && chmod 700 "$OVPN_DIR" "$WORK_DIR"
    cd "$OVPN_DIR"
    openssl genrsa -out ca.key 4096 2>/dev/null
    openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
        -subj "/CN=Amnezia-CA" -out ca.crt 2>/dev/null
    for cert in server client; do
        openssl genrsa -out "$cert.key" 2048 2>/dev/null
        openssl req -new -key "$cert.key" -subj "/CN=$cert" -out "$cert.csr" 2>/dev/null
        openssl x509 -req -in "$cert.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
            -days 3650 -sha256 -out "$cert.crt" 2>/dev/null
        rm -f "$cert.csr"
    done
    openvpn --genkey secret ta.key
    chmod 600 ca.key server.key client.key ta.key

    cat > "$OVPN_DIR/server.conf" <<EOF
port $PORT
proto udp
dev tun
ca $OVPN_DIR/ca.crt
cert $OVPN_DIR/server.crt
key $OVPN_DIR/server.key
dh none
ecdh-curve prime256v1
tls-crypt $OVPN_DIR/ta.key
cipher AES-256-GCM
auth SHA256
topology subnet
server 10.9.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 1.0.0.1"
keepalive 10 60
persist-key
persist-tun
user nobody
group nogroup
verb 3
EOF
    chmod 600 "$OVPN_DIR/server.conf"

    cat > /etc/systemd/system/openvpn-amnezia.service <<EOF
[Unit]
Description=OpenVPN (Amnezia)
After=network.target

[Service]
ExecStart=/usr/sbin/openvpn --config $OVPN_DIR/server.conf
ExecStartPost=/sbin/iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -o $IFACE -j MASQUERADE
ExecStartPost=/sbin/iptables -A FORWARD -i tun0 -j ACCEPT
ExecStartPost=/sbin/iptables -A FORWARD -o tun0 -j ACCEPT
ExecStopPost=/sbin/iptables -t nat -D POSTROUTING -s 10.9.0.0/24 -o $IFACE -j MASQUERADE
ExecStopPost=/sbin/iptables -D FORWARD -i tun0 -j ACCEPT
ExecStopPost=/sbin/iptables -D FORWARD -o tun0 -j ACCEPT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable openvpn-amnezia
    systemctl restart openvpn-amnezia
    sleep 2
    systemctl is-active --quiet openvpn-amnezia || { err "OpenVPN не запустился: journalctl -u openvpn-amnezia"; exit 1; }

    # --- Клиентский профиль (.ovpn со встроенными ключами) ---
    cat > "$CLIENT_FILE" <<EOF
client
dev tun
proto udp
remote $HOST $PORT
resolv-retry infinite
nobind
persist-key
persist-tun
cipher AES-256-GCM
auth SHA256
remote-cert-tls server
key-direction 1
verb 3
<ca>
$(cat ca.crt)
</ca>
<cert>
$(cat client.crt)
</cert>
<key>
$(cat client.key)
</key>
<tls-crypt>
$(cat ta.key)
</tls-crypt>
EOF
    chmod 600 "$CLIENT_FILE"

    cat > "$STATE_FILE" <<EOF
TITLE="$TITLE"
PORT="$PORT"
HOST="$HOST"
CLIENT_FILE="$CLIENT_FILE"
CLIENT_LINK=""
EOF
    chmod 600 "$STATE_FILE"

    ok "$TITLE установлен (порт $PORT/udp)"
    echo "Клиентский профиль: $CLIENT_FILE"
}

# === Управление клиентами (отдельный сертификат на клиента) ===
# NB: отзыва (CRL) нет — удаление убирает только файлы профиля.
# Для полного отзыва клиента переустановите протокол (remove/install).
_ovpn_build() {
    # $1 = имя клиента (CN); пишет $WORK_DIR/<имя>.ovpn
    ( source "$STATE_FILE"
      cat > "$WORK_DIR/$1.ovpn" <<EOF
client
dev tun
proto udp
remote $HOST $PORT
resolv-retry infinite
nobind
persist-key
persist-tun
cipher AES-256-GCM
auth SHA256
remote-cert-tls server
key-direction 1
verb 3
<ca>
$(cat "$OVPN_DIR/ca.crt")
</ca>
<cert>
$(cat "$OVPN_DIR/$1.crt")
</cert>
<key>
$(cat "$OVPN_DIR/$1.key")
</key>
<tls-crypt>
$(cat "$OVPN_DIR/ta.key")
</tls-crypt>
EOF
      chmod 600 "$WORK_DIR/$1.ovpn" )
}

do_add_client() {
    local cname="$1"
    [[ -f "$STATE_FILE" ]] || { err "Сначала установите: $0 install"; exit 1; }
    [[ "$cname" =~ ^[a-zA-Z0-9_-]+$ ]] || { err "Имя: только латиница, цифры, _ -"; exit 1; }
    [[ -f "$WORK_DIR/$cname.ovpn" ]] && { err "Клиент '$cname' уже существует"; exit 1; }
    ( cd "$OVPN_DIR"
      openssl genrsa -out "$cname.key" 2048 2>/dev/null
      openssl req -new -key "$cname.key" -subj "/CN=$cname" -out "$cname.csr" 2>/dev/null
      openssl x509 -req -in "$cname.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
          -days 3650 -sha256 -out "$cname.crt" 2>/dev/null
      rm -f "$cname.csr"
      chmod 600 "$cname.key" )
    _ovpn_build "$cname"
    ok "Клиент '$cname' создан: $WORK_DIR/$cname.ovpn"
}

do_remove_client() {
    local cname="$1"
    [[ -f "$WORK_DIR/$cname.ovpn" ]] || { err "Клиент '$cname' не найден"; exit 1; }
    rm -f "$WORK_DIR/$cname.ovpn" "$OVPN_DIR/$cname.key" "$OVPN_DIR/$cname.crt"
    ok "Клиент '$cname' удалён (профиль стёрт; для отзыва сертификата — переустановка протокола)"
}

do_clients() {
    # Формат строки: имя<TAB>file:путь
    local f base
    shopt -s nullglob
    for f in "$WORK_DIR"/*.ovpn; do
        base=$(basename "$f" .ovpn)
        echo -e "$base\tfile:$f"
    done
    shopt -u nullglob
}

do_remove() {
    systemctl disable --now openvpn-amnezia 2>/dev/null || true
    rm -f /etc/systemd/system/openvpn-amnezia.service "$STATE_FILE"
    rm -rf "$OVPN_DIR" "$WORK_DIR"
    systemctl daemon-reload
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
            if systemctl is-active --quiet openvpn-amnezia; then STATE="работает"; else STATE="ОСТАНОВЛЕН"; fi
            echo "installed=1"
            echo "state=$STATE"
            echo "title=$TITLE"
            echo "port=$PORT"
            echo "file=$CLIENT_FILE"
            echo "clients_api=1"
            echo "clients=$(ls -1 "$WORK_DIR"/*.ovpn 2>/dev/null | wc -l)"
        else
            echo "installed=0"
            echo "title=$TITLE"
        fi
        ;;
    *) echo "Использование: $0 install|remove|status|clients|add-client <имя>|remove-client <имя>"; exit 1 ;;
esac
