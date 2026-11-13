#!/bin/bash
# =====================================================================
#  amnezia-cascade-setup.sh  (запускать на SERVER-A)
#  Переводит прямое подключение (режим 0/1) в каскад A → B:
#  базовая установка AmneziaWG на B, туннель awg0, переключение
#  маршрутизации клиентов awg1 в туннель, SSH-ключ A→B.
#  При сбое — откат к прямому подключению.
#
#  Параметры через окружение (вызывает веб-панель) или интерактивно:
#    CASCADE_B_IP, CASCADE_B_PORT, CASCADE_B_USER, SSHPASS (пароль B)
#  Пароль нигде не сохраняется: используется один раз для установки ключа.
# =====================================================================
set -euo pipefail

CASCADE_ENV="/etc/amnezia-cascade.env"
AWG_DIR="/etc/amnezia/amneziawg"
AWG_TUNNEL_PORT="8443"
TUNNEL_A_IP="10.10.10.2"
TUNNEL_B_IP="10.10.10.1"
TUNNEL_A_IP6="fd00:10:10:10::2"
TUNNEL_B_IP6="fd00:10:10:10::1"
MTU_AWG0="1180"
MSS_CLAMP="1000"

MIRRORS=(
    "https://raw.githubusercontent.com/daff4ik/amneziawg-cascade-v3/main"
    "https://ghproxy.net/https://raw.githubusercontent.com/daff4ik/amneziawg-cascade-v3/main"
    "https://mirror.ghproxy.com/https://raw.githubusercontent.com/daff4ik/amneziawg-cascade-v3/main"
)

ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

[[ $EUID -ne 0 ]] && { err "Запускать от root"; exit 1; }
[[ -f "$CASCADE_ENV" ]] || { err "Нет $CASCADE_ENV"; exit 1; }
source "$CASCADE_ENV"
[[ "${INSTALL_MODE:-0}" == "3" ]] && { err "Каскад уже настроен"; exit 1; }
[[ -f "$AWG_DIR/awg1.conf" ]] || { err "Нет awg1.conf — сначала установите AmneziaWG"; exit 1; }
command -v awg >/dev/null || { err "Нет пакета AmneziaWG"; exit 1; }

NB_IP="${CASCADE_B_IP:-}"
NB_PORT="${CASCADE_B_PORT:-22}"
NB_USER="${CASCADE_B_USER:-root}"
[[ -z "$NB_IP" ]] && { read -p "IP-адрес SERVER-B: " NB_IP; }
[[ -z "$NB_IP" ]] && { err "IP обязателен"; exit 1; }
if [[ -z "${SSHPASS:-}" ]]; then
    read -r -s -p "SSH-пароль SERVER-B: " SSHPASS; echo
fi
export SSHPASS

command -v sshpass >/dev/null || { apt update -qq < /dev/null && apt install -y -qq sshpass < /dev/null; }

run_b() {
    sshpass -e ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 -p "$NB_PORT" "$NB_USER@$NB_IP" "$@"
}
scp_b() {
    sshpass -e scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -P "$NB_PORT" "$1" "$NB_USER@$NB_IP:$2"
}

run_b "echo SSH_OK" | grep -q SSH_OK || { err "SSH до $NB_IP не работает"; exit 1; }
ok "SSH до SERVER-B работает"

# --- Откат при сбое ---
cp "$AWG_DIR/awg1.conf" /tmp/awg1.conf.pre-cascade
rollback() {
    err "Сбой — откат к прямому подключению"
    cp /tmp/awg1.conf.pre-cascade "$AWG_DIR/awg1.conf"
    systemctl stop awg-quick@awg0 2>/dev/null || true
    systemctl disable awg-quick@awg0 2>/dev/null || true
    rm -f "$AWG_DIR/awg0.conf"
    systemctl restart awg-quick@awg1
    run_b "systemctl stop awg-quick@awg0 2>/dev/null; systemctl disable awg-quick@awg0 2>/dev/null; rm -f $AWG_DIR/awg0.conf" || true
    exit 1
}

# --- Базовая установка AmneziaWG на B ---
say() { echo -e "\n\033[1;36m=== $* ===\033[0m"; }
say "Установка AmneziaWG на SERVER-B"
V6_B=0
run_b "ip -6 route show default 2>/dev/null | grep -q '^default'" && V6_B=1 || true
FLAGS=""
[[ $V6_B -eq 1 ]] && FLAGS="--ipv6"
for m in "${MIRRORS[@]}"; do
    curl -fsSL --connect-timeout 5 --max-time 30 "$m/scripts/amnezia-server-install.sh" -o /tmp/amnezia-server-install.sh && break
done
[[ -f /tmp/amnezia-server-install.sh ]] || { err "Не скачан amnezia-server-install.sh"; rollback; }
scp_b /tmp/amnezia-server-install.sh /tmp/amnezia-server-install.sh
run_b "bash /tmp/amnezia-server-install.sh $FLAGS; rm -f /tmp/amnezia-server-install.sh" || rollback
ok "AmneziaWG на SERVER-B готов"

