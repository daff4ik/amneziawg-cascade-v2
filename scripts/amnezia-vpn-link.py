#!/usr/bin/env python3
# =====================================================================
#  amnezia-vpn-link.py <client.conf> <server_name>
#  Конвертирует .conf клиента AmneziaWG в vpn:// ссылку AmneziaVPN.
#  Используется amnezia-add-client.sh и amnezia-proto-amnezia-dns.sh.
# =====================================================================
import sys, json, zlib, base64

conf_path = sys.argv[1]
server_name = sys.argv[2]

with open(conf_path, 'r', encoding='utf-8') as f:
    content = f.read()

interface_params = {}
peer_params = {}
current_section = None

for line in content.splitlines():
    line = line.strip()
    if not line or line.startswith('#') or line.startswith(';'):
        continue
    if line.startswith('[') and line.endswith(']'):
        current_section = line[1:-1].strip().lower()
        continue
    if '=' in line:
        k, v = line.split('=', 1)
        k, v = k.strip(), v.strip()
        # При дублировании ключа (например, два Address: IPv4 и IPv6) берём первый
        if current_section == 'interface':
            interface_params.setdefault(k, v)
        elif current_section == 'peer':
            peer_params.setdefault(k, v)

endpoint = peer_params.get('Endpoint', '')
if ':' in endpoint:
    host_name, port_str = endpoint.rsplit(':', 1)
    port = int(port_str)
else:
    host_name = endpoint
    port = 51820

dns_str = interface_params.get('DNS', '1.1.1.1, 1.0.0.1')
dns_parts = [d.strip() for d in dns_str.split(',')]
dns1 = dns_parts[0] if len(dns_parts) > 0 else '1.1.1.1'
dns2 = dns_parts[1] if len(dns_parts) > 1 else '1.0.0.1'

client_ip_raw = interface_params.get('Address', '').split('/')[0]

awg_keys = [
    "DisableCookies", "H1", "H2", "H3", "H4", "HeaderProtectionKey", "I1", "I2", "I3", "I4", "I5",
    "Jc", "Jmax", "Jmin", "KeepaliveTimeout", "MaxHandshakeAttempts", "RandomTrailers",
    "RejectAfterTime", "RekeyAfterTime", "RekeyTimeout", "S1", "S2", "S3", "S4"
]

awg_params = {}
for k in awg_keys:
    if k in interface_params:
        awg_params[k] = interface_params[k]

last_config_obj = dict(awg_params)
last_config_obj.update({
    "allowed_ips": [ip.strip() for ip in peer_params.get('AllowedIPs', '0.0.0.0/0').split(',')],
    "client_ip": client_ip_raw,
    "client_priv_key": interface_params.get('PrivateKey', ''),
    "client_pub_key": "",
    "config": content,
    "hostName": host_name,
    "port": port,
    "server_pub_key": peer_params.get('PublicKey', '')
})

awg_container = dict(awg_params)
awg_container.update({
    "last_config": json.dumps(last_config_obj, ensure_ascii=False),
    "port": str(port),
    "protocol_version": "3.1",
    "subnet_address": "10.8.0.0",
    "transport_proto": "udp"
})

full_json = {
    "containers": [
        {
            "awg": awg_container,
            "container": "amnezia-awg2"
        }
    ],
    "defaultContainer": "amnezia-awg2",
    "description": server_name,
    "dns1": dns1,
    "dns2": dns2,
    "format_version": 1,
    "hostName": host_name
}

json_bytes = json.dumps(full_json, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
header = len(json_bytes).to_bytes(4, byteorder='big')
compressed = zlib.compress(json_bytes, level=9)
payload = header + compressed
b64 = base64.urlsafe_b64encode(payload).decode('utf-8')

print(f"vpn://{b64}")
