#!/usr/bin/env bash
#
# Deploy Cympho to the target host.
#
#   * Builds a self-contained release (bundled ERTS) inside a throwaway Debian
#     Docker builder using the pinned Elixir 1.19.5 / OTP 28 image — the host's
#     system Elixir is too old to build with. The release RUNS natively under
#     systemd (no container at runtime).
#   * Postgres runs as a docker container bound to loopback.
#   * nginx (already on 80/443) reverse-proxies cympho.llmotions.com with TLS
#     from Let's Encrypt. The site config is a separate sites-available file
#     symlinked into sites-enabled — never edited into the main nginx.conf.
#
# Idempotent and safe to re-run; rolls the release symlink back on failure.
#
# Required:  CYMPHO_DEPLOY_PASSWORD   SSH (and sudo) password for the deploy user.
# Usage:     CYMPHO_DEPLOY_PASSWORD='...' ./deploy.sh [--run-tests] [--skip-tls]

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}"

# --- Target / identity -------------------------------------------------------
# All overrides are CYMPHO_-namespaced so a generic DEPLOY_HOST/DEPLOY_USER set
# in the shell for a *different* app can never silently hijack this deploy.
DEPLOY_USER="${CYMPHO_DEPLOY_USER:-nick}"
DEPLOY_HOST="${CYMPHO_DEPLOY_HOST:-home.hack.ski}"
DEPLOY_PORT="${CYMPHO_DEPLOY_PORT:-22}"
DEPLOY_PASSWORD="${CYMPHO_DEPLOY_PASSWORD:-}"
DEPLOY_SUDO_PASS="${CYMPHO_DEPLOY_SUDO_PASS:-${DEPLOY_PASSWORD}}"
DEPLOY_TARGET="${DEPLOY_USER}@${DEPLOY_HOST}"

# --- App layout --------------------------------------------------------------
APP_NAME="${CYMPHO_APP_NAME:-cympho}"
APP_USER="${CYMPHO_APP_USER:-cympho}"
DOMAIN="${CYMPHO_DOMAIN:-cympho.llmotions.com}"
APP_PORT="${CYMPHO_APP_PORT:-4000}"
DB_PORT="${CYMPHO_DB_PORT:-5442}"
DEPLOY_ROOT="${CYMPHO_DEPLOY_ROOT:-/opt/cympho}"
ENV_FILE="${CYMPHO_ENV_FILE:-/etc/cympho.env}"
SERVICE_NAME="${CYMPHO_SERVICE_NAME:-cympho}"
COMPOSE_PROJECT="${CYMPHO_COMPOSE_PROJECT:-cympho}"

# Traefik (the edge proxy on this host) integration. The native app is exposed
# to the Traefik container via a dynamic config file in its watched dir; Traefik
# terminates TLS. TRAEFIK_NETWORK's host-gateway is how the container reaches
# the native app.
TRAEFIK_DYNAMIC_DIR="${CYMPHO_TRAEFIK_DYNAMIC_DIR:-/home/nick/homeserver-traefik-portainer/dynamic}"
TRAEFIK_NETWORK="${CYMPHO_TRAEFIK_NETWORK:-homeserver}"
TRAEFIK_CERTRESOLVER="${CYMPHO_TRAEFIK_CERTRESOLVER:-tlsresolver}"

SKIP_TESTS="${CYMPHO_SKIP_TESTS:-1}"

SOURCE_DIR="${DEPLOY_ROOT}/source"
RELEASES_DIR="${DEPLOY_ROOT}/releases"
CURRENT_LINK="${DEPLOY_ROOT}/current"
DB_ENV_FILE="${DEPLOY_ROOT}/db.env"
LOCAL_HEALTH_URL="http://127.0.0.1:${APP_PORT}/"
PUBLIC_HEALTH_URL="https://${DOMAIN}/"

usage() {
  cat <<EOF
Usage: CYMPHO_DEPLOY_PASSWORD='...' ./deploy.sh [--run-tests]

  --run-tests   Run 'mix test' locally before deploying (default: skip).

TLS + routing are handled by the host's Traefik (a dynamic config file is
installed into its watched dir); there is no nginx/certbot step.

