<#
.SYNOPSIS
    Finds your local Windrose world's latest backup and stages it into the
    exact folder structure the server expects.

.DESCRIPTION
    Since game update 0.10.0.5.120, RocksDB_v2_Backups\Worlds\<WorldId>\
    holds periodic backups as zips (<WorldId>_<GameVersion>_<timestamp>.zip),
    plus a <WorldId>_<GameVersion>_Latest.zip. These are RocksDB BackupEngine
    checkpoints (Checkpoint/private + Checkpoint/shared_checksum, dedup'd SST
    files) -- not a plain folder of database files -- so they must NOT be
    extracted by hand. The game engine itself knows how to restore this
    format via AutoLoadLatestBackupIfHasBroken.

    This script finds the world (searching recursively, prompting if there's
    more than one), copies its _Latest.zip untouched into a staging folder
    shaped exactly like the server's save volume
    (SaveProfiles/Default/RocksDB_v2_Backups/Worlds/<WorldId>/, "Default"
    profile rather than your Steam ID -- that's the only profile the server
    scans), and does nothing else to it.

    This does not touch the server. scp the result over and place it in the
    volume yourself as described in README.md under "Migrating your save".

.EXAMPLE
    .\stage-save.ps1 -Verify
    Lists every world found locally and prompts you to pick one.

.EXAMPLE
    .\stage-save.ps1 -WorldId 8CD21C57E2FC470B85A9602824C0D109 -Verify
    Stages that specific world without prompting.
#>

[CmdletBinding()]
param(
    [string]$SteamId      = "76561198877377174",
    # Leave unset to be shown every world found locally and pick one.
    [string]$WorldId      = "",
    [string]$LocalAppData = $env:LOCALAPPDATA,
    [string]$OutDir       = ".\migration-staging",
    [switch]$Verify
)

$ErrorActionPreference = "Stop"

# Windrose must be fully closed so the client isn't mid-write on a backup.
$running = Get-Process -Name "Windrose*" -ErrorAction SilentlyContinue
if ($running) {
    throw "Windrose is running (PID $($running.Id -join ', ')). Close it fully, then re-run."
}

$worldsRoot = Join-Path $LocalAppData "R5\Saved\SaveProfiles\$SteamId\RocksDB_v2_Backups\Worlds"
if (-not (Test-Path $worldsRoot)) {
    throw "No RocksDB_v2_Backups\Worlds found at $worldsRoot. Either the Steam ID is wrong, or your client hasn't updated past 0.10.0.5.120 yet (older clients only have RocksDB, which this new server setup can't use -- see legacy-wine-setup/ for that era)."
}

# A world folder is any directory directly under Worlds\ that holds at least
# one backup zip named after itself.
$allWorlds = Get-ChildItem $worldsRoot -Directory |
    Where-Object { Get-ChildItem $_.FullName -Filter "$($_.Name)_*.zip" -File -ErrorAction SilentlyContinue } |
    Sort-Object LastWriteTime -Descending

if (-not $allWorlds) {
    throw "No world backup zips found anywhere under $worldsRoot."
}

function Get-LatestZip($worldDir) {
    $zips = Get-ChildItem $worldDir.FullName -Filter "$($worldDir.Name)_*.zip" -File
    $latest = $zips | Where-Object { $_.Name -like "*_Latest.zip" } | Select-Object -First 1
    if (-not $latest) {
        # Fall back to the most recently modified timestamped backup if
        # there's no _Latest for some reason.
        $latest = $zips | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    $latest
}

if ($WorldId) {
    # Explicit -WorldId on the command line: filter to matches, no prompt.
    $found = $allWorlds | Where-Object { $_.Name -eq $WorldId -or $_.Name -like "$WorldId*" }
    if (-not $found) {
        Write-Host "`nNo world found matching '$WorldId'. Worlds that do exist under $worldsRoot`:"
        $allWorlds | ForEach-Object { Write-Host "  $($_.Name)  (modified $($_.LastWriteTime))" }
        throw "Adjust -WorldId (or -SteamId) to match one of the worlds above."
    }
    if ($found.Count -gt 1) {
        Write-Host "`nMultiple matching worlds found, using the most recently modified:"
        $found | ForEach-Object { Write-Host "  $($_.LastWriteTime)  $($_.FullName)" }
    }
    $worldDir = $found[0]
} elseif ($allWorlds.Count -eq 1) {
    $worldDir = $allWorlds[0]
    Write-Host "One world found: $($worldDir.FullName)"
} else {
    Write-Host "`nMultiple worlds found under $worldsRoot`:`n"
    for ($i = 0; $i -lt $allWorlds.Count; $i++) {
        $latestZip = Get-LatestZip $allWorlds[$i]
        Write-Host ("  [{0}] {1}   (latest backup: {2})" -f $i, $allWorlds[$i].Name, $latestZip.Name)
    }
    Write-Host ""
    $choice = Read-Host "Enter the number of the world to stage"
    if ($choice -notmatch '^\d+$' -or [int]$choice -ge $allWorlds.Count) {
        throw "'$choice' is not one of the listed numbers."
    }
    $worldDir = $allWorlds[[int]$choice]
}

$WorldId = $worldDir.Name
$zip = Get-LatestZip $worldDir
if (-not $zip) {
    throw "No backup zip found inside $($worldDir.FullName)."
}
Write-Host "`nUsing: $($zip.FullName)"

# Staged layout matches the server's save volume exactly: Default profile,
# flat Worlds/<WorldId>/<zip>, zip left untouched.
$stagedWorld = Join-Path $OutDir "SaveProfiles\Default\RocksDB_v2_Backups\Worlds\$WorldId"
New-Item -ItemType Directory -Force -Path $stagedWorld | Out-Null

$stagedZip = Join-Path $stagedWorld $zip.Name
Write-Host "Copying to $stagedZip"
Copy-Item -Path $zip.FullName -Destination $stagedZip -Force

if ($Verify) {
    $srcHash   = (Get-FileHash $zip.FullName -Algorithm SHA256).Hash
    $stagedHash = (Get-FileHash $stagedZip -Algorithm SHA256).Hash
    if ($srcHash -ne $stagedHash) {
        throw "Staged copy does not match the source (SHA256 mismatch)."
    }
    Write-Host "Verified: SHA256 matches." -ForegroundColor Green
}

Write-Host ""
Write-Host ("Staged: {0} ({1:N1} MB)" -f $zip.Name, ($zip.Length / 1MB))
Write-Host ""
Write-Host "Next: scp the staged folder to the server, e.g.:"
Write-Host "  scp -r $OutDir\SaveProfiles nathan@<server-ip>:/opt/windrose-docker/migration-staging/"
Write-Host "then follow README.md ""Migrating your save"" to place it in the volume."
Write-Host ""
Write-Host "Do NOT unzip $($zip.Name) yourself -- it's a RocksDB backup checkpoint,"
Write-Host "not a plain folder of files. The server restores it internally."
