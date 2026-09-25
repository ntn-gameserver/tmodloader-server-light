#!/usr/bin/env bash
# Install (or update) the tModLoader dedicated server into /data/server.
#
#   TMOD_VERSION=latest       newest stable GitHub release (default)
#   TMOD_VERSION=v2025.x.y.z  pin a specific release tag
#   TMOD_AUTO_UPDATE=1        check for a newer release on every start (latest only)
#
# Prints the directory of the active installation on stdout; logs go to stderr.

set -Eeuo pipefail

data_dir="${TMOD_DATA_DIR:-/data}"
install_root="$data_dir/server"
active_file="$install_root/active"
releases_api="${TMOD_RELEASES_API:-https://api.github.com/repos/tModLoader/tModLoader/releases}"
download_base="${TMOD_DOWNLOAD_BASE:-https://github.com/tModLoader/tModLoader/releases/download}"
requested="${TMOD_VERSION:-latest}"
auto_update="${TMOD_AUTO_UPDATE:-1}"

log() {
    printf '[INSTALL] %s\n' "$*" >&2
}

fail() {
    printf '[!!] FATAL: %s\n' "$*" >&2
    exit 1
}

installed() {
    [[ -f "$install_root/$1/.installed" && -f "$install_root/$1/LaunchUtils/ScriptCaller.sh" ]]
}

current_active() {
    local tag=""
    [[ -f "$active_file" ]] && tag="$(<"$active_file")"
    if [[ -n "$tag" ]] && installed "$tag"; then
        printf '%s\n' "$tag"
    fi
}

latest_tag() {
    curl --fail --silent --show-error --location --retry 3 \
        --connect-timeout 10 --max-time 30 \
        -H 'Accept: application/vnd.github+json' \
        -H 'User-Agent: tmodloader-server-light' \
        "$releases_api/latest" | jq -er '.tag_name'
}

install_release() {
    local tag="$1" staging

    log "Downloading tModLoader $tag ..."
    # Leftovers from an interrupted install are removed on the next start.
    staging="$(mktemp -d "$install_root/.download-XXXXXX")"

    curl --fail --silent --show-error --location --retry 3 \
        --connect-timeout 10 --max-time 600 \
        --output "$staging/tModLoader.zip" \
        "$download_base/$tag/tModLoader.zip" || fail "Could not download tModLoader $tag."

    mkdir "$staging/package"
    unzip -q "$staging/tModLoader.zip" -d "$staging/package" || fail "Could not extract tModLoader $tag."
    rm -f "$staging/tModLoader.zip"
    find "$staging/package" -name '*.sh' -exec chmod 755 {} +
    for required in tModLoader.dll LaunchUtils/ScriptCaller.sh LaunchUtils/InstallDotNet.sh; do
        [[ -f "$staging/package/$required" ]] || fail "Release $tag is incomplete (missing $required)."
    done

    log "Installing the .NET runtime required by tModLoader $tag ..."
    # Keep installer scratch space on /data; a small /tmp cannot hold .NET.
    if ! (
        cd "$staging/package/LaunchUtils"
        export TMPDIR="$staging"
        # shellcheck disable=SC1091
        . ./BashUtils.sh
        export LogFile="$staging/dotnet-install.log"
        # shellcheck disable=SC1091
        . ./DotNetVersion.sh
        run_script ./InstallDotNet.sh
    ) >&2; then
        [[ -f "$staging/dotnet-install.log" ]] && tail -n 50 "$staging/dotnet-install.log" >&2
        fail ".NET installation for tModLoader $tag failed."
    fi

    # tModLoader writes its own logs next to the install; keep them on /data.
    rm -rf "$staging/package/tModLoader-Logs"
    ln -s "$data_dir/tModLoader/Logs" "$staging/package/tModLoader-Logs"
    printf '%s\n' "$tag" > "$staging/package/.installed"

    rm -rf -- "${install_root:?}/$tag"
    mv "$staging/package" "$install_root/$tag"
    rm -rf -- "$staging"
    log "Installed tModLoader $tag."
}

activate() {
    local tag="$1" directory

    printf '%s\n' "$tag" > "$active_file.tmp"
    mv -f "$active_file.tmp" "$active_file"
    # Remove every other installed release to keep /data small.
    for directory in "$install_root"/*/; do
        directory="${directory%/}"
        [[ "$(basename "$directory")" == "$tag" ]] && continue
        [[ -f "$directory/.installed" ]] || continue
        log "Removing old release $(basename "$directory")."
        rm -rf -- "$directory"
    done
}

[[ "$auto_update" =~ ^[01]$ ]] || fail "TMOD_AUTO_UPDATE must be 0 or 1."
mkdir -p "$install_root" "$data_dir/tModLoader/Logs"
rm -rf "$install_root"/.download-*

active="$(current_active || true)"
target=""

if [[ "$requested" == latest ]]; then
    if [[ -n "$active" && "$auto_update" == 0 ]]; then
        target="$active"
        log "Automatic updates disabled; using installed tModLoader $active."
    elif target="$(latest_tag)" && [[ -n "$target" ]]; then
        log "Latest tModLoader release: $target (installed: ${active:-none})."
    elif [[ -n "$active" ]]; then
        target="$active"
        log "WARNING: Could not query GitHub for the latest release; using installed tModLoader $active."
    else
        fail "Could not determine the latest tModLoader release and nothing is installed yet."
    fi
else
    [[ "$requested" =~ ^v[0-9]+(\.[0-9]+)*$ ]] || fail "TMOD_VERSION must be 'latest' or a release tag such as v2025.01.3.1."
    target="$requested"
fi

if ! installed "$target"; then
    install_release "$target"
else
    log "tModLoader $target is already installed."
fi
activate "$target"
printf '%s\n' "$install_root/$target"
