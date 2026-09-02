#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOY="$ROOT/deploy.sh"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
python3 - "$DEPLOY" <<'PY' || exit 1
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
def require(x,msg):
    if not x:
        print('not ok - '+msg, file=sys.stderr); raise SystemExit(1)
require("Refusing to regenerate secrets when a current release exists." in s,
        "existing releases must not regenerate missing secrets")
require("_sudo test -L '${ENV_FILE}' || ! _sudo test -f '${ENV_FILE}'" in s,
        "existing runtime env must be regular and non-symlinked")
require('! -user root' in s and '! -group ${APP_USER}' in s and 'app_uid=' not in s,
        "legacy releases must be sealed to root and the application group")
require('Cympho.BuildInfo.revision()' in s and 'compiled release identity does not match' in s,
        "compiled release identity must match manifest/requested revision")
require('snapshot_complete=0' in s and 'cleanup_incomplete_snapshot' in s,
        "failed snapshot preflight must clean incomplete transaction state")
require("stat -c '%a %u %g'" in s and 'key.meta' in s,
        "snapshot must preserve prior file ownership and mode metadata")
ensure=s[s.index('step "Ensuring secrets'):s.index('step "Snapshotting installed systemd units"')]
require(ensure.index('env-file.after') < ensure.index('$snapshot/complete') < ensure.index('mv -fT -- "\\$env_publish" ${ENV_FILE}'),
        "expected bytes and completion marker must precede environment publication")
require(ensure.index('env-file.after.meta') < ensure.index('$snapshot/complete') and
        ensure.index('db-env-file.after.meta') < ensure.index('$snapshot/complete'),
        "expected candidate metadata must precede environment publication")
require('_sudo install -m 0640 -o root -g ${APP_USER} "\\$env_candidate" "\\$snapshot/env-file.after"' in ensure and
        '_sudo install -m 0600 -o ${DEPLOY_USER} -g ${DEPLOY_USER} "\\$db_candidate" "\\$snapshot/db-env-file.after"' in ensure,
        "candidate metadata must match the atomically published environment files")
require('validate_live_snapshot()' in ensure and
        ensure.count('validate_live_snapshot \'') >= 4,
        "environment publication must revalidate live files against the snapshot before each rename")
require(r'snapshot/\$key.present' in ensure and
        '_sudo test ! -e "\\$path" && _sudo test ! -L "\\$path"' in ensure,
        "forward CAS must reject externally created files when snapshot state was absent")
require('\\$snapshot/env-file.published' in ensure and
        '\\$snapshot/db-env-file.published' in ensure,
        "rollback evidence must record each environment file only after publication")
restore=s[s.index('restore_runtime_env()'):s.index('commit_runtime_env()')]
require('\\$key.published' in restore and
        'without publication evidence' in restore,
        "rollback must not remove candidate bytes without per-file publication evidence")
require('matches_file_state "\\$path" "\\$after" "\\$snapshot/\\$key.after.meta"' in restore and
        "stat -c '%a %u %g'" in restore and '[ "\\$live_meta" = "\\$expected_meta" ]' in restore,
        "rollback CAS must compare live bytes and metadata with deploy-written state")
require('elif _sudo test -f "\\$after"; then' in restore,
        "rollback must prevalidate deploy-created files before mutating either target")
require(restore.index("validate_file '${ENV_FILE}'") < restore.index("restore_file '${ENV_FILE}'") and
        restore.index("validate_file '${DB_ENV_FILE}'") < restore.index("restore_file '${ENV_FILE}'"),
        "rollback must validate both environment targets before mutating either")
require('test ! -L "\\$path"' in restore,
        "after-absent CAS must reject broken symlinks")
cleanup=s[s.index('cleanup_local()'):s.index('trap cleanup_local EXIT')]
require(cleanup.index('restore_runtime_env under-held-lock') < cleanup.index('restore_systemd_units under-held-lock'),
        "live-lock cleanup must restore environment before systemd units")
require('restore_transaction_after_lock_loss' in cleanup,
        "lock-loss cleanup must funnel through one recovered-lock coordinator")
rollback=s[s.index('rollback_release()'):s.index('step "Placing release')]
require(rollback.index('restore_runtime_env') < rollback.index('restore_systemd_units'),
        "handled rollback must restore environment then units before restart")
commit=s[s.index('commit_runtime_env()'):s.index('snapshot_systemd_units()')]
require(commit.index('ENV_SNAPSHOT_ACTIVE=0') < commit.index("rm -rf -- '${ENV_SNAPSHOT_DIR}'"),
        "commit must become logical before best-effort snapshot deletion")
require('run_remote_script_nonfatal' in commit,
        "post-commit environment cleanup must use the nonfatal operation fence")
success=s[s.index('if [[ "${public_ok}" == "1" ]]'):s.index('else\n  rollback_release', s.index('if [[ "${public_ok}" == "1" ]]'))]
first_cleanup=min(success.index('commit_systemd_units force'), success.index('commit_runtime_env force'))
require(success.index('UNIT_SNAPSHOT_ACTIVE=0') < first_cleanup and success.index('ENV_SNAPSHOT_ACTIVE=0') < first_cleanup,
        "public commit must clear both transaction flags before either cleanup request")
PY
printf 'ok - deploy runtime environment changes have snapshot, CAS rollback, and logical commit ordering\n'
printf '1..1\n'
