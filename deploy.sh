#!/bin/bash
# =====================================================================
#  AmneziaWG Cascade Deploy by David (daff4ik)
#  Запускать на SERVER-A (входном) от root.
#
#  Использование:
#    ./deploy.sh              # полная установка
#    ./deploy.sh --update     # обновить скрипты/панель без трогания конфигов и SERVER-B
#    ./deploy.sh --restore    # восстановить SERVER-A из бэкапа, лежащего на SERVER-B
# =====================================================================
set -euo pipefail

# ==================== Парсинг аргументов ====================
UPDATE_MODE=0
RESTORE_MODE=0
for arg in "$@"; do
    case "$arg" in
        --update) UPDATE_MODE=1 ;;
        --restore) RESTORE_MODE=1 ;;
        --help|-h)
            echo "Использование:"
            echo "  $0              # полная установка"
            echo "  $0 --update     # обновить скрипты и панель (только SERVER-A)"
            echo "  $0 --restore    # восстановить SERVER-A из бэкапа на SERVER-B"
            exit 0
            ;;
    esac
done

# ==================== Константы ====================
REPO_URL="https://raw.githubusercontent.com/daff4ik/amneziawg-cascade-v2/v3"

# Режим установки: 1 = только SERVER-A, 2 = только SERVER-B (панель на A), 3 = каскад A+B
INSTALL_MODE=3

AWG_DIR="/etc/amnezia/amneziawg"
AWG_TUNNEL_PORT="8443"
AWG_CLIENT_PORT="585"
TUNNEL_A_IP="10.10.10.2"
TUNNEL_B_IP="10.10.10.1"
CLIENT_SUBNET="10.8.0"
CLIENT_SERVER_IP="10.8.0.1"
MTU_AWG0="1180"
MTU_AWG1="1100"
MSS_CLAMP="1000"
CLIENT_MTU="1280"
CLIENT_DNS="1.1.1.1, 1.0.0.1"

# IPv6 (ULA-адресация внутри туннеля, в интернет — NAT66 на SERVER-B)
TUNNEL_A_IP6="fd00:10:10:10::2"
TUNNEL_B_IP6="fd00:10:10:10::1"
CLIENT_SUBNET6="fd00:10:8"
CLIENT_DNS6="2606:4700:4700::1111, 2606:4700:4700::1001"
IPV6_ENABLED=0

CASCADE_ENV="/etc/amnezia-cascade.env"

# ==================== Хелперы ====================
say()  { echo -e "\n\033[1;36m=== $* ===\033[0m"; }
ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }
sed_escape() { printf '%s' "$1" | sed -e 's/[\/&|]/\\&/g'; }

write_cascade_env() {
    cat > "$CASCADE_ENV" <<EOF
# AmneziaWG Cascade — общие константы.
# Пишет deploy.sh, читают helper-скрипты и веб-панель.
INSTALL_MODE="$INSTALL_MODE"
AWG_TUNNEL_PORT="$AWG_TUNNEL_PORT"
AWG_CLIENT_PORT="$AWG_CLIENT_PORT"
TUNNEL_A_IP="$TUNNEL_A_IP"
TUNNEL_B_IP="$TUNNEL_B_IP"
CLIENT_SUBNET="$CLIENT_SUBNET"
CLIENT_SERVER_IP="$CLIENT_SERVER_IP"
MTU_AWG0="$MTU_AWG0"
MTU_AWG1="$MTU_AWG1"
MSS_CLAMP="$MSS_CLAMP"
CLIENT_MTU="$CLIENT_MTU"
CLIENT_DNS="$CLIENT_DNS"
ENDPOINT_HOST="$ENDPOINT_HOST"
SERVER_NAME="$SERVER_NAME"
SERVER_B_IP="${SERVER_B_IP:-${DE_IP:-}}"
SERVER_B_PORT="${SERVER_B_PORT:-${DE_SSH_PORT:-22}}"
SERVER_B_USER="${SERVER_B_USER:-${DE_SSH_USER:-root}}"
SERVER_B_IFACE="${SERVER_B_IFACE:-${DE_IFACE:-}}"
BACKUP_HOST="${BACKUP_HOST:-}"
BACKUP_PORT="${BACKUP_PORT:-22}"
BACKUP_USER="${BACKUP_USER:-root}"
IPV6_ENABLED="$IPV6_ENABLED"
TUNNEL_A_IP6="$TUNNEL_A_IP6"
TUNNEL_B_IP6="$TUNNEL_B_IP6"
CLIENT_SUBNET6="$CLIENT_SUBNET6"
CLIENT_DNS6="$CLIENT_DNS6"
EOF
    chmod 600 "$CASCADE_ENV"
}

# =====================================================================
#  Интерактивный ввод
# =====================================================================
say "Ввод параметров"

if [[ $UPDATE_MODE -eq 1 ]]; then
    if [[ ! -f "$AWG_DIR/awg0.conf" ]]; then
        err "Нет $AWG_DIR/awg0.conf — нечего обновлять. Запустите полную установку."
        exit 1
    fi
    say "Режим обновления: SERVER-B не затрагивается"

    RU_IP=$(hostname -I | awk '{print $1}')
    [[ -z "$RU_IP" ]] && { err "Не удалось определить IP этого сервера"; exit 1; }

    # Подхватываем константы существующей установки
    [[ -f "$CASCADE_ENV" ]] && source "$CASCADE_ENV"

    read -p "Домен для Endpoint в клиентских конфигах [${ENDPOINT_HOST:-$RU_IP}]: " EH_INPUT
    ENDPOINT_HOST="${EH_INPUT:-${ENDPOINT_HOST:-$RU_IP}}"
    ENDPOINT_HOST=$(echo "$ENDPOINT_HOST" | sed 's/[^a-zA-Z0-9.-]//g')
    [[ -z "$ENDPOINT_HOST" ]] && ENDPOINT_HOST="$RU_IP"

    OLD_SERVER_NAME=""
    if [[ -f /usr/local/bin/amnezia-add-client.sh ]]; then
        OLD_SERVER_NAME=$(grep -oP '^SERVER_NAME="\K[^"]+' /usr/local/bin/amnezia-add-client.sh | head -1 || echo "")
    fi
    if [[ ( -z "$OLD_SERVER_NAME" || "$OLD_SERVER_NAME" == "__SERVER_NAME__" ) && -f /opt/amnezia-panel.py ]]; then
        OLD_SERVER_NAME=$(grep -oP 'SERVER_LABEL\s*=\s*"\K[^"]+' /opt/amnezia-panel.py | head -1 || echo "")
    fi

    if [[ -n "$OLD_SERVER_NAME" && "$OLD_SERVER_NAME" != "__SERVER_LABEL__" && "$OLD_SERVER_NAME" != "__SERVER_NAME__" ]]; then
        echo "Текущее имя сервера: [$OLD_SERVER_NAME]"
        read -p "Сохранить текущее имя сервера? (y/n) [y]: " KEEP_NAME
        KEEP_NAME="${KEEP_NAME:-y}"
        if [[ "$KEEP_NAME" =~ ^[yYдД] ]]; then
            SERVER_NAME="$OLD_SERVER_NAME"
        else
            read -p "Введите новое имя сервера: " SERVER_NAME
        fi
    else
        read -p "Название сервера для AmneziaVPN (например, 'MyVPN'): " SERVER_NAME
    fi
    SERVER_NAME="${SERVER_NAME:-AmneziaVPN}"

    if [[ -f /etc/amnezia-panel.conf ]]; then
        read -p "Веб-панель уже установлена. Обновить её? (y/n) [y]: " INSTALL_PANEL
    else
        read -p "Установить веб-панель? (y/n) [y]: " INSTALL_PANEL
    fi
    INSTALL_PANEL="${INSTALL_PANEL:-y}"

    read -p "Настроить/перенастроить Stealth-режим (Nginx-заглушка)? (y/n) [n]: " SETUP_STEALTH
    SETUP_STEALTH="${SETUP_STEALTH:-n}"

    read -p "Установить/обновить Fail2Ban (защита от брутфорса)? (y/n) [y]: " INSTALL_F2B
    INSTALL_F2B="${INSTALL_F2B:-y}"

    ok "Параметры для обновления получены"
