#!/usr/bin/env bash
# Light supervisor: install tModLoader, sync mods, generate config, run server.

set -Eeuo pipefail

base_dir="/terraria-server"
runtime_dir="${TMOD_RUNTIME_DIR:-/tmp/tmodloader}"
control_pipe="${TMOD_CONTROL_PIPE:-$runtime_dir/console}"
pid_path="${TMOD_SERVER_PID_FILE:-$runtime_dir/server.pid}"
generated_config_path="$base_dir/serverconfig.txt"
custom_config_path="$base_dir/customconfig.txt"
config_path="$generated_config_path"
server_pid=""
autosave_pid=""
shutdown_requested=0

fail() {
    printf '[!!] FATAL: %s\n' "$*" >&2
    exit 1
}

reject_line_breaks() {
    if [[ "$2" == *$'\n'* || "$2" == *$'\r'* ]]; then
        fail "$1 cannot contain line breaks."
    fi
}

use_custom_config() {
    case "${TMOD_USECONFIGFILE,,}" in
        yes|true|1) return 0 ;;
        no|false|0) return 1 ;;
        *) fail "TMOD_USECONFIGFILE must be Yes/No, true/false, or 1/0." ;;
    esac
}

load_password_file() {
    [[ -n "${TMOD_PASS_FILE:-}" ]] || return 0
    [[ -r "$TMOD_PASS_FILE" ]] || fail "TMOD_PASS_FILE is not readable: $TMOD_PASS_FILE"
    TMOD_PASS="$(<"$TMOD_PASS_FILE")"
    export TMOD_PASS
}

ensure_writable_directory() {
    local path="$1" probe
    mkdir -p "$path" 2>/dev/null || fail "Cannot create $path as uid $(id -u). Check the mounted directory permissions."
    probe="$(mktemp "$path/.write-test.XXXXXX" 2>/dev/null)" || fail "$path is not writable as uid $(id -u). Check the mounted directory permissions."
    rm -f "$probe"
}

server_is_running() {
    [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null
}

stop_autosave() {
    if [[ -n "$autosave_pid" ]] && kill -0 "$autosave_pid" 2>/dev/null; then
        kill "$autosave_pid" 2>/dev/null || true
        wait "$autosave_pid" 2>/dev/null || true
    fi
    autosave_pid=""
}

signal_server_group() {
    [[ -n "$server_pid" ]] || return 0
    kill "-$1" -- "-$server_pid" 2>/dev/null || kill "-$1" "$server_pid" 2>/dev/null || true
}

wait_for_server_exit() {
    local deadline="$1"
    while server_is_running && ((SECONDS < deadline)); do
        sleep 0.25
    done
    ! server_is_running
}

shutdown() {
    ((shutdown_requested)) && return
    shutdown_requested=1
    trap '' TERM INT
    stop_autosave
    if server_is_running; then
        printf '[SYSTEM] Stop requested; saving the world and shutting down.\n'
        if [[ -n "${TMOD_SHUTDOWN_MESSAGE-}" ]]; then
            inject "say $TMOD_SHUTDOWN_MESSAGE" || true
        fi
        sleep "$((10#${TMOD_SHUTDOWN_DELAY:-3}))"
        inject "exit" || true
        if ! wait_for_server_exit "$((SECONDS + 10#${TMOD_SHUTDOWN_TIMEOUT:-90}))"; then
            printf '[!!] Graceful shutdown timed out; terminating the server process group.\n' >&2
            signal_server_group TERM
            wait_for_server_exit "$((SECONDS + 5))" || signal_server_group KILL
        fi
        wait "$server_pid" 2>/dev/null || true
        server_pid=""
    fi
    exit 0
}

cleanup() {
    stop_autosave
    if server_is_running; then
        signal_server_group KILL
        wait "$server_pid" 2>/dev/null || true
    fi
    if [[ -e "/proc/$$/fd/3" ]]; then
        exec 3>&-
    fi
    rm -f "$control_pipe" "$pid_path"
}

# --- Validation --------------------------------------------------------------
[[ "$(id -u)" != "0" ]] || fail "The server refuses to run as root. Use the image's built-in tml user."
reject_line_breaks TMOD_SHUTDOWN_MESSAGE "${TMOD_SHUTDOWN_MESSAGE-}"
reject_line_breaks TMOD_AUTOSAVE_MESSAGE "${TMOD_AUTOSAVE_MESSAGE-}"
[[ "${TMOD_SHUTDOWN_DELAY:-3}" =~ ^[0-9]{1,4}$ ]] || fail "TMOD_SHUTDOWN_DELAY must be a non-negative integer (seconds)."
[[ "${TMOD_SHUTDOWN_TIMEOUT:-90}" =~ ^[1-9][0-9]{0,4}$ ]] || fail "TMOD_SHUTDOWN_TIMEOUT must be a positive integer (seconds)."
[[ "${TMOD_AUTOSAVE_INTERVAL:-10}" =~ ^[0-9]+$ ]] || fail "TMOD_AUTOSAVE_INTERVAL must be a non-negative integer (minutes)."
TMOD_LOG_LEVEL="${TMOD_LOG_LEVEL:-normal}"
TMOD_LOG_LEVEL="${TMOD_LOG_LEVEL,,}"
case "$TMOD_LOG_LEVEL" in
    quiet|normal|debug) ;;
    *) fail "TMOD_LOG_LEVEL must be quiet, normal, or debug." ;;
