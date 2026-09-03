#!/usr/bin/env bash
# Run on the Docker host. Gives uid 1000 ownership of both volumes, which
# Docker otherwise creates root-owned for the nested R5/Saved mountpoint.
set -euo pipefail

PROJECT="${1:-windrose-docker}"

for v in "${PROJECT}_windrose-install" "${PROJECT}_windrose-save"; do
    if docker volume inspect "$v" >/dev/null 2>&1; then
        echo "Fixing $v"
        docker run --rm -v "$v":/v debian:bookworm-slim chown -R 1000:1000 /v
    else
        echo "Volume $v does not exist yet, skipping"
    fi
done

echo
echo "Free space on the Docker root:"
df -h "$(docker info -f '{{.DockerRootDir}}')"
