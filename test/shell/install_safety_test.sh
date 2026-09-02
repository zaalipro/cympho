#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
INSTALLER="$ROOT/install.sh"
TMP_DIR=$(mktemp -d)
TMP_DIR=$(cd "$TMP_DIR" && pwd -P)
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    case "$1" in
        *"$2"*) ;;
        *) fail "expected output to contain: $2" ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*) fail "output unexpectedly contained: $2" ;;
        *) ;;
    esac
}

# shellcheck source=../../install.sh
source "$INSTALLER"

# Production install.sh is a first-bootstrap helper, not an updater. Once its
# managed systemd unit exists it must fail before touching dependencies,
# source, environment, proxy, or service state. Any symlink at that privileged
# path (including a broken one) is also an existing/unsafe installation.
MANAGED_UNIT="$TMP_DIR/cympho-managed.service"
printf 'prior-unit\n' > "$MANAGED_UNIT"
set +e
managed_rerun_output=$(require_fresh_production_bootstrap "$MANAGED_UNIT" 2>&1)
managed_rerun_status=$?
set -e
[ "$managed_rerun_status" -ne 0 ] || fail "production rerun accepted an existing managed unit"
assert_contains "$managed_rerun_output" "first-bootstrap-only"
assert_contains "$managed_rerun_output" "no managed in-place updater"
assert_contains "$managed_rerun_output" "separate fixed-layout workflow"
[ "$(cat "$MANAGED_UNIT")" = "prior-unit" ] || fail "rerun preflight changed existing unit"

rm -f "$MANAGED_UNIT"
require_fresh_production_bootstrap "$MANAGED_UNIT"

UNIT_TARGET="$TMP_DIR/unit-target"
printf 'do-not-touch\n' > "$UNIT_TARGET"
ln -s "$UNIT_TARGET" "$MANAGED_UNIT"
set +e
unit_symlink_output=$(require_fresh_production_bootstrap "$MANAGED_UNIT" 2>&1)
unit_symlink_status=$?
set -e
[ "$unit_symlink_status" -ne 0 ] || fail "production rerun accepted a symlinked managed unit"
[ "$(cat "$UNIT_TARGET")" = "do-not-touch" ] || fail "rerun preflight followed managed unit symlink"

rm -f "$MANAGED_UNIT"
ln -s "$TMP_DIR/missing-unit-target" "$MANAGED_UNIT"
set +e
broken_unit_output=$(require_fresh_production_bootstrap "$MANAGED_UNIT" 2>&1)
broken_unit_status=$?
set -e
[ "$broken_unit_status" -ne 0 ] || fail "production rerun accepted a broken managed unit symlink"

# Production services always use a dedicated, non-root account, never the
# invoking login account (which may itself be root on a fresh VPS).
ACCOUNT_LOG="$TMP_DIR/service-account.log"
ACCOUNT_CREATED=0
run_as_root() {
    printf '%s\n' "$*" >> "$ACCOUNT_LOG"
    if [ "${1:-}" = useradd ]; then ACCOUNT_CREATED=1; fi
    return 0
}
id() {
    case "$*" in
        "-u") printf '%s\n' 1000 ;;
        "-u cympho")
            if [ "$ACCOUNT_CREATED" -eq 1 ]; then printf '%s\n' 991; else return 1; fi
            ;;
        "-g cympho"|"-G cympho") printf '%s\n' 991 ;;
        *) command id "$@" ;;
    esac
}
getent() {
    case "$*" in
        "group cympho") printf '%s\n' 'cympho:x:991:' ;;
        group) printf '%s\n' 'cympho:x:991:' ;;
        passwd) printf '%s\n' 'cympho:x:991:991::/var/lib/cympho:/usr/sbin/nologin' ;;
        *) return 1 ;;
    esac
}
ensure_production_service_account cympho cympho
assert_contains "$(cat "$ACCOUNT_LOG")" \
    "useradd --system --create-home --shell /usr/sbin/nologin --user-group cympho"

id() {
    case "$*" in
        "-u") printf '%s\n' 1000 ;;
        "-u cympho") printf '%s\n' 991 ;;
        "-g cympho"|"-G cympho") printf '%s\n' 991 ;;
        *) command id "$@" ;;
    esac
}
ensure_production_service_account cympho cympho

id() {
    case "$*" in
        "-u") printf '%s\n' 1000 ;;
        "-u cympho") printf '%s\n' 991 ;;
        "-g cympho") printf '%s\n' 991 ;;
        "-G cympho") printf '%s\n' '991 27' ;;
        *) command id "$@" ;;
    esac
}
set +e
supplementary_group_output=$(ensure_production_service_account cympho cympho 2>&1)
supplementary_group_status=$?
set -e
[ "$supplementary_group_status" -ne 0 ] || \
    fail "installer accepted a service account with supplementary groups"
assert_contains "$supplementary_group_output" "must not have supplementary groups"

getent() {
    case "$*" in
        "group cympho") printf '%s\n' 'cympho:x:0:' ;;
        group) printf '%s\n' 'cympho:x:0:' ;;
        passwd) printf '%s\n' 'cympho:x:991:0::/var/lib/cympho:/usr/sbin/nologin' ;;
        *) return 1 ;;
    esac
}
set +e
root_group_output=$(ensure_production_service_account cympho cympho 2>&1)
root_group_status=$?
set -e
[ "$root_group_status" -ne 0 ] || fail "installer accepted a zero-GID service group"
assert_contains "$root_group_output" "group must not be root"

getent() {
    case "$*" in
        "group cympho") printf '%s\n' 'cympho:x:991:alice' ;;
        group) printf '%s\n' 'cympho:x:991:alice' ;;
        passwd) printf '%s\n' 'cympho:x:991:991::/var/lib/cympho:/usr/sbin/nologin' ;;
        *) return 1 ;;
    esac
}
id() {
    case "$*" in
        "-u") printf '%s\n' 1000 ;;
        "-u cympho") printf '%s\n' 991 ;;
        "-g cympho"|"-G cympho") printf '%s\n' 991 ;;
        *) command id "$@" ;;
    esac
}
set +e
group_member_output=$(ensure_production_service_account cympho cympho 2>&1)
group_member_status=$?
set -e
[ "$group_member_status" -ne 0 ] || fail "installer accepted a service group with another member"
assert_contains "$group_member_output" "must not have named members"

getent() {
    case "$*" in
        "group cympho") printf '%s\n' 'cympho:x:991:' ;;
        group) printf '%s\n' 'cympho:x:991:' ;;
        passwd)
            printf '%s\n' \
                'cympho:x:991:991::/var/lib/cympho:/usr/sbin/nologin' \
                'alice:x:992:991::/home/alice:/bin/sh'
            ;;
        *) return 1 ;;
    esac
}
set +e
shared_gid_output=$(ensure_production_service_account cympho cympho 2>&1)
shared_gid_status=$?
set -e
[ "$shared_gid_status" -ne 0 ] || \
    fail "installer accepted another account with the service group as its primary GID"
assert_contains "$shared_gid_output" "must not be shared by another account"

getent() {
    case "$*" in
        "group cympho") printf '%s\n' 'cympho:x:991:' ;;
        group) printf '%s\n' 'cympho:x:991:' 'cympho-alias:x:991:alice' ;;
        passwd) printf '%s\n' 'cympho:x:991:991::/var/lib/cympho:/usr/sbin/nologin' ;;
        *) return 1 ;;
    esac
}
set +e
group_alias_output=$(ensure_production_service_account cympho cympho 2>&1)
group_alias_status=$?
set -e
[ "$group_alias_status" -ne 0 ] || fail "installer accepted a numeric alias of the service group"
assert_contains "$group_alias_output" "GID must not have another group alias"

getent() {
    case "$*" in
        "group cympho"|group) printf '%s\n' 'cympho:x:991:' ;;
        passwd)
            printf '%s\n' \
                'cympho:x:991:991::/var/lib/cympho:/usr/sbin/nologin' \
                'cympho-alias:x:991:992::/home/cympho-alias:/bin/sh'
            ;;
        *) return 1 ;;
    esac
}
set +e
uid_alias_output=$(ensure_production_service_account cympho cympho 2>&1)
uid_alias_status=$?
set -e
[ "$uid_alias_status" -ne 0 ] || fail "installer accepted a duplicate service UID username"
assert_contains "$uid_alias_output" "UID must not be shared by another username"

getent() {
    case "$*" in
        "group cympho"|group) printf '%s\n' 'cympho:x:991:' ;;
        passwd) printf '%s\n' 'cympho:x:991:991::/var/lib/cympho:/usr/sbin/nologin' ;;
        *) return 1 ;;
    esac
}

id() {
    case "$*" in
        "-u"|"-u cympho") printf '%s\n' 991 ;;
        "-g cympho"|"-G cympho") printf '%s\n' 991 ;;
        *) command id "$@" ;;
    esac
}
set +e
same_account_output=$(ensure_production_service_account cympho cympho 2>&1)
same_account_status=$?
set -e
[ "$same_account_status" -ne 0 ] || fail "installer accepted the service account as operator"
assert_contains "$same_account_output" "must not run as the cympho service account"
unset -f id getent run_as_root

# A hostile checkout must not be able to turn the temporary seed-script path
# into a symlink write primitive.
SEED_TARGET="$TMP_DIR/seed-target"
SEED_LINK="$TMP_DIR/seed_admin.exs"
printf 'do-not-overwrite\n' > "$SEED_TARGET"
ln -s "$SEED_TARGET" "$SEED_LINK"
set +e
seed_link_output=$(write_seed_script "$SEED_LINK" 2>&1)
seed_link_status=$?
set -e
[ "$seed_link_status" -ne 0 ] || fail "seed script helper followed an existing symlink"
[ "$(cat "$SEED_TARGET")" = "do-not-overwrite" ] || fail "seed script helper clobbered symlink target"
assert_contains "$seed_link_output" "Refusing to replace symlinked seed script"

if grep -Eq 'ALTER[[:space:]]+USER[[:space:]]+cympho_user' "$INSTALLER"; then
    fail "installer contains a database password rotation path"
fi

