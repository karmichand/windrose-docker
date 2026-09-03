<#
.SYNOPSIS
    Copies your local Windrose world into the Docker build context so it
    gets baked into the image.

.EXAMPLE
    .\stage-save.ps1 -Verify
#>

[CmdletBinding()]
param(
    [string]$LocalSaveRoot = "C:\Users\karmi\AppData\Local\R5\Saved\SaveProfiles\76561198877377174\RocksDB",
    [string]$ProfileId     = "76561198877377174",
    [string]$BuildVersion  = "0.10.0",
    [string]$WorldId       = "8CD21C57E2FC470B85A9602824C0D109",
    [string]$SeedDir       = ".\seed",
    [switch]$Verify
)

$ErrorActionPreference = "Stop"

$source = Join-Path $LocalSaveRoot "$BuildVersion\Worlds\$WorldId"
if (-not (Test-Path $source)) { throw "World not found: $source" }
if (-not (Test-Path (Join-Path $source "WorldDescription.json"))) {
    throw "No WorldDescription.json in $source. Wrong folder."
}

# Windrose must be fully closed. An open RocksDB copies as a half-written
# LSM state and the server will refuse it or load a stale snapshot.
$running = Get-Process -Name "Windrose*" -ErrorAction SilentlyContinue
if ($running) {
    throw "Windrose is running (PID $($running.Id -join ', ')). Close it fully, then re-run."
}

$dest = Join-Path $SeedDir "SaveProfiles\$ProfileId\RocksDB\$BuildVersion\Worlds"
New-Item -ItemType Directory -Force -Path $dest | Out-Null

if (Test-Path (Join-Path $dest $WorldId)) {
    Remove-Item -Recurse -Force (Join-Path $dest $WorldId)
}

Write-Host "Copying $source"
Write-Host "     -> $dest\$WorldId"
Copy-Item -Recurse -Path $source -Destination $dest

$staged = Join-Path $dest $WorldId

if ($Verify) {
    Write-Host "`nVerifying by SHA256..."
    function Manifest($root) {
        $r = (Resolve-Path $root).Path.TrimEnd('\')
        Get-ChildItem $r -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($r.Length + 1).Replace('\','/')
            "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $rel
        } | Sort-Object
    }
    $diff = Compare-Object (Manifest $source) (Manifest $staged)
    if ($diff) {
        $diff | Select-Object -First 20 | ForEach-Object { Write-Host "  $($_.SideIndicator) $($_.InputObject)" }
        throw "Staged copy does not match the source."
    }
    Write-Host "Verified: all files match." -ForegroundColor Green
}

$island = (Get-Content (Join-Path $staged "WorldDescription.json") -Raw | ConvertFrom-Json).IslandId
$count  = (Get-ChildItem $staged -Recurse -File).Count
$size   = (Get-ChildItem $staged -Recurse -File | Measure-Object Length -Sum).Sum / 1MB

Write-Host ""
Write-Host ("Staged {0} files, {1:N1} MB" -f $count, $size)
Write-Host "IslandId: $island"
Write-Host ""
Write-Host "Next: copy this whole folder to the server, then run"
Write-Host "  docker compose build && docker compose up -d"
