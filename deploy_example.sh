#!/bin/bash
# Deploy the current repo state to the shared VPS.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}"

DEPLOY_USER="${DEPLOY_USER:-root}"
DEPLOY_HOST="${DEPLOY_HOST:-yourserver}"
DEPLOY_PORT="${DEPLOY_PORT:-22}"
DEPLOY_TARGET="${DEPLOY_USER}@${DEPLOY_HOST}"

APP_NAME="${APP_NAME:-agrenting}"
APP_USER="${APP_USER:-agrenting}"
DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/agrenting}"
ENV_FILE="${ENV_FILE:-/etc/agrenting.env}"
SERVICE_NAME="${SERVICE_NAME:-agrenting}"

LOCAL_HEALTH_URL="${LOCAL_HEALTH_URL:-http://127.0.0.1:4012/api/v1/health/readiness}"
PUBLIC_HEALTH_URL="${PUBLIC_HEALTH_URL:-https://agrenting.com/api/v1/health/readiness}"

SKIP_TESTS="${SKIP_TESTS:-0}"
SKIP_PUBLIC_CHECK="${SKIP_PUBLIC_CHECK:-0}"

SOURCE_DIR="${DEPLOY_ROOT}/source"
RELEASES_DIR="${DEPLOY_ROOT}/releases"
CURRENT_LINK="${DEPLOY_ROOT}/current"
PREVIOUS_LINK="${DEPLOY_ROOT}/previous"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

usage() {
  cat <<'EOF'
Usage: ./deploy.sh [--skip-tests] [--skip-public-check]

Environment overrides:
  DEPLOY_HOST           Default: yourserver
  DEPLOY_USER           Default: root
  DEPLOY_PORT           Default: 22
  DEPLOY_AUTH_METHOD    Default: key (options: key, password)
  DEPLOY_PASSWORD       Required if DEPLOY_AUTH_METHOD=password
  ENV_FILE              Default: /etc/agrenting.env
  PUBLIC_HEALTH_URL     Default: https://agrenting.com/api/v1/health/readiness

Examples:
  ./deploy.sh
  DEPLOY_AUTH_METHOD=password DEPLOY_PASSWORD='your-password' ./deploy.sh
  ./deploy.sh --skip-tests
EOF
}

while (($# > 0)); do
  case "$1" in
    --skip-tests)
      SKIP_TESTS=1
      ;;
    --skip-public-check)
      SKIP_PUBLIC_CHECK=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd ssh
require_cmd rsync
require_cmd curl

if [[ "${SKIP_TESTS}" != "1" ]]; then
  require_cmd mix
fi

SSH_AUTH_OPTS=()

if [[ "${DEPLOY_AUTH_METHOD:-key}" == "password" ]]; then
  if [[ -z "${DEPLOY_PASSWORD:-}" ]]; then
    echo "DEPLOY_AUTH_METHOD=password but DEPLOY_PASSWORD is not set" >&2
    exit 1
  fi

  require_cmd sshpass

  export SSHPASS="${DEPLOY_PASSWORD}"
  SSH_AUTH_OPTS=(
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
  )

  RSYNC_RSH="sshpass -e ssh ${SSH_AUTH_OPTS[*]} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p ${DEPLOY_PORT}"
else
  RSYNC_RSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p ${DEPLOY_PORT}"
fi

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -p "${DEPLOY_PORT}"
)

if [[ "${DEPLOY_AUTH_METHOD:-key}" == "password" ]]; then
  SSH_OPTS=("${SSH_AUTH_OPTS[@]}" "${SSH_OPTS[@]}")
fi

run_ssh() {
  if [[ "${DEPLOY_AUTH_METHOD:-key}" == "password" ]]; then
    sshpass -e ssh "${SSH_OPTS[@]}" "${DEPLOY_TARGET}" "$@"
  else
    ssh "${SSH_OPTS[@]}" "${DEPLOY_TARGET}" "$@"
  fi
}

run_remote_script() {
  local script_file status

  script_file="$(mktemp)"
  cat > "${script_file}"

  if [[ "${DEPLOY_AUTH_METHOD:-key}" == "password" ]]; then
    if sshpass -e ssh "${SSH_OPTS[@]}" "${DEPLOY_TARGET}" "bash -se" < "${script_file}"; then
      status=0
    else
      status=$?
    fi
  else
    if ssh "${SSH_OPTS[@]}" "${DEPLOY_TARGET}" "bash -se" < "${script_file}"; then
      status=0
    else
      status=$?
    fi
  fi

  rm -f "${script_file}"
  return "${status}"
}

