#!/usr/bin/env bash
# Parse the PLAY RECAP line(s) from an ansible-pull log file.
# Output: JSON with the 5 counters. Used by the wrapper to build the
# completion-POST body. Tolerates multiple hosts (sums them).
#
# Usage: parse-play-recap.sh <log_file>

set -euo pipefail
LOG="${1:?need log path}"

# Grab the PLAY RECAP section (last occurrence wins)
recap=$(awk '/^PLAY RECAP/,/^$/' "$LOG" | tail -n +2 | grep -v '^$' || true)

ok=0 changed=0 failed=0 skipped=0 unreachable=0
while read -r line; do
  [[ -z "$line" ]] && continue
  for kv in $line; do
    case "$kv" in
      ok=*)          ok=$((ok + ${kv#ok=})) ;;
      changed=*)     changed=$((changed + ${kv#changed=})) ;;
      failed=*)      failed=$((failed + ${kv#failed=})) ;;
      skipped=*)     skipped=$((skipped + ${kv#skipped=})) ;;
      unreachable=*) unreachable=$((unreachable + ${kv#unreachable=})) ;;
    esac
  done
done <<< "$recap"

jq -nc \
  --argjson ok "$ok" --argjson changed "$changed" \
  --argjson failed "$failed" --argjson skipped "$skipped" \
  --argjson unreachable "$unreachable" \
  '{ok:$ok, changed:$changed, failed:$failed, skipped:$skipped, unreachable:$unreachable}'
