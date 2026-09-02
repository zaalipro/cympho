#!/bin/sh
# Build the shipped container, exercise PID-1 orphan reaping, and boot its real
# release through the published readiness endpoint.
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
image_tag="${CYMPHO_DOCKER_TEST_IMAGE:-cympho-container-init-test:local}"
network="cympho-container-test-$$"
database_container="cympho-container-db-$$"
app_container="cympho-container-app-$$"
health_body=""
health_canonical=""
context_dir=""
context_archive=""

cleanup() {
  if [ -n "$health_body" ]; then rm -f "$health_body"; fi
  if [ -n "$health_canonical" ]; then rm -f "$health_canonical"; fi
  if [ -n "$context_archive" ]; then rm -f "$context_archive"; fi
  if [ -n "$context_dir" ]; then rm -rf "$context_dir"; fi
  docker rm -f "$app_container" "$database_container" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  if [ "${CYMPHO_DOCKER_TEST_KEEP_IMAGE:-0}" != "1" ]; then
    docker image rm "$image_tag" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

command -v git >/dev/null 2>&1 || {
  echo "FAIL: git is required to build an immutable container context" >&2
  exit 1
}

if ! head_revision="$(git -C "$repo_root" rev-parse --verify "HEAD^{commit}" 2>/dev/null)"; then
  echo "FAIL: the container smoke test requires a committed Git HEAD" >&2
  exit 1
fi

if [ "${CYMPHO_BUILD_REVISION+x}" = "x" ] &&
   [ "${CYMPHO_BUILD_REVISION-}" != "$head_revision" ]; then
  echo "FAIL: CYMPHO_BUILD_REVISION does not match checkout HEAD ($head_revision)" >&2
  exit 1
fi
build_revision="$head_revision"

command -v docker >/dev/null 2>&1 || {
  echo "FAIL: docker is required to verify container orphan reaping" >&2
  exit 1
}
command -v curl >/dev/null 2>&1 || {
  echo "FAIL: curl is required to verify the published readiness endpoint" >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "FAIL: python3 is required to validate the readiness document" >&2
  exit 1
}
command -v tar >/dev/null 2>&1 || {
  echo "FAIL: tar is required to build an immutable container context" >&2
  exit 1
}

# Never label bytes from a mutable working tree as HEAD. Build from an exact
# archive of that commit; tracked, staged, and untracked checkout drift cannot
# enter this context. The archived .dockerignore still removes build-only
# paths before Docker sends the context to the daemon.
context_dir="$(mktemp -d "${TMPDIR:-/tmp}/cympho-docker-context.XXXXXX")"
context_archive="$(mktemp "${TMPDIR:-/tmp}/cympho-docker-archive.XXXXXX")"
git -C "$repo_root" archive \
  --format=tar \
  --output="$context_archive" \
  "$head_revision"
tar -xf "$context_archive" -C "$context_dir"
rm -f "$context_archive"
context_archive=""

docker build \
  --build-arg "CYMPHO_BUILD_REVISION=$build_revision" \
  --tag "$image_tag" \
  "$context_dir"
docker run --rm -i "$image_tag" sh -s \
  < "$context_dir/scripts/assert-orphan-reaping.sh"

# Exercise a real release boot against Postgres, then verify both the CLI's
# exact-revision gate inside the image and the host-published HTTP port. Values
# below are isolated CI fixtures, never production credentials.
docker network create "$network" >/dev/null
docker run -d --name "$database_container" --network "$network" \
  --network-alias database \
  -e POSTGRES_USER=cympho \
  -e POSTGRES_PASSWORD=cympho-container-test \
  -e POSTGRES_DB=cympho \
  postgres:16-alpine >/dev/null

i=0
until docker exec "$database_container" pg_isready -U cympho -d cympho -q; do
  i=$((i + 1))
  if [ "$i" -ge 60 ]; then
    echo "FAIL: Postgres did not become ready for the container smoke test" >&2
    exit 1
  fi
  sleep 1
done

set -- \
  -e APP_HOST=localhost \
  -e PREVIEW_HOST=preview.localhost \
  -e CYMPHO_FORCE_SSL=false \
  -e CYMPHO_RESOURCE_PROFILE=low \
  -e CYMPHO_IMPORT_SPOOL_DIR=/data/import-transfers \
  -e CYMPHO_UPLOADS_DIR=/data/uploads \
  -e DATABASE_URL=ecto://cympho:cympho-container-test@database:5432/cympho \
  -e SECRET_KEY_BASE=container_test_secret_key_base_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx \
  -e CYMPHO_ENCRYPTION_KEY=container-test-encryption-key-xx \
  -e CYMPHO_USER_JWT_SECRET=container-test-user-jwt-secret \
  -e CYMPHO_AGENT_JWT_SECRET=container-test-agent-jwt-secret \
  -e LIVE_VIEW_SALT=container-test-live-view-salt

docker run --rm --network "$network" "$@" "$image_tag" \
  bin/cympho eval 'Cympho.Release.migrate'

docker run -d --name "$app_container" --network "$network" \
  -p 127.0.0.1::4000 "$@" "$image_tag" >/dev/null

i=0
until docker exec "$app_container" \
  bin/cymphoctl readiness --expect-revision "$build_revision" >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -ge 60 ]; then
    docker logs "$app_container" >&2 || true
    echo "FAIL: release did not become ready at revision $build_revision" >&2
    exit 1
  fi
  sleep 1
done

published="$(docker port "$app_container" 4000/tcp | head -n 1)"
case "$published" in
  127.0.0.1:*) health_port=${published##*:} ;;
  *)
    echo "FAIL: Docker did not publish the app on loopback: $published" >&2
    exit 1
    ;;
esac

health_body="$(mktemp)"
health_canonical="$(mktemp)"
rm -f "$health_canonical"
curl --disable --silent --show-error --fail --max-time 10 \
  --header 'Accept: application/json' \
  --output "$health_body" \
  "http://127.0.0.1:$health_port/api/health"
python3 "$context_dir/bin/cympho-health-validator" health \
  "$health_body" "$health_canonical" "$build_revision"
echo "PASS: published container readiness matches revision $build_revision"