echo "Deploy target: ${DEPLOY_TARGET}"
echo "Repo: ${REPO_DIR}"

if [[ "${SKIP_TESTS}" != "1" ]]; then
  echo "Running local tests..."
  if ! (
    cd "${REPO_DIR}"
    mix test
  ); then
    echo "Local tests failed. Deployment aborted." >&2
    exit 1
  fi
fi

echo "Bootstrapping remote deployment directories and service..."
run_remote_script <<EOF
set -euo pipefail

if ! command -v systemctl >/dev/null 2>&1; then
  echo "Missing required remote command: systemctl" >&2
  exit 1
fi

if ! id -u ${APP_USER} >/dev/null 2>&1; then
  useradd --system --create-home --shell /bin/bash --user-group ${APP_USER}
fi

install -d -m 0755 -o ${APP_USER} -g ${APP_USER} \
  '${DEPLOY_ROOT}' \
  '${SOURCE_DIR}' \
  '${RELEASES_DIR}'

unit_tmp=\$(mktemp)
cat > "\${unit_tmp}" <<UNIT
[Unit]
Description=Agent Marketplace
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${CURRENT_LINK}
Environment=MIX_ENV=prod
Environment=PHX_SERVER=true
EnvironmentFile=${ENV_FILE}
ExecStart=${CURRENT_LINK}/bin/${APP_NAME} start
ExecStop=${CURRENT_LINK}/bin/${APP_NAME} stop

Restart=on-failure
RestartSec=10

LimitNOFILE=65536
LimitNPROC=65536

StandardOutput=journal
StandardError=journal

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${DEPLOY_ROOT}

[Install]
WantedBy=multi-user.target
UNIT

unit_changed=0
if [[ ! -f '${SERVICE_FILE}' ]] || ! cmp -s "\${unit_tmp}" '${SERVICE_FILE}'; then
  install -m 0644 "\${unit_tmp}" '${SERVICE_FILE}'
  unit_changed=1
fi
rm -f "\${unit_tmp}"

if [[ "\${unit_changed}" == "1" ]]; then
  systemctl daemon-reload
fi

systemctl enable '${SERVICE_NAME}' >/dev/null

if [[ ! -f '${ENV_FILE}' ]]; then
  echo "Missing environment file: ${ENV_FILE}" >&2
  exit 1
fi
EOF

echo "Syncing repository to ${SOURCE_DIR}..."
rsync -az --delete -e "${RSYNC_RSH}" \
  --exclude '.git' \
  --exclude '.env' \
  --exclude '_build' \
  --exclude 'deps' \
  --exclude 'cover' \
  --exclude 'erl_crash.dump' \
  --exclude '.specs' \
  --exclude '*.html' \
  --exclude 'AGENTS.md' \
  "${REPO_DIR}/" "${DEPLOY_TARGET}:${SOURCE_DIR}/"

echo "Preparing remote source tree..."
run_remote_script <<EOF
set -euo pipefail
chown -R ${APP_USER}:${APP_USER} '${SOURCE_DIR}'
EOF

echo "Resolving remote runtime path..."
REMOTE_RUNTIME_PATH="$(
  run_remote_script <<EOF
set -euo pipefail

base_path='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin'
install_root='/home/${APP_USER}/.elixir-install/installs'
resolved_parts=()

if [[ -d "\${install_root}/otp" ]]; then
  otp_bin="\$(
    find "\${install_root}/otp" -mindepth 2 -maxdepth 2 -type d -name bin 2>/dev/null \
      | grep -v -- '-test' \
      | sort \
      | tail -n 1
  )"

  if [[ -n "\${otp_bin}" ]]; then
    resolved_parts+=("\${otp_bin}")
  fi
fi

if [[ -d "\${install_root}/elixir" ]]; then
  elixir_bin="\$(
    find "\${install_root}/elixir" -mindepth 2 -maxdepth 2 -type d -name bin 2>/dev/null \
      | grep -v -- '-test' \
      | sort \
      | tail -n 1
  )"

  if [[ -n "\${elixir_bin}" ]]; then
    resolved_parts+=("\${elixir_bin}")
  fi
