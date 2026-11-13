#!/bin/bash
# =====================================================================
#  amnezia-add-client.sh
#  Создаёт конфиг нового клиента AmneziaWG, генерирует .conf и vpn:// ссылку.
#  Плейсхолдеры __SERVER_ENDPOINT__, __SERVER_NAME__, __CLIENT_MTU__,
#  __DNS_SERVERS__ подставляет deploy.sh.
# =====================================================================
set -euo pipefail

AWG_DIR="/etc/amnezia/amneziawg"
AWG_IFACE="awg1"
SERVER_ENDPOINT="__SERVER_ENDPOINT__"
SERVER_NAME="__SERVER_NAME__"
CLIENT_MTU="__CLIENT_MTU__"
DNS_SERVERS="__DNS_SERVERS__"
SERVER_PUBKEY_FILE="$AWG_DIR/awg1_public.key"
CLIENTS_DIR="/root/clients"

# === Общие константы каскада (пишет deploy.sh) ===
CASCADE_ENV="/etc/amnezia-cascade.env"
[[ -f "$CASCADE_ENV" ]] && source "$CASCADE_ENV"
SUBNET_PREFIX="${CLIENT_SUBNET:-10.8.0}"
IPV6_ENABLED="${IPV6_ENABLED:-0}"
CLIENT_SUBNET6="${CLIENT_SUBNET6:-fd00:10:8}"
DNS6="${CLIENT_DNS6:-2606:4700:4700::1111, 2606:4700:4700::1001}"

# === Проверка прав ===
[[ $EUID -ne 0 ]] && { echo "Ошибка: запускать от root (sudo $0)"; exit 1; }
[[ ! -f "$SERVER_PUBKEY_FILE" ]] && { echo "Ошибка: нет файла $SERVER_PUBKEY_FILE"; exit 1; }