# Piped execution must stop before prompts or system changes.
set +e
noninteractive_output=$(printf '2\n' | "$INSTALLER" 2>&1)
noninteractive_status=$?
set -e
[ "$noninteractive_status" -ne 0 ] || fail "non-interactive installer unexpectedly succeeded"
assert_contains "$noninteractive_output" "interactive"
assert_contains "$noninteractive_output" "run ./install.sh from a terminal"
assert_not_contains "$noninteractive_output" "Welcome to Cympho"

# The extracted prompt still maps explicit interactive choices correctly.
prompt_install_type <<<"2" >"$TMP_DIR/prompt.out" 2>&1
prompt_output=$(cat "$TMP_DIR/prompt.out")
[ "$IS_PROD" -eq 1 ] || fail "production prompt did not set IS_PROD=1"
assert_contains "$prompt_output" "Production VPS"

ENV_FILE="$TMP_DIR/.env"
[ "$(production_env_state "$ENV_FILE")" = "new" ] || fail "missing .env was not new"

BUILD_REVISION=$(git -C "$ROOT" rev-parse --verify "HEAD^{commit}")
export BUILD_REVISION

SOURCE_REPO="$TMP_DIR/source-repo"
mkdir "$SOURCE_REPO"
git -C "$SOURCE_REPO" init -q
git -C "$SOURCE_REPO" config user.name "Installer Test"
git -C "$SOURCE_REPO" config user.email "installer@example.test"
printf 'tracked\n' > "$SOURCE_REPO/tracked.txt"
git -C "$SOURCE_REPO" add tracked.txt
git -C "$SOURCE_REPO" commit -qm initial
expected_source_revision=$(git -C "$SOURCE_REPO" rev-parse --verify "HEAD^{commit}")
[ "$(production_build_revision "$SOURCE_REPO")" = "$expected_source_revision" ] || \
    fail "clean production checkout did not derive exact HEAD"

# Production work must happen in an exact Git-object snapshot, not in the
# checkout that was clean only at the earlier attestation point. Changes made
# after staging must neither alter the staged bytes nor appear at runtime.
SOURCE_SNAPSHOT="$TMP_DIR/source-snapshot"
run_as_root() {
    case "$1" in
        chown) return 0 ;;
        install)
            shift
            [ "$1" = "-d" ] || fail "unexpected snapshot install command"
            local destination_arg
            for destination_arg in "$@"; do :; done
            mkdir -p "$destination_arg"
            ;;
        *) "$@" ;;
    esac
}
stage_production_source_snapshot \
    "$SOURCE_REPO" "$expected_source_revision" "$SOURCE_SNAPSHOT" >/dev/null
[ "$(cat "$SOURCE_SNAPSHOT/tracked.txt")" = "tracked" ] || \
    fail "production snapshot did not contain the attested tracked bytes"
[ ! -e "$SOURCE_SNAPSHOT/.git" ] || fail "production snapshot copied Git metadata"
printf 'changed after attestation\n' > "$SOURCE_REPO/tracked.txt"
printf 'untracked after attestation\n' > "$SOURCE_REPO/untracked-after-attestation.txt"
[ "$(cat "$SOURCE_SNAPSHOT/tracked.txt")" = "tracked" ] || \
    fail "checkout mutation changed the staged production source"
[ ! -e "$SOURCE_SNAPSHOT/untracked-after-attestation.txt" ] || \
    fail "untracked checkout bytes entered the staged production source"
git -C "$SOURCE_REPO" checkout -q -- tracked.txt
rm "$SOURCE_REPO/untracked-after-attestation.txt"

# Local replace refs must not make revision attestation name one commit while
# archive materialization silently reads another object's tree.
printf 'replacement bytes\n' > "$SOURCE_REPO/tracked.txt"
git -C "$SOURCE_REPO" commit -qam replacement
replacement_revision=$(git -C "$SOURCE_REPO" rev-parse HEAD)
git -C "$SOURCE_REPO" replace "$expected_source_revision" "$replacement_revision"
git -C "$SOURCE_REPO" checkout -q "$expected_source_revision"
REPLACE_SNAPSHOT="$TMP_DIR/replace-snapshot"
stage_production_source_snapshot \
    "$SOURCE_REPO" "$expected_source_revision" "$REPLACE_SNAPSHOT" >/dev/null
[ "$(cat "$REPLACE_SNAPSHOT/tracked.txt")" = "tracked" ] || \
    fail "Git replace ref changed the attested production snapshot bytes"
git -C "$SOURCE_REPO" replace -d "$expected_source_revision" >/dev/null

# A source commit containing a symlink is rejected before archive extraction,
# even when the link target would remain inside the staged tree.
ln -s tracked.txt "$SOURCE_REPO/tracked-link"
git -C "$SOURCE_REPO" add tracked-link
git -C "$SOURCE_REPO" commit -qm 'add symlink'
symlink_revision=$(git -C "$SOURCE_REPO" rev-parse HEAD)
set +e
symlink_snapshot_output=$(stage_production_source_snapshot \
    "$SOURCE_REPO" "$symlink_revision" "$TMP_DIR/symlink-snapshot" 2>&1)
symlink_snapshot_status=$?
set -e
[ "$symlink_snapshot_status" -ne 0 ] || fail "production source accepted a committed symlink"
[ ! -e "$TMP_DIR/symlink-snapshot" ] || fail "unsafe source symlink snapshot was published"
assert_contains "$symlink_snapshot_output" "must not contain symlinks"
git -C "$SOURCE_REPO" checkout -q "$expected_source_revision"

BROKEN_SNAPSHOT="$TMP_DIR/broken-snapshot"
ln -s "$TMP_DIR/does-not-exist" "$BROKEN_SNAPSHOT"
set +e
broken_snapshot_output=$(stage_production_source_snapshot \
    "$SOURCE_REPO" "$expected_source_revision" "$BROKEN_SNAPSHOT" 2>&1)
broken_snapshot_status=$?
set -e
[ "$broken_snapshot_status" -ne 0 ] || fail "broken symlink snapshot destination was accepted"
assert_contains "$broken_snapshot_output" "must not be a symlink"

ANCESTOR_TARGET="$TMP_DIR/ancestor-target"
ANCESTOR_LINK="$TMP_DIR/ancestor-link"
mkdir "$ANCESTOR_TARGET"
ln -s "$ANCESTOR_TARGET" "$ANCESTOR_LINK"
set +e
ancestor_snapshot_output=$(stage_production_source_snapshot \
    "$SOURCE_REPO" "$expected_source_revision" "$ANCESTOR_LINK/source/revision" 2>&1)
ancestor_snapshot_status=$?
set -e
[ "$ancestor_snapshot_status" -ne 0 ] || fail "symlinked snapshot ancestor was accepted"
[ ! -e "$ANCESTOR_TARGET/source" ] || fail "snapshot staging followed a symlinked ancestor"
assert_contains "$ancestor_snapshot_output" "must not be a symlink"

# A plain Mix release is completed with the same versioned operator tooling and
# identity manifest as the Docker release builders.
RELEASE_FIXTURE="$TMP_DIR/release-fixture"
mkdir -p "$RELEASE_FIXTURE/bin" "$RELEASE_FIXTURE/_build/prod/rel/cympho/bin"
cat > "$RELEASE_FIXTURE/mix.exs" <<'EOF_MIX'
defmodule Fixture.MixProject do
  use Mix.Project
  def project, do: [app: :cympho, version: "1.2.3"]
end
EOF_MIX
cp "$ROOT/bin/cymphoctl" "$RELEASE_FIXTURE/bin/cymphoctl"
cp "$ROOT/bin/cympho-health-validator" "$RELEASE_FIXTURE/bin/cympho-health-validator"
cat > "$RELEASE_FIXTURE/_build/prod/rel/cympho/bin/cympho" <<EOF_RELEASE
#!/usr/bin/env bash
printf '%s' '$expected_source_revision'
EOF_RELEASE
chmod +x "$RELEASE_FIXTURE/_build/prod/rel/cympho/bin/cympho"

install_release_operator_tools "$RELEASE_FIXTURE" "$expected_source_revision"

# A symlink in the release path ancestry must not redirect validation or
# sealing outside the staged source snapshot.
RELEASE_ANCESTOR_FIXTURE="$TMP_DIR/release-ancestor-fixture"
RELEASE_ANCESTOR_OUTSIDE="$TMP_DIR/release-ancestor-outside"
mkdir -p "$RELEASE_ANCESTOR_FIXTURE/bin" "$RELEASE_ANCESTOR_OUTSIDE"
cp "$ROOT/bin/cympho-health-validator" "$RELEASE_ANCESTOR_FIXTURE/bin/"
cp -R "$RELEASE_FIXTURE/_build/prod" "$RELEASE_ANCESTOR_OUTSIDE/prod"
mkdir -p "$RELEASE_ANCESTOR_OUTSIDE/prod/rel/cympho/releases"
printf 'cookie\n' > "$RELEASE_ANCESTOR_OUTSIDE/prod/rel/cympho/releases/COOKIE"
ln -s "$RELEASE_ANCESTOR_OUTSIDE" "$RELEASE_ANCESTOR_FIXTURE/_build"
set +e
ancestor_release_output=$(validate_production_release_payload \
    "$RELEASE_ANCESTOR_FIXTURE" "$expected_source_revision" 2>&1)
ancestor_release_status=$?
ancestor_seal_output=$(seal_production_source_snapshot \
    "$RELEASE_ANCESTOR_FIXTURE" cympho 2>&1)
ancestor_seal_status=$?
set -e
[ "$ancestor_release_status" -ne 0 ] || fail "release validation followed a symlink ancestor"
[ "$ancestor_seal_status" -ne 0 ] || fail "release sealing followed a symlink ancestor"
assert_contains "$ancestor_release_output" "ancestors"
assert_contains "$ancestor_seal_output" "ancestors"
[ -x "$RELEASE_FIXTURE/_build/prod/rel/cympho/bin/cymphoctl" ] || \
    fail "plain release is missing cymphoctl"
[ -x "$RELEASE_FIXTURE/_build/prod/rel/cympho/bin/cympho-health-validator" ] || \
    fail "plain release is missing the health validator"
[ "$(python3 "$ROOT/bin/cympho-health-validator" release-revision \
    "$RELEASE_FIXTURE/_build/prod/rel/cympho/release-info.json")" = \
    "$expected_source_revision" ] || fail "plain release identity manifest is invalid"
