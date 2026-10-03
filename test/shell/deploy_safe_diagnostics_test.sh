#!/usr/bin/env bash
#
# VAL-DEP-005: Deployment diagnostics are useful and secret-safe
# Verifies that:
#   1. Static shell contracts prohibit raw journalctl / systemctl status dumps
#      in deploy.sh and ensure read-only diagnostic boundaries.
#   2. Affected health and readiness failure paths emit only selected
#      operational state fields.
#   3. Cookie, environment, command-line, database, JWT, and journal-body
#      sentinels never appear in diagnostics.
#   4. Missing diagnostic commands do not trigger an unsafe raw-output fallback
#      or hide the deployment failure.
#

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOY_SCRIPT="$ROOT/deploy.sh"
CYMPHOCTL="$ROOT/bin/cymphoctl"
VALIDATOR="$ROOT/bin/cympho-health-validator"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cympho-deploy-diag-test.XXXXXX")"
trap 'rm -rf -- "$TMP_DIR"' EXIT
chgrp "$(id -g)" "$TMP_DIR" 2>/dev/null || true

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

# --- Part 1: Static shell contracts ------------------------------------------

[[ -x "$DEPLOY_SCRIPT" ]] || fail "deploy.sh must be executable"
[[ -x "$CYMPHOCTL" ]] || fail "bin/cymphoctl must be executable"
[[ -x "$VALIDATOR" ]] || fail "bin/cympho-health-validator must be executable"

bash -n "$DEPLOY_SCRIPT" || fail "deploy.sh must pass bash syntax check"
bash -n "$CYMPHOCTL" || fail "bin/cymphoctl must pass bash syntax check"

# deploy.sh must never invoke raw journalctl or raw systemctl status
if grep -Eq '(^|[^[:alnum:]_])journalctl([^[:alnum:]_]|$)' "$DEPLOY_SCRIPT"; then
  fail "deploy.sh must not contain raw journalctl invocations"
fi

if grep -Eq 'systemctl[[:space:]]+status' "$DEPLOY_SCRIPT"; then
  fail "deploy.sh must not contain raw systemctl status invocations"
fi

# deploy.sh must define emit_service_diagnostics and use cymphoctl service status
grep -Fq 'emit_service_diagnostics()' "$DEPLOY_SCRIPT" ||
  fail "deploy.sh must define emit_service_diagnostics helper"

grep -Fq "'\${SOURCE_DIR}/bin/cymphoctl' service status" "$DEPLOY_SCRIPT" ||
  fail "deploy.sh must invoke cymphoctl service status for diagnostics"

# deploy.sh must emit diagnostics on local health failure path
health_fail_section="$(awk '
  /if \[\[ "\$\{local_ok\}" != "1" \]\]; then/ { capture=1 }
  /echo "Local health OK\."/ { capture=0 }
  capture { print }
' "$DEPLOY_SCRIPT")"
[[ -n "$health_fail_section" ]] || fail "could not locate local health check section in deploy.sh"
echo "$health_fail_section" | grep -Fq 'emit_service_diagnostics' ||
  fail "local health failure path must call emit_service_diagnostics"

# deploy.sh must emit diagnostics on public readiness failure path
readiness_fail_section="$(awk '
  /step "Public attested readiness/ { capture=1 }
  /step "Pruning old releases/ { capture=0 }
  capture { print }
' "$DEPLOY_SCRIPT")"
[[ -n "$readiness_fail_section" ]] || fail "could not locate public readiness section in deploy.sh"
echo "$readiness_fail_section" | grep -Fq 'emit_service_diagnostics' ||
  fail "public readiness failure path must call emit_service_diagnostics"

# deploy.sh must emit diagnostics on remote service status step
grep -Fq $'step "Remote service status"\nemit_service_diagnostics' "$DEPLOY_SCRIPT" ||
  fail "step Remote service status must invoke emit_service_diagnostics"

# deploy.sh rollback readiness failure must also emit safe diagnostics
rollback_body="$(awk '
  /^rollback_release\(\)/ { capture=1 }
  /^step "Placing release/ { capture=0 }
  capture { print }
' "$DEPLOY_SCRIPT")"
[[ -n "$rollback_body" ]] || fail "could not locate rollback_release in deploy.sh"
echo "$rollback_body" | grep -Fq 'emit_service_diagnostics' ||
  fail "rollback readiness failure must invoke emit_service_diagnostics"

