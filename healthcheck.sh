#!/bin/bash
# Docker HEALTHCHECK: server process alive and game port listening.
# Reads /proc instead of connecting, because every connection takes a player slot.
set -uo pipefail

pid_file=/tmp/tmod.pid
[[ -r $pid_file ]] && kill -0 "$(<"$pid_file")" 2>/dev/null || exit 1

printf -v port_hex ':%04X' "$TMOD_PORT"
# tcp6 is missing when IPv6 is disabled.
{ cat /proc/net/tcp /proc/net/tcp6 2>/dev/null || true; } \
    | awk -v p="$port_hex" '$2 ~ p"$" && $4 == "0A" { found = 1 } END { exit !found }'
