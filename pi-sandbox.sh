#!/bin/bash
set -euo pipefail

PI_DIR="$HOME/.pi"
WORKSPACE="/tmp/pi-agent-workspace" # The fallback default
declare -a EXTRA_BINDS=()           # Raw -d/--directories specs

usage() {
    cat <<EOF
Usage: $(basename "$0") [-w WORKSPACE] [-d HOST_DIR[:SANDBOX_DIR]] [--] [COMMAND...]

  -w, --workspace DIR   Host directory to bind as /workspace
                        (default: $WORKSPACE)

  -d, --directories SPEC
                        Bind an extra host directory into the sandbox.
                        SPEC is one of:
                          /host/path                 -> read-write at /mnt/<basename>
                          /host/path:/sandbox/path   -> read-write at /sandbox/path
                          ro:/host/path[:/sandbox]   -> read-only bind
                        May be given multiple times.

  -h, --help            Show this help and exit.

Remaining arguments are run inside the sandbox (default: /bin/bash).
EOF
}

# 1. Parse the custom arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--workspace)
            [[ $# -ge 2 ]] || { echo "error: $1 requires an argument" >&2; exit 1; }
            WORKSPACE="$2"; shift 2 ;;
        --workspace=*)
            WORKSPACE="${1#*=}"; shift ;;
        -d|--directories)
            [[ $# -ge 2 ]] || { echo "error: $1 requires an argument" >&2; exit 1; }
            EXTRA_BINDS+=("$2"); shift 2 ;;
        --directories=*)
            EXTRA_BINDS+=("${1#*=}"); shift ;;
        -h|--help)
            usage; exit 0 ;;
        --)
            shift; break ;;
        -*)
            echo "error: unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)
            break ;;
    esac
done

AGENT_ARGS=("$@")
[[ ${#AGENT_ARGS[@]} -eq 0 ]] && AGENT_ARGS=(/bin/bash)

# 2. Ensure directories exist
mkdir -p "$PI_DIR/agent/sessions"
mkdir -p "$WORKSPACE"

# 3. Convert workspace to an absolute path (bwrap strictly requires absolute paths)
WORKSPACE=$(cd "$WORKSPACE" && pwd)

# 4. Resolve the extra directory binds into bwrap arguments
declare -a BIND_ARGS=()
for spec in ${EXTRA_BINDS[@]+"${EXTRA_BINDS[@]}"}; do
    mode="--bind"
    if [[ "$spec" == ro:* ]]; then
        mode="--ro-bind"
        spec="${spec#ro:}"
    fi

    # Split HOST[:SANDBOX]
    if [[ "$spec" == *:* ]]; then
        host="${spec%%:*}"
        guest="${spec#*:}"
    else
        host="$spec"
        guest="/mnt/$(basename "$host")"
    fi

    # Validate
    [[ -d "$host" ]] || { echo "error: not a directory: $host" >&2; exit 1; }
    [[ "$guest" == /* ]] || { echo "error: sandbox path must be absolute: $guest" >&2; exit 1; }

    host=$(cd "$host" && pwd)   # bwrap needs absolute source paths

    # Make sure the parent mount point exists inside the sandbox
    BIND_ARGS+=(--dir "$(dirname "$guest")")
    BIND_ARGS+=("$mode" "$host" "$guest")
done

# 5. Execute the sandbox
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
    ${BIND_ARGS[@]+"${BIND_ARGS[@]}"} \
    --unshare-pid \
    --die-with-parent \
    --chdir /workspace \
    "${AGENT_ARGS[@]}"

