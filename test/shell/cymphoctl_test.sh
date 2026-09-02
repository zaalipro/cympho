#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="${ROOT}/bin/cymphoctl"
REAL_PYTHON3="$(command -v python3)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cymphoctl-test.XXXXXX")"
FAKE_BIN="${TEST_ROOT}/bin"
STATE_DIR="${TEST_ROOT}/state"

mkdir -p "$FAKE_BIN" "$STATE_DIR"

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  if [[ "$actual" != "$expected" ]]; then
    printf 'expected: %s\nactual:   %s\n' "$expected" "$actual" >&2
    fail "$message"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"

  [[ "$haystack" == *"$needle"* ]] || fail "$message (missing: $needle)"
}

assert_file_contains() {
  local path="$1"
  local needle="$2"
  local message="$3"

  grep -Fq -- "$needle" "$path" || fail "$message (missing: $needle)"
}

assert_json() {
  local document="$1"
  local expression="$2"
  local message="$3"

  "$REAL_PYTHON3" - "$document" "$expression" <<'PY' || fail "$message"
import json
import sys

document = json.loads(sys.argv[1])
if not eval(sys.argv[2], {"__builtins__": {}}, {"d": document}):
    raise SystemExit(1)
PY
}

write_health() {
  local status="$1"
  local revision="$2"
  local database="${3:-ready}"
  local migrations="${4:-ready}"
  local application="${5:-ready}"

  cat >"${STATE_DIR}/health.json" <<EOF
{"schema_version":1,"status":"${status}","service":"cympho","release":{"version":"0.1.0","revision":"${revision}"},"checks":{"application":"${application}","database":"${database}","migrations":"${migrations}"}}
EOF
}

write_release_info() {
  local revision="$1"
  cat >"${STATE_DIR}/release-info.json" <<EOF
{"schema_version":1,"service":"cympho","release":{"version":"0.1.0","revision":"${revision}"}}
EOF
}

cat >"${FAKE_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$@" >"${CYMPHOCTL_TEST_STATE}/curl.args"

output=""
while (($# > 0)); do
  case "$1" in
    --output)
      output="$2"
      shift 2
      ;;
    *) shift ;;
  esac
done

[[ -n "$output" ]] || exit 90
if [[ "${FAKE_CURL_EXIT:-0}" != "0" ]]; then exit "$FAKE_CURL_EXIT"; fi
cat -- "${CYMPHOCTL_TEST_STATE}/health.json" >"$output"
printf '%s\n%s' "${FAKE_HTTP_STATUS:-200}" "${FAKE_CONTENT_TYPE:-application/json; charset=utf-8}"
EOF

cat >"${FAKE_BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$@" >"${CYMPHOCTL_TEST_STATE}/systemctl.args"
if [[ "${FAKE_SYSTEMCTL_EXIT:-0}" != "0" ]]; then exit "$FAKE_SYSTEMCTL_EXIT"; fi
cat <<STATUS
LoadState=${FAKE_LOAD_STATE:-loaded}
ActiveState=${FAKE_ACTIVE_STATE:-active}
UnitFileState=${FAKE_UNIT_FILE_STATE:-enabled}
MainPID=${FAKE_MAIN_PID:-4321}
STATUS
EOF

cat >"${FAKE_BIN}/journalctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$@" >"${CYMPHOCTL_TEST_STATE}/journalctl.args"
printf 'journal fixture\n'
EOF

chmod +x "$FAKE_BIN/curl" "$FAKE_BIN/systemctl" "$FAKE_BIN/journalctl"
ln -s "$REAL_PYTHON3" "$FAKE_BIN/python3"

export PATH="${FAKE_BIN}:/usr/bin:/bin"
export CYMPHOCTL_TEST_STATE="$STATE_DIR"
export CYMPHOCTL_RELEASE_INFO_FILE="${STATE_DIR}/release-info.json"
export CYMPHOCTL_APP_HOST="cympho.example.test"

run_cli() {
  STDOUT_FILE="${STATE_DIR}/stdout"
  STDERR_FILE="${STATE_DIR}/stderr"
  : >"$STDOUT_FILE"
  : >"$STDERR_FILE"

  set +e
  "$CLI" "$@" >"$STDOUT_FILE" 2>"$STDERR_FILE"
  CLI_STATUS=$?
  set -e

  CLI_STDOUT="$(cat "$STDOUT_FILE")"
  CLI_STDERR="$(cat "$STDERR_FILE")"
}

write_release_info aaaaaaa
write_health ready aaaaaaa

run_cli version --json
assert_eq 0 "$CLI_STATUS" "version JSON exits successfully"
assert_json "$CLI_STDOUT" 'd["schema_version"] == 1 and d["command"] == "version" and d["release"]["revision"] == "aaaaaaa" and d["source"] == "release_manifest"' "version JSON follows the contract"
assert_eq "" "$CLI_STDERR" "successful version JSON keeps stderr empty"
pass "version reads and validates the local release manifest"

