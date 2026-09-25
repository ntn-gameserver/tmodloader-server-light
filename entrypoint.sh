#!/bin/bash
set -euo pipefail

server_dir=/data/server
world_dir=/data/tModLoader/Worlds
workshop_dir=/data/steamMods
mod_dir=$workshop_dir/steamapps/workshop/content/1281930
enabled_path=/data/tModLoader/Mods/enabled.json
config_path=/terraria-server/serverconfig.txt
pipe=/tmp/tmod.pipe
pid_file=/tmp/tmod.pid
steam_api=https://api.steampowered.com/ISteamRemoteStorage

log() { echo "[SYSTEM] $*"; }
fail() { echo "[!!] FATAL: $*" >&2; exit 1; }
steamcmd() { LD_LIBRARY_PATH=/opt/steam-runtime/lib /opt/steamcmd/steamcmd.sh "$@"; }

# ---------------------------------------------------------------------------
# Healthcheck (Dockerfile HEALTHCHECK): server process alive and port listening.
# Reads /proc instead of connecting, because every connection takes a player slot.
# ---------------------------------------------------------------------------
if [[ ${1:-} == healthcheck ]]; then
    [[ -r $pid_file ]] && kill -0 "$(<"$pid_file")" 2>/dev/null || exit 1
    printf -v port_hex ':%04X' "$TMOD_PORT"
    # tcp6 is missing when IPv6 is disabled.
    { cat /proc/net/tcp /proc/net/tcp6 2>/dev/null || true; } \
        | awk -v p="$port_hex" '$2 ~ p"$" && $4 == "0A" { found = 1 } END { exit !found }'
    exit
fi

# ---------------------------------------------------------------------------
# Drop root: fix ownership of /data, then re-run this script as user "tml".
# ---------------------------------------------------------------------------
if [[ $(id -u) == 0 ]]; then
    mkdir -p /data
    find /data -xdev \( ! -user tml -o ! -group tml \) -exec chown -h tml:tml {} +
    rm -f "$pipe" "$pid_file"  # leftovers from a previous run of this container
    exec setpriv --reuid=tml --regid=tml --init-groups -- "$0" "$@"
fi

mkdir -p "$world_dir" /data/tModLoader/Mods "$workshop_dir"

# ---------------------------------------------------------------------------
# 1. Install / update tModLoader
# ---------------------------------------------------------------------------
installed=""
[[ -f $server_dir/.version ]] && installed=$(<"$server_dir/.version")
version=$TMOD_VERSION

if [[ $version == latest ]]; then
    if [[ -n $installed && $TMOD_AUTO_UPDATE == 0 ]]; then
        version=$installed
    else
        version=$(curl -fsSL https://api.github.com/repos/tModLoader/tModLoader/releases/latest | jq -r .tag_name) || version=""
        if [[ -z $version || $version == null ]]; then
            [[ -n $installed ]] || fail "Could not look up the latest tModLoader release."
            log "Could not look up the latest release; keeping $installed."
            version=$installed
        fi
    fi
fi

if [[ $version != "$installed" ]]; then
    log "Installing tModLoader $version (installed: ${installed:-none})..."
    rm -rf "$server_dir.new" && mkdir -p "$server_dir.new"
    curl -fL --retry 3 -o /tmp/tModLoader.zip \
        "https://github.com/tModLoader/tModLoader/releases/download/$version/tModLoader.zip" \
        || fail "Could not download tModLoader $version."
    unzip -q /tmp/tModLoader.zip -d "$server_dir.new" && rm /tmp/tModLoader.zip
    find "$server_dir.new" -name "*.sh" -exec chmod +x {} +
    echo "$version" > "$server_dir.new/.version"
    # Keep the already downloaded .NET runtime; ScriptCaller replaces it if needed.
    [[ -d $server_dir/dotnet ]] && mv "$server_dir/dotnet" "$server_dir.new/"
    rm -rf "$server_dir" && mv "$server_dir.new" "$server_dir"
fi
log "Using tModLoader $version."

# ---------------------------------------------------------------------------
# 2. Server config
# ---------------------------------------------------------------------------
world=$world_dir/$TMOD_WORLDNAME.wld
if [[ ${TMOD_USECONFIGFILE,,} == yes ]]; then
    config_path=/terraria-server/customconfig.txt
    [[ -f $config_path ]] || fail "TMOD_USECONFIGFILE=Yes, but $config_path is not mounted."
    log "Using the mounted config file."
else
    TMOD_WORLDEVIL=${TMOD_WORLDEVIL:-random}
    case $TMOD_WORLDEVIL in
        random|corruption|crimson) ;;
        *) fail "TMOD_WORLDEVIL must be random, corruption or crimson." ;;
    esac
    {
        echo "world=$world"
        echo "worldpath=$world_dir/"
        if [[ ! -e $world ]]; then
            echo "worldname=$TMOD_WORLDNAME"
            echo "autocreate=$TMOD_WORLDSIZE"
        fi
        [[ $TMOD_PASS == "N/A" ]] || echo "password=$TMOD_PASS"
        echo "motd=$TMOD_MOTD"
        echo "maxplayers=$TMOD_MAXPLAYERS"
        echo "seed=$TMOD_WORLDSEED"
        echo "difficulty=$TMOD_DIFFICULTY"
        echo "secure=$TMOD_SECURE"
        echo "language=$TMOD_LANGUAGE"
        echo "npcstream=$TMOD_NPCSTREAM"
        echo "upnp=$TMOD_UPNP"
        echo "priority=$TMOD_PRIORITY"
        echo "port=$TMOD_PORT"
        echo "journeypermission_time_setfrozen=$TMOD_JOURNEY_SETFROZEN"
        echo "journeypermission_time_setdawn=$TMOD_JOURNEY_SETDAWN"
        echo "journeypermission_time_setnoon=$TMOD_JOURNEY_SETNOON"
        echo "journeypermission_time_setdusk=$TMOD_JOURNEY_SETDUSK"
        echo "journeypermission_time_setmidnight=$TMOD_JOURNEY_SETMIDNIGHT"
        echo "journeypermission_godmode=$TMOD_JOURNEY_GODMODE"
        echo "journeypermission_wind_setstrength=$TMOD_JOURNEY_WIND_STRENGTH"
        echo "journeypermission_rain_setstrength=$TMOD_JOURNEY_RAIN_STRENGTH"
        echo "journeypermission_time_setspeed=$TMOD_JOURNEY_TIME_SPEED"
        echo "journeypermission_rain_setfrozen=$TMOD_JOURNEY_RAIN_FROZEN"
        echo "journeypermission_wind_setfrozen=$TMOD_JOURNEY_WIND_FROZEN"
        echo "journeypermission_increaseplacementrange=$TMOD_JOURNEY_PLACEMENT_RANGE"
        echo "journeypermission_setdifficulty=$TMOD_JOURNEY_SET_DIFFICULTY"
        echo "journeypermission_biomespread_setfrozen=$TMOD_JOURNEY_BIOME_SPREAD"
        echo "journeypermission_setspawnrate=$TMOD_JOURNEY_SPAWN_RATE"
    } > "$config_path"
    chmod 600 "$config_path"
    [[ -e $world ]] || log "World \"$TMOD_WORLDNAME\" not found; it will be created."
