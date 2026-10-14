#!/usr/bin/env bash
set -Eeuo pipefail

source_dir=/opt/minecraft-bedrock
instance_dir=/opt/minecraft-bedrock-19132
unit_name=minecraft-bedrock-19132.service
staged_dir=/tmp/minecraft-bedrock-19132-deploy

test "$(id -u)" -eq 0
test -x "$source_dir/bedrock_server"
id minecraft >/dev/null
test ! -e "$instance_dir"
test ! -e "/etc/systemd/system/$unit_name"
test -f "$staged_dir/minecraft-bedrock-19132.properties"
test -f "$staged_dir/$unit_name"
if ss -H -lun | grep -Eq '(^|[.:])19132([[:space:]]|$)'; then
    echo "UDP port 19132 is already occupied" >&2
    exit 1
fi

install -d -o minecraft -g minecraft -m 0750 "$instance_dir"
install -o minecraft -g minecraft -m 0750 "$source_dir/bedrock_server" "$instance_dir/bedrock_server"
for item in behavior_packs data definitions resource_packs treatments world_templates profanity_filter.wlist; do
    test -e "$source_dir/$item"
    cp -a "$source_dir/$item" "$instance_dir/"
done
install -d -o minecraft -g minecraft -m 0750 "$instance_dir/config"
install -o minecraft -g minecraft -m 0640 "$staged_dir/minecraft-bedrock-19132.properties" "$instance_dir/server.properties"
printf '[]\n' > "$instance_dir/allowlist.json"
printf '[]\n' > "$instance_dir/permissions.json"
chown -R minecraft:minecraft "$instance_dir"
install -o root -g root -m 0644 "$staged_dir/$unit_name" "/etc/systemd/system/$unit_name"

systemctl daemon-reload
systemctl enable --now "$unit_name"
for _ in $(seq 1 30); do
    if systemctl is-active --quiet "$unit_name"; then
        break
    fi
    sleep 1
done
systemctl is-active --quiet "$unit_name"
for _ in $(seq 1 30); do
    if ss -H -ltn | grep -Eq '(^|[.:])10079([[:space:]]|$)'; then
        break
    fi
    sleep 1
done
ss -H -ltn | grep -Eq '(^|[.:])10079([[:space:]]|$)'

echo '--- service ---'
systemctl --no-pager --full status "$unit_name"
echo '--- UDP listener ---'
ss -H -lntup | grep -E '(^|[.:])(10079|19132)([[:space:]]|$)' || true
echo '--- startup log ---'
journalctl -u "$unit_name" -n 40 --no-pager | grep -E 'Version:|Accepting clients|Server started|ERROR|error|Failed|failed' || true
