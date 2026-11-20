#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
source "$SCRIPT_DIR/manifest.conf"
source "$SCRIPT_DIR/lib/common.sh"

# Colors cycled across services so each one's lines are visually distinct
# in the terminal. Log files themselves are plain text (no color codes).
COLORS=(32 34 33 35 36 31) # green, blue, yellow, magenta, cyan, red

# Resource monitor (only with --monitor). Interval in seconds.
MONITOR=0
MONITOR_INTERVAL="${MONITOR_INTERVAL:-60}"
MONITOR_PID=""
MONITOR_HEADER="time_unix,service,n_procs,rss_kb,cpu_pct,threads,fds,sockets,checkpoints_kb"
CHECKPOINTS_DIR="$SCRIPT_DIR/RL-Engine/runs/training/checkpoints"

usage() {
  echo "Usage: $0 [service] [--monitor]"
  echo "  (no args)  - run all stages from RUN_STAGES, in order"
  echo "               (services within a stage run in parallel, each with"
  echo "               its own colored prefix and its own log file under logs/)"
  echo "  <folder>   - run just that one service (e.g. $0 LyNCh)"
  echo "  --monitor  - also sample CPU/memory/threads/fds/sockets of the"
  echo "               services every \$MONITOR_INTERVAL s (default 60) into"
  echo "               logs/monitor.csv (or logs/monitor_<folder>.csv)"
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

SERVICE=""
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --monitor) MONITOR=1 ;;
    -*) err "Unknown option '$arg'."; usage; exit 1 ;;
    *)
      if [ -n "$SERVICE" ]; then err "Only one service can be given."; usage; exit 1; fi
      SERVICE="$arg"
      ;;
  esac
done

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

# --- resource monitor helpers (no-ops unless --monitor) --------------------

# start_monitor <csv> <ckpt_dir|-> <name>=<pid>...  (background, sets MONITOR_PID)
start_monitor() {
  [ "$MONITOR" -eq 1 ] || return 0
  local csv="$1" ckpt="$2"; shift 2
  "$SCRIPT_DIR/lib/monitor.sh" "$MONITOR_INTERVAL" "$csv" "$$" "$ckpt" "$@" &
  MONITOR_PID=$!
  log "==> Monitor started (every ${MONITOR_INTERVAL}s -> logs/$(basename "$csv"))"
}

stop_monitor() {
  if [ -n "$MONITOR_PID" ]; then
    kill "$MONITOR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
    MONITOR_PID=""
  fi
}

# The monitor never outlives run.sh: stopped on normal exit, error, Ctrl-C or
# TERM here, and it also exits by itself if this process disappears (kill -9).
trap stop_monitor EXIT
trap 'stop_monitor; exit 130' INT
trap 'stop_monitor; exit 143' TERM

new_monitor_csv() { echo "$MONITOR_HEADER" > "$1"; }

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
  if [ "$MONITOR" -eq 1 ]; then
    # The service stays in the foreground (so Ctrl-C still reaches it); the
    # monitor samples run.sh's descendants other than itself instead.
    local csv="$LOG_DIR/monitor_${folder}.csv" ckpt="-"
    new_monitor_csv "$csv"
    [ "$folder" = "RL-Engine" ] && ckpt="$CHECKPOINTS_DIR"
    start_monitor "$csv" "$ckpt" "${folder}=children:$$"
  fi
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

  if [ "$MONITOR" -eq 1 ]; then
    local -a specs=()
    local ckpt="-"
    for i in "${!pids[@]}"; do
      specs+=("${names[$i]}=${pids[$i]}")
      [ "${names[$i]}" = "RL-Engine" ] && ckpt="$CHECKPOINTS_DIR"
    done
    start_monitor "$LOG_DIR/monitor.csv" "$ckpt" "${specs[@]}"
  fi

  local failed=0
  for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then
      err "${names[$i]} exited with an error (see logs/${names[$i]}.log)"
      failed=1
    fi
  done
  stop_monitor

  if [ "$failed" -eq 1 ]; then
    err "Stage failed, stopping pipeline"
    exit 1
  fi
}

if [ -n "$SERVICE" ]; then
  requested="$SERVICE"
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
  [ "$MONITOR" -eq 1 ] && new_monitor_csv "$LOG_DIR/monitor.csv"
  for stage in "${RUN_STAGES[@]}"; do
    run_stage "$stage"
  done
  log "==> All processes finished"
fi
