#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
{
    date -u
    uname -a
    df -h "$BUILD"
    free -h
    docker version
    python3 --version
    git --version
} | tee "$BUILD/logs/preflight.log"
# Refuse to start a many-hour sync below the minimum working set. The build
# volume has already been enlarged from the runner's root and temp filesystems.
AVAILABLE="$(df -B1 --output=avail "$BUILD" | tail -1 | tr -d ' ')"
MINIMUM=$((40 * 1024 * 1024 * 1024))
if (( AVAILABLE < MINIMUM )); then
    echo "At least 40 GiB free required before sync; found $AVAILABLE bytes after runner disk expansion. Use a larger ephemeral runner." | tee -a "$BUILD/logs/preflight.log" >&2
    exit 1
fi