esac
export TMOD_LOG_LEVEL TMOD_CONTROL_PIPE="$control_pipe" TMOD_SERVER_PID_FILE="$pid_path"

for directory in /data /data/steamMods /data/tModLoader/Logs /data/tModLoader/ModConfigs \
        /data/tModLoader/Mods /data/tModLoader/Worlds "$base_dir" "$HOME"; do
    ensure_writable_directory "$directory"
done
install -d -m 0700 "$runtime_dir"
exec 9>/data/.server.lock
flock -n 9 || fail "Another server container is already using /data."

printf '[SYSTEM] Runtime identity: uid=%s gid=%s\n' "$(id -u)" "$(id -g)"

trap shutdown TERM INT
trap cleanup EXIT

# --- 1. Game server install / update ------------------------------------------
server_dir="$("$base_dir/install-tmodloader.sh")"
printf '[SYSTEM] Using tModLoader %s\n' "$(<"$server_dir/.installed")"

# --- 2. Server configuration --------------------------------------------------
if use_custom_config; then
    [[ -r "$custom_config_path" ]] || fail "TMOD_USECONFIGFILE is enabled, but $custom_config_path is missing or unreadable."
    config_path="$custom_config_path"
    printf '[CONFIG] Using the mounted custom configuration file.\n'
else
    load_password_file
    TMOD_CONFIG_PATH="$generated_config_path" "$base_dir/prepare-config.sh"
fi
# tModLoader logs its entire environment; keep the password out of the logs.
unset TMOD_PASS TMOD_PASS_FILE

# --- 3. Mods ------------------------------------------------------------------
"$base_dir/manage-mods.sh" || fail "Mod installation failed; inspect the messages above."

# --- 4. Launch ----------------------------------------------------------------
rm -f "$control_pipe" "$pid_path"
mkfifo -m 0600 "$control_pipe"
# Holding the FIFO open read/write keeps the server's stdin alive and lets
# `inject` write commands without blocking.
exec 3<> "$control_pipe"

printf '[SYSTEM] Launching tModLoader with %s\n' "$config_path"
TMOD_SCRIPT_CALLER="$server_dir/LaunchUtils/ScriptCaller.sh" \
    setsid --wait "$base_dir/run-server.sh" "$config_path" <&3 &
server_pid=$!
printf '%s\n' "$server_pid" > "$pid_path"

if ((10#${TMOD_AUTOSAVE_INTERVAL:-10} > 0)); then
    "$base_dir/autosave.sh" &
    autosave_pid=$!
else
    printf '[SYSTEM] Periodic autosave is disabled.\n'
fi

# `wait` returns early when a trapped signal arrives; the trap then exits.
server_status=0
wait "$server_pid" || server_status=$?
server_pid=""
stop_autosave
if ((server_status != 0)); then
    printf '[!!] tModLoader exited unexpectedly with status %s.\n' "$server_status" >&2
fi
exit "$server_status"
