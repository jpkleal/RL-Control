#!/usr/bin/env bash
# campaign.sh - run measurement runs end to end: clean state, start the three
# services with the resource monitor, stop them safely, and store + export the
# artifacts of every run.
#
# Usage: ./campaign.sh --epochs N [--runs K] [--name NAME] [--interval S] [--export DIR]
#
#   --epochs N    epochs per run (required: a run ends when RL-Engine finishes them)
#   --runs K      number of independent runs (default 1)
#   --name NAME   campaign folder under campaigns/ (default: EXPERIMENT_TAG, else "untagged")
#   --interval S  resource sampling interval in seconds (default 60)
#   --export DIR  also copy each run's .tar.gz to DIR
#
# Each run k (k = 1..K):
#   1. cleans the state left by earlier runs (checkpoints, TensorBoard, models,
#      results - keeping versions.json and every symlink), so runs are independent;
#   2. starts LyNCh, then NeonFC-SSL, then RL-Engine (--epochs N), waiting for
#      each server port before starting the next, plus lib/monitor.sh;
#   3. waits for RL-Engine to finish; if any service dies earlier the run is
#      marked failed;
#   4. stops the services in their own process groups (INT, then TERM, then KILL);
#   5. stores the artifacts in campaigns/<name>/run-<k>/ and exports run-<k>.tar.gz.
# Ctrl-C (or TERM) stops the current run the same way and stores what exists.
#
# Requires: setup.sh already run, the docker stack up (./docker-ctl.sh up),
# Linux util-linux `script`, plus ps/pgrep/lsof/du/tar.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
source "$SCRIPT_DIR/manifest.conf"
source "$SCRIPT_DIR/lib/common.sh"
cd "$SCRIPT_DIR"

# Ports the services listen on (configs/neonfc.toml, LyNCh test_config.yaml).
LYNCH_PORT=10003     # LyNCh runner, used by RL-Engine
NEONFC_PORT=10002    # NeonFC event socket, used by LyNCh
PORT_WAIT=120        # seconds to wait for a port before giving up
# Shutdown escalation (seconds to wait after each signal).
GRACE_INT="${CAMPAIGN_GRACE_INT:-20}"
GRACE_TERM="${CAMPAIGN_GRACE_TERM:-10}"

EPOCHS=""; RUNS=1; NAME=""; INTERVAL=60; EXPORT_DIR=""

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --epochs)   EPOCHS="${2:-}"; shift 2 ;;
    --runs)     RUNS="${2:-}"; shift 2 ;;
    --name)     NAME="${2:-}"; shift 2 ;;
    --interval) INTERVAL="${2:-}"; shift 2 ;;
    --export)   EXPORT_DIR="${2:-}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) err "Unknown argument '$1'."; usage; exit 1 ;;
  esac
done

is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) [ "$1" -gt 0 ] ;; esac; }
is_int "$EPOCHS"   || { err "--epochs N is required (N > 0)."; exit 1; }
is_int "$RUNS"     || { err "--runs must be a positive integer."; exit 1; }
is_int "$INTERVAL" || { err "--interval must be a positive integer."; exit 1; }
[ -n "$NAME" ] || NAME="${EXPERIMENT_TAG:-}"
[ -n "$NAME" ] || NAME="untagged"
CAMPAIGN_DIR="$SCRIPT_DIR/campaigns/$NAME"

# --- preconditions -----------------------------------------------------------

command -v script >/dev/null 2>&1 || { err "'script' (util-linux) not found."; exit 1; }
command -v lsof   >/dev/null 2>&1 || { err "'lsof' not found."; exit 1; }
if ! docker compose -f "$SCRIPT_DIR/docker-compose.yml" ps -q | grep -q .; then
  err "Simulator/GUI stack is not running. Start it with: ./docker-ctl.sh up"
  exit 1
fi
[ -f shared/results/versions.json ] || { err "shared/results/versions.json missing - run ./setup.sh first."; exit 1; }
if ! grep -q '"pinned": true' shared/results/versions.json; then
  log "[warn] versions.json says the environment is NOT pinned to a tag (EXPERIMENT_TAG)."
fi

# Commands come from RUN_STAGES ("folder|cmd", ';'-separated).
LYNCH_CMD=""; NEONFC_CMD=""; ENGINE_CMD=""
for stage in "${RUN_STAGES[@]}"; do
  IFS=';' read -ra items <<< "$stage"
  for item in "${items[@]}"; do
    IFS='|' read -r folder cmd <<< "$item"
    case "$folder" in
      LyNCh) LYNCH_CMD="$cmd" ;;
      NeonFC-SSL) NEONFC_CMD="$cmd" ;;
      RL-Engine) ENGINE_CMD="$cmd" ;;
    esac
  done
