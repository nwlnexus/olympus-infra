#!/bin/bash
# Managed by Ansible (tailscale role) — do not edit manually
#
# Restarts tailscaled when it is logged in but has lost its control-plane
# connection. Seen on data-hub: tailscaled stayed "Running" with Self.Online=false
# for days (map long-poll wedged), so the node dropped off the tailnet while the
# service-manager saw a healthy process. Run by a LaunchDaemon every few minutes.
#
# Acts only when BackendState is Running and Self.Online is false (or the daemon
# does not answer) for TS_WATCHDOG_THRESHOLD consecutive runs, and at most once
# per TS_WATCHDOG_COOLDOWN seconds. A stopped or logged-out node is left alone:
# a restart cannot fix that.
#
# Every setting has a TS_WATCHDOG_* override so the test script can drive it.
set -u

TS_BIN="${TS_WATCHDOG_TS_BIN:-/opt/homebrew/bin/tailscale}"
STATE_DIR="${TS_WATCHDOG_STATE_DIR:-/var/db/tailscale-watchdog}"
LOG_FILE="${TS_WATCHDOG_LOG_FILE:-/var/log/tailscale-watchdog.log}"
THRESHOLD="${TS_WATCHDOG_THRESHOLD:-3}"
COOLDOWN="${TS_WATCHDOG_COOLDOWN:-3600}"
RESTART_CMD="${TS_WATCHDOG_RESTART_CMD:-launchctl kickstart -k system/homebrew.mxcl.tailscale}"
NOW="${TS_WATCHDOG_NOW:-$(date +%s)}"
PYTHON="${TS_WATCHDOG_PYTHON:-/usr/bin/python3}"

log() { printf '%s tailscale-watchdog: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG_FILE" 2>/dev/null || true; }

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
COUNT_FILE="$STATE_DIR/offline_count"
RESTART_FILE="$STATE_DIR/last_restart"

read_num() { local v; v=$(cat "$1" 2>/dev/null || echo 0); case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac; }

# `tailscale status` can hang when the daemon is wedged; give it 20 seconds.
status_json=$(perl -e 'alarm 20; exec @ARGV' -- "$TS_BIN" status --json 2>/dev/null)
rc=$?

verdict="unresponsive"
if [ "$rc" -eq 0 ] && [ -n "$status_json" ]; then
  verdict=$(printf '%s' "$status_json" | "$PYTHON" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("unresponsive"); sys.exit()
if d.get("BackendState") != "Running":
    print("not-running")
elif (d.get("Self") or {}).get("Online") is False:
    print("offline")
else:
    print("online")
' 2>/dev/null || echo unresponsive)
fi

case "$verdict" in
  online|not-running)
    # Healthy, or stopped / needs login: nothing a restart can fix.
    [ "$(read_num "$COUNT_FILE")" -gt 0 ] && log "recovered (state: $verdict)"
    echo 0 > "$COUNT_FILE"
    exit 0
    ;;
esac

count=$(( $(read_num "$COUNT_FILE") + 1 ))
echo "$count" > "$COUNT_FILE"

if [ "$count" -lt "$THRESHOLD" ]; then
  log "$verdict ($count/$THRESHOLD)"
  exit 0
fi

last=$(read_num "$RESTART_FILE")
if [ $(( NOW - last )) -lt "$COOLDOWN" ]; then
  log "$verdict ($count/$THRESHOLD) but last restart was $(( NOW - last ))s ago (cooldown ${COOLDOWN}s); not restarting"
  exit 0
fi

log "$verdict for $count checks; restarting tailscaled: $RESTART_CMD"
echo "$NOW" > "$RESTART_FILE"
echo 0 > "$COUNT_FILE"
if ! sh -c "$RESTART_CMD" >> "$LOG_FILE" 2>&1; then
  log "restart command failed"
  exit 1
fi
exit 0