else
    # --- Полная установка ---
    if [[ $RESTORE_MODE -eq 1 ]]; then
        say "Режим восстановления SERVER-A из бэкапа на SERVER-B"
        read -p "IP-адрес SERVER-B (там лежит бэкап): " DE_IP
        [[ -z "$DE_IP" ]] && { err "IP обязателен"; exit 1; }

        read -p "SSH-порт SERVER-B [22]: " DE_SSH_PORT
        DE_SSH_PORT="${DE_SSH_PORT:-22}"

        read -p "SSH-пользователь SERVER-B [root]: " DE_SSH_USER
        DE_SSH_USER="${DE_SSH_USER:-root}"

        read -r -s -p "SSH-пароль SERVER-B: " DE_PASS; echo
        [[ -z "$DE_PASS" ]] && { err "Пароль обязателен"; exit 1; }

        command -v sshpass >/dev/null || { apt update -qq < /dev/null && apt install -y -qq sshpass < /dev/null; }
        export SSHPASS="$DE_PASS"

        say "Скачивание последнего бэкапа с SERVER-B"
        BK_FILE=$(sshpass -e ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=15 -p "$DE_SSH_PORT" "$DE_SSH_USER@$DE_IP" \
            "ls -1t /root/amnezia-backups/amnezia-backup-*.tar.gz 2>/dev/null | head -1" | tr -d '\r')
        [[ -z "$BK_FILE" ]] && { err "На SERVER-B нет бэкапов (/root/amnezia-backups/)"; exit 1; }
        sshpass -e scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -P "$DE_SSH_PORT" "$DE_SSH_USER@$DE_IP:$BK_FILE" /tmp/amnezia-restore.tar.gz
        tar -xzf /tmp/amnezia-restore.tar.gz -C /
        rm -f /tmp/amnezia-restore.tar.gz
        ok "Бэкап распакован: $BK_FILE"

        [[ -f "$CASCADE_ENV" ]] || { err "В бэкапе нет $CASCADE_ENV"; exit 1; }
        source "$CASCADE_ENV"
        [[ "${INSTALL_MODE:-3}" == "3" ]] || { err "--restore в v3 поддерживается только для каскадного режима (INSTALL_MODE=3)"; exit 1; }

        RU_IP=$(hostname -I | awk '{print $1}')
        read -p "IP-адрес этого сервера (новый SERVER-A) [$RU_IP]: " RU_IP_INPUT
        RU_IP="${RU_IP_INPUT:-$RU_IP}"
        [[ -z "$RU_IP" ]] && { err "Не удалось определить IP этого сервера"; exit 1; }

        # Если Endpoint был IP старого сервера A — переключаем на новый IP; домен не трогаем
        if [[ "$ENDPOINT_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            ENDPOINT_HOST="$RU_IP"
        fi

        INSTALL_PANEL=n
        [[ -f /etc/amnezia-panel.conf ]] && INSTALL_PANEL=y
        INSTALL_F2B=y
        ok "Параметры из бэкапа: сервер '$SERVER_NAME', endpoint $ENDPOINT_HOST, IPv6 $([[ "$IPV6_ENABLED" == "1" ]] && echo вкл || echo выкл)"
    else
    echo "Режимы установки:"
    echo "  1) Только SERVER-A      — протоколы и веб-панель на этом сервере"
    echo "  2) Только SERVER-B      — протоколы на втором сервере, веб-панель и управление здесь (на A)"
    echo "  3) Каскад A+B           — клиенты → SERVER-A → SERVER-B, веб-панель на A (максимальная скрытность B)"
    read -p "Ваш выбор [3]: " INSTALL_MODE
    INSTALL_MODE="${INSTALL_MODE:-3}"
    [[ "$INSTALL_MODE" =~ ^[123]$ ]] || { err "Неверный режим: $INSTALL_MODE"; exit 1; }

    read -p "IP-адрес этого сервера (SERVER-A): " RU_IP
    [[ -z "$RU_IP" ]] && { err "IP обязателен"; exit 1; }

    if [[ "$INSTALL_MODE" != "1" ]]; then
    read -p "IP-адрес второго сервера (SERVER-B): " DE_IP
    [[ -z "$DE_IP" ]] && { err "IP обязателен"; exit 1; }

    read -p "SSH-порт SERVER-B [22]: " DE_SSH_PORT
    DE_SSH_PORT="${DE_SSH_PORT:-22}"

    read -p "SSH-пользователь SERVER-B [root]: " DE_SSH_USER
    DE_SSH_USER="${DE_SSH_USER:-root}"

    read -r -s -p "SSH-пароль SERVER-B: " DE_PASS; echo
    [[ -z "$DE_PASS" ]] && { err "Пароль обязателен"; exit 1; }
    fi

    # Endpoint — адрес, к которому подключаются клиенты:
    # режим 2 — напрямую к SERVER-B, режимы 1/3 — к SERVER-A
    if [[ "$INSTALL_MODE" == "2" ]]; then EP_DEFAULT="$DE_IP"; else EP_DEFAULT="$RU_IP"; fi
    read -p "Домен для Endpoint в клиентских конфигах (Enter = использовать IP $EP_DEFAULT): " ENDPOINT_HOST
    ENDPOINT_HOST="${ENDPOINT_HOST:-$EP_DEFAULT}"
    ENDPOINT_HOST=$(echo "$ENDPOINT_HOST" | sed 's/[^a-zA-Z0-9.-]//g')
    [[ -z "$ENDPOINT_HOST" ]] && ENDPOINT_HOST="$EP_DEFAULT"

    read -p "Название сервера для AmneziaVPN (например, 'MyVPN'): " SERVER_NAME
    SERVER_NAME="${SERVER_NAME:-AmneziaVPN}"

    read -p "Установить веб-панель на SERVER-A? (y/n) [y]: " INSTALL_PANEL
    INSTALL_PANEL="${INSTALL_PANEL:-y}"

    if [[ "$INSTALL_MODE" == "1" ]]; then
        read -p "Установить Fail2Ban (защита от брутфорса)? (y/n) [y]: " INSTALL_F2B
    else
        read -p "Установить Fail2Ban на оба сервера (защита от брутфорса)? (y/n) [y]: " INSTALL_F2B
    fi
    INSTALL_F2B="${INSTALL_F2B:-y}"

    # Stealth сразу при установке: если Endpoint — домен, прячем панель за него.
    # В режиме 2 домен указывает на SERVER-B, а панель на A — stealth настраивается
    # позже отдельным доменом (deploy --update).
    SETUP_STEALTH=n
    STEALTH_SECRET=""
    if [[ "$INSTALL_MODE" != "2" && ! "$ENDPOINT_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$INSTALL_PANEL" =~ ^[yYдД] ]]; then
        echo ""
        echo "Убедитесь, что A-запись домена $ENDPOINT_HOST уже указывает на $RU_IP — иначе SSL не выпустится."
        read -p "Спрятать веб-панель за доменом $ENDPOINT_HOST сразу (stealth-режим)? (y/n) [y]: " SETUP_STEALTH
        SETUP_STEALTH="${SETUP_STEALTH:-y}"
        if [[ "$SETUP_STEALTH" =~ ^[yYдД] ]]; then
            read -p "Кодовое слово для скрытого пути панели (латиница/цифры, без слэшей): " STEALTH_SECRET
            STEALTH_SECRET=$(echo "$STEALTH_SECRET" | tr -d '/' | sed 's/[^a-zA-Z0-9_-]//g')
            if [[ -z "$STEALTH_SECRET" ]]; then
                warn "Кодовое слово пустое — stealth пропускаю (можно настроить позже через --update)"
                SETUP_STEALTH=n
            fi
        fi
    fi
    fi
fi

# =====================================================================
#  Проверки окружения
# =====================================================================
say "Проверка окружения"
[[ $EUID -ne 0 ]] && { err "Запускать от root"; exit 1; }
command -v apt >/dev/null || { err "Нужен Ubuntu/Debian"; exit 1; }
command -v curl >/dev/null || { apt update -qq < /dev/null && apt install -y -qq curl < /dev/null; }
command -v python3 >/dev/null || { err "Нужен python3"; exit 1; }

HOST_IPS=$(hostname -I || true)
if [[ "$HOST_IPS" != *"$RU_IP"* ]]; then
    warn "IP $RU_IP не найден среди адресов этого сервера ($HOST_IPS)"
    read -p "Продолжить? (y/n): " ans
    [[ "$ans" =~ ^[yYдД] ]] || exit 1
fi

# =====================================================================
#  Скачивание helper-скриптов
# =====================================================================
say "Скачивание helper-скриптов из репозитория"

SCRIPTS_TO_DOWNLOAD=(
    amnezia-add-client.sh
    amnezia-remove-client.sh
    amnezia-list-clients.sh
    amnezia-notify.sh
    amnezia-notify-setup.sh
    amnezia-healthcheck.sh
    amnezia-traffic-collector.py
    amnezia-panel-access.sh
    amnezia-server-install.sh
    amnezia-backup.sh
    amnezia-restore-b.sh
)

MIRRORS=(
    "https://raw.githubusercontent.com/daff4ik/amneziawg-cascade-v2/v3"
    "https://ghproxy.net/https://raw.githubusercontent.com/daff4ik/amneziawg-cascade-v2/v3"
    "https://mirror.ghproxy.com/https://raw.githubusercontent.com/daff4ik/amneziawg-cascade-v2/v3"
)

# Запоминаем первое рабочее зеркало, чтобы не перебирать все для каждого файла
WORKING_MIRROR=""

download_url() {
    # download_url <url-путь-относительно-репо> <куда>
    local rel=$1 dest_path=$2 success=0
    local mirrors=()
    [[ -n "$WORKING_MIRROR" ]] && mirrors+=("$WORKING_MIRROR")
    for m in "${MIRRORS[@]}"; do
        [[ "$m" != "$WORKING_MIRROR" ]] && mirrors+=("$m")
    done
    echo "  ↓ $(basename "$rel")"
    for mirror in "${mirrors[@]}"; do
        if curl -fsSL --connect-timeout 5 --max-time 15 "$mirror/$rel" -o "$dest_path"; then
            WORKING_MIRROR="$mirror"
            success=1
            break
        fi
    done
    if [[ $success -eq 0 ]]; then
        warn "Не удалось скачать $rel ни с одного зеркала — пропускаю"
        rm -f "$dest_path"
    fi
}

for f in "${SCRIPTS_TO_DOWNLOAD[@]}"; do
    download_url "scripts/$f" "/tmp/$f"
    [[ -f "/tmp/$f" ]] && chmod +x "/tmp/$f"
done

# Дополнительные протоколы/сервисы (управляются из веб-панели)
PROTOCOLS=(xray-vless mtproxy tor-site)
for p in "${PROTOCOLS[@]}"; do
    download_url "protocols/$p.sh" "/tmp/proto-$p.sh"
    [[ -f "/tmp/proto-$p.sh" ]] && chmod +x "/tmp/proto-$p.sh"
done

[[ -f /tmp/amnezia-server-install.sh ]] || { err "Не скачан amnezia-server-install.sh — без него установка невозможна"; exit 1; }
ok "Скрипты скачаны"

# Флаги для amnezia-server-install.sh
INSTALL_FLAGS=()
[[ "$INSTALL_F2B" =~ ^[yYдД] ]] && INSTALL_FLAGS+=(--fail2ban)

# =====================================================================
#  Полная установка: SSH до SERVER-B, IPv6, туннели
# =====================================================================
if [[ $UPDATE_MODE -eq 0 ]]; then
    if [[ "$INSTALL_MODE" != "1" ]]; then
    say "Установка sshpass и проверка SSH до SERVER-B"
    command -v sshpass >/dev/null || { apt update -qq < /dev/null && apt install -y -qq sshpass < /dev/null; }
    export SSHPASS="$DE_PASS"

    run_de() {
        # -n: stdin ssh отключён, чтобы не «съедать» ответы при запуске через pipe
        sshpass -e ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=15 \
            -p "$DE_SSH_PORT" "$DE_SSH_USER@$DE_IP" "$@"
    }
    scp_de() {
        sshpass -e scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -P "$DE_SSH_PORT" "$1" "$DE_SSH_USER@$DE_IP:$2"
    }

    run_de "echo SSH_OK" | grep -q SSH_OK || { err "SSH до $DE_IP не работает"; exit 1; }
    ok "SSH работает"
    fi

    # --- Определение доступности IPv6 на выходном узле ---
    # Режим 1: выходной узел — A. Режимы 2/3: выходной узел — B.
    if [[ $RESTORE_MODE -eq 1 ]]; then
        # Восстановление: параметры берём из бэкапа, SERVER-B не трогаем
        [[ "$IPV6_ENABLED" == "1" ]] && IPV6_ENABLED=1 || IPV6_ENABLED=0
        [[ $IPV6_ENABLED -eq 1 ]] && INSTALL_FLAGS+=(--ipv6)
    else
    if [[ "$INSTALL_MODE" == "1" ]]; then
        EXITNODE_DESC="SERVER-A"
        exitnode_has_v6() { ip -6 route show default 2>/dev/null | grep -q '^default'; }
    else
        EXITNODE_DESC="SERVER-B"
        exitnode_has_v6() { run_de "ip -6 route show default 2>/dev/null | grep -q '^default'"; }
    fi
    say "Проверка IPv6 на $EXITNODE_DESC"
    if exitnode_has_v6; then
        read -p "На $EXITNODE_DESC есть выход в IPv6. Включить IPv6? (y/n) [y]: " V6_ANS
        V6_ANS="${V6_ANS:-y}"
        [[ "$V6_ANS" =~ ^[yYдД] ]] && IPV6_ENABLED=1
    else
        echo "IPv6 на $EXITNODE_DESC не обнаружен — будет только IPv4."
    fi
    [[ $IPV6_ENABLED -eq 1 ]] && INSTALL_FLAGS+=(--ipv6) && ok "IPv6 включён"
    fi

    # --- Установка AmneziaWG (единый скрипт) ---
    if [[ "$INSTALL_MODE" != "2" ]]; then
    say "Установка AmneziaWG на SERVER-A"
    # </dev/null: apt/debconf внутри не должен вычитывать ответы из stdin установщика
    bash /tmp/amnezia-server-install.sh "${INSTALL_FLAGS[@]}" < /dev/null
    ok "AmneziaWG на SERVER-A готов"
    fi

    if [[ $RESTORE_MODE -eq 0 && "$INSTALL_MODE" != "1" ]]; then
    say "Установка AmneziaWG на SERVER-B ($DE_IP)"
    scp_de /tmp/amnezia-server-install.sh /tmp/amnezia-server-install.sh
    run_de "bash /tmp/amnezia-server-install.sh ${INSTALL_FLAGS[*]}; rm -f /tmp/amnezia-server-install.sh"
    ok "AmneziaWG на SERVER-B готов"
    fi

    # --- Префлайт: реально ли работает IPv6 на awg-интерфейсе ---
    # ВАЖНО: IPv6 требует MTU >= 1280 на интерфейсе (RFC 8200). При MTU 1180
    # ядро ломает v6-стек интерфейса (route add → RTNETLINK No such device),
    # поэтому проверка идёт с боевым MTU, а при включённом v6 MTU поднимаем до 1280.
    if [[ $IPV6_ENABLED -eq 1 && $RESTORE_MODE -eq 0 ]]; then
        say "Проверка поддержки IPv6 модулем AmneziaWG"
        V6_CHECK='ip link add _v6chk type amneziawg 2>/dev/null && ip -6 addr add fd00::1/128 dev _v6chk 2>/dev/null && ip link set mtu 1280 up dev _v6chk 2>/dev/null && ip -6 route add fd00::2/128 dev _v6chk 2>/dev/null && ip -6 addr show dev _v6chk 2>/dev/null | grep -q "fd00::1"'
        V6_OK=1
        [[ "$INSTALL_MODE" != "2" ]] && { bash -c "$V6_CHECK; r=\$?; ip link del _v6chk 2>/dev/null; exit \$r" || V6_OK=0; }
        [[ "$INSTALL_MODE" != "1" ]] && { run_de "$V6_CHECK; r=\$?; ip link del _v6chk 2>/dev/null; exit \$r" || V6_OK=0; }
        if [[ $V6_OK -eq 0 ]]; then
            warn "Модуль AmneziaWG не поддерживает IPv6 на нужном сервере"
            warn "— продолжаю без IPv6 (клиенты останутся на IPv4, NAT44)."
            IPV6_ENABLED=0
        else
            ok "IPv6 поддерживается"
            # Минимальный MTU для IPv6 — 1280 (RFC 8200)
            MTU_AWG0=1280
            MTU_AWG1=1280
            MSS_CLAMP=1220
        fi
    fi

    # --- Общий файл констант для скриптов и панели ---
    [[ "$INSTALL_MODE" == "3" ]] && BACKUP_HOST="$DE_IP"
    write_cascade_env

    say "Генерация параметров обфускации"
    if [[ $RESTORE_MODE -eq 1 ]]; then
        ok "Пропускаю: конфиги и ключи восстановлены из бэкапа"
    else
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
    gen_s_pair() {
        while :; do
            local a=$((RANDOM % 50 + 12))
            local b=$((RANDOM % 50 + 12))
            [[ $((a + 56)) -ne $b ]] && { echo "$a $b"; return; }
        done
    }
    # Печатает набор параметров обфускации в формате key=value
    gen_obf() {
        local jmin=$((RANDOM % 40 + 10))
        local s1 s2 h1 h2 h3 h4
        read s1 s2 <<< "$(gen_s_pair)"
        read h1 h2 h3 h4 <<< "$(gen_ranges)"
        cat <<EOF
HPK=$(awg genkey)
JC=$((RANDOM % 6 + 3))
JMIN=$jmin
JMAX=$((jmin + RANDOM % 40 + 20))
S1=$s1
S2=$s2
S3=$((RANDOM % 50 + 12))
S4=$((RANDOM % 50 + 12))
H1=$h1
H2=$h2
H3=$h3
H4=$h4
EOF
    }

    eval "$(gen_obf)"                 # параметры awg0 (туннель A<->B, режим 3)
    eval "$(gen_obf | sed 's/^/C_/')" # параметры awg1 (клиенты), префикс C_
    ok "Параметры сгенерированы"

    say "Генерация ключей"
    # Ключи awg0 живут там, где поднимается туннель (режим 3 — оба сервера)
    if [[ "$INSTALL_MODE" != "2" ]]; then
        mkdir -p "$AWG_DIR" && chmod 700 "$AWG_DIR"
        cd "$AWG_DIR"
        if [[ ! -f private.key ]]; then
            umask 077
            awg genkey > private.key
            awg pubkey < private.key > public.key
            chmod 600 private.key
            chmod 644 public.key
        fi
        RU_PRIV=$(cat private.key)
        RU_PUB=$(cat public.key)
    fi

    if [[ "$INSTALL_MODE" != "1" ]]; then
    run_de "mkdir -p $AWG_DIR && chmod 700 $AWG_DIR && cd $AWG_DIR && \
        if [ ! -f private.key ]; then umask 077; awg genkey > private.key; awg pubkey < private.key > public.key; chmod 600 private.key; chmod 644 public.key; fi"
    DE_PRIV=$(run_de "cat $AWG_DIR/private.key")
    DE_PUB=$(run_de "cat $AWG_DIR/public.key")

    DE_IFACE=$(run_de "ip route get 8.8.8.8 | awk '{print \$5}' | head -1")
    [[ -z "$DE_IFACE" ]] && { err "Не удалось определить внешний интерфейс SERVER-B"; exit 1; }
    ok "Внешний интерфейс SERVER-B: $DE_IFACE"
    fi

    if [[ "$INSTALL_MODE" == "1" ]]; then
        RU_IFACE=$(ip route get 8.8.8.8 | awk '{print $5}' | head -1)
        [[ -z "$RU_IFACE" ]] && { err "Не удалось определить внешний интерфейс SERVER-A"; exit 1; }
        ok "Внешний интерфейс SERVER-A: $RU_IFACE"
    fi

    # --- IPv6-фрагменты конфигов (пустые, если v6 выключен) ---
    A_V6_ADDR=""; A_V6_POSTUP=""; A_V6_POSTDOWN=""; A_V6_ALLOWED=""
    B_V6_ADDR=""; B_V6_POSTUP=""; B_V6_POSTDOWN=""; B_V6_ALLOWED=""
    AWG1_V6_ADDR=""
    MSS6_RULE_A=""; MSS6_RULE_B=""
    if [[ $IPV6_ENABLED -eq 1 ]]; then
        A_V6_ADDR="Address = ${TUNNEL_A_IP6}/128"
        A_V6_ALLOWED=", ::/0"
        A_V6_POSTUP="PostUp = ip -6 route add ${TUNNEL_B_IP6}/128 dev awg0
PostUp = ip -6 route add default dev awg0 table 100
PostUp = ip -6 rule add from ${CLIENT_SUBNET6}::/64 lookup 100
PostUp = ip6tables -A FORWARD -i awg1 -o awg0 -j ACCEPT
PostUp = ip6tables -A FORWARD -i awg0 -o awg1 -j ACCEPT
PostUp = ip6tables -t nat -A POSTROUTING -o awg0 -j MASQUERADE
PostUp = while ip6tables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_CLAMP 2>/dev/null; do :; done
PostUp = ip6tables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_CLAMP"
        A_V6_POSTDOWN="PostDown = ip -6 rule del from ${CLIENT_SUBNET6}::/64 lookup 100
PostDown = ip -6 route del default dev awg0 table 100
PostDown = ip -6 route del ${TUNNEL_B_IP6}/128 dev awg0
PostDown = ip6tables -D FORWARD -i awg1 -o awg0 -j ACCEPT
PostDown = ip6tables -D FORWARD -i awg0 -o awg1 -j ACCEPT
PostDown = ip6tables -t nat -D POSTROUTING -o awg0 -j MASQUERADE
PostDown = ip6tables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_CLAMP 2>/dev/null || true"
        B_V6_ADDR="Address = ${TUNNEL_B_IP6}/128"
        B_V6_ALLOWED=", ${TUNNEL_A_IP6}/128"
        B_V6_POSTUP="PostUp = ip6tables -A FORWARD -i awg0 -j ACCEPT
PostUp = ip6tables -A FORWARD -o awg0 -j ACCEPT
PostUp = ip6tables -t nat -A POSTROUTING -o $DE_IFACE -j MASQUERADE
PostUp = while ip6tables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_CLAMP 2>/dev/null; do :; done
PostUp = ip6tables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_CLAMP"
        B_V6_POSTDOWN="PostDown = ip6tables -D FORWARD -i awg0 -j ACCEPT
PostDown = ip6tables -D FORWARD -o awg0 -j ACCEPT
PostDown = ip6tables -t nat -D POSTROUTING -o $DE_IFACE -j MASQUERADE
PostDown = ip6tables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_CLAMP 2>/dev/null || true"
        AWG1_V6_ADDR="Address = ${CLIENT_SUBNET6}::1/64"
    fi

    # --- Правила прямого выхода в интернет (режимы 1 и 2: без туннеля) ---
    AWG1_DIRECT_UP=""
    AWG1_DIRECT_DOWN=""
    if [[ "$INSTALL_MODE" != "3" ]]; then
        if [[ "$INSTALL_MODE" == "1" ]]; then EXIT_IFACE="$RU_IFACE"; else EXIT_IFACE="$DE_IFACE"; fi
        AWG1_DIRECT_UP="PostUp = iptables -A FORWARD -i awg1 -j ACCEPT
PostUp = iptables -A FORWARD -o awg1 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o $EXIT_IFACE -j MASQUERADE
PostUp = while iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_CLAMP 2>/dev/null; do :; done
PostUp = iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_CLAMP"
        AWG1_DIRECT_DOWN="PostDown = iptables -D FORWARD -i awg1 -j ACCEPT
PostDown = iptables -D FORWARD -o awg1 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o $EXIT_IFACE -j MASQUERADE
PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_CLAMP 2>/dev/null || true"
        if [[ $IPV6_ENABLED -eq 1 ]]; then
            AWG1_DIRECT_UP="$AWG1_DIRECT_UP
PostUp = ip6tables -A FORWARD -i awg1 -j ACCEPT
PostUp = ip6tables -A FORWARD -o awg1 -j ACCEPT
PostUp = ip6tables -t nat -A POSTROUTING -o $EXIT_IFACE -j MASQUERADE
PostUp = ip6tables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_CLAMP"
            AWG1_DIRECT_DOWN="$AWG1_DIRECT_DOWN
PostDown = ip6tables -D FORWARD -i awg1 -j ACCEPT
PostDown = ip6tables -D FORWARD -o awg1 -j ACCEPT
PostDown = ip6tables -t nat -D POSTROUTING -o $EXIT_IFACE -j MASQUERADE
PostDown = ip6tables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_CLAMP 2>/dev/null || true"
        fi
    fi

    if [[ "$INSTALL_MODE" == "3" ]]; then
    say "Настройка туннеля awg0"
    cat > "$AWG_DIR/awg0.conf" <<EOF
[Interface]
PrivateKey = $RU_PRIV
Address = $TUNNEL_A_IP/32
$A_V6_ADDR
ListenPort = $AWG_TUNNEL_PORT
MTU = $MTU_AWG0
Table = off
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
S3 = $S3
S4 = $S4
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
RandomTrailers = off
DisableCookies = on
PostUp = ip route add $TUNNEL_B_IP/32 dev awg0
PostUp = ip route add default dev awg0 table 100
PostUp = ip rule add from $CLIENT_SUBNET.0/24 lookup 100
PostUp = iptables -A FORWARD -i awg1 -o awg0 -j ACCEPT
PostUp = iptables -A FORWARD -i awg0 -o awg1 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o awg0 -j MASQUERADE
PostUp = while iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_CLAMP 2>/dev/null; do :; done
PostUp = iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_CLAMP
$A_V6_POSTUP
PostDown = ip rule del from $CLIENT_SUBNET.0/24 lookup 100
PostDown = ip route del default dev awg0 table 100
PostDown = ip route del $TUNNEL_B_IP/32 dev awg0
PostDown = iptables -D FORWARD -i awg1 -o awg0 -j ACCEPT
PostDown = iptables -D FORWARD -i awg0 -o awg1 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o awg0 -j MASQUERADE
PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_CLAMP 2>/dev/null || true
$A_V6_POSTDOWN

[Peer]
PublicKey = $DE_PUB
Endpoint = $DE_IP:$AWG_TUNNEL_PORT
AllowedIPs = 0.0.0.0/0$A_V6_ALLOWED
PersistentKeepalive = 25
EOF
    chmod 600 "$AWG_DIR/awg0.conf"

    cat > /tmp/awg0-de.conf <<EOF
[Interface]
PrivateKey = $DE_PRIV
Address = $TUNNEL_B_IP/32
$B_V6_ADDR
ListenPort = $AWG_TUNNEL_PORT
MTU = $MTU_AWG0
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
S3 = $S3
S4 = $S4
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
RandomTrailers = off
DisableCookies = on
PostUp = iptables -A FORWARD -i awg0 -j ACCEPT
PostUp = iptables -A FORWARD -o awg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o $DE_IFACE -j MASQUERADE
PostUp = while iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_CLAMP 2>/dev/null; do :; done
PostUp = iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_CLAMP
$B_V6_POSTUP
PostDown = iptables -D FORWARD -i awg0 -j ACCEPT
PostDown = iptables -D FORWARD -o awg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o $DE_IFACE -j MASQUERADE
PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_CLAMP 2>/dev/null || true
$B_V6_POSTDOWN

[Peer]
PublicKey = $RU_PUB
AllowedIPs = $TUNNEL_A_IP/32$B_V6_ALLOWED
EOF

    scp_de /tmp/awg0-de.conf "$AWG_DIR/awg0.conf"
    run_de "chmod 600 $AWG_DIR/awg0.conf"
    # Копия конфига SERVER-B для amnezia-restore-b.sh и бэкапа
    cp /tmp/awg0-de.conf "$AWG_DIR/awg0-de.conf.copy"
    chmod 600 "$AWG_DIR/awg0-de.conf.copy"
    rm -f /tmp/awg0-de.conf
    ok "Конфиги awg0 записаны"
    write_cascade_env   # теперь известен и DE_IFACE — сохраняем полный набор
    fi

    say "Запуск межсерверного туннеля"
    if [[ $RESTORE_MODE -eq 0 ]]; then
        run_de "systemctl enable awg-quick@awg0 && systemctl restart awg-quick@awg0"
        sleep 2
    fi
    systemctl enable awg-quick@awg0
    systemctl restart awg-quick@awg0
    sleep 3

    TUN_OK=1
    ping -c 3 -W 3 "$TUNNEL_B_IP" >/dev/null 2>&1 || TUN_OK=0
    if [[ $IPV6_ENABLED -eq 1 ]]; then
        ping -6 -c 3 -W 3 "$TUNNEL_B_IP6" >/dev/null 2>&1 || TUN_OK=0
    fi
    if [[ $TUN_OK -eq 1 ]]; then
        ok "Туннель awg0 работает"
    else
        err "Пинг до SERVER-B через туннель не идёт"
        exit 1
    fi
    fi   # конец блока режима 3 (туннель awg0)

    say "Настройка клиентского интерфейса awg1"
    if [[ $RESTORE_MODE -eq 1 ]]; then
        ok "awg1.conf восстановлен из бэкапа — генерация не требуется"
    else
    # Ключи awg1 живут там, где слушает клиентский интерфейс (режим 2 — на B)
    if [[ "$INSTALL_MODE" == "2" ]]; then
        run_de "cd $AWG_DIR && if [ ! -f awg1_private.key ]; then umask 077; awg genkey > awg1_private.key; awg pubkey < awg1_private.key > awg1_public.key; chmod 600 awg1_private.key; chmod 644 awg1_public.key; fi"
        AWG1_PRIV=$(run_de "cat $AWG_DIR/awg1_private.key" | tr -d '\r')
    else
    if [[ ! -f "$AWG_DIR/awg1_private.key" ]]; then
        umask 077
        awg genkey > "$AWG_DIR/awg1_private.key"
        awg pubkey < "$AWG_DIR/awg1_private.key" > "$AWG_DIR/awg1_public.key"
        chmod 600 "$AWG_DIR/awg1_private.key"
        chmod 644 "$AWG_DIR/awg1_public.key"
    fi
    AWG1_PRIV=$(cat "$AWG_DIR/awg1_private.key")
    fi

    cat > /tmp/awg1-gen.conf <<EOF
[Interface]
PrivateKey = $AWG1_PRIV
Address = $CLIENT_SERVER_IP/24
$AWG1_V6_ADDR
ListenPort = $AWG_CLIENT_PORT
MTU = $MTU_AWG1
Jc = $C_JC
Jmin = $C_JMIN
Jmax = $C_JMAX
S1 = $C_S1
S2 = $C_S2
S3 = $C_S3
S4 = $C_S4
H1 = $C_H1
H2 = $C_H2
H3 = $C_H3
H4 = $C_H4
HeaderProtectionKey = $C_HPK
ContentPaddingAddition = 16
RekeyAfterTime = 100-120
RekeyTimeout = 3-7
RejectAfterTime = 150-180
KeepaliveTimeout = 5-15
MaxHandshakeAttempts = 15-20
RandomTrailers = on
DisableCookies = on
$AWG1_DIRECT_UP
$AWG1_DIRECT_DOWN
EOF

    if [[ "$INSTALL_MODE" == "2" ]]; then
        scp_de /tmp/awg1-gen.conf "$AWG_DIR/awg1.conf"
        run_de "chmod 600 $AWG_DIR/awg1.conf && systemctl enable awg-quick@awg1 && systemctl restart awg-quick@awg1"
        rm -f /tmp/awg1-gen.conf
        ok "awg1 поднят на SERVER-B"
    else
        cp /tmp/awg1-gen.conf "$AWG_DIR/awg1.conf"
        rm -f /tmp/awg1-gen.conf
        chmod 600 "$AWG_DIR/awg1.conf"
    fi
    fi

    if [[ "$INSTALL_MODE" != "2" ]]; then
    systemctl enable awg-quick@awg1
    systemctl restart awg-quick@awg1
    sleep 2
    ok "awg1 поднят"
    fi

    # Восстановление пиров из /root/clients (awg1.conf пересоздан, а конфиги клиентов сохранились)
    PEERS_RESTORED=0
    shopt -s nullglob
    for CLIENT_CONF_FILE in /root/clients/*.conf; do
        RESTORE_NAME=$(basename "$CLIENT_CONF_FILE" .conf)
        RESTORE_PRIV=$(awk -F' = ' '/^PrivateKey =/{print $2; exit}' "$CLIENT_CONF_FILE")
        [[ -z "$RESTORE_PRIV" ]] && continue
        RESTORE_PUB=$(echo "$RESTORE_PRIV" | awg pubkey 2>/dev/null || true)
        [[ -z "$RESTORE_PUB" ]] && continue
        grep -qF "$RESTORE_PUB" "$AWG_DIR/awg1.conf" && continue
        RESTORE_ALLOWED=$(awk '/^Address =/{printf "%s, ", $3}' "$CLIENT_CONF_FILE" | sed 's/, $//')
        [[ -z "$RESTORE_ALLOWED" ]] && continue
        cat >> "$AWG_DIR/awg1.conf" <<EOF

[Peer]
# Client: $RESTORE_NAME
PublicKey = $RESTORE_PUB
AllowedIPs = $RESTORE_ALLOWED
EOF
        PEERS_RESTORED=$((PEERS_RESTORED + 1))
        ok "Восстановлен пир клиента: $RESTORE_NAME"
    done
    shopt -u nullglob
    if [[ $PEERS_RESTORED -gt 0 ]]; then
        systemctl restart awg-quick@awg1
        sleep 2
    fi
else
    # --- Режим обновления: константы и AmneziaWG уже на месте ---
    write_cascade_env
    [[ "${IPV6_ENABLED:-0}" == "1" ]] && INSTALL_FLAGS+=(--ipv6)

    say "Обновление базовых пакетов AmneziaWG на SERVER-A"
    bash /tmp/amnezia-server-install.sh "${INSTALL_FLAGS[@]}" < /dev/null
    ok "Базовые пакеты обновлены"
fi

# =====================================================================
#  Установка helper-скриптов
#  Режимы 1/3 — протоколы на SERVER-A: скрипты локально.
#  Режим 2 — протоколы на SERVER-B: скрипты на B, на A только управляющие.
# =====================================================================
say "Установка helper-скриптов"
mkdir -p /usr/local/bin

# Скрипты, нужные на сервере с веб-панелью (A) в режиме 2
PANEL_SIDE_SCRIPTS=(amnezia-panel-access.sh amnezia-restore-b.sh amnezia-notify.sh amnezia-notify-setup.sh)

install_script_local() {
    sed -e "s|__SERVER_ENDPOINT__|$(sed_escape "$ENDPOINT_HOST:$AWG_CLIENT_PORT")|g" \
        -e "s|__SERVER_NAME__|$(sed_escape "$SERVER_NAME")|g" \
        -e "s|__CLIENT_MTU__|$CLIENT_MTU|g" \
        -e "s|__DNS_SERVERS__|$(sed_escape "$CLIENT_DNS")|g" \
        "/tmp/$1" > "/usr/local/bin/$1"
    chmod +x "/usr/local/bin/$1"
}

if [[ "$INSTALL_MODE" == "2" && $UPDATE_MODE -eq 0 ]]; then
    # Все helper-скрипты — на SERVER-B
    for script in "${SCRIPTS_TO_DOWNLOAD[@]}"; do
        if [[ -f "/tmp/$script" ]]; then
            sed -e "s|__SERVER_ENDPOINT__|$(sed_escape "$ENDPOINT_HOST:$AWG_CLIENT_PORT")|g" \
                -e "s|__SERVER_NAME__|$(sed_escape "$SERVER_NAME")|g" \
                -e "s|__CLIENT_MTU__|$CLIENT_MTU|g" \
                -e "s|__DNS_SERVERS__|$(sed_escape "$CLIENT_DNS")|g" \
                "/tmp/$script" > "/tmp/_inst_$script"
            scp_de "/tmp/_inst_$script" "/usr/local/bin/$script"
            run_de "chmod +x /usr/local/bin/$script; mkdir -p /root/clients && chmod 700 /root/clients"
            rm -f "/tmp/_inst_$script"
        fi
    done
    # Протоколы — тоже на SERVER-B
    for p in "${PROTOCOLS[@]}"; do
        if [[ -f "/tmp/proto-$p.sh" ]]; then
            scp_de "/tmp/proto-$p.sh" "/usr/local/bin/amnezia-proto-$p.sh"
            run_de "chmod +x /usr/local/bin/amnezia-proto-$p.sh"
        fi
    done
    # На SERVER-A — только управляющие скрипты
    for script in "${PANEL_SIDE_SCRIPTS[@]}"; do
        [[ -f "/tmp/$script" ]] && install_script_local "$script"
    done
    mkdir -p /root/clients && chmod 700 /root/clients
else
    mkdir -p /root/clients && chmod 700 /root/clients
    for script in "${SCRIPTS_TO_DOWNLOAD[@]}"; do
        [[ -f "/tmp/$script" ]] && install_script_local "$script"
    done
    for p in "${PROTOCOLS[@]}"; do
        if [[ -f "/tmp/proto-$p.sh" ]]; then
            cp "/tmp/proto-$p.sh" "/usr/local/bin/amnezia-proto-$p.sh"
            chmod +x "/usr/local/bin/amnezia-proto-$p.sh"
        fi
    done
fi
ok "Скрипты установлены"

say "Настройка cron и ротации логов"
mkdir -p /var/lib/amnezia-panel
[[ -f /var/lib/amnezia-panel/traffic_enabled ]] || echo "1" > /var/lib/amnezia-panel/traffic_enabled
rm -f /usr/local/bin/amnezia-traffic-collector.sh  # очистка от старой версии

cat > /etc/logrotate.d/amnezia <<'EOF'
/var/log/amnezia-*.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    copytruncate
}
EOF

# healthcheck и сбор трафика — на сервере с протоколами (A в режимах 1/3, B в режиме 2)
if [[ "$INSTALL_MODE" == "2" && $UPDATE_MODE -eq 0 ]]; then
    run_de "cat > /etc/logrotate.d/amnezia <<'EOF'
/var/log/amnezia-*.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    copytruncate
}
EOF
cat > /etc/cron.d/amnezia-healthcheck <<'EOF'
0 * * * * root /usr/local/bin/amnezia-healthcheck.sh
EOF
cat > /etc/cron.d/amnezia-traffic <<'EOF'
*/5 * * * * root /usr/local/bin/amnezia-traffic-collector.py
EOF
chmod 644 /etc/cron.d/amnezia-* /etc/logrotate.d/amnezia
mkdir -p /var/lib/amnezia-panel
[ -f /var/lib/amnezia-panel/traffic_enabled ] || echo 1 > /var/lib/amnezia-panel/traffic_enabled
/usr/local/bin/amnezia-traffic-collector.py 2>/dev/null || true"
else
if [[ -x /usr/local/bin/amnezia-healthcheck.sh ]]; then
    cat > /etc/cron.d/amnezia-healthcheck <<'EOF'
0 * * * * root /usr/local/bin/amnezia-healthcheck.sh
EOF
    chmod 644 /etc/cron.d/amnezia-healthcheck
fi

if [[ -x /usr/local/bin/amnezia-traffic-collector.py ]]; then
    cat > /etc/cron.d/amnezia-traffic <<'EOF'
*/5 * * * * root /usr/local/bin/amnezia-traffic-collector.py
EOF
    chmod 644 /etc/cron.d/amnezia-traffic
    /usr/local/bin/amnezia-traffic-collector.py 2>/dev/null || true
fi
fi

# === Ежедневный бэкап ===
# Режим 1: только локально на A. Режим 3: локально на A + копия на B (ключ A→B).
# Режим 2: бэкап делается на B, копия уходит на A (ключ B→A).
if [[ "$INSTALL_MODE" == "2" && $UPDATE_MODE -eq 0 ]]; then
    say "Настройка бэкапа на SERVER-B (копии прилетают на SERVER-A)"
    # Константы для helper-скриптов на B (бэкап-копии уходят на A)
    write_cascade_env
    sed "s|^BACKUP_HOST=.*|BACKUP_HOST=\"$RU_IP\"|" "$CASCADE_ENV" > /tmp/_cascade_b.env
    scp_de /tmp/_cascade_b.env "$CASCADE_ENV"
    run_de "chmod 600 $CASCADE_ENV"
    rm -f /tmp/_cascade_b.env

    run_de "cat > /etc/cron.d/amnezia-backup <<'EOF'
17 4 * * * root /usr/local/bin/amnezia-backup.sh
EOF
chmod 644 /etc/cron.d/amnezia-backup"
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
    run_de "[[ -f /root/.ssh/id_ed25519 ]] || ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519 -q; cat /root/.ssh/id_ed25519.pub" > /tmp/_b_pubkey
    B_PUBKEY=$(cat /tmp/_b_pubkey | tr -d '\r'); rm -f /tmp/_b_pubkey
    grep -qxF "$B_PUBKEY" /root/.ssh/authorized_keys 2>/dev/null || echo "$B_PUBKEY" >> /root/.ssh/authorized_keys \
        && ok "SSH-ключ SERVER-B → SERVER-A установлен (для бэкапов)" \
        || warn "Не удалось установить ключ — бэкап будет только локальным на B"
    mkdir -p /root/amnezia-backups && chmod 700 /root/amnezia-backups

    # SSH-ключ SERVER-A → SERVER-B для управления из веб-панели
    [[ ! -f /root/.ssh/id_ed25519 ]] && ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519 -q
    A_PUBKEY=$(cat /root/.ssh/id_ed25519.pub)
    run_de "mkdir -p /root/.ssh && chmod 700 /root/.ssh && touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && grep -qxF '$A_PUBKEY' /root/.ssh/authorized_keys || echo '$A_PUBKEY' >> /root/.ssh/authorized_keys" \
        && ok "SSH-ключ SERVER-A → SERVER-B установлен (для панели)" \
        || { err "Не удалось установить ключ A → B — панель не сможет управлять SERVER-B"; exit 1; }
elif [[ "$INSTALL_MODE" != "2" && -x /usr/local/bin/amnezia-backup.sh ]]; then
    cat > /etc/cron.d/amnezia-backup <<'EOF'
17 4 * * * root /usr/local/bin/amnezia-backup.sh
EOF
    chmod 644 /etc/cron.d/amnezia-backup

    # SSH-ключ SERVER-A -> SERVER-B для отправки бэкапов (fresh и restore)
    if [[ $UPDATE_MODE -eq 0 && "$INSTALL_MODE" == "3" ]]; then
        say "Настройка SSH-ключа для бэкапов на SERVER-B"
        [[ ! -f /root/.ssh/id_ed25519 ]] && ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519 -q
        A_PUBKEY=$(cat /root/.ssh/id_ed25519.pub)
        run_de "mkdir -p /root/.ssh && chmod 700 /root/.ssh && touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && grep -qxF '$A_PUBKEY' /root/.ssh/authorized_keys || echo '$A_PUBKEY' >> /root/.ssh/authorized_keys" \
            && ok "SSH-ключ установлен на SERVER-B" \
            || warn "Не удалось установить SSH-ключ на SERVER-B — бэкап будет только локальным"
    fi
fi
ok "cron настроен"

if [[ $UPDATE_MODE -eq 0 ]]; then
    say "Создание первого клиента (admin)"
    if [[ "$INSTALL_MODE" == "2" ]]; then
        run_de "[[ -f /root/clients/admin.conf ]] || echo n | /usr/local/bin/amnezia-add-client.sh admin" \
            && ok "Клиент admin создан на SERVER-B" || warn "admin уже существует или создан"
    else
    if [[ ! -f /root/clients/admin.conf ]] && [[ -x /usr/local/bin/amnezia-add-client.sh ]]; then
        echo "n" | /usr/local/bin/amnezia-add-client.sh admin || warn "admin уже существует или создан"
    else
        ok "Клиент admin уже существует"
    fi
    fi
fi

# =====================================================================
#  Установка веб-панели
# =====================================================================
if [[ "$INSTALL_PANEL" =~ ^[yYдД] ]]; then
    say "Установка веб-панели"

    if [[ ( $UPDATE_MODE -eq 1 || $RESTORE_MODE -eq 1 ) && -f /etc/amnezia-panel.conf ]]; then
        AUTH_CHOICE="keep"
        ok "Учётные данные панели сохраняются"
    else
        echo ""
        echo "Выберите способ создания учётных данных для панели:"
        echo "  1) Сгенерировать автоматически (рекомендуется)"
        echo "  2) Указать свой логин и пароль"
        echo ""
        read -p "Ваш выбор [1]: " AUTH_CHOICE
        AUTH_CHOICE="${AUTH_CHOICE:-1}"

        case "$AUTH_CHOICE" in
            2)
                read -p "Логин: " PANEL_USER
                [[ -z "$PANEL_USER" ]] && { err "Логин не может быть пустым"; exit 1; }
                while :; do
                    read -r -s -p "Пароль (мин. 8 символов): " PANEL_PASS; echo
                    [[ ${#PANEL_PASS} -lt 8 ]] && { warn "Пароль слишком короткий, попробуйте снова"; continue; }
                    read -r -s -p "Повторите пароль: " PANEL_PASS2; echo
                    [[ "$PANEL_PASS" != "$PANEL_PASS2" ]] && { warn "Пароли не совпадают, попробуйте снова"; continue; }
                    break
                done
                ;;
            *)
                PANEL_USER="admin"
                # openssl завершается сам — нет SIGPIPE, безопасно под pipefail
                PANEL_PASS=$(openssl rand -hex 12)
                ;;
        esac
    fi

    echo "  ↓ Скачивание файлов веб-панели"
    download_url "web-panel/amnezia-panel.py" /tmp/amnezia-panel.py
    download_url "web-panel/amnezia-panel.service" /tmp/amnezia-panel.service
    [[ -f /tmp/amnezia-panel.py && -f /tmp/amnezia-panel.service ]] || { err "Не удалось скачать файлы панели"; exit 1; }

    apt install -y -qq python3-venv < /dev/null
    python3 -m venv /opt/amnezia-panel-venv
    /opt/amnezia-panel-venv/bin/pip install --quiet --upgrade pip
    /opt/amnezia-panel-venv/bin/pip install --quiet fastapi 'uvicorn[standard]' python-multipart

    sed "s|__SERVER_LABEL__|$(sed_escape "$SERVER_NAME")|g" /tmp/amnezia-panel.py > /opt/amnezia-panel.py
    chmod 700 /opt/amnezia-panel.py

    if [[ "$AUTH_CHOICE" != "keep" ]]; then
        # Пароль хранится только в виде хэша с солью
        PANEL_SALT=$(openssl rand -hex 16)
        PANEL_HASH=$(printf '%s' "${PANEL_SALT}${PANEL_PASS}" | sha256sum | awk '{print $1}')
        cat > /etc/amnezia-panel.conf <<EOF
username=$PANEL_USER
password_hash=sha256:$PANEL_SALT:$PANEL_HASH
EOF
        chmod 600 /etc/amnezia-panel.conf
    fi

    # Fail2Ban-защита формы логина панели (если fail2ban установлен)
    if command -v fail2ban-client >/dev/null 2>&1; then
        cat > /etc/fail2ban/filter.d/amnezia-panel.conf <<'EOF'
[Definition]
failregex = ^.*Failed login attempt from <HOST>.*$
ignoreregex =
EOF
        if ! grep -q '^\[amnezia-panel\]' /etc/fail2ban/jail.local 2>/dev/null; then
            cat >> /etc/fail2ban/jail.local <<'EOF'

[amnezia-panel]
enabled = true
port = 80,443,8000
filter = amnezia-panel
backend = polling
logpath = /var/log/amnezia-panel-auth.log
maxretry = 5
bantime = 3600
findtime = 600
EOF
        fi
        systemctl restart fail2ban
        ok "Fail2Ban защищает и форму логина панели"
    fi

    mkdir -p /etc/amnezia-panel-ssl
    if [[ ! -f /etc/amnezia-panel-ssl/cert.pem ]]; then
        openssl req -x509 -newkey rsa:4096 \
            -keyout /etc/amnezia-panel-ssl/key.pem \
            -out /etc/amnezia-panel-ssl/cert.pem \
            -days 3650 -nodes -subj "/CN=amnezia-panel" 2>/dev/null
        chmod 600 /etc/amnezia-panel-ssl/*.pem
    fi

    cp /tmp/amnezia-panel.service /etc/systemd/system/amnezia-panel.service
    systemctl daemon-reload
    systemctl enable amnezia-panel
    systemctl restart amnezia-panel
    sleep 2
    rm -f /tmp/amnezia-panel.py /tmp/amnezia-panel.service

    echo "  ↓ Сохранение текущей версии репозитория"
    LATEST_SHA=$(curl -s "https://api.github.com/repos/daff4ik/amneziawg-cascade-v2/commits/v3" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null || true)
    [[ -n "$LATEST_SHA" ]] && echo "$LATEST_SHA" > /var/lib/amnezia-panel/installed_commit
fi

# =====================================================================
#  Stealth сразу при первой установке (если Endpoint — домен и выбрано)
# =====================================================================
if [[ $UPDATE_MODE -eq 0 && "${SETUP_STEALTH:-n}" =~ ^[yYдД] && "$INSTALL_PANEL" =~ ^[yYдД] ]]; then
    say "Настройка Stealth-режима (домен $ENDPOINT_HOST)"
    download_url "stealth-setup.sh" /tmp/stealth-setup.sh
    if [[ -f /tmp/stealth-setup.sh ]]; then
        STEALTH_DOMAIN="$ENDPOINT_HOST" STEALTH_SECRET_PATH="$STEALTH_SECRET" bash /tmp/stealth-setup.sh \
            || warn "Stealth не настроился — повторите позже: deploy.sh --update"
        rm -f /tmp/stealth-setup.sh
    else
        warn "Не удалось скачать stealth-setup.sh — настройте позже: deploy.sh --update"
    fi
fi

# =====================================================================
#  Настройка Stealth-режима (Только в режиме --update)
# =====================================================================
if [[ $UPDATE_MODE -eq 1 && "${SETUP_STEALTH:-n}" =~ ^[yYдД] ]]; then
    say "Настройка Stealth-режима (Сайт-заглушка)"
    download_url "stealth-setup.sh" /tmp/stealth-setup.sh
    if [[ -f /tmp/stealth-setup.sh ]]; then
        bash /tmp/stealth-setup.sh
        rm -f /tmp/stealth-setup.sh
    else
        err "Не удалось скачать stealth-setup.sh"
        exit 1
    fi
fi

# =====================================================================
#  Итоговый вывод
# =====================================================================
# === Первый бэкап — после полной настройки (включая панель) ===
if [[ $UPDATE_MODE -eq 0 && "$INSTALL_MODE" == "2" ]]; then
    say "Создание первого бэкапа (на SERVER-B, копия прилетит сюда)"
    run_de "/usr/local/bin/amnezia-backup.sh" || warn "Первый бэкап не удался — проверьте вручную на B: /usr/local/bin/amnezia-backup.sh"
elif [[ $UPDATE_MODE -eq 0 && -x /usr/local/bin/amnezia-backup.sh ]]; then
    say "Создание первого бэкапа"
    /usr/local/bin/amnezia-backup.sh || warn "Первый бэкап не удался — проверьте вручную: /usr/local/bin/amnezia-backup.sh"
fi

say "ГОТОВО"
if [[ $UPDATE_MODE -eq 1 ]]; then
    echo "Режим обновления завершён."
    echo "Конфиги awg0/awg1 и клиенты не изменены."
elif [[ $RESTORE_MODE -eq 1 ]]; then
    cat <<EOM

SERVER-A восстановлен из бэкапа.

  Новый SERVER-A:  $RU_IP
  SERVER-B:        $DE_IP (конфиг не менялся)
  Endpoint:        $ENDPOINT_HOST:$AWG_CLIENT_PORT
  Клиенты и ключи восстановлены — конфиги клиентов менять НЕ нужно.
  Если Endpoint — домен, обновите его A-запись на $RU_IP.
EOM
else
    MODE_DESC="Каскад A+B"
    [[ "$INSTALL_MODE" == "1" ]] && MODE_DESC="Только SERVER-A"
    [[ "$INSTALL_MODE" == "2" ]] && MODE_DESC="Только SERVER-B (панель на A)"
    cat <<EOM

Каскадный VPN развёрнут. Режим: $MODE_DESC

  SERVER-A (этот): $RU_IP
$( [[ "$INSTALL_MODE" != "1" ]] && echo "  SERVER-B:        $DE_IP" )
$( [[ "$INSTALL_MODE" == "3" ]] && echo "  Туннель awg0:    порт $AWG_TUNNEL_PORT/udp" )
  Клиенты awg1:    порт $AWG_CLIENT_PORT/udp
  Endpoint:        $ENDPOINT_HOST:$AWG_CLIENT_PORT
  Подсеть:         $CLIENT_SUBNET.0/24
  IPv6:            $([[ $IPV6_ENABLED -eq 1 ]] && echo "включён ($CLIENT_SUBNET6::/64)" || echo "выключен")
  Fail2Ban:        $([[ "$INSTALL_F2B" =~ ^[yYдД] ]] && echo "установлен" || echo "не установлен")
EOM
fi

if [[ "$INSTALL_PANEL" =~ ^[yYдД] ]]; then
    P_CONF="/etc/amnezia-panel.conf"
    P_HOST=$(awk -F'=' '/^host/ {print $2}' "$P_CONF" 2>/dev/null | tr -d ' \r\n')
    [[ -z "$P_HOST" ]] && P_HOST="0.0.0.0"
    P_BASE=$(awk -F'=' '/^base_url/ {print $2}' "$P_CONF" 2>/dev/null | tr -d ' \r\n')

    # Данные stealth-режима читаем из сохранённого файла (пишет stealth-setup.sh)
    P_DOMAIN=""
    if [[ -f /etc/amnezia-stealth.conf ]]; then
        P_DOMAIN=$(awk -F'=' '/^domain/ {print $2}' /etc/amnezia-stealth.conf 2>/dev/null | tr -d ' \r\n')
    fi

    echo "=============================================="
    if [[ "$P_HOST" == "127.0.0.1" && -n "$P_DOMAIN" ]]; then
        echo "URL заглушка:         https://$P_DOMAIN"
        echo "URL веб панели:       https://$P_DOMAIN$P_BASE"
        echo "IP адрес веб панели : https://$RU_IP:8000 - не доступно - включен домен"
    else
        echo "Веб-панель:           https://$RU_IP:8000"
    fi
    echo "Учётные данные:       /etc/amnezia-panel.conf"
    if [[ -n "${PANEL_PASS:-}" ]]; then
        echo "Логин:                $PANEL_USER"
        echo "Пароль:               $PANEL_PASS"
        echo "(СОХРАНИТЕ ПАРОЛЬ! На сервере хранится только его хэш)"
    fi
    echo "=============================================="

    # --- ИНСТРУКЦИЯ ПО STEALTH ТОЛЬКО ДЛЯ ПЕРВОЙ УСТАНОВКИ БЕЗ STEALTH ---
    if [[ $UPDATE_MODE -eq 0 && ! -f /etc/amnezia-stealth.conf ]]; then
        echo ""
        say "Stealth-режим (Сайт-заглушка)"
        echo "Для максимальной маскировки вы можете спрятать панель за собственным сайтом-заглушкой."
        echo ""
        echo "ИНСТРУКЦИЯ ПО НАСТРОЙКЕ:"
        echo "1. Получите домен (например, на https://freedns.afraid.org/) и направьте его на IP: $RU_IP"
        echo "2. Подготовьте файлы вашего фейкового сайта (index.html, картинки и т.д.)."
        echo "3. Загрузите эти файлы на сервер в папку: /var/www/stealth"
        echo "4. Запустите скрипт обновления с флагом --update:"
        echo "   sudo bash -c \"\$(curl -fsSL $REPO_URL/deploy.sh)\" -- --update"
        echo "5. При обновлении ответьте 'y' на вопрос о настройке Stealth-режима."
        echo "=============================================="
    fi
fi

echo ""
echo "Приятного использования!"
