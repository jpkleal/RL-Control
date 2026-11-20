#!/usr/bin/env bash
# monitor.sh - periodic resource sampler for the services started by run.sh.
#
# Usage: monitor.sh <interval_s> <csv_file> <watch_pid> <checkpoints_dir|-> <name>=<pid> ...
#
#   <name>=<pid>           sample the process tree rooted at <pid>
#   <name>=children:<pid>  sample the descendants of <pid> (not <pid> itself),
#                          excluding this monitor - used when the service runs
#                          in the foreground of run.sh and has no PID of its own
#
# Appends one CSV row per service per sample (the header is written by run.sh):
#   time_unix,service,n_procs,rss_kb,cpu_pct,threads,fds,sockets,checkpoints_kb
# plus one "_disk" row with the size of <checkpoints_dir> (unless it is "-").
#
# The first sample is taken immediately. The monitor exits on SIGTERM, or by
# itself as soon as <watch_pid> (run.sh) is gone, so it can't be orphaned.
# Compatible with bash 3.2 (macOS) and Linux. Needs ps, pgrep, lsof, du.

set -u
# C locale: decimal point in ps/awk output (a comma would split CSV fields).
export LC_ALL=C

interval="$1"; out="$2"; watch_pid="$3"; ckpt_dir="$4"; shift 4
services=("$@")

trap 'exit 0' TERM INT

# Thread count: Linux ps has nlwp; macOS lists one line per thread with -M.
if ps -o nlwp= -p $$ >/dev/null 2>&1; then
  threads_of() { ps -o nlwp= -p "$1" 2>/dev/null | tr -d ' '; }
else
  threads_of() { ps -M -p "$1" 2>/dev/null | tail -n +2 | wc -l | tr -d ' '; }
fi

# Prints <pid> and all of its descendants, one per line.
tree_of() {
  local p="$1" c
  echo "$p"
  for c in $(pgrep -P "$p" 2>/dev/null); do tree_of "$c"; done
}

# Prints the PIDs to sample for one service spec (pid or children:pid).
pids_for() {
  local spec="$1" root self
  case "$spec" in
    children:*)
      root="${spec#children:}"
      self="$(tree_of $$ | tr '\n' ' ')"
      for p in $(tree_of "$root"); do
        [ "$p" = "$root" ] && continue
        case " $self " in *" $p "*) continue ;; esac
        echo "$p"
      done
      ;;
    *)
      kill -0 "$spec" 2>/dev/null && tree_of "$spec"
      ;;
  esac
}

dead=" "

sample() {
  local now entry name spec pids list n rss cpu thr fds socks p
  now="$(date +%s)"
  for entry in "${services[@]}"; do
    name="${entry%%=*}"; spec="${entry#*=}"
    pids="$(pids_for "$spec" | tr '\n' ' ')"
    if [ -z "${pids// /}" ]; then
      # Record the drop once, then leave the service out of later samples.
      case "$dead" in *" $name "*) ;; *)
        echo "$now,$name,0,,,,,," >> "$out"; dead="$dead$name " ;;
      esac
      continue
    fi
    n=0; rss=0; cpu=0; thr=0
    for p in $pids; do
      set -- $(ps -o rss=,%cpu= -p "$p" 2>/dev/null) || true
      [ $# -ge 2 ] || continue
      n=$((n + 1))
      rss=$((rss + $1))
      cpu="$(awk -v a="$cpu" -v b="$2" 'BEGIN { printf "%.1f", a + b }')"
      t="$(threads_of "$p")"; thr=$((thr + ${t:-0}))
    done
    list="$(echo $pids | tr ' ' ',')"
    fds="$(lsof -nP -p "$list" -F f 2>/dev/null | grep -cE '^f[0-9]+' || true)"
    socks="$(lsof -nP -a -i -p "$list" -F f 2>/dev/null | grep -cE '^f[0-9]+' || true)"
    echo "$now,$name,$n,$rss,$cpu,$thr,$fds,$socks," >> "$out"
  done
  if [ "$ckpt_dir" != "-" ]; then
    local kb=""
    [ -d "$ckpt_dir" ] && kb="$(du -sk "$ckpt_dir" 2>/dev/null | cut -f1)"
    echo "$now,_disk,,,,,,,$kb" >> "$out"
  fi
}

while kill -0 "$watch_pid" 2>/dev/null; do
  sample
  # Sleep in 1 s steps so a vanished run.sh is noticed quickly.
  i=0
  while [ "$i" -lt "$interval" ]; do
    kill -0 "$watch_pid" 2>/dev/null || exit 0
    sleep 1
    i=$((i + 1))
  done
done
