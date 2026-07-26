#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
source "$SCRIPT_DIR/manifest.conf"
source "$SCRIPT_DIR/lib/common.sh"

# Colors cycled across services so each one's lines are visually distinct
# in the terminal. Log files themselves are plain text (no color codes).
COLORS=(32 34 33 35 36 31) # green, blue, yellow, magenta, cyan, red

usage() {
  echo "Usage: $0 [service]"
  echo "  (no args)  - run all stages from RUN_STAGES, in order"
  echo "               (services within a stage run in parallel, each with"
  echo "               its own colored prefix and its own log file under logs/)"
  echo "  <folder>   - run just that one service (e.g. $0 LyNCh)"
  echo
  echo "Available services:"
  for stage in "${RUN_STAGES[@]}"; do
    IFS=';' read -ra items <<< "$stage"
    for item in "${items[@]}"; do
      IFS='|' read -r folder cmd <<< "$item"
      echo "  - $folder  ($cmd)"
    done
  done
  echo
  echo "This script does NOT manage docker. Start the simulator/GUI stack"
  echo "separately and leave it running: ./docker-ctl.sh up"
}

if [ "${#RUN_STAGES[@]}" -eq 0 ]; then
  err "RUN_STAGES is empty in manifest.conf."
  exit 1
fi

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if ! command -v script >/dev/null 2>&1; then
  err "'script' is not installed (it's part of util-linux on Linux, usually"
  err "preinstalled - install with e.g. 'sudo apt install util-linux' if missing)."
  exit 1
fi

if ! docker compose -f "$SCRIPT_DIR/docker-compose.yml" ps -q | grep -q .; then
  err "Simulator/GUI stack doesn't look like it's running."
  err "Start it once with: ./docker-ctl.sh up"
  exit 1
fi

mkdir -p "$LOG_DIR"

# Single-service debug run: plain foreground output, still logged.
# Wrapped with `script` so the child process gets a real pseudo-terminal -
# without this, piping/logging its output turns stdout into a plain pipe,
# and any program that calls os.get_terminal_size() (or similar) directly
# will crash with "OSError: Inappropriate ioctl for device".
run_one() {
  local folder="$1" cmd="$2"
  local logfile="$LOG_DIR/${folder}.log"
  log "==> Running $folder: $cmd"
  log "    (also logging to logs/${folder}.log)"
  ( cd "$SCRIPT_DIR/$folder" && script -qefc "$cmd" "$logfile" )
}

# One entry within a parallel stage: colored prefix in the terminal,
# raw (unprefixed) output also captured to its own log file. `script -e`
# makes it exit with the child command's own exit status, so PIPESTATUS[0]
# below still reflects whether the actual command succeeded or failed.
run_item_parallel() {
  local folder="$1" cmd="$2" color="$3"
  local logfile="$LOG_DIR/${folder}.log"
  (
    cd "$SCRIPT_DIR/$folder"
    script -qefc "$cmd" "$logfile" | while IFS= read -r line; do
      printf "\033[1;%sm[%s]\033[0m %s\n" "$color" "$folder" "$line"
    done
    exit "${PIPESTATUS[0]}"
  ) &
}

run_stage() {
  local stage="$1"
  local -a pids=()
  local -a names=()
  local color_idx=0

  IFS=';' read -ra items <<< "$stage"
  for item in "${items[@]}"; do
    IFS='|' read -r folder cmd <<< "$item"
    local color="${COLORS[$((color_idx % ${#COLORS[@]}))]}"
    color_idx=$((color_idx + 1))
    log "==> Starting $folder: $cmd  (logs/${folder}.log)"
    run_item_parallel "$folder" "$cmd" "$color"
    pids+=("$!")
    names+=("$folder")
  done

  local failed=0
  for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then
      err "${names[$i]} exited with an error (see logs/${names[$i]}.log)"
      failed=1
    fi
  done

  if [ "$failed" -eq 1 ]; then
    err "Stage failed, stopping pipeline"
    exit 1
  fi
}

if [ -n "${1:-}" ]; then
  requested="$1"
  found=0
  for stage in "${RUN_STAGES[@]}"; do
    IFS=';' read -ra items <<< "$stage"
    for item in "${items[@]}"; do
      IFS='|' read -r folder cmd <<< "$item"
      if [ "$folder" = "$requested" ]; then
        run_one "$folder" "$cmd"
        found=1
        break 2
      fi
    done
  done
  if [ "$found" -eq 0 ]; then
    err "Unknown service '$requested'."
    usage
    exit 1
  fi
else
  for stage in "${RUN_STAGES[@]}"; do
    run_stage "$stage"
  done
  log "==> All processes finished"
fi
