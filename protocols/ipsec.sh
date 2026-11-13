#!/bin/bash
# =====================================================================
#  amnezia-proto-ipsec.sh
#  IKEv2/IPsec на strongSwan (EAP-MSCHAPv2: логин+пароль, сертификат CA).
#  Нативно поддерживается iOS/macOS/Windows/Android и AmneziaVPN.
#
#  Команды: install | remove | status
#  Переменные окружения (опционально):
#    IKE_USER (по умолчанию vpn), IKE_PASS (генерируется),
#    ENDPOINT_HOST (адрес сервера для клиентов)
# =====================================================================
set -euo pipefail

NAME="ipsec"
TITLE="IKEv2/IPsec (strongSwan)"
STATE_DIR="/etc/amnezia-protocols"
STATE_FILE="$STATE_DIR/$NAME.conf"
WORK_DIR="$STATE_DIR/$NAME"
CLIENT_FILE="$WORK_DIR/ikev2-client.txt"

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
    [[ -f "$STATE_FILE" ]] && { err "Уже установлен. Сначала удалите: $0 remove"; exit 1; }
    USER_NAME="${IKE_USER:-vpn}"
    USER_PASS="${IKE_PASS:-$(openssl rand -hex 8)}"
    HOST=$(endpoint_host)
    IFACE=$(ip route get 8.8.8.8 | awk '{print $5}' | head -1)
    [[ -z "$IFACE" ]] && { err "Не удалось определить внешний интерфейс"; exit 1; }

    apt update -qq < /dev/null
    apt install -y -qq strongswan < /dev/null

    # --- PKI: свой CA + сертификат сервера ---
    mkdir -p /etc/ipsec.d/private /etc/ipsec.d/cacerts /etc/ipsec.d/certs "$WORK_DIR"
    chmod 700 /etc/ipsec.d/private "$WORK_DIR"
    ipsec pki --gen --type rsa --size 4096 --outform pem > /etc/ipsec.d/private/ca-key.pem
    ipsec pki --self --ca --lifetime 3650 --in /etc/ipsec.d/private/ca-key.pem \
        --dn "CN=Amnezia VPN CA" --outform pem > /etc/ipsec.d/cacerts/ca-cert.pem
    ipsec pki --gen --type rsa --size 2048 --outform pem > /etc/ipsec.d/private/server-key.pem
    ipsec pki --pub --in /etc/ipsec.d/private/server-key.pem | \
        ipsec pki --issue --lifetime 1825 --cacert /etc/ipsec.d/cacerts/ca-cert.pem \
        --cakey /etc/ipsec.d/private/ca-key.pem --dn "CN=$HOST" --san "$HOST" \
        --flag serverAuth --flag ikeIntermediate --outform pem > /etc/ipsec.d/certs/server-cert.pem
    chmod 600 /etc/ipsec.d/private/*.pem

    # --- Конфигурация ---
    [[ -f /etc/ipsec.conf ]] && cp /etc/ipsec.conf "/etc/ipsec.conf.bak.$(date +%s)" || true
    cat > /etc/ipsec.conf <<EOF
config setup
    charondebug="ike 1, knl 1, cfg 0"
    uniqueids=no

conn ikev2-amnezia
    auto=add
    compress=no
    type=tunnel
    keyexchange=ikev2
    fragmentation=yes
    forceencaps=yes
    dpdaction=clear
    dpddelay=300s
    rekey=no
    left=%any
    leftid=@$HOST
    leftcert=server-cert.pem
    leftsendcert=always
    leftsubnet=0.0.0.0/0
    right=%any
    rightid=%any
    rightauth=eap-mschapv2
    rightsourceip=10.20.0.0/24
    rightdns=1.1.1.1,1.0.0.1
    rightsendcert=never
    eap_identity=%identity
    ike=chacha20poly1305-sha512-curve25519-prfsha512,aes256gcm16-sha384-prfsha384-ecp384,aes256-sha1-modp1024!
    esp=chacha20poly1305-sha512,aes256gcm16-ecp384,aes256-sha1!
EOF

    [[ -f /etc/ipsec.secrets ]] && cp /etc/ipsec.secrets "/etc/ipsec.secrets.bak.$(date +%s)" || true
    cat > /etc/ipsec.secrets <<EOF
: RSA "server-key.pem"
$USER_NAME : EAP "$USER_PASS"
EOF
    chmod 600 /etc/ipsec.secrets

    # --- NAT для клиентской подсети ---
    mkdir -p /etc/systemd/system/strongswan-starter.service.d
    cat > /etc/systemd/system/strongswan-starter.service.d/amnezia.conf <<EOF
[Service]
ExecStartPost=/sbin/iptables -t nat -A POSTROUTING -s 10.20.0.0/24 -o $IFACE -j MASQUERADE
ExecStopPost=/sbin/iptables -t nat -D POSTROUTING -s 10.20.0.0/24 -o $IFACE -j MASQUERADE
EOF
    systemctl daemon-reload
    systemctl enable strongswan-starter
    systemctl restart strongswan-starter
    sleep 2
    systemctl is-active --quiet strongswan-starter || { err "strongSwan не запустился: journalctl -u strongswan-starter"; exit 1; }

    # --- Файл с данными для подключения ---
    cp /etc/ipsec.d/cacerts/ca-cert.pem "$WORK_DIR/ca-cert.pem"
    cat > "$CLIENT_FILE" <<EOF
Подключение IKEv2/IPsec
=======================
Сервер (адрес):  $HOST
Порты:           UDP 500, UDP 4500 (+ протокол ESP)
Логин:           $USER_NAME
Пароль:          $USER_PASS
Сертификат CA:   $WORK_DIR/ca-cert.pem (импортировать и доверять,
                 либо в клиенте отключить проверку сертификата)

AmneziaVPN: Добавить профиль → IKEv2 → ввести сервер, логин, пароль.
iOS/macOS:  VPN → IKEv2, Server и Remote ID = $HOST.
Android:    strongSwan VPN Client (IKEv2 EAP).
Windows:    VPN → IKEv2, предварительно установить ca-cert.pem
            в «Доверенные корневые центры сертификации».
EOF
    chmod 600 "$CLIENT_FILE"

    cat > "$STATE_FILE" <<EOF
TITLE="$TITLE"
PORT="500,4500/udp"
HOST="$HOST"
CLIENT_FILE="$CLIENT_FILE"
CLIENT_LINK="сервер $HOST, логин $USER_NAME, пароль $USER_PASS"
EOF
    chmod 600 "$STATE_FILE"

    # Файл основного пользователя в едином формате (<логин>.txt)
    cat > "$WORK_DIR/$USER_NAME.txt" <<EOF
Подключение IKEv2/IPsec
=======================
Сервер (адрес):  $HOST
Логин:           $USER_NAME
Пароль:          $USER_PASS
Сертификат CA:   $WORK_DIR/ca-cert.pem
EOF
    chmod 600 "$WORK_DIR/$USER_NAME.txt"

    ok "$TITLE установлен"
    echo "Данные для подключения: $CLIENT_FILE"
}

do_remove() {
    systemctl disable --now strongswan-starter 2>/dev/null || true
    rm -rf /etc/systemd/system/strongswan-starter.service.d "$WORK_DIR" "$STATE_FILE"
    systemctl daemon-reload
    ok "$TITLE удалён (пакет strongswan оставлен в системе)"
}

# === Управление клиентами (пользователи EAP) ===
_ike_client_file() {
    # $1 = логин, $2 = пароль; пишет $WORK_DIR/<логин>.txt
    ( source "$STATE_FILE"
      cat > "$WORK_DIR/$1.txt" <<EOF
Подключение IKEv2/IPsec
=======================
Сервер (адрес):  $HOST
Логин:           $1
Пароль:          $2
Сертификат CA:   $WORK_DIR/ca-cert.pem
EOF
      chmod 600 "$WORK_DIR/$1.txt" )
}

do_add_client() {
    local cname="$1"
    [[ -f "$STATE_FILE" ]] || { err "Сначала установите: $0 install"; exit 1; }
    [[ "$cname" =~ ^[a-zA-Z0-9_-]+$ ]] || { err "Имя: только латиница, цифры, _ -"; exit 1; }
    grep -q "^$cname : EAP " /etc/ipsec.secrets && { err "Клиент '$cname' уже существует"; exit 1; }
    local pass
    pass=$(openssl rand -hex 8)
    echo "$cname : EAP \"$pass\"" >> /etc/ipsec.secrets
    ipsec rereadsecrets 2>/dev/null || systemctl restart strongswan-starter
    _ike_client_file "$cname" "$pass"
    ok "Клиент '$cname' создан: $WORK_DIR/$cname.txt"
}

do_remove_client() {
    local cname="$1"
    grep -q "^$cname : EAP " /etc/ipsec.secrets 2>/dev/null || { err "Клиент '$cname' не найден"; exit 1; }
    sed -i "/^$cname : EAP /d" /etc/ipsec.secrets
    ipsec rereadsecrets 2>/dev/null || systemctl restart strongswan-starter
    rm -f "$WORK_DIR/$cname.txt"
    ok "Клиент '$cname' удалён"
}

do_clients() {
    # Формат строки: имя<TAB>file:путь
    grep -oP '^[a-zA-Z0-9_-]+(?= : EAP )' /etc/ipsec.secrets 2>/dev/null | while read -r cname; do
        [[ -f "$WORK_DIR/$cname.txt" ]] && echo -e "$cname\tfile:$WORK_DIR/$cname.txt"
    done
    exit 0
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
            if systemctl is-active --quiet strongswan-starter; then STATE="работает"; else STATE="ОСТАНОВЛЕН"; fi
            echo "installed=1"
            echo "state=$STATE"
            echo "title=$TITLE"
            echo "port=$PORT"
            echo "link=$CLIENT_LINK"
            echo "file=$CLIENT_FILE"
            echo "clients_api=1"
            echo "clients=$(grep -c ' : EAP ' /etc/ipsec.secrets 2>/dev/null || echo 0)"
        else
            echo "installed=0"
            echo "title=$TITLE"
        fi
        ;;
    *) echo "Использование: $0 install|remove|status|clients|add-client <имя>|remove-client <имя>"; exit 1 ;;
esac