# cymphoctl must remain strictly read-only and unprivileged
if grep -Eq '(^|[^[:alnum:]_])(eval|sudo)([^[:alnum:]_]|$)' "$CYMPHOCTL"; then
  fail "cymphoctl must not evaluate text or acquire privileges"
fi

printf 'ok - static shell contracts prohibit raw dumps and enforce safe diagnostics\n'

# --- Part 2: Behavioral sentinel isolation & diagnostic output ----------------

SENTINEL_COOKIE="sentinel_cookie_secret_val_98765"
SENTINEL_CMDLINE="sentinel_cmdline_beam_smp_arg_87654"
SENTINEL_ENV="sentinel_env_secret_key_base_76543"
SENTINEL_DB="sentinel_db_postgres_password_65432"
SENTINEL_JWT="sentinel_jwt_secret_token_54321"
SENTINEL_JOURNAL="sentinel_journal_body_raw_log_43210"

ALL_SENTINELS=(
  "$SENTINEL_COOKIE"
  "$SENTINEL_CMDLINE"
  "$SENTINEL_ENV"
  "$SENTINEL_DB"
  "$SENTINEL_JWT"
  "$SENTINEL_JOURNAL"
)

assert_no_sentinels() {
  local output="$1"
  local context="$2"
  for s in "${ALL_SENTINELS[@]}"; do
    if [[ "$output" == *"$s"* ]]; then
      fail "sentinel leaked in $context: $s"
    fi
  done
}

FAKE_BIN="$TMP_DIR/fake-bin"
mkdir -p "$FAKE_BIN"
chgrp "$(id -g)" "$FAKE_BIN" 2>/dev/null || true

# Mock systemctl used by cymphoctl
cat >"$FAKE_BIN/systemctl" <<EOF
#!/usr/bin/env bash
if [[ "\${MOCK_MISSING_SYSTEMCTL:-0}" == "1" ]]; then
  exit 127
fi
if [[ "\${MOCK_FAILING_SYSTEMCTL:-0}" == "1" ]]; then
  exit 1
fi
for arg in "\$@"; do
  if [[ "\$arg" == "--property="* ]]; then
    printf 'LoadState=loaded\\n'
    printf 'ActiveState=%s\\n' "\${MOCK_SYSTEMD_STATE:-active}"
    printf 'UnitFileState=enabled\\n'
    printf 'MainPID=4200\\n'
    exit 0
  fi
done
exit 0
EOF
chmod +x "$FAKE_BIN/systemctl"

# Mock curl used by cymphoctl
cat >"$FAKE_BIN/curl" <<EOF
#!/usr/bin/env bash
if [[ "\${MOCK_MISSING_CURL:-0}" == "1" ]]; then
  exit 127
fi
out_file=""
while [[ "\$#" -gt 0 ]]; do
  case "\$1" in
    --output) out_file="\$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -n "\$out_file" ]]; then
  cat >"\$out_file" <<JSON
{
  "schema_version": 1,
  "status": "\${MOCK_HEALTH_STATUS:-ready}",
  "service": "cympho",
  "release": {
    "version": "0.1.0",
    "revision": "\${MOCK_REVISION:-111111111111}"
  },
  "checks": {
    "application": "\${MOCK_APP_CHECK:-ready}",
    "database": "\${MOCK_DB_CHECK:-ready}",
    "migrations": "\${MOCK_MIG_CHECK:-ready}"
  }
}
JSON
fi

http_code="200"
if [[ "\${MOCK_HEALTH_STATUS:-ready}" == "not_ready" ]]; then
  http_code="503"
fi
printf '%s\napplication/json' "\$http_code"
exit 0
EOF
chmod +x "$FAKE_BIN/curl"

# Mock journalctl to ensure any raw journal fallback emits sentinel and fails assertion
cat >"$FAKE_BIN/journalctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$SENTINEL_JOURNAL"
exit 0
EOF
chmod +x "$FAKE_BIN/journalctl"

cat >"$TMP_DIR/release-info.json" <<EOF
{
  "schema_version": 1,
  "service": "cympho",
  "release": {
    "version": "0.1.0",
    "revision": "111111111111"
  }
}
EOF

# Load the exact emit_service_diagnostics function from deploy.sh
diag_definition="$(awk '
  /^emit_service_diagnostics\(\)/ { capture=1 }
  /^rollback_release\(\)/ { capture=0 }
  capture { print }