validate_production_release_payload "$RELEASE_FIXTURE" "$expected_source_revision"

# Release identity publication must not follow an existing symlink.
RELEASE_INFO_TARGET="$TMP_DIR/release-info-outside"
printf 'must-not-overwrite\n' > "$RELEASE_INFO_TARGET"
rm -f "$RELEASE_FIXTURE/_build/prod/rel/cympho/release-info.json"
ln -s "$RELEASE_INFO_TARGET" "$RELEASE_FIXTURE/_build/prod/rel/cympho/release-info.json"
set +e
release_info_link_output=$(install_release_operator_tools \
    "$RELEASE_FIXTURE" "$expected_source_revision" 2>&1)
release_info_link_status=$?
set -e
[ "$release_info_link_status" -ne 0 ] || fail "release-info publication followed a symlink"
[ "$(cat "$RELEASE_INFO_TARGET")" = "must-not-overwrite" ] || \
    fail "release-info publication clobbered a symlink target"
assert_contains "$release_info_link_output" "symlink"
rm -f "$RELEASE_FIXTURE/_build/prod/rel/cympho/release-info.json"
install_release_operator_tools "$RELEASE_FIXTURE" "$expected_source_revision"

TOOL_LINK_TARGET="$TMP_DIR/tool-outside"
printf 'must-not-overwrite\n' > "$TOOL_LINK_TARGET"
rm -f "$RELEASE_FIXTURE/_build/prod/rel/cympho/bin/cymphoctl"
ln -s "$TOOL_LINK_TARGET" "$RELEASE_FIXTURE/_build/prod/rel/cympho/bin/cymphoctl"
set +e
tool_link_output=$(install_release_operator_tools \
    "$RELEASE_FIXTURE" "$expected_source_revision" 2>&1)
tool_link_status=$?
set -e
[ "$tool_link_status" -ne 0 ] || fail "operator tool publication followed a symlink"
[ "$(cat "$TOOL_LINK_TARGET")" = "must-not-overwrite" ] || \
    fail "operator tool publication clobbered a symlink target"
assert_contains "$tool_link_output" "symlink"
rm -f "$RELEASE_FIXTURE/_build/prod/rel/cympho/bin/cymphoctl"
install_release_operator_tools "$RELEASE_FIXTURE" "$expected_source_revision"

# No symlink is permitted anywhere in the final release payload, not merely at
# the operator entry points checked individually below.
ln -s /tmp "$RELEASE_FIXTURE/_build/prod/rel/cympho/escaped-state"
set +e
release_symlink_output=$(validate_production_release_payload \
    "$RELEASE_FIXTURE" "$expected_source_revision" 2>&1)
release_symlink_status=$?
set -e
[ "$release_symlink_status" -ne 0 ] || fail "release validation accepted a payload symlink"
assert_contains "$release_symlink_output" "must not contain symlinks"
rm "$RELEASE_FIXTURE/_build/prod/rel/cympho/escaped-state"

COMMAND_EXISTS_DEFINITION=$(declare -f command_exists)
command_exists() {
    [ "$1" != python3 ]
}
set +e
missing_python_output=$(validate_production_release_payload \
    "$RELEASE_FIXTURE" "$expected_source_revision" 2>&1)
missing_python_status=$?
set -e
eval "$COMMAND_EXISTS_DEFINITION"
[ "$missing_python_status" -ne 0 ] || fail "release validation accepted missing python3"
assert_contains "$missing_python_output" "Python 3 is required"

COMMAND_EXISTS_DEFINITION=$(declare -f command_exists)
command_exists() {
    [ "$1" != timeout ]
}
set +e
missing_timeout_output=$(validate_production_release_payload \
    "$RELEASE_FIXTURE" "$expected_source_revision" 2>&1)
missing_timeout_status=$?
set -e
eval "$COMMAND_EXISTS_DEFINITION"
[ "$missing_timeout_status" -eq 0 ] || \
    fail "release validation required non-portable timeout command"

rm "$RELEASE_FIXTURE/_build/prod/rel/cympho/bin/cymphoctl"
set +e
missing_cli_output=$(validate_production_release_payload \
    "$RELEASE_FIXTURE" "$expected_source_revision" 2>&1)
missing_cli_status=$?
set -e
[ "$missing_cli_status" -ne 0 ] || fail "release validation accepted a missing cymphoctl"
assert_contains "$missing_cli_output" "operator tooling"

printf 'untracked\n' > "$SOURCE_REPO/untracked.txt"
set +e
dirty_source_output=$(production_build_revision "$SOURCE_REPO" 2>&1)
dirty_source_status=$?
set -e
[ "$dirty_source_status" -ne 0 ] || fail "dirty production checkout was accepted"
assert_contains "$dirty_source_output" "clean Git checkout"
rm "$SOURCE_REPO/untracked.txt"

PASSWORD_SENTINEL="database-password-must-stay-private"
cat > "$ENV_FILE" <<EOF_ENV
MIX_ENV=prod
PORT=4000
APP_HOST=cympho.example.test
PREVIEW_HOST=preview.cympho.example.test
SECRET_KEY_BASE=secret-key
LIVE_VIEW_SALT=live-salt
CYMPHO_ENCRYPTION_KEY=encryption-key
CYMPHO_USER_JWT_SECRET=user-jwt
CYMPHO_AGENT_JWT_SECRET=agent-jwt
CYMPHO_BUILD_REVISION=$BUILD_REVISION
DATABASE_URL=ecto://cympho_user:$PASSWORD_SENTINEL@localhost/cympho_prod
CYMPHO_UPLOADS_DIR=/var/lib/cympho/data/uploads
CYMPHO_IMPORT_SPOOL_DIR=/var/lib/cympho/data/import-transfers
EOF_ENV

[ "$(production_env_state "$ENV_FILE")" = "existing" ] || fail "regular .env was not existing"
before_checksum=$(cksum "$ENV_FILE")
validation_output=$(validate_existing_production_env \
    "$ENV_FILE" cympho.example.test preview.cympho.example.test "$BUILD_REVISION" 2>&1)
after_checksum=$(cksum "$ENV_FILE")
[ "$before_checksum" = "$after_checksum" ] || fail "rerun validation changed .env"
[ -z "$validation_output" ] || fail "successful validation printed environment data"

# A legacy otherwise-valid environment may add the new non-secret revision
# atomically before the strict production preflight is run.
LEGACY_ENV_FILE="$TMP_DIR/.env-legacy-no-revision"
grep -v '^CYMPHO_BUILD_REVISION=' "$ENV_FILE" > "$LEGACY_ENV_FILE"
reconcile_production_build_revision "$LEGACY_ENV_FILE" "$BUILD_REVISION"
validate_existing_production_env \
    "$LEGACY_ENV_FILE" cympho.example.test preview.cympho.example.test "$BUILD_REVISION"

LEGACY_RUNTIME_ENV_FILE="$TMP_DIR/.env-legacy-runtime-paths"
grep -Ev '^(CYMPHO_UPLOADS_DIR|CYMPHO_IMPORT_SPOOL_DIR)=' "$ENV_FILE" > "$LEGACY_RUNTIME_ENV_FILE"
set +e
legacy_runtime_status=0
validate_existing_production_env \
    "$LEGACY_RUNTIME_ENV_FILE" cympho.example.test preview.cympho.example.test \
    "$BUILD_REVISION" >/dev/null 2>&1 || legacy_runtime_status=$?
set -e
[ "$legacy_runtime_status" -ne 0 ] || fail "legacy runtime paths were accepted before reconciliation"
validate_existing_production_env \
    "$LEGACY_RUNTIME_ENV_FILE" cympho.example.test preview.cympho.example.test \
    "$BUILD_REVISION" false true
reconcile_production_env_key \
    "$LEGACY_RUNTIME_ENV_FILE" CYMPHO_UPLOADS_DIR /var/lib/cympho/data/uploads
reconcile_production_env_key \
    "$LEGACY_RUNTIME_ENV_FILE" CYMPHO_IMPORT_SPOOL_DIR /var/lib/cympho/data/import-transfers
validate_existing_production_env \
    "$LEGACY_RUNTIME_ENV_FILE" cympho.example.test preview.cympho.example.test "$BUILD_REVISION"

# Failed legacy preflight must not rewrite even the managed metadata when a
# required credential is missing.
INCOMPLETE_LEGACY_ENV_FILE="$TMP_DIR/.env-incomplete-legacy"
grep -Ev '^(CYMPHO_BUILD_REVISION|SECRET_KEY_BASE)=' "$ENV_FILE" > "$INCOMPLETE_LEGACY_ENV_FILE"
incomplete_before=$(cksum "$INCOMPLETE_LEGACY_ENV_FILE")
set +e
incomplete_legacy_output=$(validate_existing_production_env \
    "$INCOMPLETE_LEGACY_ENV_FILE" cympho.example.test preview.cympho.example.test "" true 2>&1)
incomplete_legacy_status=$?
set -e
[ "$incomplete_legacy_status" -ne 0 ] || fail "incomplete legacy environment passed preflight"
[ "$incomplete_before" = "$(cksum "$INCOMPLETE_LEGACY_ENV_FILE")" ] || \
    fail "failed legacy preflight changed the environment"
assert_contains "$incomplete_legacy_output" "SECRET_KEY_BASE"

stale_revision=$(printf '0%.0s' {1..40})
STALE_ENV_FILE="$TMP_DIR/.env-stale-revision"
sed "s/^CYMPHO_BUILD_REVISION=.*/CYMPHO_BUILD_REVISION=$stale_revision/" \
    "$ENV_FILE" > "$STALE_ENV_FILE"
secret_before=$(grep '^DATABASE_URL=' "$STALE_ENV_FILE")
reconcile_production_build_revision "$STALE_ENV_FILE" "$BUILD_REVISION"
[ "$(grep -c '^CYMPHO_BUILD_REVISION=' "$STALE_ENV_FILE")" -eq 1 ] || \
    fail "revision reconciliation duplicated the assignment"
