#!/usr/bin/env bash
# Stand-in for ansible-pull in BATS tests.
#
# - Appends its argv (one arg per line, then a "--" separator) to
#   $MOCK_PULL_ARGS when set.
# - Fails with exit 5 (ansible's "bad options" code) if any
#   `--extra-vars @file` is missing or is not a YAML/JSON mapping, which is
#   what real ansible does.
# - Prints a PLAY RECAP and exits with $MOCK_PULL_RC (default 0).
set -euo pipefail

# - Records the names of OP_* variables it received in $MOCK_PULL_ENV when set.
if [[ -n "${MOCK_PULL_ENV:-}" ]]; then
  env | grep -o '^OP_[A-Z_]*' | sort >> "$MOCK_PULL_ENV" || true
fi
if [[ -n "${MOCK_PULL_ARGS:-}" ]]; then
  printf '%s\n' "$@" -- >> "$MOCK_PULL_ARGS"
fi

prev=""
for arg in "$@"; do
  if [[ "$prev" == "--extra-vars" && "$arg" == @* ]]; then
    f="${arg#@}"
    if [[ ! -f "$f" ]]; then
      echo "ERROR! the file_name '$f' does not exist, or is not readable"
      exit 5
    fi
    if ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
      echo "ERROR! Invalid extra vars data supplied. '@$f' could not be made into a dictionary"
      exit 5
    fi
  fi
  prev="$arg"
done

echo "PLAY RECAP *********************************************************************"
echo "testhost                   : ok=3    changed=1    unreachable=0    failed=0    skipped=2    rescued=0    ignored=0"
echo
exit "${MOCK_PULL_RC:-0}"