fi
# tModLoader logs its environment; keep the password out of the logs.
unset TMOD_PASS

# ---------------------------------------------------------------------------
# 3. Mods: download/update from the Workshop and write enabled.json
#    Entries are Workshop IDs or collection:<ID> (nested collections work too).
# ---------------------------------------------------------------------------

# Print all item IDs of a collection; falls back to the last known list offline.
expand_collection() {
    local id=$1 cache=$workshop_dir/collection-$1.txt response child type
    if response=$(curl -fsS --max-time 30 -d collectioncount=1 -d "publishedfileids[0]=$id" \
            "$steam_api/GetCollectionDetails/v1/") \
        && jq -e '.response.collectiondetails[0].result == 1' <<< "$response" > /dev/null; then
        while read -r child type; do
            if [[ $type == 2 ]]; then
                expand_collection "$child"
            else
                echo "$child"
            fi
        done < <(jq -r '.response.collectiondetails[0].children[]? | "\(.publishedfileid) \(.filetype)"' <<< "$response") \
            | tee "$cache.tmp"
        mv "$cache.tmp" "$cache"
    elif [[ -s $cache ]]; then
        echo "[SYSTEM] Collection $id could not be loaded; using the cached list." >&2
        cat "$cache"
    else
        fail "Collection $id could not be loaded."
    fi
}

