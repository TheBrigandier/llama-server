#!/usr/bin/env bash
# Sample a llama-server deployment's cgroup and track running peaks.
#
#   ./memsample.sh <profile>          e.g. ./memsample.sh full-128k
#   UNIT=my-own.service ./memsample.sh whatever
#
# Tracks anon+shmem ("unreclaimable") plus memory.current and system-wide
# available RAM, writing a running summary to peaks-<profile>.txt next to
# this script. Runs until killed, or until the cgroup disappears.
#
# WHY anon+shmem AND NOT memory.current: the model's host-side weights live in
# shmem, and memory.current here is dominated by page cache from reading a
# 22GB GGUF under --no-mmap. `anon` alone hides the model (~0.5 GiB at rest vs
# 16.24 GiB real); `memory.current` overstates what a hard cap must clear.
# anon+shmem is the figure MemoryHigh/MemoryMax have to be sized against.
set -u

PROFILE="${1:?usage: memsample.sh <profile>   (or set UNIT=<unit>.service)}"
UNIT="${UNIT:-llama-server-${PROFILE}.service}"
INTERVAL="${INTERVAL:-2}"
CG="${CGROUP_PATH:-/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/app.slice/${UNIT}}"
OUT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/peaks-${PROFILE}.txt"

if [ ! -d "$CG" ]; then
  echo "cgroup not found: $CG" >&2
  echo "  Is $UNIT running? (systemctl --user status $UNIT)" >&2
  echo "  For a system-level unit or a different layout, set CGROUP_PATH." >&2
  exit 1
fi

PEAK_U=0; PEAK_C=0; MIN_AVAIL=99999999
printf "%-8s %9s %11s %10s %10s %9s\n" TIME ANON_GiB UNRECL_GiB CURR_GiB HIGH_EV AVAIL_Mi
while [ -d "$CG" ]; do
  A=$(awk '/^anon /{print $2}' "$CG/memory.stat" 2>/dev/null) || break
  [ -n "${A:-}" ] || break
  S=$(awk '/^shmem /{print $2}' "$CG/memory.stat")
  C=$(cat "$CG/memory.current")
  H=$(awk '/^high/{print $2}' "$CG/memory.events")
  U=$((A + S))
  AV=$(free -m | awk '/^Mem:/{print $7}')
  [ "$U" -gt "$PEAK_U" ] && PEAK_U=$U
  [ "$C" -gt "$PEAK_C" ] && PEAK_C=$C
  [ "$AV" -lt "$MIN_AVAIL" ] && MIN_AVAIL=$AV
  printf "%-8s %9.2f %11.2f %10.2f %10s %9s\n" "$(date +%H:%M:%S)" \
    "$(awk -v v="$A" 'BEGIN{print v/1073741824}')" \
    "$(awk -v v="$U" 'BEGIN{print v/1073741824}')" \
    "$(awk -v v="$C" 'BEGIN{print v/1073741824}')" "$H" "$AV"
  {
    awk -v u="$PEAK_U" -v c="$PEAK_C" -v m="$MIN_AVAIL" -v p="$PROFILE" 'BEGIN{
      printf "profile=%s peak_unreclaimable=%.2fGiB peak_current=%.2fGiB min_avail=%dMi\n",
             p, u/1073741824, c/1073741824, m}'
    echo "events: $(tr '\n' ' ' < "$CG/memory.events")"
    echo "swap.current: $(awk '{printf "%.2f GiB", $1/1073741824}' "$CG/memory.swap.current")"
  } > "$OUT"
  sleep "$INTERVAL"
done
