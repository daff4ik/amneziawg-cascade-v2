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
[[ -f "$CASCADE_ENV" ]] && source "$CASCADE_ENV"

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

# === Копия на SERVER-B (по SSH-ключу, без пароля) ===
if [[ -n "$SERVER_B_IP" && -f /root/.ssh/id_ed25519 ]]; then
    SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15)
    if ssh "${SSH_OPTS[@]}" -p "$SERVER_B_PORT" "$SERVER_B_USER@$SERVER_B_IP" \
        "mkdir -p $BACKUP_DIR && chmod 700 $BACKUP_DIR" 2>/dev/null; then
        scp "${SSH_OPTS[@]}" -P "$SERVER_B_PORT" "$ARCHIVE" \
            "$SERVER_B_USER@$SERVER_B_IP:$BACKUP_DIR/" >/dev/null
        ssh "${SSH_OPTS[@]}" -p "$SERVER_B_PORT" "$SERVER_B_USER@$SERVER_B_IP" \
            "ls -1t $BACKUP_DIR/amnezia-backup-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f"
        echo "Копия отправлена на SERVER-B ($SERVER_B_IP:$BACKUP_DIR)"
    else
        echo "[WARN] SERVER-B ($SERVER_B_IP) недоступен по SSH-ключу — только локальная копия" >&2
    fi
fi
