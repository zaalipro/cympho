#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$ROOT/deploy.sh" <<'PY'
import sys

deploy = open(sys.argv[1], encoding="utf-8").read()


def require(fragment, message):
    if fragment not in deploy:
        raise SystemExit(f"not ok - {message}")


def require_in(section, fragment, message):
    if fragment not in section:
        raise SystemExit(f"not ok - {message}")


def require_before(first, second, message):
    require(first, message)
    require(second, message)
    if deploy.index(first) >= deploy.index(second):
        raise SystemExit(f"not ok - {message}")


require_before(
    'step "Snapshotting installed systemd units"',
    'step "Installing systemd units"',
    "both installed units must be snapshotted before either is activated",
)
require(
    "snapshot_systemd_units",
    "deploy must expose one fail-closed systemd-unit snapshot operation",
)
require(
    "restore_systemd_units",
    "deploy must expose one systemd-unit restore operation used by failures",
)

for unit in ("cympho.service", "cympho-git-agent.service"):
    require(
        unit,
        f"transaction must cover {unit}",
    )
require(
    'live="/etc/systemd/system/\\$unit"',
    "both unit names must resolve under /etc/systemd/system",
)

restore_start = deploy.index("restore_systemd_units()")
restore_end = deploy.index("\ncommit_systemd_units()", restore_start)
restore_body = deploy[restore_start:restore_end]
if restore_body.count("cmp -s") < 2:
    raise SystemExit(
        "not ok - restore must compare both live units before overwriting external changes"
    )
require_in(
    restore_body,
    "systemctl daemon-reload",
    "unit restoration must reload the systemd manager",
)
snapshot_start = deploy.index("snapshot_systemd_units()")
snapshot_end = deploy.index("\nrestore_systemd_units()", snapshot_start)
snapshot_body = deploy[snapshot_start:snapshot_end]
require_in(
    snapshot_body,
    "systemctl is-enabled",
    "snapshot must record whether the main unit was enabled before deployment",
)
require_in(
    snapshot_body,
    "main-unit.enabled",
    "enable-state evidence must be stored with the protected unit snapshot",
)
require_in(snapshot_body, "main-unit.active", "snapshot must record prior main service active state")
require_in(snapshot_body, "stat -c '%a %u %g'", "snapshot must preserve prior unit metadata")
require_in(snapshot_body, "main-unit.active", "snapshot must preserve active state text")
require_in(snapshot_body, "Unexpected active state", "snapshot must fail closed on transitional active states")
if "is-active --quiet" in snapshot_body:
    raise SystemExit("not ok - active-state snapshot must preserve exact systemctl text")
require_in(restore_body, "unit.meta", "rollback must validate saved unit metadata")
require_in(restore_body, 'fresh_meta="644 0 0"', "rollback must use installed candidate metadata, not read-only source metadata")
if "fresh_meta=\\$(_sudo stat -c '%a %u %g' -- \\\"\\$fresh\\\")" in restore_body:
    raise SystemExit("not ok - rollback must not treat source mode 0444 as installed unit metadata")
require_in(restore_body, '-m "\\$prior_mode" -o "\\$prior_uid" -g "\\$prior_gid"', "rollback must restore exact prior unit metadata")
require_in(snapshot_body, "Active state does not match an absent main unit", "snapshot must reject active not-found service state")
require_in(restore_body, "main-unit.active", "rollback must restore prior main service active state")
require_in(restore_body, "systemctl restart", "rollback must restore a previously active service")
require_in(restore_body, "systemctl stop", "rollback must restore a previously inactive service")
if restore_body.index("systemctl stop ${SERVICE_NAME}") >= restore_body.index("restore_unit ${SERVICE_NAME}.service"):
    raise SystemExit("not ok - first-deploy cleanup must stop a possibly started service before removing its unit")
if snapshot_body.count("enabled|disabled|not-found) ;;\n") != 1 or restore_body.count(
    "enabled|disabled|not-found) ;;\n"
) < 1 or "static|" in snapshot_body or "static|" in restore_body:
    raise SystemExit(
        "not ok - enable-state transaction must fail closed on states it cannot restore exactly"
    )
