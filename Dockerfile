# tModLoader dedicated server – light.
# Based on JACOBSMILE/tmodloader1.4; tModLoader itself is installed at runtime
# into /data so the version can be controlled with TMOD_VERSION.

# Ubuntu 24.04 with SteamCMD and its i386 libraries already installed.
FROM steamcmd/steamcmd:ubuntu-24

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl jq unzip libicu74 libssl3 libgssapi-krb5-2 libsdl2-2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# The server runs as the unprivileged user "tml" (uid/gid 1000, Ubuntu's "ubuntu" user renamed).
# It gets its own copy of the SteamCMD install from the base image, so SteamCMD can update itself.
RUN groupmod --new-name tml ubuntu \
    && usermod --login tml --home /home/tml --move-home --groups "" ubuntu \
    && install -d -o tml -g tml /data /terraria-server /home/tml/.local/share \
    && cp -a /root/.local/share/Steam /home/tml/.local/share/ \
    && chown -R tml:tml /home/tml
ENV HOME=/home/tml

# Defaults for all settings; see .env.example for a description of each one.
ENV TMOD_VERSION="latest" \
    TMOD_AUTO_UPDATE="1" \
    TMOD_MODS="" \
    TMOD_SHUTDOWN_MESSAGE="Server is shutting down NOW!" \
    TMOD_AUTOSAVE_INTERVAL="10" \
    TMOD_USECONFIGFILE="No" \
    TMOD_MOTD="A tModLoader server powered by Docker!" \
    TMOD_PASS="docker" \
    TMOD_MAXPLAYERS="8" \
    TMOD_PORT="7777" \
    TMOD_LANGUAGE="en-US" \
    TMOD_SECURE="0" \
    TMOD_NPCSTREAM="60" \
    TMOD_UPNP="0" \
    TMOD_PRIORITY="1" \
    TMOD_WORLDNAME="Docker" \
    TMOD_WORLDSIZE="3" \
    TMOD_DIFFICULTY="1" \
    TMOD_WORLDSEED="Docker" \
    TMOD_WORLDEVIL="random" \
    TMOD_JOURNEY_SETFROZEN="0" \
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
COPY --chmod=755 healthcheck.sh /usr/local/bin/healthcheck

EXPOSE 7777
VOLUME ["/data"]
# The first start downloads tModLoader, .NET and mods; give it time.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30m --retries=3 CMD ["healthcheck"]
# Starts as root only to fix /data ownership, then entrypoint.sh switches to "tml".
ENTRYPOINT ["./entrypoint.sh"]
