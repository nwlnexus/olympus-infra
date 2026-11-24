#!/usr/bin/env bash
# Converge handover test (olympus-sdk#341): run roles/baseline in --check mode in an Ubuntu 24.04
# container (distro ansible, systemd as PID 1) three times and compare the task results:
#   base  = origin/main's roles, converge_managed_roles unset
#   empty = this tree, converge_managed_roles unset   -> must equal base (plus the two handover tasks
#           and the ssh-access include, split out of ssh.yml)
#   full  = this tree, every converge role listed     -> only the mapped tasks drop out
# Needs podman. Nothing touches a real host.
#
#   tests/converge-handover/run.sh [base-ref]    (exit 1 on an unexpected result)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
ref=${1:-origin/main}
work=$(mktemp -d)
trap 'podman rm -f w4e-handover >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

mkdir -p "$work/base"
git -C "$repo" archive "$ref" roles | tar -x -C "$work/base"

podman build -q -t olympus-infra-handover -f - "$here" >/dev/null <<'CF'
FROM docker.io/library/ubuntu:24.04
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq systemd systemd-sysv ansible \
    openssh-server fail2ban unattended-upgrades chrony ufw logrotate sudo python3-apt >/dev/null && apt-get clean
RUN useradd -m -s /bin/bash ansible
CMD ["/sbin/init"]
CF
podman run -d --name w4e-handover --systemd=always \
  -v "$repo:/src:ro" -v "$work/base/roles:/base-roles:ro" olympus-infra-handover >/dev/null
sleep 3

run() { # <name> <roles path> [extra vars json]
  podman exec -e ANSIBLE_STDOUT_CALLBACK=json -e ANSIBLE_ROLES_PATH="$2" -e ANSIBLE_LOCALHOST_WARNING=false \
    w4e-handover ansible-playbook -i localhost, -c local --check --skip-tags baseline-op-cli \
    ${3:+-e "$3"} /src/tests/converge-handover/site.yml >"$work/$1.json" || true
  python3 "$here/summarize.py" <"$work/$1.json" >"$work/$1.txt"
}
all='{"converge_managed_roles":["sshd","unattended-upgrades","fail2ban","timesync","base-packages","firewall","base-sysctl","motd","ansible-account","ansible-ssh-key","iscsi","ddclient"]}'
run base /base-roles
run empty /src/roles
run full /src/roles "$all"
run typo /src/roles '{"converge_managed_roles":["sshd","fail2bam"]}'

echo "== base vs empty (expected: only the two 'Converge handover' tasks and the ssh-access include added)"
diff "$work/base.txt" "$work/empty.txt" || true
echo "== empty vs full (expected: only the mapped tasks gone or skipped)"
diff "$work/empty.txt" "$work/full.txt" || true
echo "== typo (expected: the name check fails)"
grep -E 'failed|handover' "$work/typo.txt" || true

# Assertions (exit 1 on an unexpected result).
fail=0
added=$(diff "$work/base.txt" "$work/empty.txt" | grep -c '^[<>]' || true)
expected_added=$(diff "$work/base.txt" "$work/empty.txt" | grep -c -E '^> ok\s+baseline : (Converge handover — |baseline — ansible account SSH access$)' || true)
[ "$added" = 3 ] && [ "$expected_added" = 3 ] || { echo "FAIL: base vs empty differs beyond the handover tasks"; fail=1; }
for t in 'baseline — ansible account SSH access' 'Ensure ansible user .local/bin exists' 'Configure logrotate for ansible-pull logs'; do
  grep -q -F "$t" "$work/full.txt" || { echo "FAIL: '$t' missing with every role listed"; fail=1; }
done
for t in 'baseline — SSH hardening' 'baseline — fail2ban' 'baseline — unattended upgrades' 'baseline — time sync' 'baseline — firewall (UFW)' 'Install logrotate'; do
  grep -q -E "^skipped	baseline : ${t//(/\\(}" "$work/full.txt" || { echo "FAIL: '$t' not skipped with every role listed"; fail=1; }
done
grep -q -F 'failed	baseline : Converge handover — check the names' "$work/typo.txt" || { echo "FAIL: a typo did not fail the run"; fail=1; }
[ "$fail" = 0 ] && echo "PASS"
exit "$fail"