run_cli readiness --json --expect-revision aaaaaaa
assert_eq 0 "$CLI_STATUS" "ready service exits successfully"
assert_json "$CLI_STDOUT" 'd["status"] == "ready" and d["checks"]["database"] == "ready"' "readiness JSON follows the contract"
assert_file_contains "${STATE_DIR}/curl.args" "--max-redirs" "curl forbids redirects"
assert_file_contains "${STATE_DIR}/curl.args" "--connect-timeout" "curl uses a connect timeout"
assert_file_contains "${STATE_DIR}/curl.args" "--max-time" "curl uses an overall timeout"
assert_file_contains "${STATE_DIR}/curl.args" "--disable" "curl ignores user configuration"
assert_file_contains "${STATE_DIR}/curl.args" "--noproxy" "curl bypasses proxies for loopback"
assert_file_contains "${STATE_DIR}/curl.args" "http://127.0.0.1:4000/api/health" "curl uses the fixed loopback URL"
assert_file_contains "${STATE_DIR}/curl.args" "Host: cympho.example.test" "curl sends the configured Host header"
assert_file_contains "${STATE_DIR}/curl.args" "Accept: application/json" "curl requests JSON explicitly"
pass "readiness accepts only the versioned ready document through bounded loopback curl"

export FAKE_CONTENT_TYPE=text/html
run_cli readiness --json
assert_eq 1 "$CLI_STATUS" "wrong content type fails readiness"
assert_json "$CLI_STDOUT" 'd["status"] == "error" and d["error"] == "invalid_content_type"' "content-type failure is machine readable"
assert_contains "$CLI_STDERR" "application/json" "wrong content type is diagnosed on stderr"
unset FAKE_CONTENT_TYPE
pass "readiness requires an application/json media type"

run_cli readiness --json --expect-revision bbbbbbb
assert_eq 1 "$CLI_STATUS" "stale revision fails readiness"
assert_json "$CLI_STDOUT" 'd["status"] == "not_ready" and d["error"] == "revision_mismatch" and d["expected_revision"] == "bbbbbbb"' "revision mismatch is machine readable"
assert_contains "$CLI_STDERR" "does not match expected revision" "revision mismatch is diagnosed on stderr"
run_cli readiness --expect-revision bbbbbbb
assert_eq 1 "$CLI_STATUS" "human stale revision fails readiness"
assert_contains "$CLI_STDOUT" "Cympho is not ready" "human stale revision never claims readiness"
if [[ "$CLI_STDOUT" == *"Cympho is ready"* ]]; then
  fail "human stale revision must not print a ready claim"
fi
pass "readiness rejects a stale release revision"

write_health not_ready aaaaaaa unavailable pending
export FAKE_HTTP_STATUS=503
run_cli readiness --json
assert_eq 1 "$CLI_STATUS" "not-ready service exits nonzero"
assert_json "$CLI_STDOUT" 'd["status"] == "not_ready" and d["checks"]["database"] == "unavailable" and d["checks"]["migrations"] == "pending"' "503 body remains bounded machine output"
assert_contains "$CLI_STDERR" "not ready" "not-ready service is diagnosed on stderr"
pass "readiness accepts the 503 not-ready schema but exits nonzero"

write_health not_ready aaaaaaa unavailable unavailable unavailable
run_cli readiness --json
assert_eq 1 "$CLI_STATUS" "unavailable application exits nonzero"
assert_json "$CLI_STDOUT" 'd["status"] == "not_ready" and d["checks"]["application"] == "unavailable"' "cache failure schema remains valid"
assert_contains "$CLI_STDERR" "not ready" "unavailable application is diagnosed as not-ready"
pass "readiness accepts the producer's unavailable application state"

unset FAKE_HTTP_STATUS
printf '<html>foreign responder</html>\n' >"${STATE_DIR}/health.json"
run_cli readiness --json
assert_eq 1 "$CLI_STATUS" "foreign HTML responder fails readiness"
assert_json "$CLI_STDOUT" 'd["status"] == "error" and d["error"] == "invalid_document"' "foreign responder has stable JSON error"
assert_eq "" "$(cat "${STATE_DIR}/health.json" | grep -F 'database_url=' || true)" "fixture contains no accidental secret"
pass "readiness rejects foreign and malformed responders"

cat >"${STATE_DIR}/health.json" <<'EOF'
{"schema_version":1,"schema_version":1,"status":"ready","service":"cympho","release":{"version":"0.1.0","revision":"aaaaaaa"},"checks":{"application":"ready","database":"ready","migrations":"ready"}}
EOF
run_cli readiness --json
assert_eq 1 "$CLI_STATUS" "duplicate JSON keys fail readiness"
assert_json "$CLI_STDOUT" 'd["status"] == "error" and d["error"] == "invalid_document"' "duplicate JSON keys have a stable failure"
pass "readiness rejects non-strict JSON documents"

