#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRET_FILE="${SCRIPT_DIR}/.deploy_remote.local"
REMOTE_COMPOSE="docker-compose.yml"
REMOTE_OVERRIDE="docker-compose.deploy.yml"
LOCAL_IMAGE_REPOSITORY="openmaic"
LOCAL_HTTP_PROXY="${LOCAL_HTTP_PROXY:-}"
COLIMA_STARTED_BY_SCRIPT=0
TMP_DIR=""
IMAGE_TAG=""

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM

  if [[ -n "${IMAGE_TAG}" ]] && docker info >/dev/null 2>&1; then
    log "Removing the local deployment image..."
    docker image rm -f "${IMAGE_TAG}" >/dev/null 2>&1 || true
  fi

  if [[ "${COLIMA_STARTED_BY_SCRIPT}" == "1" ]]; then
    # This VM is dedicated to the upgrade, so clearing all of its build data
    # cannot affect unrelated local containers, images, or volumes.
    log "Removing Docker build cache from the temporary Colima VM..."
    docker buildx prune -af >/dev/null 2>&1 || true
    docker system prune -af --volumes >/dev/null 2>&1 || true
    log "Stopping and deleting the temporary Colima build VM..."
    colima stop >/dev/null 2>&1 || true
    colima delete -f >/dev/null 2>&1 || true
    # Colima keeps the downloaded base image outside the VM. It is only a
    # disposable build dependency for this deployment workflow.
    if [[ -d "${HOME}/Library/Caches/colima" ]]; then
      find "${HOME}/Library/Caches/colima" -depth -delete 2>/dev/null || true
    fi
  fi

  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi

  exit "${exit_code}"
}
trap cleanup EXIT INT TERM

[[ -f "${SECRET_FILE}" ]] || fail "Missing ${SECRET_FILE}. Copy .deploy_remote.local.example and fill in the server connection settings."
# shellcheck source=/dev/null
source "${SECRET_FILE}"

: "${SSH_USER:?SSH_USER is required}"
: "${SSH_HOST:?SSH_HOST is required}"
: "${SSH_PASSWORD:?SSH_PASSWORD is required}"
: "${REMOTE_DIR:?REMOTE_DIR is required}"

GIT_REMOTE="${GIT_REMOTE:-upstream}"
GIT_BRANCH="${GIT_BRANCH:-main}"
COLIMA_CPU="${COLIMA_CPU:-6}"
COLIMA_MEMORY_GB="${COLIMA_MEMORY_GB:-12}"
COLIMA_DISK_GB="${COLIMA_DISK_GB:-30}"
ALPINE_MIRROR="${ALPINE_MIRROR:-mirrors.tuna.tsinghua.edu.cn}"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com}"

command -v git >/dev/null || fail 'git is required'
command -v sshpass >/dev/null || fail 'sshpass is required'
command -v ssh >/dev/null || fail 'ssh is required'
command -v gzip >/dev/null || fail 'gzip is required'
command -v tar >/dev/null || fail 'tar is required'
command -v docker >/dev/null || fail 'Docker CLI is required (brew install docker docker-buildx)'
command -v colima >/dev/null || fail 'Colima is required when no Docker daemon is running (brew install colima)'
docker buildx version >/dev/null 2>&1 || fail 'docker-buildx is required and must be registered as a Docker CLI plugin'

SSH_BASE=(sshpass -e ssh -T -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 "${SSH_USER}@${SSH_HOST}")
export SSHPASS="${SSH_PASSWORD}"

cd "${SCRIPT_DIR}"

# Pull on the server first, before any image build or container operation.
log "Pulling the application source on the server before deployment..."
remote_dir_q=$(printf '%q' "${REMOTE_DIR}")
remote_compose_q=$(printf '%q' "${REMOTE_COMPOSE}")
remote_override_q=$(printf '%q' "${REMOTE_OVERRIDE}")
"${SSH_BASE[@]}" <<EOF
set -Eeuo pipefail
cd ${remote_dir_q}
git pull --ff-only
printf 'Remote commit: '
git rev-parse HEAD
test -f ${remote_compose_q}
test -f .env.local
EOF
REMOTE_COMMIT="$("${SSH_BASE[@]}" "cd ${remote_dir_q} && git rev-parse HEAD")"

# Fetch the same revision locally without modifying the developer's current
# branch or including uncommitted files in the production image.
log "Fetching ${GIT_REMOTE}/${GIT_BRANCH} locally..."
git fetch "${GIT_REMOTE}" "${GIT_BRANCH}"
LOCAL_COMMIT="$(git rev-parse FETCH_HEAD)"
[[ "${LOCAL_COMMIT}" == "${REMOTE_COMMIT}" ]] || fail "Local and remote commits differ: local=${LOCAL_COMMIT}, remote=${REMOTE_COMMIT}"

SHORT_COMMIT="$(git rev-parse --short=12 "${LOCAL_COMMIT}")"
IMAGE_TAG="${LOCAL_IMAGE_REPOSITORY}:deploy-${SHORT_COMMIT}"
TMP_DIR="$(mktemp -d /tmp/openmaic-upgrade.XXXXXX)"
mkdir -p "${TMP_DIR}/source"
git archive "${LOCAL_COMMIT}" | tar -x -C "${TMP_DIR}/source"