require_in(
    snapshot_body,
    "Enablement state does not match the installed main unit",
    "snapshot must reject contradictory is-enabled output and unit-file existence",
)
require_in(
    restore_body,
    "systemctl disable",
    "rollback must undo enablement when the main unit was previously disabled or absent",
)
require_in(
    restore_body,
    "systemctl enable",
    "rollback must restore prior main-unit enablement",
)
require_in(
    restore_body,
    "main-unit.enable-attempted",
    "rollback must distinguish an interrupted enable operation",
)
require_in(
    restore_body,
    "main-unit.expected-enabled",
    "rollback must require activation-owned expected enablement evidence",
)
if "Refusing automatic unit rollback after an interrupted enable operation" in restore_body:
    raise SystemExit("not ok - known partial enable outcomes must remain CAS-restorable")
require_in(restore_body, "Ambiguous enable operation outcome", "unknown partial enablement must still fail closed")
require_in(
    restore_body,
    "Unexpected current enablement state",
    "rollback must fail closed when live enablement differs from activation evidence",
)
disable_call = restore_body.index("systemctl disable")
restore_main_call = restore_body.index("\nrestore_unit ${SERVICE_NAME}.service")
if disable_call >= restore_main_call:
    raise SystemExit(
        "not ok - rollback must remove new enablement while the new unit bytes still exist"
    )
if "systemctl disable ${SERVICE_NAME} >/dev/null 2>&1 || true" in restore_body:
    raise SystemExit("not ok - rollback must fail closed if prior disablement cannot be restored")
require(
    'main_live=/etc/systemd/system/${SERVICE_NAME}.service',
    "enable-state restore must identify whether the main unit was actually installed",
)
require(
    'if [ "\\$current_enabled_state" = enabled ] && [ "\\$main_enabled_state" != enabled ]',
    "rollback must disable only a known newly enabled unit",
)
if "systemctl enable ${SERVICE_NAME} >/dev/null 2>&1 || true" in deploy:
    raise SystemExit("not ok - enablement failure must trigger transactional rollback")

install_step = deploy.index('step "Installing systemd units"')
install_end = deploy.index('\nstep "Verifying Postgres', install_step)
install_body = deploy[install_step:install_end]
require_in(install_body, "stat -c '%a %u %g'", "unit installation must inspect existing metadata")
require_in(install_body, '644 0 0', "unit installation must require root-owned non-writable metadata")
require_in(install_body, 'install_unit \"\\$unit_src\" \"\\$unit_dst\"', "unsafe metadata must trigger atomic reinstall")
require_in(
    install_body,
    "main-unit.enable-attempted",
    "activation must record enablement intent before invoking systemctl enable",
)
require_in(
    install_body,
    "main-unit.expected-enabled",
    "activation must record successfully read-back enablement",
)
if "_sudo tee '${UNIT_SNAPSHOT_DIR}/main-unit.enable" in install_body:
    raise SystemExit("not ok - enablement transaction markers must not use tee publication")
require_in(install_body, "atomic_enable_marker", "enablement markers must use atomic same-directory publication")
require_in(install_body, "sync -d", "enablement markers must sync their file and parent directory")
require_in(install_body, "enable_status=\\$?", "enable command failure must be captured before readback recording")
if install_body.index("enable_status=\\$?") >= install_body.index("systemctl is-enabled"):
    raise SystemExit("not ok - enable failure status must be captured before mandatory readback")
if install_body.index("main-unit.enable-attempted") >= install_body.index("systemctl enable"):
    raise SystemExit("not ok - enablement intent must be recorded before enable starts")
if install_body.index("systemctl enable") >= install_body.index("main-unit.expected-enabled"):
    raise SystemExit("not ok - expected enablement marker must follow successful enable")
