#!@shell@ -e
# shellcheck shell=bash

export PATH="@binPath@:$PATH"

MIN_AGE_SEC="@minAgeSec@"
POKE_TIMEOUT="@pokeTimeoutSec@"
MAX_STUCK_PER_FILE="@maxStuckPerFile@"
INTERVAL_SEC="@intervalSec@"
MIN_POKE_INTERVAL_SEC="@minPokeIntervalSec@"
LOCK_DIR="/tmp/ffprobe-monitor-locks"
RATE_LIMIT_DIR="/tmp/ffprobe-monitor-poked"
CACHE_TTL_SEC="3600"

mkdir -p "$LOCK_DIR" "$RATE_LIMIT_DIR"

cleanup_old_data() {
  local cutoff
  cutoff=$(($(date +%s) - CACHE_TTL_SEC))
  find "$RATE_LIMIT_DIR" -type f -not -newermt "@$cutoff" -delete 2>/dev/null || true
  find "$LOCK_DIR" -type f -not -newermt "@$cutoff" -delete 2>/dev/null || true
}

extract_input_path() {
  local cmdline_file="$1"
  local prev_arg=""
  local last_arg=""
  local found_i=""
  while IFS= read -r -d "" arg || [ -n "$arg" ]; do
    if [ "$prev_arg" = "-i" ] && [ -n "$arg" ]; then
      found_i="$arg"
    fi
    if [ -n "$arg" ]; then
      last_arg="$arg"
    fi
    prev_arg="$arg"
  done < "$cmdline_file"
  if [ -n "$found_i" ] && [ -f "$found_i" ]; then
    printf '%s' "$found_i"
    return
  fi
  case "$last_arg" in
    -*) printf "" ;;
    *)  printf '%s' "$last_arg" ;;
  esac
}

get_file_id() {
  printf '%s' "$1" | md5sum | cut -d' ' -f1
}

{
  renice -n 19 -p $$ 2>/dev/null || true
  ionice -c 3 -p $$ 2>/dev/null || true
} >/dev/null 2>&1

logger -t ffprobe-monitor "Starting ffprobe monitor (Safety Valve mode)..."

while true; do
  declare -A file_stuck_count
  declare -A file_path_map

  # 1. Inventory all currently stuck ffprobe processes
  while read -r pid state age; do
    [ -z "$pid" ] && continue
    [ "$state" != "D" ] && continue
    [ "$age" -lt "$MIN_AGE_SEC" ] && continue

    fpath=$(extract_input_path "/proc/$pid/cmdline")
    if [ -n "$fpath" ] && [ -f "$fpath" ]; then
      fid=$(get_file_id "$fpath")
      file_stuck_count["$fid"]=$(( ${file_stuck_count["$fid"]:-0} + 1 ))
      file_path_map["$fid"]="$fpath"
    fi
  done < <(ps -C ffprobe -o pid=,state=,etimes= 2>/dev/null || true)

  # 2. Process stuck files
  for fid in "${!file_stuck_count[@]}"; do
    count=${file_stuck_count[$fid]}
    fpath=${file_path_map[$fid]}

    if [ "$count" -ge "$MAX_STUCK_PER_FILE" ]; then
      logger -t ffprobe-monitor "ALERT: Deadlock detected on file: $fpath ($count probes stuck in D state). SUGGESTION: Replace or delete this file to resolve the hang."
    else
      poke_file="$RATE_LIMIT_DIR/$fid"
      now=$(date +%s)
      last_poke=$(cat "$poke_file" 2>/dev/null || echo 0)

      if [ "$((now - last_poke))" -ge "$MIN_POKE_INTERVAL_SEC" ]; then
        logger -t ffprobe-monitor "Poking stuck ffprobe for: $fpath (count=$count, age>=${MIN_AGE_SEC}s)"
        timeout "$POKE_TIMEOUT" ffprobe -loglevel error -probesize 32 -show_format "$fpath" >/dev/null 2>&1 &
        printf '%s' "$now" > "$poke_file"
      fi
    fi
  done

  cleanup_old_data
  sleep "$INTERVAL_SEC"
done