if ! docker info >/dev/null 2>&1; then
  log "Starting a temporary local Colima VM (${COLIMA_CPU} CPU, ${COLIMA_MEMORY_GB} GiB RAM)..."
  proxy_env=()
  if [[ -n "${LOCAL_HTTP_PROXY}" ]]; then
    proxy_env=(
      "http_proxy=${LOCAL_HTTP_PROXY}"
      "https_proxy=${LOCAL_HTTP_PROXY}"
      "HTTP_PROXY=${LOCAL_HTTP_PROXY}"
      "HTTPS_PROXY=${LOCAL_HTTP_PROXY}"
    )
  fi
  env "${proxy_env[@]}" colima start \
    --runtime docker \
    --cpu "${COLIMA_CPU}" \
    --memory "${COLIMA_MEMORY_GB}" \
    --disk "${COLIMA_DISK_GB}" \
    --vm-type vz
  COLIMA_STARTED_BY_SCRIPT=1
fi

docker info >/dev/null 2>&1 || fail 'Docker daemon is not available'

# Pull serially because some authenticated company proxies limit concurrent
# CONNECT sessions. Removing the syntax directive then keeps BuildKit from
# re-fetching the Dockerfile frontend during the actual build.
log 'Pulling Docker build base images...'
docker pull docker/dockerfile:1
docker pull node:22-alpine
tail -n +2 "${TMP_DIR}/source/Dockerfile" > "${TMP_DIR}/Dockerfile"

log "Building ${IMAGE_TAG} locally..."
docker buildx build \
  --load \
  --pull=false \
  --progress=plain \
  --build-arg "ALPINE_MIRROR=${ALPINE_MIRROR}" \
  --build-arg "NPM_REGISTRY=${NPM_REGISTRY}" \
  --build-arg NEXT_PUBLIC_PERSISTENCE=1 \
  -f "${TMP_DIR}/Dockerfile" \
  -t "${IMAGE_TAG}" \
  "${TMP_DIR}/source"

image_arch="$(docker image inspect "${IMAGE_TAG}" --format '{{.Architecture}}')"
[[ "${image_arch}" == 'amd64' ]] || fail "Expected an amd64 image, got ${image_arch}"

log "Uploading ${IMAGE_TAG} to ${SSH_HOST}..."
docker save "${IMAGE_TAG}" | gzip -1 | "${SSH_BASE[@]}" 'gunzip | docker load'

image_tag_q=$(printf '%q' "${IMAGE_TAG}")
log 'Updating the resource-limited Docker Compose override and recreating the services...'
"${SSH_BASE[@]}" <<EOF
set -Eeuo pipefail
cd ${remote_dir_q}

cat > ${remote_override_q} <<'YAML'
services:
  openmaic:
    image: \${OPENMAIC_IMAGE}
    mem_limit: 768m
    mem_reservation: 256m
    cpus: 1.5
    pids_limit: 256
  postgres:
    mem_limit: 256m
    mem_reservation: 64m
    cpus: 0.5
    pids_limit: 128
    command:
      - postgres
      - -c
      - shared_buffers=32MB
      - -c
      - work_mem=2MB
      - -c
      - maintenance_work_mem=32MB
      - -c
      - max_connections=30
YAML

chmod 600 .env.local
if [ ! -f .env ]; then
  pgpass="\$(sed -n 's/^PERSISTENCE_POSTGRES_PASSWORD=//p' .env.local | tail -1)"
  test -n "\${pgpass}"
  printf 'PERSISTENCE_POSTGRES_PASSWORD=%s\\nNEXT_PUBLIC_PERSISTENCE=1\\n' "\${pgpass}" > .env
  chmod 600 .env
fi

previous_image="\$(docker inspect -f '{{.Config.Image}}' openmaic-openmaic-1 2>/dev/null || true)"
export OPENMAIC_IMAGE=${image_tag_q}

docker compose -f ${remote_compose_q} -f ${remote_override_q} --profile server-persistence up -d --no-build --force-recreate

healthy=0
for attempt in \$(seq 1 60); do
  app_status="\$(docker inspect -f '{{.State.Status}}' openmaic-openmaic-1 2>/dev/null || true)"
  pg_health="\$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' openmaic-postgres-1 2>/dev/null || true)"
  if [ "\${app_status}" = running ] && [ "\${pg_health}" = healthy ] && curl -fsS --max-time 5 http://127.0.0.1:3000/api/health >/dev/null; then
    healthy=1
    break
  fi
  sleep 2
done

if [ "\${healthy}" != 1 ]; then
  echo 'The upgraded application did not become healthy.' >&2
  docker logs --tail 150 openmaic-openmaic-1 >&2 || true
  if [ -n "\${previous_image}" ] && docker image inspect "\${previous_image}" >/dev/null 2>&1; then
    echo "Rolling back to \${previous_image}..." >&2
    export OPENMAIC_IMAGE="\${previous_image}"
    docker compose -f ${remote_compose_q} -f ${remote_override_q} --profile server-persistence up -d --no-build --force-recreate openmaic
  fi
  exit 1
fi

# Confirm the runtime can authenticate to PostgreSQL, not only that the
# PostgreSQL healthcheck succeeds.
docker exec -i openmaic-openmaic-1 node - <<'NODE'
const { Client } = require('pg');
const client = new Client({ connectionString: process.env.DATABASE_URL });
client.connect()
  .then(() => client.query('select current_database() db, current_user usr'))
  .then((result) => {
    console.log('PostgreSQL:', JSON.stringify(result.rows[0]));
    return client.end();
  })
  .catch((error) => {
    console.error(error.stack || error.message);
    process.exit(1);
  });
NODE

docker compose -f ${remote_compose_q} -f ${remote_override_q} --profile server-persistence ps
docker stats --no-stream --format 'table {{.Name}}\\t{{.MemUsage}}\\t{{.MemPerc}}\\t{{.CPUPerc}}' openmaic-openmaic-1 openmaic-postgres-1
curl -fsS http://127.0.0.1:3000/api/health
printf '\\nUpgrade completed at commit %s.\\n' ${LOCAL_COMMIT}
EOF

log "Upgrade completed successfully: ${LOCAL_COMMIT}"
