#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOY_SCRIPT="${CYMPHO_DEPLOY_SCRIPT_UNDER_TEST:-$ROOT/deploy.sh}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cympho-env-rollback-behavior.XXXXXX")"
trap 'rm -rf -- "$TMP_DIR"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

file_mode() {
  stat -c '%a' -- "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# Exercise the real rollback function without invoking deploy.sh's top-level
# SSH/systemd/Docker workflow. The fake remote runner executes its heredoc in a
# child Bash process and adapts GNU `install -o/-g` and `mv -T` to an unprivileged
# local fixture; all validation/CAS/restore branching remains the production code.
restore_definition="$(awk '
  /^restore_runtime_env\(\)/ { capture=1 }
  /^commit_runtime_env\(\)/ { capture=0 }
  capture { print }
' "$DEPLOY_SCRIPT")"
[ -n "$restore_definition" ] || fail "could not load deploy runtime-env restore function"
eval "$restore_definition"

run_remote_script() {
  {
    printf '%s\n' 'set -euo pipefail'
    cat <<'FAKE_SUDO'
_sudo() {
  if [ "$1" = mv ] && [ "${2:-}" = -fT ]; then
    shift 2
    [ "${1:-}" = -- ] && shift
    command mv -f -- "$@"
  elif [ "$1" = install ]; then
    shift
    args=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -o|-g) shift 2 ;;
        *) args+=("$1"); shift ;;
      esac
    done
    command install "${args[@]}"
  elif [ "$1" = stat ] && [ "${2:-}" = -c ] && ! command stat -c '%a %u %g' -- . >/dev/null 2>&1; then
    shift 3
    command stat -f '%Lp %u %g' "$@"
  else
    "$@"
  fi
}
FAKE_SUDO
    cat
  } | bash
}

ENV_FILE="$TMP_DIR/cympho.env"
DB_ENV_FILE="$TMP_DIR/db.env"
ENV_SNAPSHOT_DIR="$TMP_DIR/snapshot"
DEPLOY_LOCK_PID=$$
DEPLOY_NONCE=deadbeef
ENV_SNAPSHOT_ACTIVE=1
ENV_SNAPSHOT_CLEANUP_DEBT=0

prepare_snapshot() {
  rm -rf -- "$ENV_SNAPSHOT_DIR"
  mkdir -p "$ENV_SNAPSHOT_DIR"
  printf 'APP_HOST=old.example\nSECRET_KEY_BASE=old-secret\n' > "$ENV_SNAPSHOT_DIR/env-file"
  printf 'POSTGRES_PASSWORD=old-db-secret\n' > "$ENV_SNAPSHOT_DIR/db-env-file"
  printf 'APP_HOST=new.example\nSECRET_KEY_BASE=old-secret\n' > "$ENV_SNAPSHOT_DIR/env-file.after"
  printf 'POSTGRES_PASSWORD=old-db-secret\n' > "$ENV_SNAPSHOT_DIR/db-env-file.after"
  : > "$ENV_SNAPSHOT_DIR/env-file.present"
  : > "$ENV_SNAPSHOT_DIR/db-env-file.present"
  printf '600 %s %s\n' "$(id -u)" "$(id -g)" > "$ENV_SNAPSHOT_DIR/env-file.meta"
  printf '600 %s %s\n' "$(id -u)" "$(id -g)" > "$ENV_SNAPSHOT_DIR/db-env-file.meta"
  printf '640 %s %s\n' "$(id -u)" "$(id -g)" > "$ENV_SNAPSHOT_DIR/env-file.after.meta"
  printf '600 %s %s\n' "$(id -u)" "$(id -g)" > "$ENV_SNAPSHOT_DIR/db-env-file.after.meta"
  : > "$ENV_SNAPSHOT_DIR/complete"
  ENV_SNAPSHOT_ACTIVE=1
  ENV_SNAPSHOT_CLEANUP_DEBT=0
}

# Simulate interruption after the app env was atomically published but before
# the unchanged DB env publish. Rollback must accept both candidate and prior
# live states, restore both prior files, and retire its evidence.
prepare_snapshot
cp "$ENV_SNAPSHOT_DIR/env-file.after" "$ENV_FILE"
cp "$ENV_SNAPSHOT_DIR/db-env-file" "$DB_ENV_FILE"
: > "$ENV_SNAPSHOT_DIR/env-file.published"
chmod 0640 "$ENV_FILE"
chmod 0600 "$DB_ENV_FILE"
restore_runtime_env
cmp -s "$ENV_FILE" <(printf 'APP_HOST=old.example\nSECRET_KEY_BASE=old-secret\n') ||
  fail "partial publish did not restore the prior app environment"
cmp -s "$DB_ENV_FILE" <(printf 'POSTGRES_PASSWORD=old-db-secret\n') ||
  fail "partial publish changed the prior DB environment"
