#!/usr/bin/env bash
#
# Deploy Cympho to the target host.
#
#   * Builds a self-contained release (bundled ERTS) inside a throwaway Debian
#     Docker builder using the pinned Elixir 1.19.5 / OTP 28 image — the host's
#     system Elixir is too old to build with. The release RUNS natively under
#     systemd (no container at runtime).
#   * Postgres runs natively under systemd on the host, bound to loopback. The
#     script does not provision it — see the "Verifying Postgres" step for what
#     to create by hand on a fresh host.
#   * nginx (already on 80/443) reverse-proxies cympho.llmotions.com with TLS
#     from Let's Encrypt (certbot --nginx). The site config is a separate
#     sites-available file symlinked into sites-enabled — never edited into the
#     main nginx.conf.
#
# Idempotent and safe to re-run; rolls the release symlink back on failure.
#
# Target host uses SSH key auth and passwordless sudo — no password required.
# Usage:     ./deploy.sh [--run-tests]

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}"

# --- Target / identity -------------------------------------------------------
# GCP VPS (zaali@34.136.10.30). CYMPHO_-namespaced overrides win; the generic
# DEPLOY_HOST/DEPLOY_USER from ~/.secrets point at the same box.
DEPLOY_USER="${CYMPHO_DEPLOY_USER:-${DEPLOY_USER:-zaali}}"
DEPLOY_HOST="${CYMPHO_DEPLOY_HOST:-${DEPLOY_HOST:-34.136.10.30}}"
DEPLOY_PORT="${CYMPHO_DEPLOY_PORT:-22}"
DEPLOY_TARGET="${DEPLOY_USER}@${DEPLOY_HOST}"

# --- App layout --------------------------------------------------------------
APP_NAME="${CYMPHO_APP_NAME:-cympho}"
APP_USER="${CYMPHO_APP_USER:-cympho}"
DOMAIN="${CYMPHO_DOMAIN:-cympho.llmotions.com}"
PREVIEW_DOMAIN="${CYMPHO_PREVIEW_DOMAIN:-preview.${DOMAIN}}"
APP_PORT="${CYMPHO_APP_PORT:-4000}"
DB_PORT="${CYMPHO_DB_PORT:-5432}"
DEPLOY_ROOT="${CYMPHO_DEPLOY_ROOT:-/opt/cympho}"
ENV_FILE="${CYMPHO_ENV_FILE:-/etc/cympho.env}"
SERVICE_NAME="${CYMPHO_SERVICE_NAME:-cympho}"

# TLS certificate contact for certbot's first issuance on this host.
CERTBOT_EMAIL="${CYMPHO_CERTBOT_EMAIL:-admin@llmotions.com}"

SKIP_TESTS="${CYMPHO_SKIP_TESTS:-1}"

SOURCES_DIR="${DEPLOY_ROOT}/sources"
SOURCE_DIR=""
SOURCE_DIR_SAFE=0
RELEASES_DIR="${DEPLOY_ROOT}/releases"
CURRENT_LINK="${DEPLOY_ROOT}/current"
DB_ENV_FILE="${DEPLOY_ROOT}/db.env"
UPLOADS_DIR="${DEPLOY_ROOT}/data/uploads"
IMPORT_SPOOL_DIR="${DEPLOY_ROOT}/data/import-transfers"
LOCAL_READINESS_URL="http://127.0.0.1:${APP_PORT}/api/health"
PUBLIC_READINESS_URL="https://${DOMAIN}/api/health"
BUILD_REVISION="${CYMPHO_BUILD_REVISION:-}"
SOURCE_REVISION=""
DEPLOY_CONTEXT=""
DEPLOY_LOCK_PID=""
DEPLOY_LOCK_MONITOR_PID=""
DEPLOY_MAIN_PID="$$"
DEPLOY_LOCK_OUTPUT=""
STARTED_DEPLOY_LOCK_PID=""
DEPLOY_SESSION_LOCK="/var/lock/cympho-deploy.lock"
DEPLOY_OPERATION_LOCK="/var/lock/cympho-deploy-operation.lock"
DEPLOY_EPOCH_FILE="/var/lock/cympho-deploy.epoch"
DEPLOY_EPOCH=""
DEPLOY_NONCE=""
BUILD_IMAGE_TAG=""
UNIT_SNAPSHOT_DIR=""
UNIT_SNAPSHOT_ACTIVE=0
UNIT_SNAPSHOT_CLEANUP_DEBT=0
ENV_SNAPSHOT_DIR=""
ENV_SNAPSHOT_ACTIVE=0
ENV_SNAPSHOT_CLEANUP_DEBT=0
PREVIOUS_RELEASE=""
RELEASE_DIR=""

usage() {
  cat <<EOF
Usage: ./deploy.sh [--run-tests]

  --run-tests   Run 'mix test' locally before deploying (default: skip).

TLS + routing are handled by the host's nginx; certbot issues/renews one cert
for ${DOMAIN} and the isolated preview origin ${PREVIEW_DOMAIN} (webroot
/var/www/certbot, same pattern as the other sites). Point both DNS names here.

Environment overrides (CYMPHO_-namespaced win over generic): CYMPHO_DEPLOY_HOST,
CYMPHO_DEPLOY_USER, CYMPHO_DEPLOY_PORT, CYMPHO_DOMAIN, CYMPHO_PREVIEW_DOMAIN,
CYMPHO_DB_PORT, CYMPHO_CERTBOT_EMAIL, CYMPHO_SKIP_HOST_CHECK.

This checked-in systemd unit is fixed to app/service 'cympho', user 'cympho',
/opt/cympho, /etc/cympho.env, and port 4000. Overrides for those fixed values
are rejected rather than silently installing an inconsistent unit.
EOF
}

while (($# > 0)); do
  case "$1" in
    --run-tests) SKIP_TESTS=0 ;;
    --skip-tests) SKIP_TESTS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

valid_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

valid_hostname() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]
}

valid_absolute_path() {
  [[ "$1" =~ ^/[A-Za-z0-9_./-]+$ ]] &&
    [[ "$1" != "/" && "$1" != *"//"* && "$1" != *"/../"* && "$1" != */.. ]]
}

valid_release_path() {
  [[ "$1" =~ ^/opt/cympho/releases/([0-9]{14}|[0-9]{14}-[0-9a-f]{12}-[0-9a-f]{8})$ ]]
}

new_deploy_epoch() {
  python3 -c 'import secrets; print(secrets.token_hex(16))'
}

