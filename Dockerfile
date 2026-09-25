# syntax=docker/dockerfile:1
#
# tModLoader server – light edition.
# Everything is configured through environment variables; there is no web UI,
# no backup system and no update management beyond "install latest or a pinned
# release" plus Steam Workshop mod install/update.

# The Steam client is still 32-bit; take steamcmd and its i386 libraries from here.
FROM --platform=linux/amd64 steamcmd/steamcmd:ubuntu-22 AS builder_amd64
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl tar \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /root/installer
RUN curl --fail --silent --show-error --location \
        https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
    | tar --extract --gzip

FROM ubuntu:24.04 AS runtime-base
ARG TARGETARCH
ARG TMOD_UID=1000
ARG TMOD_GID=1000

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        jq \
        libc6 \
        libgcc-s1 \
        libgssapi-krb5-2 \
        libicu74 \
        libsdl2-2.0-0 \
        libssl3 \
        libstdc++6 \
        locales \
        python3 \
        tini \
        tzdata \
        unzip \
        util-linux \
        zlib1g \
    && case "$TARGETARCH" in \
        amd64|arm64) ;; \
        *) echo "Unsupported architecture: $TARGETARCH (use amd64 or arm64)" >&2; exit 1 ;; \
    esac \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

ENV LANG="en_US.UTF-8" \
    LC_ALL="en_US.UTF-8"

# Unprivileged runtime user. Ubuntu 24.04 ships "ubuntu" as 1000:1000; reuse it.
RUN existing_user="$(getent passwd "$TMOD_UID" | cut -d: -f1)" \
    && existing_group="$(getent group "$TMOD_GID" | cut -d: -f1)" \
    && if [ "$existing_user" = ubuntu ] && [ "$existing_group" = ubuntu ]; then \
        groupmod --new-name tml ubuntu; \
        usermod --login tml --home /home/tml --move-home ubuntu; \
    elif [ -n "$existing_user" ] || [ -n "$existing_group" ]; then \
        echo "TMOD_UID or TMOD_GID is already assigned in the base image." >&2; exit 1; \
    else \
        groupadd --gid "$TMOD_GID" tml; \
        useradd --no-log-init --uid "$TMOD_UID" --gid "$TMOD_GID" \
            --create-home --home-dir /home/tml --shell /bin/bash tml; \
    fi \
    && install -d -m 0755 -o tml -g tml /home/tml/.steam /data /terraria-server

ENV HOME="/home/tml" \
    USER="tml"
WORKDIR /terraria-server

# --- Workshop downloader per architecture -------------------------------------
FROM runtime-base AS runtime-amd64
COPY --from=builder_amd64 /root/installer/ /opt/steamcmd-seed/
COPY --from=builder_amd64 /lib/i386-linux-gnu/ /opt/steam-runtime/lib/
COPY --from=builder_amd64 /root/installer/linux32/libstdc++.so.6 /opt/steam-runtime/lib/
RUN ln -s /opt/steam-runtime/lib/ld-linux.so.2 /lib/ld-linux.so.2
COPY --chmod=0755 steamcmd-wrapper.sh /usr/bin/steamcmd
ENV TMOD_WORKSHOP_BACKEND="steamcmd"
USER tml:tml
RUN steamcmd +login anonymous +quit
USER root:root

FROM runtime-base AS runtime-arm64
# Native .NET downloader; avoids x86 SteamCMD emulation on ARM hosts.
ARG DEPOTDOWNLOADER_VERSION=3.4.0
RUN curl --fail --silent --show-error --location --retry 5 \
        "https://github.com/SteamRE/DepotDownloader/releases/download/DepotDownloader_${DEPOTDOWNLOADER_VERSION}/DepotDownloader-linux-arm64.zip" \
        --output /tmp/depotdownloader.zip \
    && unzip -q /tmp/depotdownloader.zip -d /opt/depotdownloader \
    && chmod 755 /opt/depotdownloader/DepotDownloader \
    && ln -s /opt/depotdownloader/DepotDownloader /usr/local/bin/depotdownloader \
    && rm /tmp/depotdownloader.zip \
    && depotdownloader --version
ENV TMOD_WORKSHOP_BACKEND="depotdownloader"

# --- Final image --------------------------------------------------------------
FROM runtime-${TARGETARCH} AS runtime

# Game server install
ENV TMOD_VERSION="latest" \
    TMOD_AUTO_UPDATE="1"

# Mods
ENV TMOD_MODS="" \
    TMOD_LOCAL_MODS="" \
    TMOD_MOD_PRUNE="0" \
    TMOD_DOWNLOAD_RETRIES="3" \
    TMOD_DOWNLOAD_RETRY_DELAY="10" \
    TMOD_MOD_OFFLINE_POLICY="use-cache" \
    TMOD_COLLECTION_MAX_ITEMS="1000"

# Server settings (serverconfig.txt is generated from these)
ENV TMOD_USECONFIGFILE="No" \
    TMOD_MOTD="A tModLoader server powered by Docker!" \
    TMOD_PASS="docker" \
    TMOD_PASS_FILE="" \
    TMOD_MAXPLAYERS="8" \
    TMOD_WORLDNAME="Docker" \
    TMOD_WORLDSIZE="3" \
    TMOD_WORLDEVIL="random" \
    TMOD_WORLDSEED="Docker" \
    TMOD_DIFFICULTY="1" \
    TMOD_SECURE="0" \
    TMOD_LANGUAGE="en-US" \
    TMOD_NPCSTREAM="60" \
    TMOD_UPNP="0" \
    TMOD_PRIORITY="1" \
    TMOD_PORT="7777"

# Journey mode power permissions (0 = locked, 1 = host only, 2 = everyone)
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

# Runtime behaviour
ENV TMOD_AUTOSAVE_INTERVAL="10" \
    TMOD_AUTOSAVE_MESSAGE="Scheduled world save starting." \
    TMOD_SHUTDOWN_MESSAGE="Server is shutting down NOW!" \
    TMOD_SHUTDOWN_DELAY="3" \
    TMOD_SHUTDOWN_TIMEOUT="90" \
    TMOD_LOG_LEVEL="normal" \
    TMOD_CRASH_LOG_LINES="200"

COPY --chown=root:root --chmod=0755 \
    entrypoint.sh run-server.sh install-tmodloader.sh prepare-config.sh \
    manage-mods.sh autosave.sh log-filter.sh \
    ./
COPY --chown=root:root --chmod=0644 create_world.py workshop_download.py filter_client_mods.py ./
COPY --chown=root:root --chmod=0755 inject.sh /usr/local/bin/inject
COPY --chown=root:root --chmod=0755 healthcheck.sh /usr/local/bin/healthcheck
COPY --chown=root:root --chmod=0755 container-init.sh /usr/local/bin/tmod-init
RUN chown tml:tml /terraria-server

EXPOSE 7777
VOLUME ["/data"]

# First start downloads tModLoader, .NET and all mods; allow plenty of time.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30m --retries=3 CMD ["healthcheck"]
STOPSIGNAL SIGTERM

# tmod-init runs as root only to fix /data ownership, then drops to "tml".
ENTRYPOINT ["/usr/local/bin/tmod-init", "/usr/bin/tini", "--", "./entrypoint.sh"]