[ "$ENV_SNAPSHOT_ACTIVE" -eq 0 ] || fail "successful rollback left snapshot active"
[ ! -e "$ENV_SNAPSHOT_DIR" ] || fail "successful rollback retained snapshot evidence"
[ "$(file_mode "$ENV_FILE")" = 600 ] ||
  fail "partial publish did not restore the prior app environment mode"
[ "$(file_mode "$DB_ENV_FILE")" = 600 ] ||
  fail "partial publish did not restore the prior DB environment mode"

# If a prior file was absent and an external writer creates it before
# publication, rollback must preserve that evidence rather than deleting it.
prepare_snapshot
rm -f -- "$ENV_FILE" "$DB_ENV_FILE"
rm -f -- "$ENV_SNAPSHOT_DIR/env-file.present" "$ENV_SNAPSHOT_DIR/db-env-file.present"
rm -f -- "$ENV_SNAPSHOT_DIR/env-file.meta" "$ENV_SNAPSHOT_DIR/db-env-file.meta"
rm -f -- "$ENV_SNAPSHOT_DIR/env-file.published" "$ENV_SNAPSHOT_DIR/db-env-file.published"
printf 'APP_HOST=external.example\n' > "$ENV_FILE"
set +e
restore_runtime_env >/dev/null 2>&1
restore_status=$?
set -e
[ "$restore_status" -ne 0 ] || fail "absent preimage conflict unexpectedly restored environment"
grep -Fq 'external.example' "$ENV_FILE" || fail "absent preimage conflict deleted external app env"
[ -d "$ENV_SNAPSHOT_DIR" ] || fail "absent preimage conflict deleted recovery evidence"

# Candidate bytes alone are insufficient evidence that the live file still
# belongs to this deploy. A metadata-only external change must trip the same
# compare-and-swap boundary and preserve both targets and rollback evidence.
prepare_snapshot
cp "$ENV_SNAPSHOT_DIR/env-file.after" "$ENV_FILE"
cp "$ENV_SNAPSHOT_DIR/db-env-file.after" "$DB_ENV_FILE"
: > "$ENV_SNAPSHOT_DIR/env-file.published"
: > "$ENV_SNAPSHOT_DIR/db-env-file.published"
chmod 0600 "$ENV_FILE"
chmod 0600 "$DB_ENV_FILE"
set +e
restore_runtime_env >/dev/null 2>&1
restore_status=$?
set -e
[ "$restore_status" -ne 0 ] || fail "metadata-only CAS conflict unexpectedly restored environment"
cmp -s "$ENV_FILE" "$ENV_SNAPSHOT_DIR/env-file.after" ||
  fail "metadata-only CAS conflict changed app env bytes"
[ "$(file_mode "$ENV_FILE")" = 600 ] ||
  fail "metadata-only CAS conflict changed the external app env mode"
cmp -s "$DB_ENV_FILE" "$ENV_SNAPSHOT_DIR/db-env-file.after" ||
  fail "metadata-only CAS conflict partially restored DB env"
[ "$ENV_SNAPSHOT_ACTIVE" -eq 1 ] || fail "metadata-only CAS conflict cleared active recovery state"
[ "$ENV_SNAPSHOT_CLEANUP_DEBT" -eq 1 ] || fail "metadata-only CAS conflict did not record cleanup debt"
[ -d "$ENV_SNAPSHOT_DIR" ] || fail "metadata-only CAS conflict deleted recovery evidence"

# A third-party live value matches neither the prior nor this deploy's candidate.
# The compare-and-swap boundary must reject it without changing either file or
# deleting evidence needed for operator recovery.
prepare_snapshot
printf 'APP_HOST=external.example\nSECRET_KEY_BASE=external-secret\n' > "$ENV_FILE"
cp "$ENV_SNAPSHOT_DIR/db-env-file.after" "$DB_ENV_FILE"
: > "$ENV_SNAPSHOT_DIR/env-file.published"
: > "$ENV_SNAPSHOT_DIR/db-env-file.published"
chmod 0640 "$ENV_FILE"
chmod 0600 "$DB_ENV_FILE"
set +e
restore_runtime_env >/dev/null 2>&1
restore_status=$?
set -e
[ "$restore_status" -ne 0 ] || fail "CAS conflict unexpectedly restored environment"
grep -Fq 'external-secret' "$ENV_FILE" || fail "CAS conflict overwrote external app env"
cmp -s "$DB_ENV_FILE" "$ENV_SNAPSHOT_DIR/db-env-file.after" ||
  fail "CAS conflict partially restored DB env"
[ "$ENV_SNAPSHOT_ACTIVE" -eq 1 ] || fail "CAS conflict cleared active recovery state"
[ "$ENV_SNAPSHOT_CLEANUP_DEBT" -eq 1 ] || fail "CAS conflict did not record cleanup debt"
[ -d "$ENV_SNAPSHOT_DIR" ] || fail "CAS conflict deleted recovery evidence"

printf 'ok - runtime env rollback behavior restores partial publication and rejects CAS conflicts\n'
printf '1..1\n'