Environment overrides (all CYMPHO_-namespaced): CYMPHO_DEPLOY_HOST,
CYMPHO_DEPLOY_USER, CYMPHO_DEPLOY_PORT, CYMPHO_DEPLOY_SUDO_PASS, CYMPHO_DOMAIN,
CYMPHO_APP_PORT, CYMPHO_DB_PORT, CYMPHO_DEPLOY_ROOT, CYMPHO_TRAEFIK_DYNAMIC_DIR,
CYMPHO_TRAEFIK_NETWORK, CYMPHO_TRAEFIK_CERTRESOLVER, CYMPHO_SKIP_HOST_CHECK.
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
require_cmd ssh
require_cmd rsync
require_cmd curl
require_cmd sshpass

if [[ -z "${DEPLOY_PASSWORD}" ]]; then
  echo "CYMPHO_DEPLOY_PASSWORD is not set." >&2
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

export SSHPASS="${DEPLOY_PASSWORD}"

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=20
  -p "${DEPLOY_PORT}"
)
RSYNC_RSH="sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p ${DEPLOY_PORT}"

run_ssh() {
  sshpass -e ssh "${SSH_OPTS[@]}" "${DEPLOY_TARGET}" "$@"
}

# Run a bash script on the host with `set -euo pipefail` and a `_sudo` helper
# that feeds the sudo password over stdin (never in argv or logs).
run_remote_script() {
  local body
  body="$(cat)"
  {
    printf 'SUDO_PASS=%q\n' "${DEPLOY_SUDO_PASS}"
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' '_sudo() { echo "$SUDO_PASS" | sudo -S -p "" "$@"; }'
    printf '%s\n' "${body}"
  } | run_ssh "bash -s"
}

step() { echo; echo "==> $*"; }

# ---------------------------------------------------------------------------

echo "Deploy target: ${DEPLOY_TARGET}"
echo "Domain:        ${DOMAIN}"
echo "Deploy root:   ${DEPLOY_ROOT}"

if [[ "${SKIP_TESTS}" != "1" ]]; then
  step "Running local tests"
  ( cd "${REPO_DIR}" && mix test ) || { echo "Local tests failed. Aborting." >&2; exit 1; }
fi

step "Bootstrapping host (user, directories, systemd unit)"
run_remote_script <<EOF
command -v systemctl >/dev/null 2>&1 || { echo "systemd required" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "docker required" >&2; exit 1; }

if ! id -u ${APP_USER} >/dev/null 2>&1; then
  _sudo useradd --system --create-home --shell /usr/sbin/nologin --user-group ${APP_USER}
fi

_sudo install -d -m 0755 ${DEPLOY_ROOT}
_sudo install -d -m 0755 -o ${DEPLOY_USER} -g ${DEPLOY_USER} ${SOURCE_DIR}
_sudo install -d -m 0755 -o ${APP_USER} -g ${APP_USER} ${RELEASES_DIR}
EOF

step "Ensuring secrets (${ENV_FILE}, ${DB_ENV_FILE}) — generated once, never overwritten"
run_remote_script <<EOF
if _sudo test -f ${ENV_FILE}; then
  echo "Keeping existing ${ENV_FILE}."
else
  DBPASS=\$(openssl rand -hex 24)
  SKB=\$(openssl rand -hex 64)
  ENC=\$(openssl rand -hex 16)         # exactly 32 bytes (AES-256 key)
  UJWT=\$(openssl rand -hex 48)
  AJWT=\$(openssl rand -hex 48)
  LVSALT=\$(openssl rand -hex 16)

  db_tmp=\$(mktemp); env_tmp=\$(mktemp)
  cat > "\$db_tmp" <<DBENV
POSTGRES_USER=cympho
POSTGRES_PASSWORD=\${DBPASS}
POSTGRES_DB=cympho
DB_PUBLISH_PORT=${DB_PORT}
DBENV
  cat > "\$env_tmp" <<APPENV
