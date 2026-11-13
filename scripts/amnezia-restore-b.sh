#!/bin/bash
# =====================================================================
#  amnezia-restore-b.sh  (запускать на SERVER-A)
#  «restore_b»: перенос выходного сервера на новый SERVER-B —
#  например, если старый заблокирован по IP.
#  Делает: базовая установка на новом B, новые ключи awg0 на B,
#  обновление пира на A (с откатом при сбое), SSH-ключ для бэкапов,
#  servers.json панели.
#
#  Единый движок переключения SERVER-B: его же вызывает веб-панель
#  (вкладка «Серверы») через переменные окружения:
#    RESTORE_B_IP, RESTORE_B_PORT, RESTORE_B_USER, SSHPASS (пароль),
#    RESTORE_B_F2B (y/n), RESTORE_B_NO_JSON=1 (не трогать servers.json)
#  Без этих переменных скрипт работает интерактивно.
# =====================================================================
set -euo pipefail

CASCADE_ENV="/etc/amnezia-cascade.env"
AWG_DIR="/etc/amnezia/amneziawg"
B_COPY="$AWG_DIR/awg0-de.conf.copy"
REPO_URL="https://raw.githubusercontent.com/daff4ik/amneziawg-cascade-v3/main"

ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

[[ $EUID -ne 0 ]] && { err "Запускать от root (sudo $0)"; exit 1; }
[[ -f "$CASCADE_ENV" ]] || { err "Нет $CASCADE_ENV — система не развёрнута"; exit 1; }
source "$CASCADE_ENV"
[[ "${INSTALL_MODE:-3}" == "3" ]] || { err "Переключение SERVER-B поддерживается только в каскадном режиме (INSTALL_MODE=3)"; exit 1; }
[[ -f "$B_COPY" ]] || { err "Нет $B_COPY — копия конфига SERVER-B не сохранена (установка старой версии). Выполните deploy --update на SERVER-A, затем повторите."; exit 1; }

# === Параметры: из окружения (вызывает панель) или интерактивно ===
NB_IP="${RESTORE_B_IP:-}"
NB_PORT="${RESTORE_B_PORT:-22}"
NB_USER="${RESTORE_B_USER:-root}"
NB_PASS="${SSHPASS:-}"
NB_F2B="${RESTORE_B_F2B:-y}"

echo "=============================================="
echo " Восстановление SERVER-B на новом сервере"
echo "=============================================="
[[ -z "$NB_IP" ]] && { read -p "IP-адрес НОВОГО SERVER-B: " NB_IP; }
[[ -z "$NB_IP" ]] && { err "IP обязателен"; exit 1; }
[[ -z "${RESTORE_B_PORT:-}" ]] && { read -p "SSH-порт [$NB_PORT]: " NB_PORT_IN; NB_PORT="${NB_PORT_IN:-$NB_PORT}"; }
[[ -z "${RESTORE_B_USER:-}" ]] && { read -p "SSH-пользователь [$NB_USER]: " NB_USER_IN; NB_USER="${NB_USER_IN:-$NB_USER}"; }
[[ -z "$NB_PASS" ]] && { read -r -s -p "SSH-пароль: " NB_PASS; echo; }
[[ -z "$NB_PASS" ]] && { err "Пароль обязателен"; exit 1; }
[[ -z "${RESTORE_B_F2B:-}" ]] && { read -p "Установить Fail2Ban на новый SERVER-B? (y/n) [y]: " NB_F2B; NB_F2B="${NB_F2B:-y}"; }

command -v sshpass >/dev/null || { apt update -qq < /dev/null && apt install -y -qq sshpass < /dev/null; }
export SSHPASS="$NB_PASS"

run_nb() {
    sshpass -e ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 -p "$NB_PORT" "$NB_USER@$NB_IP" "$@"
}
scp_nb() {
    sshpass -e scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -P "$NB_PORT" "$1" "$NB_USER@$NB_IP:$2"
}

run_nb "echo SSH_OK" | grep -q SSH_OK || { err "SSH до $NB_IP не работает"; exit 1; }
ok "SSH до нового SERVER-B работает"