[ "$(grep '^CYMPHO_BUILD_REVISION=' "$STALE_ENV_FILE")" = \
    "CYMPHO_BUILD_REVISION=$BUILD_REVISION" ] || fail "stale revision was not reconciled"
[ "$(grep '^DATABASE_URL=' "$STALE_ENV_FILE")" = "$secret_before" ] || \
    fail "revision reconciliation changed a secret"
validate_existing_production_env \
    "$STALE_ENV_FILE" cympho.example.test preview.cympho.example.test "$BUILD_REVISION"

# Runtime data stays outside the root-owned release payload. The installer
# creates only these writable leaves for the service account.
RUNTIME_DIR_LOG="$TMP_DIR/runtime-directories.log"
run_as_root() {
    printf '%s\n' "$*" >> "$RUNTIME_DIR_LOG"

    case "$1" in
        chown) return 0 ;;
        install)
            shift
            local mode=""
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    -d) shift ;;
                    -m) mode=$2; shift 2 ;;
                    -o|-g) shift 2 ;;
                    *) break ;;
                esac
            done
            install -d -m "$mode" "$@"
            ;;
        *) "$@" ;;
    esac
}
RUNTIME_UPLOADS_DIR="$TMP_DIR/runtime-data/uploads"
RUNTIME_IMPORT_DIR="$TMP_DIR/runtime-data/import-transfers"
mkdir -p "$RUNTIME_UPLOADS_DIR" "$RUNTIME_IMPORT_DIR"
chmod 0750 "$RUNTIME_UPLOADS_DIR" "$RUNTIME_IMPORT_DIR"
CUSTOM_RUNTIME_ENV="$TMP_DIR/.env-custom-runtime-paths"
sed \
    -e "s|^CYMPHO_UPLOADS_DIR=.*|CYMPHO_UPLOADS_DIR=$RUNTIME_UPLOADS_DIR|" \
    -e "s|^CYMPHO_IMPORT_SPOOL_DIR=.*|CYMPHO_IMPORT_SPOOL_DIR=$RUNTIME_IMPORT_DIR|" \
    "$ENV_FILE" > "$CUSTOM_RUNTIME_ENV"
reconcile_production_env_key \
    "$CUSTOM_RUNTIME_ENV" CYMPHO_UPLOADS_DIR /var/lib/cympho/data/uploads
reconcile_production_env_key \
    "$CUSTOM_RUNTIME_ENV" CYMPHO_IMPORT_SPOOL_DIR /var/lib/cympho/data/import-transfers
assert_contains "$(cat "$CUSTOM_RUNTIME_ENV")" "CYMPHO_UPLOADS_DIR=$RUNTIME_UPLOADS_DIR"
assert_contains "$(cat "$CUSTOM_RUNTIME_ENV")" "CYMPHO_IMPORT_SPOOL_DIR=$RUNTIME_IMPORT_DIR"
validate_existing_production_env \
    "$CUSTOM_RUNTIME_ENV" cympho.example.test preview.cympho.example.test "$BUILD_REVISION"

UNSAFE_RUNTIME_ENV="$TMP_DIR/.env-unsafe-runtime-path"
sed 's|^CYMPHO_UPLOADS_DIR=.*|CYMPHO_UPLOADS_DIR=/tmp/../release|' \
    "$CUSTOM_RUNTIME_ENV" > "$UNSAFE_RUNTIME_ENV"
set +e
unsafe_env_output=$(validate_existing_production_env \
    "$UNSAFE_RUNTIME_ENV" cympho.example.test preview.cympho.example.test \
    "$BUILD_REVISION" 2>&1)
unsafe_env_status=$?
set -e
[ "$unsafe_env_status" -ne 0 ] || fail "unsafe runtime path passed environment preflight"
assert_contains "$unsafe_env_output" "persistent safe absolute path"
prepare_production_runtime_directories \
    "$(id -un)" "$RUNTIME_UPLOADS_DIR" "$RUNTIME_IMPORT_DIR"
runtime_dir_commands=$(cat "$RUNTIME_DIR_LOG")
assert_not_contains "$runtime_dir_commands" "install -d"
[ -w "$RUNTIME_UPLOADS_DIR" ] || fail "production uploads directory is not writable"
[ -w "$RUNTIME_IMPORT_DIR" ] || fail "production import directory is not writable"

PRODUCTION_SOURCE_STAGE="$SOURCE_SNAPSHOT"
set +e
unsafe_runtime_output=$(prepare_production_runtime_directories \
    "$(id -un)" "$SOURCE_SNAPSHOT/uploads" "$RUNTIME_IMPORT_DIR" 2>&1)
unsafe_runtime_status=$?
set -e
PRODUCTION_SOURCE_STAGE=""
[ "$unsafe_runtime_status" -ne 0 ] || fail "snapshot-contained runtime data path was accepted"
assert_contains "$unsafe_runtime_output" "outside the production source snapshot"

RUNTIME_SYMLINK="$TMP_DIR/runtime-symlink"
ln -s "$RUNTIME_UPLOADS_DIR" "$RUNTIME_SYMLINK"
set +e
runtime_symlink_output=$(prepare_production_runtime_directories \
    "$(id -un)" "$RUNTIME_SYMLINK" "$RUNTIME_IMPORT_DIR" 2>&1)
runtime_symlink_status=$?
set -e
[ "$runtime_symlink_status" -ne 0 ] || fail "symlinked custom runtime path was accepted"
assert_contains "$runtime_symlink_output" "non-symlink directory"

SNAPSHOT_COOKIE="$SOURCE_SNAPSHOT/_build/prod/rel/cympho/releases/COOKIE"
mkdir -p "$(dirname "$SNAPSHOT_COOKIE")"
printf 'release-cookie\n' > "$SNAPSHOT_COOKIE"
chmod 0644 "$SNAPSHOT_COOKIE"
seal_production_source_snapshot "$SOURCE_SNAPSHOT" cympho
[ ! -w "$SOURCE_SNAPSHOT" ] || fail "production source snapshot remained writable"
[ ! -w "$SOURCE_SNAPSHOT/tracked.txt" ] || fail "staged production source bytes remained writable"
if ! python3 - "$SOURCE_SNAPSHOT" "$SNAPSHOT_COOKIE" <<'PY'
import os
import stat
import sys

snapshot_mode = stat.S_IMODE(os.stat(sys.argv[1]).st_mode)
cookie_mode = stat.S_IMODE(os.stat(sys.argv[2]).st_mode)
accessible_snapshot = snapshot_mode & 0o050 == 0o050 and snapshot_mode & 0o007 == 0
protected_cookie = cookie_mode == 0o440
raise SystemExit(0 if accessible_snapshot and protected_cookie else 1)
PY
then
    fail "sealed production release is not service-readable with a protected cookie"
fi
chmod -R u+w "$SOURCE_SNAPSHOT"

invalid_revision_file="$TMP_DIR/.env-invalid-revision"
sed 's/^CYMPHO_BUILD_REVISION=.*/CYMPHO_BUILD_REVISION=unknown/' "$ENV_FILE" > "$invalid_revision_file"
set +e
invalid_revision_output=$(validate_existing_production_env \
    "$invalid_revision_file" cympho.example.test preview.cympho.example.test "$BUILD_REVISION" 2>&1)
invalid_revision_status=$?
set -e
[ "$invalid_revision_status" -ne 0 ] || fail "unknown production build revision was accepted"
assert_contains "$invalid_revision_output" "CYMPHO_BUILD_REVISION"

# The checked-in service and Caddy fragment are fixed to port 4000. A preserved
# production environment using another port must fail before either is restarted.
MISMATCHED_ENV_FILE="$TMP_DIR/.env-mismatched-port"
sed 's/^PORT=4000$/PORT=9999/' "$ENV_FILE" > "$MISMATCHED_ENV_FILE"
set +e
mismatched_port_output=$(validate_existing_production_env \
    "$MISMATCHED_ENV_FILE" cympho.example.test preview.cympho.example.test 2>&1)
mismatched_port_status=$?
set -e
[ "$mismatched_port_status" -ne 0 ] || fail "mismatched production port was accepted"
assert_contains "$mismatched_port_output" "PORT=4000"

# Existing credentials skip every PostgreSQL command, especially password rotation.
DB_LOG="$TMP_DIR/db.log"
run_as_postgres() {
    local stdin
    printf '%s\n' "$*" >> "$DB_LOG"

    if [[ " $* " != *" -c "* ]]; then
        stdin=$(cat)
        if [ -n "$stdin" ]; then
            printf '%s\n' "$stdin" >> "$DB_LOG"
        fi
    fi
}
rerun_output=$(provision_production_database existing Linux "should-not-be-used" 2>&1)
[ ! -e "$DB_LOG" ] || fail "rerun invoked PostgreSQL"
assert_contains "$rerun_output" "Preserving"
assert_not_contains "$rerun_output" "$PASSWORD_SENTINEL"
assert_not_contains "$rerun_output" "should-not-be-used"

# A first install creates the role once and never emits ALTER USER.
provision_production_database new Linux "newpassword123" >/dev/null
first_install_sql=$(cat "$DB_LOG")
assert_contains "$first_install_sql" "SELECT 1 FROM pg_roles"
assert_contains "$first_install_sql" "CREATE USER cympho_user"
assert_not_contains "$first_install_sql" "ALTER USER"

# A missing .env plus a pre-existing role is inconsistent and must fail closed.
: > "$DB_LOG"
run_as_postgres() {
    printf '%s\n' "$*" >> "$DB_LOG"
    if [[ " $* " == *" -c "* ]]; then
        printf '1\n'
    else
        cat >/dev/null
    fi
}
PRODUCTION_DATABASE_MUTATION_ATTEMPTED=0
set +e
inconsistent_output=$(provision_production_database new Linux "replacement-password" 2>&1)
inconsistent_status=$?
set -e
[ "$inconsistent_status" -ne 0 ] || fail "existing role without .env did not fail"
assert_contains "$inconsistent_output" "refusing to replace its password"
inconsistent_commands=$(cat "$DB_LOG")
assert_not_contains "$inconsistent_commands" "CREATE USER"
assert_not_contains "$inconsistent_commands" "ALTER USER"
assert_not_contains "$inconsistent_output" "replacement-password"
[ "${PRODUCTION_DATABASE_MUTATION_ATTEMPTED:-0}" -eq 0 ] || \
    fail "preflight failure claimed a database mutation attempt"

