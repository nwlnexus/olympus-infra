#!/usr/bin/env bash
# Checks the stale-branch refusal pattern in .github/workflows/automerge.yml.
set -euo pipefail
wf="$(dirname "$0")/../workflows/automerge.yml"
re=$(sed -n "s/^ *REFUSAL_RE='\(.*\)'$/\1/p" "$wf")
[ -n "$re" ] || { echo "REFUSAL_RE not found in $wf"; exit 1; }
fail=0
check() { # expected(0|1) text
  if printf '%s' "$2" | grep -Eiq "$re"; then got=0; else got=1; fi
  if [ "$got" != "$1" ]; then echo "FAIL (want $1): $2"; fail=1; else echo "ok: $2"; fi
}
check 0 'gh: Required status check "CI gate" is expected. (HTTP 405)'
check 0 'gh: Base branch was modified. Review and try the merge again. (HTTP 405)'
check 0 'gh: Required status check "CI gate" is expected.'
check 0 'gh: Base branch was modified. Review and try the merge again.'
check 1 'gh: Head branch was modified. Review and try the merge again. (HTTP 409)'
check 1 'gh: Resource not accessible by integration (HTTP 403)'
check 1 'gh: Not Found (HTTP 404)'
exit "$fail"