# --- IPv6: в туннеле только если v6 есть на ОБОИХ концах ---
IPV6="${IPV6_ENABLED:-0}"
[[ "$IPV6" == "1" && $V6_B -eq 1 ]] && TUN_V6=1 || TUN_V6=0
if [[ $TUN_V6 -eq 1 ]]; then MTU_AWG0=1280; MSS_CLAMP=1220; fi

# --- Параметры обфускации туннеля ---
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
while :; do
    S1=$((RANDOM % 50 + 12)); S2=$((RANDOM % 50 + 12))
    [[ $((S1 + 56)) -ne $S2 ]] && break
done
HPK=$(awg genkey)
JC=$((RANDOM % 6 + 3)); JMIN=$((RANDOM % 40 + 10)); JMAX=$((JMIN + RANDOM % 40 + 20))
read -r H1 H2 H3 H4 <<< "$(gen_ranges)"

# --- Ключи awg0 ---
if [[ ! -f "$AWG_DIR/private.key" ]]; then
    umask 077
    awg genkey > "$AWG_DIR/private.key"
    awg pubkey < "$AWG_DIR/private.key" > "$AWG_DIR/public.key"
    chmod 600 "$AWG_DIR/private.key"; chmod 644 "$AWG_DIR/public.key"
fi
RU_PUB=$(cat "$AWG_DIR/public.key")
run_b "mkdir -p $AWG_DIR && chmod 700 $AWG_DIR && cd $AWG_DIR && \
    if [ ! -f private.key ]; then umask 077; awg genkey > private.key; awg pubkey < private.key > public.key; chmod 600 private.key; chmod 644 public.key; fi"
DE_PUB=$(run_b "cat $AWG_DIR/public.key" | tr -d '\r')
DE_IFACE=$(run_b "ip route get 8.8.8.8 | awk '{print \$5}' | head -1" | tr -d '\r')
[[ -z "$DE_IFACE" ]] && { err "Не удалось определить внешний интерфейс SERVER-B"; rollback; }

CLIENT_SUBNET="${CLIENT_SUBNET:-10.8.0}"
CLIENT_SUBNET6="${CLIENT_SUBNET6:-fd00:10:8}"

# --- IPv6-фрагменты ---
A_V6_ADDR=""; A_V6_ALLOWED=""; A_V6_POST=""; B_V6_ADDR=""; B_V6_ALLOWED=""; B_V6_POST=""
if [[ $TUN_V6 -eq 1 ]]; then
    A_V6_ADDR="Address = ${TUNNEL_A_IP6}/128"
    A_V6_ALLOWED=", ::/0"
    A_V6_POST="PostUp = ip -6 route add ${TUNNEL_B_IP6}/128 dev awg0
PostUp = ip -6 route add default dev awg0 table 100
PostUp = ip -6 rule add from ${CLIENT_SUBNET6}::/64 lookup 100
PostUp = ip6tables -A FORWARD -i awg1 -o awg0 -j ACCEPT
PostUp = ip6tables -A FORWARD -i awg0 -o awg1 -j ACCEPT
PostUp = ip6tables -t nat -A POSTROUTING -o awg0 -j MASQUERADE
PostDown = ip -6 rule del from ${CLIENT_SUBNET6}::/64 lookup 100
PostDown = ip -6 route del default dev awg0 table 100
PostDown = ip -6 route del ${TUNNEL_B_IP6}/128 dev awg0
PostDown = ip6tables -D FORWARD -i awg1 -o awg0 -j ACCEPT
PostDown = ip6tables -D FORWARD -i awg0 -o awg1 -j ACCEPT
PostDown = ip6tables -t nat -D POSTROUTING -o awg0 -j MASQUERADE"
    B_V6_ADDR="Address = ${TUNNEL_B_IP6}/128"
    B_V6_ALLOWED=", ${TUNNEL_A_IP6}/128"
    B_V6_POST="PostUp = ip6tables -A FORWARD -i awg0 -j ACCEPT
PostUp = ip6tables -A FORWARD -o awg0 -j ACCEPT
PostUp = ip6tables -t nat -A POSTROUTING -o $DE_IFACE -j MASQUERADE
PostDown = ip6tables -D FORWARD -i awg0 -j ACCEPT
PostDown = ip6tables -D FORWARD -o awg0 -j ACCEPT
PostDown = ip6tables -t nat -D POSTROUTING -o $DE_IFACE -j MASQUERADE"
fi

# --- Конфиги awg0 ---
say "Настройка туннеля awg0"
cat > "$AWG_DIR/awg0.conf" <<EOF
[Interface]
PrivateKey = $(cat "$AWG_DIR/private.key")
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
S3 = $((RANDOM % 50 + 12))
S4 = $((RANDOM % 50 + 12))
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
$A_V6_POST
PostDown = ip rule del from $CLIENT_SUBNET.0/24 lookup 100
PostDown = ip route del default dev awg0 table 100
PostDown = ip route del $TUNNEL_B_IP/32 dev awg0
PostDown = iptables -D FORWARD -i awg1 -o awg0 -j ACCEPT
PostDown = iptables -D FORWARD -i awg0 -o awg1 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o awg0 -j MASQUERADE
PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_CLAMP 2>/dev/null || true

