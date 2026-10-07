#!/usr/bin/env python3
"""Passive, rollback-only browser fixture. No dev DB, agents, or port-based kill.

Run `python3 scripts/validation_browser.py start` in the background, then use
`healthcheck` and `stop`. Runtime files (including synthetic login credentials)
are private; never copy login.json into browser evidence. Build test assets and
compile separately before starting. Total lifetime, including reaping, is 210s.
"""

import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request

SCRIPT = Path(__file__).resolve()
REPO = SCRIPT.parent.parent
ROOT = Path("/tmp") / f"cympho-browser-validation-{os.getuid()}"
BASE_URL = "http://127.0.0.1:4329"
LIFETIME = 210


def private_root():
    try:
        ROOT.mkdir(mode=0o700)
        os.chown(ROOT, os.getuid(), os.getgid())
    except FileExistsError:
        pass
    info = ROOT.lstat()
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.getuid()
        or info.st_gid != os.getgid()
        or info.st_mode & 0o077
    ):
        raise RuntimeError("Harness root must be a private, owned directory")
    return ROOT


def owned_wrapper(state):
    if state["repo"] != str(REPO) or state["wrapper_pid"] <= 1:
        raise RuntimeError("Invalid harness process record")
    result = subprocess.run(
        ["ps", "-p", str(state["wrapper_pid"]), "-o", "command="],
        capture_output=True, text=True, timeout=1, check=True,
    )
    args = shlex.split(result.stdout.strip())
    if str(SCRIPT) not in args or args[-1:] != ["start"]:
        raise RuntimeError("Recorded PID is not this harness; refusing to signal")


def pressure():
    result = subprocess.run(
        ["sysctl", "-n", "kern.memorystatus_vm_pressure_level"],
        capture_output=True, text=True, timeout=1, check=True,
    )
    value = result.stdout.strip()
    if value not in ("1", "2", "4"):
        raise RuntimeError("Memory pressure metric unavailable or unknown")
    if value == "4":
        raise RuntimeError("High memory pressure; refusing browser fixture")


def group_alive(pid):
    try:
        os.killpg(pid, 0)
        return True
    except ProcessLookupError:
        return False


def reap(child):
    # Only the group created by this invocation is ever signalled.
    for sig in (signal.SIGTERM, signal.SIGKILL):
        if group_alive(child.pid):
            os.killpg(child.pid, sig)
        until = time.monotonic() + 4
        while group_alive(child.pid) and time.monotonic() < until:
            child.poll()
            time.sleep(0.1)
    child.wait(timeout=1)
    if group_alive(child.pid):
        raise RuntimeError("Owned process group survived cleanup")