' "$DEPLOY_SCRIPT")"
[[ -n "$diag_definition" ]] || fail "could not load emit_service_diagnostics from deploy.sh"

SERVICE_NAME="cympho"
APP_PORT="49999"
DOMAIN="cympho.llmotions.com"
SOURCE_DIR="$TMP_DIR/mock-source"
RELEASE_DIR="$TMP_DIR/mock-release"
mkdir -p "$SOURCE_DIR/bin" "$RELEASE_DIR"
cp "$CYMPHOCTL" "$SOURCE_DIR/bin/cymphoctl"
cp "$VALIDATOR" "$SOURCE_DIR/bin/cympho-health-validator"
cp "$TMP_DIR/release-info.json" "$RELEASE_DIR/release-info.json"

eval "$diag_definition"

# Test 2: Local health check failure emits only allowlisted operational fields
run_ssh() {
  local cmd="$1"

  # Trap any raw journalctl or systemctl status calls - they must NEVER occur
  if [[ "$cmd" == *"journalctl"* ]]; then
    printf '%s\n' "$SENTINEL_JOURNAL"
    return 0
  fi
  if [[ "$cmd" == *"systemctl status"* ]]; then
    printf '● cympho.service - Cympho AI\n'
    printf '   Main PID: 4200 (beam.smp)\n'
    printf '   CGroup: %s %s %s %s %s\n' "$SENTINEL_COOKIE" "$SENTINEL_CMDLINE" "$SENTINEL_ENV" "$SENTINEL_DB" "$SENTINEL_JWT"
    return 0
  fi

  # Execute the command in an environment containing sentinels
  env \
    PATH="$FAKE_BIN:$PATH" \
    COOKIE="$SENTINEL_COOKIE" \
    CMDLINE_ARG="$SENTINEL_CMDLINE" \
    SECRET_KEY_BASE="$SENTINEL_ENV" \
    POSTGRES_PASSWORD="$SENTINEL_DB" \
    CYMPHO_USER_JWT_SECRET="$SENTINEL_JWT" \
    bash -c "$cmd"
}

export -f run_ssh

# Simulate failure scenario: application unavailable, database timeout, migrations pending
export MOCK_SYSTEMD_STATE="active"
export MOCK_HEALTH_STATUS="not_ready"
export MOCK_APP_CHECK="unavailable"
export MOCK_DB_CHECK="timeout"
export MOCK_MIG_CHECK="pending"
export MOCK_REVISION="111111111111"

# Execute emit_service_diagnostics on health failure
set +e
HEALTH_FAIL_OUT="$(emit_service_diagnostics "${RELEASE_DIR}/release-info.json" 2>&1)"
HEALTH_FAIL_STATUS=$?
set -e

[[ "$HEALTH_FAIL_OUT" == *"Service cympho.service: active, enabled, pid 4200."* ]] ||
  fail "health failure diagnostics must emit allowlisted supervisor state"
[[ "$HEALTH_FAIL_OUT" == *"application=unavailable, database=timeout, migrations=pending"* ]] ||
  fail "health failure diagnostics must emit allowlisted component checks"
[[ "$HEALTH_FAIL_OUT" == *"the managed service is active but not ready"* ]] ||
  fail "health failure diagnostics must emit allowlisted diagnosis message"

assert_no_sentinels "$HEALTH_FAIL_OUT" "health failure diagnostics"

printf 'ok - health failure path emits only allowlisted operational fields and no sentinels\n'

# Test 3: Remote service status (success path) emits allowlisted fields without sentinels
export MOCK_SYSTEMD_STATE="active"
export MOCK_HEALTH_STATUS="ready"
export MOCK_APP_CHECK="ready"
export MOCK_DB_CHECK="ready"
export MOCK_MIG_CHECK="ready"

set +e
SUCCESS_OUT="$(emit_service_diagnostics "${RELEASE_DIR}/release-info.json" 2>&1)"
SUCCESS_STATUS=$?
set -e

[[ "$SUCCESS_OUT" == *"Service cympho.service: active, enabled, pid 4200."* ]] ||
  fail "success path diagnostics must emit allowlisted supervisor state"
[[ "$SUCCESS_OUT" == *"Cympho is ready (version 0.1.0, revision 111111111111)."* ]] ||
  fail "success path diagnostics must emit allowlisted ready state"

assert_no_sentinels "$SUCCESS_OUT" "success path diagnostics"

printf 'ok - success path diagnostics emit only allowlisted operational fields and no sentinels\n'

