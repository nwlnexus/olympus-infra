#!/usr/bin/env bash
# Render ansible-pull-run.j2 to a bash script for BATS testing.
#
# Uses real Jinja2 with the same block handling as Ansible's template module
# (trim_blocks=True, lstrip_blocks=False), so whitespace/line-continuation
# bugs in the template show up in the rendered script exactly as on a host.
#
# Usage:
#   render-wrapper.sh <template> <output> [--os=Linux|Darwin] [--limit=STR]
#                     [--skip-tags=STR] [--bin-linux=PATH]
#
# Exit codes: 0 ok, 2 bad args, 4 python3/jinja2 unavailable (callers skip).

set -euo pipefail

TEMPLATE="${1:?need template path}"
OUTPUT="${2:?need output path}"
shift 2

OS_FAMILY="Linux"
LIMIT=""
SKIP_TAGS=""
BIN_LINUX="$(command -v true)"
for arg in "$@"; do
  case "$arg" in
    --os=*)        OS_FAMILY="${arg#--os=}" ;;
    --limit=*)     LIMIT="${arg#--limit=}" ;;
    --skip-tags=*) SKIP_TAGS="${arg#--skip-tags=}" ;;
    --bin-linux=*) BIN_LINUX="${arg#--bin-linux=}" ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

PYTHON="${RENDER_PYTHON:-python3}"
if ! "$PYTHON" -c 'import jinja2' >/dev/null 2>&1; then
  echo "render-wrapper.sh: $PYTHON with jinja2 is required" >&2
  exit 4
fi

TEMPLATE="$TEMPLATE" OUTPUT="$OUTPUT" OS_FAMILY="$OS_FAMILY" LIMIT="$LIMIT" SKIP_TAGS="$SKIP_TAGS" \
BIN_LINUX="$BIN_LINUX" "$PYTHON" - <<'PY'
import os
import jinja2

env = jinja2.Environment(
    trim_blocks=True,
    lstrip_blocks=False,
    keep_trailing_newline=True,
    undefined=jinja2.StrictUndefined,
)
with open(os.environ["TEMPLATE"]) as fh:
    tmpl = env.from_string(fh.read())

ctx = {
    "ansible_facts": {"os_family": os.environ["OS_FAMILY"]},
    "ansible_pull_user": "ansible",
    "ansible_pull_repo": "file:///dev/null",
    "ansible_pull_inventory": "inventory/test.yml",
    "ansible_pull_playbook": "playbooks/test.yml",
    "ansible_pull_limit": os.environ["LIMIT"],
    "ansible_pull_skip_tags": os.environ["SKIP_TAGS"],
    "ansible_pull_bin_linux": os.environ["BIN_LINUX"],
    "ansible_pull_bin_macos": os.environ["BIN_LINUX"],
    "ansible_pull_log_dir": "/tmp/render-default-log-dir",
    "ansible_pull_log_file": "/tmp/render-default-log-dir/run.log",
    "ansible_pull_state_dir": "/tmp/render-default-state-dir",
    "ansible_pull_runtime_dir": "/tmp/render-default-state-dir/run",
}
with open(os.environ["OUTPUT"], "w") as fh:
    fh.write(tmpl.render(**ctx))
PY
chmod +x "$OUTPUT"
