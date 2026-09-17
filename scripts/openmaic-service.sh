#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="${OPENMAIC_RUNTIME_DIR:-$PROJECT_ROOT/data/runtime}"
PID_FILE="${OPENMAIC_PID_FILE:-$RUNTIME_DIR/openmaic.pid}"
LOG_FILE="${OPENMAIC_LOG_FILE:-$RUNTIME_DIR/openmaic.log}"
PORT="${PORT:-3000}"
NODE_VERSION="${OPENMAIC_NODE_VERSION:-24.11.1}"
MODE="${OPENMAIC_MODE:-dev}"
START_TIMEOUT_SECONDS="${OPENMAIC_START_TIMEOUT_SECONDS:-90}"
OPENSSL_CONFIG="${OPENMAIC_OPENSSL_CONFIG:-$RUNTIME_DIR/openssl-compat.cnf}"

usage() {
  cat <<'EOF'
Usage: scripts/openmaic-service.sh {start|stop|restart|status}

Environment overrides:
  PORT                          HTTP port (default: 3000)
  OPENMAIC_MODE                 pnpm command to run: dev or start (default: dev)
  OPENMAIC_NODE_VERSION         nvm Node version (default: 24.11.1)
  OPENMAIC_RUNTIME_DIR          PID/log directory (default: data/runtime)
  OPENMAIC_START_TIMEOUT_SECONDS  Readiness timeout (default: 90)
  OPENMAIC_OPENSSL_CONFIG       OpenSSL compatibility config path
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

is_pid_alive() {
  [[ -n "${1:-}" ]] && kill -0 "$1" 2>/dev/null
}

read_pid_file() {
  [[ -f "$PID_FILE" ]] || return 0
  local pid
  pid="$(tr -d '[:space:]' <"$PID_FILE")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  printf '%s\n' "$pid"
}

port_pids() {
  lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true
}

pid_cwd() {
  lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1
}

belongs_to_project() {
  local pid="$1" cwd
  cwd="$(pid_cwd "$pid")"
  [[ "$cwd" == "$PROJECT_ROOT" || "$cwd" == "$PROJECT_ROOT/"* ]]
}

collect_process_tree() {
  local pid="$1" child
  printf '%s\n' "$pid"
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    collect_process_tree "$child"
  done < <(pgrep -P "$pid" 2>/dev/null || true)
}

terminate_process_trees() {
  local roots=("$@") pids
  [[ ${#roots[@]} -gt 0 ]] || return 0

  pids="$(
    for pid in "${roots[@]}"; do
      is_pid_alive "$pid" && collect_process_tree "$pid"
    done | awk '!seen[$0]++'
  )"
  [[ -n "$pids" ]] || return 0

  # Descendants are listed before parents by the collector; TERM the whole set.
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null || true

  local attempt
  for attempt in $(seq 1 50); do
    local alive=0
    for pid in $pids; do
      if is_pid_alive "$pid"; then
        alive=1
        break
      fi
    done
    [[ "$alive" -eq 0 ]] && return 0
    sleep 0.1
  done

  # shellcheck disable=SC2086
  kill -KILL $pids 2>/dev/null || true
}

load_runtime() {
  local nvm_sh="${NVM_DIR:-$HOME/.nvm}/nvm.sh"
  if [[ -s "$nvm_sh" ]]; then
    set +u
    # shellcheck disable=SC1090
    source "$nvm_sh"
    nvm use "$NODE_VERSION" >/dev/null
    set -u
  fi

  require_command node
  require_command pnpm

  if ! node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>22 || (a===22 && b>=19) ? 0 : 1)'; then
    die "Node >= 22.19 is required; active version is $(node --version)"
  fi
}

prepare_openssl_config() {
  mkdir -p "$RUNTIME_DIR"
  if [[ ! -f "$OPENSSL_CONFIG" ]]; then
    cat >"$OPENSSL_CONFIG" <<'EOF'
openssl_conf = openssl_init

[openssl_init]
ssl_conf = ssl_sect

[ssl_sect]
system_default = system_default_sect

[system_default_sect]
Options = UnsafeLegacyRenegotiation,UnsafeLegacyServerConnect
EOF
  fi
}

show_log_tail() {
  [[ -f "$LOG_FILE" ]] || return 0
  printf '\nLast log lines (%s):\n' "$LOG_FILE" >&2
  tail -n 40 "$LOG_FILE" >&2 || true
}

wait_for_health() {
  local pid="$1" attempt
  for attempt in $(seq 1 "$START_TIMEOUT_SECONDS"); do
    if ! is_pid_alive "$pid"; then
      show_log_tail
      return 1
    fi
    if curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  show_log_tail
  return 1
}

start_service() {
  require_command lsof
  require_command curl
  load_runtime
  prepare_openssl_config
  mkdir -p "$RUNTIME_DIR"

  local existing_pid
  existing_pid="$(read_pid_file)"
  if is_pid_alive "$existing_pid"; then
    if belongs_to_project "$existing_pid"; then
      printf 'OpenMAIC is already running (PID %s), %s\n' "$existing_pid" "http://localhost:$PORT"
      return 0
    fi
    die "PID file references a non-project process ($existing_pid); remove $PID_FILE after checking it"
  fi
  [[ -f "$PID_FILE" ]] && printf 'Removed stale PID file: %s\n' "$PID_FILE"
  rm -f "$PID_FILE"

  if [[ -n "$(port_pids)" ]]; then
    die "Port $PORT is already in use. Run scripts/stop-openmaic.sh first if it belongs to OpenMAIC"
  fi

  [[ "$MODE" == "dev" || "$MODE" == "start" ]] || die "OPENMAIC_MODE must be dev or start"
  [[ -f "$PROJECT_ROOT/.env.local" ]] || die "Missing $PROJECT_ROOT/.env.local"

  export HOSTNAME=0.0.0.0
  export PORT
  export NODE_OPTIONS="--openssl-config=$OPENSSL_CONFIG --openssl-shared-config ${NODE_OPTIONS:-}"

  printf 'Starting OpenMAIC in %s mode on 0.0.0.0:%s\n' "$MODE" "$PORT"
  python3 - "$PROJECT_ROOT" "$LOG_FILE" "$PID_FILE" "$MODE" <<'PY'
import os
import shutil
import subprocess
import sys

project_root, log_file, pid_file, mode = sys.argv[1:]
pnpm = shutil.which('pnpm')
if not pnpm:
    raise SystemExit('pnpm was not found after runtime selection')

with open(log_file, 'ab', buffering=0) as log:
    process = subprocess.Popen(
        [pnpm, 'run', mode],
        cwd=project_root,
        env=os.environ.copy(),
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=subprocess.STDOUT,
        close_fds=True,
        start_new_session=True,
    )

with open(pid_file, 'w', encoding='ascii') as handle:
    handle.write(f'{process.pid}\n')
PY

  local pid
  pid="$(read_pid_file)"
  [[ -n "$pid" ]] || die "Failed to write PID file: $PID_FILE"

  if ! wait_for_health "$pid"; then
    terminate_process_trees "$pid"
    rm -f "$PID_FILE"
    die "OpenMAIC failed to become ready within ${START_TIMEOUT_SECONDS}s"
  fi

  printf 'OpenMAIC started (PID %s)\n' "$pid"
  printf 'Local:  http://localhost:%s\n' "$PORT"
  printf 'LAN:    http://%s:%s\n' "$(ipconfig getifaddr en0 2>/dev/null || printf '<lan-ip>')" "$PORT"
  printf 'Log:    %s\n' "$LOG_FILE"
}

stop_service() {
  require_command lsof
  local roots=() pid

  pid="$(read_pid_file)"
  is_pid_alive "$pid" && roots+=("$pid")

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    if belongs_to_project "$pid"; then
      roots+=("$pid")
    else
      die "Port $PORT is owned by PID $pid in $(pid_cwd "$pid"), not this OpenMAIC checkout"
    fi
  done < <(port_pids)

  if [[ ${#roots[@]} -eq 0 ]]; then
    rm -f "$PID_FILE"
    printf 'OpenMAIC is not running on port %s\n' "$PORT"
    return 0
  fi

  printf 'Stopping OpenMAIC processes: %s\n' "${roots[*]}"
  terminate_process_trees "${roots[@]}"
  rm -f "$PID_FILE"

  if [[ -n "$(port_pids)" ]]; then
    die "Port $PORT is still in use after stopping OpenMAIC"
  fi
  printf 'OpenMAIC stopped\n'
}

status_service() {
  require_command lsof
  local pid
  pid="$(read_pid_file)"

  if is_pid_alive "$pid"; then
    printf 'OpenMAIC PID %s is running.\n' "$pid"
  else
    pid="$(port_pids | head -n 1)"
    if [[ -n "$pid" ]]; then
      printf 'A process is listening on port %s (PID %s), but no valid OpenMAIC PID file was found.\n' "$PORT" "$pid"
    else
      printf 'OpenMAIC is not running.\n'
      return 1
    fi
  fi

  if curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
    printf 'Health:  ok (http://localhost:%s/api/health)\n' "$PORT"
  else
    printf 'Health:  unavailable (http://localhost:%s/api/health)\n' "$PORT"
  fi
  [[ -f "$LOG_FILE" ]] && printf 'Log:     %s\n' "$LOG_FILE"
}

case "${1:-}" in
  start) start_service ;;
  stop) stop_service ;;
  restart)
    stop_service
    start_service
    ;;
  status) status_service ;;
  help | --help | -h | '') usage ;;
  *) usage >&2; exit 2 ;;
esac