# === Префлайт IPv6: маршрут наружу ===
if [[ "${IPV6_ENABLED:-0}" == "1" ]]; then
    if ! run_nb "ip -6 route show default 2>/dev/null | grep -q '^default'"; then
        err "На сервере $NB_IP нет выхода в IPv6, а в конфигурации туннеля IPv6 включён."
        err "Выберите сервер с поддержкой IPv6."
        exit 1
    fi
fi

# === Базовая установка на новом B ===
FLAGS=()
[[ "${IPV6_ENABLED:-0}" == "1" ]] && FLAGS+=(--ipv6)
[[ "$NB_F2B" =~ ^[yYдД] ]] && FLAGS+=(--fail2ban)

echo "Скачивание amnezia-server-install.sh..."
DL_OK=0
for BASE in "$REPO_URL" \
    "https://ghproxy.net/$REPO_URL" \
    "https://mirror.ghproxy.com/$REPO_URL"; do
    if curl -fsSL --connect-timeout 15 "$BASE/scripts/amnezia-server-install.sh" -o /tmp/amnezia-server-install.sh 2>/dev/null; then
        DL_OK=1; break
    fi
done
[[ $DL_OK -eq 1 ]] || { err "Не удалось скачать amnezia-server-install.sh"; exit 1; }

echo "Установка AmneziaWG на новом SERVER-B ($NB_IP)..."
scp_nb /tmp/amnezia-server-install.sh /tmp/amnezia-server-install.sh
run_nb "bash /tmp/amnezia-server-install.sh ${FLAGS[*]}; rm -f /tmp/amnezia-server-install.sh"
rm -f /tmp/amnezia-server-install.sh
ok "Базовая установка на новом SERVER-B завершена"

# === Префлайт IPv6: поддержка модулем AmneziaWG (MTU 1280, RFC 8200) ===
if [[ "${IPV6_ENABLED:-0}" == "1" ]]; then
    V6_CHECK='ip link add _v6chk type amneziawg 2>/dev/null && ip -6 addr add fd00::1/128 dev _v6chk 2>/dev/null && ip link set mtu 1280 up dev _v6chk 2>/dev/null && ip -6 route add fd00::2/128 dev _v6chk 2>/dev/null && ip -6 addr show dev _v6chk 2>/dev/null | grep -q "fd00::1"'
    if ! run_nb "$V6_CHECK; r=\$?; ip link del _v6chk 2>/dev/null; exit \$r"; then
        err "Модуль AmneziaWG на сервере $NB_IP не поддерживает IPv6 (старое ядро/dkms),"
        err "а в конфигурации туннеля IPv6 включён. Выберите другой сервер."
        exit 1
    fi
fi

# === Новые ключи awg0 на B ===
run_nb "mkdir -p $AWG_DIR && chmod 700 $AWG_DIR && cd $AWG_DIR && \
    umask 077; awg genkey > private.key; awg pubkey < private.key > public.key; \
    chmod 600 private.key; chmod 644 public.key"
NB_PRIV=$(run_nb "cat $AWG_DIR/private.key" | tr -d '\r')
NB_PUB=$(run_nb "cat $AWG_DIR/public.key" | tr -d '\r')
[[ -n "$NB_PRIV" && -n "$NB_PUB" ]] || { err "Не удалось сгенерировать ключи на новом SERVER-B"; exit 1; }

NB_IFACE=$(run_nb "ip route get 8.8.8.8 | awk '{print \$5}' | head -1" | tr -d '\r')
[[ -z "$NB_IFACE" ]] && { err "Не удалось определить внешний интерфейс нового SERVER-B"; exit 1; }
ok "Внешний интерфейс нового SERVER-B: $NB_IFACE"

# === Конфиг awg0 для нового B (из сохранённой копии) ===
sed -e "s|^PrivateKey = .*|PrivateKey = $NB_PRIV|" "$B_COPY" > /tmp/awg0-de.conf
if [[ -n "${SERVER_B_IFACE:-}" && "$SERVER_B_IFACE" != "$NB_IFACE" ]]; then
    sed -i "s|-o ${SERVER_B_IFACE} |-o ${NB_IFACE} |g" /tmp/awg0-de.conf
