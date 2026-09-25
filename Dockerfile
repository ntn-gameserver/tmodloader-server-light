# tModLoader dedicated server – light.
# Based on JACOBSMILE/tmodloader1.4; tModLoader itself is installed at runtime
# into /data so the version can be controlled with TMOD_VERSION.

# SteamCMD is 32-bit; take it and its i386 libraries from this image.
FROM steamcmd/steamcmd:ubuntu-22 AS builder
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl tar
WORKDIR /root/installer
RUN curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar zxf -

# Pinned: ubuntu:latest moved to a release without tModLoader's .NET dependencies.
FROM ubuntu:24.04

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl jq unzip libicu74 libssl3 libgssapi-krb5-2 libsdl2-2.0-0 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /root/installer /opt/steamcmd
COPY --from=builder /lib/i386-linux-gnu /opt/steam-runtime/lib
COPY --from=builder /root/installer/linux32/libstdc++.so.6 /opt/steam-runtime/lib/
RUN ln -s /opt/steam-runtime/lib/ld-linux.so.2 /lib/ld-linux.so.2 \
    && LD_LIBRARY_PATH=/opt/steam-runtime/lib /opt/steamcmd/steamcmd.sh +login anonymous +quit

# --- Game server install ---
# "latest" or a release tag such as v2025.01.3.1
ENV TMOD_VERSION="latest"
# 1 = look for a newer release on every start (only with TMOD_VERSION=latest)
ENV TMOD_AUTO_UPDATE="1"

# --- Mods ---
# Steam Workshop IDs, comma separated. Downloaded/updated and enabled on start.
ENV TMOD_MODS=""

# --- Runtime ---
ENV TMOD_SHUTDOWN_MESSAGE="Server is shutting down NOW!"
# Minutes between world saves, 0 disables
ENV TMOD_AUTOSAVE_INTERVAL="10"

# --- Server config ---
# "Yes" = use /terraria-server/customconfig.txt instead of the settings below
ENV TMOD_USECONFIGFILE="No"
ENV TMOD_MOTD="A tModLoader server powered by Docker!"
# "N/A" disables the password
ENV TMOD_PASS="docker"
ENV TMOD_MAXPLAYERS="8"
ENV TMOD_WORLDNAME="Docker"
ENV TMOD_WORLDSIZE="3"
ENV TMOD_WORLDSEED="Docker"
ENV TMOD_DIFFICULTY="1"
ENV TMOD_SECURE="0"
ENV TMOD_LANGUAGE="en-US"
ENV TMOD_NPCSTREAM="60"
ENV TMOD_UPNP="0"
ENV TMOD_PRIORITY="1"
ENV TMOD_PORT="7777"

# --- Journey mode permissions (0 = locked, 1 = host, 2 = everyone) ---
ENV TMOD_JOURNEY_SETFROZEN="0" \
    TMOD_JOURNEY_SETDAWN="0" \
    TMOD_JOURNEY_SETNOON="0" \
    TMOD_JOURNEY_SETDUSK="0" \
    TMOD_JOURNEY_SETMIDNIGHT="0" \
    TMOD_JOURNEY_GODMODE="0" \
    TMOD_JOURNEY_WIND_STRENGTH="0" \
    TMOD_JOURNEY_RAIN_STRENGTH="0" \
    TMOD_JOURNEY_TIME_SPEED="0" \
    TMOD_JOURNEY_RAIN_FROZEN="0" \
    TMOD_JOURNEY_WIND_FROZEN="0" \
    TMOD_JOURNEY_PLACEMENT_RANGE="0" \
    TMOD_JOURNEY_SET_DIFFICULTY="0" \
    TMOD_JOURNEY_BIOME_SPREAD="0" \
    TMOD_JOURNEY_SPAWN_RATE="0"

WORKDIR /terraria-server
COPY --chmod=755 entrypoint.sh .
COPY --chmod=755 inject.sh /usr/local/bin/inject

EXPOSE 7777
VOLUME ["/data"]
ENTRYPOINT ["./entrypoint.sh"]
