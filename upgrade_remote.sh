#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRET_FILE="${SCRIPT_DIR}/.deploy_remote.local"
REMOTE_COMPOSE="docker-compose.yml"
REMOTE_OVERRIDE="docker-compose.deploy.yml"
LOCAL_IMAGE_REPOSITORY="openmaic"
LOCAL_HTTP_PROXY="${LOCAL_HTTP_PROXY:-}"
COLIMA_PROFILE_ACTIVE=0
DOCKER_CONTEXT=""
LOCAL_IMAGE_CREATED=0
TMP_DIR=""
IMAGE_TAG=""

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

log_duration() {
  local label="$1"
  local started_at="$2"
  log "${label} completed in $((SECONDS - started_at))s."
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM

  if [[ "${LOCAL_IMAGE_CREATED}" == "1" && -n "${DOCKER_CONTEXT}" ]] && \
    docker --context "${DOCKER_CONTEXT}" info >/dev/null 2>&1; then
    log "Removing the local deployment image..."
    docker --context "${DOCKER_CONTEXT}" image rm -f "${IMAGE_TAG}" >/dev/null 2>&1 || true
  fi

  if [[ "${COLIMA_PROFILE_ACTIVE}" == "1" ]]; then
    # Stop the dedicated VM to release CPU and memory, but retain its disk and
    # BuildKit cache. Delete it manually with: colima delete "${COLIMA_PROFILE}"
    log "Stopping the ${COLIMA_PROFILE} Colima build VM (cache retained)..."
    colima stop "${COLIMA_PROFILE}" >/dev/null 2>&1 || true
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
COLIMA_PROFILE="${COLIMA_PROFILE:-openmaic-deploy}"
COLIMA_CPU="${COLIMA_CPU:-6}"
COLIMA_MEMORY_GB="${COLIMA_MEMORY_GB:-12}"
COLIMA_DISK_GB="${COLIMA_DISK_GB:-30}"
ALPINE_MIRROR="${ALPINE_MIRROR:-mirrors.tuna.tsinghua.edu.cn}"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com}"
DEPLOY_FORCE_REBUILD="${DEPLOY_FORCE_REBUILD:-0}"
# This script exposes port 3000 directly unless a TLS proxy is configured.
# Keep 0 for plain HTTP; set 1 when HTTPS terminates in front of the app.
REMOTE_COOKIE_SECURE="${REMOTE_COOKIE_SECURE:-0}"

command -v git >/dev/null || fail 'git is required'
command -v sshpass >/dev/null || fail 'sshpass is required'
command -v ssh >/dev/null || fail 'ssh is required'

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
[[ "${REMOTE_COOKIE_SECURE}" == '0' || "${REMOTE_COOKIE_SECURE}" == '1' ]] || fail 'REMOTE_COOKIE_SECURE must be 0 (HTTP) or 1 (HTTPS)'
[[ "${DEPLOY_FORCE_REBUILD}" == '0' || "${DEPLOY_FORCE_REBUILD}" == '1' ]] || fail 'DEPLOY_FORCE_REBUILD must be 0 or 1'
[[ -n "${COLIMA_PROFILE}" ]] || fail 'COLIMA_PROFILE must not be empty'

SHORT_COMMIT="$(git rev-parse --short=12 "${LOCAL_COMMIT}")"
IMAGE_TAG="${LOCAL_IMAGE_REPOSITORY}:deploy-${SHORT_COMMIT}"
image_tag_q=$(printf '%q' "${IMAGE_TAG}")

REMOTE_IMAGE_EXISTS=0
if [[ "${DEPLOY_FORCE_REBUILD}" == '0' ]] && \
  "${SSH_BASE[@]}" "docker image inspect ${image_tag_q} >/dev/null 2>&1"; then
  REMOTE_IMAGE_EXISTS=1
  log "Remote image ${IMAGE_TAG} already exists; skipping the local build and upload."
fi