APP_HOST=${DOMAIN}
PORT=${APP_PORT}
HTTP_BIND_IP=0.0.0.0
POOL_SIZE=25
DATABASE_URL=ecto://cympho:\${DBPASS}@127.0.0.1:${DB_PORT}/cympho
SECRET_KEY_BASE=\${SKB}
CYMPHO_ENCRYPTION_KEY=\${ENC}
CYMPHO_USER_JWT_SECRET=\${UJWT}
CYMPHO_AGENT_JWT_SECRET=\${AJWT}
LIVE_VIEW_SALT=\${LVSALT}
APPENV

  _sudo install -m 0600 -o ${DEPLOY_USER} -g ${DEPLOY_USER} "\$db_tmp" ${DB_ENV_FILE}
  _sudo install -m 0640 -o root -g ${APP_USER} "\$env_tmp" ${ENV_FILE}
  rm -f "\$db_tmp" "\$env_tmp"
  echo "Generated ${ENV_FILE} and ${DB_ENV_FILE}."
fi
EOF

step "Syncing repository to ${SOURCE_DIR}"
rsync -az --delete -e "${RSYNC_RSH}" \
  --exclude '.git' --exclude '_build' --exclude 'deps' --exclude '_rel' \
  --exclude 'erl_crash.dump' --exclude 'cover' --exclude '.elixir_ls' \
  --exclude 'screens' --exclude 'designs' --exclude '.specs' --exclude 'test' \
  --exclude 'priv/static/uploads' \
  "${REPO_DIR}/" "${DEPLOY_TARGET}:${SOURCE_DIR}/"

step "Installing systemd unit"
run_remote_script <<EOF
unit_src=${SOURCE_DIR}/deploy/cympho.service
unit_dst=/etc/systemd/system/${SERVICE_NAME}.service
if ! _sudo cmp -s "\$unit_src" "\$unit_dst" 2>/dev/null; then
  _sudo install -m 0644 "\$unit_src" "\$unit_dst"
  _sudo systemctl daemon-reload
fi
_sudo systemctl enable ${SERVICE_NAME} >/dev/null 2>&1 || true
EOF

step "Starting Postgres container"
run_remote_script <<EOF
cd ${SOURCE_DIR}
docker compose -p ${COMPOSE_PROJECT} --env-file ${DB_ENV_FILE} up -d
status=starting
for _ in \$(seq 1 30); do
  status=\$(docker inspect -f '{{.State.Health.Status}}' cympho-db 2>/dev/null || echo starting)
  [ "\$status" = "healthy" ] && break
  sleep 2
done
if [ "\$status" != "healthy" ]; then
  echo "Postgres did not become healthy" >&2
  docker logs --tail 40 cympho-db >&2 || true
  exit 1
fi
echo "Postgres healthy."
EOF

step "Building release via Docker (deps + assets + release; first run is slow)"
run_remote_script <<EOF
cd ${SOURCE_DIR}
docker build -f deploy/build.Dockerfile -t ${APP_NAME}-build:latest .
rm -rf ${SOURCE_DIR}/_rel && mkdir -p ${SOURCE_DIR}/_rel
cid=\$(docker create ${APP_NAME}-build:latest)
docker cp "\${cid}:/rel/." ${SOURCE_DIR}/_rel/
docker rm "\${cid}" >/dev/null
test -x ${SOURCE_DIR}/_rel/bin/${APP_NAME} || { echo "release binary missing" >&2; exit 1; }
echo "Release extracted."
EOF

# --- Activate ---------------------------------------------------------------
TS="$(date +%Y%m%d%H%M%S)"
RELEASE_DIR="${RELEASES_DIR}/${TS}"
PREVIOUS_RELEASE="$(run_ssh "readlink -f '${CURRENT_LINK}' 2>/dev/null || true" || true)"

rollback_release() {
  echo "ERROR: $1" >&2
  if [[ -n "${PREVIOUS_RELEASE}" && "${PREVIOUS_RELEASE}" != "${RELEASE_DIR}" ]]; then
    echo "Rolling back to ${PREVIOUS_RELEASE}" >&2
    run_ssh "echo '${DEPLOY_SUDO_PASS}' | sudo -S -p '' ln -sfn '${PREVIOUS_RELEASE}' '${CURRENT_LINK}'" || true
    run_ssh "echo '${DEPLOY_SUDO_PASS}' | sudo -S -p '' systemctl restart '${SERVICE_NAME}'" || true
  fi
  exit 1
}

