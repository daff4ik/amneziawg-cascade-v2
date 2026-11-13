#!/bin/bash
# =====================================================================
#  amnezia-proto-tor-site.sh
#  Сайт в сети Tor (onion-сервис v3): статика на 127.0.0.1:8088 +
#  скрытый сервис Tor. Файлы сайта — /var/www/tor-site (можно менять).
#
#  Команды: install | remove | status
# =====================================================================
set -euo pipefail

NAME="tor-site"
TITLE="Сайт в Tor (onion)"
STATE_DIR="/etc/amnezia-protocols"
STATE_FILE="$STATE_DIR/$NAME.conf"
WEB_ROOT="/var/www/tor-site"
HS_DIR="/var/lib/tor/amnezia_site"
LOCAL_PORT="8088"

ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

[[ $EUID -ne 0 ]] && { err "Запускать от root (sudo $0)"; exit 1; }

do_install() {
    if [[ -f "$STATE_FILE" ]]; then
        err "Уже установлен. Сначала удалите: $0 remove"; exit 1
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt install -y -qq tor < /dev/null

    # --- Статика ---
    mkdir -p "$WEB_ROOT"
    if [[ ! -f "$WEB_ROOT/index.html" ]]; then
        cat > "$WEB_ROOT/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Сайт в разработке</title>
    <style>
        body { background: #000; color: #ccc; font-family: Arial, sans-serif; text-align: center; margin: 0; }
        p { margin-top: 45vh; font-size: 16px; }
    </style>
</head>
<body>
    <p>Сайт в разработке</p>
</body>
</html>
EOF
    fi
    chmod 755 /var/www
    chmod -R 755 "$WEB_ROOT"

    # --- Локальный веб-сервер для статики ---
    cat > /etc/systemd/system/tor-site-web.service <<EOF
[Unit]
Description=Static site for Tor onion service
After=network.target

[Service]
ExecStart=/usr/bin/python3 -m http.server $LOCAL_PORT --bind 127.0.0.1 --directory $WEB_ROOT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # --- Onion-сервис ---
    grep -q "^HiddenServiceDir $HS_DIR" /etc/tor/torrc 2>/dev/null || cat >> /etc/tor/torrc <<EOF

HiddenServiceDir $HS_DIR/
HiddenServicePort 80 127.0.0.1:$LOCAL_PORT
EOF

    systemctl daemon-reload
    systemctl enable tor tor-site-web
    systemctl restart tor-site-web
    systemctl restart tor

    # Ждём генерацию onion-адреса
    ONION=""
    for _ in $(seq 1 15); do
        [[ -f "$HS_DIR/hostname" ]] && { ONION=$(cat "$HS_DIR/hostname"); break; }
        sleep 2
    done
    [[ -z "$ONION" ]] && { err "Onion-адрес не сгенерирован — проверьте: journalctl -u tor"; exit 1; }

    LINK="http://$ONION"
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
    cat > "$STATE_FILE" <<EOF
TITLE="$TITLE"
ONION="$ONION"
WEB_ROOT="$WEB_ROOT"
CLIENT_LINK="$LINK"
EOF
    chmod 600 "$STATE_FILE"

    ok "$TITLE установлен"
    echo ""
    echo "Onion-адрес (открывать в Tor Browser):"
    echo "$LINK"
    echo "Файлы сайта: $WEB_ROOT (можно заменить на свои)"
}

do_remove() {
    systemctl disable --now tor-site-web 2>/dev/null || true
    rm -f /etc/systemd/system/tor-site-web.service
    # Убираем onion-сервис из torrc
    sed -i "\|^HiddenServiceDir $HS_DIR|d; \|^HiddenServicePort 80 127.0.0.1:$LOCAL_PORT|d" /etc/tor/torrc 2>/dev/null || true
    rm -rf "$HS_DIR" "$STATE_FILE"
    systemctl daemon-reload
    systemctl restart tor 2>/dev/null || true
    ok "$TITLE удалён (Tor и файлы сайта оставлены)"
}

do_status() {
    if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE"
        if systemctl is-active --quiet tor; then STATE="работает"; else STATE="ОСТАНОВЛЕН"; fi
        echo "installed=1"
        echo "state=$STATE"
        echo "title=$TITLE"
        echo "link=$CLIENT_LINK"
        echo "web_root=$WEB_ROOT"
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
