#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
source "$SCRIPT_DIR/manifest.conf"
source "$SCRIPT_DIR/lib/common.sh"

# wait -n (used below to notice a dying service) needs bash 4.3.
(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )) \
  || { err "bash >= 4.3 required (found ${BASH_VERSION})"; exit 1; }

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

command -v docker >/dev/null || { err "docker not found on PATH"; exit 1; }

if ! docker compose -f "$SCRIPT_DIR/docker-compose.yml" ps -q | grep -q .; then
  err "Simulator/GUI stack doesn't look like it's running."
  err "Start it once with: ./docker-ctl.sh up"
  exit 1
fi

mkdir -p "$LOG_DIR"

# Ctrl-C in parallel mode would otherwise orphan the background
# services, which keep holding ports 10001-10003 so the next run fails
# with "address already in use".
#
# Job control is enabled while services start so each one leads its own
# process group; we then signal that group rather than the pid, because
# a service is `script` wrapping the real command and a bare TERM to the
# subshell never reaches it.
JOB_PIDS=()

cleanup_jobs() {
  local pid
  for pid in "${JOB_PIDS[@]:-}"; do
    # `|| true`: a service that already exited has no process group left
    # to signal, and under `set -e` that failure would abandon the rest.
    [ -n "$pid" ] && kill -TERM -"$pid" 2>/dev/null || true
  done
}

trap 'trap - INT TERM; cleanup_jobs; kill -TERM $$ 2>/dev/null; wait' INT TERM

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
  local statusfile="$LOG_DIR/.${folder}.status"
  rm -f "$statusfile"
  (
    cd "$SCRIPT_DIR/$folder"
    # `set -e` + pipefail would abort this subshell the moment script
    # exits non-zero, before the status is recorded.
    set +e
    script -qefc "$cmd" "$logfile" | while IFS= read -r line; do
      printf "\033[1;%sm[%s]\033[0m %s\n" "$color" "$folder" "$line"
    done
    rc=${PIPESTATUS[0]}
    set -e
    # `wait -n` doesn't say which job it reaped, so each one records its
    # own exit status for the stage loop to read back.
    printf '%s' "$rc" > "$statusfile"
    exit "$rc"
  ) &
}

# Name of the first service in this stage that reported a non-zero exit.
failed_service() {
  local name statusfile
  for name in "${names[@]}"; do
    statusfile="$LOG_DIR/.${name}.status"
    if [ -f "$statusfile" ] && [ "$(cat "$statusfile" 2>/dev/null)" != "0" ]; then
      printf '%s' "$name"
      return 0
    fi
  done
  return 1
}

run_stage() {
  local stage="$1"
  local -a pids=()
  local -a names=()
  local color_idx=0

  IFS=';' read -ra items <<< "$stage"
  set -m   # each background service becomes its own process group leader
  for item in "${items[@]}"; do
    IFS='|' read -r folder cmd <<< "$item"
    local color="${COLORS[$((color_idx % ${#COLORS[@]}))]}"
    color_idx=$((color_idx + 1))
    log "==> Starting $folder: $cmd  (logs/${folder}.log)"
    run_item_parallel "$folder" "$cmd" "$color"
    pids+=("$!")
    JOB_PIDS+=("$!")
    names+=("$folder")
  done
  set +m   # groups are assigned; silence job-control notifications

  # wait -n so a dying service is noticed immediately, instead of the
  # surviving ones holding the stage open indefinitely.
  local remaining=${#pids[@]}
  while [ "$remaining" -gt 0 ]; do
    wait -n || true
    remaining=$((remaining - 1))

    if failed_name=$(failed_service); then
      err "${failed_name} exited with an error (see logs/${failed_name}.log)"
      err "Stopping the rest of the stage"
      cleanup_jobs
      wait 2>/dev/null
      exit 1
    fi
  done
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
