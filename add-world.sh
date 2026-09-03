#!/usr/bin/env bash
# Places a world backup zip (from stage-save.ps1, scp'd over) into the save
# volume where the server will find it. Run on the Docker host.
#
# Usage: ./add-world.sh <path-to-WorldId_GameVersion_Latest.zip>
#
# Does not touch WORLD_ISLAND_ID or restart anything -- run select-world.sh
# afterward to actually switch the server to this world.
set -euo pipefail

ZIP="${1:?Usage: $0 <path-to-WorldId_GameVersion_Latest.zip>}"
[ -f "$ZIP" ] || { echo "No such file: $ZIP" >&2; exit 1; }

BASENAME="$(basename "$ZIP")"
# World IDs are 32 hex chars with no underscores, so everything before the
# first underscore in <WorldId>_<GameVersion>_<Latest|timestamp>.zip is it.
WORLD_ID="${BASENAME%%_*}"
if ! [[ "$WORLD_ID" =~ ^[0-9A-Fa-f]{32}$ ]]; then
    echo "Couldn't parse a world ID out of '$BASENAME' (expected <WorldId>_<GameVersion>_....zip)." >&2
    exit 1
fi

SRC_DIR="$(cd "$(dirname "$ZIP")" && pwd)"

echo "Placing $BASENAME as world $WORLD_ID ..."
docker run --rm \
    -v windrose-save-dir:/v \
    -v "$SRC_DIR":/src:ro \
    alpine:3.23 sh -c "
        mkdir -p /v/SaveProfiles/Default/RocksDB_v2_Backups/Worlds/$WORLD_ID &&
        cp /src/$BASENAME /v/SaveProfiles/Default/RocksDB_v2_Backups/Worlds/$WORLD_ID/ &&
        chown -R 10001:10001 /v/SaveProfiles/Default/RocksDB_v2_Backups/Worlds/$WORLD_ID
    "

echo "Done. World $WORLD_ID is now available -- run ./select-world.sh to load it."
