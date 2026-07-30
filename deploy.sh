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
# GCP VPS (zaali@35.232.94.44). CYMPHO_-namespaced overrides win; the generic
# DEPLOY_HOST/DEPLOY_USER from ~/.secrets point at the same box.
DEPLOY_USER="${CYMPHO_DEPLOY_USER:-${DEPLOY_USER:-zaali}}"
DEPLOY_HOST="${CYMPHO_DEPLOY_HOST:-${DEPLOY_HOST:-35.232.94.44}}"
DEPLOY_PORT="${CYMPHO_DEPLOY_PORT:-22}"
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

# TLS certificate contact for certbot's first issuance on this host.
CERTBOT_EMAIL="${CYMPHO_CERTBOT_EMAIL:-admin@llmotions.com}"

SKIP_TESTS="${CYMPHO_SKIP_TESTS:-1}"

SOURCE_DIR="${DEPLOY_ROOT}/source"
RELEASES_DIR="${DEPLOY_ROOT}/releases"
CURRENT_LINK="${DEPLOY_ROOT}/current"
DB_ENV_FILE="${DEPLOY_ROOT}/db.env"
LOCAL_HEALTH_URL="http://127.0.0.1:${APP_PORT}/"
PUBLIC_HEALTH_URL="https://${DOMAIN}/"

usage() {
  cat <<EOF
Usage: ./deploy.sh [--run-tests]

  --run-tests   Run 'mix test' locally before deploying (default: skip).

TLS + routing are handled by the host's nginx; certbot issues/renews the cert
for ${DOMAIN} (webroot /var/www/certbot, same pattern as the other sites).

Environment overrides (CYMPHO_-namespaced win over generic): CYMPHO_DEPLOY_HOST,
CYMPHO_DEPLOY_USER, CYMPHO_DEPLOY_PORT, CYMPHO_DOMAIN, CYMPHO_APP_PORT,
CYMPHO_DB_PORT, CYMPHO_DEPLOY_ROOT, CYMPHO_CERTBOT_EMAIL, CYMPHO_SKIP_HOST_CHECK.
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
  -o StrictHostKeyChecking=no
  -o ConnectTimeout=20
  -p "${DEPLOY_PORT}"
)
RSYNC_RSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -p ${DEPLOY_PORT}"

run_ssh() {
  ssh "${SSH_OPTS[@]}" "${DEPLOY_TARGET}" "$@"
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
HTTP_BIND_IP=127.0.0.1
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
git_agent_src=${SOURCE_DIR}/deploy/cympho-git-agent.service
git_agent_dst=/etc/systemd/system/cympho-git-agent.service
units_changed=0
_sudo systemd-analyze verify "\$unit_src" "\$git_agent_src"
if ! _sudo cmp -s "\$unit_src" "\$unit_dst" 2>/dev/null; then
  _sudo install -m 0644 "\$unit_src" "\$unit_dst"
  units_changed=1
fi
if ! _sudo cmp -s "\$git_agent_src" "\$git_agent_dst" 2>/dev/null; then
  _sudo install -m 0644 "\$git_agent_src" "\$git_agent_dst"
  units_changed=1
fi
if [ "\$units_changed" = "1" ]; then
  _sudo systemctl daemon-reload
fi
_sudo systemctl enable ${SERVICE_NAME} >/dev/null 2>&1 || true
EOF

step "Starting Postgres container"
run_remote_script <<EOF
cd ${SOURCE_DIR}
# db.env is a root-owned secret (0600), so compose must read it as root.
_sudo docker compose -p ${COMPOSE_PROJECT} --env-file ${DB_ENV_FILE} up -d
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
# docker cp extracts as root (via the daemon), so a prior run's _rel is
# root-owned — clean it with sudo, then recreate as the deploy user.
_sudo rm -rf ${SOURCE_DIR}/_rel && mkdir -p ${SOURCE_DIR}/_rel
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
    run_ssh "sudo ln -sfn '${PREVIOUS_RELEASE}' '${CURRENT_LINK}'" || true
    run_ssh "sudo systemctl restart '${SERVICE_NAME}'" || true
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
# cd + RELEASE_TMP: the BEAM crashes at boot if its cwd is unreadable by
# ${APP_USER} (sudo keeps the caller's cwd, e.g. a 0700 home dir).
_sudo -u ${APP_USER} env bash -c '
  set -euo pipefail
  set -a; source ${ENV_FILE}; set +a
  cd ${RELEASE_DIR}
  export RELEASE_TMP=/tmp
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
local_ok=0
for _ in $(seq 1 15); do
  if run_ssh "curl -fsS --max-time 10 '${LOCAL_HEALTH_URL}' >/dev/null"; then
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

step "Pruning old releases (keeping 5 most recent)"
run_remote_script <<EOF || true
ls -1dt ${RELEASES_DIR}/*/ 2>/dev/null | tail -n +6 | while read -r d; do _sudo rm -rf "\$d"; done
EOF

step "Configuring nginx site + TLS (certbot) for ${DOMAIN}"
run_remote_script <<EOF
site_avail=/etc/nginx/sites-available/${DOMAIN}
site_enabled=/etc/nginx/sites-enabled/${DOMAIN}

# HTTP-only vhost first (ACME webroot + redirect); certbot upgrades it to TLS.
if ! _sudo test -f /etc/letsencrypt/live/${DOMAIN}/fullchain.pem; then
  tmp=\$(mktemp)
  cat > "\$tmp" <<'NGX'
# __DOMAIN__ -> Phoenix on 127.0.0.1:__PORT__ (managed by cympho deploy.sh)
server {
    listen 80;
    listen [::]:80;
    server_name __DOMAIN__;
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
  sed -i "s|__DOMAIN__|${DOMAIN}|g; s|__PORT__|${APP_PORT}|g" "\$tmp"
  _sudo install -m 0644 "\$tmp" "\$site_avail"
  rm -f "\$tmp"
  _sudo ln -sfn "\$site_avail" "\$site_enabled"
  _sudo nginx -t
  _sudo systemctl reload nginx
fi

# Issue the cert once DNS resolves here; certbot --nginx rewrites the vhost
# with TLS + the HTTP->HTTPS redirect and installs auto-renewal.
if ! _sudo test -f /etc/letsencrypt/live/${DOMAIN}/fullchain.pem; then
  if _sudo certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos -m ${CERTBOT_EMAIL} --redirect; then
    echo "Certificate issued for ${DOMAIN}."
  else
    echo "WARNING: certbot failed (DNS for ${DOMAIN} may not point here yet)." >&2
    echo "         Site is serving plain HTTP; re-run deploy.sh after DNS propagates." >&2
  fi
else
  echo "Certificate for ${DOMAIN} already present."
fi
EOF

step "Remote service status"
run_ssh "sudo systemctl status ${SERVICE_NAME} --no-pager -l | sed -n '1,12p'" || true

step "Public check (${PUBLIC_HEALTH_URL}) — Traefik may take ~30s to obtain the cert"
public_ok=0
for _ in 1 2 3 4 5 6; do
  if curl -fsS --max-time 15 "${PUBLIC_HEALTH_URL}" >/dev/null 2>&1; then public_ok=1; break; fi
  sleep 10
done
if [[ "${public_ok}" == "1" ]]; then
  echo "Public HTTPS OK."
else
  echo "WARNING: public HTTPS check failed — most likely DNS for ${DOMAIN} has not" >&2
  echo "         propagated to ${DEPLOY_HOST} yet. Re-run deploy.sh once it has." >&2
fi

echo
echo "Deployment complete: ${RELEASE_DIR}"
