#!/usr/bin/env bash
#
# Upload only the local .env.local to an existing OpenMAIC deployment and
# recreate the application container so the new environment is loaded.
#
# This intentionally does not upload source code, data, or rebuild images.
# Build-time values such as NEXT_PUBLIC_* still require deploy-remote.sh.
#
# Usage:
#   OPENMAIC_DEPLOY_PASSWORD='...' ./scripts/update-remote-env.sh
#
# The SSH/deployment variables are the same as scripts/deploy-remote.sh:
#   OPENMAIC_DEPLOY_HOST, OPENMAIC_DEPLOY_USER, OPENMAIC_DEPLOY_SSH_PORT,
#   OPENMAIC_DEPLOY_DIR, OPENMAIC_DEPLOY_PORT,
#   OPENMAIC_DEPLOY_HEALTH_TIMEOUT_SECONDS, OPENMAIC_DEPLOY_ALLOW_LOOPBACK
#
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env.local"

SERVER_HOST="${OPENMAIC_DEPLOY_HOST:-192.169.6.239}"
SERVER_USER="${OPENMAIC_DEPLOY_USER:-root}"
SSH_PORT="${OPENMAIC_DEPLOY_SSH_PORT:-22}"
APP_PORT="${OPENMAIC_DEPLOY_PORT:-3000}"
REMOTE_DIR="${OPENMAIC_DEPLOY_DIR:-/opt/openmaic}"
SSH_PASSWORD="${OPENMAIC_DEPLOY_PASSWORD:-}"
HEALTH_TIMEOUT_SECONDS="${OPENMAIC_DEPLOY_HEALTH_TIMEOUT_SECONDS:-300}"
ALLOW_LOOPBACK="${OPENMAIC_DEPLOY_ALLOW_LOOPBACK:-0}"
NPM_PACKAGE_VERSION="${OPENMAIC_DEPLOY_NPM_PACKAGE_VERSION:-$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT_DIR/package.json" | head -n 1)}"

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
  local args=(-az --human-readable)
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
if [[ "$ALLOW_LOOPBACK" != "1" ]] && ! grep -Eq '^[[:space:]]*OPENMAIC_PUBLISH_ADDRESS[[:space:]]*=[[:space:]]*0\.0\.0\.0([[:space:]]*#.*)?$' "$ENV_FILE"; then
  die "OPENMAIC_PUBLISH_ADDRESS must be set to 0.0.0.0 in $ENV_FILE for direct remote access; use OPENMAIC_DEPLOY_ALLOW_LOOPBACK=1 only behind a reverse proxy"
fi
ACTIVE_MODEL_ROUTES="$(grep -E '^[[:space:]]*MODEL_ROUTES[[:space:]]*=' "$ENV_FILE" | tail -n 1 || true)"
[[ "$REMOTE_DIR" != *" "* ]] || die "OPENMAIC_DEPLOY_DIR must not contain spaces"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "OPENMAIC_DEPLOY_SSH_PORT must be a number"
[[ "$APP_PORT" =~ ^[0-9]+$ ]] || die "OPENMAIC_DEPLOY_PORT must be a number"
[[ "$HEALTH_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || die "OPENMAIC_DEPLOY_HEALTH_TIMEOUT_SECONDS must be a number"

require_command ssh
require_command rsync
if [[ -n "$SSH_PASSWORD" ]]; then
  require_command sshpass
elif ! command -v sshpass >/dev/null 2>&1; then
  log "No deployment password supplied; falling back to SSH keys/agent"
fi

# A fixed temporary filename prevents a partially uploaded .env.local from
# being consumed if rsync is interrupted. The remote command atomically moves
# it into place only after the upload has completed.
REMOTE_ENV_TMP=".env.local.update.$$"
REMOTE_ENV_PATH="$REMOTE_DIR/app/.env.local"
REMOTE_ENV_TMP_PATH="$REMOTE_DIR/app/$REMOTE_ENV_TMP"

cleanup_remote_tmp() {
  run_ssh "rm -f '$REMOTE_ENV_TMP_PATH'" >/dev/null 2>&1 || true
}
trap cleanup_remote_tmp EXIT

log "Checking remote OpenMAIC deployment"
run_ssh "set -e; command -v docker >/dev/null; docker compose version >/dev/null; command -v curl >/dev/null; test -f '$REMOTE_DIR/app/docker-compose.yml'; test -f '$REMOTE_DIR/app/scripts/docker-compose.deploy.yml'"

if [[ -n "$ACTIVE_MODEL_ROUTES" ]] && ! run_ssh "test -f '$REMOTE_DIR/app/openmaic.yml'"; then
  die "The local .env.local still sets MODEL_ROUTES, but the remote deployment has no openmaic.yml; remove MODEL_ROUTES or deploy a migrated openmaic.yml first"
fi

log "Uploading only .env.local to $SSH_TARGET:$REMOTE_ENV_TMP_PATH"
run_rsync "$ENV_FILE" "$SSH_TARGET:$REMOTE_ENV_TMP_PATH"

log "Activating the new runtime configuration"
run_ssh "set -e; install -m 600 '$REMOTE_ENV_TMP_PATH' '$REMOTE_ENV_PATH'; rm -f '$REMOTE_ENV_TMP_PATH'"

log "Recreating the OpenMAIC container without rebuilding or uploading application files"
run_ssh "set -e; cd '$REMOTE_DIR/app'; \
  NPM_PACKAGE_VERSION='$NPM_PACKAGE_VERSION' \
  COMPOSE_PROJECT_NAME=openmaic OPENMAIC_DATA_DIR='$REMOTE_DIR/data' \
  docker compose --env-file .env.local -f docker-compose.yml -f scripts/docker-compose.deploy.yml \
  up -d --no-build --force-recreate openmaic"

log "Waiting for http://127.0.0.1:$APP_PORT/api/health on the remote host"
deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  if health="$(run_ssh "curl -fsS --max-time 5 'http://127.0.0.1:$APP_PORT/api/health'" 2>/dev/null)"; then
    printf '%s\n' "$health"
    log "Runtime configuration update succeeded"
    exit 0
  fi
  sleep 3
done

run_ssh "cd '$REMOTE_DIR/app'; COMPOSE_PROJECT_NAME=openmaic OPENMAIC_DATA_DIR='$REMOTE_DIR/data' docker compose --env-file .env.local -f docker-compose.yml -f scripts/docker-compose.deploy.yml ps" || true
run_ssh "docker logs --tail 120 openmaic 2>&1 || docker logs --tail 120 openmaic-1 2>&1 || true" || true
die "Health check timed out after ${HEALTH_TIMEOUT_SECONDS}s"
