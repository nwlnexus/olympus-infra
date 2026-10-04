#!/usr/bin/env bats
# BATS tests for roles/ansible-pull/templates/ansible-pull-run.j2
#
# The template is rendered with tests/bin/render-wrapper.sh (real Jinja2,
# Ansible's block settings) before each test. WRAPPER_* env vars redirect
# every filesystem path the wrapper touches into a per-test temp dir. PATH is
# salted so `curl` resolves to tests/bats/helpers/mock-curl.sh, and
# WRAPPER_ANSIBLE_PULL_BIN points at tests/bats/helpers/mock-ansible-pull.sh,
# which validates the --extra-vars files the way ansible does.
#
# Requires: bats, jq, python3 with jinja2. Skips cleanly if any is missing.

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq required"

  TEST_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  RENDER="$TEST_ROOT/tests/bin/render-wrapper.sh"
  TEMPLATE="$TEST_ROOT/templates/ansible-pull-run.j2"
  PARSER="$TEST_ROOT/files/parse-play-recap.sh"
  FIXTURES="$TEST_ROOT/tests/fixtures"
  MOCK_CURL="$TEST_ROOT/tests/bats/helpers/mock-curl.sh"
  MOCK_PULL="$TEST_ROOT/tests/bats/helpers/mock-ansible-pull.sh"

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
  export WRAPPER_OP_TOKEN_FILE="$TMPDIR/etc/olympus/op-service-account-token"
  export WRAPPER_OP_CONNECT_TOKEN_FILE="$TMPDIR/etc/olympus/op-connect-token"
  export WRAPPER_PARSER="$PARSER"
  export WRAPPER_ANSIBLE_PULL_BIN="$MOCK_PULL"
  export MOCK_PULL_ARGS="$TMPDIR/pull-args"
  unset STATE_DIRECTORY RUNTIME_DIRECTORY MOCK_PULL_RC

  mkdir -p "$TMPDIR/etc/olympus" "$TMPDIR/var/log"

  echo "fake-op-token" > "$WRAPPER_OP_TOKEN_FILE"
  echo "fake-hermes-token" > "$WRAPPER_HERMES_TOKEN_FILE"

  render
  # Salt PATH so the wrapper picks up mock-curl. The mock honors MOCK_*
  # env vars set per-test.
  mkdir -p "$TMPDIR/path-shim"
  ln -s "$MOCK_CURL" "$TMPDIR/path-shim/curl"
  export PATH="$TMPDIR/path-shim:$PATH"
  export MOCK_CURL_LOG="$TMPDIR/curl.log"
}

# render [render-wrapper.sh options...] — (re)render the wrapper under test.
render() {
  local rc=0
  "$RENDER" "$TEMPLATE" "$WRAPPER" "$@" || rc=$?
  [[ "$rc" -eq 4 ]] && skip "python3 with jinja2 required to render the template"
  [[ "$rc" -eq 0 ]]
}

teardown() {
  if [[ -n "${TMPDIR:-}" && -d "$TMPDIR" ]]; then
    chmod -R u+rwx "$TMPDIR" 2>/dev/null || true
    rm -rf "$TMPDIR"
  fi
}

skip_if_root() {
  [[ "$(id -u)" -ne 0 ]] || skip "permission checks are meaningless as root"
}

# The value following $1 in the mock's recorded argv.
pull_arg_after() {
  awk -v k="$1" 'found { print; exit } $0 == k { found = 1 }' "$MOCK_PULL_ARGS"
}

@test "rendered Linux and Darwin wrappers are valid bash" {
  bash -n "$WRAPPER"
  render --os=Darwin
  bash -n "$WRAPPER"
  grep -q 'stat -f %Sm' "$WRAPPER"
}

@test "fatal exit (78) when hermes-token missing" {
  rm -f "$WRAPPER_HERMES_TOKEN_FILE"
  run bash "$WRAPPER"
  [ "$status" -eq 78 ]
  [[ "$output" == *"Hermes token missing"* ]]
}

