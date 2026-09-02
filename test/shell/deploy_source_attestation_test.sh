#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/cympho-deploy-source-test.XXXXXX")"

cleanup() { rm -rf -- "$FIXTURE"; }
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

git -C "$FIXTURE" init -q
git -C "$FIXTURE" config user.email test@example.test
git -C "$FIXTURE" config user.name "Cympho test"
cp "$ROOT/deploy.sh" "$FIXTURE/deploy.sh"
printf 'tracked\n' >"$FIXTURE/input.txt"
git -C "$FIXTURE" add deploy.sh input.txt
git -C "$FIXTURE" commit -qm initial
INITIAL_REVISION="$(git -C "$FIXTURE" rev-parse HEAD)"

set +e
OUTPUT="$(CYMPHO_SERVICE_NAME='bad;touch injected' CYMPHO_SKIP_HOST_CHECK=1 bash "$FIXTURE/deploy.sh" 2>&1)"
STATUS=$?
set -e
[[ "$STATUS" == 1 ]] || fail "injection-shaped service override must fail validation"
[[ "$OUTPUT" == *"simple systemd service name"* ]] ||
  fail "unsafe service override must have a stable diagnostic"
[[ ! -e "$FIXTURE/injected" ]] || fail "unsafe override must never execute shell text"

ln -s input.txt "$FIXTURE/tracked-link"
git -C "$FIXTURE" add tracked-link
git -C "$FIXTURE" commit -qm tracked-symlink
set +e
OUTPUT="$(CYMPHO_SKIP_HOST_CHECK=1 bash "$FIXTURE/deploy.sh" 2>&1)"
STATUS=$?
set -e
[[ "$STATUS" == 1 ]] || fail "a tracked source symlink must fail before deployment"
[[ "$OUTPUT" == *"tracked symlinks are not permitted in deployment source"* ]] ||
  fail "a tracked source symlink must have a stable diagnostic"
git -C "$FIXTURE" reset -q --hard "$INITIAL_REVISION"

run_fixture() {
  set +e
  OUTPUT="$(CYMPHO_SKIP_HOST_CHECK=1 bash "$FIXTURE/deploy.sh" 2>&1)"
  STATUS=$?
  set -e
}

printf 'dirty\n' >>"$FIXTURE/input.txt"
run_fixture
[[ "$STATUS" == 1 ]] || fail "tracked worktree drift must fail before deployment"
[[ "$OUTPUT" == *"working tree, index, or untracked build inputs differ from HEAD"* ]] ||
  fail "tracked drift must explain the attestation failure"
git -C "$FIXTURE" checkout -q -- input.txt

printf 'staged\n' >>"$FIXTURE/input.txt"
git -C "$FIXTURE" add input.txt
run_fixture
[[ "$STATUS" == 1 ]] || fail "index drift must fail before deployment"
[[ "$OUTPUT" == *"working tree, index, or untracked build inputs differ from HEAD"* ]] ||
  fail "index drift must explain the attestation failure"
git -C "$FIXTURE" reset -q --hard HEAD

printf 'untracked\n' >"$FIXTURE/untracked.txt"
run_fixture
[[ "$STATUS" == 1 ]] || fail "untracked build input must fail before deployment"
[[ "$OUTPUT" == *"working tree, index, or untracked build inputs differ from HEAD"* ]] ||
  fail "untracked drift must explain the attestation failure"

rm -f "$FIXTURE/untracked.txt"
FAKE_BIN="$FIXTURE/fake-bin"
mkdir "$FAKE_BIN"
printf 'fake-bin/\n' >>"$FIXTURE/.git/info/exclude"
cat >"$FAKE_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"command -v flock"* ]]; then exit 0; fi
printf 'flock: failed to acquire lock\n' >&2
exit 75
EOF
chmod +x "$FAKE_BIN/ssh"

set +e
OUTPUT="$(PATH="$FAKE_BIN:$PATH" CYMPHO_SKIP_HOST_CHECK=1 bash "$FIXTURE/deploy.sh" 2>&1)"
STATUS=$?
set -e
[[ "$STATUS" == 1 ]] || fail "a held host lock must refuse a concurrent deploy"
[[ "$OUTPUT" == *"Refusing concurrent deploy"* ]] ||
  fail "a held host lock must produce a stable diagnostic"

