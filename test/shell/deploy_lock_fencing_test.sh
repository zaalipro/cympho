#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOY_SCRIPT="${CYMPHO_DEPLOY_SCRIPT_UNDER_TEST:-$ROOT/deploy.sh}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cympho-deploy-fence.XXXXXX")"
trap 'rm -rf -- "$TMP_DIR"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

python3 - "$DEPLOY_SCRIPT" <<'PY' || exit 1
from pathlib import Path
import sys

deploy = Path(sys.argv[1]).read_text()

def require(condition, message):
    if not condition:
        print("not ok - " + message, file=sys.stderr)
        raise SystemExit(1)

def function(name, next_name):
    start = deploy.index(name + "()")
    end = deploy.index(next_name + "()", start)
    return deploy[start:end]

require("DEPLOY_OPERATION_LOCK=" in deploy and "DEPLOY_EPOCH_FILE=" in deploy,
        "deploy must define a distinct operation lock and epoch file")
require("secrets.token_hex(16)" in deploy,
        "deploy epochs must carry 128 bits of randomness")

admission = function("start_deploy_lock_holder", "acquire_deploy_lock")
session = admission.index("DEPLOY_SESSION_LOCK")
operation = admission.index("DEPLOY_OPERATION_LOCK", session)
publish = admission.index("mv -fT", operation)
unlock = admission.index("flock --unlock", publish)
ack = admission.index("lock_ack", unlock)
require(session < operation < publish < unlock < ack,
        "admission must hold session then operation, publish epoch, unlock operation, then ACK")
require("chown root:root" in admission and "chmod 0644" in admission and
        "install -m 0600 -o root -g root" in admission and
        "chmod 0600 \"\\$session_lock\"" in admission,
        "admission must atomically publish a root-owned epoch and protect the operation inode")
require("session_lock='${DEPLOY_SESSION_LOCK}'" in admission and
        admission.count("test ! -L") >= 3 and admission.count("stat -c %u") >= 3,
        "admission must validate permanent session/operation lock and epoch paths")

fence = function("operation_fence_command", "run_fenced_ssh")
require("DEPLOY_OPERATION_LOCK" in fence and "DEPLOY_EPOCH_FILE" in fence,
        "operation fence must use the separate lock and epoch")
require("stale deploy epoch" in fence and "sudo -u" in fence and '-- \\"\\$@\\"' in fence,
        "operation fence must reject stale epochs before executing its body")
require("DEPLOY_SESSION_LOCK" not in fence,
        "normal operations must never reacquire the session lock")

prior_preflight = deploy[deploy.index("# --- Preflight rollback attestation"):
                         deploy.index("# A current release is the only rollback target")]
require("! -group ${APP_USER}" in prior_preflight and
        'case "\\$mode" in' in prior_preflight and
        "440|550" in prior_preflight,
        "previous releases must be sealed root:app with only 0440/0550 entries")

runner = function("run_remote_script", "validate_managed_paths")
require("run_fenced_ssh" in runner,
        "the common remote mutation runner must use the operation fence")
cas_runner = function("run_remote_script_with_current_link_cas", "atomic_current_link")
require("run_fenced_ssh_nonfatal" in cas_runner,
        "cleanup CAS mutations must use the nonfatal operation fence")

for name, next_name in [
    ("cleanup_remote_source_dir", "run_remote_script_with_current_link_cas"),
    ("atomic_current_link", "snapshot_runtime_env"),
    ("commit_runtime_env", "snapshot_systemd_units"),
    ("commit_systemd_units", "restore_transaction_after_lock_loss"),
]:
    body = function(name, next_name)
    require("run_remote_script" in body or "run_remote_script_nonfatal" in body,
            f"{name} must mutate only through the common operation fence")
    require('ssh "${SSH_OPTS[@]}"' not in body and "run_ssh \"" not in body,
            f"{name} must not bypass the operation fence")
cleanup_source = function("cleanup_remote_source_dir", "run_remote_script_with_current_link_cas")
require("run_remote_script_nonfatal" in cleanup_source,
        "EXIT source cleanup must not abort recursively when its fenced cleanup cannot run")
for name, next_name in [
    ("commit_runtime_env", "snapshot_systemd_units"),
    ("commit_systemd_units", "restore_transaction_after_lock_loss"),
]:
    body = function(name, next_name)
    require("run_remote_script_nonfatal" in body,
            f"{name} must record cleanup debt instead of exiting when its fenced cleanup cannot run")

require('RSYNC_PATH="$(operation_fence_command rsync)"' in deploy and
        '--rsync-path="${RSYNC_PATH}"' in deploy,
        "the rsync server must execute under the operation fence")

recovery = function("restore_transaction_after_lock_loss", "public_readiness_matches")
require(sum(1 for line in recovery.splitlines()
            if line.strip().startswith("start_deploy_lock_holder recovery")) == 1,
        "lock-loss recovery must obtain exactly one bounded admission")
require("seq 1 850" in recovery,
        "recovery polling must cover its session and operation-lock waits")
require("new_deploy_epoch" in recovery,
        "lock-loss recovery must publish a fresh recovery epoch")
require(recovery.index("restore_runtime_env under-recovered-lock") <
        recovery.index("restore_systemd_units under-recovered-lock"),
        "lock-loss recovery must restore environment before units")

