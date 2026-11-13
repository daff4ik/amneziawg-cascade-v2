#!/bin/bash
# =====================================================================
#  amnezia-proto-mtproxy.sh
#  MTProxy для Telegram на базе mtg v2 (FakeTLS-секрет).
#  Ссылка tg://proxy — открывается прямо в Telegram; в AmneziaVPN
#  отображается как сервис MTProxy.
#
#  Команды: install | remove | status
#  Переменные окружения (опционально):
#    MTG_PORT (по умолчанию 8444), MTG_DOMAIN (маскировочный домен),
#    ENDPOINT_HOST (адрес для ссылки, иначе — внешний IP сервера)
# =====================================================================
set -euo pipefail

NAME="mtproxy"
TITLE="MTProxy (Telegram)"
STATE_DIR="/etc/amnezia-protocols"
STATE_FILE="$STATE_DIR/$NAME.conf"
MTG_BIN="/usr/local/bin/mtg"

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
    PORT="${MTG_PORT:-8444}"
    DOMAIN="${MTG_DOMAIN:-www.google.com}"

    if [[ -f "$STATE_FILE" ]]; then
        err "Уже установлен. Сначала удалите: $0 remove"; exit 1
    fi
    if ss -ltn | awk '{print $4}' | grep -qE "[:.]${PORT}\$"; then
        err "Порт $PORT занят. Выберите другой: MTG_PORT=9443 $0 install"; exit 1
    fi

    if [[ ! -x "$MTG_BIN" ]]; then
        echo "Скачивание mtg..."
        URL=$(curl -fsSL -m 15 "https://api.github.com/repos/9seconds/mtg/releases/latest" \
            | grep -oP '"browser_download_url":\s*"\K[^"]*linux-amd64\.tar\.gz' | head -1)
        [[ -z "$URL" ]] && { err "Не удалось получить ссылку на релиз mtg"; exit 1; }
        curl -fsSL -m 120 "$URL" -o /tmp/mtg.tar.gz
        tar -xzf /tmp/mtg.tar.gz -C /tmp
        MTG_EXTRACTED=$(find /tmp -maxdepth 2 -name mtg -type f | head -1)
        [[ -z "$MTG_EXTRACTED" ]] && { err "Не найден бинарник mtg в архиве"; exit 1; }
        install -m 755 "$MTG_EXTRACTED" "$MTG_BIN"
        rm -f /tmp/mtg.tar.gz; rm -rf "$(dirname "$MTG_EXTRACTED")"
    fi
    ok "mtg: $("$MTG_BIN" --version 2>&1 | head -1)"

    SECRET=$("$MTG_BIN" generate-secret --hex "$DOMAIN" 2>/dev/null || "$MTG_BIN" generate-secret "$DOMAIN")
    [[ -z "$SECRET" ]] && { err "Не удалось сгенерировать секрет"; exit 1; }
    HOST=$(endpoint_host)

    cat > /etc/systemd/system/mtg.service <<EOF
[Unit]
Description=MTProxy (mtg)
After=network.target

[Service]
ExecStart=$MTG_BIN simple-run -b 0.0.0.0:$PORT $SECRET
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable mtg
    systemctl restart mtg
    sleep 1
    systemctl is-active --quiet mtg || { err "mtg не запустился: journalctl -u mtg"; exit 1; }

    LINK="tg://proxy?server=$HOST&port=$PORT&secret=$SECRET"
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
    cat > "$STATE_FILE" <<EOF
TITLE="$TITLE"
PORT="$PORT"
DOMAIN="$DOMAIN"
HOST="$HOST"
CLIENT_LINK="$LINK"
EOF
    chmod 600 "$STATE_FILE"

    ok "$TITLE установлен (порт $PORT)"
    echo ""
    echo "Ссылка для Telegram (открыть на устройстве):"
    echo "$LINK"
    echo "https://t.me/proxy?server=$HOST&port=$PORT&secret=$SECRET"
    command -v qrencode >/dev/null 2>&1 && { echo ""; qrencode -t ansiutf8 "$LINK"; }
}

do_remove() {
    systemctl disable --now mtg 2>/dev/null || true
    rm -f /etc/systemd/system/mtg.service "$STATE_FILE"
    systemctl daemon-reload
    ok "$TITLE удалён"
}

do_status() {
    if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE"
        if systemctl is-active --quiet mtg; then STATE="работает"; else STATE="ОСТАНОВЛЕН"; fi
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
