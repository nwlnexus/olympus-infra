#!/usr/bin/env bash
# Render the ansible-pull-run.j2 template to a bash script for BATS testing.
# Performs the minimum subset of Jinja substitution that the template needs:
#
#   - Variable refs:    {{ name | default('X') }}, {{ name }}
#   - One-liner if:     {% if ansible_pull_limit | default('') != '' %}...{% endif %}
#
# This is NOT a full Jinja implementation. It is deliberately scoped to the
# token shapes that appear in roles/ansible-pull/templates/ansible-pull-run.j2.
# If the template grows new Jinja constructs, extend this helper or commit a
# pre-rendered fixture instead.
#
# Usage:
#   render-wrapper.sh <template> <output> [--bin-linux=/path/to/ansible-pull]
#
# Variables consumed (with bake-in defaults for the test fixture):
#   hermes_url           = http://localhost:18080
#   ansible_pull_log_dir = $LOG_DIR  (left as env var so WRAPPER_LOG_DIR wins)
#   ansible_pull_log_file= $LOG_FILE
#   ansible_pull_bin_linux = first --bin-linux=... arg, else /bin/true
#   ansible_pull_repo    = file:///dev/null
#   ansible_pull_inventory = inventory/test.yml
#   ansible_pull_playbook= playbooks/test.yml
#   ansible_pull_limit   = "" (the {% if %} branch evaluates to empty)

set -euo pipefail

TEMPLATE="${1:?need template path}"
OUTPUT="${2:?need output path}"
shift 2

# Resolve a portable `true` so tests run on macOS (/usr/bin/true) and Linux
# (/bin/true). Caller can override with --bin-linux=/path.
BIN_LINUX="$(command -v true)"
for arg in "$@"; do
  case "$arg" in
    --bin-linux=*) BIN_LINUX="${arg#--bin-linux=}" ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# Read the template
content=$(cat "$TEMPLATE")

# 1. Strip the {% if ansible_pull_limit %} branch — limit is empty in tests so
#    the conditional evaluates to "" and the line collapses to just the
#    backslash-continuation + playbook path.
#
#    The template has the if-block as the sole content of its own line:
#        {% if ansible_pull_limit | default('') != '' %}--limit ... \{% endif %}
#    so dropping the whole line is safe and avoids leaving a stray
#    "  \n  \n" pair that bash would parse as a missing command.
content=$(printf '%s' "$content" | perl -0777 -pe 's/^[ \t]*\{%\s*if\s+ansible_pull_limit\s*\|\s*default\([^)]*\)\s*!=\s*\x27\x27\s*%\}.*?\{%\s*endif\s*%\}[ \t]*\n//gm')

# 2. Substitute simple {{ var }} and {{ var | default('X') }} forms.
#    Use perl with a hash table for substitutions.
content=$(printf '%s' "$content" | perl -pe '
  s{\{\{\s*hermes_url\s*\|\s*default\(\x27([^\x27]*)\x27\)\s*\}\}}{$1}g;
  s{\{\{\s*ansible_pull_log_dir\s*\}\}}{/tmp/render-default-log-dir}g;
  s{\{\{\s*ansible_pull_log_file\s*\}\}}{/tmp/render-default-log-file}g;
  s{\{\{\s*ansible_pull_bin_linux\s*\}\}}{'"$BIN_LINUX"'}g;
  s{\{\{\s*ansible_pull_repo\s*\}\}}{file:///dev/null}g;
  s{\{\{\s*ansible_pull_inventory\s*\}\}}{inventory/test.yml}g;
  s{\{\{\s*ansible_pull_playbook\s*\}\}}{playbooks/test.yml}g;
')

# 3. Verify no Jinja constructs remain. If any survive, the wrapper would be
#    syntactically invalid bash — fail loudly so the test author knows to
#    extend this helper.
if printf '%s' "$content" | grep -qE '\{\{|\{%'; then
  echo "render-wrapper.sh: unresolved Jinja constructs remain in output:" >&2
  printf '%s' "$content" | grep -nE '\{\{|\{%' >&2
  exit 3
fi

# 4. Write output and mark executable
printf '%s' "$content" > "$OUTPUT"
chmod +x "$OUTPUT"