restore_env = function("restore_runtime_env", "commit_runtime_env")
restore_units = function("restore_systemd_units", "commit_systemd_units")
require("start_deploy_lock_holder" not in restore_env and
        "start_deploy_lock_holder" not in restore_units and
        "DEPLOY_SESSION_LOCK" not in restore_env and
        "DEPLOY_SESSION_LOCK" not in restore_units,
        "individual restore helpers must not reacquire session admission")
acquire = function("acquire_deploy_lock", "step")
require("seq 1 650" in acquire,
        "normal admission polling must cover the configured operation-lock wait")
cleanup = deploy[deploy.index("cleanup_local()"):
                 deploy.index("trap cleanup_local EXIT")]
require("recovery_attempted=0" in cleanup and
        cleanup.count("recovery_attempted=1") == 2 and
        '"${recovery_attempted}" == "0"' in cleanup,
        "EXIT cleanup must permit lock-race recovery but cap it at one session admission")
PY

# Execute the production fence generator with a fake flock/stat layer. This
# checks the gate's behavior without requiring Linux flock or root on macOS.
fence_definition="$(awk '
  /^shell_quote\(\)/ { capture=1 }
  /^run_fenced_ssh\(\)/ { capture=0 }
  capture { print }
' "$DEPLOY_SCRIPT")"
[ -n "$fence_definition" ] || fail "could not load operation fence generator"
eval "$fence_definition"

FAKE_BIN="$TMP_DIR/fake-bin"
mkdir "$FAKE_BIN"
cat >"$FAKE_BIN/flock" <<'EOF'
#!/usr/bin/env bash
while [[ "$1" == -* ]]; do
  case "$1" in
    --conflict-exit-code|--wait) shift 2 ;;
    *) shift ;;
  esac
done
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then exit 0; fi
shift
exec "$@"
EOF
cat >"$FAKE_BIN/stat" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == -c && "$2" == %u ]]; then printf '0\n'; exit 0; fi
exec /usr/bin/stat "$@"
EOF
cat >"$FAKE_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -u ]]; then shift 2; fi
if [[ "${1:-}" == -- ]]; then shift; fi
exec "$@"
EOF
chmod +x "$FAKE_BIN/flock" "$FAKE_BIN/stat" "$FAKE_BIN/sudo"

DEPLOY_OPERATION_LOCK="$TMP_DIR/operation.lock"
DEPLOY_EPOCH_FILE="$TMP_DIR/epoch"
DEPLOY_EPOCH=11111111111111111111111111111111
DEPLOY_USER="$(id -un)"
: >"$DEPLOY_OPERATION_LOCK"
printf '%s\n' 22222222222222222222222222222222 >"$DEPLOY_EPOCH_FILE"
marker="$TMP_DIR/mutated"
# bash -s is intentionally passed as two command arguments. The wrapper must
# preserve argv boundaries (an executable literally named "bash -s" is wrong).
command="$(operation_fence_command bash -s)"
[[ "$command" == *"'bash' '-s'"* ]] ||
  fail "operation fence must preserve separate bash and -s argv entries"

# Parse the generated command through both shells before executing it. This
# catches broken single-quote escaping in shell_quote instead of relying on a
# fake runner that would bypass remote command parsing.
expected_quote="'a'\"'\"'b'"
[ "$(shell_quote "a'b")" = "$expected_quote" ] ||
  fail "shell_quote must use canonical single-quote escaping"
shell_quote_definition="$(awk '
  /^shell_quote\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$DEPLOY_SCRIPT")"
if [ -x /bin/bash ]; then
  bash3_quote="$(/bin/bash -c "$shell_quote_definition; shell_quote \"a'b\"")"
  [ "$bash3_quote" = "$expected_quote" ] ||
    fail "shell_quote must preserve canonical escaping on macOS system Bash 3.2"
fi
printf '%s\n' "$command" >"$TMP_DIR/fence-command.sh"
bash -n "$TMP_DIR/fence-command.sh" || fail "generated fence command does not parse in bash"
sh -n "$TMP_DIR/fence-command.sh" || fail "generated fence command does not parse in sh"

set +e
printf 'touch %q\n' "$marker" | PATH="$FAKE_BIN:$PATH" bash -c "$command" \
  >"$TMP_DIR/stale.out" 2>&1
status=$?
set -e
[ "$status" -ne 0 ] || fail "stale epoch unexpectedly executed a mutation"
[ ! -e "$marker" ] || fail "stale epoch changed remote state"
grep -Fq 'stale deploy epoch' "$TMP_DIR/stale.out" ||
  fail "stale epoch rejection lacked a stable diagnostic"

printf '%s\n' "$DEPLOY_EPOCH" >"$DEPLOY_EPOCH_FILE"
printf 'touch %q\n' "$marker" | PATH="$FAKE_BIN:$PATH" bash -c "$command"
[ -e "$marker" ] || fail "current epoch did not execute the fenced body"

printf 'ok - deploy mutation fence rejects stale epochs and covers every mutation runner\n'
printf 'ok - deploy admission and lock-loss recovery preserve lock and restore ordering\n'
printf '1..2\n'