[Peer]
PublicKey = $DE_PUB
Endpoint = $NB_IP:$AWG_TUNNEL_PORT
AllowedIPs = 0.0.0.0/0$A_V6_ALLOWED
PersistentKeepalive = 25
EOF
chmod 600 "$AWG_DIR/awg0.conf"

cat > /tmp/awg0-de.conf <<EOF
[Interface]
PrivateKey = $(run_b "cat $AWG_DIR/private.key" | tr -d '\r')
Address = $TUNNEL_B_IP/32
$B_V6_ADDR
ListenPort = $AWG_TUNNEL_PORT
MTU = $MTU_AWG0
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
S3 = $((RANDOM % 50 + 12))
S4 = $((RANDOM % 50 + 12))
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
$B_V6_POST
PostDown = iptables -D FORWARD -i awg0 -j ACCEPT
PostDown = iptables -D FORWARD -o awg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o $DE_IFACE -j MASQUERADE
PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_CLAMP 2>/dev/null || true

[Peer]
PublicKey = $RU_PUB
AllowedIPs = $TUNNEL_A_IP/32$B_V6_ALLOWED
EOF
scp_b /tmp/awg0-de.conf "$AWG_DIR/awg0.conf"
run_b "chmod 600 $AWG_DIR/awg0.conf"
cp /tmp/awg0-de.conf "$AWG_DIR/awg0-de.conf.copy"
chmod 600 "$AWG_DIR/awg0-de.conf.copy"
rm -f /tmp/awg0-de.conf

# --- awg1: убираем правила прямого NAT (маршрутизация переезжает в awg0) ---
sed -i '/^PostUp =/d; /^PostDown =/d' "$AWG_DIR/awg1.conf"

# --- Запуск ---
say "Запуск туннеля"
run_b "systemctl enable awg-quick@awg0 && systemctl restart awg-quick@awg0" || rollback
sleep 2
systemctl enable awg-quick@awg0
systemctl restart awg-quick@awg0 || rollback
sleep 3
systemctl restart awg-quick@awg1 || rollback
ping -c 3 -W 3 "$TUNNEL_B_IP" >/dev/null 2>&1 || rollback
[[ $TUN_V6 -eq 1 ]] && { ping -6 -c 3 -W 3 "$TUNNEL_B_IP6" >/dev/null 2>&1 || rollback; }
ok "Туннель awg0 работает"

# --- SSH-ключ A→B (бэкапы, управление) ---
[[ ! -f /root/.ssh/id_ed25519 ]] && ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519 -q
A_PUBKEY=$(cat /root/.ssh/id_ed25519.pub)
run_b "mkdir -p /root/.ssh && chmod 700 /root/.ssh && touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && grep -qxF '$A_PUBKEY' /root/.ssh/authorized_keys || echo '$A_PUBKEY' >> /root/.ssh/authorized_keys" \
    && ok "SSH-ключ A → B установлен" \
    || warn "Ключ не установлен — бэкапы на B работать не будут"

# --- Обновление констант ---
sed -i '/^INSTALL_MODE=/d; /^SERVER_B_IP=/d; /^SERVER_B_PORT=/d; /^SERVER_B_USER=/d; /^SERVER_B_IFACE=/d; /^AWG_TUNNEL_PORT=/d; /^TUNNEL_A_IP=/d; /^TUNNEL_B_IP=/d; /^BACKUP_HOST=/d; /^BACKUP_PORT=/d; /^BACKUP_USER=/d; /^TUNNEL_A_IP6=/d; /^TUNNEL_B_IP6=/d; /^MTU_AWG0=/d' "$CASCADE_ENV"
cat >> "$CASCADE_ENV" <<EOF
INSTALL_MODE="3"
AWG_TUNNEL_PORT="$AWG_TUNNEL_PORT"
TUNNEL_A_IP="$TUNNEL_A_IP"
TUNNEL_B_IP="$TUNNEL_B_IP"
TUNNEL_A_IP6="$TUNNEL_A_IP6"
TUNNEL_B_IP6="$TUNNEL_B_IP6"
MTU_AWG0="$MTU_AWG0"
SERVER_B_IP="$NB_IP"
SERVER_B_PORT="$NB_PORT"
SERVER_B_USER="$NB_USER"
SERVER_B_IFACE="$DE_IFACE"
BACKUP_HOST="$NB_IP"
BACKUP_PORT="$NB_PORT"
BACKUP_USER="$NB_USER"
EOF

# Панель читает cascade.env при старте
systemctl restart amnezia-panel 2>/dev/null || true
rm -f /tmp/awg1.conf.pre-cascade

echo ""
echo "=============================================="
echo " Каскад A → B настроен и работает"
echo " SERVER-B: $NB_IP, туннель awg0: порт $AWG_TUNNEL_PORT/udp"
echo " Совет: выполните deploy.sh --update, чтобы доустановить"
echo " helper-скрипты, healthcheck и бэкапы для каскадного режима."
echo "=============================================="