cat >"${STATE_DIR}/health.json" <<'EOF'
{"schema_version":1,"status":"ready","service":"cympho","release":{"version":"0.1.0","revision":"aaaaaaa"},"checks":{"application":"ready","database":"ready","migrations":"ready"},"unexpected":"value"}
EOF
run_cli readiness --json
assert_eq 1 "$CLI_STATUS" "unexpected JSON keys fail readiness"
assert_json "$CLI_STDOUT" 'd["status"] == "error" and d["error"] == "invalid_document"' "extra JSON keys have a stable failure"
pass "readiness requires the exact versioned key set"

write_health ready aaaaaaa
export FAKE_HTTP_STATUS=302
run_cli readiness --json
assert_eq 1 "$CLI_STATUS" "redirect status fails readiness"
assert_json "$CLI_STDOUT" 'd["status"] == "not_ready" and d["error"] == "unexpected_http_status" and d["http_status"] == 302' "redirect failure is machine readable"
pass "readiness does not treat redirects as health"

unset FAKE_HTTP_STATUS
run_cli service status --json
assert_eq 0 "$CLI_STATUS" "active matching service status succeeds"
assert_json "$CLI_STDOUT" 'd["command"] == "service.status" and d["status"] == "ready" and d["supervisor"]["active"] is True and d["health"]["release"]["revision"] == "aaaaaaa"' "service status combines supervisor and readiness"
assert_file_contains "${STATE_DIR}/systemctl.args" "--no-pager" "systemctl disables a pager"
assert_file_contains "${STATE_DIR}/systemctl.args" "cympho.service" "systemctl receives a fixed unit name"
pass "service status requires both active systemd state and exact release readiness"

export FAKE_ACTIVE_STATE=inactive
export FAKE_MAIN_PID=0
run_cli service status --json
assert_eq 1 "$CLI_STATUS" "inactive managed service exits nonzero"
assert_json "$CLI_STDOUT" 'd["status"] == "not_ready" and d["supervisor"]["active"] is False and d["health"]["status"] == "ready"' "inactive foreign responder is attributed"
assert_contains "$CLI_STDERR" "inactive even though" "inactive service with a responder is diagnosed"
pass "service status does not attribute a healthy foreign process to systemd"
unset FAKE_ACTIVE_STATE FAKE_MAIN_PID

printf '{"schema_version":1,"service":"cympho","release":{"version":"bad version","revision":"aaaaaaa"}}\n' \
  >"${STATE_DIR}/release-info.json"
run_cli version --json
assert_eq 1 "$CLI_STATUS" "invalid local release identity fails version"
assert_json "$CLI_STDOUT" 'd["status"] == "error" and d["error"] == "release_identity_invalid"' "invalid identity is machine readable"
run_cli service status --json
assert_eq 1 "$CLI_STATUS" "invalid local release identity fails service status"
assert_json "$CLI_STDOUT" 'd["status"] == "not_ready" and d["health_error"] == "release_identity_invalid"' "status fails closed on invalid local identity"
write_release_info aaaaaaa
pass "local release identity is strictly validated and fails closed"

rm -f "${STATE_DIR}/release-info.json"
run_cli service status --json
assert_eq 1 "$CLI_STATUS" "missing local release identity fails service status"
assert_json "$CLI_STDOUT" 'd["status"] == "not_ready" and d["health_error"] == "release_identity_absent"' "missing identity fails closed"
write_release_info aaaaaaa
pass "service status requires a local release identity to match"

run_cli service logs -n 250 -f
assert_eq 0 "$CLI_STATUS" "valid log request succeeds"
assert_eq "journal fixture" "$CLI_STDOUT" "journal output is streamed to stdout"
assert_file_contains "${STATE_DIR}/journalctl.args" "--no-pager" "journalctl disables its pager"
assert_file_contains "${STATE_DIR}/journalctl.args" "--lines" "journalctl receives an explicit line bound"
assert_file_contains "${STATE_DIR}/journalctl.args" "250" "journalctl receives the requested line count"
assert_file_contains "${STATE_DIR}/journalctl.args" "--follow" "journalctl receives follow without shell evaluation"
pass "service logs passes validated arguments directly to journalctl"

rm -f "${STATE_DIR}/journalctl.args"
run_cli service logs -n "1;touch ${STATE_DIR}/injected"
assert_eq 64 "$CLI_STATUS" "malicious log line value is a usage error"
[[ ! -e "${STATE_DIR}/journalctl.args" ]] || fail "invalid log count must not invoke journalctl"
[[ ! -e "${STATE_DIR}/injected" ]] || fail "invalid log count must not execute shell text"
run_cli service logs -n 10001
assert_eq 64 "$CLI_STATUS" "oversized log line value is a usage error"
pass "service logs rejects injection-shaped and unbounded line counts"

export CYMPHOCTL_SERVICE_NAME='bad;unit'
run_cli service status --json
assert_eq 64 "$CLI_STATUS" "unsafe service name is rejected before systemctl"
assert_contains "$CLI_STDERR" "simple systemd service name" "unsafe service name has a useful diagnostic"
unset CYMPHOCTL_SERVICE_NAME
pass "service override is constrained to a simple unit name"

printf '1..17\n'