fi

resolved_parts+=("\${base_path}")
printf '%s\n' "\$(IFS=:; echo "\${resolved_parts[*]}")"
EOF
)"

echo "Validating remote environment and toolchain..."
run_remote_script <<EOF
set -euo pipefail

run_as_app() {
  if command -v sudo >/dev/null 2>&1; then
    sudo -H -u ${APP_USER} env "\$@"
  elif [[ "\$(id -u)" -eq 0 ]] && command -v runuser >/dev/null 2>&1; then
    runuser -u ${APP_USER} -- env "\$@"
  else
    echo "Need sudo or runuser to execute commands as ${APP_USER}" >&2
    exit 1
  fi
}

run_as_app ENV_FILE='${ENV_FILE}' PATH='${REMOTE_RUNTIME_PATH}' bash -lc '
  set -euo pipefail
  cd "\$HOME"

  required_tools=(mix elixir erl node npm)
  for tool in "\${required_tools[@]}"; do
    if ! command -v "\$tool" >/dev/null 2>&1; then
      echo "Missing required remote command for ${APP_USER}: \$tool" >&2
      exit 1
    fi
  done

  set -a
  source "\$ENV_FILE"
  set +a

  required_vars=(
    SECRET_KEY_BASE
    DATABASE_URL
    CYMPHO_ENCRYPTION_KEY
    CYMPHO_USER_JWT_SECRET
    CYMPHO_AGENT_JWT_SECRET
    STRIPE_SECRET_KEY
    STRIPE_WEBHOOK_SECRET
    CIRCLE_API_KEY
    CIRCLE_WEBHOOK_SECRET
    NOWPAYMENTS_API_KEY
    NOWPAYMENTS_SECRET_KEY
    SECRETS_VAULT_KEY
  )

  for var in "\${required_vars[@]}"; do
    value="\${!var:-}"

    if [[ -z "\$value" ]]; then
      echo "Missing required environment variable in \$ENV_FILE: \$var" >&2
      exit 1
    fi

    if [[ "\$value" == *placeholder* ]]; then
      echo "Placeholder value detected in \$ENV_FILE: \$var" >&2
      exit 1
    fi
  done

  if [[ -z "\${HONEYBADGER_API_KEY:-}" ]]; then
    echo "WARNING: HONEYBADGER_API_KEY is not set in \$ENV_FILE; Honeybadger reporting will be disabled." >&2
  fi
'
EOF

echo "Building release on the VPS..."
run_remote_script <<EOF
set -euo pipefail

run_as_app() {
  if command -v sudo >/dev/null 2>&1; then
    sudo -H -u ${APP_USER} env "\$@"
  elif [[ "\$(id -u)" -eq 0 ]] && command -v runuser >/dev/null 2>&1; then
    runuser -u ${APP_USER} -- env "\$@"
  else
    echo "Need sudo or runuser to execute commands as ${APP_USER}" >&2
    exit 1
  fi
}

run_as_app SOURCE_DIR='${SOURCE_DIR}' ENV_FILE='${ENV_FILE}' PATH='${REMOTE_RUNTIME_PATH}' bash -lc '
  set -euo pipefail
  cd "\$SOURCE_DIR"
  set -a
  source "\$ENV_FILE"
  set +a
  export MIX_ENV=prod
  mix deps.get --only prod
  mix deps.compile
  mix assets.deploy
  mix release --overwrite
'
EOF

echo "Activating release..."
TS="$(date +%Y%m%d%H%M%S)"
RELEASE_DIR="${RELEASES_DIR}/${TS}"

PREVIOUS_RELEASE="$(run_ssh "readlink -f '${CURRENT_LINK}' || true")"

rollback_release() {
  local reason="$1"

  echo "ERROR: ${reason}" >&2

  if [[ -n "${PREVIOUS_RELEASE}" ]]; then
    echo "Rolling back to ${PREVIOUS_RELEASE}" >&2
    run_ssh "ln -sfn '${PREVIOUS_RELEASE}' '${CURRENT_LINK}'" || true
    run_ssh "ln -sfn '${PREVIOUS_RELEASE}' '${PREVIOUS_LINK}'" || true

    if run_ssh "systemctl is-active --quiet '${SERVICE_NAME}'"; then
      run_ssh "systemctl restart '${SERVICE_NAME}'" || true
    else
      run_ssh "systemctl start '${SERVICE_NAME}'" || true
    fi
  fi

  exit 1
}