if [[ "${REMOTE_IMAGE_EXISTS}" == '0' ]]; then
  command -v gzip >/dev/null || fail 'gzip is required'
  command -v tar >/dev/null || fail 'tar is required'
  command -v docker >/dev/null || fail 'Docker CLI is required (brew install docker docker-buildx)'
  command -v colima >/dev/null || fail 'Colima is required for the dedicated deployment builder (brew install colima)'
  docker buildx version >/dev/null 2>&1 || fail 'docker-buildx is required and must be registered as a Docker CLI plugin'

  source_started_at=${SECONDS}
  log "Preparing source archive for ${LOCAL_COMMIT}..."
  TMP_DIR="$(mktemp -d /tmp/openmaic-upgrade.XXXXXX)"
  mkdir -p "${TMP_DIR}/source"
  git archive "${LOCAL_COMMIT}" | tar -x -C "${TMP_DIR}/source"
  # The repository syntax directive normally downloads a Dockerfile frontend.
  # The bundled BuildKit frontend supports the features used here, so removing
  # the directive avoids an extra proxy-sensitive network request.
  tail -n +2 "${TMP_DIR}/source/Dockerfile" > "${TMP_DIR}/Dockerfile"
  log_duration 'Source preparation' "${source_started_at}"

  if [[ "${COLIMA_PROFILE}" == 'default' ]]; then
    DOCKER_CONTEXT='colima'
  else
    DOCKER_CONTEXT="colima-${COLIMA_PROFILE}"
  fi

  log "Starting the dedicated ${COLIMA_PROFILE} Colima VM (${COLIMA_CPU} CPU, ${COLIMA_MEMORY_GB} GiB RAM)..."
  proxy_env=()
  if [[ -n "${LOCAL_HTTP_PROXY}" ]]; then
    proxy_env=(
      "http_proxy=${LOCAL_HTTP_PROXY}"
      "https_proxy=${LOCAL_HTTP_PROXY}"
      "HTTP_PROXY=${LOCAL_HTTP_PROXY}"
      "HTTPS_PROXY=${LOCAL_HTTP_PROXY}"
    )
  fi
  env "${proxy_env[@]}" colima start "${COLIMA_PROFILE}" \
    --activate=false \
    --runtime docker \
    --arch x86_64 \
    --cpu "${COLIMA_CPU}" \
    --memory "${COLIMA_MEMORY_GB}" \
    --disk "${COLIMA_DISK_GB}" \
    --vm-type vz
  COLIMA_PROFILE_ACTIVE=1

  docker --context "${DOCKER_CONTEXT}" info >/dev/null 2>&1 || fail "Docker context ${DOCKER_CONTEXT} is not available"
  docker --context "${DOCKER_CONTEXT}" buildx version >/dev/null 2>&1 || fail 'docker-buildx is not available for the deployment context'

  pull_started_at=${SECONDS}
  log 'Pulling the Docker build base image...'
  docker --context "${DOCKER_CONTEXT}" pull node:22-alpine
  log_duration 'Base-image pull' "${pull_started_at}"

  build_started_at=${SECONDS}
  log "Building ${IMAGE_TAG} locally..."
  docker --context "${DOCKER_CONTEXT}" buildx build \
    --load \
    --pull=false \
    --progress=plain \
    --build-arg "ALPINE_MIRROR=${ALPINE_MIRROR}" \
    --build-arg "NPM_REGISTRY=${NPM_REGISTRY}" \
    --build-arg NEXT_PUBLIC_PERSISTENCE=1 \
    -f "${TMP_DIR}/Dockerfile" \
    -t "${IMAGE_TAG}" \
    "${TMP_DIR}/source"
  LOCAL_IMAGE_CREATED=1
  log_duration 'Image build' "${build_started_at}"

  image_arch="$(docker --context "${DOCKER_CONTEXT}" image inspect "${IMAGE_TAG}" --format '{{.Architecture}}')"
  [[ "${image_arch}" == 'amd64' ]] || fail "Expected an amd64 image, got ${image_arch}"

  upload_started_at=${SECONDS}
  log "Uploading ${IMAGE_TAG} to ${SSH_HOST}..."
  docker --context "${DOCKER_CONTEXT}" save "${IMAGE_TAG}" | gzip -1 | "${SSH_BASE[@]}" 'gunzip | docker load'
  log_duration 'Image upload' "${upload_started_at}"
fi

remote_cookie_secure_q=$(printf '%q' "${REMOTE_COOKIE_SECURE}")
deploy_started_at=${SECONDS}
log 'Updating the resource-limited Docker Compose override and recreating the services...'
"${SSH_BASE[@]}" <<EOF
set -Eeuo pipefail
cd ${remote_dir_q}

cat > ${remote_override_q} <<'YAML'
services:
  openmaic:
    image: \${OPENMAIC_IMAGE}
    environment:
      COOKIE_SECURE: "\${COOKIE_SECURE:-0}"
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
pgpass="\$(sed -n 's/^PERSISTENCE_POSTGRES_PASSWORD=//p' .env.local | tail -1)"
test -n "\${pgpass}"

# Keep Compose's PostgreSQL initialization value synchronized with the runtime
# DATABASE_URL credentials. POSTGRES_PASSWORD does not rotate an existing
# database volume, so the role itself is synchronized below after PostgreSQL is
# healthy and before the application is recreated.
env_tmp="\$(mktemp .env.deploy.XXXXXX)"
if [ -f .env ]; then
  grep -Ev '^(PERSISTENCE_POSTGRES_PASSWORD|NEXT_PUBLIC_PERSISTENCE)=' .env > "\${env_tmp}" || true
fi
printf 'PERSISTENCE_POSTGRES_PASSWORD=%s\\nNEXT_PUBLIC_PERSISTENCE=1\\n' "\${pgpass}" >> "\${env_tmp}"
chmod 600 "\${env_tmp}"
mv "\${env_tmp}" .env

previous_image="\$(docker inspect -f '{{.Config.Image}}' openmaic-openmaic-1 2>/dev/null || true)"
export OPENMAIC_IMAGE=${image_tag_q}
export COOKIE_SECURE=${remote_cookie_secure_q}
export PERSISTENCE_POSTGRES_PASSWORD="\${pgpass}"