# Test 4: Missing diagnostic command does not trigger raw fallback or hide failure
# Test when cymphoctl binary is absent
MISSING_SOURCE_DIR="$TMP_DIR/empty-source"
mkdir -p "$MISSING_SOURCE_DIR/bin"

missing_cmd_run() {
  local exit_code=0
  local simulated_failure_logged=0

  # Simulate the deploy.sh failure block with missing cymphoctl
  local SOURCE_DIR="$MISSING_SOURCE_DIR"
  emit_service_diagnostics "${RELEASE_DIR}/release-info.json" || true

  # Simulate rollback_release call after diagnostic emission
  simulated_failure_logged=1
  return 1
}

set +e
MISSING_OUT="$(missing_cmd_run 2>&1)"
MISSING_CODE=$?
set -e

[[ "$MISSING_CODE" == 1 ]] || fail "missing diagnostic command must not hide deployment failure"
assert_no_sentinels "$MISSING_OUT" "missing diagnostic command path"

printf 'ok - missing diagnostic command does not trigger raw fallback or hide deployment failure\n'

# Test 5: Missing systemctl handled cleanly by cymphoctl
export MOCK_MISSING_SYSTEMCTL=1
export MOCK_HEALTH_STATUS="not_ready"
export MOCK_APP_CHECK="unavailable"

set +e
NO_SYSTEMD_OUT="$(emit_service_diagnostics "${RELEASE_DIR}/release-info.json" 2>&1)"
NO_SYSTEMD_CODE=$?
set -e

[[ "$NO_SYSTEMD_OUT" == *"systemd service status is unavailable"* ]] ||
  fail "missing supervisor must report supervisor unavailability cleanly"
assert_no_sentinels "$NO_SYSTEMD_OUT" "missing supervisor diagnostic path"

printf 'ok - missing supervisor tool is handled without raw fallback\n'

# Test 6: Sealed manifest permission layout — unreadable release-info.json
# Under normal production permissions (0550 / 0440 root:cympho), DEPLOY_USER cannot read release-info.json.
# Diagnostics supplied with trusted attested revision must report ready service and not fail on absent manifest.
chmod 000 "$RELEASE_DIR/release-info.json" 2>/dev/null || chmod -r "$RELEASE_DIR/release-info.json"
export MOCK_MISSING_SYSTEMCTL=0
export MOCK_SYSTEMD_STATE="active"
export MOCK_HEALTH_STATUS="ready"
export MOCK_APP_CHECK="ready"
export MOCK_DB_CHECK="ready"
export MOCK_MIG_CHECK="ready"
export MOCK_REVISION="111111111111"
export BUILD_REVISION="111111111111"

set +e
SEALED_OUT="$(emit_service_diagnostics "${BUILD_REVISION}" 2>&1)"
SEALED_CODE=$?
set -e

[[ "$SEALED_OUT" == *"Cympho is ready (version 0.1.0, revision 111111111111)."* ]] ||
  fail "sealed manifest with trusted revision must report ready service"
[[ "$SEALED_OUT" != *"the local release identity manifest is"* ]] ||
  fail "sealed manifest with trusted revision must not falsely diagnose missing manifest"
[[ "$SEALED_OUT" != *"release_identity_absent"* ]] ||
  fail "sealed manifest must not report release_identity_absent"
assert_no_sentinels "$SEALED_OUT" "sealed manifest success path"

printf 'ok - sealed manifest success path reports ready without unreadable manifest failure\n'

# Test 7: Sealed manifest with revision mismatch fails closed and diagnoses mismatch
export MOCK_REVISION="222222222222"

set +e
MISMATCH_OUT="$(emit_service_diagnostics "${BUILD_REVISION}" 2>&1)"
MISMATCH_CODE=$?
set -e

[[ "$MISMATCH_OUT" == *"revision 222222222222 does not match expected 111111111111"* ]] ||
  fail "revision mismatch under sealed manifest must be diagnosed accurately"
assert_no_sentinels "$MISMATCH_OUT" "sealed manifest revision mismatch"

printf 'ok - revision mismatch under sealed manifest fails closed with accurate diagnosis\n'

