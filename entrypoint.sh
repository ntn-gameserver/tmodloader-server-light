#!/bin/bash
set -euo pipefail

server_dir=/data/server
workshop_dir=/data/steamMods
mod_dir=$workshop_dir/steamapps/workshop/content/1281930
enabled_path=/data/tModLoader/Mods/enabled.json
config_path=/terraria-server/serverconfig.txt
pipe=/tmp/tmod.pipe

log() { echo "[SYSTEM] $*"; }
fail() { echo "[!!] FATAL: $*" >&2; exit 1; }
steamcmd() { LD_LIBRARY_PATH=/opt/steam-runtime/lib /opt/steamcmd/steamcmd.sh "$@"; }

mkdir -p /data/tModLoader/Worlds /data/tModLoader/Mods "$workshop_dir"

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
    chmod +x "$server_dir.new"/*.sh "$server_dir.new"/LaunchUtils/*.sh
    echo "$version" > "$server_dir.new/.version"
    # Keep the already downloaded .NET runtime; ScriptCaller replaces it if needed.
    [[ -d $server_dir/dotnet ]] && mv "$server_dir/dotnet" "$server_dir.new/"
    rm -rf "$server_dir" && mv "$server_dir.new" "$server_dir"
fi
log "Using tModLoader $version."

# ---------------------------------------------------------------------------
# 2. Server config
# ---------------------------------------------------------------------------
if [[ ${TMOD_USECONFIGFILE,,} == yes ]]; then
    config_path=/terraria-server/customconfig.txt
    [[ -f $config_path ]] || fail "TMOD_USECONFIGFILE=Yes, but $config_path is not mounted."
    log "Using the mounted config file."
else
    world=/data/tModLoader/Worlds/$TMOD_WORLDNAME.wld
    {
        echo "world=$world"
        echo "worldpath=/data/tModLoader/Worlds/"
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
    [[ -e $world ]] || log "World \"$TMOD_WORLDNAME\" not found; it will be created."
fi
# tModLoader logs its environment; keep the password out of the logs.
unset TMOD_PASS

# ---------------------------------------------------------------------------
# 3. Mods: download/update from the Workshop and write enabled.json
# ---------------------------------------------------------------------------
if [[ -z ${TMOD_MODS// /} ]]; then
    log "TMOD_MODS is empty; keeping the existing enabled.json."
else
    IFS=',' read -ra mod_ids <<< "${TMOD_MODS// /}"
    args=()
    for id in "${mod_ids[@]}"; do
        [[ $id =~ ^[0-9]+$ ]] || fail "Invalid Workshop ID in TMOD_MODS: $id"
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
        mod=$(find "$mod_dir/$id" -name '*.tmod' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2-)
        [[ -n $mod ]] || fail "Mod $id was not downloaded."
        names+=("$(basename "$mod" .tmod)")
        log "Enabled ${names[-1]} ($id)."
    done
    jq -n '$ARGS.positional' --args "${names[@]}" > "$enabled_path"
fi

# ---------------------------------------------------------------------------
# 4. Run the server; commands are fed through a pipe (see inject.sh)
# ---------------------------------------------------------------------------
rm -f "$pipe" && mkfifo "$pipe"
exec 3<> "$pipe"

cd "$server_dir"
./LaunchUtils/ScriptCaller.sh -server \
    -tmlsavedirectory /data/tModLoader \
    -steamworkshopfolder "$workshop_dir/steamapps/workshop" \
    -config "$config_path" <&3 &
server_pid=$!

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