if [[ -z ${TMOD_MODS// /} ]]; then
    log "TMOD_MODS is empty; keeping the existing enabled.json."
else
    mod_ids=()
    declare -A seen=() from_collection=()
    IFS=',' read -ra entries <<< "${TMOD_MODS// /}"
    for entry in "${entries[@]}"; do
        if [[ $entry =~ ^collection:([0-9]+)$ ]]; then
            items=$(expand_collection "${BASH_REMATCH[1]}")
            log "Collection ${BASH_REMATCH[1]}: $(wc -w <<< "$items") item(s)."
            for id in $items; do
                from_collection[$id]=1
                [[ -n ${seen[$id]:-} ]] || { seen[$id]=1; mod_ids+=("$id"); }
            done
        elif [[ $entry =~ ^[0-9]+$ ]]; then
            [[ -n ${seen[$entry]:-} ]] || { seen[$entry]=1; mod_ids+=("$entry"); }
        else
            fail "Invalid entry in TMOD_MODS: $entry"
        fi
    done

    args=()
    for id in "${mod_ids[@]}"; do
        args+=(+workshop_download_item 1281930 "$id")
    done
    log "Downloading/updating ${#mod_ids[@]} mod(s)..."
    for attempt in 1 2 3; do
        steamcmd +force_install_dir "$workshop_dir" +login anonymous "${args[@]}" +quit && break
        log "SteamCMD failed (attempt $attempt/3)."
        sleep 10
    done

    names=()
    for id in "${mod_ids[@]}"; do
        # Mods keep one folder per tModLoader version; use the newest file.
        mod=$(find "$mod_dir/$id" -name '*.tmod' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2- || true)
        if [[ -z $mod ]]; then
            # Collections may contain items that are not tModLoader mods.
            [[ -n ${from_collection[$id]:-} ]] || fail "Mod $id was not downloaded."
            log "Skipping collection item $id (no .tmod file)."
            continue
        fi
        names+=("$(basename "$mod" .tmod)")
        log "Enabled ${names[-1]} ($id)."
    done
    jq -n '$ARGS.positional | unique' --args "${names[@]}" > "$enabled_path"
fi

# ---------------------------------------------------------------------------
# 4. New world with a fixed evil (corruption/crimson)
#    The config file cannot choose the evil, so we answer the server's
#    interactive world creation menu once, then start normally.
# ---------------------------------------------------------------------------
server_cmd=(./LaunchUtils/ScriptCaller.sh -server -tmlsavedirectory /data/tModLoader
            -steamworkshopfolder "$workshop_dir/steamapps/workshop")
cd "$server_dir"

create_world() {
    local tmp gen_log gen_pid pos=0 deadline=$((SECONDS + 3600))
    tmp=$(mktemp -d "$world_dir/.create-XXXXXX")
    gen_log=$tmp/console.log
    # Same settings, but no world to load and generated worlds go to $tmp.
    grep -vE '^(world|worldname|worldpath|autocreate|seed|language)=' "$config_path" > "$tmp/config.txt"
    printf 'worldpath=%s/\nlanguage=en-US\n' "$tmp" >> "$tmp/config.txt"
    mkfifo "$tmp/in" && exec 4<> "$tmp/in"
    setsid "${server_cmd[@]}" -config "$tmp/config.txt" <&4 > >(tee "$gen_log") 2>&1 &
    gen_pid=$!

    answer() {  # wait for a prompt, then type the answer
        until tail -c +$((pos + 1)) "$gen_log" 2>/dev/null | grep -qiE "$1"; do
            kill -0 "$gen_pid" 2>/dev/null || fail "World creation stopped unexpectedly."
            ((SECONDS < deadline)) || fail "World creation timed out."
            sleep 1
        done
        pos=$(stat -c %s "$gen_log")
        [[ -z ${2+x} ]] || echo "$2" >&4
    }
    log "Creating world \"$TMOD_WORLDNAME\" with $TMOD_WORLDEVIL..."
    answer 'Choose World' n
    answer 'Choose size' "$TMOD_WORLDSIZE"
    answer 'Choose difficulty' "$((TMOD_DIFFICULTY + 1))"
    answer 'Choose (world )?evil' "$([[ $TMOD_WORLDEVIL == corruption ]] && echo 2 || echo 3)"
    answer 'Enter world name' "$TMOD_WORLDNAME"
    answer 'Enter seed' "$TMOD_WORLDSEED"
    answer 'Choose World'   # back at the menu = world generated and saved
    kill -- -"$gen_pid" 2>/dev/null || true
    wait "$gen_pid" 2>/dev/null || true
    exec 4>&-

    local generated
    generated=$(find "$tmp" -maxdepth 1 -name '*.wld' | head -n 1)
    [[ -n $generated ]] || fail "World creation finished without a world file."
    for ext in wld twld; do
        [[ -f ${generated%.wld}.$ext ]] && mv "${generated%.wld}.$ext" "$world_dir/$TMOD_WORLDNAME.$ext"
    done
    rm -rf "$tmp"
    log "World created."
    # The world exists now; drop the autocreate lines.
    sed -i '/^worldname=/d; /^autocreate=/d' "$config_path"
}

if [[ ${TMOD_USECONFIGFILE,,} != yes && ! -e $world && $TMOD_WORLDEVIL != random ]]; then
    rm -rf "$world_dir"/.create-*
    create_world
fi

# ---------------------------------------------------------------------------
# 5. Run the server; commands are fed through a pipe (see inject.sh)
# ---------------------------------------------------------------------------
rm -f "$pipe" && mkfifo -m 600 "$pipe"
exec 3<> "$pipe"

"${server_cmd[@]}" -config "$config_path" <&3 &
server_pid=$!
echo "$server_pid" > "$pid_file"

if (( TMOD_AUTOSAVE_INTERVAL > 0 )); then
    while sleep "${TMOD_AUTOSAVE_INTERVAL}m"; do
        log "Saving world..."
        inject save || true
    done &
fi

shutdown() {
    log "Shutting down..."
    inject "say $TMOD_SHUTDOWN_MESSAGE" || true
    sleep 3
    inject exit || true
    wait "$server_pid" || true
    exit 0
}
trap shutdown TERM INT

wait "$server_pid"
