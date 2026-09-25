#!/usr/bin/env bash
# Start the dedicated server, keeping a raw console log next to tModLoader's own logs.

set -Eeuo pipefail

config_path="$1"
base_dir="$(dirname "${BASH_SOURCE[0]}")"
log_level="${TMOD_LOG_LEVEL:-normal}"
crash_log_lines="${TMOD_CRASH_LOG_LINES:-200}"
log_dir="/data/tModLoader/Logs"
script_caller="${TMOD_SCRIPT_CALLER:?TMOD_SCRIPT_CALLER is not set}"
raw_log="$log_dir/container-console.log"

mkdir -p "$log_dir"
if [[ -f "$raw_log" ]]; then
    mv -f "$raw_log" "$log_dir/container-console.previous.log"
fi

set +e
python3 "$base_dir/create_world.py" "$config_path" bash "$script_caller" \
    -server \
    -tmlsavedirectory /data/tModLoader \
    -steamworkshopfolder /data/steamMods/steamapps/workshop \
    -config "$config_path" \
    2>&1 | tee "$raw_log" | bash "$base_dir/log-filter.sh" "$log_level"
server_status="${PIPESTATUS[0]}"
set -e

if [[ "$server_status" != 0 && "$log_level" != debug && "$crash_log_lines" != 0 ]]; then
    printf '\n[!!] tModLoader failed; last %s raw console lines from %s:\n' "$crash_log_lines" "$raw_log" >&2
    tail -n "$crash_log_lines" "$raw_log" >&2
fi

exit "$server_status"
