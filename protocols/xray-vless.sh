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
    rm -f /etc/systemd/system/xray.service "$STATE_FILE"
    systemctl daemon-reload
    ok "$TITLE удалён"
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
    else
        echo "installed=0"
        echo "title=$TITLE"
    fi
}

case "${1:-status}" in
    install) do_install ;;
    remove)  do_remove ;;
    status)  do_status ;;
    *) echo "Использование: $0 install|remove|status"; exit 1 ;;
esac