rollback_and_exit() {
  local reason="$1"
  echo "\${reason}" >&2
  docker logs --tail 150 openmaic-openmaic-1 >&2 || true
  if [ -n "\${previous_image}" ] && docker image inspect "\${previous_image}" >/dev/null 2>&1; then
    echo "Rolling back to \${previous_image}..." >&2
    export OPENMAIC_IMAGE="\${previous_image}"
    docker compose -f ${remote_compose_q} -f ${remote_override_q} --profile server-persistence up -d --no-build --force-recreate openmaic
  fi
  exit 1
}

# Start PostgreSQL first. An existing data volume keeps the role password from
# its initial creation, even when POSTGRES_PASSWORD later changes.
docker compose -f ${remote_compose_q} -f ${remote_override_q} --profile server-persistence up -d --no-build postgres

pg_healthy=0
for attempt in \$(seq 1 60); do
  pg_health="\$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' openmaic-postgres-1 2>/dev/null || true)"
  if [ "\${pg_health}" = healthy ]; then
    pg_healthy=1
    break
  fi
  sleep 2
done
if [ "\${pg_healthy}" != 1 ]; then
  docker logs --tail 150 openmaic-postgres-1 >&2 || true
  exit 1
fi

# Use the local Unix socket, which is available to the database owner without
# the stale TCP password, to rotate the role safely without embedding it in SQL.
docker compose -f ${remote_compose_q} -f ${remote_override_q} --profile server-persistence \
  exec -T postgres psql -U openmaic -d openmaic -v ON_ERROR_STOP=1 -v role_password="\${pgpass}" <<'SQL'
SELECT format('ALTER ROLE %I PASSWORD %L', 'openmaic', :'role_password') \gexec
SQL

docker compose -f ${remote_compose_q} -f ${remote_override_q} --profile server-persistence \
  up -d --no-build --force-recreate openmaic

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
  rollback_and_exit 'The upgraded application did not become healthy.'
fi

# Confirm the runtime can authenticate to PostgreSQL, not only that the
# PostgreSQL healthcheck succeeds.
if ! docker exec -i openmaic-openmaic-1 node - <<'NODE'
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
then
  rollback_and_exit 'The application cannot authenticate to PostgreSQL with DATABASE_URL.'
fi

# Exercise the same path the browser uses: access-code verification, the
# resulting cookie, and the owner-scoped course listing backed by PostgreSQL.
# A /api/health response alone would pass even when both cookies and database
# access are broken.
smoke_dir="\$(mktemp -d)"
access_code_present="\$(docker exec openmaic-openmaic-1 node -e 'process.stdout.write(process.env.ACCESS_CODE ? "1" : "")')"
if [ -n "\${access_code_present}" ]; then
  verify_body="\$(docker exec openmaic-openmaic-1 node -e 'process.stdout.write(JSON.stringify({ code: process.env.ACCESS_CODE }))')"
  if ! curl -fsS --max-time 10 -D "\${smoke_dir}/headers" -o /dev/null \
    -c "\${smoke_dir}/cookies" -H 'Content-Type: application/json' \
    --data "\${verify_body}" http://127.0.0.1:3000/api/access-code/verify; then
    rm -rf "\${smoke_dir}"
    rollback_and_exit 'Access-code verification failed after deployment.'
  fi
  if [ "\${COOKIE_SECURE}" = '0' ] && grep -Eiq '^set-cookie:.*; Secure([;[:space:]]|$)' "\${smoke_dir}/headers"; then
    rm -rf "\${smoke_dir}"
    rollback_and_exit 'The access cookie is Secure while the deployment is served over plain HTTP; browsers will discard it.'
  fi
fi
if ! curl -fsS --max-time 10 -b "\${smoke_dir}/cookies" http://127.0.0.1:3000/api/stages \
  | docker exec -i openmaic-openmaic-1 node -e 'let body=""; process.stdin.setEncoding("utf8"); process.stdin.on("data", (chunk) => { body += chunk; }); process.stdin.on("end", () => { const parsed = JSON.parse(body); if (!parsed || !Array.isArray(parsed.stages)) process.exit(1); });'
then
  rm -rf "\${smoke_dir}"
  rollback_and_exit 'The authenticated persistence smoke test failed.'
fi
rm -rf "\${smoke_dir}"

docker compose -f ${remote_compose_q} -f ${remote_override_q} --profile server-persistence ps
docker stats --no-stream --format 'table {{.Name}}\\t{{.MemUsage}}\\t{{.MemPerc}}\\t{{.CPUPerc}}' openmaic-openmaic-1 openmaic-postgres-1
curl -fsS http://127.0.0.1:3000/api/health
printf '\\nUpgrade completed at commit %s.\\n' ${LOCAL_COMMIT}
EOF
log_duration 'Remote restart and verification' "${deploy_started_at}"

log "Upgrade completed successfully: ${LOCAL_COMMIT}"