require_in(
    install_body,
    "systemctl is-enabled",
    "activation must read enablement back before recording its expected state",
)
enable_call = install_body.index("systemctl enable")
enable_readback = install_body.index("systemctl is-enabled")
expected_marker = install_body.index("main-unit.expected-enabled")
if not enable_call < enable_readback < expected_marker:
    raise SystemExit(
        "not ok - expected enablement must be recorded only after successful enable readback"
    )

cleanup_start = deploy.index("cleanup_local()")
cleanup_end = deploy.index("\n}\n", cleanup_start)
cleanup_body = deploy[cleanup_start:cleanup_end]
require(
    "restore_systemd_units",
    "the EXIT trap must restore units after failures before release cutover",
)
if cleanup_body.index("restore_systemd_units") >= cleanup_body.index('kill "${DEPLOY_LOCK_PID}"'):
    raise SystemExit("not ok - unit restoration must run while the remote deploy lock is held")
require_in(
    cleanup_body,
    '"${UNIT_SNAPSHOT_CLEANUP_DEBT}" != "1"',
    "post-commit cleanup debt must preserve its referenced source evidence",
)
require_in(
    cleanup_body,
    "restore_systemd_units under-held-lock",
    "EXIT cleanup must never independently reacquire from a restore helper",
)
require_in(cleanup_body, "restore_transaction_after_lock_loss", "lock loss must restore env and units under one reacquired lock")
require_in(cleanup_body, "under-held-lock", "cleanup must use non-reacquiring restore mode while original lock is live")
require_in(cleanup_body, "restore_transaction_after_lock_loss", "cleanup must funnel lock-loss races through one coordinator")
transaction_start = deploy.index("restore_transaction_after_lock_loss()")
transaction_end = deploy.index("\n}\n", transaction_start)
transaction_body = deploy[transaction_start:transaction_end]
require_in(transaction_body, "restore_runtime_env under-recovered-lock", "combined recovery must restore env under recovered lock")
require_in(transaction_body, "restore_systemd_units under-recovered-lock", "combined recovery must restore units under recovered lock")
if transaction_body.count("flock --wait 20") != 1:
    raise SystemExit("not ok - lock-loss transaction must reacquire exactly one bounded flock")
if transaction_body.index("restore_runtime_env") >= transaction_body.index("restore_systemd_units"):
    raise SystemExit("not ok - lock-loss transaction must restore environment before systemd units")
cas_start = deploy.index("run_remote_script_with_current_link_cas()")
cas_end = deploy.index("\n}\n", cas_start)
cas_body = deploy[cas_start:cas_end]
require_in(cas_body, "run_ssh_nonfatal", "cleanup CAS runner must return lock loss to the coordinator")
if '| run_ssh "bash -s"' in cas_body:
    raise SystemExit("not ok - cleanup CAS runner must not use fail-fast run_ssh")
if "run_remote_script_with_reacquired_lock" in deploy:
    raise SystemExit("not ok - individual restore helpers must not reacquire their own flock")
require_in(restore_body, '_sudo ln -s "\\$previous_release" "\\$rollback_link"', "recovery must stage the previous release link")
require_in(restore_body, '_sudo mv -fT -- "\\$rollback_link"', "recovery must atomically publish the previous release link")
require_in(restore_body, "systemctl restart ${SERVICE_NAME}", "recovery must restart the previous release after cutover rollback")
require_in(restore_body, '[ "\\$current_enabled_state" != "\\$expected_current_state" ] &&', "unit rollback must accept an already-restored prior enablement state")
require_in(restore_body, '[ "\\$main_enabled_state" != not-found ] || [ "\\$current_enabled_state" != disabled ]', "retry after disabling a newly installed candidate must accept only the sealed disabled candidate state")
require_in(restore_body, '[ "\\$main_enabled_state" = not-found ] && _sudo test -f "\\$main_live"', "rollback must stop a newly started service before removing an absent prior unit")
require_in(restore_body, 'under-recovered-lock', "recovery mode must trigger current-link CAS")

