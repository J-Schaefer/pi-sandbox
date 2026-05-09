#!/bin/bash

PI_DIR="$HOME/.pi"
WORKSPACE="/tmp/pi-agent-workspace" # The fallback default

# 1. Parse the custom workspace argument
if [[ "$1" == "-w" ]]; then
    WORKSPACE="$2"
    shift 2 # Remove the '-w' and the 'path' so they aren't passed to the agent
fi

# 2. Ensure directories exist
mkdir -p "$PI_DIR/agent/sessions"
mkdir -p "$WORKSPACE"

# 3. Convert workspace to an absolute path (bwrap strictly requires absolute paths)
WORKSPACE=$(cd "$WORKSPACE" && pwd)

# 4. Execute the sandbox
exec bwrap \
    --unshare-uts \
    --hostname pi-sandbox \
    --ro-bind /usr /usr \
    --symlink usr/lib /lib \
    --symlink usr/lib64 /lib64 \
    --symlink usr/bin /bin \
    --symlink usr/sbin /sbin \
    --ro-bind /etc /etc \
    --proc /proc \
    --dev /dev \
    --tmpfs /tmp \
    --ro-bind "$PI_DIR" "$PI_DIR" \
    --bind "$PI_DIR/agent" "$PI_DIR/agent" \
    --bind "$WORKSPACE" /workspace \
    --unshare-pid \
    --die-with-parent \
    --chdir /workspace \
    "${@:-/bin/bash}"