# Once CREATE is sent, failure is ambiguous and the installer must retain the
# exact matching environment instead of stranding an unknown password.
run_as_postgres() {
    if [[ " $* " == *" -c "* ]]; then
        return 0
    fi

    cat >/dev/null
    return 1
}
PRODUCTION_DATABASE_MUTATION_ATTEMPTED=0
set +e
provision_production_database new Linux "ambiguous-password" >/dev/null 2>&1
ambiguous_status=$?
set -e
[ "$ambiguous_status" -ne 0 ] || fail "mocked CREATE failure succeeded"
[ "$PRODUCTION_DATABASE_MUTATION_ATTEMPTED" -eq 1 ] || \
    fail "CREATE failure was not marked ambiguous"

# Missing, duplicate, or mismatched preserved configuration must fail closed.
cp "$ENV_FILE" "$TMP_DIR/incomplete.env"
sed -i.bak '/^DATABASE_URL=/d' "$TMP_DIR/incomplete.env"
set +e
invalid_output=$(validate_existing_production_env \
    "$TMP_DIR/incomplete.env" cympho.example.test preview.cympho.example.test 2>&1)
invalid_status=$?
set -e
[ "$invalid_status" -ne 0 ] || fail "incomplete .env passed validation"
assert_contains "$invalid_output" "missing DATABASE_URL"
assert_not_contains "$invalid_output" "$PASSWORD_SENTINEL"

set +e
mismatch_output=$(validate_existing_production_env \
    "$ENV_FILE" other.example.test preview.cympho.example.test 2>&1)
mismatch_status=$?
set -e
[ "$mismatch_status" -ne 0 ] || fail "mismatched domain passed validation"
assert_contains "$mismatch_output" "does not match APP_HOST"
assert_not_contains "$mismatch_output" "$PASSWORD_SENTINEL"

# Existing .env is data, never shell code. Command substitutions, quoting,
# whitespace tricks, unknown keys, and duplicate assignments all fail closed.
MALICIOUS_MARKER="$TMP_DIR/malicious-was-executed"
cp "$ENV_FILE" "$TMP_DIR/malicious.env"
sed -i.bak \
    "s|^DATABASE_URL=.*|DATABASE_URL=\$(touch $MALICIOUS_MARKER)|" \
    "$TMP_DIR/malicious.env"
set +e
malicious_output=$(validate_existing_production_env \
    "$TMP_DIR/malicious.env" cympho.example.test preview.cympho.example.test 2>&1)
malicious_status=$?
set -e
[ "$malicious_status" -ne 0 ] || fail "command substitution passed validation"
[ ! -e "$MALICIOUS_MARKER" ] || fail "installer evaluated command substitution"
assert_contains "$malicious_output" "non-literal or malformed assignment"
assert_not_contains "$malicious_output" "$PASSWORD_SENTINEL"

cp "$ENV_FILE" "$TMP_DIR/export.env"
sed -i.bak 's/^MIX_ENV=/export MIX_ENV=/' "$TMP_DIR/export.env"
set +e
export_output=$(validate_existing_production_env \
    "$TMP_DIR/export.env" cympho.example.test preview.cympho.example.test 2>&1)
export_status=$?
set -e
[ "$export_status" -ne 0 ] || fail "shell-only export assignment passed validation"
assert_contains "$export_output" "non-literal or malformed assignment"

cp "$ENV_FILE" "$TMP_DIR/duplicate.env"
printf 'DATABASE_URL=ecto://duplicate.example/cympho\n' >> "$TMP_DIR/duplicate.env"
set +e
duplicate_output=$(validate_existing_production_env \
    "$TMP_DIR/duplicate.env" cympho.example.test preview.cympho.example.test 2>&1)
duplicate_status=$?
set -e
[ "$duplicate_status" -ne 0 ] || fail "duplicate assignment passed validation"
assert_contains "$duplicate_output" "more than one DATABASE_URL"

cp "$ENV_FILE" "$TMP_DIR/unknown.env"
printf 'PATH=/operator-controlled/path\n' >> "$TMP_DIR/unknown.env"
set +e
unknown_output=$(validate_existing_production_env \
    "$TMP_DIR/unknown.env" cympho.example.test preview.cympho.example.test 2>&1)
unknown_status=$?
set -e
[ "$unknown_status" -ne 0 ] || fail "unknown assignment passed validation"
assert_contains "$unknown_output" "unsupported key PATH"

ln -s "$ENV_FILE" "$TMP_DIR/env-link"
set +e
symlink_output=$(production_env_state "$TMP_DIR/env-link" 2>&1)
symlink_status=$?
set -e
[ "$symlink_status" -ne 0 ] || fail "symlink .env was accepted"
assert_contains "$symlink_output" "non-symlink"

ln -s "$TMP_DIR/missing.env" "$TMP_DIR/broken-env-link"
set +e
broken_env_output=$(production_env_state "$TMP_DIR/broken-env-link" 2>&1)
broken_env_status=$?
set -e
[ "$broken_env_status" -ne 0 ] || fail "broken symlink .env was treated as a new environment"
assert_contains "$broken_env_output" "non-symlink"

# First-install config is published atomically before provisioning. A failed
# provisioning attempt removes it only while it is still the staged inode.
STAGED_ENV="$TMP_DIR/staged.env"
PUBLISHED_ENV="$TMP_DIR/published.env"
printf 'DATABASE_URL=ecto://generated-private-value\n' > "$STAGED_ENV"
chmod 600 "$STAGED_ENV"
install_staged_production_env "$STAGED_ENV" "$PUBLISHED_ENV"
env_file_is_staged_file "$PUBLISHED_ENV" "$STAGED_ENV" || \
    fail "published .env is not the staged inode"
cleanup_production_env_stage "$PUBLISHED_ENV" "$STAGED_ENV" 0
[ ! -e "$PUBLISHED_ENV" ] || fail "failed provisioning left published .env"
[ ! -e "$STAGED_ENV" ] || fail "failed provisioning left staged .env"

# A concurrent file wins without being overwritten or removed.
printf 'DATABASE_URL=ecto://staged-private-value\n' > "$STAGED_ENV"
printf 'OPERATOR_CONFIG=preserve-me\n' > "$PUBLISHED_ENV"
set +e
race_output=$(install_staged_production_env "$STAGED_ENV" "$PUBLISHED_ENV" 2>&1)
race_status=$?
set -e
[ "$race_status" -ne 0 ] || fail "concurrent .env did not fail"
[ "$(cat "$PUBLISHED_ENV")" = "OPERATOR_CONFIG=preserve-me" ] || \
    fail "concurrent .env was overwritten"
cleanup_production_env_stage "$PUBLISHED_ENV" "$STAGED_ENV" 0 >/dev/null 2>&1
[ -e "$STAGED_ENV" ] || fail "changed-inode recovery configuration was removed"
[ "$(cat "$PUBLISHED_ENV")" = "OPERATOR_CONFIG=preserve-me" ] || \
    fail "cleanup removed concurrent .env"
assert_not_contains "$race_output" "staged-private-value"

# Once provisioning succeeds, cleanup removes only the extra staging name and
# retains the exact published inode needed to recover its database credential.
rm -f "$PUBLISHED_ENV" "$STAGED_ENV"
printf 'DATABASE_URL=ecto://recoverable-private-value\n' > "$STAGED_ENV"
install_staged_production_env "$STAGED_ENV" "$PUBLISHED_ENV"
cleanup_production_env_stage "$PUBLISHED_ENV" "$STAGED_ENV" 1
[ -e "$PUBLISHED_ENV" ] || fail "successful provisioning removed .env"
[ ! -e "$STAGED_ENV" ] || fail "successful provisioning retained extra stage name"

# An ambiguous CREATE result follows the same retention path.
rm -f "$PUBLISHED_ENV"
printf 'DATABASE_URL=ecto://ambiguous-private-value\n' > "$STAGED_ENV"
install_staged_production_env "$STAGED_ENV" "$PUBLISHED_ENV"
cleanup_production_env_stage "$PUBLISHED_ENV" "$STAGED_ENV" \
    "$PRODUCTION_DATABASE_MUTATION_ATTEMPTED"
[ -e "$PUBLISHED_ENV" ] || fail "ambiguous CREATE removed recovery .env"
[ ! -e "$STAGED_ENV" ] || fail "ambiguous CREATE retained extra stage name"

# The EXIT path also retains the exact inode and gives non-secret recovery
# guidance after any attempted CREATE.
rm -f "$PUBLISHED_ENV"
printf 'DATABASE_URL=ecto://exit-recovery-private-value\n' > "$STAGED_ENV"
install_staged_production_env "$STAGED_ENV" "$PUBLISHED_ENV"
ENV_FILE="$PUBLISHED_ENV"
PRODUCTION_ENV_STAGE="$STAGED_ENV"
PRODUCTION_ENV_PUBLISHED=1
PRODUCTION_DATABASE_MUTATION_ATTEMPTED=1
exit_recovery_output=$(cleanup_production_environment_on_exit 2>&1)
[ -e "$PUBLISHED_ENV" ] || fail "EXIT cleanup removed recovery .env"
[ ! -e "$STAGED_ENV" ] || fail "EXIT cleanup retained extra stage name"
assert_contains "$exit_recovery_output" "Database provisioning may have completed"
assert_contains "$exit_recovery_output" "do not delete it or replace its database password"
assert_not_contains "$exit_recovery_output" "exit-recovery-private-value"
PRODUCTION_ENV_STAGE=""
PRODUCTION_ENV_PUBLISHED=0
PRODUCTION_DATABASE_MUTATION_ATTEMPTED=0

