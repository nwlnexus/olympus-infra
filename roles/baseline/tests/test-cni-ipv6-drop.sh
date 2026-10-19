#!/bin/bash
# Idempotency test for files/olympus-cni-ipv6-drop inside a throwaway network
# namespace (needs root: uses `sudo -n`). Run: roles/baseline/tests/test-cni-ipv6-drop.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../files/olympus-cni-ipv6-drop"
NS="olympus-test-$$"
fails=0
sudo -n ip netns add "$NS" || { echo "cannot create netns (needs sudo/root)"; exit 2; }
trap 'sudo -n ip netns del "$NS" 2>/dev/null' EXIT

run() { sudo -n ip netns exec "$NS" "$SCRIPT" "$@"; }
count() { sudo -n ip netns exec "$NS" ip6tables -S | grep -c "olympus-cni-ipv6-drop"; }
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (expected $2, got $3)"; fails=$((fails+1)); fi; }

check "starts empty" 0 "$(count)"
out=$(run apply); check "first apply adds INPUT and FORWARD" "added INPUT added FORWARD" "$(echo $out)"
check "two rules present" 2 "$(count)"
out=$(run apply); check "second apply is a no-op" "" "$out"
check "still two rules" 2 "$(count)"
run status >/dev/null; check "status ok when present" 0 $?
sudo -n ip netns exec "$NS" ip6tables -D INPUT -i cni0 -m comment --comment olympus-cni-ipv6-drop -j DROP
out=$(run apply); check "apply repairs one missing rule" "added INPUT" "$(echo $out)"
out=$(run remove); check "remove deletes both" "removed INPUT removed FORWARD" "$(echo $out)"
check "none left" 0 "$(count)"
out=$(run remove); check "remove is idempotent" "" "$out"
run status >/dev/null; check "status fails when missing" 1 $?
sudo -n ip netns exec "$NS" ip6tables -S INPUT | grep -q -- "-i cni0" && check "rule absent after remove" absent present || check "rule absent after remove" absent absent

[ "$fails" -eq 0 ] && echo "PASS: olympus-cni-ipv6-drop" || { echo "$fails failure(s)"; exit 1; }
