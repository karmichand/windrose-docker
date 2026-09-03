#!/usr/bin/env bash
# Picks which world the server loads and restarts it. Run on the Docker
# host, from the same directory as docker-compose.yml and .env.
#
# Usage:
#   ./select-world.sh              interactive: lists worlds, prompts
#   ./select-world.sh <WorldId>    non-interactive: switch directly
#
# Only switches between worlds already in the windrose-save-dir volume --
# use add-world.sh first to bring a new one over from stage-save.ps1.
set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE=".env"
[ -f "$ENV_FILE" ] || { echo "No .env found. Run: cp .env.example .env" >&2; exit 1; }

# One line per world: "<WorldId>|<mtime of its _Latest.zip, or a note>".
mapfile -t WORLD_LINES < <(docker run --rm -v windrose-save-dir:/v alpine:3.23 sh -c '
    for d in /v/SaveProfiles/Default/RocksDB_v2_Backups/Worlds/*/; do
        [ -d "$d" ] || continue
        id=$(basename "$d")
        latest=$(ls -t "$d"*_Latest.zip 2>/dev/null | head -1)
        if [ -n "$latest" ]; then
            mtime=$(stat -c "%y" "$latest" | cut -d. -f1)
        else
            mtime="no _Latest.zip -- check add-world.sh ran correctly"
        fi
        echo "$id|$mtime"
    done
')

if [ "${#WORLD_LINES[@]}" -eq 0 ]; then
    echo "No worlds found under RocksDB_v2_Backups/Worlds/ in the volume." >&2
    echo "Transfer one first: stage-save.ps1 on Windows, scp it over, then add-world.sh." >&2
    exit 1
fi

WORLD_IDS=()
for line in "${WORLD_LINES[@]}"; do
    WORLD_IDS+=("${line%%|*}")
done

if [ -n "${1:-}" ]; then
    WORLD_ID="$1"
    match=false
    for id in "${WORLD_IDS[@]}"; do
        [ "$id" = "$WORLD_ID" ] && match=true && break
    done
    if [ "$match" != true ]; then
        echo "World $WORLD_ID not found. Available:" >&2
        printf '  %s\n' "${WORLD_IDS[@]}" >&2
        exit 1
    fi
else
    echo "Worlds available:"
    for i in "${!WORLD_LINES[@]}"; do
        line="${WORLD_LINES[$i]}"
        echo "  [$i] ${line%%|*}   (${line#*|})"
    done
    echo ""
    read -rp "Enter the number of the world to load: " CHOICE
    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -ge "${#WORLD_IDS[@]}" ]; then
        echo "'$CHOICE' is not one of the listed numbers." >&2
        exit 1
    fi
    WORLD_ID="${WORLD_IDS[$CHOICE]}"
fi

if grep -q '^WORLD_ISLAND_ID=' "$ENV_FILE"; then
    sed -i "s/^WORLD_ISLAND_ID=.*/WORLD_ISLAND_ID=${WORLD_ID}/" "$ENV_FILE"
else
    echo "WORLD_ISLAND_ID=${WORLD_ID}" >> "$ENV_FILE"
fi
echo "WORLD_ISLAND_ID set to $WORLD_ID in .env."

echo "Restarting windrose-server ..."
docker compose up -d
echo ""
echo "Watching logs -- Ctrl-C to stop watching (the server keeps running):"
docker compose logs -f windrose-server
