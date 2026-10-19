#!/bin/bash
# Behavioural test for files/tailscale-watchdog.sh. Needs bash, perl, python3.
# Run: roles/tailscale/tests/test-watchdog.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WD="$HERE/../files/tailscale-watchdog.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0

mk_ts() { # $1 = JSON to print (or "FAIL")
  if [ "$1" = FAIL ]; then printf '#!/bin/sh\nexit 1\n' > "$T/ts"
  else printf '#!/bin/sh\ncat <<JSON\n%s\nJSON\n' "$1" > "$T/ts"; fi
  chmod +x "$T/ts"
}
run() { # $1 = now
  TS_WATCHDOG_TS_BIN="$T/ts" TS_WATCHDOG_STATE_DIR="$T/state" TS_WATCHDOG_LOG_FILE="$T/log" \
  TS_WATCHDOG_RESTART_CMD="echo restarted >> $T/restarts" TS_WATCHDOG_THRESHOLD=3 \
  TS_WATCHDOG_COOLDOWN=3600 TS_WATCHDOG_NOW="$1" "$WD"
}
restarts() { [ -f "$T/restarts" ] && wc -l < "$T/restarts" | tr -d ' ' || echo 0; }
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (expected $2, got $3)"; fails=$((fails+1)); fi
}
reset() { rm -rf "$T/state" "$T/restarts" "$T/log"; }

OFFLINE='{"BackendState":"Running","Self":{"Online":false}}'
ONLINE='{"BackendState":"Running","Self":{"Online":true}}'

reset; mk_ts "$ONLINE"; run 10000; run 10300; check "online never restarts" 0 "$(restarts)"

reset; mk_ts "$OFFLINE"; run 10000; run 10300; check "offline below threshold does not restart" 0 "$(restarts)"
run 10600; check "third consecutive offline restarts" 1 "$(restarts)"

reset; mk_ts "$OFFLINE"; run 10000; run 10300; mk_ts "$ONLINE"; run 10600; mk_ts "$OFFLINE"; run 10900; run 11200
check "recovery resets the counter" 0 "$(restarts)"

reset; mk_ts "$OFFLINE"; run 10000; run 10300; run 10600; run 10900; run 11200; run 11500
check "cooldown blocks a second restart" 1 "$(restarts)"
run 20000; run 20300; run 20600; check "restarts again after the cooldown" 2 "$(restarts)"

reset; mk_ts '{"BackendState":"NeedsLogin","Self":{"Online":false}}'; run 10000; run 10300; run 10600; run 10900
check "logged-out node is left alone" 0 "$(restarts)"

reset; mk_ts '{"BackendState":"Stopped","Self":{"Online":false}}'; run 10000; run 10300; run 10600
check "stopped node is left alone" 0 "$(restarts)"

reset; mk_ts FAIL; run 10000; run 10300; run 10600
check "unresponsive daemon counts as offline" 1 "$(restarts)"

reset; mk_ts 'not json'; run 10000; run 10300; run 10600
check "garbage output counts as unresponsive" 1 "$(restarts)"

[ "$fails" -eq 0 ] && echo "PASS: tailscale-watchdog" || { echo "$fails failure(s)"; exit 1; }
