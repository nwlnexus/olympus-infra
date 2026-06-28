#!/usr/bin/env bash
# mem0-recall-hook.sh — SessionStart auto-recall hook for OpenMemory/Mem0.
#
# Reads the Claude Code hook stdin (JSON with session metadata), extracts the
# working directory as the search query, POSTs to the Mem0 /filter endpoint,
# and emits a SessionStart additionalContext JSON blob with the top-k hits.
#
# FAIL OPEN: any error (timeout, non-200, bad JSON, missing tool) results in
# {"continue":true} and exit 0 — this hook MUST NEVER block session start.
#
# Overridable via env:
#   MEM0_URL        — base URL of the OpenMemory API
#   MEM0_USER_ID    — Mem0 user_id (shared persona)
#   MEM0_TOP_K      — number of memories to retrieve
#
# The hook stdin JSON shape is {"session_id":"...","cwd":"...","...":...}.

set -euo pipefail

MEM0_URL="${MEM0_URL:-http://openmemory.raptor-mimosa.ts.net:8765}"
MEM0_USER_ID="${MEM0_USER_ID:-mnemosyne}"
MEM0_TOP_K="${MEM0_TOP_K:-5}"
FILTER_ENDPOINT="${MEM0_URL}/api/v1/memories/filter"

# Emit continue-only JSON and exit cleanly — used on any error path.
fail_open() {
    printf '{"continue":true}\n'
    exit 0
}

# Read stdin (may be empty in some invocation modes).
stdin_data=""
if read -t 2 -r line 2>/dev/null; then
    stdin_data="$line"
    # Drain remaining lines without blocking.
    while IFS= read -t 0.1 -r extra 2>/dev/null; do
        stdin_data="${stdin_data}${extra}"
    done
fi

# Extract cwd from stdin JSON as the search query. Fall back to PWD.
search_query=""
if [ -n "$stdin_data" ] && command -v python3 >/dev/null 2>&1; then
    search_query="$(printf '%s' "$stdin_data" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    cwd = d.get('cwd', '') or d.get('workingDirectory', '') or ''
    print(cwd.strip())
except Exception:
    print('')
" 2>/dev/null || true)"
fi
search_query="${search_query:-${PWD:-}}"

# Nothing to search — bail open.
if [ -z "$search_query" ]; then
    fail_open
fi

# Build POST body. python3 is used to ensure proper JSON escaping.
if ! command -v python3 >/dev/null 2>&1; then
    fail_open
fi

post_body="$(python3 -c "
import json, sys
body = {
    'user_id': sys.argv[1],
    'search_query': sys.argv[2],
    'page': 1,
    'size': int(sys.argv[3]),
}
print(json.dumps(body))
" "$MEM0_USER_ID" "$search_query" "$MEM0_TOP_K" 2>/dev/null)" || fail_open

# POST to the filter endpoint with a hard 2-second wall-clock limit.
response="$(curl \
    --silent \
    --show-error \
    --connect-timeout 1 \
    --max-time 2 \
    --request POST \
    --header "Content-Type: application/json" \
    --data "$post_body" \
    --write-out '\n%{http_code}' \
    "$FILTER_ENDPOINT" 2>/dev/null)" || fail_open

# Split body from HTTP status code (last line).
http_status="$(printf '%s' "$response" | tail -1)"
response_body="$(printf '%s' "$response" | head -n -1)"

if [ "$http_status" != "200" ]; then
    fail_open
fi

# Parse the response and format the top-k memories.
context_text="$(python3 -c "
import json, sys

try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(1)

items = data.get('items', [])
total = data.get('total', 0)

if not items or total == 0:
    sys.exit(0)

lines = ['## Recalled memories (Mem0 — mnemosyne)']
for i, item in enumerate(items, 1):
    memory = item.get('memory', '') or item.get('text', '') or str(item)
    memory = memory.strip().replace('\n', ' ')
    if memory:
        lines.append(f'{i}. {memory}')

if len(lines) > 1:
    print('\n'.join(lines))
" <<< "$response_body" 2>/dev/null)" || fail_open

# If no memories (empty but valid response), still continue cleanly.
if [ -z "$context_text" ]; then
    printf '{"continue":true}\n'
    exit 0
fi

# Emit the SessionStart additionalContext JSON.
python3 -c "
import json, sys
context = sys.argv[1]
output = {
    'hookSpecificOutput': {
        'hookEventName': 'SessionStart',
        'additionalContext': context,
    }
}
print(json.dumps(output))
" "$context_text" 2>/dev/null || fail_open
