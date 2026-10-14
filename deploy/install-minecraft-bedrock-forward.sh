#!/usr/bin/env bash
set -Eeuo pipefail

base=/opt/minecraft-bedrock
stamp=$(date +%Y%m%d-%H%M%S)

test -f "$base/server.properties"
id minecraft >/dev/null

systemctl stop minecraft-bedrock.service || true
mkdir -p "$base/backups"
cp -a "$base/server.properties" "$base/server.properties.bak.codex-forward-$stamp"

python3 - <<'PY'
from pathlib import Path

path = Path('/opt/minecraft-bedrock/server.properties')
updates = {
    'server-port': '29132',
    'server-portv6': '29133',
    'transport': 'nethernet',
    'server-udp-ports': '27551,211.154.18.253:7551:27551',
}
lines = path.read_text().splitlines()
seen = set()
out = []
for line in lines:
    key, sep, _value = line.partition('=')
    if sep and key in updates:
        out.append(f'{key}={updates[key]}')
        seen.add(key)
    else:
        out.append(line)
for key, value in updates.items():
    if key not in seen:
        out.append(f'{key}={value}')
path.write_text('\n'.join(out) + '\n')
PY

install -d -m 0755 /usr/local/libexec
install -o root -g root -m 0755 /tmp/minecraft-bedrock-forward.py /usr/local/libexec/minecraft-bedrock-forward.py
install -o root -g root -m 0644 /tmp/minecraft-bedrock-forward.service /etc/systemd/system/minecraft-bedrock-forward.service
install -d -m 0755 /etc/systemd/system/minecraft-bedrock.service.d
if [ -f /etc/systemd/system/minecraft-bedrock.service.d/forwarder.conf ]; then
    cp -a /etc/systemd/system/minecraft-bedrock.service.d/forwarder.conf \
        "/etc/systemd/system/minecraft-bedrock.service.d/forwarder.conf.bak.$stamp"
fi
printf '%s\n' '[Unit]' \
    'Requires=minecraft-bedrock-forward.service' \
    'After=minecraft-bedrock-forward.service' \
    > /etc/systemd/system/minecraft-bedrock.service.d/forwarder.conf

chown minecraft:minecraft "$base/server.properties"
systemctl daemon-reload
systemctl enable minecraft-bedrock-forward.service >/dev/null
systemctl enable minecraft-bedrock.service >/dev/null
systemctl reset-failed minecraft-bedrock-forward.service minecraft-bedrock.service || true
systemctl start minecraft-bedrock.service

for _ in $(seq 1 20); do
    if systemctl is-active --quiet minecraft-bedrock.service; then
        break
    fi
    sleep 1
done

echo '--- service states ---'
systemctl is-active minecraft-bedrock-forward.service
systemctl is-active minecraft-bedrock.service
echo '--- properties ---'
grep -E '^(server-port|server-portv6|transport|server-udp-ports)=' "$base/server.properties"
echo '--- sockets ---'
ss -H -lntup | grep -E ':(19132|29132|7551|27551)([[:space:]]|$)' || true
echo '--- minecraft log ---'
journalctl -u minecraft-bedrock.service -n 80 --no-pager | \
    grep -E 'Version:|Opening level|Accepting clients|Server started|ERROR|error|Failed|failed' || true
echo '--- forwarder log ---'
journalctl -u minecraft-bedrock-forward.service -n 40 --no-pager || true