fi
chmod 600 /tmp/awg0-de.conf
scp_nb /tmp/awg0-de.conf "$AWG_DIR/awg0.conf"
run_nb "chmod 600 $AWG_DIR/awg0.conf"
cp /tmp/awg0-de.conf "$B_COPY"   # обновляем сохранённую копию (актуальный ключ/интерфейс)
rm -f /tmp/awg0-de.conf
ok "Конфиг awg0 развёрнут на новом SERVER-B"

# === Обновление пира на SERVER-A (с бэкапом для отката) ===
cp "$AWG_DIR/awg0.conf" "$AWG_DIR/awg0.conf.before_restore_b"
sed -i -e "s|^Endpoint = .*|Endpoint = $NB_IP:$AWG_TUNNEL_PORT|" \
       -e "/^\[Peer\]/,\$ s|^PublicKey = .*|PublicKey = $NB_PUB|" \
    "$AWG_DIR/awg0.conf"
ok "Пир в awg0.conf на SERVER-A обновлён"

# === Запуск туннеля ===
run_nb "systemctl enable awg-quick@awg0 && systemctl restart awg-quick@awg0"
systemctl restart awg-quick@awg0
sleep 3

TUN_OK=1
ping -c 3 -W 3 "$TUNNEL_B_IP" >/dev/null 2>&1 || TUN_OK=0
if [[ "${IPV6_ENABLED:-0}" == "1" ]]; then
    ping -6 -c 3 -W 3 "$TUNNEL_B_IP6" >/dev/null 2>&1 || TUN_OK=0
fi
if [[ $TUN_OK -eq 1 ]]; then
    ok "Туннель awg0 до нового SERVER-B работает"
    rm -f "$AWG_DIR/awg0.conf.before_restore_b"
else
    cp "$AWG_DIR/awg0.conf.before_restore_b" "$AWG_DIR/awg0.conf"
    systemctl restart awg-quick@awg0 || true
    err "Пинг до нового SERVER-B через туннель не идёт — конфиг SERVER-A откачен."
    err "Проверьте новый сервер вручную (awg show, journalctl -u awg-quick@awg0)."
    exit 1
fi

# === Обновление cascade.env ===
sed -i -e "s|^SERVER_B_IP=.*|SERVER_B_IP=\"$NB_IP\"|" \
       -e "s|^SERVER_B_PORT=.*|SERVER_B_PORT=\"$NB_PORT\"|" \
       -e "s|^SERVER_B_USER=.*|SERVER_B_USER=\"$NB_USER\"|" \
       -e "s|^SERVER_B_IFACE=.*|SERVER_B_IFACE=\"$NB_IFACE\"|" \
    "$CASCADE_ENV"
ok "cascade.env обновлён"

# === SSH-ключ для бэкапов на новый B ===
[[ ! -f /root/.ssh/id_ed25519 ]] && ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519 -q
A_PUBKEY=$(cat /root/.ssh/id_ed25519.pub)
run_nb "mkdir -p /root/.ssh && chmod 700 /root/.ssh && touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && grep -qxF '$A_PUBKEY' /root/.ssh/authorized_keys || echo '$A_PUBKEY' >> /root/.ssh/authorized_keys"
ok "SSH-ключ для бэкапов установлен на новый SERVER-B"

# === Обновление списка серверов в панели (пропускается при вызове из панели) ===
SERVERS_JSON="/var/lib/amnezia-panel/servers.json"
if [[ "${RESTORE_B_NO_JSON:-0}" != "1" && -f "$SERVERS_JSON" ]]; then
    python3 - "$SERVERS_JSON" "$NB_IP" "$NB_PORT" "$NB_USER" <<'PYEOF' || warn "Не удалось обновить servers.json — обновите вручную в панели"
import json, sys
path, ip, port, user = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
servers = data.get("servers", [])
new_id = max([s.get("id", 0) for s in servers], default=0) + 1
servers.append({"id": new_id, "ip": ip, "port": port, "user": user, "name": f"Restored ({ip})"})
data["servers"] = servers
data["active_id"] = new_id
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
PYEOF
    ok "Сервер в панели переключён на $NB_IP"
fi

echo "=============================================="
echo "✅ SERVER-B восстановлен на $NB_IP"
echo "=============================================="
echo "Клиенты продолжают работать — их конфиги не менялись."