def start(lock):
    deadline = time.monotonic() + LIFETIME
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    database = os.environ.get("TEST_DB_NAME", "cympho_test")
    if not re.fullmatch(r"cympho_test(?:_[a-z0-9_]+)?", database):
        raise RuntimeError("Browser fixture requires a cympho_test database name")
    if os.environ.get("TEST_DB_HOST", "127.0.0.1") != "127.0.0.1":
        raise RuntimeError("Browser fixture requires TEST_DB_HOST=127.0.0.1")
    pressure()
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 4329))
    for path in ("_build/test/lib/cympho/ebin/cympho.app",
                 "priv/static/assets/app.js", "priv/static/assets/app.css"):
        if not (REPO / path).is_file():
            raise RuntimeError("Compile and build test assets before starting")
    run_root = Path(tempfile.mkdtemp(prefix="run-", dir=ROOT))
    for name in ("tmp", "home", "uploads", "workspace", "profiles"):
        (run_root / name).mkdir(mode=0o700)
    # Do not inherit provider/proxy credentials, telemetry, storage, dev DB,
    # shell startup files, or arbitrary ERL_FLAGS. Test DB credentials only.
    env = {
        key: os.environ[key]
        for key in ("PATH", "LANG", "MIX_HOME", "MIX_ARCHIVES")
        if key in os.environ
    }
    for key in ("TEST_DB_USER", "TEST_DB_PASSWORD"):
        if key in os.environ:
            env[key] = os.environ[key]
    env.update(
        MIX_ENV="test", TEST_DB_HOST="127.0.0.1", TEST_DB_NAME=database,
        ERL_FLAGS="+S 2:2 +SDcpu 1 +SDio 1",
        HOME=str(run_root / "home"), TMPDIR=str(run_root / "tmp"),
        APP_HOST="127.0.0.1", PORT="4329", HTTP_BIND_IP="127.0.0.1",
        CYMPHO_MAX_CONCURRENT_AGENTS="1", CYMPHO_MAX_LOCAL_AGENT_RUNS="1",
        CYMPHO_BROWSER_ROOT=str(run_root),
    )
    child = None
    stopped = False
    state = {}

    def stop_requested(_signum, _frame):
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGTERM, stop_requested)
    signal.signal(signal.SIGINT, stop_requested)
    try:
        with (run_root / "server.log").open("x") as log:
            child = subprocess.Popen(
                ["mix", "run", "--no-start", "--no-compile", "--no-deps-check",
                 str(REPO / "test/support/browser_fixture_server.exs")],
                cwd=REPO, env=env, stdin=subprocess.DEVNULL, stdout=log,
                stderr=subprocess.STDOUT, start_new_session=True,
            )
            state = {
                "wrapper_pid": os.getpid(), "child_pid": child.pid,
                "repo": str(REPO), "run_root": str(run_root), "database": database,
            }
            (ROOT / "active.json").write_text(json.dumps(state))
            print(f"HARNESS_PID={os.getpid()} ROOT={run_root} MAX_LIFETIME=210",
                  flush=True)
            next_pressure = 0
            while child.poll() is None and not stopped:
                if time.monotonic() >= deadline - 16:
                    break
                if time.monotonic() >= next_pressure:
                    pressure()
                    next_pressure = time.monotonic() + 2
                time.sleep(0.2)
    finally:
        if child is not None:
            # Let the fixture rollback before any OS signal can stop the VM.
            (run_root / "stop").touch()
            try:
                child.wait(timeout=4)
            except subprocess.TimeoutExpired:
                pass
            reap(child)
        clean = run_root.joinpath("cleanup.ok").is_file()
        result = {**state, "sandbox_cleanup_verified": clean,
                  "exit_code": child.returncode if child else None}
        (ROOT / "last.json").write_text(json.dumps(result))
        (ROOT / "active.json").unlink(missing_ok=True)
        if clean and child.returncode == 0:
            shutil.rmtree(run_root)
        else:
            print(f"Private startup/cleanup diagnostics retained at {run_root}",
                  file=sys.stderr)
    if not clean:
        raise RuntimeError("Sandbox cleanup needs independent verification")
    if child.returncode != 0:
        raise RuntimeError("Fixture exited unsuccessfully")


def inspect_service(lock, action):
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        pass
    else:
        if action == "stop":
            if (ROOT / "last.json").exists():
                result = json.loads((ROOT / "last.json").read_text())
                if not result["sandbox_cleanup_verified"]:
                    raise RuntimeError("Previous sandbox cleanup needs independent verification")
            print("Harness is not running; no process signalled")
            return
        raise RuntimeError("Harness is not running")
    state = json.loads((ROOT / "active.json").read_text())
    owned_wrapper(state)
    if action == "stop":
        os.kill(state["wrapper_pid"], signal.SIGTERM)
        until = time.monotonic() + 15
        while time.monotonic() < until:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                result = json.loads((ROOT / "last.json").read_text())
                if not result["sandbox_cleanup_verified"]:
                    raise RuntimeError("Sandbox cleanup needs independent verification")
                print("Owned harness stopped; sandbox cleanup verified")
                return
            except BlockingIOError:
                time.sleep(0.2)
        raise RuntimeError("Owned harness stop deadline exceeded")
    if not (Path(state["run_root"]) / "ready").is_file():
        raise RuntimeError("Fixture is not ready")
    # Port inspection is read-only and never supplies the PID for stop.
    listener = subprocess.run(
        ["lsof", "-nP", "-a", "-iTCP:4329", "-sTCP:LISTEN", "-t"],
        capture_output=True, text=True, timeout=1, check=True,
    )
    pids = [int(value) for value in listener.stdout.split()]
    if not pids or any(os.getpgid(pid) != state["child_pid"] for pid in pids):
        raise RuntimeError("Loopback listener is not owned by this harness")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(BASE_URL + "/api/health", timeout=3) as response:
        report = json.load(response)
    if (
        report.get("schema_version") != 1
        or report.get("status") != "ready"
        or report.get("service") != "cympho"
    ):
        raise RuntimeError("Loopback application health check failed")
    print("Sandbox browser fixture ready at " + BASE_URL
          + " database=" + state["database"])


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("start", "stop", "healthcheck"):
        raise RuntimeError("Usage: validation_browser.py start|stop|healthcheck")
    if sys.argv[1] == "start" and sys.argv[0] != str(SCRIPT):
        os.execv(sys.executable, [sys.executable, str(SCRIPT), "start"])
    os.umask(0o077)
    private_root()
    with (ROOT / "lifecycle.lock").open("a+") as lock:
        if sys.argv[1] == "start":
            start(lock)
        else:
            inspect_service(lock, sys.argv[1])


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        message = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print(f"HARNESS_ERROR: {message}", file=sys.stderr)
        sys.exit(1)