DEPLOY_RUN_LOG="$(mktemp "${TMPDIR:-/tmp}/cympho-deploy-run.XXXXXX")"
cleanup_run_log() { rm -f -- "$DEPLOY_RUN_LOG"; }
trap 'cleanup; cleanup_run_log' EXIT
cat >"$FAKE_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
command="${!#}"
case "$command" in
  *"flock --nonblock"*)
    printf 'CYMPHO_DEPLOY_LOCKED\n'
    exec sleep 60
    ;;
  *"command -v flock"*) exit 0 ;;
  *"if sudo test -L '/opt/cympho/current'"*)
    printf '/opt/cympho/releases/20260101010101'
    ;;
  *"release-revision"*) exit 1 ;;
  *)
    printf '%s\n' "$command" >>"$DEPLOY_RUN_LOG"
    if [[ "$command" == "bash -s" ||
          "$command" == *"cympho-deploy-operation"*"'bash' '-s'"* ]]; then
      body=$(cat)
      printf '%s\n' "$body" >>"$DEPLOY_RUN_LOG"
      if [[ "${FAKE_MANAGED_PATH_FAILURE:-0}" == 1 &&
            "$body" == *"validate_managed_directory_path"* ]]; then
        printf '%s\n' 'Managed deployment path is not a canonical directory: /opt/cympho/releases' >&2
        exit 1
      fi
      if [[ "${FAKE_ACCOUNT_FAILURE:-0}" == 1 &&
            "$body" == *"Application service account"* ]]; then
        printf '%s\n' 'Application service account must not have supplementary groups.' >&2
        exit 1
      fi
    fi
    printf '%s\n' '---' >>"$DEPLOY_RUN_LOG"
    ;;
esac
EOF
cat >"$FAKE_BIN/rsync" <<'EOF'
#!/usr/bin/env bash
printf 'rsync %s\n' "$*" >>"$DEPLOY_RUN_LOG"
EOF
chmod +x "$FAKE_BIN/ssh" "$FAKE_BIN/rsync"

set +e
OUTPUT="$(PATH="$FAKE_BIN:$PATH" DEPLOY_RUN_LOG="$DEPLOY_RUN_LOG" \
  FAKE_MANAGED_PATH_FAILURE=1 CYMPHO_SKIP_HOST_CHECK=1 \
  bash "$FIXTURE/deploy.sh" 2>&1)"
STATUS=$?
set -e
[[ "$STATUS" == 1 ]] || fail "an unsafe managed deployment path must abort deployment"
[[ "$OUTPUT" == *"Managed deployment path is not a canonical directory"* ]] ||
  fail "an unsafe managed path must have a stable diagnostic"
if grep -Fq '_sudo install -d -m 0755 -o root -g root /opt/cympho' "$DEPLOY_RUN_LOG"; then
  fail "managed path validation must run before bootstrap directory writes"
fi
if grep -Eq "sudo rm -rf '?/opt/cympho/sources/" "$DEPLOY_RUN_LOG"; then
  fail "cleanup must not delete a source path rejected by managed-path validation"
fi
: >"$DEPLOY_RUN_LOG"

set +e
OUTPUT="$(PATH="$FAKE_BIN:$PATH" DEPLOY_RUN_LOG="$DEPLOY_RUN_LOG" \
  FAKE_ACCOUNT_FAILURE=1 CYMPHO_SKIP_HOST_CHECK=1 \
  bash "$FIXTURE/deploy.sh" 2>&1)"
STATUS=$?
set -e
[[ "$STATUS" == 1 ]] || fail "an unsafe application service account must abort deployment"
[[ "$OUTPUT" == *"must not have supplementary groups"* ]] ||
  fail "an unsafe application service account must have a stable diagnostic"
if grep -Fq '_sudo install -d -m 0755 -o root -g root /opt/cympho' "$DEPLOY_RUN_LOG"; then
  fail "service account validation must run before bootstrap directory writes"
fi
: >"$DEPLOY_RUN_LOG"

set +e
OUTPUT="$(PATH="$FAKE_BIN:$PATH" DEPLOY_RUN_LOG="$DEPLOY_RUN_LOG" \
  CYMPHO_SKIP_HOST_CHECK=1 bash "$FIXTURE/deploy.sh" 2>&1)"
STATUS=$?
set -e
[[ "$STATUS" == 1 ]] || fail "an invalid previous manifest must abort deployment"
[[ "$OUTPUT" == *"Current release has no valid trusted revision manifest; refusing deployment."* ]] ||
  fail "an invalid previous manifest must have a stable diagnostic"
if [[ "$OUTPUT" == *"==> Ensuring secrets"* ]]; then
  fail "an invalid previous manifest must abort before environment/secret mutation"
fi
if [[ "$OUTPUT" == *"==> Snapshotting installed systemd units"* ]] ||
   [[ "$OUTPUT" == *"==> Installing systemd units"* ]]; then
  fail "an invalid previous manifest must abort before systemd-unit mutation"
fi
if [[ "$OUTPUT" == *"==> Verifying Postgres"* ]]; then
  fail "an invalid previous manifest must abort before Postgres preflight"
