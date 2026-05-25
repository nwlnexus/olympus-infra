#!/usr/bin/env bats
# BATS tests for roles/ansible-pull/templates/ansible-pull-run.j2
#
# The template is rendered with tests/bin/render-wrapper.sh before each run,
# producing a sandbox-ready bash script. WRAPPER_* env vars redirect every
# filesystem path the wrapper touches into a per-test temp dir. PATH is
# salted so the wrapper's `curl` resolves to tests/bats/helpers/mock-curl.sh.
#
# Requires: bats, jq. Skips cleanly if either is missing on PATH.

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq required"

  TEST_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  RENDER="$TEST_ROOT/tests/bin/render-wrapper.sh"
  TEMPLATE="$TEST_ROOT/templates/ansible-pull-run.j2"
  PARSER="$TEST_ROOT/files/parse-play-recap.sh"
  FIXTURES="$TEST_ROOT/tests/fixtures"
  MOCK_CURL="$TEST_ROOT/tests/bats/helpers/mock-curl.sh"

  TMPDIR="$(mktemp -d)"
  WRAPPER="$TMPDIR/ansible-pull-run"

  # Sandbox paths the wrapper will use
  export WRAPPER_HERMES_TOKEN_FILE="$TMPDIR/etc/olympus/hermes-token"
  export WRAPPER_HERMES_DISABLED_FLAG="$TMPDIR/etc/olympus/hermes-disabled"
  export WRAPPER_CACHE_DIR="$TMPDIR/var/lib/olympus"
  export WRAPPER_PENDING_DIR="$TMPDIR/var/lib/olympus/pending-completions"
  export WRAPPER_RUNTIME_DIR="$TMPDIR/run/olympus"
  export WRAPPER_LOG_DIR="$TMPDIR/var/log"
  export WRAPPER_LOG_FILE="$TMPDIR/var/log/run.log"
  export WRAPPER_OP_TOKEN_FILE="$TMPDIR/opt/ansible-pull/.op-service-account-token"
  export WRAPPER_PARSER="$PARSER"

  mkdir -p "$TMPDIR/etc/olympus" "$TMPDIR/opt/ansible-pull" "$TMPDIR/var/log"

  # OP token must exist or the wrapper bails before reaching Hermes logic
  echo "fake-op-token" > "$WRAPPER_OP_TOKEN_FILE"
  echo "fake-hermes-token" > "$WRAPPER_HERMES_TOKEN_FILE"

  # Render the wrapper with /bin/true as the "ansible-pull" binary so the
  # actual pull step exits 0 without doing anything.
  "$RENDER" "$TEMPLATE" "$WRAPPER" --bin-linux=/bin/true

  # Salt PATH so the wrapper picks up mock-curl. The mock honors MOCK_*
  # env vars set per-test.
  mkdir -p "$TMPDIR/path-shim"
  ln -s "$MOCK_CURL" "$TMPDIR/path-shim/curl"
  export PATH="$TMPDIR/path-shim:$PATH"
  export MOCK_CURL_LOG="$TMPDIR/curl.log"
}

teardown() {
  [[ -n "${TMPDIR:-}" && -d "$TMPDIR" ]] && rm -rf "$TMPDIR"
}

@test "fatal exit (78) when hermes-token missing" {
  rm -f "$WRAPPER_HERMES_TOKEN_FILE"
  run bash "$WRAPPER"
  [ "$status" -eq 78 ]
}

@test "uses cached classify on Hermes outage" {
  cp "$FIXTURES/classify-ok.json" "$WRAPPER_CACHE_DIR/classify.json" \
    || { mkdir -p "$WRAPPER_CACHE_DIR" && cp "$FIXTURES/classify-ok.json" "$WRAPPER_CACHE_DIR/classify.json"; }
  MOCK_RESPONSE_FAIL=1 run bash "$WRAPPER"
  # ansible-pull mocked to /bin/true → RC=0; no run_id → no completion path
  [ "$status" -eq 0 ]
  grep -q "using cache" "$WRAPPER_LOG_FILE"
}

@test "exits EX_TEMPFAIL (75) when Hermes unreachable + no cache" {
  # Ensure no cache file exists
  mkdir -p "$WRAPPER_CACHE_DIR"
  rm -f "$WRAPPER_CACHE_DIR/classify.json"
  MOCK_RESPONSE_FAIL=1 run bash "$WRAPPER"
  [ "$status" -eq 75 ]
}

@test "materializes 5 vars files when classify ok" {
  export MOCK_RESP_START_RUN="$FIXTURES/start-run-resp.json"
  export MOCK_RESP_CLASSIFY="$FIXTURES/classify-ok.json"
  # Pre-create the log so the parser has something to read post-run
  cp "$FIXTURES/play-recap-sample.log" "$WRAPPER_LOG_FILE"
  export MOCK_RESP_LOG_UPLOAD="$FIXTURES/start-run-resp.json"   # any JSON works
  export MOCK_RESP_COMPLETE="$FIXTURES/start-run-resp.json"
  run bash "$WRAPPER"
  [ "$status" -eq 0 ]
  [ -f "$WRAPPER_RUNTIME_DIR/00-global.yml" ]
  [ -f "$WRAPPER_RUNTIME_DIR/10-tags.yml" ]
  [ -f "$WRAPPER_RUNTIME_DIR/20-roles.yml" ]
  [ -f "$WRAPPER_RUNTIME_DIR/30-host.yml" ]
  [ -f "$WRAPPER_RUNTIME_DIR/99-roles.yml" ]
  grep -q 'hermes_extra_roles' "$WRAPPER_RUNTIME_DIR/99-roles.yml"
}

@test "hermes-disabled flag short-circuits Hermes calls" {
  touch "$WRAPPER_HERMES_DISABLED_FLAG"
  run bash "$WRAPPER"
  [ "$status" -eq 0 ]
  [ -f "$WRAPPER_RUNTIME_DIR/99-roles.yml" ]
  grep -q '^hermes_extra_roles: \[\]' "$WRAPPER_RUNTIME_DIR/99-roles.yml"
  # No curl calls should have been made
  if [[ -f "$MOCK_CURL_LOG" ]]; then
    ! grep -q '/v1/pull/' "$MOCK_CURL_LOG"
  fi
}

@test "parse-play-recap.sh sums counters across hosts" {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  tmp_log="$TMPDIR/sample.log"
  cat > "$tmp_log" <<'EOF'
PLAY RECAP *********************************************************************
host-a                     : ok=10  changed=2  unreachable=0  failed=0  skipped=3  rescued=0  ignored=0
host-b                     : ok=5   changed=1  unreachable=1  failed=2  skipped=0  rescued=0  ignored=0

EOF
  out=$("$BATS_TEST_DIRNAME/../../files/parse-play-recap.sh" "$tmp_log")
  [ "$(echo "$out" | jq -r .ok)" -eq 15 ]
  [ "$(echo "$out" | jq -r .changed)" -eq 3 ]
  [ "$(echo "$out" | jq -r .failed)" -eq 2 ]
  [ "$(echo "$out" | jq -r .unreachable)" -eq 1 ]
}