rollback_start = deploy.index("rollback_release()")
rollback_end = deploy.index('\nstep "Placing release', rollback_start)
rollback_body = deploy[rollback_start:rollback_end]
require_in(rollback_body, "prior_active_state", "rollback must read saved active state before probing")
require_in(rollback_body, "readiness probe skipped", "inactive rollback must report skipped readiness probe")
require_in(rollback_body, "systemctl is-active", "inactive rollback must verify exact inactive state")
require(
    "restore_systemd_units",
    "post-cutover rollback must restore unit bytes as well as the release link",
)
require_in(rollback_body, "atomic_current_link", "explicit rollback must atomically publish the prior release link")
require_in(rollback_body, "restore_systemd_units", "explicit rollback must delegate active-state restoration to unit rollback")
first_branch = rollback_body[rollback_body.index('No previous release exists'):]
if 'systemctl stop ${SERVICE_NAME}" || true' in first_branch:
    raise SystemExit("not ok - first deployment stop failure must remain recoverable")
if 'sudo rm -f \'${CURRENT_LINK}\'" || true' in first_branch:
    raise SystemExit("not ok - first deployment link removal failure must remain recoverable")
require_in(first_branch, "Failed to stop first deployment service", "first deployment stop failure needs a stable diagnostic")
if not first_branch.index("systemctl stop") < first_branch.index("sudo rm -f -- '${CURRENT_LINK}'") < first_branch.index("restore_runtime_env") < first_branch.index("restore_systemd_units"):
    raise SystemExit("not ok - first deployment must stop, remove link, then consume rollback snapshots")

public_ready = deploy.index('echo "Public HTTPS readiness verified at revision ${BUILD_REVISION}."')
commit_call = deploy.index('UNIT_SNAPSHOT_ACTIVE=0', public_ready)
if public_ready >= commit_call:
    raise SystemExit("not ok - new unit bytes must not be committed until public readiness succeeds")
commit_start = deploy.index("commit_systemd_units()")
commit_end = deploy.index("\n}\n", commit_start)
commit_body = deploy[commit_start:commit_end]
require_in(
    commit_body,
    "UNIT_SNAPSHOT_ACTIVE=0",
    "logical unit commit must be recorded locally",
)
require_in(
    commit_body,
    "WARNING: committed systemd-unit snapshot cleanup failed",
    "failed post-commit cleanup must leave explicit cleanup debt",
)
require_in(
    commit_body,
    "run_remote_script_nonfatal",
    "post-commit snapshot cleanup must be best-effort even if the lock holder died",
)
if commit_body.index("UNIT_SNAPSHOT_ACTIVE=0") >= commit_body.index("run_remote_script_nonfatal"):
    raise SystemExit(
        "not ok - local transaction must commit before ambiguous remote snapshot deletion"
    )
if "run_ssh" in commit_body or "ssh \"${SSH_OPTS[@]}\"" in commit_body:
    raise SystemExit(
        "not ok - best-effort post-commit cleanup must not invoke the fail-fast lock guard"
    )
if "commit_systemd_units || rollback_release" in deploy:
    raise SystemExit("not ok - snapshot cleanup failure after public readiness must not roll release back")
require_in(
    deploy[public_ready:],
    "UNIT_SNAPSHOT_ACTIVE=0",
    "combined logical commit must clear unit transaction before cleanup",
)
require_in(
    deploy[public_ready:],
    "ENV_SNAPSHOT_ACTIVE=0",
    "combined logical commit must clear environment transaction before cleanup",
)

for current_fragment in ("ln -sfn '${CURRENT_LINK}'", "ln -sfn \"${CURRENT_LINK}\""):
    if current_fragment in deploy:
        raise SystemExit("not ok - current release cutover must not use non-atomic ln -sfn")
require_in(deploy, "atomic_current_link", "release cutover/rollback must use atomic current-link replacement")
activation_start = deploy.index('step "Activating release and restarting service"')
activation_end = deploy.index('\nstep "Attested readiness check', activation_start)
activation_body = deploy[activation_start:activation_end]
require_in(activation_body, "mv -fT", "release activation must publish current with atomic rename")

print("ok - deploy snapshots and transactionally restores both systemd units")
print("1..1")
PY