# === Имя клиента ===
CLIENT_NAME=""
if [[ $# -ge 1 ]]; then
    CLIENT_NAME="$1"
else
    echo "=============================================="
    echo " Создание нового клиента AmneziaWG"
    echo "=============================================="
    read -p "Введите имя клиента (буквы, цифры, _, -): " CLIENT_NAME
fi

CLIENT_SAFE=$(echo "$CLIENT_NAME" | sed 's/[^a-zA-Z0-9_-]//g')
[[ -z "$CLIENT_SAFE" ]] && { echo "Ошибка: имя должно содержать только латиницу, цифры, _ или -"; exit 1; }

mkdir -p "$CLIENTS_DIR" && chmod 700 "$CLIENTS_DIR"

# === Проверка существования ===
if [[ -f "$CLIENTS_DIR/${CLIENT_SAFE}.conf" ]] || grep -qxF "# Client: $CLIENT_SAFE" "$AWG_DIR/$AWG_IFACE.conf"; then
    echo "Ошибка: клиент '$CLIENT_SAFE' уже существует!"
    exit 1
fi

# === Поиск свободного IP ===
GREP_PREFIX=$(echo "$SUBNET_PREFIX" | sed 's/\./\\./g')
USED_IPS=$(grep -oP "AllowedIPs\\s*=\\s*\\K${GREP_PREFIX}\\.[0-9]+" "$AWG_DIR/$AWG_IFACE.conf" | awk -F. '{print $4}' || true)
CLIENT_IP_LAST=""
for i in $(seq 2 254); do
    echo "$USED_IPS" | grep -qx "$i" || { CLIENT_IP_LAST=$i; break; }
done
[[ -z "$CLIENT_IP_LAST" ]] && { echo "Ошибка: нет свободных IP в $SUBNET_PREFIX.0/24"; exit 1; }
CLIENT_IP="${SUBNET_PREFIX}.${CLIENT_IP_LAST}"

# === IPv6 (если включён на сервере) ===
CLIENT_ADDRESS_LINES="Address = ${CLIENT_IP}/32"
CLIENT_DNS_LINE="$DNS_SERVERS"
SERVER_ALLOWED_IPS="${CLIENT_IP}/32"
if [[ "$IPV6_ENABLED" == "1" ]]; then
    CLIENT_IP6="${CLIENT_SUBNET6}::${CLIENT_IP_LAST}"
    CLIENT_ADDRESS_LINES="$CLIENT_ADDRESS_LINES
Address = ${CLIENT_IP6}/128"
    CLIENT_DNS_LINE="$CLIENT_DNS_LINE, $DNS6"
    SERVER_ALLOWED_IPS="$SERVER_ALLOWED_IPS, ${CLIENT_IP6}/128"
fi

# === Генерация ключей клиента ===
CLIENT_PRIV=$(awg genkey)
CLIENT_PUB=$(echo "$CLIENT_PRIV" | awg pubkey)

# === Уникальный I1 (маскировочный пакет под DNS) ===
I1=$(python3 - <<'PYEOF'
import os, random
domains = ["google.com","cloudflare.com","yandex.ru","mail.ru","apple.com",
           "icloud.com","amazon.com","microsoft.com","github.com","wikipedia.org",
           "bing.com","duckduckgo.com","mozilla.org","debian.org","ubuntu.com"]
d = random.choice(domains)
labels = d.split(".")
h  = "8580" + "0001" + "0001" + "0000" + "0000"
for lbl in labels:
    h += f"{len(lbl):02x}" + lbl.encode().hex()
h += "00" + "0001" + "0001"
h += "c00c" + "0001" + "0001" + "0000105a" + "0004" + os.urandom(4).hex()
print(f"<r 2><b 0x{h}>")
PYEOF
)

# === Параметры обфускации берём из awg1.conf ===
PARAMS=$(awk '/^\[Interface\]/{f=1;next} /^\[/{f=0} f' "$AWG_DIR/$AWG_IFACE.conf" \
  | grep -E '^(Jc|Jmin|Jmax|S1|S2|S3|S4|H1|H2|H3|H4|HeaderProtectionKey|ContentPaddingAddition|RekeyAfterTime|RekeyTimeout|RejectAfterTime|KeepaliveTimeout|MaxHandshakeAttempts|RandomTrailers|DisableCookies)\s*=' \
  | sed 's/^[[:space:]]*//')

# === Файл клиента ===
CONF="$CLIENTS_DIR/${CLIENT_SAFE}.conf"
cat > "$CONF" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIV
$CLIENT_ADDRESS_LINES
MTU = $CLIENT_MTU
DNS = $CLIENT_DNS_LINE
$PARAMS
I1 = $I1

[Peer]
PublicKey = $(cat "$SERVER_PUBKEY_FILE")
Endpoint = $SERVER_ENDPOINT
AllowedIPs = 0.0.0.0/0$( [[ "$IPV6_ENABLED" == "1" ]] && echo ", ::/0" )
PersistentKeepalive = 25
EOF
chmod 600 "$CONF"

# === Добавление peer на сервере ===
cat >> "$AWG_DIR/$AWG_IFACE.conf" <<EOF

[Peer]
# Client: $CLIENT_SAFE
PublicKey = $CLIENT_PUB
AllowedIPs = $SERVER_ALLOWED_IPS
EOF

# === Перезапуск ===
systemctl restart "awg-quick@$AWG_IFACE"

echo ""
echo "=============================================="
echo " Клиент '$CLIENT_SAFE' успешно создан"
echo " IP: $CLIENT_IP"
echo " Конфиг: $CONF"
echo "=============================================="
cat "$CONF"

if command -v qrencode >/dev/null 2>&1; then
    echo ""
    echo " QR-код (.conf):"
    qrencode -t ansiutf8 < "$CONF"
fi

# =======================================================
#  Конвертация в vpn:// для AmneziaVPN
# =======================================================
echo ""
read -p "Сконвертировать в vpn:// ссылку Amnezia? (y/n): " CONVERT_ANSWER
case "$CONVERT_ANSWER" in
    [yY]|[yY][eE][sS]|[дД]|[дД][aA])
        echo ""
        echo "Генерация vpn:// ссылки..."

        VPN_LINK=$(/usr/local/bin/amnezia-vpn-link.py "$CONF" "$SERVER_NAME")

        VPN_FILE="$CLIENTS_DIR/${CLIENT_SAFE}.vpn.txt"
        echo "$VPN_LINK" > "$VPN_FILE"
        chmod 600 "$VPN_FILE"

        echo ""
        echo "=============================================="
        echo " Amnezia VPN Link ($CLIENT_SAFE):"
        echo " Имя сервера: $SERVER_NAME"
        echo " Сохранено в файл: $VPN_FILE"
        echo "=============================================="
        echo "$VPN_LINK"
        echo "=============================================="

        if command -v qrencode >/dev/null 2>&1; then
            echo ""
            echo " QR-код для Amnezia (vpn://):"
            qrencode -t ansiutf8 "$VPN_LINK"
        fi
        ;;
    *)
        echo "Конвертация пропущена."
        ;;
esac