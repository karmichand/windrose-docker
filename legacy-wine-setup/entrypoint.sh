#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

SERVER_DIR="${SERVER_DIR:-/server}"
SAVED_DIR="${SERVER_DIR}/R5/Saved"
SEED_DIR="${SEED_DIR:-/seed}"
DESC="${SERVER_DIR}/ServerDescription.json"

# ---------------------------------------------------------------- 1. update

# SteamCMD stages the download under steamapps/downloading and then moves it
# into place, so it needs roughly twice the app size free. Failing that move
# is what produces "state is 0x602 after update job".
preflight_space() {
    local need_gb="${MIN_FREE_GB:-8}"
    local avail_kb avail_gb
    avail_kb="$(df -Pk "${SERVER_DIR}" | awk 'NR==2 {print $4}')"
    avail_gb=$(( avail_kb / 1024 / 1024 ))
    log "Free space at ${SERVER_DIR}: ${avail_gb} GB"
    if [ "${avail_gb}" -lt "${need_gb}" ]; then
        log "Filesystem holding ${SERVER_DIR}:"
        df -h "${SERVER_DIR}" | sed 's/^/    /'
        die "Need at least ${need_gb} GB free, have ${avail_gb} GB. SteamCMD error 0x602 is a disk write failure. Grow the CT disk (pct resize <CTID> rootfs +20G) or prune Docker, then retry."
    fi
}

# The nested volume at R5/Saved is created root-owned by Docker. SteamCMD and
# the server both run as uid 1000 and cannot write into it.
preflight_perms() {
    local d
    for d in "${SERVER_DIR}" "${SAVED_DIR}"; do
        mkdir -p "${d}" 2>/dev/null || true
        if ! touch "${d}/.wtest" 2>/dev/null; then
            log "Ownership of ${d}:"
            ls -ld "${d}" | sed 's/^/    /'
            die "Cannot write to ${d} as $(id -un) (uid $(id -u)). Fix from the host with: docker run --rm -v <volume>:/v debian chown -R 1000:1000 /v"
        fi
        rm -f "${d}/.wtest"
    done
    log "Write access confirmed for ${SERVER_DIR} and ${SAVED_DIR}"
}

preflight_perms
preflight_space

if [ "${SKIP_UPDATE:-0}" != "1" ]; then
    log "Updating Windrose dedicated server (app ${STEAM_APPID})..."
    set +e
    /steamcmd/steamcmd.sh \
        +@sSteamCmdForcePlatformType windows \
        +force_install_dir "${SERVER_DIR}" \
        +login anonymous \
        +app_update "${STEAM_APPID}" validate \
        +quit
    steam_rc=$?
    set -e

    if [ "${steam_rc}" -ne 0 ]; then
        log "SteamCMD exited ${steam_rc}."
        log "Free space now:"
        df -h "${SERVER_DIR}" | sed 's/^/    /'
        log "Partial download under steamapps/downloading:"
        du -sh "${SERVER_DIR}/steamapps/downloading" 2>/dev/null | sed 's/^/    /' || true
        die "SteamCMD failed. Exit 0x602 or similar means a disk write failure: out of space, or the install directory is not writable by uid $(id -u)."
    fi
else
    log "SKIP_UPDATE=1, using the installed build as-is."
fi

SERVER_EXE="$(find "${SERVER_DIR}" -name 'WindroseServer*.exe' -type f | head -1 || true)"
[ -n "${SERVER_EXE}" ] || die "WindroseServer executable not found under ${SERVER_DIR}."
log "Executable: ${SERVER_EXE}"

# ------------------------------------------------------------ 2. wineprefix

if [ ! -f "${WINEPREFIX}/system.reg" ]; then
    log "Initializing Wine prefix..."
    xvfb-run -a wineboot --init
    # wineserver keeps running after init; wait it out so the next launch is clean
    wineserver -w || true
fi

# ------------------------------------------------------------- 3. seed save

mkdir -p "${SAVED_DIR}"