done
for v in LYNCH_CMD NEONFC_CMD ENGINE_CMD; do
  [ -n "${!v}" ] || { err "RUN_STAGES has no command for ${v%_CMD}."; exit 1; }
done
case " $ENGINE_CMD " in *" --epochs "*) err "Remove --epochs from the RL-Engine command in RUN_STAGES; campaign.sh sets it."; exit 1 ;; esac

for k in $(seq 1 "$RUNS"); do
  d="$CAMPAIGN_DIR/$(printf 'run-%02d' "$k")"
  [ ! -e "$d" ] || { err "$d already exists - choose another --name or move it away."; exit 1; }
done
mkdir -p "$CAMPAIGN_DIR" "$LOG_DIR"
[ -z "$EXPORT_DIR" ] || mkdir -p "$EXPORT_DIR"

# --- process management ------------------------------------------------------

# Services are started with job control on, so each one leads its own process
# group and its whole tree (script -> poetry -> python -> NeonFC layer
# processes) can be signalled at once with kill -- -<pgid>. Job control is
# switched off again right after, which keeps bash's job notices quiet.

LYNCH_PID=""; NEONFC_PID=""; ENGINE_PID=""; MONITOR_PID=""
RUN_DIR=""; RUN_STATUS=""; INTERRUPTED=0

# start_service <folder> <cmd> : starts it as its own process group; PID in $!
# (not via $(...): a command substitution subshell would own the job instead).
start_service() {
  local folder="$1" cmd="$2"
  set -m
  ( cd "$SCRIPT_DIR/$folder" && exec script -qefc "$cmd" "$LOG_DIR/${folder}.log" ) \
    > /dev/null 2>&1 < /dev/null &
  set +m
}

alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }
group_alive() { [ -n "${1:-}" ] && kill -0 -- "-$1" 2>/dev/null; }

wait_port() { # <port> <pid> : wait until something listens on <port>, while <pid> lives
  local port="$1" pid="$2" t=0
  while [ "$t" -lt "$PORT_WAIT" ]; do
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && return 0
    alive "$pid" || return 1
    sleep 1; t=$((t + 1))
  done
  return 1
}

stop_group() { # <name> <pgid> : INT -> TERM -> KILL on the whole process group
  local name="$1" pg="$2" t
  group_alive "$pg" || return 0
  log "  stopping $name (pgid $pg)"
  for sig in INT TERM; do
    kill -s "$sig" -- "-$pg" 2>/dev/null || true
    if [ "$sig" = INT ]; then t="$GRACE_INT"; else t="$GRACE_TERM"; fi
    while [ "$t" -gt 0 ] && group_alive "$pg"; do sleep 1; t=$((t - 1)); done
    group_alive "$pg" || return 0
  done
  log "  [warn] $name did not exit, sending KILL"
  kill -s KILL -- "-$pg" 2>/dev/null || true
}

stop_all() {
  if [ -n "$MONITOR_PID" ]; then
    kill "$MONITOR_PID" 2>/dev/null || true; wait "$MONITOR_PID" 2>/dev/null || true
    MONITOR_PID=""
  fi
  # Trainer first (it may save a final checkpoint on INT), servers last.
  stop_group RL-Engine "$ENGINE_PID";  ENGINE_PID=""
  stop_group NeonFC-SSL "$NEONFC_PID"; NEONFC_PID=""
  stop_group LyNCh "$LYNCH_PID";       LYNCH_PID=""
  for p in "$LYNCH_PORT" "$NEONFC_PORT"; do
    if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
      log "  [warn] port $p is still in use after shutdown"
    fi
  done
}

# --- state, artifacts --------------------------------------------------------

