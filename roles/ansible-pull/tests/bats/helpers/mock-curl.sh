#!/usr/bin/env bash
# Drop-in 'curl' replacement for BATS tests.
#
# The wrapper-under-test makes several curl calls (drain-pending, start_run,
# classify, log upload, complete_run). This mock dispatches by URL fragment
# so the same test can stub different responses for different endpoints.
#
# Env vars consumed:
#   MOCK_CURL_LOG          — append each invocation to this file (one per line)
#   MOCK_RESPONSE_FAIL     — if set, exit 22 immediately (simulates outage)
#   MOCK_RESPONSE_FILE     — file to cat on stdout for ANY successful call
#                            (single-response mode; convenient for simple cases)
#   MOCK_RESP_START_RUN    — file to cat when URL matches /v1/pull/runs (POST,
#                            no run-id suffix). Overrides MOCK_RESPONSE_FILE.
#   MOCK_RESP_CLASSIFY     — file to cat when URL matches /v1/pull/classify.
#                            Overrides MOCK_RESPONSE_FILE.
#   MOCK_RESP_LOG_UPLOAD   — file to cat for PUT requests to .../log.
#                            Overrides MOCK_RESPONSE_FILE.
#   MOCK_RESP_COMPLETE     — file to cat when URL matches /v1/pull/runs/<id>
#                            (POST with run-id suffix). Overrides FILE.
#
# Recognized curl flags (silently consumed): -f -s -S -X <m> --max-time <n>
#   -H <hdr> --data-binary @file -d <body>
# The trailing positional arg is treated as the URL.

set -euo pipefail

if [[ -n "${MOCK_CURL_LOG:-}" ]]; then
  echo "curl $*" >> "$MOCK_CURL_LOG"
fi

if [[ -n "${MOCK_RESPONSE_FAIL:-}" ]]; then
  exit 22
fi

# Parse args to find the URL and method
method="GET"
url=""
while (( $# )); do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -H|--max-time|-d|--data-binary) shift 2 ;;
    -f|-s|-S|-fsS|-fs|-fS|-sS|--fail|--silent|--show-error) shift ;;
    --) shift; url="$1"; shift ;;
    -*) shift ;;  # unknown flag with no arg — skip
    *) url="$1"; shift ;;
  esac
done

# Dispatch by URL + method
case "$url" in
  */v1/pull/classify*)
    file="${MOCK_RESP_CLASSIFY:-${MOCK_RESPONSE_FILE:-}}"
    ;;
  */v1/pull/runs/*/log*)
    file="${MOCK_RESP_LOG_UPLOAD:-${MOCK_RESPONSE_FILE:-}}"
    ;;
  */v1/pull/runs/*)
    # POST to runs/<id> — completion. Could also be GET, but the wrapper
    # only does POST here.
    file="${MOCK_RESP_COMPLETE:-${MOCK_RESPONSE_FILE:-}}"
    ;;
  */v1/pull/runs*)
    file="${MOCK_RESP_START_RUN:-${MOCK_RESPONSE_FILE:-}}"
    ;;
  *)
    file="${MOCK_RESPONSE_FILE:-}"
    ;;
esac

if [[ -n "$file" && -f "$file" ]]; then
  cat "$file"
fi
exit 0
