FROM debian:bookworm-slim

# Windrose ships a Windows-only dedicated server binary. On Linux it runs
# under Wine with a virtual framebuffer, since the binary expects a display
# even in headless mode.

ARG DEBIAN_FRONTEND=noninteractive
ARG WINE_BRANCH=staging

RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg2 \
        lib32gcc-s1 \
        procps \
        python3 \
        tini \
        xvfb \
        xauth \
        winbind \
        cabextract \
        unzip && \
    rm -rf /var/lib/apt/lists/*

# WineHQ repository
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://dl.winehq.org/wine-builds/winehq.key \
        -o /etc/apt/keyrings/winehq-archive.key && \
    curl -fsSL https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources \
        -o /etc/apt/sources.list.d/winehq-bookworm.sources && \
    apt-get update && \
    apt-get install -y --no-install-recommends winehq-${WINE_BRANCH} && \
    rm -rf /var/lib/apt/lists/*

# SteamCMD
RUN mkdir -p /steamcmd && \
    curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
        | tar -xz -C /steamcmd

RUN useradd -m -u 1000 -s /bin/bash windrose && \
    mkdir -p /server /seed /wineprefix && \
    chown -R windrose:windrose /server /seed /wineprefix /steamcmd

# ---------------------------------------------------------------------------
# Bake the world save into the image.
#
# Put your world folder under ./seed/ before building, preserving the profile
# and build structure the game uses:
#
#   seed/SaveProfiles/<steamid>/RocksDB/<version>/Worlds/<worldid>/
#
# The entrypoint copies this into the live save volume on first start, or on
# every start when FORCE_SEED=1.
# ---------------------------------------------------------------------------
COPY --chown=windrose:windrose seed/ /seed/

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

ENV WINEPREFIX=/wineprefix \
    WINEARCH=win64 \
    WINEDEBUG=-all \
    SERVER_DIR=/server \
    STEAM_APPID=4129620

USER windrose
WORKDIR /server

VOLUME ["/server/R5/Saved"]

# Direct connection mode. Invite-code mode uses dynamic ports and needs
# host networking instead.
EXPOSE 7777/tcp 7777/udp 27015/udp

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
