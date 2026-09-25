#!/bin/bash
# Send a console command to the server: docker exec tmodloader inject "say Hello"
pipe=/tmp/tmod.pipe
[[ -p "$pipe" ]] || { echo "The server is not running." >&2; exit 1; }
timeout 5 bash -c 'printf "%s\n" "$1" > "$2"' -- "$*" "$pipe"
