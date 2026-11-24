#!/usr/bin/env bash
# Converge handover of the iscsi role (olympus-sdk#345): run playbooks/pull/olympus.yml --tags iscsi in
# --check mode in an Ubuntu 24.04 container (as a k3s node: iscsi_state present, iscsi_mode csi_node)
#   managed = converge_managed_roles unset     -> the iscsi role's csi_node tasks run
#   handed  = converge_managed_roles [iscsi]   -> none of them run; the baseline name check passes
# Needs podman. Nothing touches a real host.
#
#   tests/converge-handover/iscsi.sh    (exit 1 on an unexpected result)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
work=$(mktemp -d)
trap 'podman rm -f w6b-iscsi >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

# As run.sh's image plus the packages the csi_node tasks start (a k3s node has them).
podman build -q -t olympus-infra-handover-iscsi -f - "$here" >/dev/null <<'CF'
FROM docker.io/library/ubuntu:24.04
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq systemd systemd-sysv ansible \
    openssh-server fail2ban unattended-upgrades chrony ufw logrotate sudo python3-apt open-iscsi multipath-tools >/dev/null && apt-get clean
RUN useradd -m -s /bin/bash ansible
CMD ["/sbin/init"]
CF
podman run -d --name w6b-iscsi --systemd=always -v "$repo:/src:ro" olympus-infra-handover-iscsi >/dev/null
sleep 3
# The pull playbook's pre_tasks only check that these exist.
podman exec w6b-iscsi sh -c 'mkdir -p /etc/olympus && touch /etc/olympus/op-service-account-token /etc/olympus/hermes-disabled'

run() { # <name> [extra vars json]
  podman exec -w /src -e ANSIBLE_STDOUT_CALLBACK=json -e ANSIBLE_ROLES_PATH=/src/roles -e ANSIBLE_LOCALHOST_WARNING=false \
    w6b-iscsi ansible-playbook -i localhost, -c local --check --tags iscsi \
    -e '{"iscsi_state":"present","iscsi_mode":"csi_node"}' ${2:+-e "$2"} playbooks/pull/olympus.yml >"$work/$1.json" || true
  python3 "$here/summarize.py" <"$work/$1.json" >"$work/$1.txt"
}
run managed
run handed '{"converge_managed_roles":["iscsi"]}'

echo "== managed (expected: the csi_node tasks run)"; cat "$work/managed.txt"
echo "== handed (expected: the csi_node tasks skipped, no failure)"; cat "$work/handed.txt"

fail=0
csi=('Set deterministic iSCSI initiator name' 'Install iSCSI and multipath packages' 'Enable and start iscsid'
     'Configure multipath.conf for Trident' 'Enable and start multipathd')
for t in "${csi[@]}"; do
  grep -q -E "^(ok|changed)	iscsi : $t\$" "$work/managed.txt" || { echo "FAIL: '$t' did not run without the handover"; fail=1; }
  grep -q -E "^(ok|changed)	iscsi : $t\$" "$work/handed.txt" && { echo "FAIL: '$t' ran with iscsi handed to converge"; fail=1; }
done
grep -q -F 'ok	baseline : Converge handover — check the names' "$work/handed.txt" || { echo "FAIL: the name check did not pass with iscsi listed"; fail=1; }
grep -q '^failed' "$work/handed.txt" && { echo "FAIL: a task failed with iscsi handed to converge"; fail=1; }
[ "$fail" = 0 ] && echo "PASS"
exit "$fail"
