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
require("close_deploy_lock_fifo" in deploy,
        "deploy must define a close_deploy_lock_fifo helper")
require("mkfifo" in admission and "close_deploy_lock_fifo" in admission and
        "exec 8<>" in admission and "exec cat >/dev/null" in admission,
        "admission must use a private FIFO on FD 8 and cat >/dev/null for bounded release")
require("sleep infinity" not in admission,
        "admission must not orphan unbounded sleep infinity holders")
require("Finite implementation and fixture release bounds:" in deploy and
        "finite fixture watchdog bounds" in deploy,
        "deploy must document finite implementation and fixture release bounds")

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

# --- Local holder/caller protocol lifecycle test ---
python3 - "$DEPLOY_SCRIPT" "$TMP_DIR" <<'PY' || fail "local caller lifecycle test failed"
import os, subprocess, time, tempfile, signal, sys

deploy_sh = sys.argv[1]
tmp_dir = sys.argv[2]

# 1. Test signals during long owned work (SIGTERM, SIGINT, SIGHUP)
for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    with tempfile.TemporaryDirectory(dir=tmp_dir) as td:
        caller_script = os.path.join(td, "caller.sh")
        caller_context = os.path.join(td, "context")
        fifo = os.path.join(td, "lock.fifo")
        os.mkfifo(fifo)
        os.makedirs(caller_context, exist_ok=True)

        holder = subprocess.Popen(["bash", "-c", f"cat >/dev/null <'{fifo}'"])

        with open(caller_script, "w") as f:
            f.write(f"""#!/usr/bin/env bash
set -euo pipefail
export CYMPHO_DEPLOY_SOURCE_ONLY=1
source '{deploy_sh}'

export DEPLOY_CONTEXT='{caller_context}'
export DEPLOY_LOCK_OUTPUT='{caller_context}/deploy-lock.out'
export DEPLOY_LOCK_PID={holder.pid}

exec 8<>'{fifo}'
close_deploy_lock_fifo() {{
  if {{ true >&8; }} 2>/dev/null; then exec 8>&-; fi
}}

(
  while kill -0 {holder.pid} 2>/dev/null; do command sleep 0.05; done
  kill -TERM $$ 2>/dev/null || true
) &
DEPLOY_LOCK_MONITOR_PID=$!

init_deploy_traps

printf 'READY:%s\\n' "$$"
run_owned_op command sleep 30
""")
        os.chmod(caller_script, 0o755)

        caller = subprocess.Popen([caller_script], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        ready_line = caller.stdout.readline().strip()
        assert ready_line.startswith("READY:")
        caller_pid = int(ready_line.split(":")[1])

        t0 = time.monotonic()
        os.kill(caller_pid, sig)
        caller.wait(timeout=2.0)
        elapsed = time.monotonic() - t0
        assert elapsed <= 2.0, f"Signal {sig} release exceeded deadline: {elapsed}s"
        assert caller.returncode != 0

        holder.terminate()
        holder.wait(timeout=1.0)

# 1b. Test signals during foreground subshell / run_local_tests (SIGTERM, SIGINT, SIGHUP)
for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    with tempfile.TemporaryDirectory(dir=tmp_dir) as td:
        caller_script = os.path.join(td, "caller.sh")
        caller_context = os.path.join(td, "context")
        fifo = os.path.join(td, "lock.fifo")
        os.mkfifo(fifo)
        os.makedirs(caller_context, exist_ok=True)

        holder = subprocess.Popen(["bash", "-c", f"cat >/dev/null <'{fifo}'"])

        with open(caller_script, "w") as f:
            f.write(f"""#!/usr/bin/env bash
set -euo pipefail
export CYMPHO_DEPLOY_SOURCE_ONLY=1
source '{deploy_sh}'

export DEPLOY_CONTEXT='{caller_context}'
export DEPLOY_LOCK_OUTPUT='{caller_context}/deploy-lock.out'
export DEPLOY_LOCK_PID={holder.pid}

exec 8<>'{fifo}'
close_deploy_lock_fifo() {{
  if {{ true >&8; }} 2>/dev/null; then exec 8>&-; fi
}}

(
  while kill -0 {holder.pid} 2>/dev/null; do command sleep 0.05; done
  kill -TERM $$ 2>/dev/null || true
) &
DEPLOY_LOCK_MONITOR_PID=$!

init_deploy_traps

printf 'READY:%s\\n' "$$"
run_local_tests() {{
  ( cd /tmp && exec sleep 30 )
}}
run_owned_op run_local_tests
""")
        os.chmod(caller_script, 0o755)

        caller = subprocess.Popen([caller_script], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        ready_line = caller.stdout.readline().strip()
        assert ready_line.startswith("READY:")
        caller_pid = int(ready_line.split(":")[1])

        t0 = time.monotonic()
        os.kill(caller_pid, sig)
        caller.wait(timeout=2.0)
        elapsed = time.monotonic() - t0
        assert elapsed <= 2.0, f"Subshell signal {sig} release exceeded deadline: {elapsed}s"
        assert caller.returncode != 0

        holder.terminate()
        holder.wait(timeout=1.0)

# 1c. Test signals during captured operation / command-substitution path (SIGTERM, SIGINT, SIGHUP)
for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    with tempfile.TemporaryDirectory(dir=tmp_dir) as td:
        caller_script = os.path.join(td, "caller.sh")
        caller_context = os.path.join(td, "context")
        fifo = os.path.join(td, "lock.fifo")
        os.mkfifo(fifo)
        os.makedirs(caller_context, exist_ok=True)

        holder = subprocess.Popen(["bash", "-c", f"cat >/dev/null <'{fifo}'"])

        with open(caller_script, "w") as f:
            f.write(f"""#!/usr/bin/env bash
set -euo pipefail
export CYMPHO_DEPLOY_SOURCE_ONLY=1
source '{deploy_sh}'

export DEPLOY_CONTEXT='{caller_context}'
export DEPLOY_LOCK_OUTPUT='{caller_context}/deploy-lock.out'
export DEPLOY_LOCK_PID={holder.pid}

exec 8<>'{fifo}'
close_deploy_lock_fifo() {{
  if {{ true >&8; }} 2>/dev/null; then exec 8>&-; fi
}}

(
  while kill -0 {holder.pid} 2>/dev/null; do command sleep 0.05; done
  kill -TERM $$ 2>/dev/null || true
) &
DEPLOY_LOCK_MONITOR_PID=$!

init_deploy_traps

printf 'READY:%s\\n' "$$"
run_owned_op_capture CAPTURED_VAL command sleep 30
""")
        os.chmod(caller_script, 0o755)

        caller = subprocess.Popen([caller_script], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        ready_line = caller.stdout.readline().strip()
        assert ready_line.startswith("READY:")
        caller_pid = int(ready_line.split(":")[1])

        t0 = time.monotonic()
        os.kill(caller_pid, sig)
        caller.wait(timeout=2.0)
        elapsed = time.monotonic() - t0
        assert elapsed <= 2.0, f"Captured op signal {sig} release exceeded deadline: {elapsed}s"
        assert caller.returncode != 0

        holder.terminate()
        holder.wait(timeout=1.0)

# 2. Test snapshot recovery ordering (environment before unit) during interruption
with tempfile.TemporaryDirectory(dir=tmp_dir) as td:
    caller_script = os.path.join(td, "caller.sh")
    caller_context = os.path.join(td, "context")
    order_log = os.path.join(td, "order.log")
    fifo = os.path.join(td, "lock.fifo")
    os.mkfifo(fifo)
    os.makedirs(caller_context, exist_ok=True)

    holder = subprocess.Popen(["bash", "-c", f"cat >/dev/null <'{fifo}'"])

    with open(caller_script, "w") as f:
        f.write(f"""#!/usr/bin/env bash
set -euo pipefail
export CYMPHO_DEPLOY_SOURCE_ONLY=1
source '{deploy_sh}'

export DEPLOY_CONTEXT='{caller_context}'
export DEPLOY_LOCK_OUTPUT='{caller_context}/deploy-lock.out'
export DEPLOY_LOCK_PID={holder.pid}
export ENV_SNAPSHOT_ACTIVE=1
export UNIT_SNAPSHOT_ACTIVE=1

exec 8<>'{fifo}'
close_deploy_lock_fifo() {{
  if {{ true >&8; }} 2>/dev/null; then exec 8>&-; fi
}}

restore_runtime_env() {{
  echo "RESTORE_ENV" >> '{order_log}'
  return 0
}}

restore_systemd_units() {{
  echo "RESTORE_UNITS" >> '{order_log}'
  return 0
}}

init_deploy_traps

printf 'READY:%s\\n' "$$"
run_owned_op command sleep 30
""")
    os.chmod(caller_script, 0o755)

    caller = subprocess.Popen([caller_script], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    ready_line = caller.stdout.readline().strip()
    assert ready_line.startswith("READY:")
    caller_pid = int(ready_line.split(":")[1])

    t0 = time.monotonic()
    os.kill(caller_pid, signal.SIGTERM)
    caller.wait(timeout=2.0)
    elapsed = time.monotonic() - t0
    assert elapsed <= 2.0

    holder.terminate()
    holder.wait(timeout=1.0)

    with open(order_log) as f:
        order = f.read().splitlines()
    assert order == ["RESTORE_ENV", "RESTORE_UNITS"], f"Unexpected restore order: {order}"

# 3. Test transport loss (holder process termination triggers monitor signal to caller)
with tempfile.TemporaryDirectory(dir=tmp_dir) as td:
    caller_script = os.path.join(td, "caller.sh")
    caller_context = os.path.join(td, "context")
    fifo = os.path.join(td, "lock.fifo")
    os.mkfifo(fifo)
    os.makedirs(caller_context, exist_ok=True)

    holder = subprocess.Popen(["bash", "-c", f"cat >/dev/null <'{fifo}'"])

    with open(caller_script, "w") as f:
        f.write(f"""#!/usr/bin/env bash
set -euo pipefail
export CYMPHO_DEPLOY_SOURCE_ONLY=1
source '{deploy_sh}'

export DEPLOY_CONTEXT='{caller_context}'
export DEPLOY_LOCK_OUTPUT='{caller_context}/deploy-lock.out'
export DEPLOY_LOCK_PID={holder.pid}

exec 8<>'{fifo}'
close_deploy_lock_fifo() {{
  if {{ true >&8; }} 2>/dev/null; then exec 8>&-; fi
}}

(
  while kill -0 {holder.pid} 2>/dev/null; do command sleep 0.05; done
  kill -TERM $$ 2>/dev/null || true
) &
DEPLOY_LOCK_MONITOR_PID=$!

init_deploy_traps

printf 'READY:%s\\n' "$$"
run_owned_op command sleep 30
""")
    os.chmod(caller_script, 0o755)

    caller = subprocess.Popen([caller_script], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    ready_line = caller.stdout.readline().strip()
    assert ready_line.startswith("READY:")
    caller_pid = int(ready_line.split(":")[1])

    t0 = time.monotonic()
    holder.kill()
    holder.wait()
    caller.wait(timeout=2.0)
    elapsed = time.monotonic() - t0
    assert elapsed <= 2.0
PY

printf 'ok - local caller interrupt lifecycle reaps owned work and releases holder on signals and transport loss\n'

# --- Genuine Linux acceptance fixture on authorized GCP host ---
DEPLOY_TARGET="${CYMPHO_DEPLOY_TARGET:-zaali@34.136.10.30}"
SSH_KEY="${CYMPHO_DEPLOY_KEY:-}"
DEFAULT_KEY="${HOME}/.ssh/id_ed25519_gcp"
if [[ -z "${SSH_KEY}" && -f "${DEFAULT_KEY}" ]]; then
  SSH_KEY="${DEFAULT_KEY}"
fi

RUN_REMOTE=0
if [[ "${CYMPHO_RUN_LINUX_FIXTURE:-0}" == "1" || -n "${CYMPHO_DEPLOY_KEY:-}" ]]; then
  RUN_REMOTE=1
fi

SSH_CHECK_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)
if [[ -n "${SSH_KEY}" ]]; then
  SSH_CHECK_OPTS+=(-i "${SSH_KEY}")
fi

if [[ "${RUN_REMOTE}" == "1" ]]; then
  if ! ssh "${SSH_CHECK_OPTS[@]}" "$DEPLOY_TARGET" true 2>/dev/null; then
    fail "Explicitly requested Linux acceptance failed: SSH probe to $DEPLOY_TARGET was unreachable or rejected"
  fi
  python3 -u - "$DEPLOY_TARGET" "${SSH_KEY}" "$DEPLOY_SCRIPT" <<'PY' || fail "Linux flock fixture failed"
import os, subprocess, time, secrets, tempfile, signal, sys, shutil, traceback

target = sys.argv[1]
key = sys.argv[2]
deploy_sh = sys.argv[3]
nonce = secrets.token_hex(6)
fixture_dir = f"/tmp/cympho-linux-fixture.{nonce}"

ssh_opts = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=10"]
if key and os.path.exists(key):
    ssh_opts += ["-i", key]
ssh_opts += [target]

spawned_callers = []
spawned_temp_dirs = []

def reap_local_processes():
    for caller in spawned_callers:
        if caller.poll() is None:
            try:
                os.killpg(caller.pid, signal.SIGTERM)
            except (OSError, ProcessLookupError):
                try:
                    caller.terminate()
                except (OSError, ProcessLookupError):
                    pass
            try:
                caller.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(caller.pid, signal.SIGKILL)
                except (OSError, ProcessLookupError):
                    try:
                        caller.kill()
                    except (OSError, ProcessLookupError):
                        pass
                caller.wait(timeout=1.0)

def cleanup_local_dirs():
    for td in spawned_temp_dirs:
        shutil.rmtree(td, ignore_errors=True)

def cleanup_remote():
    # Targeted remote kill of processes associated with fixture_dir, avoiding self-matching
    cleanup_cmd = f"""
set +e
for pid in $(lsof -t +D '{fixture_dir}' 2>/dev/null || fuser '{fixture_dir}'/* 2>/dev/null || true); do
  if [ "$pid" != "$$" ] && [ "$pid" != "$PPID" ]; then
    kill -9 "$pid" 2>/dev/null || true
  fi
done
rm -rf '{fixture_dir}'
test ! -e '{fixture_dir}'
"""
    subprocess.run(ssh_opts + [cleanup_cmd], capture_output=True, text=True, timeout=10)

def full_teardown(signum=None, frame=None):
    reap_local_processes()
    cleanup_local_dirs()
    try:
        cleanup_remote()
    except Exception:
        pass
    if signum is not None:
        sys.exit(128 + signum)

signal.signal(signal.SIGINT, full_teardown)
signal.signal(signal.SIGTERM, full_teardown)
signal.signal(signal.SIGHUP, full_teardown)

# Setup remote fixture with explicit privilege substitutions
setup_cmd = f"""
set -euo pipefail
umask 077
mkdir -p '{fixture_dir}/bin'
cat >'{fixture_dir}/bin/sudo' <<'EOF'
#!/bin/bash
if [[ "$1" == -u ]]; then shift 2; fi
if [[ "$1" == -- ]]; then shift; fi
exec "$@"
EOF
cat >'{fixture_dir}/bin/stat' <<'EOF'
#!/bin/bash
if [[ "$1" == -c && "$2" == %u ]]; then
  printf '0\\n'
  exit 0
fi
exec /usr/bin/stat "$@"
EOF
cat >'{fixture_dir}/bin/chown' <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x '{fixture_dir}/bin/sudo' '{fixture_dir}/bin/stat' '{fixture_dir}/bin/chown'
touch '{fixture_dir}/session.lock' '{fixture_dir}/operation.lock'
chmod 0600 '{fixture_dir}/session.lock' '{fixture_dir}/operation.lock'
"""
subprocess.run(ssh_opts + [setup_cmd], check=True, timeout=10)

try:
    session_lock = f"{fixture_dir}/session.lock"
    operation_lock = f"{fixture_dir}/operation.lock"
    epoch_file = f"{fixture_dir}/epoch.txt"
    contender_marker = f"{fixture_dir}/contender.mutated"
    live_marker = f"{fixture_dir}/live.mutated"
    normal_marker = f"{fixture_dir}/normal.mutated"
    stale_marker = f"{fixture_dir}/stale.mutated"
    valid_marker = f"{fixture_dir}/valid.mutated"

    def run_caller(mode="hold"):
        td = tempfile.mkdtemp()
        spawned_temp_dirs.append(td)
        caller_script = os.path.join(td, "caller.sh")
        caller_context = os.path.join(td, "context")
        os.makedirs(caller_context, exist_ok=True)
        with open(caller_script, "w") as f:
            f.write(f"""#!/usr/bin/env bash
set -euo pipefail
export CYMPHO_DEPLOY_SOURCE_ONLY=1
export CYMPHO_DEPLOY_TARGET='{target}'
export CYMPHO_DEPLOY_PORT=22
export CYMPHO_DEPLOY_USER='zaali'
export CYMPHO_DEPLOY_SESSION_LOCK='{session_lock}'
export CYMPHO_DEPLOY_OPERATION_LOCK='{operation_lock}'
export CYMPHO_DEPLOY_EPOCH_FILE='{epoch_file}'
export CYMPHO_DEPLOY_REMOTE_COMMAND_PREFIX="export PATH=\\"{fixture_dir}/bin:\\$PATH\\"; "
export DEPLOY_CONTEXT='{caller_context}'
export DEPLOY_LOCK_OUTPUT='{caller_context}/deploy-lock.out'
export DEPLOY_EPOCH="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"

source '{deploy_sh}'

DEPLOY_TARGET='{target}'
if [ -n '{key}' ]; then
  SSH_OPTS+=(-i '{key}')
fi

init_deploy_traps
acquire_deploy_lock

printf 'CALLER_READY:%s:%s\\n' "$$" "${{DEPLOY_LOCK_PID}}"

if [[ "{mode}" == "hold" ]]; then
  run_owned_op command sleep 60
elif [[ "{mode}" == "normal" ]]; then
  cmd="$(operation_fence_command touch '{normal_marker}')"
  run_owned_op ssh "${{SSH_OPTS[@]}}" "${{DEPLOY_TARGET}}" "${{cmd}}"
  cleanup_local
  exit 0
elif [[ "{mode}" == "remote_sleep" ]]; then
  cmd="$(operation_fence_command command sleep 60)"
  run_owned_op ssh "${{SSH_OPTS[@]}}" "${{DEPLOY_TARGET}}" "${{cmd}}"
fi
""")
        os.chmod(caller_script, 0o755)
        caller = subprocess.Popen([caller_script], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        spawned_callers.append(caller)
        ready_line = caller.stdout.readline().strip()
        assert ready_line.startswith("CALLER_READY:"), f"Bad ready line: {ready_line}"
        _, cpid, hpid = ready_line.split(":")
        return caller, int(cpid), int(hpid), td

    # VAL-DEP-001: Live actual caller retains exclusive ownership; competing admission cannot mutate epoch or payload
    print("# VAL-DEP-001: testing live retention and contention...", flush=True)
    caller, cpid, hpid, td = run_caller("hold")
    try:
        # Read initial epoch published by caller
        initial_epoch_res = subprocess.run(ssh_opts + [f'cat "{epoch_file}"'], capture_output=True, text=True, timeout=5, check=True)
        initial_epoch = initial_epoch_res.stdout.strip()
        assert len(initial_epoch) > 0

        # Launch contender caller attempting actual deploy.sh acquisition
        contender_td = tempfile.mkdtemp()
        spawned_temp_dirs.append(contender_td)
        contender_script = os.path.join(contender_td, "contender.sh")
        contender_context = os.path.join(contender_td, "context")
        os.makedirs(contender_context, exist_ok=True)
        with open(contender_script, "w") as f:
            f.write(f"""#!/usr/bin/env bash
set -euo pipefail
export CYMPHO_DEPLOY_SOURCE_ONLY=1
export CYMPHO_DEPLOY_TARGET='{target}'
export CYMPHO_DEPLOY_PORT=22
export CYMPHO_DEPLOY_USER='zaali'
export CYMPHO_DEPLOY_SESSION_LOCK='{session_lock}'
export CYMPHO_DEPLOY_OPERATION_LOCK='{operation_lock}'
export CYMPHO_DEPLOY_EPOCH_FILE='{epoch_file}'
export CYMPHO_DEPLOY_REMOTE_COMMAND_PREFIX="export PATH=\\"{fixture_dir}/bin:\\$PATH\\"; "
export DEPLOY_CONTEXT='{contender_context}'
export DEPLOY_LOCK_OUTPUT='{contender_context}/deploy-lock.out'
export DEPLOY_EPOCH="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"

source '{deploy_sh}'

DEPLOY_TARGET='{target}'
if [ -n '{key}' ]; then
  SSH_OPTS+=(-i '{key}')
fi

init_deploy_traps
acquire_deploy_lock
touch '{contender_marker}'
""")
        os.chmod(contender_script, 0o755)
        contender = subprocess.run([contender_script], capture_output=True, text=True, timeout=10)
        assert contender.returncode != 0, f"Contender unexpectedly succeeded: exit code {contender.returncode}"
        assert subprocess.run(ssh_opts + [f'test ! -e "{contender_marker}"'], timeout=5).returncode == 0, "Contender mutated state during live hold!"

        # Verify epoch file was not modified by contender
        after_epoch_res = subprocess.run(ssh_opts + [f'cat "{epoch_file}"'], capture_output=True, text=True, timeout=5, check=True)
        after_epoch = after_epoch_res.stdout.strip()
        assert after_epoch == initial_epoch, f"Contender modified epoch: {initial_epoch} -> {after_epoch}"

        # Caller can execute fenced operation using actual operation fence command (proper FD 9 locking)
        fence_cmd = subprocess.run(
            ["bash", "-c", f"""
export CYMPHO_DEPLOY_SOURCE_ONLY=1
source '{deploy_sh}'
export DEPLOY_OPERATION_LOCK='{operation_lock}'
export DEPLOY_EPOCH_FILE='{epoch_file}'
export DEPLOY_EPOCH='{initial_epoch}'
export DEPLOY_USER='zaali'
export DEPLOY_REMOTE_COMMAND_PREFIX="export PATH=\\"{fixture_dir}/bin:\\$PATH\\"; "
operation_fence_command touch '{live_marker}'
"""], capture_output=True, text=True, check=True
        ).stdout.strip()

        fence_check = subprocess.run(ssh_opts + [fence_cmd], timeout=5)
        assert fence_check.returncode == 0, "Live operation could not run under held lock!"
        assert subprocess.run(ssh_opts + [f'test -f "{live_marker}"'], timeout=5).returncode == 0
    finally:
        try:
            os.killpg(caller.pid, signal.SIGTERM)
        except (OSError, ProcessLookupError):
            pass
        caller.wait(timeout=5.0)

    # Reacquire after VAL-DEP-001
    subprocess.run(ssh_opts + [f'export PATH="{fixture_dir}/bin:$PATH"; flock -n -E 75 "{session_lock}" true'], timeout=5, check=True)

    # VAL-DEP-002: Interruption signals (SIGINT, SIGTERM, SIGHUP) clean up operations, monitor, holder within finite bounds
    print("# VAL-DEP-002: testing normal completion, signals, and remote cancellation...", flush=True)
    # A. Normal completion: caller executes fenced op, runs cleanup_local, exits 0
    normal_caller, ncpid, nhpid, ntd = run_caller("normal")
    out, err = normal_caller.communicate(timeout=10.0)
    assert normal_caller.returncode == 0, f"Normal caller failed with returncode {normal_caller.returncode}. Out: {out} Err: {err}"
    assert subprocess.run(ssh_opts + [f'test -f "{normal_marker}"'], timeout=5).returncode == 0
    # Verify session lock was released by normal completion and can be immediately reacquired
    reacq = subprocess.run(ssh_opts + [f'export PATH="{fixture_dir}/bin:$PATH"; flock -n -E 75 "{session_lock}" true'], timeout=5.0)
    assert reacq.returncode == 0, "Lock reacquisition failed after normal completion"
    survivors = subprocess.run(ssh_opts + [f"ps -eo pid,cmd | grep '{fixture_dir}/' | grep -v grep || true"], capture_output=True, text=True, timeout=5.0).stdout.strip()
    assert survivors == "", f"Found remote survivors after normal completion: {survivors}"

    # B. Interruption signals (SIGINT, SIGTERM, SIGHUP)
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        caller, cpid, hpid, td = run_caller("hold")
        t0 = time.monotonic()
        try:
            os.killpg(caller.pid, sig)
        except (OSError, ProcessLookupError):
            os.kill(cpid, sig)
        caller.wait(timeout=5.0)
        elapsed = time.monotonic() - t0
        assert elapsed <= 5.0, f"Caller release after {sig} exceeded 5s deadline: {elapsed}s"
        assert caller.returncode != 0

        # Verify immediate lock reacquisition on Linux within finite bounds
        t_reacq = time.monotonic()
        reacq = subprocess.run(ssh_opts + [f'export PATH="{fixture_dir}/bin:$PATH"; flock -n -E 75 "{session_lock}" true'], timeout=5.0)
        assert reacq.returncode == 0, f"Lock reacquisition failed after signal {sig}"
        assert (time.monotonic() - t_reacq) <= 5.0, f"Reacquisition exceeded 5s deadline"

        # Verify zero remote survivors
        survivors = subprocess.run(ssh_opts + [f"ps -eo pid,cmd | grep '{fixture_dir}/' | grep -v grep || true"], capture_output=True, text=True, timeout=5.0).stdout.strip()
        assert survivors == "", f"Found remote survivors after signal {sig}: {survivors}"

    # C. Remote protected work cancellation & settlement
    caller, cpid, hpid, td = run_caller("remote_sleep")
    time.sleep(1.0)
    t0 = time.monotonic()
    try:
        os.killpg(caller.pid, signal.SIGTERM)
    except (OSError, ProcessLookupError):
        os.kill(cpid, signal.SIGTERM)
    caller.wait(timeout=5.0)
    elapsed = time.monotonic() - t0
    assert elapsed <= 5.0, f"Caller release after remote op interrupt exceeded 5s: {elapsed}s"

    # Verify operation lock was settled and can be immediately reacquired
    reacq_op = subprocess.run(ssh_opts + [f'export PATH="{fixture_dir}/bin:$PATH"; flock -n -E 76 "{operation_lock}" true'], timeout=5.0)
    assert reacq_op.returncode == 0, "Operation lock reacquisition failed after remote op interrupt"
    survivors = subprocess.run(ssh_opts + [f"ps -eo pid,cmd | grep '{fixture_dir}/' | grep -v grep || true"], capture_output=True, text=True, timeout=5.0).stdout.strip()
    assert survivors == "", f"Found remote survivors after remote op interrupt: {survivors}"

    # VAL-DEP-003: Lost controller input / transport loss permits reacquisition without stale mutations or live-lock loss
    print("# VAL-DEP-003: testing transport loss...", flush=True)
    caller, cpid, hpid, td = run_caller("hold")
    t0 = time.monotonic()
    os.kill(hpid, signal.SIGKILL)
    caller.wait(timeout=5.0)
    elapsed = time.monotonic() - t0
    assert elapsed <= 5.0, f"Caller release after transport loss exceeded 5s: {elapsed}s"

    t_reacq = time.monotonic()
    reacq = subprocess.run(ssh_opts + [f'export PATH="{fixture_dir}/bin:$PATH"; flock -n -E 75 "{session_lock}" true'], timeout=5.0)
    assert reacq.returncode == 0, "Lock reacquisition failed after transport loss"
    assert (time.monotonic() - t_reacq) <= 5.0

    survivors = subprocess.run(ssh_opts + [f"ps -eo pid,cmd | grep '{fixture_dir}/' | grep -v grep || true"], capture_output=True, text=True, timeout=5.0).stdout.strip()
    assert survivors == "", f"Found remote survivors after transport loss: {survivors}"

    # VAL-DEP-004: Fencing rejects stale epoch before mutation executes; valid epoch succeeds
    print("# VAL-DEP-004: testing epoch fencing with actual operation_fence_command...", flush=True)
    current_epoch = secrets.token_hex(16)
    stale_epoch = secrets.token_hex(16)
    subprocess.run(ssh_opts + [f'printf "%s\\n" "{current_epoch}" >"{epoch_file}"'], check=True, timeout=5.0)

    # Stale epoch test using actual generator
    stale_cmd = subprocess.run(
        ["bash", "-c", f"""
export CYMPHO_DEPLOY_SOURCE_ONLY=1
source '{deploy_sh}'
export DEPLOY_OPERATION_LOCK='{operation_lock}'
export DEPLOY_EPOCH_FILE='{epoch_file}'
export DEPLOY_EPOCH='{stale_epoch}'
export DEPLOY_USER='zaali'
export DEPLOY_REMOTE_COMMAND_PREFIX="export PATH=\\"{fixture_dir}/bin:\\$PATH\\"; "
operation_fence_command touch '{stale_marker}'
"""], capture_output=True, text=True, check=True
    ).stdout.strip()

    res_stale = subprocess.run(ssh_opts + [stale_cmd], capture_output=True, text=True, timeout=5.0)
    assert res_stale.returncode == 76, f"Expected 76, got {res_stale.returncode}"
    assert "stale deploy epoch" in res_stale.stderr
    assert subprocess.run(ssh_opts + [f'test ! -e "{stale_marker}"'], timeout=5).returncode == 0, "Stale epoch executed mutation!"

    # Valid epoch test using actual generator
    valid_cmd = subprocess.run(
        ["bash", "-c", f"""
export CYMPHO_DEPLOY_SOURCE_ONLY=1
source '{deploy_sh}'
export DEPLOY_OPERATION_LOCK='{operation_lock}'
export DEPLOY_EPOCH_FILE='{epoch_file}'
export DEPLOY_EPOCH='{current_epoch}'
export DEPLOY_USER='zaali'
export DEPLOY_REMOTE_COMMAND_PREFIX="export PATH=\\"{fixture_dir}/bin:\\$PATH\\"; "
operation_fence_command touch '{valid_marker}'
"""], capture_output=True, text=True, check=True
    ).stdout.strip()

    subprocess.run(ssh_opts + [valid_cmd], check=True, timeout=5.0)
    assert subprocess.run(ssh_opts + [f'test -f "{valid_marker}"'], timeout=5).returncode == 0

except Exception as e:
    traceback.print_exc()
    raise
finally:
    full_teardown()
    rem_check = subprocess.run(ssh_opts + [f'test ! -e "{fixture_dir}"'], timeout=5)
    assert rem_check.returncode == 0, "Remote fixture directory was not removed!"
    survivors = subprocess.run(ssh_opts + [f"ps -eo pid,cmd | grep '{fixture_dir}/' | grep -v grep || true"], capture_output=True, text=True, timeout=5.0).stdout.strip()
    assert survivors == "", f"Residual survivors found in cleanup: {survivors}"
PY
  printf 'ok - genuine Linux acceptance verifies VAL-DEP-001 through VAL-DEP-004 on authorized host\n'
else
  printf 'ok - genuine Linux acceptance skipped: explicit remote execution not requested (set CYMPHO_RUN_LINUX_FIXTURE=1) # SKIP\n'
fi

printf '1..4\n'