[[ "${APP_NAME}" =~ ^[a-z][a-z0-9_]{0,63}$ ]] || {
  echo "CYMPHO_APP_NAME must be a safe lowercase release name." >&2; exit 1;
}
[[ "${APP_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || {
  echo "CYMPHO_APP_USER must be a safe Unix account name." >&2; exit 1;
}
[[ "${DEPLOY_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || {
  echo "CYMPHO_DEPLOY_USER must be a safe Unix account name." >&2; exit 1;
}
[[ "${SERVICE_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]{0,127}$ ]] || {
  echo "CYMPHO_SERVICE_NAME must be a simple systemd service name." >&2; exit 1;
}
valid_hostname "${DEPLOY_HOST}" || {
  echo "CYMPHO_DEPLOY_HOST must be a bare hostname or IPv4 address." >&2; exit 1;
}
valid_hostname "${DOMAIN}" || {
  echo "CYMPHO_DOMAIN must be a bare hostname." >&2; exit 1;
}
if ! valid_hostname "${PREVIEW_DOMAIN}" || [[ "${PREVIEW_DOMAIN}" == "${DOMAIN}" ]]; then
  echo "CYMPHO_PREVIEW_DOMAIN must be a distinct bare hostname." >&2
  exit 1
fi
valid_port "${DEPLOY_PORT}" || { echo "CYMPHO_DEPLOY_PORT must be 1-65535." >&2; exit 1; }
valid_port "${APP_PORT}" || { echo "CYMPHO_APP_PORT must be 1-65535." >&2; exit 1; }
valid_port "${DB_PORT}" || { echo "CYMPHO_DB_PORT must be 1-65535." >&2; exit 1; }
valid_absolute_path "${DEPLOY_ROOT}" || {
  echo "CYMPHO_DEPLOY_ROOT must be a safe absolute path." >&2; exit 1;
}
valid_absolute_path "${ENV_FILE}" || {
  echo "CYMPHO_ENV_FILE must be a safe absolute path." >&2; exit 1;
}
[[ "${CERTBOT_EMAIL}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] || {
  echo "CYMPHO_CERTBOT_EMAIL must be a simple email address." >&2; exit 1;
}

if [[ "${APP_NAME}" != "cympho" || "${APP_USER}" != "cympho" ||
      "${SERVICE_NAME}" != "cympho" || "${DEPLOY_ROOT}" != "/opt/cympho" ||
      "${ENV_FILE}" != "/etc/cympho.env" || "${APP_PORT}" != "4000" ]]; then
  echo "This deployment unit requires app/service/user cympho, /opt/cympho, /etc/cympho.env, and port 4000." >&2
  exit 1
fi
if [[ "${DEPLOY_USER}" == "${APP_USER}" ]]; then
  echo "CYMPHO_DEPLOY_USER must differ from the untrusted application service user." >&2
  exit 1
fi

require_cmd ssh
require_cmd rsync
require_cmd curl
require_cmd git
require_cmd tar
require_cmd python3

SOURCE_REVISION="$(git --no-replace-objects -C "${REPO_DIR}" rev-parse --verify HEAD)"
if [[ -z "${BUILD_REVISION}" ]]; then BUILD_REVISION="${SOURCE_REVISION}"; fi

if [[ ! "${BUILD_REVISION}" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
  echo "CYMPHO_BUILD_REVISION must be a 7-64 character hexadecimal revision." >&2
  exit 1
fi

if [[ "${BUILD_REVISION}" != "${SOURCE_REVISION}" ]]; then
  echo "Refusing to attest the synced source as ${BUILD_REVISION}: HEAD is ${SOURCE_REVISION}." >&2
  exit 1
fi

if ! git --no-replace-objects -C "${REPO_DIR}" diff --quiet -- ||
   ! git --no-replace-objects -C "${REPO_DIR}" diff --cached --quiet -- ||
   [[ -n "$(git --no-replace-objects -C "${REPO_DIR}" ls-files --others --exclude-standard)" ]]; then
  echo "Refusing to deploy while the working tree, index, or untracked build inputs differ from HEAD." >&2
  echo "Commit or remove those changes so the deployed revision matches operator intent." >&2
  exit 1
fi

if git --no-replace-objects -C "${REPO_DIR}" ls-files -s |
   awk '$1 == 120000 { found=1 } END { exit(found ? 0 : 1) }'; then
  echo "Refusing to deploy: tracked symlinks are not permitted in deployment source." >&2
  exit 1
fi

DEPLOY_CONTEXT="$(mktemp -d "${TMPDIR:-/tmp}/cympho-deploy.XXXXXX")"
DEPLOY_LOCK_OUTPUT="${DEPLOY_CONTEXT}/deploy-lock.out"
DEPLOY_EPOCH="$(new_deploy_epoch)"
DEPLOY_NONCE="$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
BUILD_IMAGE_TAG="${APP_NAME}-build:${BUILD_REVISION:0:12}-${DEPLOY_NONCE}"
SOURCE_DIR="${SOURCES_DIR}/${BUILD_REVISION:0:12}-${DEPLOY_NONCE}"
UNIT_SNAPSHOT_DIR="${DEPLOY_ROOT}/unit-snapshots/${BUILD_REVISION:0:12}-${DEPLOY_NONCE}"
ENV_SNAPSHOT_DIR="${DEPLOY_ROOT}/env-snapshots/${BUILD_REVISION:0:12}-${DEPLOY_NONCE}"
cleanup_local() {
  local unit_restore_failed=0
  local env_restore_failed=0
  local recovery_attempted=0

  if [[ -n "${DEPLOY_LOCK_MONITOR_PID}" ]]; then
    kill "${DEPLOY_LOCK_MONITOR_PID}" 2>/dev/null || true
    wait "${DEPLOY_LOCK_MONITOR_PID}" 2>/dev/null || true
  fi
  if [[ "${ENV_SNAPSHOT_ACTIVE}" == "1" || "${UNIT_SNAPSHOT_ACTIVE}" == "1" ]]; then
    if [[ -n "${DEPLOY_LOCK_PID}" ]] && kill -0 "${DEPLOY_LOCK_PID}" 2>/dev/null; then
      if [[ "${ENV_SNAPSHOT_ACTIVE}" == "1" ]] && ! restore_runtime_env under-held-lock; then env_restore_failed=1; fi
      if [[ "${UNIT_SNAPSHOT_ACTIVE}" == "1" && "${env_restore_failed}" != "1" ]] && ! restore_systemd_units under-held-lock; then unit_restore_failed=1; fi
    else
      recovery_attempted=1
      if ! restore_transaction_after_lock_loss; then
        [[ "${ENV_SNAPSHOT_ACTIVE}" == "1" ]] && env_restore_failed=1
        [[ "${UNIT_SNAPSHOT_ACTIVE}" == "1" ]] && unit_restore_failed=1
      fi
    fi
    if [[ "${env_restore_failed}" == "1" || "${unit_restore_failed}" == "1" ]] &&
       [[ "${recovery_attempted}" == "0" ]] &&
       { [[ -z "${DEPLOY_LOCK_PID}" ]] || ! kill -0 "${DEPLOY_LOCK_PID}" 2>/dev/null; } &&
       [[ "${ENV_SNAPSHOT_ACTIVE}" == "1" || "${UNIT_SNAPSHOT_ACTIVE}" == "1" ]]; then
      recovery_attempted=1
      env_restore_failed=0
      unit_restore_failed=0
      if ! restore_transaction_after_lock_loss; then
        [[ "${ENV_SNAPSHOT_ACTIVE}" == "1" ]] && env_restore_failed=1
        [[ "${UNIT_SNAPSHOT_ACTIVE}" == "1" ]] && unit_restore_failed=1
      fi
    fi
    if [[ "${env_restore_failed}" == "1" || "${unit_restore_failed}" == "1" ]]; then
      echo "CRITICAL: failed to restore deployment transaction; preserving deployment evidence." >&2
    fi
  fi
  if [[ -n "${DEPLOY_LOCK_PID}" ]]; then
    if kill -0 "${DEPLOY_LOCK_PID}" 2>/dev/null; then
      if [[ "${SOURCE_DIR_SAFE}" == "1" &&
            "${unit_restore_failed}" != "1" && "${env_restore_failed}" != "1" &&
            "${UNIT_SNAPSHOT_CLEANUP_DEBT}" != "1" && "${ENV_SNAPSHOT_CLEANUP_DEBT}" != "1" ]]; then
        cleanup_remote_source_dir >/dev/null 2>&1 || true
      fi
    fi
    kill "${DEPLOY_LOCK_PID}" 2>/dev/null || true
    wait "${DEPLOY_LOCK_PID}" 2>/dev/null || true
  fi
  rm -rf -- "${DEPLOY_CONTEXT}"
}
trap cleanup_local EXIT
trap 'exit 1' HUP INT TERM
git --no-replace-objects -C "${REPO_DIR}" archive --format=tar "${SOURCE_REVISION}^{commit}" |
  tar -xf - -C "${DEPLOY_CONTEXT}"
if find "${DEPLOY_CONTEXT}" -xdev -type l -print -quit | grep -q .; then
  echo "Refusing to deploy: symlinks are not permitted in the extracted source archive." >&2
  exit 1
fi

# Safety guard: the domain must point at the deploy host. If it doesn't, we're
# almost certainly aimed at the wrong machine — abort. Best-effort (needs dig).
if [[ "${CYMPHO_SKIP_HOST_CHECK:-0}" != "1" ]] && command -v dig >/dev/null 2>&1; then
  domain_ip="$(dig +short "${DOMAIN}" A | tail -1)"
  host_ip="$(dig +short "${DEPLOY_HOST}" A | tail -1)"
  [[ -z "${host_ip}" ]] && host_ip="${DEPLOY_HOST}"  # DEPLOY_HOST is already an IP
  if [[ -n "${domain_ip}" && "${domain_ip}" != "${host_ip}" ]]; then
    echo "Refusing to deploy: ${DOMAIN} resolves to ${domain_ip}, but deploy host" >&2
    echo "${DEPLOY_HOST} is ${host_ip}. Wrong target? Set CYMPHO_SKIP_HOST_CHECK=1 to override." >&2
    exit 1
  fi
fi

SSH_OPTS=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=20
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=3
  -p "${DEPLOY_PORT}"
)
RSYNC_RSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -p ${DEPLOY_PORT}"

run_ssh() {
  require_deploy_lock
  ssh "${SSH_OPTS[@]}" "${DEPLOY_TARGET}" "$@"
}

shell_quote() {
  local quoted="" rest="${1-}" prefix
  while [[ "${rest}" == *"'"* ]]; do
    prefix="${rest%%\'*}"
    quoted+="${prefix}'\"'\"'"
    rest="${rest#*\'}"
  done
  printf "'%s%s'" "${quoted}" "${rest}"
}

# Render a remote command that holds the permanent operation-lock inode for
# its entire body and validates this deploy's root-published epoch after the
# lock is acquired. The command itself still runs as the SSH deploy user.
operation_fence_command() {
  (($# > 0)) || { echo "remote command required" >&2; return 1; }
  local fence_body command remote_command_arg quoted_args=""

  for remote_command_arg in "$@"; do
    quoted_args+=" $(shell_quote "${remote_command_arg}")"
  done

  fence_body="set -euo pipefail
operation_lock=$(shell_quote "${DEPLOY_OPERATION_LOCK}")
epoch_file=$(shell_quote "${DEPLOY_EPOCH_FILE}")
expected_epoch=$(shell_quote "${DEPLOY_EPOCH}")
[ ! -L \"\$operation_lock\" ] && [ -f \"\$operation_lock\" ] || { echo \"invalid deploy operation lock\" >&2; exit 76; }
[ \"\$(stat -c %u -- \"\$operation_lock\")\" = 0 ] || { echo \"deploy operation lock is not root-owned\" >&2; exit 76; }
exec 9>>\"\$operation_lock\"
flock --exclusive --wait 60 9 || { echo \"timed out waiting for deploy operation lock\" >&2; exit 76; }
[ ! -L \"\$epoch_file\" ] && [ -f \"\$epoch_file\" ] || { echo \"invalid deploy epoch file\" >&2; exit 76; }
[ \"\$(stat -c %u -- \"\$epoch_file\")\" = 0 ] || { echo \"deploy epoch file is not root-owned\" >&2; exit 76; }
actual_epoch=\$(cat -- \"\$epoch_file\")
[ \"\$actual_epoch\" = \"\$expected_epoch\" ] || { echo \"stale deploy epoch; refusing remote mutation\" >&2; exit 76; }
# Do not exec the deploy-user child: sudo may close inherited descriptors,
# while this root wrapper must retain FD 9 until the entire body exits.
sudo -u $(shell_quote "${DEPLOY_USER}") -- \"\$@\""
  command="sudo bash -c $(shell_quote "${fence_body}") cympho-deploy-operation${quoted_args}"
  printf '%s\n' "${command}"
}

run_fenced_ssh() {
  local command
  require_deploy_lock
  command="$(operation_fence_command bash -s)"
  ssh "${SSH_OPTS[@]}" "${DEPLOY_TARGET}" "${command}"
}

run_fenced_ssh_nonfatal() {
  local command
  if [[ -z "${DEPLOY_LOCK_PID}" ]] || ! kill -0 "${DEPLOY_LOCK_PID}" 2>/dev/null; then
    echo "Remote deploy admission holder exited during cleanup." >&2
    return 1
  fi
  command="$(operation_fence_command bash -s)"
  ssh "${SSH_OPTS[@]}" "${DEPLOY_TARGET}" "${command}"
}

require_deploy_lock() {
  if [[ -n "${DEPLOY_LOCK_PID}" ]] && ! kill -0 "${DEPLOY_LOCK_PID}" 2>/dev/null; then
    echo "Remote deploy lock holder exited; refusing to continue unlocked." >&2
    exit 1
  fi
}

# Run a bash script on the host with `set -euo pipefail`. The deploy user has
# passwordless sudo, so `_sudo` is plain sudo (kept as a helper so the remote
# script bodies stay unchanged).
run_remote_script() {
  local body
  body="$(cat)"
  {
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' '_sudo() { sudo "$@"; }'
    printf '%s\n' "${body}"
  } | run_fenced_ssh
}

run_remote_script_nonfatal() {
  local body
  body="$(cat)"
  {
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' '_sudo() { sudo "$@"; }'
    printf '%s\n' "${body}"
  } | run_fenced_ssh_nonfatal
}

validate_managed_paths() {
  run_remote_script <<EOF
validate_managed_directory_path() {
  local path label nearest parent canonical
  path="\$1"; label="\$2"
  if _sudo test -L "\$path" || { _sudo test -e "\$path" && ! _sudo test -d "\$path"; }; then
    echo "\$label is not a canonical directory: \$path" >&2
    return 1
  fi
  nearest="\$path"
  while ! _sudo test -e "\$nearest"; do
    parent=\$(dirname -- "\$nearest")
    [ "\$parent" != "\$nearest" ] || break
    nearest="\$parent"
  done
  _sudo test -d "\$nearest"
  canonical=\$(_sudo readlink -f -- "\$nearest")
  [ "\$canonical" = "\$nearest" ] || {
    echo "\$label has a symlinked ancestor: \$nearest" >&2
    return 1
  }
  if _sudo test -e "\$path"; then
    canonical=\$(_sudo readlink -f -- "\$path")
    [ "\$canonical" = "\$path" ] || {
      echo "\$label is not canonical: \$path" >&2
      return 1
    }
  fi
}

validate_root_owned_ancestor_chain() {
  local path label nearest parent component owner unsafe
  path="\$1"; label="\$2"
  nearest="\$path"
  while ! _sudo test -e "\$nearest"; do
    parent=\$(dirname -- "\$nearest")
    [ "\$parent" != "\$nearest" ] || break
    nearest="\$parent"
  done
  component="\$nearest"
  while :; do
    _sudo test ! -L "\$component"
    _sudo test -d "\$component"
    owner=\$(_sudo stat -c %u -- "\$component")
    unsafe=\$(_sudo find "\$component" -maxdepth 0 \\( ! -user root -o -perm /022 \\) -print -quit)
    if [ "\$owner" != 0 ] || [ -n "\$unsafe" ]; then
      echo "\$label has a non-root-owned or writable privileged ancestor: \$component" >&2
      return 1
    fi
    [ "\$component" != / ] || break
    component=\$(dirname -- "\$component")
  done
}

validate_managed_file_path() {
  local path label parent
  path="\$1"; label="\$2"; parent=\$(dirname -- "\$path")
  validate_managed_directory_path "\$parent" "\$label parent"
  if _sudo test -L "\$path" || { _sudo test -e "\$path" && ! _sudo test -f "\$path"; }; then
    echo "\$label is not a regular non-symlink file: \$path" >&2
    return 1
  fi
}

validate_managed_directory_path '${DEPLOY_ROOT}' DEPLOY_ROOT
validate_managed_directory_path '${SOURCES_DIR}' sources
validate_managed_directory_path '${SOURCE_DIR}' source
validate_managed_directory_path '${RELEASES_DIR}' releases
validate_managed_directory_path '${DEPLOY_ROOT}/data' data
validate_managed_directory_path '${UPLOADS_DIR}' uploads
validate_managed_directory_path '${IMPORT_SPOOL_DIR}' import-spool
validate_managed_directory_path '${DEPLOY_ROOT}/claude-home' claude-home
validate_managed_directory_path '${DEPLOY_ROOT}/bin' bin
validate_managed_directory_path '${DEPLOY_ROOT}/env-snapshots' env-snapshots
validate_managed_directory_path '${DEPLOY_ROOT}/unit-snapshots' unit-snapshots
validate_managed_file_path '${ENV_FILE}' runtime-env
validate_managed_file_path '${DB_ENV_FILE}' database-env
validate_root_owned_ancestor_chain '${DEPLOY_ROOT}' DEPLOY_ROOT
validate_root_owned_ancestor_chain '${SOURCES_DIR}' sources
validate_root_owned_ancestor_chain '${SOURCES_DIR}' source-parent
validate_root_owned_ancestor_chain '${RELEASES_DIR}' releases
validate_root_owned_ancestor_chain '${DEPLOY_ROOT}/data' data-parent
validate_root_owned_ancestor_chain '${DEPLOY_ROOT}/bin' bin
validate_root_owned_ancestor_chain '${DEPLOY_ROOT}/env-snapshots' env-snapshots
validate_root_owned_ancestor_chain '${DEPLOY_ROOT}/unit-snapshots' unit-snapshots
validate_root_owned_ancestor_chain "\$(dirname -- '${ENV_FILE}')" runtime-env-parent
validate_root_owned_ancestor_chain "\$(dirname -- '${DB_ENV_FILE}')" database-env-parent
EOF
}

validate_deploy_service_account() {
  run_remote_script <<EOF
if ! id -u ${APP_USER} >/dev/null 2>&1; then
  _sudo useradd --system --create-home --shell /usr/sbin/nologin --user-group ${APP_USER}
fi
uid=\$(id -u ${APP_USER})
gid=\$(id -g ${APP_USER})
deploy_uid=\$(id -u ${DEPLOY_USER})
group_entry=\$(getent group ${APP_USER})
group_gid=\$(printf '%s\n' "\$group_entry" | awk -F: 'NF >= 3 { print \$3; exit }')
group_members=\$(printf '%s\n' "\$group_entry" | awk -F: 'NF >= 4 { print \$4; exit }')
[ "\$uid" != 0 ] && [ "\$gid" != 0 ] || {
  echo "Application service account must have nonzero UID and GID." >&2
  exit 1
}
[ "\$uid" != "\$deploy_uid" ] || {
  echo "Application service account UID must differ from the deploy operator UID." >&2
  exit 1
}
[ "\$group_gid" = "\$gid" ] || {
  echo "Application service account must use its dedicated primary group." >&2
  exit 1
}
[ -z "\$group_members" ] || {
  echo "Application service group must not have named members." >&2
  exit 1
}
passwd_entries=\$(getent passwd) || {
  echo "Could not verify application service group membership." >&2
  exit 1
}
group_alias=\$(getent group 2>/dev/null || true)
group_alias=\$(printf '%s\n' "\$group_alias" | awk -F: \\
  -v gid="\$group_gid" -v service_group="${APP_USER}" \\
  '\$3 == gid && \$1 != service_group { print \$1; exit }')
[ -z "\$group_alias" ] || {
  echo "Application service group GID must not have another group alias." >&2
  exit 1
}
shared_uid_account=\$(printf '%s\n' "\$passwd_entries" | awk -F: \\
  -v uid="\$uid" -v service_user="${APP_USER}" \\
  '\$3 == uid && \$1 != service_user { print \$1; exit }')
[ -z "\$shared_uid_account" ] || {
  echo "Application service account UID must not be shared by another username." >&2
  exit 1
}
shared_primary_account=\$(printf '%s\n' "\$passwd_entries" | awk -F: \
  -v gid="\$group_gid" -v service_user="${APP_USER}" \
  '\$4 == gid && \$1 != service_user { print \$1; exit }')
[ -z "\$shared_primary_account" ] || {
  echo "Application service group must not be shared by another account." >&2
  exit 1
}
groups=\$(id -G ${APP_USER})
for group_id in \$groups; do
  [ "\$group_id" = "\$gid" ] || {
    echo "Application service account must not have supplementary groups." >&2
    exit 1
  }
done
EOF
}

cleanup_remote_source_dir() {
  run_remote_script_nonfatal <<EOF
source=${SOURCE_DIR}
parent=${SOURCES_DIR}
base=\${source##*/}
[ "\$(_sudo readlink -f -- "\$parent")" = "\$parent" ]
[ "\$(_sudo readlink -f -- "\$source")" = "\$source" ]
case "\$source" in "\$parent"/*) ;; *) exit 1 ;; esac
[[ "\$base" =~ ^${BUILD_REVISION:0:12}-[0-9a-f]{8}\$ ]]
_sudo rm -rf -- "\$source"
EOF
}

# The long-lived SSH process normally owns the deploy flock. If that process
# dies, EXIT cleanup gets one bounded chance to reacquire the same remote lock
# and restore the unit snapshot. The current-link CAS prevents an old cleanup
# from overwriting a newer deploy that acquired the lock first.
run_remote_script_with_current_link_cas() {
  local body
  body="$(cat)"
  # The old run_ssh_nonfatal path is intentionally replaced by this
  # operation-fenced equivalent; it still returns admission loss to recovery.
  {
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' '_sudo() { sudo "$@"; }'
    cat <<EOF
previous_release='${PREVIOUS_RELEASE}'
deploy_release='${RELEASE_DIR}'
if [ -L '${CURRENT_LINK}' ]; then
  observed_current="\$(readlink -- '${CURRENT_LINK}')"
elif [ -e '${CURRENT_LINK}' ]; then
  echo "current release changed before cleanup recovery" >&2
  exit 76
else
  observed_current=""
fi
if [ "\$observed_current" != "\$previous_release" ] &&
   { [ -z "\$deploy_release" ] || [ "\$observed_current" != "\$deploy_release" ]; }; then
  echo "current release changed before cleanup recovery" >&2
  exit 76
fi
EOF
    printf '%s\n' "${body}"
  } | run_fenced_ssh_nonfatal
}

atomic_current_link() {
  local expected_target="$1"
  local new_target="$2"
  local link_tmp="${CURRENT_LINK}.cympho-${DEPLOY_NONCE}.tmp"

  run_remote_script <<EOF
observed=\$(if [ -L '${CURRENT_LINK}' ]; then readlink -- '${CURRENT_LINK}'; elif [ -e '${CURRENT_LINK}' ]; then printf INVALID; fi)
[ "\$observed" = '${expected_target}' ]
_sudo test ! -e '${link_tmp}'
_sudo test ! -L '${link_tmp}'
_sudo ln -s '${new_target}' '${link_tmp}'
_sudo mv -fT -- '${link_tmp}' '${CURRENT_LINK}'
EOF
}

snapshot_runtime_env() {
  run_remote_script <<EOF
snapshot=${ENV_SNAPSHOT_DIR}
snapshot_parent=${DEPLOY_ROOT}/env-snapshots
if [ -n '${PREVIOUS_RELEASE}' ] &&
   { _sudo test -L '${ENV_FILE}' || ! _sudo test -f '${ENV_FILE}'; }; then
  echo "Refusing to regenerate secrets when a current release exists." >&2
  exit 1
fi
for path in '${ENV_FILE}' '${DB_ENV_FILE}'; do
  if _sudo test -L "\$path"; then
    echo "Refusing a symlinked runtime environment file \$path." >&2
    exit 1
  elif _sudo test -e "\$path" && ! _sudo test -f "\$path"; then
    echo "Runtime environment path is not a regular file: \$path." >&2
    exit 1
  fi
done
if _sudo test -L "\$snapshot_parent"; then
  echo "Refusing a symlinked runtime-environment snapshot directory." >&2
  exit 1
fi
_sudo install -d -m 0700 -o root -g root "\$snapshot_parent"
[ "\$(_sudo readlink -f -- "\$snapshot_parent")" = "\$snapshot_parent" ] || {
  echo "Runtime-environment snapshot directory is not canonical." >&2
  exit 1
}
if _sudo test -e "\$snapshot" || _sudo test -L "\$snapshot"; then
  echo "Refusing to reuse an existing runtime-environment snapshot." >&2
  exit 1
fi
_sudo install -d -m 0700 -o root -g root "\$snapshot"
snapshot_complete=0
cleanup_incomplete_snapshot() {
  if [ "\$snapshot_complete" != 1 ]; then _sudo rm -rf -- "\$snapshot"; fi
}
trap cleanup_incomplete_snapshot EXIT
snapshot_file() {
  path="\$1"; key="\$2"
  if _sudo test -L "\$path"; then
    echo "Refusing a symlinked runtime environment file \$path." >&2
    return 1
  elif _sudo test -e "\$path"; then
    _sudo test -f "\$path" || return 1
    _sudo install -m 0600 -o root -g root "\$path" "\$snapshot/\$key"
    _sudo touch "\$snapshot/\$key.present"
    _sudo stat -c '%a %u %g' -- "\$path" | _sudo tee "\$snapshot/\$key.meta" >/dev/null
  fi
}
snapshot_file '${ENV_FILE}' env-file
snapshot_file '${DB_ENV_FILE}' db-env-file
snapshot_complete=1
trap - EXIT
EOF
  ENV_SNAPSHOT_ACTIVE=1
}

restore_runtime_env() {
  local recovery_mode="${1:-}"
  local remote_runner=run_remote_script

  [[ "${ENV_SNAPSHOT_ACTIVE}" == "1" ]] || return 0
  if [[ "${recovery_mode}" == "under-recovered-lock" || "${recovery_mode}" == "under-held-lock" ]]; then
    if [[ -n "${DEPLOY_LOCK_PID}" ]] && kill -0 "${DEPLOY_LOCK_PID}" 2>/dev/null; then
      remote_runner=run_remote_script_with_current_link_cas
    else
      echo "Recovered deploy lock was lost during environment restoration." >&2
      return 1
    fi
  elif [[ -z "${DEPLOY_LOCK_PID}" ]] || ! kill -0 "${DEPLOY_LOCK_PID}" 2>/dev/null; then
    echo "Cannot restore runtime environment after the remote deploy lock was lost." >&2
    return 1
  fi

  if "${remote_runner}" <<EOF
snapshot=${ENV_SNAPSHOT_DIR}
_sudo test ! -L "\$snapshot"
_sudo test -d "\$snapshot"
if ! _sudo test -f "\$snapshot/complete"; then
  # Candidate bytes are recorded before either live file is replaced.
  _sudo rm -rf -- "\$snapshot"
  exit 0
fi
restore_file() {
  path="\$1"; key="\$2"
  prior="\$snapshot/\$key"
  after="\$snapshot/\$key.after"
  marker="\$snapshot/\$key.present"
  published="\$snapshot/\$key.published"
  if ! _sudo test ! -L "\$published"; then
    echo "Refusing symlinked runtime environment publication marker \$published." >&2
    return 1
  fi
  if ! _sudo test -f "\$published"; then
    if _sudo test -f "\$marker"; then
      matches_file_state "\$path" "\$prior" "\$snapshot/\$key.meta" || {
        echo "Refusing to restore runtime environment file \$path without publication evidence." >&2
        return 1
      }
    else
      _sudo test ! -e "\$path" && _sudo test ! -L "\$path" || {
        echo "Refusing to restore externally created runtime environment file \$path without publication evidence." >&2
        return 1
      }
    fi
    return 0
  fi
  if _sudo test -f "\$marker"; then
    matches_file_state "\$path" "\$prior" "\$snapshot/\$key.meta" ||
      matches_file_state "\$path" "\$after" "\$snapshot/\$key.after.meta" || {
      echo "Refusing to overwrite externally changed runtime environment file \$path." >&2
      return 1
    }
    meta=\$(_sudo cat "\$snapshot/\$key.meta")
    read -r mode uid gid <<<"\$meta"
    tmp="\$path.cympho-env-rollback-${DEPLOY_NONCE}.tmp"
    _sudo test ! -e "\$tmp"
    _sudo test ! -L "\$tmp"
    _sudo install -m "\$mode" -o "\$uid" -g "\$gid" "\$prior" "\$tmp"
    _sudo mv -fT -- "\$tmp" "\$path"
  elif _sudo test -f "\$snapshot/\$key.after-absent"; then
    _sudo test ! -e "\$path" && _sudo test ! -L "\$path" || {
      echo "Refusing to overwrite externally created runtime environment file \$path." >&2
      return 1
    }
  elif _sudo test -e "\$path" || _sudo test -L "\$path"; then
    matches_file_state "\$path" "\$after" "\$snapshot/\$key.after.meta" || {
      echo "Refusing to remove externally changed runtime environment file \$path." >&2
      return 1
    }
    _sudo rm -f -- "\$path"
  fi
}
matches_file_state() {
  local path expected expected_meta_file live_meta expected_meta
  path="\$1"; expected="\$2"; expected_meta_file="\$3"
  _sudo test ! -L "\$path" && _sudo test -f "\$path" || return 1
  _sudo test ! -L "\$expected" && _sudo test -f "\$expected" || return 1
  _sudo test ! -L "\$expected_meta_file" && _sudo test -f "\$expected_meta_file" || return 1
  _sudo cmp -s "\$path" "\$expected" || return 1
  live_meta=\$(_sudo stat -c '%a %u %g' -- "\$path")
  expected_meta=\$(_sudo cat "\$expected_meta_file")
  [ "\$live_meta" = "\$expected_meta" ]
}
validate_file() {
  path="\$1"; key="\$2"
  prior="\$snapshot/\$key"
  after="\$snapshot/\$key.after"
  marker="\$snapshot/\$key.present"
  published="\$snapshot/\$key.published"
  _sudo test ! -L "\$published" || {
    echo "Refusing symlinked runtime environment publication marker \$published." >&2
    return 1
  }
  if ! _sudo test -f "\$published"; then
    if _sudo test -f "\$marker"; then
      matches_file_state "\$path" "\$prior" "\$snapshot/\$key.meta" || return 1
    else
      _sudo test ! -e "\$path" && _sudo test ! -L "\$path" || return 1
    fi
    return 0
  fi
  if _sudo test -f "\$marker"; then
    matches_file_state "\$path" "\$prior" "\$snapshot/\$key.meta" ||
      matches_file_state "\$path" "\$after" "\$snapshot/\$key.after.meta" || {
      echo "Refusing to overwrite externally changed runtime environment file \$path." >&2
      return 1
    }
  elif _sudo test -f "\$snapshot/\$key.after-absent"; then
    _sudo test ! -e "\$path" && _sudo test ! -L "\$path" || {
      echo "Refusing to remove externally changed runtime environment file \$path." >&2
      return 1
    }
  elif _sudo test -f "\$after"; then
    if _sudo test -e "\$path" || _sudo test -L "\$path"; then
      matches_file_state "\$path" "\$after" "\$snapshot/\$key.after.meta" || {
        echo "Refusing to remove externally changed runtime environment file \$path." >&2
        return 1
      }
    fi
  fi
}
validate_file '${ENV_FILE}' env-file
validate_file '${DB_ENV_FILE}' db-env-file
restore_file '${ENV_FILE}' env-file
restore_file '${DB_ENV_FILE}' db-env-file
_sudo rm -rf -- "\$snapshot"
EOF
  then
    ENV_SNAPSHOT_ACTIVE=0
    return 0
  fi
  ENV_SNAPSHOT_CLEANUP_DEBT=1
  return 1
}

commit_runtime_env() {
  local force="${1:-}"
  [[ "${ENV_SNAPSHOT_ACTIVE}" == "1" || "${force}" == force ]] || return 0
  ENV_SNAPSHOT_ACTIVE=0
  if ! run_remote_script_nonfatal <<EOF
_sudo rm -rf -- '${ENV_SNAPSHOT_DIR}'
EOF
  then
    ENV_SNAPSHOT_CLEANUP_DEBT=1
    echo "WARNING: deployment committed but runtime-environment snapshot cleanup failed." >&2
  fi
}

snapshot_systemd_units() {
  run_remote_script <<EOF
snapshot=${UNIT_SNAPSHOT_DIR}
snapshot_parent=${DEPLOY_ROOT}/unit-snapshots
if _sudo test -L "\$snapshot_parent"; then
  echo "Refusing a symlinked systemd-unit snapshot directory." >&2
  exit 1
fi
_sudo install -d -m 0700 -o root -g root "\$snapshot_parent"
[ "\$(_sudo readlink -f -- "\$snapshot_parent")" = "\$snapshot_parent" ] || {
  echo "Systemd-unit snapshot directory is not canonical." >&2
  exit 1
}
if _sudo test -e "\$snapshot" || _sudo test -L "\$snapshot"; then
  echo "Refusing to reuse an existing systemd-unit snapshot." >&2
  exit 1
fi
_sudo install -d -m 0700 -o root -g root "\$snapshot"
snapshot_complete=0
cleanup_incomplete_snapshot() {
  if [ "\$snapshot_complete" != 1 ]; then _sudo rm -rf -- "\$snapshot"; fi
}
trap cleanup_incomplete_snapshot EXIT

main_enabled_state=\$(_sudo systemctl is-enabled ${SERVICE_NAME} 2>/dev/null || true)
if [ -z "\$main_enabled_state" ]; then main_enabled_state=not-found; fi
case "\$main_enabled_state" in
  enabled|disabled|not-found) ;;
  *)
    echo "Unexpected enablement state for ${SERVICE_NAME}: \$main_enabled_state" >&2
    exit 1
    ;;
esac
main_live=/etc/systemd/system/${SERVICE_NAME}.service
if [ "\$main_enabled_state" = not-found ]; then
  _sudo test ! -e "\$main_live" || {
    echo "Enablement state does not match the installed main unit." >&2
    exit 1
  }
elif _sudo test ! -f "\$main_live"; then
  echo "Enablement state does not match the installed main unit." >&2
  exit 1
fi
_sudo tee "\$snapshot/main-unit.enabled" >/dev/null <<<"\$main_enabled_state"
_sudo chmod 0600 "\$snapshot/main-unit.enabled"
main_active_state=\$(_sudo systemctl is-active ${SERVICE_NAME} 2>/dev/null || true)
case "\$main_active_state" in
  active|inactive) ;;
  *) echo "Unexpected active state for ${SERVICE_NAME}: \$main_active_state" >&2; exit 1 ;;
esac
if [ "\$main_enabled_state" = not-found ] && [ "\$main_active_state" = active ]; then
  echo "Active state does not match an absent main unit." >&2
  exit 1
fi
_sudo tee "\$snapshot/main-unit.active" >/dev/null <<<"\$main_active_state"
_sudo chmod 0600 "\$snapshot/main-unit.active"

for unit in ${SERVICE_NAME}.service cympho-git-agent.service; do
  live="/etc/systemd/system/\$unit"
  if _sudo test -L "\$live"; then
    echo "Refusing to snapshot symlinked systemd unit \$live." >&2
    exit 1
  elif _sudo test -e "\$live"; then
    _sudo test -f "\$live" || {
      echo "Expected \$live to be a regular file." >&2
      exit 1
    }
    _sudo install -m 0600 -o root -g root "\$live" "\$snapshot/\$unit"
    _sudo touch "\$snapshot/\$unit.present"
    _sudo stat -c '%a %u %g' -- "\$live" | _sudo tee "\$snapshot/\$unit.meta" >/dev/null
  fi
done

snapshot_complete=1
trap - EXIT
EOF
  UNIT_SNAPSHOT_ACTIVE=1
}

restore_systemd_units() {
  local recovery_mode="${1:-}"
  local remote_runner=run_remote_script

  [[ "${UNIT_SNAPSHOT_ACTIVE}" == "1" ]] || return 0
  if [[ "${recovery_mode}" == "under-recovered-lock" || "${recovery_mode}" == "under-held-lock" ]]; then
    if [[ -n "${DEPLOY_LOCK_PID}" ]] && kill -0 "${DEPLOY_LOCK_PID}" 2>/dev/null; then
      remote_runner=run_remote_script_with_current_link_cas
    else
      echo "Recovered deploy lock was lost during systemd restoration." >&2
      return 1
    fi
  elif [[ -z "${DEPLOY_LOCK_PID}" ]] || ! kill -0 "${DEPLOY_LOCK_PID}" 2>/dev/null; then
    echo "Cannot restore systemd units after the remote deploy lock was lost." >&2
    return 1
  fi

  if "${remote_runner}" <<EOF
snapshot=${UNIT_SNAPSHOT_DIR}
_sudo test ! -L "\$snapshot"
_sudo test -d "\$snapshot"
_sudo test "\$(_sudo stat -c %u -- "\$snapshot")" = 0
_sudo test ! -L "\$snapshot/main-unit.enabled"
_sudo test -f "\$snapshot/main-unit.enabled"
_sudo test ! -L "\$snapshot/main-unit.active"
_sudo test -f "\$snapshot/main-unit.active"
main_enabled_state=\$(_sudo cat "\$snapshot/main-unit.enabled")
main_active_state=\$(_sudo cat "\$snapshot/main-unit.active")
case "\$main_enabled_state" in
  enabled|disabled|not-found) ;;
  *) echo "Invalid saved enablement state for ${SERVICE_NAME}." >&2; exit 1 ;;
esac
case "\$main_active_state" in
  active|inactive) ;;
  *) echo "Invalid saved active state for ${SERVICE_NAME}." >&2; exit 1 ;;
esac
enable_attempted="\$snapshot/main-unit.enable-attempted"
expected_enabled="\$snapshot/main-unit.expected-enabled"
_sudo test ! -L "\$enable_attempted"
_sudo test ! -L "\$expected_enabled"
if _sudo test -e "\$expected_enabled" && ! _sudo test -f "\$enable_attempted"; then
  echo "Enablement expectation exists without an activation attempt." >&2
  exit 1
fi
if _sudo test -f "\$expected_enabled"; then
  expected_marker_state=\$(_sudo cat "\$expected_enabled")
  case "\$expected_marker_state" in
    enabled|disabled|not-found|ambiguous) ;;
    *) echo "Invalid expected enablement marker." >&2; exit 1 ;;
  esac
fi

validate_restore_candidate() {
  unit="\$1"
  fresh="\$2"
  live="/etc/systemd/system/\$unit"
  prior="\$snapshot/\$unit"
  marker="\$snapshot/\$unit.present"

  _sudo test ! -L "\$fresh"
  _sudo test -f "\$fresh"
  # The source tree is intentionally read-only (typically mode 0444) before
  # activation; installation publishes units with this explicit metadata.
  fresh_meta="644 0 0"
  if _sudo test -f "\$marker"; then
    _sudo test ! -L "\$prior"
    _sudo test -f "\$prior"
    _sudo test ! -L "\$live"
    _sudo test -f "\$live"
    _sudo test ! -L "\$snapshot/\$unit.meta"
    _sudo test -f "\$snapshot/\$unit.meta"
    prior_meta=\$(_sudo cat "\$snapshot/\$unit.meta")
    [[ "\$prior_meta" =~ ^[0-7]{3,4}[[:space:]][0-9]+[[:space:]][0-9]+$ ]] || {
      echo "Invalid saved systemd unit metadata." >&2
      return 1
    }
    live_meta=\$(_sudo stat -c '%a %u %g' -- "\$live")
    { _sudo cmp -s "\$live" "\$prior" && [ "\$live_meta" = "\$prior_meta" ]; } ||
      { _sudo cmp -s "\$live" "\$fresh" && [ "\$live_meta" = "\$fresh_meta" ]; } || {
      echo "Refusing to overwrite externally changed systemd unit \$live." >&2
      return 1
    }
  elif _sudo test -e "\$live" || _sudo test -L "\$live"; then
    _sudo test ! -L "\$live"
    _sudo test -f "\$live"
    live_meta=\$(_sudo stat -c '%a %u %g' -- "\$live")
    _sudo cmp -s "\$live" "\$fresh" && [ "\$live_meta" = "\$fresh_meta" ] || {
      echo "Refusing to remove externally created systemd unit \$live." >&2
      return 1
    }
  fi
}

restore_unit() {
  unit="\$1"
  live="/etc/systemd/system/\$unit"
  prior="\$snapshot/\$unit"
  marker="\$snapshot/\$unit.present"
  tmp="\$live.cympho-rollback-${DEPLOY_NONCE}.tmp"
  if _sudo test -f "\$marker"; then
    prior_meta=\$(_sudo cat "\$snapshot/\$unit.meta")
    read -r prior_mode prior_uid prior_gid <<<"\$prior_meta"
    _sudo test ! -e "\$tmp"
    _sudo test ! -L "\$tmp"
    _sudo install -m "\$prior_mode" -o "\$prior_uid" -g "\$prior_gid" "\$prior" "\$tmp"
    _sudo mv -fT -- "\$tmp" "\$live"
  elif _sudo test -e "\$live"; then
    _sudo rm -f -- "\$live"
  fi
}

validate_restore_candidate ${SERVICE_NAME}.service ${SOURCE_DIR}/deploy/cympho.service
validate_restore_candidate cympho-git-agent.service ${SOURCE_DIR}/deploy/cympho-git-agent.service
main_live=/etc/systemd/system/${SERVICE_NAME}.service
current_enabled_state=\$(_sudo systemctl is-enabled ${SERVICE_NAME} 2>/dev/null || true)
if [ -z "\$current_enabled_state" ]; then current_enabled_state=not-found; fi
if [ "\$main_enabled_state" = not-found ] && _sudo test -f "\$main_live"; then
  pre_enable_state=disabled
else
  pre_enable_state=\$main_enabled_state
fi
if _sudo test -f "\$expected_enabled"; then
  expected_current_state=\$(_sudo cat "\$expected_enabled")
  case "\$expected_current_state" in
    enabled|disabled|not-found) ;;
    ambiguous|*) echo "Ambiguous enable operation outcome; refusing automatic rollback." >&2; exit 1 ;;
  esac
elif _sudo test -f "\$enable_attempted"; then
  case "\$current_enabled_state" in
    enabled|"\$pre_enable_state") expected_current_state=\$current_enabled_state ;;
    *) echo "Ambiguous enable operation outcome; refusing automatic rollback." >&2; exit 1 ;;
  esac
else
  expected_current_state=\$pre_enable_state
fi
if [ "\$current_enabled_state" != "\$expected_current_state" ] &&
   [ "\$current_enabled_state" != "\$main_enabled_state" ] &&
   { [ "\$main_enabled_state" != not-found ] || [ "\$current_enabled_state" != disabled ]; }; then
  echo "Unexpected current enablement state for ${SERVICE_NAME}; refusing automatic rollback." >&2
  exit 1
fi
if [ -n "${recovery_mode}" ] &&
   [ "\$observed_current" = "\$deploy_release" ]; then
  if [ -n "\$previous_release" ]; then
    rollback_link='${CURRENT_LINK}.cympho-recovery-${DEPLOY_NONCE}.tmp'
    _sudo test ! -e "\$rollback_link"
    _sudo test ! -L "\$rollback_link"
    _sudo ln -s "\$previous_release" "\$rollback_link"
    _sudo mv -fT -- "\$rollback_link" '${CURRENT_LINK}'
  else
    _sudo rm -f -- '${CURRENT_LINK}'
  fi
fi
if [ "\$current_enabled_state" = enabled ] && [ "\$main_enabled_state" != enabled ] && _sudo test -f "\$main_live"; then
  _sudo systemctl disable ${SERVICE_NAME} >/dev/null
fi
if [ -n "\$deploy_release" ] &&
   [ "\$main_enabled_state" = not-found ] && _sudo test -f "\$main_live"; then
  _sudo systemctl stop ${SERVICE_NAME}
fi
restore_unit ${SERVICE_NAME}.service
restore_unit cympho-git-agent.service
_sudo systemctl daemon-reload
if [ "\$main_enabled_state" = enabled ]; then
  _sudo systemctl enable ${SERVICE_NAME} >/dev/null
fi
if [ "\$main_active_state" = active ]; then
  _sudo systemctl restart ${SERVICE_NAME}
elif [ "\$main_enabled_state" != not-found ]; then
  _sudo systemctl stop ${SERVICE_NAME}
fi
_sudo rm -rf -- "\$snapshot"
EOF
  then
    UNIT_SNAPSHOT_ACTIVE=0
    return 0
  fi

  return 1
}

commit_systemd_units() {
  local force="${1:-}"
  [[ "${UNIT_SNAPSHOT_ACTIVE}" == "1" || "${force}" == force ]] || return 0
  UNIT_SNAPSHOT_ACTIVE=0
  if ! run_remote_script_nonfatal <<EOF
_sudo rm -rf -- '${UNIT_SNAPSHOT_DIR}'
EOF
  then
    UNIT_SNAPSHOT_CLEANUP_DEBT=1
    echo "WARNING: committed systemd-unit snapshot cleanup failed; preserve ${UNIT_SNAPSHOT_DIR} for operator cleanup." >&2
  fi
}

restore_transaction_after_lock_loss() {
  local recovery_output="${DEPLOY_CONTEXT}/recovery-lock.out"
  local recovery_pid
  # start_deploy_lock_holder recovery executes one bounded `flock --wait 20`
  # admission before either restore helper runs.
  DEPLOY_EPOCH="$(new_deploy_epoch)"
  start_deploy_lock_holder recovery CYMPHO_RECOVERY_LOCKED "${DEPLOY_EPOCH}" "${recovery_output}"
  recovery_pid="${STARTED_DEPLOY_LOCK_PID}"
  for _ in $(seq 1 850); do
    if grep -Fxq CYMPHO_RECOVERY_LOCKED "${recovery_output}"; then
      DEPLOY_LOCK_PID="${recovery_pid}"
      if [[ "${ENV_SNAPSHOT_ACTIVE}" == "1" ]] && ! restore_runtime_env under-recovered-lock; then return 1; fi
      if [[ "${UNIT_SNAPSHOT_ACTIVE}" == "1" ]] && ! restore_systemd_units under-recovered-lock; then return 1; fi
      return 0
    fi
    if ! kill -0 "${recovery_pid}" 2>/dev/null; then
      wait "${recovery_pid}" 2>/dev/null || true
      cat "${recovery_output}" >&2
      return 1
    fi
    sleep 0.1
  done
  kill "${recovery_pid}" 2>/dev/null || true
  wait "${recovery_pid}" 2>/dev/null || true
  echo "Timed out waiting for bounded deploy recovery lock." >&2
  return 1
}

public_readiness_matches() {
  local body_path="${DEPLOY_CONTEXT}/public-readiness.json"
  local canonical_path="${DEPLOY_CONTEXT}/public-readiness-canonical.json"
  local metadata http_status content_type curl_status

  require_deploy_lock
  set +e
  metadata="$(
    curl --disable --silent --request GET --proto '=https' \
      --connect-timeout 5 --max-time 15 --max-redirs 0 --max-filesize 65536 \
      --noproxy '*' \
      --header 'Accept: application/json' --output "${body_path}" \
      --write-out $'%{http_code}\n%{content_type}' \
      "${PUBLIC_READINESS_URL}" 2>/dev/null
  )"
  curl_status=$?
  set -e
  if ((curl_status != 0)); then return 1; fi

  http_status="${metadata%%$'\n'*}"
  content_type=""
  if [[ "${metadata}" == *$'\n'* ]]; then content_type="${metadata#*$'\n'}"; fi
  [[ "${http_status}" == "200" ]] || return 1
  [[ "${content_type}" =~ ^[Aa][Pp][Pp][Ll][Ii][Cc][Aa][Tt][Ii][Oo][Nn]/[Jj][Ss][Oo][Nn]([[:space:]]*\;.*)?$ ]] || return 1

  rm -f -- "${canonical_path}"
  python3 "${DEPLOY_CONTEXT}/bin/cympho-health-validator" health \
    "${body_path}" "${canonical_path}" "${BUILD_REVISION}"
}

# Acquire the session/admission lock, briefly acquire the permanent operation
# lock to publish a fresh epoch, then release operation before ACK. The SSH
# process remains alive (and owns only the session lock) until the deploy ends.
start_deploy_lock_holder() {
  local mode="${1:?lock-holder mode required}"
  local lock_ack="${2:?lock-holder ACK required}"
  local epoch="${3:?lock-holder epoch required}"
  local output="${4:?lock-holder output path required}"
  local lock_args="--nonblock"

  if [[ "${mode}" == "recovery" ]]; then
    lock_args="--wait 20"
  elif [[ "${mode}" != "admission" ]]; then
    echo "invalid deploy lock-holder mode: ${mode}" >&2
    return 1
  fi

  : >"${output}"
  ssh "${SSH_OPTS[@]}" "${DEPLOY_TARGET}" \
    "sudo flock ${lock_args} --conflict-exit-code 75 '${DEPLOY_SESSION_LOCK}' bash -s" \
    >"${output}" 2>&1 <<EOF &
set -euo pipefail
session_lock='${DEPLOY_SESSION_LOCK}'
operation_lock='${DEPLOY_OPERATION_LOCK}'
epoch_file='${DEPLOY_EPOCH_FILE}'
expected_epoch='${epoch}'
test ! -L "\$session_lock" && test -f "\$session_lock" || {
  echo "invalid deploy session lock" >&2
  exit 76
}
[ "\$(stat -c %u -- "\$session_lock")" = 0 ] || {
  echo "deploy session lock is not root-owned" >&2
  exit 76
}
chmod 0600 "\$session_lock"
[ "\$(stat -c %a -- "\$session_lock")" = 600 ] || {
  echo "deploy session lock has unsafe permissions" >&2
  exit 76
}
if ! test ! -L "\$operation_lock" || { test -e "\$operation_lock" && ! test -f "\$operation_lock"; }; then
  echo "invalid deploy operation lock" >&2
  exit 76
fi
if [ ! -e "\$operation_lock" ]; then
  install -m 0600 -o root -g root /dev/null "\$operation_lock"
fi
[ "\$(stat -c %u -- "\$operation_lock")" = 0 ] || {
  echo "deploy operation lock is not root-owned" >&2
  exit 76
}
chmod 0600 "\$operation_lock"
if ! test ! -L "\$epoch_file" || { test -e "\$epoch_file" && ! test -f "\$epoch_file"; }; then
  echo "invalid deploy epoch file" >&2
  exit 76
fi
exec 9>>"\$operation_lock"
flock --exclusive --wait 60 9
epoch_tmp="\$epoch_file.cympho-\$expected_epoch.tmp"
[ ! -e "\$epoch_tmp" ] && [ ! -L "\$epoch_tmp" ]
umask 077
printf '%s\\n' "\$expected_epoch" >"\$epoch_tmp"
chown root:root "\$epoch_tmp"
chmod 0644 "\$epoch_tmp"
sync -f "\$epoch_tmp"
mv -fT -- "\$epoch_tmp" "\$epoch_file"
test ! -L "\$epoch_file" && test -f "\$epoch_file"
[ "\$(stat -c %u -- "\$epoch_file")" = 0 ]
[ "\$(stat -c %a -- "\$epoch_file")" = 644 ]
sync -d "\$(dirname -- "\$epoch_file")"
flock --unlock 9
lock_ack='${lock_ack}'
printf '%s\\n' "\$lock_ack"
exec sleep infinity
EOF
  STARTED_DEPLOY_LOCK_PID=$!
}


acquire_deploy_lock() {
  start_deploy_lock_holder admission CYMPHO_DEPLOY_LOCKED "${DEPLOY_EPOCH}" "${DEPLOY_LOCK_OUTPUT}"
  DEPLOY_LOCK_PID="${STARTED_DEPLOY_LOCK_PID}"

  for _ in $(seq 1 650); do
    if grep -Fxq 'CYMPHO_DEPLOY_LOCKED' "${DEPLOY_LOCK_OUTPUT}"; then
      (
        while kill -0 "${DEPLOY_LOCK_PID}" 2>/dev/null; do sleep 0.2; done
        kill -TERM "${DEPLOY_MAIN_PID}" 2>/dev/null || true
      ) &
      DEPLOY_LOCK_MONITOR_PID=$!
      return 0
    fi
    if ! kill -0 "${DEPLOY_LOCK_PID}" 2>/dev/null; then
      wait "${DEPLOY_LOCK_PID}" 2>/dev/null || true
      echo "Refusing concurrent deploy: the host deploy lock is held or unavailable." >&2
      cat "${DEPLOY_LOCK_OUTPUT}" >&2
      return 1
    fi
    sleep 0.1
  done

  echo "Timed out acquiring the host deploy lock." >&2
  return 1
}


step() { echo; echo "==> $*"; }

# ---------------------------------------------------------------------------

echo "Deploy target: ${DEPLOY_TARGET}"
echo "Domain:        ${DOMAIN}"
echo "Deploy root:   ${DEPLOY_ROOT}"

run_ssh "command -v flock >/dev/null 2>&1" || {
  echo "Remote host requires flock for serialized deploys." >&2
  exit 1
}
acquire_deploy_lock

if [[ "${SKIP_TESTS}" != "1" ]]; then
  step "Running local tests"
  ( cd "${REPO_DIR}" && mix test ) || { echo "Local tests failed. Aborting." >&2; exit 1; }
fi

step "Validating managed deployment paths"
validate_managed_paths
step "Validating application service account"
validate_deploy_service_account

step "Bootstrapping host (user, directories, systemd unit)"
run_remote_script <<EOF
command -v systemctl >/dev/null 2>&1 || { echo "systemd required" >&2; exit 1; }
command -v systemd-run >/dev/null 2>&1 || { echo "systemd-run required (migration runner)" >&2; exit 1; }
command -v bash >/dev/null 2>&1 || { echo "bash required (operator CLI)" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl required (readiness probe)" >&2; exit 1; }
# Docker is only used to build the release (deploy/build.Dockerfile pins
# Elixir 1.19.5 / OTP 28; the host's system Elixir is 1.18.4). Nothing runs in
# a container at runtime.
command -v docker >/dev/null 2>&1 || { echo "docker required (release builder)" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 required (operator readiness validator)" >&2; exit 1; }

_sudo install -d -m 0755 -o root -g root ${DEPLOY_ROOT}
_sudo install -d -m 0755 -o root -g root ${SOURCES_DIR}
_sudo install -d -m 0755 -o ${DEPLOY_USER} -g ${DEPLOY_USER} ${SOURCE_DIR}
_sudo install -d -m 0755 -o root -g root ${RELEASES_DIR}
_sudo install -d -m 0755 -o root -g root ${DEPLOY_ROOT}/data
_sudo install -d -m 0750 -o ${APP_USER} -g ${APP_USER} ${UPLOADS_DIR}
_sudo install -d -m 0700 -o ${APP_USER} -g ${APP_USER} ${IMPORT_SPOOL_DIR}
_sudo install -d -m 0700 -o ${APP_USER} -g ${APP_USER} ${DEPLOY_ROOT}/claude-home
if _sudo test -L ${DEPLOY_ROOT}/bin; then
  echo "Refusing to follow a symlink at ${DEPLOY_ROOT}/bin." >&2
  exit 1
fi
_sudo install -d -m 0755 -o root -g root ${DEPLOY_ROOT}/bin
if _sudo test -L ${DEPLOY_ROOT}/bin/claude; then
  echo "Refusing to follow a symlink at ${DEPLOY_ROOT}/bin/claude." >&2
  exit 1
elif _sudo test -e ${DEPLOY_ROOT}/bin/claude; then
  _sudo test -f ${DEPLOY_ROOT}/bin/claude || {
    echo "Expected ${DEPLOY_ROOT}/bin/claude to be a regular file." >&2
    exit 1
  }
  _sudo chown --no-dereference root:root ${DEPLOY_ROOT}/bin/claude
  _sudo chmod 0755 -- ${DEPLOY_ROOT}/bin/claude
fi
EOF

# Recheck the directories just created before rsync or any root-owned payload,
# environment, or snapshot bytes are written through them.
validate_managed_paths
SOURCE_DIR_SAFE=1

step "Syncing the exact Git tree ${SOURCE_REVISION} to ${SOURCE_DIR}"
require_deploy_lock
RSYNC_PATH="$(operation_fence_command rsync)"
rsync -az --delete -e "${RSYNC_RSH}" \
  --rsync-path="${RSYNC_PATH}" \
  "${DEPLOY_CONTEXT}/" "${DEPLOY_TARGET}:${SOURCE_DIR}/"
run_remote_script <<EOF
_sudo chown -R root:root ${SOURCE_DIR}
_sudo chmod -R a-w ${SOURCE_DIR}
EOF

# --- Preflight rollback attestation -----------------------------------------
# Resolve and validate the current release before publishing/reconciling the
# environment, mutating systemd units, checking Postgres, or building a
# replacement. An existing current release must remain a trustworthy rollback
# target through every later step.
PREVIOUS_RELEASE="$(
  run_ssh "if sudo test -L '${CURRENT_LINK}'; then sudo readlink -- '${CURRENT_LINK}'; elif sudo test -e '${CURRENT_LINK}'; then printf '%s' INVALID_CURRENT_LINK; fi"
)"
PREVIOUS_REVISION=""

if [[ -n "${PREVIOUS_RELEASE}" ]]; then
  if ! valid_release_path "${PREVIOUS_RELEASE}"; then
    echo "Current release link has an invalid or unsupported target; refusing deployment." >&2
    exit 1
  fi

  # Rollback payloads and their manifests must be outside service write
  # authority. App-owned legacy releases cannot provide durable identity and
  # require an explicit operator migration rather than automatic adoption.
  if ! run_remote_script <<EOF
target='${PREVIOUS_RELEASE}'
_sudo test "\$(_sudo readlink -- '${CURRENT_LINK}')" = "\$target"
_sudo test ! -L "\$target"
_sudo test -d "\$target"
_sudo test "\$(_sudo readlink -f -- "\$target")" = "\$target"
_sudo test -z "\$(_sudo find "\$target" -type l -print -quit)"
_sudo test -z "\$(_sudo find "\$target" \\( ! -user root -o -perm /022 \\) -print -quit)"
owner=\$(_sudo stat -c %u -- "\$target")
_sudo test "\$owner" = 0
_sudo test -z "\$(_sudo find "\$target" ! -user root -print -quit)"
_sudo test -z "\$(_sudo find "\$target" ! -group ${APP_USER} -print -quit)"
while IFS= read -r -d '' entry; do
  mode=\$(_sudo stat -c %a -- "\$entry")
  if _sudo test -d "\$entry"; then
    [ "\$mode" = 550 ] || {
      echo "Release directory is not sealed at mode 0550: \$entry" >&2
      exit 1
    }
  elif _sudo test -f "\$entry"; then
    case "\$mode" in
      440|550) ;;
      *) echo "Release file is not sealed at mode 0440 or 0550: \$entry" >&2; exit 1 ;;
    esac
  else
    echo "Release contains an unsupported entry type: \$entry" >&2
    exit 1
  fi
done < <(_sudo find "\$target" -print0)
EOF
  then
    echo "Current release target failed path or ownership validation; refusing deployment." >&2
    exit 1
  fi

  PREVIOUS_REVISION="$(
    run_ssh "sudo python3 '${SOURCE_DIR}/bin/cympho-health-validator' release-revision '${PREVIOUS_RELEASE}/release-info.json'" || true
  )"
  if [[ ! "${PREVIOUS_REVISION}" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
    PREVIOUS_REVISION=""
  fi
  if [[ -n "${PREVIOUS_REVISION}" ]]; then
    if ! run_ssh "sudo test ! -L '${ENV_FILE}' && sudo test -f '${ENV_FILE}'"; then
      echo "Current release requires a regular runtime environment file; refusing deployment." >&2
      exit 1
    fi
    PREVIOUS_COMPILED_REVISION="$(
      run_ssh "sudo systemd-run --wait --pipe --collect --quiet \\
        --unit=cympho-previous-identity-${DEPLOY_NONCE} \\
        --property=RuntimeMaxSec=30s \\
        --property=EnvironmentFile=${ENV_FILE} \\
        --working-directory=${PREVIOUS_RELEASE} \\
        --uid=${APP_USER} --gid=${APP_USER} \\
        ${PREVIOUS_RELEASE}/bin/${APP_NAME} eval 'IO.write(Cympho.BuildInfo.revision())'" || true
    )"
    if [[ "${PREVIOUS_COMPILED_REVISION}" != "${PREVIOUS_REVISION}" ]]; then
      echo "Current release compiled identity does not match its trusted manifest; refusing deployment." >&2
      exit 1
    fi
  fi
fi

# A current release is the only rollback target once migrations or cutover
# begin.  If its identity cannot be attested by the trusted validator above,
# fail closed now rather than creating an unrecoverable deployment state.
if [[ -n "${PREVIOUS_RELEASE}" && -z "${PREVIOUS_REVISION}" ]]; then
  echo "Current release has no valid trusted revision manifest; refusing deployment." >&2
  exit 1
fi

step "Snapshotting runtime environment"
snapshot_runtime_env

step "Ensuring secrets (${ENV_FILE}, ${DB_ENV_FILE}) and non-secret runtime paths"
run_remote_script <<EOF
snapshot=${ENV_SNAPSHOT_DIR}
env_candidate=\$(mktemp)
db_candidate=\$(mktemp)
db_exists=0
cleanup_candidates() { rm -f "\$env_candidate" "\$db_candidate"; }
trap cleanup_candidates EXIT
validate_live_snapshot() {
  path="\$1"; key="\$2"
  if _sudo test -f "\$snapshot/\$key.present"; then
    _sudo test ! -L "\$path" && _sudo test -f "\$path" || {
      echo "Refusing to overwrite externally changed runtime environment file \$path." >&2
      return 1
    }
    _sudo cmp -s "\$path" "\$snapshot/\$key" || {
      echo "Refusing to overwrite externally changed runtime environment file \$path." >&2
      return 1
    }
    live_meta=\$(_sudo stat -c '%a %u %g' -- "\$path")
    expected_meta=\$(_sudo cat "\$snapshot/\$key.meta")
    [ "\$live_meta" = "\$expected_meta" ] || {
      echo "Refusing to overwrite externally changed runtime environment file \$path." >&2
      return 1
    }
  else
    _sudo test ! -e "\$path" && _sudo test ! -L "\$path" || {
      echo "Refusing to overwrite externally created runtime environment file \$path." >&2
      return 1
    }
  fi
}
validate_live_snapshot '${ENV_FILE}' env-file
validate_live_snapshot '${DB_ENV_FILE}' db-env-file

if _sudo test -f ${ENV_FILE}; then
  _sudo awk \
    -v app_host='${DOMAIN}' -v preview_host='${PREVIEW_DOMAIN}' \
    -v port='${APP_PORT}' -v bind_ip='127.0.0.1' \
    -v uploads='${UPLOADS_DIR}' -v spool='${IMPORT_SPOOL_DIR}' \
    -v proxies='127.0.0.1,::1' '
    BEGIN {
      keys[1]="APP_HOST"; vals[1]=app_host
      keys[2]="PREVIEW_HOST"; vals[2]=preview_host
      keys[3]="PORT"; vals[3]=port
      keys[4]="HTTP_BIND_IP"; vals[4]=bind_ip
      keys[5]="CYMPHO_UPLOADS_DIR"; vals[5]=uploads
      keys[6]="CYMPHO_IMPORT_SPOOL_DIR"; vals[6]=spool
      keys[7]="CYMPHO_TRUSTED_PROXY_IPS"; vals[7]=proxies
    }
    {
      matched=0
      for (i=1; i<=7; i++) {
        if (index(\$0, keys[i] "=") == 1) {
          if (!seen[i]) print keys[i] "=" vals[i]
          seen[i]=1; matched=1; break
        }
      }
      if (!matched) print
    }
    END { for (i=1; i<=7; i++) if (!seen[i]) print keys[i] "=" vals[i] }
  ' ${ENV_FILE} > "\$env_candidate"
  if _sudo test -f ${DB_ENV_FILE}; then
    _sudo cat ${DB_ENV_FILE} > "\$db_candidate"
    db_exists=1
  fi
else
  DBPASS=\$(openssl rand -hex 24)
  SKB=\$(openssl rand -hex 64)
  ENC=\$(openssl rand -hex 16)
  UJWT=\$(openssl rand -hex 48)
  AJWT=\$(openssl rand -hex 48)
  LVSALT=\$(openssl rand -hex 16)
  db_exists=1
  cat > "\$db_candidate" <<DBENV
POSTGRES_USER=cympho
POSTGRES_PASSWORD=\${DBPASS}
POSTGRES_DB=cympho
DB_PUBLISH_PORT=${DB_PORT}
DBENV
  cat > "\$env_candidate" <<APPENV
APP_HOST=${DOMAIN}
PREVIEW_HOST=${PREVIEW_DOMAIN}
PORT=${APP_PORT}
HTTP_BIND_IP=127.0.0.1
CYMPHO_TRUSTED_PROXY_IPS=127.0.0.1,::1
CYMPHO_RESOURCE_PROFILE=balanced
CYMPHO_UPLOADS_DIR=${UPLOADS_DIR}
CYMPHO_IMPORT_SPOOL_DIR=${IMPORT_SPOOL_DIR}
DATABASE_URL=ecto://cympho:\${DBPASS}@127.0.0.1:${DB_PORT}/cympho
SECRET_KEY_BASE=\${SKB}
CYMPHO_ENCRYPTION_KEY=\${ENC}
CYMPHO_USER_JWT_SECRET=\${UJWT}
CYMPHO_AGENT_JWT_SECRET=\${AJWT}
LIVE_VIEW_SALT=\${LVSALT}
APPENV
fi

_sudo install -m 0640 -o root -g ${APP_USER} "\$env_candidate" "\$snapshot/env-file.after"
_sudo stat -c '%a %u %g' -- "\$snapshot/env-file.after" |
  _sudo tee "\$snapshot/env-file.after.meta" >/dev/null
if [ "\$db_exists" = 1 ]; then
  _sudo install -m 0600 -o ${DEPLOY_USER} -g ${DEPLOY_USER} "\$db_candidate" "\$snapshot/db-env-file.after"
  _sudo stat -c '%a %u %g' -- "\$snapshot/db-env-file.after" |
    _sudo tee "\$snapshot/db-env-file.after.meta" >/dev/null
else
  _sudo touch "\$snapshot/db-env-file.after-absent"
fi
_sudo touch "\$snapshot/complete"
env_publish=${ENV_FILE}.cympho-activate-${DEPLOY_NONCE}.tmp
validate_live_snapshot '${ENV_FILE}' env-file
_sudo test ! -e "\$env_publish"
_sudo test ! -L "\$env_publish"
_sudo install -m 0640 -o root -g ${APP_USER} "\$env_candidate" "\$env_publish"
validate_live_snapshot '${ENV_FILE}' env-file
_sudo mv -fT -- "\$env_publish" ${ENV_FILE}
_sudo test ! -e "\$snapshot/env-file.published"
_sudo test ! -L "\$snapshot/env-file.published"
_sudo touch "\$snapshot/env-file.published"
_sudo chmod 0600 "\$snapshot/env-file.published"
if [ "\$db_exists" = 1 ]; then
  db_publish=${DB_ENV_FILE}.cympho-activate-${DEPLOY_NONCE}.tmp
  validate_live_snapshot '${DB_ENV_FILE}' db-env-file
  _sudo test ! -e "\$db_publish"
  _sudo test ! -L "\$db_publish"
  _sudo install -m 0600 -o ${DEPLOY_USER} -g ${DEPLOY_USER} "\$db_candidate" "\$db_publish"
  validate_live_snapshot '${DB_ENV_FILE}' db-env-file
  _sudo mv -fT -- "\$db_publish" ${DB_ENV_FILE}
  _sudo test ! -e "\$snapshot/db-env-file.published"
  _sudo test ! -L "\$snapshot/db-env-file.published"
  _sudo touch "\$snapshot/db-env-file.published"
  _sudo chmod 0600 "\$snapshot/db-env-file.published"
fi
EOF

step "Snapshotting installed systemd units"
snapshot_systemd_units

step "Installing systemd units"
run_remote_script <<EOF
unit_src=${SOURCE_DIR}/deploy/cympho.service
unit_dst=/etc/systemd/system/${SERVICE_NAME}.service
git_agent_src=${SOURCE_DIR}/deploy/cympho-git-agent.service
git_agent_dst=/etc/systemd/system/cympho-git-agent.service
units_changed=0
install_unit() {
  src="\$1"
  dst="\$2"
  tmp="\$dst.cympho-activate-${DEPLOY_NONCE}.tmp"
  _sudo install -m 0644 -o root -g root "\$src" "\$tmp"
  _sudo mv -fT -- "\$tmp" "\$dst"
}
unit_is_current() {
  src="\$1"
  dst="\$2"
  _sudo test ! -L "\$dst" || return 1
  _sudo test -f "\$dst" || return 1
  _sudo cmp -s "\$src" "\$dst" || return 1
  metadata=\$(_sudo stat -c '%a %u %g' -- "\$dst")
  [ "\$metadata" = "644 0 0" ]
}
_sudo systemd-analyze verify "\$unit_src" "\$git_agent_src"
if ! unit_is_current "\$unit_src" "\$unit_dst"; then
  install_unit "\$unit_src" "\$unit_dst"
  units_changed=1
fi
if ! unit_is_current "\$git_agent_src" "\$git_agent_dst"; then
  install_unit "\$git_agent_src" "\$git_agent_dst"
  units_changed=1
fi
if [ "\$units_changed" = "1" ]; then
  _sudo systemctl daemon-reload
fi
atomic_enable_marker() {
  marker="\$1"
  value="\$2"
  tmp="\$marker.cympho-${DEPLOY_NONCE}.tmp"
  _sudo test ! -e "\$tmp"
  _sudo test ! -L "\$tmp"
  printf '%s\\n' "\$value" | _sudo tee "\$tmp" >/dev/null
  _sudo chmod 0600 "\$tmp"
  _sudo sync -f "\$tmp"
  _sudo mv -fT -- "\$tmp" "\$marker"
  _sudo sync -d "\$(dirname -- "\$marker")"
}
atomic_enable_marker '${UNIT_SNAPSHOT_DIR}/main-unit.enable-attempted' attempted
set +e
_sudo systemctl enable ${SERVICE_NAME} >/dev/null
enable_status=\$?
set -e
enabled_after=\$(_sudo systemctl is-enabled ${SERVICE_NAME} 2>/dev/null || true)
if [ "\$enabled_after" = enabled ]; then
  atomic_enable_marker '${UNIT_SNAPSHOT_DIR}/main-unit.expected-enabled' enabled
elif [ "\$enabled_after" = disabled ] || [ "\$enabled_after" = not-found ]; then
  atomic_enable_marker '${UNIT_SNAPSHOT_DIR}/main-unit.expected-enabled' "\$enabled_after"
  echo "systemd enablement did not read back as enabled: \$enabled_after" >&2
  exit 1
else
  atomic_enable_marker '${UNIT_SNAPSHOT_DIR}/main-unit.expected-enabled' ambiguous
  echo "systemd enablement readback was ambiguous: \$enabled_after" >&2
  exit 1
fi
if [ "\$enable_status" != 0 ]; then
  echo "systemd enable command failed after state was recorded." >&2
  exit 1
fi
EOF

step "Verifying Postgres (native, ${DB_PORT})"
run_remote_script <<EOF
# Postgres runs natively under systemd — there is no container to start. We
# only assert the cluster is up and the app's database exists before building
# and cutting over, so a dead database fails the deploy early rather than
# after the release symlink has moved.
if ! _sudo -u postgres pg_isready -h 127.0.0.1 -p ${DB_PORT} -q; then
  echo "Postgres is not accepting connections on 127.0.0.1:${DB_PORT}." >&2
  echo "Start it with: sudo systemctl start postgresql" >&2
  exit 1
fi

if ! _sudo -u postgres psql -tAc "select 1 from pg_database where datname='cympho'" | grep -q 1; then
  echo "Database 'cympho' does not exist on 127.0.0.1:${DB_PORT}." >&2
  echo "On a fresh host, create the role and database once (password must match" >&2
  echo "POSTGRES_PASSWORD in ${DB_ENV_FILE} / DATABASE_URL in ${ENV_FILE}):" >&2
  echo "  sudo -u postgres psql -c \"CREATE ROLE cympho LOGIN PASSWORD '<pass>'\"" >&2
  echo "  sudo -u postgres psql -c 'CREATE DATABASE cympho OWNER cympho'" >&2
  exit 1
fi

echo "Postgres reachable, database present."
EOF

step "Building release via Docker (deps + assets + release; first run is slow)"
run_remote_script <<EOF
cd ${SOURCE_DIR}
image=${BUILD_IMAGE_TAG}
cid=""
cleanup_build() {
  if [ -n "\$cid" ]; then docker rm -f "\$cid" >/dev/null 2>&1 || true; fi
  docker image rm "\$image" >/dev/null 2>&1 || true
}
trap cleanup_build EXIT
docker build --build-arg CYMPHO_BUILD_REVISION=${BUILD_REVISION} -f deploy/build.Dockerfile -t "\$image" .
# docker cp extracts as root. Keep the exact source tree read-only and grant
# the deploy operator only this ignored artifact output directory.
_sudo rm -rf ${SOURCE_DIR}/_rel
_sudo install -d -m 0700 -o ${DEPLOY_USER} -g ${DEPLOY_USER} ${SOURCE_DIR}/_rel
cid=\$(docker create "\$image")
docker cp "\${cid}:/rel/." ${SOURCE_DIR}/_rel/
docker rm "\${cid}" >/dev/null
cid=""
symlink=\$(_sudo find ${SOURCE_DIR}/_rel -type l -print -quit)
[ -z "\$symlink" ] || { echo "release payload contains a forbidden symlink: \$symlink" >&2; exit 1; }
_sudo test ! -L ${SOURCE_DIR}/_rel/releases/COOKIE
_sudo test -f ${SOURCE_DIR}/_rel/releases/COOKIE
_sudo chown -R root:${APP_USER} ${SOURCE_DIR}/_rel
_sudo chmod -R u=rX,g=rX,o= ${SOURCE_DIR}/_rel
_sudo chmod 0440 ${SOURCE_DIR}/_rel/releases/COOKIE
_sudo test "\$(_sudo readlink -f -- ${SOURCE_DIR}/_rel)" = ${SOURCE_DIR}/_rel
_sudo test -z "\$(_sudo find ${SOURCE_DIR}/_rel \\( ! -user root -o -perm /022 \\) -print -quit)"
_sudo test -x ${SOURCE_DIR}/_rel/bin/${APP_NAME} || { echo "release binary missing" >&2; exit 1; }
_sudo test -x ${SOURCE_DIR}/_rel/bin/cymphoctl || { echo "operator CLI missing" >&2; exit 1; }
manifest_revision=\$(_sudo python3 '${SOURCE_DIR}/bin/cympho-health-validator' release-revision '${SOURCE_DIR}/_rel/release-info.json')
[ "\$manifest_revision" = "${BUILD_REVISION}" ] || {
  echo "trusted release manifest revision does not match the requested build revision" >&2
  exit 1
}
compiled_revision=\$(_sudo systemd-run --wait --pipe --collect --quiet \
  --unit=cympho-identity-${DEPLOY_NONCE} \
  --uid=${APP_USER} --gid=${APP_USER} \
  --property=RuntimeMaxSec=30s \
  --property=EnvironmentFile=${ENV_FILE} \
  --property=PrivateTmp=true \
  --working-directory=${SOURCE_DIR}/_rel \
  ${SOURCE_DIR}/_rel/bin/${APP_NAME} eval 'IO.write(Cympho.BuildInfo.revision())')
[ "\$compiled_revision" = "${BUILD_REVISION}" ] || {
  echo "compiled release identity does not match the requested build revision" >&2
  exit 1
}
[ "\$manifest_revision" = "\$compiled_revision" ] || {
  echo "manifest and compiled release identities disagree" >&2
  exit 1
}
echo "Release extracted."
EOF

# --- Activate ---------------------------------------------------------------
RELEASE_ID="$(date -u +%Y%m%d%H%M%S)-${BUILD_REVISION:0:12}-${DEPLOY_NONCE}"
RELEASE_DIR="${RELEASES_DIR}/${RELEASE_ID}"

rollback_release() {
  local rollback_ready=0
  local current_target=""
  local rollback_link_ok=0
  local unit_restore_ok=0
  local env_restore_ok=0
  local prior_active_state=""

  echo "ERROR: $1" >&2
  current_target="$(run_ssh "readlink -f '${CURRENT_LINK}' 2>/dev/null || true" || true)"

  if [[ -n "${PREVIOUS_RELEASE}" && "${PREVIOUS_RELEASE}" != "${RELEASE_DIR}" ]]; then
    prior_active_state="$(run_ssh "sudo cat '${UNIT_SNAPSHOT_DIR}/main-unit.active' 2>/dev/null || true" || true)"
    case "${prior_active_state}" in
      active|inactive) ;;
      *) echo "CRITICAL: saved prior service active state is unavailable or invalid." >&2; exit 1 ;;
    esac
    if [[ "${current_target}" == "${RELEASE_DIR}" ]]; then
      echo "Rolling back to ${PREVIOUS_RELEASE}" >&2
      rollback_link_ok=0
      unit_restore_ok=0
      env_restore_ok=0
      if restore_runtime_env; then
        env_restore_ok=1
      fi
      if [[ "${env_restore_ok}" == "1" ]] &&
         atomic_current_link "${RELEASE_DIR}" "${PREVIOUS_RELEASE}"; then
        rollback_link_ok=1
      fi
      if [[ "${env_restore_ok}" == "1" ]] && restore_systemd_units; then
        unit_restore_ok=1
      fi
      if [[ "${rollback_link_ok}" != "1" || "${unit_restore_ok}" != "1" || "${env_restore_ok}" != "1" ]]; then
        echo "CRITICAL: failed to restore the previous release, systemd units, or runtime environment." >&2
        exit 1
      fi
    elif [[ "${current_target}" == "${PREVIOUS_RELEASE}" ]]; then
      echo "Cutover had not occurred; verifying the unchanged previous release." >&2
      if ! restore_runtime_env; then
        echo "CRITICAL: failed to restore the prior runtime environment." >&2
        exit 1
      fi
      if ! restore_systemd_units; then
        echo "CRITICAL: failed to restore the prior systemd units." >&2
        exit 1
      fi
    else
      echo "CRITICAL: current release changed unexpectedly; refusing to overwrite it during rollback." >&2
      exit 1
    fi

    if [[ "${prior_active_state}" == "inactive" ]]; then
      observed_active="$(run_ssh "sudo systemctl is-active '${SERVICE_NAME}' 2>/dev/null || true" || true)"
      if [[ "${observed_active}" != "inactive" ]]; then
        echo "CRITICAL: rollback did not restore the previously inactive service state." >&2
      else
        echo "Rollback restored the previously inactive service; readiness probe skipped." >&2
        rollback_ready=1
      fi
    elif [[ -n "${PREVIOUS_REVISION}" ]]; then
      for _ in $(seq 1 15); do
        if run_ssh "env CYMPHOCTL_SERVICE_NAME='${SERVICE_NAME}' CYMPHOCTL_HEALTH_PORT='${APP_PORT}' CYMPHOCTL_APP_HOST='${DOMAIN}' CYMPHOCTL_HEALTH_VALIDATOR='${SOURCE_DIR}/bin/cympho-health-validator' '${SOURCE_DIR}/bin/cymphoctl' readiness --expect-revision '${PREVIOUS_REVISION}' >/dev/null"; then
          rollback_ready=1
          break
        fi
        sleep 2
      done
    else
      echo "CRITICAL: previous release has no valid revision manifest; rollback cannot be attested." >&2
    fi

    if [[ "${rollback_ready}" == "1" && "${prior_active_state}" == "inactive" ]]; then
      echo "Rollback inactive state verified." >&2
    elif [[ "${rollback_ready}" == "1" ]]; then
      echo "Rollback readiness verified at revision ${PREVIOUS_REVISION}." >&2
      echo "This verifies boot compatibility only; database migrations were not reversed." >&2
    else
      echo "CRITICAL: rollback did not become ready at its recorded revision." >&2
    fi
  else
    if [[ "${current_target}" == "${RELEASE_DIR}" ]]; then
      echo "No previous release exists; stopping the failed first deployment." >&2
      if ! run_remote_script <<EOF
_sudo systemctl stop '${SERVICE_NAME}'
EOF
      then
        echo "CRITICAL: Failed to stop first deployment service; preserving recovery evidence." >&2
        exit 1
      fi
      if ! run_remote_script <<EOF
current=\$(readlink -- '${CURRENT_LINK}' 2>/dev/null || true)
[ "\$current" = '${RELEASE_DIR}' ]
_sudo rm -f -- '${CURRENT_LINK}'
EOF
      then
        echo "CRITICAL: failed to remove first deployment current link; preserving recovery evidence." >&2
        exit 1
      fi
      if ! restore_runtime_env; then
        echo "CRITICAL: failed to restore the prior runtime environment." >&2
        exit 1
      fi
      if ! restore_systemd_units; then
        echo "CRITICAL: failed to restore the prior systemd units." >&2
        exit 1
      fi
      echo "CRITICAL: no previous release was available; service recovery is required." >&2
    elif [[ -n "${current_target}" ]]; then
      echo "CRITICAL: an unexpected current release exists; it was left unchanged." >&2
    else
      echo "Cutover had not occurred and no prior service state was changed." >&2
      if ! restore_runtime_env; then
        echo "CRITICAL: failed to restore the prior runtime environment." >&2
        exit 1
      fi
      if ! restore_systemd_units; then
        echo "CRITICAL: failed to restore the prior systemd units." >&2
        exit 1
      fi
    fi
  fi
  exit 1
}

step "Placing release at ${RELEASE_DIR}"
run_remote_script <<EOF || rollback_release "Failed to place release"
_sudo install -d -m 0700 -o root -g root ${RELEASE_DIR}
_sudo cp -a ${SOURCE_DIR}/_rel/. ${RELEASE_DIR}/
_sudo chown -R root:${APP_USER} ${RELEASE_DIR}
_sudo chmod -R u=rX,g=rX,o= ${RELEASE_DIR}
_sudo test "\$(_sudo readlink -f -- ${RELEASE_DIR})" = ${RELEASE_DIR}
_sudo test -z "\$(_sudo find ${RELEASE_DIR} -type l -print -quit)"
_sudo test -z "\$(_sudo find ${RELEASE_DIR} \\( ! -user root -o -perm /022 \\) -print -quit)"
_sudo test ! -L ${RELEASE_DIR}/releases/COOKIE
_sudo test -f ${RELEASE_DIR}/releases/COOKIE
_sudo chown root:${APP_USER} ${RELEASE_DIR}/releases/COOKIE
_sudo chmod 0440 ${RELEASE_DIR}/releases/COOKIE
EOF

step "Running database migrations"
run_remote_script <<EOF || rollback_release "Migrations failed"
# EnvironmentFile is parsed by systemd's non-shell grammar, matching the
# long-running service. No environment-file byte is executed as shell code.
_sudo systemd-run --wait --pipe --collect --quiet \
  --unit=cympho-migrate-${DEPLOY_NONCE} \
  --uid=${APP_USER} --gid=${APP_USER} \
  --property=EnvironmentFile=${ENV_FILE} \
  --property=PrivateTmp=true \
  --working-directory=${RELEASE_DIR} \
  --setenv=RELEASE_TMP=/tmp \
  ${RELEASE_DIR}/bin/${APP_NAME} eval 'Cympho.Release.migrate'
EOF

step "Activating release and restarting service"
run_remote_script <<EOF || rollback_release "Failed to activate/restart"
observed_current=\$(readlink -f ${CURRENT_LINK} 2>/dev/null || true)
if [ "\$observed_current" != "${PREVIOUS_RELEASE}" ]; then
  echo "Current release changed after this deploy began; refusing a stale cutover." >&2
  exit 1
fi
_sudo test ! -e '${CURRENT_LINK}.cympho-activate-${DEPLOY_NONCE}.tmp'
_sudo test ! -L '${CURRENT_LINK}.cympho-activate-${DEPLOY_NONCE}.tmp'
_sudo ln -s '${RELEASE_DIR}' '${CURRENT_LINK}.cympho-activate-${DEPLOY_NONCE}.tmp'
_sudo mv -fT -- '${CURRENT_LINK}.cympho-activate-${DEPLOY_NONCE}.tmp' '${CURRENT_LINK}'
if _sudo systemctl is-active --quiet ${SERVICE_NAME}; then
  _sudo systemctl restart ${SERVICE_NAME}
else
  _sudo systemctl start ${SERVICE_NAME}
fi
EOF

step "Attested readiness check (${LOCAL_READINESS_URL})"
deployed_main_pid=""
for _ in $(seq 1 15); do
  deployed_main_pid="$(
    run_remote_script <<EOF || true
pid_before=\$(_sudo systemctl show '${SERVICE_NAME}' -p MainPID --value)
case "\$pid_before" in ''|*[!0-9]*|0) exit 1 ;; esac
_sudo systemctl is-active --quiet '${SERVICE_NAME}'
sleep 1
pid_after=\$(_sudo systemctl show '${SERVICE_NAME}' -p MainPID --value)
[ "\$pid_after" = "\$pid_before" ]
_sudo systemctl is-active --quiet '${SERVICE_NAME}'
printf '%s' "\$pid_before"
EOF
  )"
  if [[ "${deployed_main_pid}" =~ ^[1-9][0-9]*$ ]]; then break; fi
  deployed_main_pid=""
  sleep 1
done
if [[ -z "${deployed_main_pid}" ]]; then
  rollback_release "Service did not establish a stable active MainPID"
fi

local_ok=0
for _ in $(seq 1 15); do
  if run_remote_script <<EOF
pid=\$(_sudo systemctl show '${SERVICE_NAME}' -p MainPID --value)
[ "\$pid" = '${deployed_main_pid}' ]
_sudo systemctl is-active --quiet '${SERVICE_NAME}'
env CYMPHOCTL_SERVICE_NAME='${SERVICE_NAME}' CYMPHOCTL_HEALTH_PORT='${APP_PORT}' CYMPHOCTL_APP_HOST='${DOMAIN}' CYMPHOCTL_HEALTH_VALIDATOR='${SOURCE_DIR}/bin/cympho-health-validator' '${SOURCE_DIR}/bin/cymphoctl' readiness --expect-revision '${BUILD_REVISION}' >/dev/null
_sudo systemctl is-active --quiet '${SERVICE_NAME}'
[ "\$(_sudo systemctl show '${SERVICE_NAME}' -p MainPID --value)" = "\$pid" ]
echo "Readiness accepted only while MainPID remains active: \$pid"
EOF
  then
    local_ok=1
    break
  fi
  sleep 2
done
if [[ "${local_ok}" != "1" ]]; then
  run_ssh "sudo journalctl -u ${SERVICE_NAME} -n 60 --no-pager" || true
  rollback_release "Service failed local health check"
fi
echo "Local health OK."

step "Configuring nginx site + TLS (certbot) for ${DOMAIN} and ${PREVIEW_DOMAIN}"
run_remote_script <<EOF || rollback_release "Failed to configure nginx/TLS"
site_avail=/etc/nginx/sites-available/${DOMAIN}
site_enabled=/etc/nginx/sites-enabled/${DOMAIN}
preview_site_avail=/etc/nginx/sites-available/${PREVIEW_DOMAIN}
preview_site_enabled=/etc/nginx/sites-enabled/${PREVIEW_DOMAIN}

# Preserve any certbot-managed existing vhost. New installs start HTTP-only;
# certbot upgrades both isolated hostnames after nginx accepts the config.
if ! _sudo test -f "\$site_avail"; then
  tmp=\$(mktemp)
  cat > "\$tmp" <<'NGX'
# __HOST__ -> Phoenix on 127.0.0.1:__PORT__ (managed by cympho deploy.sh)
server {
    listen 80;
    listen [::]:80;
    server_name __HOST__;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }

    client_max_body_size 25m;

    location / {
        proxy_pass http://127.0.0.1:__PORT__;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
        proxy_buffering off;
    }

    access_log /var/log/nginx/cympho-access.log;
    error_log /var/log/nginx/cympho-error.log;
}
NGX
  sed -i "s|__HOST__|${DOMAIN}|g; s|__PORT__|${APP_PORT}|g" "\$tmp"
  _sudo install -m 0644 "\$tmp" "\$site_avail"
  rm -f "\$tmp"
fi

# Create the preview HTTP vhost independently. Copying the primary file is
# unsafe on upgrades because certbot may already have added primary-host TLS
# blocks and redirects to it. Preserve an existing certbot-managed preview
# file, but always reconcile its enabled symlink below.
if ! _sudo test -f "\$preview_site_avail"; then
  tmp=\$(mktemp)
  cat > "\$tmp" <<'NGX'
# __HOST__ -> Phoenix preview proxy on 127.0.0.1:__PORT__ (managed by cympho deploy.sh)
server {
    listen 80;
    listen [::]:80;
    server_name __HOST__;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }

    client_max_body_size 25m;

    location / {
        proxy_pass http://127.0.0.1:__PORT__;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
        proxy_buffering off;
    }

    access_log /var/log/nginx/cympho-preview-access.log;
    error_log /var/log/nginx/cympho-preview-error.log;
}
NGX
  sed -i "s|__HOST__|${PREVIEW_DOMAIN}|g; s|__PORT__|${APP_PORT}|g" "\$tmp"
  _sudo install -m 0644 "\$tmp" "\$preview_site_avail"
  rm -f "\$tmp"
fi

_sudo ln -sfn "\$site_avail" "\$site_enabled"
_sudo ln -sfn "\$preview_site_avail" "\$preview_site_enabled"
_sudo nginx -t
_sudo systemctl reload nginx

# Existing single-host certificates are expanded in place. Inspecting the SAN
# avoids needless renewal attempts and rate-limit pressure on later deploys.
cert=/etc/letsencrypt/live/${DOMAIN}/fullchain.pem
if _sudo test -f "\$cert" &&
   _sudo openssl x509 -in "\$cert" -noout -ext subjectAltName 2>/dev/null |
     grep -Fq "DNS:${PREVIEW_DOMAIN}"; then
  echo "Certificate already covers ${DOMAIN} and ${PREVIEW_DOMAIN}."
else
  if _sudo test -f "\$cert"; then
    certbot_args="--cert-name ${DOMAIN} --expand"
  else
    certbot_args=""
  fi

  if _sudo certbot --nginx \$certbot_args -d ${DOMAIN} -d ${PREVIEW_DOMAIN} --non-interactive --agree-tos -m ${CERTBOT_EMAIL} --redirect; then
    echo "Certificate now covers ${DOMAIN} and ${PREVIEW_DOMAIN}."
  else
    echo "WARNING: certbot failed (both DNS names must point here)." >&2
    echo "         Existing primary TLS remains intact; re-run after preview DNS propagates." >&2
  fi
fi
EOF

step "Remote service status"
run_ssh "sudo systemctl status ${SERVICE_NAME} --no-pager -l | sed -n '1,12p'" || true

step "Public attested readiness (${PUBLIC_READINESS_URL}) — TLS may take ~30s to settle"
public_ok=0
for _ in 1 2 3 4 5 6; do
  if public_readiness_matches; then public_ok=1; break; fi
  sleep 10
done
if [[ "${public_ok}" == "1" ]]; then
  echo "Public HTTPS readiness verified at revision ${BUILD_REVISION}."
  # Logical commit happens before either best-effort evidence deletion so a
  # lost cleanup ACK cannot trigger rollback of a healthy deployment.
  unit_snapshot_to_delete="${UNIT_SNAPSHOT_ACTIVE}"
  env_snapshot_to_delete="${ENV_SNAPSHOT_ACTIVE}"
  UNIT_SNAPSHOT_ACTIVE=0
  ENV_SNAPSHOT_ACTIVE=0
  if [[ "${unit_snapshot_to_delete}" == "1" ]]; then
    commit_systemd_units force
  fi
  if [[ "${env_snapshot_to_delete}" == "1" ]]; then
    commit_runtime_env force
  fi
else
  rollback_release "Public readiness did not return the exact deployed revision at ${PUBLIC_READINESS_URL}"
fi

step "Pruning old releases (keeping 5 most recent after public validation)"
run_remote_script <<EOF || true
ls -1dt ${RELEASES_DIR}/*/ 2>/dev/null | tail -n +6 | while read -r d; do _sudo rm -rf "\$d"; done
EOF

echo
echo "Deployment complete: ${RELEASE_DIR}"
