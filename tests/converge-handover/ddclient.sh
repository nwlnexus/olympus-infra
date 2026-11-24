#!/usr/bin/env bash
# Converge handover of the ddclient role (olympus-sdk#1155): run playbooks/pull/olympus.yml --tags ddclient
# in --check mode in an Ubuntu 24.04 container (ddclient_state present, a dummy vault token so no
# 1Password read is attempted)
#   managed = converge_managed_roles unset       -> the ddclient role runs
#   handed  = converge_managed_roles [ddclient]  -> none of its tasks run; the baseline name check passes
# Needs podman. Nothing touches a real host; the container has no network, so the managed run's
# Cloudflare lookup fails locally (expected) and nothing reaches Cloudflare.
#
#   tests/converge-handover/ddclient.sh    (exit 1 on an unexpected result)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
work=$(mktemp -d)
trap 'podman rm -f w6g-ddclient >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

podman build -q -t olympus-infra-handover -f - "$here" >/dev/null <<'CF'
FROM docker.io/library/ubuntu:24.04
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq systemd systemd-sysv ansible \
    openssh-server fail2ban unattended-upgrades chrony ufw logrotate sudo python3-apt >/dev/null && apt-get clean
RUN useradd -m -s /bin/bash ansible
CMD ["/sbin/init"]
CF
podman run -d --name w6g-ddclient --systemd=always --network=none -v "$repo:/src:ro" olympus-infra-handover >/dev/null
sleep 3
# The pull playbook's pre_tasks only check that these exist.
podman exec w6g-ddclient sh -c 'mkdir -p /etc/olympus && touch /etc/olympus/op-service-account-token /etc/olympus/hermes-disabled'

run() { # <name> [extra vars json]
  podman exec -w /src -e ANSIBLE_STDOUT_CALLBACK=json -e ANSIBLE_ROLES_PATH=/src/roles -e ANSIBLE_LOCALHOST_WARNING=false \
    w6g-ddclient ansible-playbook -i localhost, -c local --check --tags ddclient \
    -e '{"ddclient_state":"present","ddclient_cf_api_token":"dummy-not-a-token"}' ${2:+-e "$2"} \
    playbooks/pull/olympus.yml >"$work/$1.json" || true
  python3 "$here/summarize.py" <"$work/$1.json" >"$work/$1.txt"
}
run managed
run handed '{"converge_managed_roles":["ddclient"]}'

echo "== managed (expected: the ddclient role runs)"; cat "$work/managed.txt"
echo "== handed (expected: no ddclient task runs, no failure)"; cat "$work/handed.txt"

fail=0
for t in 'Set ddclient state' 'Use vault-provided Cloudflare token'; do
  grep -q -E "^(ok|changed)	ddclient : $t\$" "$work/managed.txt" || { echo "FAIL: '$t' did not run without the handover"; fail=1; }
done
grep -q -E '^(ok|changed|failed)	ddclient : ' "$work/handed.txt" && { echo "FAIL: a ddclient task ran with ddclient handed to converge"; fail=1; }
grep -q -F 'ok	baseline : Converge handover — check the names' "$work/handed.txt" || { echo "FAIL: the name check did not pass with ddclient listed"; fail=1; }
grep -q '^failed' "$work/handed.txt" && { echo "FAIL: a task failed with ddclient handed to converge"; fail=1; }
[ "$fail" = 0 ] && echo "PASS"
exit "$fail"