fi
if [[ "$OUTPUT" == *"==> Building release via Docker"* ]]; then
  fail "an invalid previous manifest must abort before release build"
fi
if grep -Fq 'cympho-migrate-' "$DEPLOY_RUN_LOG"; then
  fail "an invalid previous manifest must abort before migrations"
fi
if grep -Fq '_sudo ln -sfn /opt/cympho/releases/' "$DEPLOY_RUN_LOG"; then
  fail "an invalid previous manifest must abort before release cutover"
fi

grep -Fq 'snapshot_runtime_env' "$ROOT/deploy.sh" ||
  fail "deploy must snapshot runtime environment files before mutation"
grep -Fq 'restore_runtime_env' "$ROOT/deploy.sh" ||
  fail "deploy must restore runtime environment files during rollback"
grep -Fq 'Refusing to regenerate secrets when a current release exists.' "$ROOT/deploy.sh" ||
  fail "deploy must refuse missing environment secrets on an existing release"
grep -Fq 'Refusing to overwrite externally changed runtime environment file' "$ROOT/deploy.sh" ||
  fail "runtime environment rollback must use compare-and-swap"
grep -Fq 'Application service group must not have named members.' "$ROOT/deploy.sh" ||
  fail "deploy must reject supplementary readers of the service secret group"
grep -Fq 'Application service group must not be shared by another account.' "$ROOT/deploy.sh" ||
  fail "deploy must reject another account sharing the service group as its primary GID"
grep -Fq 'Application service group GID must not have another group alias.' "$ROOT/deploy.sh" ||
  fail "deploy must reject numeric aliases of the service group"
grep -Fq 'Application service account UID must not be shared by another username.' "$ROOT/deploy.sh" ||
  fail "deploy must reject numeric aliases of the service account"
grep -Fq 'validate_root_owned_ancestor_chain' "$ROOT/deploy.sh" ||
  fail "deploy must validate root-owned privileged path ancestors"
grep -Fq '_sudo install -d -m 0755 -o root -g root ${SOURCES_DIR}' "$ROOT/deploy.sh" ||
  fail "the privileged sources parent must be root-owned"
grep -Fq "validate_root_owned_ancestor_chain '\${DEPLOY_ROOT}/data' data-parent" "$ROOT/deploy.sh" ||
  fail "the privileged data parent must reject service-user ownership"
python3 - "$ROOT/deploy.sh" <<'PY' || fail "data parent must be root-owned before app-owned leaves are created"
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text()
parent = '_sudo install -d -m 0755 -o root -g root ${DEPLOY_ROOT}/data'
leaf = '_sudo install -d -m 0750 -o ${APP_USER} -g ${APP_USER} ${UPLOADS_DIR}'
raise SystemExit(0 if parent in s and s.index(parent) < s.index(leaf) else 1)
PY
grep -Fq '_sudo find ${SOURCE_DIR}/_rel -type l -print -quit' "$ROOT/deploy.sh" ||
  fail "deploy must reject every symlink in the extracted release"
grep -Fq '_sudo find ${RELEASE_DIR} -type l -print -quit' "$ROOT/deploy.sh" ||
  fail "deploy must reject every symlink in the published release"
grep -Fq 'find "${DEPLOY_CONTEXT}" -xdev -type l -print -quit' "$ROOT/deploy.sh" ||
  fail "deploy must reject symlinks in the extracted source archive"
[[ "$(grep -c 'git --no-replace-objects -C "${REPO_DIR}"' "$ROOT/deploy.sh")" -ge 6 ]] ||
  fail "every local Git attestation operation must disable replacement objects"
grep -Fq "_sudo systemctl show '\${SERVICE_NAME}' -p MainPID --value" "$ROOT/deploy.sh" ||
  fail "deploy readiness must obtain the service MainPID"
grep -Fq 'Readiness accepted only while MainPID remains active' "$ROOT/deploy.sh" ||
  fail "deploy readiness must remain associated with one active MainPID"
printf 'ok - deploy refuses tracked, indexed, and untracked source drift before attestation\n'
printf 'ok - deploy fails closed when the host serialization lock is held\n'
printf 'ok - deploy rejects injection-shaped environment overrides before use\n'
printf 'ok - deploy refuses an unattestable previous release before migration/cutover\n'
printf 'ok - deploy rejects unsafe managed path ancestors before bootstrap writes\n'
printf 'ok - deploy rejects unsafe existing application service accounts before writes\n'
printf 'ok - deploy rejects tracked and extracted release symlinks\n'
printf 'ok - deploy readiness is bound to one stable active MainPID\n'
printf '1..8\n'