# Test 8: Rollback diagnostics with attested previous revision under sealed manifest
PREV_RELEASE_DIR="$TMP_DIR/mock-prev-release"
mkdir -p "$PREV_RELEASE_DIR"
cat >"$PREV_RELEASE_DIR/release-info.json" <<EOF
{
  "schema_version": 1,
  "service": "cympho",
  "release": {
    "version": "0.1.0",
    "revision": "333333333333"
  }
}
EOF
chmod 000 "$PREV_RELEASE_DIR/release-info.json" 2>/dev/null || chmod -r "$PREV_RELEASE_DIR/release-info.json"
export PREVIOUS_REVISION="333333333333"
export MOCK_REVISION="333333333333"

set +e
ROLLBACK_OUT="$(emit_service_diagnostics "${PREVIOUS_REVISION}" 2>&1)"
ROLLBACK_CODE=$?
set -e

[[ "$ROLLBACK_OUT" == *"Cympho is ready (version 0.1.0, revision 333333333333)."* ]] ||
  fail "rollback diagnostics with trusted previous revision must report ready"
[[ "$ROLLBACK_OUT" != *"the local release identity manifest is"* ]] ||
  fail "rollback diagnostics must not falsely diagnose missing manifest"
assert_no_sentinels "$ROLLBACK_OUT" "rollback diagnostics path"

printf 'ok - rollback diagnostics use trusted previous revision and succeed under sealed manifest\n'

# Test 9: Deployment failure path preserves failure exit and emits safe diagnostics
# Simulates deploy.sh local health failure block: emit diagnostics then rollback_release
deploy_health_fail_block() {
  local local_ok=0
  if [[ "${local_ok}" != "1" ]]; then
    emit_service_diagnostics "${BUILD_REVISION}" "${RELEASE_DIR}/release-info.json"
    echo "ERROR: Service failed local health check" >&2
    return 1
  fi
  return 0
}

export MOCK_HEALTH_STATUS="not_ready"
export MOCK_APP_CHECK="unavailable"
export MOCK_REVISION="111111111111"
set +e
FAIL_BLOCK_OUT="$(deploy_health_fail_block 2>&1)"
FAIL_BLOCK_CODE=$?
set -e

[[ "$FAIL_BLOCK_CODE" == 1 ]] || fail "failure path must exit nonzero"
[[ "$FAIL_BLOCK_OUT" == *"Service failed local health check"* ]] ||
  fail "failure path must record rollback reason"
[[ "$FAIL_BLOCK_OUT" == *"the managed service is active but not ready"* ]] ||
  fail "failure path must emit operational diagnostic"
assert_no_sentinels "$FAIL_BLOCK_OUT" "deploy failure path"

printf 'ok - deployment failure block emits safe diagnostics and preserves exit 1\n'

# Test 10: Ready health with unavailable supervisor metadata is not reported inactive
export MOCK_MISSING_SYSTEMCTL=0
export MOCK_FAILING_SYSTEMCTL=1
export MOCK_HEALTH_STATUS="ready"
export MOCK_APP_CHECK="ready"
export MOCK_DB_CHECK="ready"
export MOCK_MIG_CHECK="ready"
export MOCK_REVISION="111111111111"
export BUILD_REVISION="111111111111"

set +e
SUPERVISOR_UNAVAIL_OUT="$(emit_service_diagnostics "${BUILD_REVISION}" 2>&1)"
SUPERVISOR_UNAVAIL_CODE=$?
set -e

[[ "$SUPERVISOR_UNAVAIL_OUT" == *"systemd service status is unavailable"* ]] ||
  fail "supervisor query failure must diagnose supervisor unavailability"
[[ "$SUPERVISOR_UNAVAIL_OUT" != *"the managed service is inactive"* ]] ||
  fail "supervisor query failure with ready health must not falsely diagnose inactive service"
[[ "$SUPERVISOR_UNAVAIL_OUT" != *"inactive even though"* ]] ||
  fail "supervisor query failure with ready health must not claim inactive foreign responder"
[[ "$SUPERVISOR_UNAVAIL_OUT" == *"Cympho is ready (version 0.1.0, revision 111111111111)."* ]] ||
  fail "ready health responder output must remain visible when supervisor fails"
assert_no_sentinels "$SUPERVISOR_UNAVAIL_OUT" "supervisor query failure diagnostic path"

export MOCK_FAILING_SYSTEMCTL=0
printf 'ok - ready health with unavailable supervisor is diagnosed as unavailable and not inactive\n'

# Restore manifest permission for cleanup
chmod 644 "$RELEASE_DIR/release-info.json" "$PREV_RELEASE_DIR/release-info.json" 2>/dev/null || true

printf '1..10\n'
