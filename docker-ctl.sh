#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

usage() {
  echo "Usage: $0 {up|down|status|restart}"
  echo "  up      - start simulator/GUI stack (no-op if already running)"
  echo "  down    - stop simulator/GUI stack"
  echo "  status  - show whether the stack is running"
  echo "  restart - down, then up (rarely needed - see note below)"
  exit 1
}

is_running() {
  docker compose -f "$COMPOSE_FILE" ps -q | grep -q .
}

case "${1:-}" in
  up)
    if is_running; then
      log "Simulator/GUI stack already running"
    else
      log "Starting simulator/GUI stack"
      docker compose -f "$COMPOSE_FILE" up -d
    fi
    ;;
  down)
    log "Stopping simulator/GUI stack"
    docker compose -f "$COMPOSE_FILE" down
    ;;
  status)
    if is_running; then
      log "Simulator/GUI stack is running"
    else
      log "Simulator/GUI stack is NOT running"
    fi
    ;;
  restart)
    # Note: the compose file uses network_mode: host, so only ever have one
    # instance up. Restarting isn't something you should need during normal
    # debugging of lynch/neonfc/rl-engine - only if the simulator itself
    # is misbehaving.
    log "Restarting simulator/GUI stack"
    docker compose -f "$COMPOSE_FILE" down
    docker compose -f "$COMPOSE_FILE" up -d
    ;;
  *)
    usage
    ;;
esac