# Root execution must fail explicitly when runuser is unavailable.
set +e
runuser_output=$(bash -c '
    source "$1"
    id() { printf "0\\n"; }
    command_exists() { return 1; }
    run_as_postgres true
' bash "$INSTALLER" 2>&1)
runuser_status=$?
set -e
[ "$runuser_status" -ne 0 ] || fail "root path without runuser succeeded"
assert_contains "$runuser_output" "runuser is required"

# A PostgreSQL inspection failure is explicit and occurs before any mutation.
run_as_postgres() {
    return 1
}
PRODUCTION_DATABASE_MUTATION_ATTEMPTED=0
set +e
inspection_output=$(provision_production_database new Linux "unused-password" 2>&1)
inspection_status=$?
set -e
[ "$inspection_status" -ne 0 ] || fail "failed PostgreSQL inspection succeeded"
assert_contains "$inspection_output" "Could not safely inspect PostgreSQL role"
[ "$PRODUCTION_DATABASE_MUTATION_ATTEMPTED" -eq 0 ] || \
    fail "failed inspection marked a database mutation"
assert_not_contains "$inspection_output" "unused-password"

# Caddy is managed through one dedicated fragment and one stable import. The
# fake root runner avoids privileges while preserving command/validation order.
CADDY_DIR="$TMP_DIR/caddy"
CADDYFILE="$CADDY_DIR/Caddyfile"
CADDY_FRAGMENT="$CADDY_DIR/cympho.caddy"
CADDY_LOG="$TMP_DIR/caddy.log"
SYSTEMCTL_LOG="$TMP_DIR/systemctl.log"
CADDY_COUNT_FILE="$TMP_DIR/caddy.count"
CADDY_ENABLE_STATE_FILE="$TMP_DIR/caddy.enable-state"
CADDY_ACTIVE_STATE_FILE="$TMP_DIR/caddy.active-state"
mkdir -p "$CADDY_DIR"
printf 'disabled\n' > "$CADDY_ENABLE_STATE_FILE"
printf 'inactive\n' > "$CADDY_ACTIVE_STATE_FILE"

file_mode() {
    stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

cat > "$CADDYFILE" <<'EOF_CADDY'
import snippets/*.caddy

import __CYMPHO_FRAGMENT__ stale-argument

unrelated.example.test {
    respond "keep this site"
}
EOF_CADDY
sed -i.bak "s|__CYMPHO_FRAGMENT__|$CADDY_FRAGMENT|" "$CADDYFILE"
printf 'old.invalid { respond "old" }\n' > "$CADDY_FRAGMENT"
chmod 0600 "$CADDYFILE"
chmod 0640 "$CADDY_FRAGMENT"

run_as_root() {
    local command=$1
    shift

    case "$command" in
        install)
            local mode=0644
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    -m) mode=$2; shift 2 ;;
                    -o|-g) shift 2 ;;
                    --) shift; break ;;
                    *) break ;;
                esac
            done
            cp "$1" "$2"
            chmod "$mode" "$2"
            ;;
        caddy)
            local count=0
            [ ! -e "$CADDY_COUNT_FILE" ] || count=$(cat "$CADDY_COUNT_FILE")
            count=$((count + 1))
            printf '%s\n' "$count" > "$CADDY_COUNT_FILE"
            printf '%s\n' "$*" >> "$CADDY_LOG"
            if [ "${FAKE_CADDY_FAIL_ON_CALL:-0}" -eq "$count" ] ||
               [ "${FAKE_CADDY_FAIL:-0}" -eq 1 ]; then
                return 1
            fi
            ;;
        stat)
            local stat_path=""
            for stat_path in "$@"; do :; done
            printf '%s 0 0\n' "$(file_mode "$stat_path")"
            ;;
        systemctl)
            printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
            if [ "$1" = "is-enabled" ] && [ "$2" = caddy ]; then
                state=$(cat "$CADDY_ENABLE_STATE_FILE")
                printf '%s\n' "$state"
                [ "$state" = enabled ]
                return
            elif [ "$1" = enable ] && [ "$2" = caddy ]; then
                if [ "${FAKE_SYSTEMCTL_FAIL_NEXT_ENABLE:-0}" -eq 1 ]; then
                    FAKE_SYSTEMCTL_FAIL_NEXT_ENABLE=0
                    return 1
                fi
                printf 'enabled\n' > "$CADDY_ENABLE_STATE_FILE"
                return 0
            elif [ "$1" = disable ] && [ "$2" = caddy ]; then
                printf 'disabled\n' > "$CADDY_ENABLE_STATE_FILE"
                return 0
            elif [ "$1" = is-active ] && [ "$2" = caddy ]; then
                state=$(cat "$CADDY_ACTIVE_STATE_FILE")
                printf '%s\n' "$state"
                [ "$state" = active ]
                return
            elif [ "$1" = is-active ] && [ "$2" = --quiet ] && [ "$3" = caddy ]; then
                [ "$(cat "$CADDY_ACTIVE_STATE_FILE")" = active ]
                return
            elif [ "$1" = stop ] && [ "$2" = caddy ]; then
                printf 'inactive\n' > "$CADDY_ACTIVE_STATE_FILE"
                return 0
            fi
            if [ "${FAKE_SYSTEMCTL_FAIL_NEXT_RELOAD:-0}" -eq 1 ] &&
               [ "$1" = "reload-or-restart" ]; then
                FAKE_SYSTEMCTL_FAIL_NEXT_RELOAD=0
                return 1
            fi
            if [ "$1" = "reload-or-restart" ] && [ "$2" = caddy ]; then
                printf 'active\n' > "$CADDY_ACTIVE_STATE_FILE"
            fi
            ;;
        *)
            "$command" "$@"
            ;;
    esac
}

# macOS test shim for the Linux renameat2 exchange primitive.
atomic_exchange_caddy_file() {
    local source_file=$1 target_file=$2 expected_file=$3 expected_meta=$4
    local displaced="${target_file}.exchange-test"
    local mode uid gid
    read -r mode uid gid <<<"$expected_meta"
    chmod "$mode" "$source_file"
    mv "$target_file" "$displaced" || return 1
    mv "$source_file" "$target_file" || { mv "$displaced" "$target_file"; return 1; }
    if ! caddy_file_matches "$displaced" "$expected_file" "$expected_meta"; then
        mv "$target_file" "$source_file"
        mv "$displaced" "$target_file"
        return 1
    fi
    cp -p "$target_file" "$source_file"
    rm -f "$displaced"
}

configure_cympho_caddy \
    cympho.example.test preview.cympho.example.test \
    "$CADDYFILE" "$CADDY_FRAGMENT" >/dev/null

global_config=$(cat "$CADDYFILE")
fragment_config=$(cat "$CADDY_FRAGMENT")
assert_contains "$global_config" "unrelated.example.test"
assert_contains "$global_config" "import snippets/*.caddy"
assert_contains "$global_config" 'respond "keep this site"'
assert_contains "$fragment_config" "cympho.example.test"
assert_contains "$fragment_config" "preview.cympho.example.test"
assert_contains "$fragment_config" "reverse_proxy 127.0.0.1:4000"
[ "$(file_mode "$CADDYFILE")" = 600 ] || fail "Caddyfile metadata was widened"
[ "$(file_mode "$CADDY_FRAGMENT")" = 640 ] || fail "Caddy fragment metadata was widened"
[ "$(cat "$CADDY_ENABLE_STATE_FILE")" = enabled ] || fail "successful Caddy activation was not enabled"
[ "$(cat "$CADDY_ACTIVE_STATE_FILE")" = active ] || fail "successful Caddy activation was not active"
[ "$(grep -Fxc "import $CADDY_FRAGMENT" "$CADDYFILE")" -eq 1 ] || \
    fail "Caddyfile does not contain exactly one stable Cympho import"
assert_contains "$(cat "$SYSTEMCTL_LOG")" "enable caddy"
assert_contains "$(cat "$SYSTEMCTL_LOG")" "reload-or-restart caddy"

# A successful rerun is byte-idempotent and cannot duplicate the managed import.
first_global_checksum=$(cksum "$CADDYFILE")
first_fragment_checksum=$(cksum "$CADDY_FRAGMENT")
: > "$CADDY_LOG"
: > "$SYSTEMCTL_LOG"
: > "$CADDY_COUNT_FILE"
configure_cympho_caddy \
    cympho.example.test preview.cympho.example.test \
    "$CADDYFILE" "$CADDY_FRAGMENT" >/dev/null
[ "$first_global_checksum" = "$(cksum "$CADDYFILE")" ] || \
    fail "Caddy global config changed on an identical rerun"
[ "$first_fragment_checksum" = "$(cksum "$CADDY_FRAGMENT")" ] || \
    fail "Caddy fragment changed on an identical rerun"
[ "$(grep -Fxc "import $CADDY_FRAGMENT" "$CADDYFILE")" -eq 1 ] || \
    fail "Caddy rerun duplicated its stable import"

# Candidate validation failure occurs before either active file or the service
# is touched.
before_failed_global=$(cksum "$CADDYFILE")
before_failed_fragment=$(cksum "$CADDY_FRAGMENT")
: > "$CADDY_LOG"
: > "$SYSTEMCTL_LOG"
: > "$CADDY_COUNT_FILE"
FAKE_CADDY_FAIL=1
set +e
failed_caddy_output=$(configure_cympho_caddy \
    changed.example.test preview.changed.example.test \
    "$CADDYFILE" "$CADDY_FRAGMENT" 2>&1)
failed_caddy_status=$?
set -e
unset FAKE_CADDY_FAIL
[ "$failed_caddy_status" -ne 0 ] || fail "invalid Caddy candidate was published"
[ "$before_failed_global" = "$(cksum "$CADDYFILE")" ] || \
    fail "candidate validation failure changed the global Caddyfile"
[ "$before_failed_fragment" = "$(cksum "$CADDY_FRAGMENT")" ] || \
    fail "candidate validation failure changed the Cympho fragment"
if grep -Ev '^(is-enabled|is-active) caddy$' "$SYSTEMCTL_LOG" | grep -q .; then
    fail "candidate validation failure mutated Caddy service state"
fi
assert_contains "$failed_caddy_output" "active files were preserved"

# The exact final paths are validated too, catching wildcard-import interactions
# without ever reloading invalid bytes.
: > "$CADDY_LOG"
: > "$SYSTEMCTL_LOG"
: > "$CADDY_COUNT_FILE"
FAKE_CADDY_FAIL_ON_CALL=2
set +e
final_path_output=$(configure_cympho_caddy \
    changed.example.test preview.changed.example.test \
    "$CADDYFILE" "$CADDY_FRAGMENT" 2>&1)
final_path_status=$?
set -e
unset FAKE_CADDY_FAIL_ON_CALL
[ "$final_path_status" -ne 0 ] || fail "final-path Caddy validation failure succeeded"
[ "$before_failed_global" = "$(cksum "$CADDYFILE")" ] || \
    fail "final-path validation failure did not restore the global Caddyfile"
[ "$before_failed_fragment" = "$(cksum "$CADDY_FRAGMENT")" ] || \
    fail "final-path validation failure did not restore the Cympho fragment"
if grep -Ev '^(is-enabled|is-active) caddy$' "$SYSTEMCTL_LOG" | grep -q .; then
    fail "final-path validation failure mutated Caddy service state"
fi
assert_contains "$final_path_output" "restored without reload"

# An activation failure is ambiguous. The installer restores both previous
# files and performs one best-effort reload of the restored, validated config.
: > "$CADDY_LOG"
: > "$SYSTEMCTL_LOG"
: > "$CADDY_COUNT_FILE"
FAKE_SYSTEMCTL_FAIL_NEXT_RELOAD=1
printf 'disabled\n' > "$CADDY_ENABLE_STATE_FILE"
printf 'inactive\n' > "$CADDY_ACTIVE_STATE_FILE"
set +e
activation_output=$(configure_cympho_caddy \
    activated.example.test preview.activated.example.test \
    "$CADDYFILE" "$CADDY_FRAGMENT" 2>&1)
activation_status=$?
set -e
unset FAKE_SYSTEMCTL_FAIL_NEXT_RELOAD
[ "$activation_status" -ne 0 ] || fail "failed Caddy activation reported success"
[ "$before_failed_global" = "$(cksum "$CADDYFILE")" ] || \
    fail "activation failure did not restore the global Caddyfile"
[ "$before_failed_fragment" = "$(cksum "$CADDY_FRAGMENT")" ] || \
    fail "activation failure did not restore the Cympho fragment"
[ "$(grep -Fc 'reload-or-restart caddy' "$SYSTEMCTL_LOG")" -eq 1 ] || \
    fail "inactive Caddy rollback unexpectedly restarted the service"
[ "$(cat "$CADDY_ENABLE_STATE_FILE")" = disabled ] || \
    fail "activation failure did not restore prior Caddy enablement"
assert_contains "$(cat "$SYSTEMCTL_LOG")" "disable caddy"
assert_contains "$(cat "$SYSTEMCTL_LOG")" "stop caddy"
[ "$(cat "$CADDY_ACTIVE_STATE_FILE")" = inactive ] || \
    fail "activation failure did not restore prior inactive Caddy state"
[ "$(file_mode "$CADDYFILE")" = 600 ] || fail "Caddyfile rollback did not restore metadata"
[ "$(file_mode "$CADDY_FRAGMENT")" = 640 ] || fail "Caddy fragment rollback did not restore metadata"
assert_contains "$activation_output" "previous files were restored"

# A previously active+enabled Caddy is reloaded after restoring its exact prior
# config and remains active+enabled when candidate activation fails.
: > "$CADDY_LOG"
: > "$SYSTEMCTL_LOG"
: > "$CADDY_COUNT_FILE"
printf 'enabled\n' > "$CADDY_ENABLE_STATE_FILE"
printf 'active\n' > "$CADDY_ACTIVE_STATE_FILE"
FAKE_SYSTEMCTL_FAIL_NEXT_RELOAD=1
set +e
active_activation_output=$(configure_cympho_caddy \
    active.example.test preview.active.example.test \
    "$CADDYFILE" "$CADDY_FRAGMENT" 2>&1)
active_activation_status=$?
set -e
unset FAKE_SYSTEMCTL_FAIL_NEXT_RELOAD
[ "$active_activation_status" -ne 0 ] || fail "failed active Caddy activation reported success"
[ "$(grep -Fc 'reload-or-restart caddy' "$SYSTEMCTL_LOG")" -eq 2 ] || \
    fail "active Caddy rollback did not reload restored config"
[ "$(cat "$CADDY_ACTIVE_STATE_FILE")" = active ] || fail "active Caddy state was not restored"
[ "$(cat "$CADDY_ENABLE_STATE_FILE")" = enabled ] || fail "enabled Caddy state was not restored"
assert_not_contains "$(cat "$SYSTEMCTL_LOG")" "stop caddy"
assert_contains "$active_activation_output" "previous files were restored"

# When Caddy files were initially absent, an activation failure must remove
# both newly-created files and restore the absent preimage exactly.
ABSENT_CADDYFILE="$CADDY_DIR/absent-Caddyfile"
ABSENT_CADDY_FRAGMENT="$CADDY_DIR/absent-cympho.caddy"
rm -f "$ABSENT_CADDYFILE" "$ABSENT_CADDY_FRAGMENT"
: > "$SYSTEMCTL_LOG"
: > "$CADDY_COUNT_FILE"
printf 'disabled\n' > "$CADDY_ENABLE_STATE_FILE"
printf 'inactive\n' > "$CADDY_ACTIVE_STATE_FILE"
FAKE_SYSTEMCTL_FAIL_NEXT_RELOAD=1
set +e
absent_activation_output=$(configure_cympho_caddy \
    absent.example.test preview.absent.example.test \
    "$ABSENT_CADDYFILE" "$ABSENT_CADDY_FRAGMENT" 2>&1)
absent_activation_status=$?
set -e
unset FAKE_SYSTEMCTL_FAIL_NEXT_RELOAD
[ "$absent_activation_status" -ne 0 ] || fail "absent Caddy activation failure reported success"
[ ! -e "$ABSENT_CADDYFILE" ] || fail "absent Caddyfile rollback left a file behind"
[ ! -e "$ABSENT_CADDY_FRAGMENT" ] || fail "absent Caddy fragment rollback left a file behind"
[ "$(cat "$CADDY_ENABLE_STATE_FILE")" = disabled ] || \
    fail "absent Caddy rollback did not restore prior enablement"
[ "$(cat "$CADDY_ACTIVE_STATE_FILE")" = inactive ] || \
    fail "absent Caddy rollback did not restore prior activity"
assert_contains "$absent_activation_output" "previous files were restored"

# Forward compare-and-swap protects an operator edit made after snapshotting
# but before publication of that file.
CAS_CADDYFILE="$CADDY_DIR/cas-Caddyfile"
CAS_CADDY_FRAGMENT="$CADDY_DIR/cas-cympho.caddy"
printf 'operator-global { respond "keep" }\n' > "$CAS_CADDYFILE"
printf 'operator-fragment\n' > "$CAS_CADDY_FRAGMENT"
chmod 0644 "$CAS_CADDYFILE" "$CAS_CADDY_FRAGMENT"
CADDY_EXCHANGE_BASE_DEFINITION=$(declare -f atomic_exchange_caddy_file)
atomic_exchange_caddy_file() {
    local source_file=$1 target_file=$2
    printf 'exchange-race edit\n' > "$target_file"
    return 1
}
set +e
exchange_output=$(configure_cympho_caddy \
    exchange.example.test preview.exchange.example.test \
    "$CAS_CADDYFILE" "$CAS_CADDY_FRAGMENT" 2>&1)
exchange_status=$?
set -e
unset -f atomic_exchange_caddy_file
eval "$CADDY_EXCHANGE_BASE_DEFINITION"
[ "$exchange_status" -ne 0 ] || fail "Caddy exchange publication reported success after a race"
[ "$(cat "$CAS_CADDY_FRAGMENT")" = "exchange-race edit" ] || \
    fail "Caddy exchange race edit was not preserved"

# If publication fails before one of the existing files is exchanged, rollback
# must recognize that file's unchanged preimage as an idempotent no-op rather
# than attempting a candidate-preimage swap and reporting manual recovery.
NOOP_GLOBAL="$CADDY_DIR/noop-Caddyfile"
NOOP_FRAGMENT="$CADDY_DIR/noop-cympho.caddy"
NOOP_EXISTING_GLOBAL="$TMP_DIR/noop-existing-Caddyfile"
NOOP_EXISTING_FRAGMENT="$TMP_DIR/noop-existing-cympho.caddy"
NOOP_CANDIDATE_GLOBAL="$TMP_DIR/noop-candidate-Caddyfile"
NOOP_CANDIDATE_FRAGMENT="$TMP_DIR/noop-candidate-cympho.caddy"
printf 'old global\n' > "$NOOP_GLOBAL"
printf 'old fragment\n' > "$NOOP_FRAGMENT"
printf 'old global\n' > "$NOOP_EXISTING_GLOBAL"
printf 'old fragment\n' > "$NOOP_EXISTING_FRAGMENT"
printf 'new global\n' > "$NOOP_CANDIDATE_GLOBAL"
printf 'new fragment\n' > "$NOOP_CANDIDATE_FRAGMENT"
chmod 0644 "$NOOP_GLOBAL" "$NOOP_FRAGMENT" "$NOOP_EXISTING_GLOBAL" \
    "$NOOP_EXISTING_FRAGMENT" "$NOOP_CANDIDATE_GLOBAL" "$NOOP_CANDIDATE_FRAGMENT"
NOOP_EXCHANGE_COUNT=0
atomic_exchange_caddy_file() {
    NOOP_EXCHANGE_COUNT=$((NOOP_EXCHANGE_COUNT + 1))
    return 1
}
set +e
noop_restore_status=0
restore_caddy_files \
    1 "$NOOP_EXISTING_GLOBAL" "$NOOP_GLOBAL" "$NOOP_CANDIDATE_GLOBAL" "644 0 0" \
    1 "$NOOP_EXISTING_FRAGMENT" "$NOOP_FRAGMENT" "$NOOP_CANDIDATE_FRAGMENT" "644 0 0" || \
    noop_restore_status=$?
set -e
unset -f atomic_exchange_caddy_file
eval "$CADDY_EXCHANGE_BASE_DEFINITION"
[ "$noop_restore_status" -eq 0 ] || \
    fail "Caddy rollback rejected an unchanged preimage before publication"
[ "$NOOP_EXCHANGE_COUNT" -eq 0 ] || \
    fail "Caddy rollback exchanged an already-restored preimage"
[ "$(cat "$NOOP_GLOBAL")" = 'old global' ] || \
    fail "Caddy no-op rollback changed the global preimage"
[ "$(cat "$NOOP_FRAGMENT")" = 'old fragment' ] || \
    fail "Caddy no-op rollback changed the fragment preimage"

# Existing managed files must be root-owned and not group/world writable.
chmod 0664 "$CAS_CADDYFILE"
set +e
metadata_output=$(configure_cympho_caddy \
    reject.example.test preview.reject.example.test \
    "$CAS_CADDYFILE" "$CAS_CADDY_FRAGMENT" 2>&1)
metadata_status=$?
set -e
[ "$metadata_status" -ne 0 ] || fail "writable Caddy metadata was accepted"
assert_contains "$metadata_output" "root-owned"
chmod 0644 "$CAS_CADDYFILE"

# A target that appears after the initial absence check must win; publishing a
# newly-created Caddy file uses create-without-replace hard-link semantics.
NOREPLACE_TARGET="$CADDY_DIR/noreplace.caddy"
rm -f "$NOREPLACE_TARGET"
NOREPLACE_SOURCE="$TMP_DIR/noreplace-source"
printf 'candidate\n' > "$NOREPLACE_SOURCE"
NOREPLACE_BASE_RUNNER=$(declare -f run_as_root)
eval "${NOREPLACE_BASE_RUNNER/run_as_root/base_noreplace_run_as_root}"
run_as_root() {
    local command=$1
    shift
    if [ "$command" = install ]; then
        base_noreplace_run_as_root "$command" "$@"
        printf 'operator-created\n' > "$NOREPLACE_TARGET"
        return 0
    fi
    base_noreplace_run_as_root "$command" "$@"
}
set +e
noreplace_output=$(atomic_install_caddy_file \
    "$NOREPLACE_SOURCE" "$NOREPLACE_TARGET" "644 0 0" 0 2>&1)
noreplace_status=$?
set -e
unset -f run_as_root base_noreplace_run_as_root
eval "$NOREPLACE_BASE_RUNNER"
[ "$noreplace_status" -ne 0 ] || fail "Caddy no-replace publication overwrote a raced target"
[ "$(cat "$NOREPLACE_TARGET")" = "operator-created" ] || \
    fail "raced Caddy target was not preserved"
assert_contains "$noreplace_output" "Refusing to replace existing configuration file"

# A symlinked Caddy parent is rejected before any candidate or service change.
SYMLINK_CADDY_PARENT="$CADDY_DIR/symlink-parent"
SYMLINK_CADDY_TARGET="$CADDY_DIR/real-parent"
mkdir -p "$SYMLINK_CADDY_TARGET"
ln -s "$SYMLINK_CADDY_TARGET" "$SYMLINK_CADDY_PARENT"
set +e
parent_symlink_output=$(configure_cympho_caddy \
    parent.example.test preview.parent.example.test \
    "$SYMLINK_CADDY_PARENT/Caddyfile" "$SYMLINK_CADDY_PARENT/cympho.caddy" 2>&1)
parent_symlink_status=$?
set -e
[ "$parent_symlink_status" -ne 0 ] || fail "symlinked Caddy parent was accepted"
assert_contains "$parent_symlink_output" "parent directory"

# An uninstalled Caddy unit has no exact enablement state to restore and is
# rejected before writing either managed file.
printf 'not-found\n' > "$CADDY_ENABLE_STATE_FILE"
NOT_FOUND_CADDYFILE="$CADDY_DIR/not-found-Caddyfile"
NOT_FOUND_FRAGMENT="$CADDY_DIR/not-found-cympho.caddy"
set +e
not_found_output=$(configure_cympho_caddy \
    missing.example.test preview.missing.example.test \
    "$NOT_FOUND_CADDYFILE" "$NOT_FOUND_FRAGMENT" 2>&1)
not_found_status=$?
set -e
[ "$not_found_status" -ne 0 ] || fail "not-found Caddy unit was accepted"
[ ! -e "$NOT_FOUND_CADDYFILE" ] && [ ! -e "$NOT_FOUND_FRAGMENT" ] || \
    fail "not-found Caddy preflight wrote configuration"
assert_contains "$not_found_output" "enabled or disabled"
printf 'disabled\n' > "$CADDY_ENABLE_STATE_FILE"

# Systemd unit interpolation accepts only canonical absolute directories and a
# safe Unix user. Injection-shaped input fails before a root-owned unit appears.
SYSTEMD_APP_DIR="$TMP_DIR/systemd-app"
SYSTEMD_ASDF_DIR="$TMP_DIR/systemd-asdf"
SYSTEMD_UNIT="$TMP_DIR/cympho.service"
mkdir -p "$SYSTEMD_APP_DIR" "$SYSTEMD_ASDF_DIR"
SYSTEMD_APP_DIR=$(cd "$SYSTEMD_APP_DIR" && pwd -P)
SYSTEMD_ASDF_DIR=$(cd "$SYSTEMD_ASDF_DIR" && pwd -P)

install_cympho_systemd_service \
    "$SYSTEMD_APP_DIR" "$SYSTEMD_ASDF_DIR" cympho "$SYSTEMD_UNIT" \
    "$SYSTEMD_APP_DIR/.env" /var/lib/cympho/data/uploads \
    /var/lib/cympho/data/import-transfers
unit_source=$(cat "$SYSTEMD_UNIT")
assert_contains "$unit_source" "User=cympho"
assert_contains "$unit_source" "Group=cympho"
assert_contains "$unit_source" "Environment=RELEASE_TMP=/tmp"
assert_contains "$unit_source" "PrivateTmp=true"
assert_contains "$unit_source" "NoNewPrivileges=true"
assert_not_contains "$unit_source" "ProtectSystem="
assert_not_contains "$unit_source" "ProtectHome="
assert_contains "$unit_source" "ReadWritePaths=/var/lib/cympho/data/uploads /var/lib/cympho/data/import-transfers"
assert_contains "$unit_source" "WorkingDirectory=$SYSTEMD_APP_DIR"
assert_contains "$unit_source" "EnvironmentFile=$SYSTEMD_APP_DIR/.env"
assert_contains "$unit_source" \
    "ExecStart=$SYSTEMD_APP_DIR/_build/prod/rel/cympho/bin/cympho start"
assert_not_contains "$unit_source" "mix phx.server"

# First-bootstrap publication must not overwrite a unit that appeared after
# the early existence check (for example, a concurrent deploy/operator).
RACE_UNIT="$TMP_DIR/race.service"
RUN_AS_ROOT_DEFINITION=$(declare -f run_as_root)
eval "$(declare -f run_as_root | sed '1s/^run_as_root/base_run_as_root/')"
run_as_root() {
    local command=$1
    local last_arg=""
    shift

    for last_arg in "$@"; do :; done
    case "$last_arg" in
        "$TMP_DIR"/.race.service.tmp.*)
            printf 'operator-owned-unit\n' > "$RACE_UNIT"
            ;;
    esac

    base_run_as_root "$command" "$@"
}
set +e
PRODUCTION_SOURCE_PUBLISHED=0
install_cympho_systemd_service \
    "$SYSTEMD_APP_DIR" "$SYSTEMD_ASDF_DIR" cympho "$RACE_UNIT" \
    >"$TMP_DIR/race-unit.out" 2>&1
race_unit_status=$?
set -e
race_unit_output=$(cat "$TMP_DIR/race-unit.out")
unset -f run_as_root base_run_as_root
eval "$RUN_AS_ROOT_DEFINITION"
[ "$race_unit_status" -ne 0 ] || fail "systemd bootstrap publication overwrote an existing unit"
[ "$PRODUCTION_SOURCE_PUBLISHED" -eq 0 ] || \
    fail "failed systemd publication retained an unreferenced sealed source"
[ "$(cat "$RACE_UNIT")" = "operator-owned-unit" ] || \
    fail "systemd bootstrap publication changed a concurrently-created unit"

INJECTED_UNIT="$TMP_DIR/injected.service"
set +e
newline_path_output=$(install_cympho_systemd_service \
    "$SYSTEMD_APP_DIR"$'\nExecStart=/bin/false' \
    "$SYSTEMD_ASDF_DIR" cympho "$INJECTED_UNIT" 2>&1)
newline_path_status=$?
set -e
[ "$newline_path_status" -ne 0 ] || fail "newline checkout path reached unit installation"
[ ! -e "$INJECTED_UNIT" ] || fail "newline checkout path installed a systemd unit"
assert_contains "$newline_path_output" "canonical absolute path"

set +e
newline_asdf_output=$(install_cympho_systemd_service \
    "$SYSTEMD_APP_DIR" "$SYSTEMD_ASDF_DIR"$'\nEnvironment=BAD=1' \
    cympho "$INJECTED_UNIT" 2>&1)
newline_asdf_status=$?
set -e
[ "$newline_asdf_status" -ne 0 ] || fail "newline HOME/asdf path reached unit installation"
[ ! -e "$INJECTED_UNIT" ] || fail "newline HOME/asdf path installed a systemd unit"
assert_contains "$newline_asdf_output" "canonical absolute path"

set +e
newline_user_output=$(install_cympho_systemd_service \
    "$SYSTEMD_APP_DIR" "$SYSTEMD_ASDF_DIR" \
    $'cympho\nExecStart=/bin/false' "$INJECTED_UNIT" 2>&1)
newline_user_status=$?
set -e
[ "$newline_user_status" -ne 0 ] || fail "injection-shaped account reached unit installation"
[ ! -e "$INJECTED_UNIT" ] || fail "injection-shaped account installed a systemd unit"
assert_contains "$newline_user_output" "safe Unix account name"

# The installer never truncates the global Caddyfile and publishes files through
# a same-directory rename after setting explicit root ownership and mode.
installer_source=$(cat "$INSTALLER")
assert_not_contains "$installer_source" 'tee $CADDYFILE'
assert_contains "$installer_source" 'install -m 0644 -o root -g root'
assert_contains "$installer_source" 'mv -f -- "$staged_file" "$target_file"'
assert_not_contains "$installer_source" 'Your app should now be running'
assert_contains "$installer_source" 'Local exact-revision readiness verified'
assert_contains "$installer_source" 'Verify public HTTPS and Caddy separately'

echo "install safety tests passed"