echo "Creating release directory: ${RELEASE_DIR}"
run_ssh "install -d -o ${APP_USER} -g ${APP_USER} '${RELEASE_DIR}'" ||
  rollback_release "Failed to create release directory"

run_ssh "cp -a '${SOURCE_DIR}/_build/prod/rel/${APP_NAME}/.' '${RELEASE_DIR}/'" ||
  rollback_release "Failed to copy release into place"

run_ssh "chown -R ${APP_USER}:${APP_USER} '${RELEASE_DIR}'" ||
  rollback_release "Failed to fix release ownership"

echo "Running migrations..."
run_remote_script <<EOF
set -euo pipefail

run_as_app() {
  if command -v sudo >/dev/null 2>&1; then
    sudo -H -u ${APP_USER} env "\$@"
  elif [[ "\$(id -u)" -eq 0 ]] && command -v runuser >/dev/null 2>&1; then
    runuser -u ${APP_USER} -- env "\$@"
  else
    echo "Need sudo or runuser to execute commands as ${APP_USER}" >&2
    exit 1
  fi
}

run_as_app RELEASE_DIR='${RELEASE_DIR}' ENV_FILE='${ENV_FILE}' APP_NAME='${APP_NAME}' PATH='${REMOTE_RUNTIME_PATH}' bash -lc '
  set -euo pipefail
  cd "\$RELEASE_DIR"
  set -a
  source "\$ENV_FILE"
  set +a
  "bin/\$APP_NAME" eval "Agrenting.Release.migrate"
'
EOF

if [[ -n "${PREVIOUS_RELEASE}" ]]; then
  echo "Recording previous release: ${PREVIOUS_RELEASE}"
  run_ssh "ln -sfn '${PREVIOUS_RELEASE}' '${PREVIOUS_LINK}'" ||
    rollback_release "Failed to update previous release symlink"
fi

if run_ssh "systemctl is-active --quiet '${SERVICE_NAME}'"; then
  echo "Stopping current service..."
  run_ssh "systemctl stop '${SERVICE_NAME}'" ||
    rollback_release "Failed to stop existing service"
fi

echo "Updating symlink: ${RELEASE_DIR} -> ${CURRENT_LINK}"
run_ssh "ln -sfn '${RELEASE_DIR}' '${CURRENT_LINK}'" ||
  rollback_release "Failed to update release symlink"

echo "Starting service..."
run_ssh "systemctl start '${SERVICE_NAME}'" ||
  rollback_release "Failed to start service"

echo "Waiting for service to start..."
sleep 3

if ! run_ssh "systemctl is-active --quiet '${SERVICE_NAME}'"; then
  rollback_release "Service failed to reach active state"
fi

RUNNING_CMD="$(run_ssh "PID=\$(systemctl show -p MainPID --value '${SERVICE_NAME}'); if [ -n \"\$PID\" ] && [ \"\$PID\" != \"0\" ] && [ -r \"/proc/\$PID/cmdline\" ]; then tr '\\0' ' ' < \"/proc/\$PID/cmdline\"; fi")"

if [[ -z "${RUNNING_CMD}" ]]; then
  rollback_release "Unable to inspect the running service process"
fi

if [[ "${RUNNING_CMD}" != *"${RELEASE_DIR}"* ]]; then
  echo "Running command line: ${RUNNING_CMD}" >&2
  rollback_release "Service is not running the newly activated release"
fi

echo "Health check..."
if ! run_ssh "curl -fsS --max-time 10 '${LOCAL_HEALTH_URL}' >/dev/null"; then
  echo "WARNING: Health check failed, but service is running" >&2
fi

echo "Release ${RELEASE_DIR} activated successfully"
echo "Active release: ${RELEASE_DIR}"

echo "Checking remote service status..."
run_ssh "systemctl status ${SERVICE_NAME}.service --no-pager -l | sed -n '1,40p'"

if [[ "${SKIP_PUBLIC_CHECK}" != "1" ]]; then
  echo "Checking public readiness: ${PUBLIC_HEALTH_URL}"
  curl -fsS "${PUBLIC_HEALTH_URL}"
  echo
fi

echo "Deployment complete."