clean_state() {
  # Training state (resume point, curves) - not the runs/training/current symlink.
  rm -rf RL-Engine/runs/training/checkpoints RL-Engine/runs/training/index.jsonl \
         RL-Engine/runs/tensorboard
  # Policies served to NeonFC (contents only; the shared dir and links stay).
  find shared/models -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  # Results of earlier runs, except the setup record.
  find shared/results -mindepth 1 -maxdepth 1 ! -name versions.json -exec rm -rf {} + 2>/dev/null || true
  rm -f "$LOG_DIR"/*.log "$LOG_DIR"/monitor*.csv
}

write_env() { # <file> : machine / software description for the report
  {
    echo "run=$(basename "$RUN_DIR")  epochs=$EPOCHS  status=$RUN_STATUS"
    echo "started=$1  finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "--- host"; uname -a
    (lscpu 2>/dev/null | grep -E 'Model name|^CPU\(s\)') || sysctl -n machdep.cpu.brand_string hw.ncpu 2>/dev/null || true
    (grep MemTotal /proc/meminfo 2>/dev/null) || sysctl -n hw.memsize 2>/dev/null || true
    (nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null) || echo "gpu: none detected"
    echo "--- software"
    "python${PYTHON_VERSION}" --version 2>&1 || true
    poetry --version 2>&1 || true
    docker --version 2>&1 || true
    (cd RL-Engine && poetry run python -c 'import torch; print("torch", torch.__version__)' 2>/dev/null) || true
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" images 2>/dev/null || true
  } > "$2"
}

collect_artifacts() { # <started>
  mkdir -p "$RUN_DIR/logs"
  cp shared/results/versions.json "$RUN_DIR/" 2>/dev/null || true
  cp shared/results/timing.jsonl "$RUN_DIR/" 2>/dev/null || true
  for f in shared/results/*/summaries.jsonl; do
    [ -e "$f" ] || continue
    mkdir -p "$RUN_DIR/summaries"
    cp "$f" "$RUN_DIR/summaries/$(basename "$(dirname "$f")").jsonl"
  done
  [ ! -d shared/results/archive ] || cp -R shared/results/archive "$RUN_DIR/archive"
  [ ! -d RL-Engine/runs/tensorboard ] || cp -R RL-Engine/runs/tensorboard "$RUN_DIR/tensorboard"
  cp "$LOG_DIR"/monitor*.csv "$RUN_DIR/" 2>/dev/null || true
  cp "$LOG_DIR"/*.log "$RUN_DIR/logs/" 2>/dev/null || true
  write_env "$1" "$RUN_DIR/env.txt"

  local tarball="$CAMPAIGN_DIR/$(basename "$RUN_DIR").tar.gz"
  tar -czf "$tarball" -C "$CAMPAIGN_DIR" "$(basename "$RUN_DIR")"
  [ -z "$EXPORT_DIR" ] || cp "$tarball" "$EXPORT_DIR/"
  log "  stored $RUN_DIR (+ $(basename "$tarball"))${EXPORT_DIR:+, exported to $EXPORT_DIR}"
}

on_signal() {
  INTERRUPTED=1
  log "==> Interrupted - stopping services safely"
  RUN_STATUS="interrupted"
  stop_all
  [ -z "$RUN_DIR" ] || collect_artifacts "${RUN_STARTED:-?}"
  exit 130
}
trap on_signal INT TERM
trap stop_all EXIT

# --- runs ----------------------------------------------------------------------

log "==> Campaign '$NAME': $RUNS run(s) x $EPOCHS epoch(s) -> campaigns/$NAME/"
for k in $(seq 1 "$RUNS"); do
  RUN_DIR="$CAMPAIGN_DIR/$(printf 'run-%02d' "$k")"
  RUN_STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  RUN_STATUS="failed"
  log "==> Run $k/$RUNS"

  clean_state
  echo "time_unix,service,n_procs,rss_kb,cpu_pct,threads,fds,sockets,checkpoints_kb" > "$LOG_DIR/monitor.csv"

  start_service LyNCh "$LYNCH_CMD"; LYNCH_PID=$!
  if wait_port "$LYNCH_PORT" "$LYNCH_PID"; then
    start_service NeonFC-SSL "$NEONFC_CMD"; NEONFC_PID=$!
    if wait_port "$NEONFC_PORT" "$NEONFC_PID"; then
      start_service RL-Engine "$ENGINE_CMD --epochs $EPOCHS"; ENGINE_PID=$!
      "$SCRIPT_DIR/lib/monitor.sh" "$INTERVAL" "$LOG_DIR/monitor.csv" "$$" \
        "$SCRIPT_DIR/RL-Engine/runs/training/checkpoints" \
        "LyNCh=$LYNCH_PID" "NeonFC-SSL=$NEONFC_PID" "RL-Engine=$ENGINE_PID" &
      MONITOR_PID=$!
      log "  services up (LyNCh $LYNCH_PID, NeonFC-SSL $NEONFC_PID, RL-Engine $ENGINE_PID), monitor every ${INTERVAL}s"

      # Wait for the trainer; a server dying first fails the run.
      while alive "$ENGINE_PID"; do
        if ! alive "$LYNCH_PID" || ! alive "$NEONFC_PID"; then
          err "  a server exited before RL-Engine finished (see logs/)"
          break
        fi
        sleep 2
      done
      if ! alive "$ENGINE_PID"; then
        if wait "$ENGINE_PID"; then RUN_STATUS="completed"; else RUN_STATUS="failed"; fi
      fi
    else
      err "  NeonFC-SSL did not open port $NEONFC_PORT (see logs/NeonFC-SSL.log)"
    fi
  else
    err "  LyNCh did not open port $LYNCH_PORT (see logs/LyNCh.log)"
  fi

  stop_all
  collect_artifacts "$RUN_STARTED"
  log "==> Run $k/$RUNS: $RUN_STATUS"
  RUN_DIR=""
  [ "$RUN_STATUS" = "completed" ] || { err "Stopping the campaign after a failed run."; exit 1; }
done

log "==> Campaign '$NAME' finished: campaigns/$NAME/"