@test "uses cached classify on Hermes outage" {
  mkdir -p "$WRAPPER_CACHE_DIR"
  cp "$FIXTURES/classify-ok.json" "$WRAPPER_CACHE_DIR/classify.json"
  MOCK_RESPONSE_FAIL=1 run bash "$WRAPPER"
  # no run_id → no completion path; the mock ansible-pull exits 0
  [ "$status" -eq 0 ]
  grep -q "using cache" "$WRAPPER_LOG_FILE"
}

@test "exits EX_TEMPFAIL (75) when Hermes unreachable + no cache" {
  mkdir -p "$WRAPPER_CACHE_DIR"
  rm -f "$WRAPPER_CACHE_DIR/classify.json"
  MOCK_RESPONSE_FAIL=1 run bash "$WRAPPER"
  [ "$status" -eq 75 ]
}

@test "materializes 5 vars files when classify ok" {
  export MOCK_RESP_START_RUN="$FIXTURES/start-run-resp.json"
  export MOCK_RESP_CLASSIFY="$FIXTURES/classify-ok.json"
  export MOCK_RESP_LOG_UPLOAD="$FIXTURES/start-run-resp.json"   # any JSON works
  export MOCK_RESP_COMPLETE="$FIXTURES/start-run-resp.json"
  run bash "$WRAPPER"
  [ "$status" -eq 0 ]
  for f in 00-global 10-tags 20-roles 30-host 99-roles; do
    jq -e 'type == "object"' "$WRAPPER_RUNTIME_DIR/$f.yml"
  done
  [ "$(jq -r .foo "$WRAPPER_RUNTIME_DIR/00-global.yml")" = "bar" ]
  [ "$(jq -r .plex_root "$WRAPPER_RUNTIME_DIR/20-roles.yml")" = "/srv/plex" ]
  [ "$(jq -c .hermes_extra_roles "$WRAPPER_RUNTIME_DIR/99-roles.yml")" = '["plex"]' ]
}

@test "empty classify vars still produce parseable vars files" {
  echo '{"extra_roles": [], "etag": "e"}' > "$TMPDIR/classify-empty.json"
  export MOCK_RESP_CLASSIFY="$TMPDIR/classify-empty.json"
  run bash "$WRAPPER"
  [ "$status" -eq 0 ]
  [ "$(cat "$WRAPPER_RUNTIME_DIR/00-global.yml")" = "{}" ]
  [ "$(cat "$WRAPPER_RUNTIME_DIR/10-tags.yml")" = "{}" ]
}

@test "hermes-disabled: no Hermes calls, all vars files exist and parse" {
  touch "$WRAPPER_HERMES_DISABLED_FLAG"
  rm -f "$WRAPPER_HERMES_TOKEN_FILE"
  # stale file from an earlier Hermes-enabled run must not leak in
  mkdir -p "$WRAPPER_RUNTIME_DIR"
  echo 'hermes_extra_roles: ["plex"]' > "$WRAPPER_RUNTIME_DIR/99-roles.yml"
  run bash "$WRAPPER"
  [ "$status" -eq 0 ]
  for f in 00-global 10-tags 20-roles 30-host 99-roles; do
    jq -e 'type == "object"' "$WRAPPER_RUNTIME_DIR/$f.yml"
  done
  [ "$(jq -c .hermes_extra_roles "$WRAPPER_RUNTIME_DIR/99-roles.yml")" = "[]" ]
  if [[ -f "$MOCK_CURL_LOG" ]]; then
    ! grep -q '/v1/pull/' "$MOCK_CURL_LOG"
  fi
}

@test "missing OP token is a visible failure, not a silent skip" {
  rm -f "$WRAPPER_OP_TOKEN_FILE"
  run bash "$WRAPPER"
  [ "$status" -eq 78 ]
  [[ "$output" == *"[FATAL] OP service-account token not found"* ]]
  grep -q 'FATAL' "$WRAPPER_LOG_FILE"
  [ ! -f "$MOCK_PULL_ARGS" ]
}

@test "unreadable Connect token fails with EX_NOPERM (77)" {
  skip_if_root
  echo "connect-token" > "$WRAPPER_OP_CONNECT_TOKEN_FILE"
  chmod 000 "$WRAPPER_OP_CONNECT_TOKEN_FILE"
  run bash "$WRAPPER"
  [ "$status" -eq 77 ]
  [[ "$output" == *"not readable"* ]]
}

