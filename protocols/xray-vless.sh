#!/bin/bash
# =====================================================================
#  amnezia-proto-xray-vless.sh
#  VLESS + REALITY (XTLS Vision) на базе xray-core.
#  Клиентская ссылка — стандартная vless:// (импортируется в AmneziaVPN
#  и другие клиенты: «Добавить профиль → вставить ключ»).
#
#  Команды: install | remove | status
#  Переменные окружения (опционально):
#    XRAY_PORT (по умолчанию 443), XRAY_SNI (маскировочный домен),
#    ENDPOINT_HOST (адрес для ссылки, иначе — внешний IP сервера)
# =====================================================================
set -euo pipefail

NAME="xray-vless"
TITLE="VLESS + REALITY (Xray)"
STATE_DIR="/etc/amnezia-protocols"
STATE_FILE="$STATE_DIR/$NAME.conf"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF_DIR="/usr/local/etc/xray"
XRAY_CONF="$XRAY_CONF_DIR/config.json"
CLIENTS_FILE="$STATE_DIR/$NAME.clients"

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
    PORT="${XRAY_PORT:-443}"
    SNI="${XRAY_SNI:-www.microsoft.com}"

    if [[ -f "$STATE_FILE" ]]; then
        err "Уже установлен. Сначала удалите: $0 remove"; exit 1
    fi
    if ss -ltn | awk '{print $4}' | grep -qE "[:.]${PORT}\$"; then
        err "Порт $PORT занят. Выберите другой: XRAY_PORT=8444 $0 install"; exit 1
    fi

    # --- Бинарник xray (последний релиз с GitHub) ---
    if [[ ! -x "$XRAY_BIN" ]]; then
        echo "Скачивание xray-core..."
        URL=$(curl -fsSL -m 15 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
            | grep -oP '"browser_download_url":\s*"\K[^"]*Xray-linux-64\.zip' | head -1)
        [[ -z "$URL" ]] && { err "Не удалось получить ссылку на релиз xray"; exit 1; }
        curl -fsSL -m 120 "$URL" -o /tmp/xray.zip
        apt install -y -qq unzip < /dev/null
        unzip -o /tmp/xray.zip xray geoip.dat geosite.dat -d /tmp/xray-dist >/dev/null
        install -m 755 /tmp/xray-dist/xray "$XRAY_BIN"
        mkdir -p "$XRAY_CONF_DIR"
        install -m 644 /tmp/xray-dist/geoip.dat /tmp/xray-dist/geosite.dat "$XRAY_CONF_DIR/"
        rm -rf /tmp/xray.zip /tmp/xray-dist
    fi
    ok "xray-core: $("$XRAY_BIN" version | head -1)"

    # --- Ключи и параметры ---
    UUID=$("$XRAY_BIN" uuid)
    KEYS=$("$XRAY_BIN" x25519)
    PRIV=$(echo "$KEYS" | awk '/PrivateKey:/ {print $2}')
    PUB=$(echo "$KEYS" | awk '/PublicKey:/ {print $2}')
    [[ -z "$PRIV" || -z "$PUB" ]] && { PRIV=$(echo "$KEYS" | awk '/Private key:/ {print $3}'); PUB=$(echo "$KEYS" | awk '/Public key:/ {print $3}'); }
    [[ -n "$PRIV" && -n "$PUB" ]] || { err "Не удалось сгенерировать x25519 ключи"; exit 1; }
    SID=$(openssl rand -hex 8)
    HOST=$(endpoint_host)

    # --- Конфиг сервера ---
    mkdir -p "$XRAY_CONF_DIR"
    cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$UUID", "flow": "xtls-rprx-vision" } ],
        "decryption": "none",
        "fallbacks": [ { "dest": "127.0.0.1:80" } ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$SNI:443",
          "xver": 0,
          "serverNames": [ "$SNI" ],
          "privateKey": "$PRIV",
          "shortIds": [ "$SID" ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
EOF
    chmod 600 "$XRAY_CONF"

    # --- systemd ---
    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray (VLESS+REALITY)
After=network.target

[Service]
ExecStart=$XRAY_BIN run -c $XRAY_CONF
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xray
    systemctl restart xray
    sleep 1
    systemctl is-active --quiet xray || { err "xray не запустился: journalctl -u xray"; exit 1; }

    LINK="vless://$UUID@$HOST:$PORT?type=tcp&security=reality&pbk=$PUB&fp=chrome&sni=$SNI&sid=$SID&flow=xtls-rprx-vision#Amnezia-VLESS"
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
    echo "default $UUID" > "$CLIENTS_FILE" && chmod 600 "$CLIENTS_FILE"
    cat > "$STATE_FILE" <<EOF
TITLE="$TITLE"
PORT="$PORT"
SNI="$SNI"
UUID="$UUID"
PUBLIC_KEY="$PUB"
SHORT_ID="$SID"
HOST="$HOST"
CLIENT_LINK="$LINK"
EOF
    chmod 600 "$STATE_FILE"

    ok "$TITLE установлен (порт $PORT, маскировка под $SNI)"
    echo ""
    echo "Ссылка для импорта в AmneziaVPN (и другие клиенты):"
    echo "$LINK"
    command -v qrencode >/dev/null 2>&1 && { echo ""; qrencode -t ansiutf8 "$LINK"; }
}

do_remove() {
    systemctl disable --now xray 2>/dev/null || true
    rm -f /etc/systemd/system/xray.service "$STATE_FILE" "$CLIENTS_FILE"
    systemctl daemon-reload
    ok "$TITLE удалён"
}

# === Управление клиентами (UUID в config.json) ===
_vless_link() {
    # $1 = uuid, $2 = имя клиента; параметры — из state-файла
    ( source "$STATE_FILE"
      echo "vless://$1@$HOST:$PORT?type=tcp&security=reality&pbk=$PUBLIC_KEY&fp=chrome&sni=$SNI&sid=$SHORT_ID&flow=xtls-rprx-vision#Amnezia-$2" )
}

_cfg_add_uuid() {
    python3 - "$XRAY_CONF" "$1" <<'PY'
import json, sys
p, uid = sys.argv[1], sys.argv[2]
c = json.load(open(p))
c["inbounds"][0]["settings"]["clients"].append({"id": uid, "flow": "xtls-rprx-vision"})
json.dump(c, open(p, "w"), indent=2)
PY
}

_cfg_del_uuid() {
    python3 - "$XRAY_CONF" "$1" <<'PY'
import json, sys
p, uid = sys.argv[1], sys.argv[2]
c = json.load(open(p))
cl = c["inbounds"][0]["settings"]["clients"]
c["inbounds"][0]["settings"]["clients"] = [x for x in cl if x.get("id") != uid]
json.dump(c, open(p, "w"), indent=2)
PY
}

do_add_client() {
    local cname="$1"
    [[ -f "$STATE_FILE" ]] || { err "Сначала установите: $0 install"; exit 1; }
    [[ "$cname" =~ ^[a-zA-Z0-9_-]+$ ]] || { err "Имя: только латиница, цифры, _ -"; exit 1; }
    grep -q "^$cname " "$CLIENTS_FILE" 2>/dev/null && { err "Клиент '$cname' уже существует"; exit 1; }
    local uid
    uid=$("$XRAY_BIN" uuid)
    _cfg_add_uuid "$uid"
    echo "$cname $uid" >> "$CLIENTS_FILE"
    systemctl restart xray
    ok "Клиент '$cname' создан"
    _vless_link "$uid" "$cname"
}

do_remove_client() {
    local cname="$1"
    local uid
    uid=$(awk -v n="$cname" '$1==n {print $2}' "$CLIENTS_FILE" 2>/dev/null | head -1)
    [[ -z "$uid" ]] && { err "Клиент '$cname' не найден"; exit 1; }
    _cfg_del_uuid "$uid"
    sed -i "/^$cname /d" "$CLIENTS_FILE"
    systemctl restart xray
    ok "Клиент '$cname' удалён"
}

do_clients() {
    # Формат строки: имя<TAB>ссылка
    [[ -f "$CLIENTS_FILE" ]] || exit 0
    while read -r cname uid; do
        [[ -z "$cname" ]] && continue
        echo -e "$cname\t$(_vless_link "$uid" "$cname")"
    done < "$CLIENTS_FILE"
}

# === Каскад A → B: локальный xray заворачивает трафик в xray на SERVER-B ===
# Использование: SSHPASS='<пароль>' $0 cascade <IP B> [ssh-порт] [ssh-пользователь]
do_cascade() {
    local B_IP="$1" B_SSH_PORT="${2:-22}" B_USER="${3:-root}"
    [[ -f "$STATE_FILE" ]] || { err "Сначала установите: $0 install"; exit 1; }
    [[ -n "${SSHPASS:-}" ]] || { err "Нужен пароль SERVER-B в переменной SSHPASS"; exit 1; }
    command -v sshpass >/dev/null || { apt update -qq < /dev/null && apt install -y -qq sshpass < /dev/null; }
    export SSHPASS
    run_b() { sshpass -e ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 -p "$B_SSH_PORT" "$B_USER@$B_IP" "$@"; }
    run_b "echo SSH_OK" | grep -q SSH_OK || { err "SSH до $B_IP не работает"; exit 1; }

    echo "Установка xray на SERVER-B ($B_IP)..."
    sshpass -e scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -P "$B_SSH_PORT" "$0" "$B_USER@$B_IP:/usr/local/bin/amnezia-proto-xray-vless.sh"
    run_b "chmod +x /usr/local/bin/amnezia-proto-xray-vless.sh && \
        ENDPOINT_HOST=$B_IP /usr/local/bin/amnezia-proto-xray-vless.sh install" \
        || { err "Не удалось установить xray на SERVER-B"; exit 1; }

    # Параметры сервера B из его state-файла
    local B_STATE
    B_STATE=$(run_b "cat /etc/amnezia-protocols/xray-vless.conf")
    local B_UUID B_XPORT B_SNI B_PUB B_SID
    B_UUID=$(grep -oP '^UUID="\K[^"]+' <<< "$B_STATE")
    B_XPORT=$(grep -oP '^PORT="\K[^"]+' <<< "$B_STATE")
    B_SNI=$(grep -oP '^SNI="\K[^"]+' <<< "$B_STATE")
    B_PUB=$(grep -oP '^PUBLIC_KEY="\K[^"]+' <<< "$B_STATE")
    B_SID=$(grep -oP '^SHORT_ID="\K[^"]+' <<< "$B_STATE")
    [[ -n "$B_UUID" && -n "$B_PUB" ]] || { err "Не удалось получить параметры xray с SERVER-B"; exit 1; }

    # Исходящее подключение A → B (xray на A становится клиентом B)
    python3 - "$XRAY_CONF" "$B_IP" "$B_XPORT" "$B_UUID" "$B_SNI" "$B_PUB" "$B_SID" <<'PY'
import json, sys
p, ip, port, uid, sni, pub, sid = sys.argv[1:8]
c = json.load(open(p))
c["outbounds"] = [{
    "protocol": "vless", "tag": "proxy",
    "settings": {"vnext": [{"address": ip, "port": int(port),
        "users": [{"id": uid, "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
    "streamSettings": {"network": "tcp", "security": "reality",
        "realitySettings": {"serverName": sni, "publicKey": pub, "shortId": sid, "fingerprint": "chrome"}}
}]
json.dump(c, open(p, "w"), indent=2)
PY
    systemctl restart xray
    sleep 1
    systemctl is-active --quiet xray || { err "xray не запустился после настройки каскада"; exit 1; }
    sed -i '/^CASCADE=/d' "$STATE_FILE"
    echo "CASCADE=\"$B_IP\"" >> "$STATE_FILE"
    ok "Каскад настроен: клиенты → этот сервер → $B_IP → интернет"
}

do_direct() {
    [[ -f "$STATE_FILE" ]] || { err "Не установлен"; exit 1; }
    python3 - "$XRAY_CONF" <<'PY'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c["outbounds"] = [{"protocol": "freedom", "tag": "direct"}]
json.dump(c, open(p, "w"), indent=2)
PY
    systemctl restart xray
    sed -i '/^CASCADE=/d' "$STATE_FILE"
    echo 'CASCADE=""' >> "$STATE_FILE"
    ok "Каскад отключён — прямое подключение (xray на SERVER-B оставлен, удалите его там при желании)"
}

do_status() {
    if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE"
        if systemctl is-active --quiet xray; then STATE="работает"; else STATE="ОСТАНОВЛЕН"; fi
        echo "installed=1"
        echo "state=$STATE"
        echo "title=$TITLE"
        echo "port=$PORT"
        echo "link=$CLIENT_LINK"
        echo "cascade=${CASCADE:-}"
        echo "clients_api=1"
        echo "clients=$(grep -c . "$CLIENTS_FILE" 2>/dev/null || echo 0)"
    else
        echo "installed=0"
        echo "title=$TITLE"
    fi
}

case "${1:-status}" in
    install) do_install ;;
    remove)  do_remove ;;
    cascade) [[ -n "${2:-}" ]] || { err "Укажите IP SERVER-B: SSHPASS=... $0 cascade <IP> [ssh-порт] [пользователь]"; exit 1; }; do_cascade "$2" "${3:-22}" "${4:-root}" ;;
    direct)  do_direct ;;
    add-client)    [[ -n "${2:-}" ]] || { err "Укажите имя: $0 add-client <имя>"; exit 1; }; do_add_client "$2" ;;
    remove-client) [[ -n "${2:-}" ]] || { err "Укажите имя: $0 remove-client <имя>"; exit 1; }; do_remove_client "$2" ;;
    clients)  do_clients ;;
    status)  do_status ;;
    *) echo "Использование: $0 install|remove|status|clients|add-client <имя>|remove-client <имя>|cascade <IP B>|direct"; exit 1 ;;
esac
