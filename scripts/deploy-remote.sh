#!/usr/bin/env bash
#
# Build and deploy OpenMAIC to a remote Docker host.
#
# Required local file:
#   .env.local
#
# Recommended invocation:
#   OPENMAIC_DEPLOY_PASSWORD='...' ./scripts/deploy-remote.sh
#
# If no password is supplied, the script uses the local SSH agent/key setup.
#
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"
OVERRIDE_FILE="$ROOT_DIR/scripts/docker-compose.deploy.yml"
ENV_FILE="$ROOT_DIR/.env.local"
DATA_DIR="$ROOT_DIR/data"

SERVER_HOST="${OPENMAIC_DEPLOY_HOST:-192.169.6.239}"
SERVER_USER="${OPENMAIC_DEPLOY_USER:-root}"
SSH_PORT="${OPENMAIC_DEPLOY_SSH_PORT:-22}"
APP_PORT="${OPENMAIC_DEPLOY_PORT:-3000}"
REMOTE_DIR="${OPENMAIC_DEPLOY_DIR:-/opt/openmaic}"
SSH_PASSWORD="${OPENMAIC_DEPLOY_PASSWORD:-}"
ALPINE_MIRROR="${OPENMAIC_DEPLOY_ALPINE_MIRROR:-mirrors.aliyun.com}"
NPM_REGISTRY="${OPENMAIC_DEPLOY_NPM_REGISTRY:-https://registry.npmmirror.com}"
COOKIE_SECURE="${OPENMAIC_DEPLOY_COOKIE_SECURE:-0}"
NPM_PACKAGE_VERSION="${OPENMAIC_DEPLOY_NPM_PACKAGE_VERSION:-$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT_DIR/package.json" | head -n 1)}"
HEALTH_TIMEOUT_SECONDS="${OPENMAIC_DEPLOY_HEALTH_TIMEOUT_SECONDS:-300}"

SSH_TARGET="${SERVER_USER}@${SERVER_HOST}"
SSH_OPTS=(
  -p "$SSH_PORT"
  -o ConnectTimeout=15
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=4
  -o StrictHostKeyChecking=accept-new
)

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

run_ssh() {
  if [[ -n "$SSH_PASSWORD" ]]; then
    SSHPASS="$SSH_PASSWORD" sshpass -e ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$@"
  else
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$@"
  fi
}

run_rsync() {
  local delete_mode="$1"
  shift
  local args=(-az --human-readable)
  if [[ "$delete_mode" == "delete" ]]; then
    args+=(--delete)
  fi
  if [[ -n "$SSH_PASSWORD" ]]; then
    SSHPASS="$SSH_PASSWORD" sshpass -e rsync "${args[@]}" \
      -e "ssh -p $SSH_PORT -o ConnectTimeout=15 -o ServerAliveInterval=30 -o StrictHostKeyChecking=accept-new" \
      "$@"
  else
    rsync "${args[@]}" \
      -e "ssh -p $SSH_PORT -o ConnectTimeout=15 -o ServerAliveInterval=30 -o StrictHostKeyChecking=accept-new" \
      "$@"
  fi
}

[[ -f "$ENV_FILE" ]] || die "Missing $ENV_FILE"
[[ -f "$COMPOSE_FILE" ]] || die "Missing $COMPOSE_FILE"
[[ -f "$OVERRIDE_FILE" ]] || die "Missing $OVERRIDE_FILE"
[[ "$REMOTE_DIR" != *" "* ]] || die "OPENMAIC_DEPLOY_DIR must not contain spaces"

require_command ssh
require_command rsync
if [[ -n "$SSH_PASSWORD" ]]; then
  require_command sshpass
elif ! command -v sshpass >/dev/null 2>&1; then
  log "No deployment password supplied; falling back to SSH keys/agent"
fi

log "Checking remote Docker and deployment directory"
run_ssh "set -e; command -v docker >/dev/null; docker compose version >/dev/null; mkdir -p '$REMOTE_DIR/app' '$REMOTE_DIR/data'"

log "Uploading application source to $SSH_TARGET:$REMOTE_DIR/app"
run_rsync delete \
  --exclude '.git/' \
  --exclude 'node_modules/' \
  --exclude '.next/' \
  --exclude 'data/' \
  --exclude '.env.local' \
  --exclude 'local-deploy.txt' \
  --exclude '*.pem' \
  --exclude '.DS_Store' \
  --exclude 'tsconfig.tsbuildinfo' \
  "$ROOT_DIR/" "$SSH_TARGET:$REMOTE_DIR/app/"

log "Uploading current runtime configuration"
run_rsync no-delete "$ENV_FILE" "$SSH_TARGET:$REMOTE_DIR/app/.env.local"
run_ssh "chmod 600 '$REMOTE_DIR/app/.env.local'"

log "Uploading classroom/application data"
for data_name in classrooms classroom-jobs usage; do
  if [[ -d "$DATA_DIR/$data_name" ]]; then
    mkdir -p "$DATA_DIR/$data_name"
    run_rsync no-delete "$DATA_DIR/$data_name/" "$SSH_TARGET:$REMOTE_DIR/data/$data_name/"
  fi
done
run_ssh "chown -R 1001:1001 '$REMOTE_DIR/data' && chmod -R u+rwX,g+rX,o-rwx '$REMOTE_DIR/data'"

log "Building and starting the Docker Compose service"
run_ssh "set -e; cd '$REMOTE_DIR/app'; \
  COMPOSE_PROJECT_NAME=openmaic DOCKER_BUILDKIT=1 OPENMAIC_DATA_DIR='$REMOTE_DIR/data' \
  ALPINE_MIRROR='$ALPINE_MIRROR' NPM_REGISTRY='$NPM_REGISTRY' COOKIE_SECURE='$COOKIE_SECURE' \
  NPM_PACKAGE_VERSION='$NPM_PACKAGE_VERSION' \
  docker compose --env-file .env.local -f docker-compose.yml -f scripts/docker-compose.deploy.yml \
  up -d --build openmaic"

log "Waiting for http://$SERVER_HOST:$APP_PORT/api/health"
deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  if health="$(curl -fsS --max-time 5 "http://$SERVER_HOST:$APP_PORT/api/health" 2>/dev/null)"; then
    printf '%s\n' "$health"
    log "Deployment succeeded: http://$SERVER_HOST:$APP_PORT"
    exit 0
  fi
  sleep 3
done

run_ssh "cd '$REMOTE_DIR/app'; COMPOSE_PROJECT_NAME=openmaic OPENMAIC_DATA_DIR='$REMOTE_DIR/data' docker compose --env-file .env.local -f docker-compose.yml -f scripts/docker-compose.deploy.yml ps"
run_ssh "docker logs --tail 120 openmaic 2>&1 || docker logs --tail 120 openmaic-1 2>&1 || true"
die "Health check timed out after ${HEALTH_TIMEOUT_SECONDS}s"