step "Placing release at ${RELEASE_DIR}"
run_remote_script <<EOF || rollback_release "Failed to place release"
_sudo install -d -o ${APP_USER} -g ${APP_USER} ${RELEASE_DIR}
_sudo cp -a ${SOURCE_DIR}/_rel/. ${RELEASE_DIR}/
_sudo chown -R ${APP_USER}:${APP_USER} ${RELEASE_DIR}
EOF

step "Running database migrations"
run_remote_script <<EOF || rollback_release "Migrations failed"
_sudo -u ${APP_USER} env bash -c '
  set -euo pipefail
  set -a; source ${ENV_FILE}; set +a
  ${RELEASE_DIR}/bin/${APP_NAME} eval "Cympho.Release.migrate"
'
EOF

step "Activating release and restarting service"
run_remote_script <<EOF || rollback_release "Failed to activate/restart"
_sudo ln -sfn ${RELEASE_DIR} ${CURRENT_LINK}
if _sudo systemctl is-active --quiet ${SERVICE_NAME}; then
  _sudo systemctl restart ${SERVICE_NAME}
else
  _sudo systemctl start ${SERVICE_NAME}
fi
EOF

step "Health check (${LOCAL_HEALTH_URL})"
sleep 4
if ! run_ssh "curl -fsS --max-time 10 '${LOCAL_HEALTH_URL}' >/dev/null"; then
  run_ssh "echo '${DEPLOY_SUDO_PASS}' | sudo -S -p '' journalctl -u ${SERVICE_NAME} -n 60 --no-pager" || true
  rollback_release "Service failed local health check"
fi
echo "Local health OK."

step "Pruning old releases (keeping 5 most recent)"
run_remote_script <<EOF || true
ls -1dt ${RELEASES_DIR}/*/ 2>/dev/null | tail -n +6 | while read -r d; do _sudo rm -rf "\$d"; done
EOF

step "Registering route with Traefik (dynamic config file — no main config edited)"
run_remote_script <<EOF
dyn_dir=${TRAEFIK_DYNAMIC_DIR}
[ -d "\$dyn_dir" ] || { echo "Traefik dynamic dir \$dyn_dir not found" >&2; exit 1; }

# Host-gateway of the Traefik network: how the container reaches the native app.
gw=\$(docker network inspect ${TRAEFIK_NETWORK} -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)
[ -n "\$gw" ] || { echo "Could not resolve ${TRAEFIK_NETWORK} network gateway" >&2; exit 1; }

# Written with placeholders (literal heredoc), then substituted — avoids any
# shell/backtick escaping surprises.
cat > "\$dyn_dir/cympho.yml" <<'DYN'
# Managed by cympho deploy.sh — routes __DOMAIN__ to the native app.
http:
  routers:
    cympho:
      rule: "Host(\`__DOMAIN__\`)"
      entryPoints:
        - websecure
      service: cympho
      tls:
        certResolver: __RESOLVER__
  services:
    cympho:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: "http://__GW__:__PORT__"
DYN
sed -i "s|__DOMAIN__|${DOMAIN}|g; s|__RESOLVER__|${TRAEFIK_CERTRESOLVER}|g; s|__GW__|\${gw}|g; s|__PORT__|${APP_PORT}|g" "\$dyn_dir/cympho.yml"
echo "Wrote \$dyn_dir/cympho.yml:"; cat "\$dyn_dir/cympho.yml"
EOF

step "Remote service status"
run_ssh "echo '${DEPLOY_SUDO_PASS}' | sudo -S -p '' systemctl status ${SERVICE_NAME} --no-pager -l | sed -n '1,12p'" || true

step "Public check (${PUBLIC_HEALTH_URL}) — Traefik may take ~30s to obtain the cert"
public_ok=0
for _ in 1 2 3 4 5 6; do
  if curl -fsS --max-time 15 "${PUBLIC_HEALTH_URL}" >/dev/null 2>&1; then public_ok=1; break; fi
  sleep 10
done
if [[ "${public_ok}" == "1" ]]; then
  echo "Public HTTPS OK."
else
  echo "WARNING: public HTTPS check failed (cert may still be issuing, or ${TRAEFIK_CERTRESOLVER}" >&2
  echo "         can't validate ${DOMAIN}). Check: docker logs traefik | grep -i acme" >&2
fi

echo
echo "Deployment complete: ${RELEASE_DIR}"