@test "readable Connect token is preferred over the service account" {
  touch "$WRAPPER_HERMES_DISABLED_FLAG"
  echo "connect-token" > "$WRAPPER_OP_CONNECT_TOKEN_FILE"
  run bash "$WRAPPER"
  [ "$status" -eq 0 ]
  grep -q 'using Connect' "$WRAPPER_LOG_FILE"
}

@test "unwritable state directory fails with EX_CANTCREAT (73)" {
  skip_if_root
  mkdir -p "$TMPDIR/ro"
  chmod 555 "$TMPDIR/ro"
  export WRAPPER_CACHE_DIR="$TMPDIR/ro/olympus"
  export WRAPPER_PENDING_DIR="$TMPDIR/ro/olympus/pending-completions"
  run bash "$WRAPPER"
  [ "$status" -eq 73 ]
  [[ "$output" == *"state directory $TMPDIR/ro/olympus is missing or not writable"* ]]
  [ ! -f "$MOCK_PULL_ARGS" ]
}

@test "systemd STATE_DIRECTORY / RUNTIME_DIRECTORY are used when no override" {
  touch "$WRAPPER_HERMES_DISABLED_FLAG"
  unset WRAPPER_CACHE_DIR WRAPPER_PENDING_DIR WRAPPER_RUNTIME_DIR
  export STATE_DIRECTORY="$TMPDIR/systemd/state"
  export RUNTIME_DIRECTORY="$TMPDIR/systemd/run"
  run bash "$WRAPPER"
  [ "$status" -eq 0 ]
  [ -d "$STATE_DIRECTORY/pending-completions" ]
  [ -f "$RUNTIME_DIRECTORY/99-roles.yml" ]
  [ "$(pull_arg_after --extra-vars)" = "@$RUNTIME_DIRECTORY/00-global.yml" ]
}

@test "ansible-pull failure propagates its exit code and is logged" {
  touch "$WRAPPER_HERMES_DISABLED_FLAG"
  MOCK_PULL_RC=2 run bash "$WRAPPER"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ansible-pull FAILED with exit code 2"* ]]
  grep -q 'ansible-pull FAILED with exit code 2' "$WRAPPER_LOG_FILE"
  grep -q 'PLAY RECAP' "$WRAPPER_LOG_FILE"
}

@test "--limit renders on its own line and the playbook stays last" {
  render --limit='$(hostname -s)'
  touch "$WRAPPER_HERMES_DISABLED_FLAG"
  run bash "$WRAPPER"
  [ "$status" -eq 0 ]
  [ "$(pull_arg_after --limit)" = "$(hostname -s)" ]
  # last recorded arg before the "--" separator is the playbook
  [ "$(grep -v '^--$' "$MOCK_PULL_ARGS" | tail -n 1)" = "playbooks/test.yml" ]
}

@test "--skip-tags is passed through when configured" {
  render --limit=myhost --skip-tags=common,tailscale
  touch "$WRAPPER_HERMES_DISABLED_FLAG"
  run bash "$WRAPPER"
  [ "$status" -eq 0 ]
  [ "$(pull_arg_after --skip-tags)" = "common,tailscale" ]
  [ "$(pull_arg_after --limit)" = "myhost" ]
  [ "$(grep -v '^--$' "$MOCK_PULL_ARGS" | tail -n 1)" = "playbooks/test.yml" ]
}

@test "completion counters cover only this run, not the whole log history" {
  cp "$FIXTURES/play-recap-sample.log" "$WRAPPER_LOG_FILE"
  export MOCK_RESP_START_RUN="$FIXTURES/start-run-resp.json"
  export MOCK_RESP_CLASSIFY="$FIXTURES/classify-ok.json"
  export MOCK_RESP_LOG_UPLOAD="$FIXTURES/start-run-resp.json"
  export MOCK_RESP_COMPLETE="$FIXTURES/start-run-resp.json"
  run bash "$WRAPPER"
  [ "$status" -eq 0 ]
  # the sample log already holds older recaps; only this run's ok=3 counts
  grep -q '"ok_count":3,' "$MOCK_CURL_LOG"
  grep -q 'PLAY RECAP' "$WRAPPER_RUNTIME_DIR/last-run.log"
}

@test "parse-play-recap.sh sums counters across hosts" {
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
