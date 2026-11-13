#!/bin/bash
# =====================================================================
#  amnezia-backup.sh
#  Бэкап всей конфигурации каскада с SERVER-A:
#  локально в /root/amnezia-backups и (если настроен SSH-ключ) на SERVER-B.
#  Хранит последние 7 копий с каждой стороны. Запускается по cron.
# =====================================================================
set -euo pipefail

BACKUP_DIR="/root/amnezia-backups"
KEEP=7
CASCADE_ENV="/etc/amnezia-cascade.env"
AWG_DIR="/etc/amnezia/amneziawg"

[[ $EUID -ne 0 ]] && { echo "Ошибка: запускать от root (sudo $0)"; exit 1; }

SERVER_B_IP=""; SERVER_B_PORT="22"; SERVER_B_USER="root"
BACKUP_HOST=""; BACKUP_PORT="22"; BACKUP_USER="root"
[[ -f "$CASCADE_ENV" ]] && source "$CASCADE_ENV"
# Цель для копии: новые обобщённые BACKUP_* (приоритет) или старые SERVER_B_*
BK_HOST="${BACKUP_HOST:-$SERVER_B_IP}"
BK_PORT="${BACKUP_PORT:-$SERVER_B_PORT}"
BK_USER="${BACKUP_USER:-$SERVER_B_USER}"

mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
TS=$(date +%Y%m%d-%H%M%S)
ARCHIVE="$BACKUP_DIR/amnezia-backup-$TS.tar.gz"

# === Список файлов (только существующие) ===
FILES=()
for f in \
    "$AWG_DIR/awg0.conf" "$AWG_DIR/awg1.conf" \
    "$AWG_DIR/private.key" "$AWG_DIR/public.key" \
    "$AWG_DIR/awg1_private.key" "$AWG_DIR/awg1_public.key" \
    "$AWG_DIR/awg0-de.conf.copy" \
    "$CASCADE_ENV" \
    /etc/amnezia-panel.conf \
    /etc/amnezia-stealth.conf \
    /var/lib/amnezia-panel/servers.json
do
    [[ -f "$f" ]] && FILES+=("${f#/}")
done
[[ -d /root/clients ]] && FILES+=("root/clients")
[[ -d /etc/amnezia-panel-ssl ]] && FILES+=("etc/amnezia-panel-ssl")

[[ ${#FILES[@]} -eq 0 ]] && { echo "Ошибка: нечего бэкапить"; exit 1; }

tar -czf "$ARCHIVE" -C / "${FILES[@]}"
chmod 600 "$ARCHIVE"
echo "Локальный бэкап: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"

# === Ротация локальных копий ===
ls -1t "$BACKUP_DIR"/amnezia-backup-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f

# === Копия на удалённый сервер (по SSH-ключу, без пароля) ===
if [[ -n "$BK_HOST" && -f /root/.ssh/id_ed25519 ]]; then
    SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15)
    if ssh "${SSH_OPTS[@]}" -p "$BK_PORT" "$BK_USER@$BK_HOST" \
        "mkdir -p $BACKUP_DIR && chmod 700 $BACKUP_DIR" 2>/dev/null; then
        scp "${SSH_OPTS[@]}" -P "$BK_PORT" "$ARCHIVE" \
            "$BK_USER@$BK_HOST:$BACKUP_DIR/" >/dev/null
        ssh "${SSH_OPTS[@]}" -p "$BK_PORT" "$BK_USER@$BK_HOST" \
            "ls -1t $BACKUP_DIR/amnezia-backup-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f"
        echo "Копия отправлена на $BK_HOST:$BACKUP_DIR"
    else
        echo "[WARN] $BK_HOST недоступен по SSH-ключу — только локальная копия" >&2
    fi
fi