seed_world() {
    local src_worlds dst_worlds world_dir world_id
    src_worlds="$(find "${SEED_DIR}" -type d -name Worlds | head -1 || true)"
    [ -n "${src_worlds}" ] || { log "No baked-in save found under ${SEED_DIR}, skipping seed."; return 0; }

    world_dir="$(find "${src_worlds}" -mindepth 1 -maxdepth 1 -type d | head -1 || true)"
    [ -n "${world_dir}" ] || { log "Seed Worlds dir is empty, skipping."; return 0; }
    world_id="$(basename "${world_dir}")"

    # Mirror the seed layout under the live Saved dir. The path below Worlds
    # carries the profile id and build version, both of which matter.
    local rel="${src_worlds#${SEED_DIR}/}"
    dst_worlds="${SAVED_DIR}/${rel}"

    if [ -d "${dst_worlds}/${world_id}" ] && [ "${FORCE_SEED:-0}" != "1" ]; then
        log "World ${world_id} already present, leaving it alone. Set FORCE_SEED=1 to overwrite."
    else
        if [ -d "${dst_worlds}/${world_id}" ]; then
            local stamp; stamp="$(date -u +%Y%m%d-%H%M%S)"
            log "FORCE_SEED=1, moving existing world aside to ${world_id}.replaced-${stamp}"
            mv "${dst_worlds}/${world_id}" "${dst_worlds}/${world_id}.replaced-${stamp}"
        fi
        log "Seeding world ${world_id} into ${dst_worlds}"
        mkdir -p "${dst_worlds}"
        cp -a "${world_dir}" "${dst_worlds}/"
    fi

    # Verify the copy landed and is readable.
    local n; n="$(find "${dst_worlds}/${world_id}" -type f | wc -l)"
    [ "${n}" -gt 0 ] || die "Seeded world at ${dst_worlds}/${world_id} contains no files."
    log "World in place: ${n} files at ${dst_worlds}/${world_id}"

    # Pull the island id so ServerDescription.json can point at it.
    if [ -f "${dst_worlds}/${world_id}/WorldDescription.json" ]; then
        SEEDED_ISLAND_ID="$(python3 -c \
            "import json;print(json.load(open('${dst_worlds}/${world_id}/WorldDescription.json')).get('IslandId',''))" \
            2>/dev/null || true)"
        log "IslandId: ${SEEDED_ISLAND_ID:-<unreadable>}"
    fi
}

SEEDED_ISLAND_ID=""
seed_world

# ------------------------------------------------- 4. ServerDescription.json

# The server generates this on first run. Create a minimal one if it is
# missing so the env vars below have something to write into.
if [ ! -f "${DESC}" ]; then
    log "Creating ${DESC}"
    cat > "${DESC}" <<'JSON'
{
  "Version": 1,
  "ServerDescription_Persistent": {
    "InviteCode": "",
    "IsPasswordProtected": false,
    "Password": "",
    "ServerName": "",
    "WorldIslandId": "",
    "MaxPlayerCount": 10,
    "P2pProxyAddress": "0.0.0.0"
  }
}
JSON
fi

WORLD_ISLAND_ID="${WORLD_ISLAND_ID:-${SEEDED_ISLAND_ID}}"

SERVER_NAME="${SERVER_NAME:-}" \
INVITE_CODE="${INVITE_CODE:-}" \
SERVER_PASSWORD="${SERVER_PASSWORD:-}" \
MAX_PLAYERS="${MAX_PLAYERS:-}" \
P2P_PROXY_ADDRESS="${P2P_PROXY_ADDRESS:-}" \
WORLD_ISLAND_ID="${WORLD_ISLAND_ID}" \
USE_DIRECT_CONNECTION="${USE_DIRECT_CONNECTION:-}" \
DESC="${DESC}" \
python3 <<'PY'
import json, os

path = os.environ["DESC"]
with open(path) as f:
    doc = json.load(f)

# Some builds nest settings, some do not. Write into whichever shape exists.
target = doc.get("ServerDescription_Persistent", doc)

def setval(key, env, cast=str):
    raw = os.environ.get(env, "")
    if raw != "":
        target[key] = cast(raw)
        print("  %s = %s" % (key, target[key]))

setval("ServerName",     "SERVER_NAME")
setval("InviteCode",     "INVITE_CODE")
setval("WorldIslandId",  "WORLD_ISLAND_ID")
setval("MaxPlayerCount", "MAX_PLAYERS", int)
setval("P2pProxyAddress","P2P_PROXY_ADDRESS")

pw = os.environ.get("SERVER_PASSWORD", "")
if pw:
    target["Password"] = pw
    target["IsPasswordProtected"] = True

udc = os.environ.get("USE_DIRECT_CONNECTION", "")
if udc:
    target["UseDirectConnection"] = udc.lower() in ("1", "true", "yes")

with open(path, "w") as f:
    json.dump(doc, f, indent=2)
PY

log "ServerDescription.json written."

# Read back the island id and confirm a matching world exists on disk.
FINAL_ID="$(python3 -c \
    "import json;d=json.load(open('${DESC}'));t=d.get('ServerDescription_Persistent',d);print(t.get('WorldIslandId',''))")"

if [ -n "${FINAL_ID}" ]; then
    if find "${SAVED_DIR}" -name WorldDescription.json -exec grep -l "${FINAL_ID}" {} \; 2>/dev/null | grep -q .; then
        log "Confirmed: WorldIslandId ${FINAL_ID} matches a world on disk."
    else
        log "WARNING: WorldIslandId ${FINAL_ID} does not match any world under ${SAVED_DIR}."
        log "The server will likely generate a fresh world instead of loading yours."
    fi
else
    log "WARNING: WorldIslandId is empty. The server will pick or create its own world."
fi

# ------------------------------------------------------------- 5. launch

cd "$(dirname "${SERVER_EXE}")"
log "Starting Windrose server..."

exec xvfb-run -a --server-args="-screen 0 1024x768x24" \
    wine "$(basename "${SERVER_EXE}")" ${SERVER_ARGS:-}
