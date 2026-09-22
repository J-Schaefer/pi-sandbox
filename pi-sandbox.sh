#!/bin/bash
set -euo pipefail

PI_DIR="${HOME}/.pi"
WORKSPACE="/tmp/pi-agent-workspace"    # The fallback default
USER_LOCAL="${HOME}/.local"              # Host dir of user-local installs
USER_LOCAL_MOUNT="/userlocal"          # Where it appears inside the sandbox
NVM_DIR_HOST="${NVM_DIR:-${HOME}/.config/nvm}"  # Matches your bashrc
NVM_MOUNT="/nvm"                       # Where nvm appears inside the sandbox
declare -a EXTRA_BINDS=()              # Raw -d/--directories specs

usage() {
    cat <<EOF
Usage: $(basename "$0") [-w WORKSPACE] [-d HOST_DIR[:SANDBOX_DIR]] [--] [COMMAND...]

  -w, --workspace DIR   Host directory to bind as /workspace
                        (default: ${WORKSPACE})

  -d, --directories SPEC
                        Bind an extra host directory into the sandbox.
                        SPEC is one of:
                          /host/path                 -> read-write at /mnt/<basename>
                          /host/path:/sandbox/path   -> read-write at /sandbox/path
                          ro:/host/path[:/sandbox]   -> read-only bind
                        May be given multiple times.

  -h, --help            Show this help and exit.

  ~/.local is bound read-only at ${USER_LOCAL_MOUNT}.
  nvm (${NVM_DIR_HOST}) is bound read-only at ${NVM_MOUNT} and the
  active node bin directory is prepended to PATH.

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
mkdir -p "${PI_DIR}/agent/sessions"
mkdir -p "${WORKSPACE}"

# 3. Convert workspace to an absolute path (bwrap strictly requires absolute paths)
WORKSPACE=$(cd "${WORKSPACE}" && pwd)

# 4. Read-only bind of ~/.local at ${USER_LOCAL_MOUNT} (only if it exists on the host).
declare -a USER_LOCAL_ARGS=()
if [[ -d "${USER_LOCAL}" ]]; then
    USER_LOCAL=$(cd "${USER_LOCAL}" && pwd)
    USER_LOCAL_ARGS=(
        --dir "${USER_LOCAL_MOUNT}"
        --ro-bind "${USER_LOCAL}" "${USER_LOCAL_MOUNT}"
    )
fi

# 5. Resolve the active nvm node install (host side) and bind nvm read-only.
resolve_nvm_node_bin() {
    local candidate=""

    # Preferred: ask nvm which node the "default" alias resolves to.
    if [[ -s "${NVM_DIR_HOST}/nvm.sh" ]]; then
        candidate="$(
            set +eu                      # nvm.sh is not -u/-e clean
            export NVM_DIR="${NVM_DIR_HOST}"
            # shellcheck disable=SC1090
            . "$NVM_DIR/nvm.sh" >/dev/null 2>&1
            nvm which default 2>/dev/null || true
        )"
        candidate="${candidate%%$'\n'*}"
        candidate="${candidate%$'\r'}"
    fi
    if [[ -x "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    # Fallback: newest installed version, by version sort.
    local -a nodes=()
    shopt -s nullglob
    nodes=( "$NVM_DIR_HOST"/versions/node/*/bin/node )
    shopt -u nullglob
    ((${#nodes[@]})) || return 1
    printf '%s\n' "${nodes[@]}" | sort -V | tail -n1
}

declare -a NVM_ARGS=()
NODE_BIN_DIR_SANDBOX=""
if [[ -d "${NVM_DIR_HOST}" ]]; then
    NVM_DIR_HOST=$(cd "${NVM_DIR_HOST}" && pwd)

    NODE_BIN="$(resolve_nvm_node_bin || true)"
    if [[ -n "${NODE_BIN}" ]]; then
        NODE_BIN_DIR="$(dirname "${NODE_BIN}")"
        NODE_BIN_DIR_SANDBOX="${NVM_MOUNT}/${NODE_BIN_DIR#"${NVM_DIR_HOST}"/}"
    else
        echo "warning: nvm found at ${NVM_DIR_HOST} but no node install detected" >&2
    fi

    NVM_ARGS=(
        --dir "${NVM_MOUNT}"
        --ro-bind "${NVM_DIR_HOST}" "${NVM_MOUNT}"
    )
fi

# 6. Resolve the extra directory binds into bwrap arguments
declare -a BIND_ARGS=()
for spec in ${EXTRA_BINDS[@]+"${EXTRA_BINDS[@]}"}; do
    mode="--bind"
    if [[ "${spec}" == ro:* ]]; then
        mode="--ro-bind"
        spec="${spec#ro:}"
    fi

    # Split HOST[:SANDBOX]
    if [[ "{$spec}" == *:* ]]; then
        host="${spec%%:*}"
        guest="${spec#*:}"
    else
        host="$spec"
        guest="/mnt/$(basename "$host")"
    fi

    # Validate
    [[ -d "$host" ]] || { echo "error: not a directory: $host" >&2; exit 1; }
    [[ "${guest}" == /* ]] || { echo "error: sandbox path must be absolute: ${guest}" >&2; exit 1; }

    host=$(cd "$host" && pwd)   # bwrap needs absolute source paths

    # Make sure the parent mount point exists inside the sandbox
    BIND_ARGS+=(--dir "$(dirname "${guest}")")
    BIND_ARGS+=("${mode}" "${host}" "${guest}")
done

# 7. Build the in-sandbox PATH
declare -a PATH_PARTS=()
if [[ -n "${NODE_BIN_DIR_SANDBOX}" ]]; then
    PATH_PARTS+=("${NODE_BIN_DIR_SANDBOX}")   # node/npm/npx from nvm
fi
if ((${#USER_LOCAL_ARGS[@]})); then
    PATH_PARTS+=("${USER_LOCAL_MOUNT}/bin")
fi
PATH_PARTS+=(/usr/local/bin /usr/bin /bin)
SANDBOX_PATH="$(IFS=:; printf '%s' "${PATH_PARTS[*]}")"

# 8. Environment for the sandbox
declare -a ENV_ARGS=(--setenv PATH "$SANDBOX_PATH" --setenv npm_config_cache /tmp/.npm)
if ((${#NVM_ARGS[@]})); then
    ENV_ARGS+=(--setenv NVM_DIR "$NVM_MOUNT")
    [[ -n "$NODE_BIN_DIR_SANDBOX" ]] && ENV_ARGS+=(--setenv NVM_BIN "$NODE_BIN_DIR_SANDBOX")
fi
# Proxy is routing, not isolation: only inject if one is actually configured/running
if [[ -n "${PI_PROXY:-}" ]]; then
    ENV_ARGS+=(--setenv HTTP_PROXY "$PI_PROXY" --setenv HTTPS_PROXY "$PI_PROXY"
               --setenv NO_PROXY "localhost,127.0.0.1")
fi


# 9. Execute the sandbox
exec bwrap \
    --unshare-all \
    --share-net \
    --hostname pi-sandbox \
    --new-session \
    --die-with-parent \
    --ro-bind /usr /usr \
    --symlink usr/lib /lib \
    --symlink usr/lib64 /lib64 \
    --symlink usr/bin /bin \
    --symlink usr/sbin /sbin \
    --ro-bind /etc /etc \
    --proc /proc \
    --dev /dev \
    --size 2147483648 \
    --tmpfs /tmp \
    --tmpfs /home/agent \
    --ro-bind "${PI_DIR}" "${PI_DIR}" \
    --bind "${PI_DIR}/agent" "${PI_DIR}/agent" \
    --bind "${WORKSPACE}" /workspace \
    "${USER_LOCAL_ARGS[@]}" \
    "${NVM_ARGS[@]}" \
    "${BIND_ARGS[@]}" \
    --clearenv \
    --setenv HOME /home/agent \
    --setenv TERM "${TERM:-dumb}" \
    "${ENV_ARGS[@]}" \
    --chdir /workspace \
    "${AGENT_ARGS[@]}"
