# Windrose dedicated server, containerized

## What this is

Kraken Express (the developers) publish an official native-Linux dedicated
server image. This compose stack runs it via
[`pfeiffermax/windrose-dedicated-server`](https://hub.docker.com/r/pfeiffermax/windrose-dedicated-server),
a community wrapper that tracks the official image nightly and adds env-var
configuration and a persistent save volume.

No Wine, no SteamCMD, no Xvfb. An earlier version of this repo ran the
Windows binary under Wine because at the time there was no Linux build —
those files are kept in [`legacy-wine-setup/`](legacy-wine-setup/) for
reference but are not used by anything here anymore.

## Layout

```
windrose-docker/
  docker-compose.yml
  .env.example
  stage-save.ps1         run on Windows to prepare a world for upload
  legacy-wine-setup/     obsolete, kept for reference only
  seed/                  obsolete Wine-era world export, safe to delete
```

Two services: `init-container` (one-shot, fixes save-volume ownership on
every start) and `windrose-server` (the game). World migration below is done
straight from the command line via a throwaway helper container — no web UI,
no extra exposed port.

## Steps

```bash
cd /opt/windrose-docker
cp .env.example .env
$EDITOR .env          # set INVITE_CODE at minimum
docker compose up -d
docker compose logs -f windrose-server
```

The server needs to start once to generate `ServerDescription.json` before a
world can be pointed at — this first boot is slower.

## Migrating your existing save

Since game update `0.10.0.5.120`, the save format changed: the live folder
the server actually plays out of is `RocksDB_v2` (versioned per game build,
e.g. `RocksDB_v2/0.10.0/Worlds/`), and the transferable, exportable copies
live in `RocksDB_v2_Backups`. **Only ever touch `_Backups`** — never write
directly into `RocksDB_v2`, the server owns that.

The backups themselves are RocksDB BackupEngine checkpoints — zips with a
`Checkpoint/private/` + `Checkpoint/shared_checksum/` layout, not a plain
folder of database files. **Never extract these yourself.** They must be
copied over as-is; the game engine restores them internally (that's what
`AUTO_LOAD_LATEST_BACKUP_IF_HAS_BROKEN` triggers).

1. Close the game client. Stop the server container:
   ```bash
   docker compose stop windrose-server
   ```
2. On your gaming PC, run `stage-save.ps1` (in this repo). Each world under
   `RocksDB_v2_Backups\Worlds\<WorldId>\` holds periodic backup zips plus a
   `<WorldId>_<GameVersion>_Latest.zip` — the script finds the right world
   (prompting if there's more than one) and copies just that `_Latest.zip`,
   untouched:
   ```powershell
   .\stage-save.ps1 -Verify
   ```
   This produces `migration-staging\SaveProfiles\Default\RocksDB_v2_Backups\Worlds\<WorldId>\<WorldId>_<GameVersion>_Latest.zip`.
3. Copy the whole staged tree to the server:
   ```powershell
   scp -r .\migration-staging\SaveProfiles nathan@<server-ip>:/opt/windrose-docker/migration-staging/
   ```
4. On the server, drop it straight into the save volume and fix ownership
   with a throwaway container — no need to run `windrose-server` or anything
   else for this:
   ```bash
   cd /opt/windrose-docker
   docker run --rm -v windrose-save-dir:/v -v "$(pwd)/migration-staging":/src:ro alpine:3.23 sh -c "
     cp -a /src/SaveProfiles/Default/RocksDB_v2_Backups/Worlds/. /v/SaveProfiles/Default/RocksDB_v2_Backups/Worlds/ &&
     chown -R 10001:10001 /v/SaveProfiles/Default/RocksDB_v2_Backups/Worlds
   "
   ```
   The server only ever recognizes worlds under the `Default` profile, not
   your Steam ID — that's why the staged path says `Default` regardless of
   whose save this is. Sanity-check the result before moving on:
   ```bash
   docker run --rm -v windrose-save-dir:/v alpine:3.23 \
     find /v/SaveProfiles/Default/RocksDB_v2_Backups/Worlds -maxdepth 2
   ```
   You should see `.../Worlds/<WorldId>/<WorldId>_<GameVersion>_Latest.zip`
   — the zip itself, still zipped.
5. In `.env`, set `WORLD_ISLAND_ID` to that world's folder name and make sure
   `AUTO_LOAD_LATEST_BACKUP_IF_HAS_BROKEN=true` (the default in
   `.env.example`), then:
   ```bash
   docker compose up -d
   docker compose logs -f windrose-server
   ```

**Expect one or two restarts before it takes.** The server validates
`WORLD_ISLAND_ID` against what's currently live under `RocksDB_v2` — which
your migrated world isn't yet, since it only exists under `_Backups`. You'll
see a log line like:

```
World with WORLD_ISLAND_ID <id> does not exist. Available worlds: [...]
```

`restart: unless-stopped` keeps retrying, and on a successful pass the server
restores your world from `_Backups` into the live `RocksDB_v2/<version>/`
path itself (that's what `AUTO_LOAD_LATEST_BACKUP_IF_HAS_BROKEN` does). Give
it a minute or two of restarts rather than assuming it's stuck.

### Cleaning up stray worlds

Every restart where `WORLD_ISLAND_ID` doesn't resolve leaves behind an
auto-generated placeholder world under
`SaveProfiles/Default/RocksDB_v2/<version>/Worlds/`. Once your real world is
confirmed loading and playable, remove the others:

```bash
docker run --rm -v windrose-save-dir:/v alpine:3.23 sh -c \
  'rm -rf /v/SaveProfiles/Default/RocksDB_v2/*/Worlds/<stray-id>'
```

## Networking

Invite-code play (default) is P2P: a client resolves your invite code, then
negotiates a direct connection via ICE (STUN, falling back to a TURN relay).
This is fragile in practice — symmetric NAT, or simply a client on the same
LAN as the server trying to reach it via a public-IP-negotiated path (NAT
hairpin/loopback, which plenty of consumer routers don't support), both
produce the same symptom: the client shows up and connects at the account
level, then the log fills with

```
Check consent was failed for IceControlling. Reach timeout 10000 ms
...Error on Ue P2P connecting. Error 'Failed to connect to remote'
```

**For same-network play, skip P2P entirely and use direct connection
instead** — it's a plain IP:port connection, no NAT traversal involved. Set
`USE_DIRECT_CONNECTION=true` in `.env` and leave `NETWORK_MODE=host` as-is —
host networking already exposes `DIRECT_CONNECTION_SERVER_PORT` (default
28050) directly on the host's real IP, so no `ports:` mapping or switch to
bridge networking is needed. Players connect via the server's LAN IP and
that port instead of an invite code.

Only switch `NETWORK_MODE=bridge` (and uncomment the `ports:` block in
`docker-compose.yml`) if you specifically need Docker's bridge networking for
some other reason — it isn't required for direct connection to work, and
host networking is the simpler default either way. If you later want players
outside your LAN to join over direct connection, forward
`DIRECT_CONNECTION_SERVER_PORT` on both TCP and UDP on your router to the
server's LAN IP.

Behind a Proxmox CT: unprivileged containers can be awkward for Docker. If
`docker compose up` fails on overlayfs, either use a privileged CT or add
`features: nesting=1,keyctl=1` to the CT config.

## Backups

The world lives in the `windrose-save-dir` named volume:

```bash
docker compose stop windrose-server
docker run --rm -v windrose-save-dir:/data \
  -v /var/backups/windrose:/backup debian:bookworm-slim \
  tar czf /backup/save-$(date +%F-%H%M).tar.gz -C /data .
docker compose start windrose-server
```

Better, if the CT sits on ZFS: change the volume to a bind mount pointing at
a dataset on the Proxmox host and snapshot it there instead.

## Updates

The compose file pins `pfeiffermax/windrose-dedicated-server:latest` with
`pull_policy: always`, so `docker compose up -d` pulls and restarts on a new
release. Automate it with a cron job if you want — see
[windrose-server-update.sh](https://github.com/max-pfeiffer/windrose-dedicated-server-docker-helm/blob/main/examples/docker-compose/windrose-server-update.sh)
in the upstream repo.

## How the world-selection logic actually works

If you need to debug this further, the relevant source is
[`build/scripts/update_server_description.py`](https://github.com/max-pfeiffer/windrose-dedicated-server-docker-helm/blob/main/build/scripts/update_server_description.py)
in the upstream repo — it's a thin Python wrapper that only validates
`WORLD_ISLAND_ID` against what's already live under
`SaveProfiles/Default/RocksDB_v2/<version>/Worlds/` before handing off to the
actual (closed-source) game engine binary. The backup-restore behavior
described above happens inside the engine itself, gated by
`AutoLoadLatestBackupIfHasBroken`, not in that wrapper script.
