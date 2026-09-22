#!/bin/bash
set -euo pipefail

PI_DIR="$HOME/.pi"
# Default workspace = current directory, NOT a fixed hidden folder.
# (A fixed default like "$HOME/.pi-agent/workspace" is never populated
# unless you remember to copy files into it -- it looks "always empty"
# because it silently is, regardless of where you ran the script from.)
WORKSPACE="$(pwd)"                          # host dir bound rw at $HOME_AGENT/workspace
USER_LOCAL="$HOME/.local"                   # host user-local installs (ro)
NVM_DIR_HOST="${NVM_DIR:-$HOME/.config/nvm}" # matches your bashrc (ro)
SANDBOX_USER=""                             # resolved in step 2 (default: current username)
HOME_AGENT="/home/agent"                    # placeholder for --help text; recomputed in step 2

declare -a EXTRA_BINDS=()

# Resolve a directory to a symlink-free absolute path (bwrap needs absolute paths)
abs() { ( cd -- "$1" 2>/dev/null && pwd -P ); }

usage() {
    cat <<EOF
Usage: $(basename "$0") [-w WORKSPACE] [-u USER] [-d HOST_DIR[:SANDBOX_DIR]] [--] [COMMAND...]

  -w, --workspace DIR   Host directory bound rw at ${HOME_AGENT}/workspace
                        (default: the current directory, i.e. $(pwd))

  -u, --user NAME       Username inside the sandbox; also determines its
                        \$HOME (/home/NAME). Default: your current host
                        username (falls back to "agent" if undetectable).
                        NOTE: this default is LESS isolated than a fixed
                        generic name -- it exposes your host username to
                        the sandboxed process -- but many compiled
                        binaries / virtualenvs / shebangs hardcode an
                        absolute \$HOME path and only work if it matches.

  -d, --directories SPEC
                        Bind an extra host directory into the sandbox.
                        SPEC is one of:
                          /host/path                 -> rw, same absolute
                                                         path inside the
                                                         sandbox as on the
                                                         host (needed for
                                                         binaries with
                                                         hardcoded paths)
                          /host/path:/sandbox/path   -> rw at /sandbox/path
                          ro:/host/path[:/sandbox]   -> read-only bind
                        May be given multiple times. Destinations under
                        /usr, /etc, /proc, /dev, /sys, /tmp, /run, /boot,
                        or the sandbox's reserved home paths (workspace,
                        .local, .nvm, .pi) are rejected.

  -h, --help            Show this help and exit.

Sandbox layout (home = ${HOME_AGENT}, a tmpfs):
  ${HOME_AGENT}/workspace  rw   ${WORKSPACE}
  ${HOME_AGENT}/.local     ro   ${USER_LOCAL}
  ${HOME_AGENT}/.nvm       ro   ${NVM_DIR_HOST}
  ${HOME_AGENT}/.pi        ro   ${PI_DIR}  (${HOME_AGENT}/.pi/agent is rw)

Network is shared with the host (outbound internet works). Export
PI_PROXY=http://host:port before invoking to route via a local proxy.
Only the whitelisted variables are exported into the sandbox.

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
        -u|--user)
            [[ $# -ge 2 ]] || { echo "error: $1 requires an argument" >&2; exit 1; }
            SANDBOX_USER="$2"; shift 2 ;;
        --user=*)
            SANDBOX_USER="${1#*=}"; shift ;;
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
if [[ ${#AGENT_ARGS[@]} -eq 0 ]]; then AGENT_ARGS=(/bin/bash); fi

# 2. Resolve the sandbox identity (username -> $HOME inside the sandbox)
SANDBOX_USER="${SANDBOX_USER:-${USER:-$(id -un 2>/dev/null || echo agent)}}"

# The username is embedded straight into a filesystem path below, so it
# must not contain '/', '..', or other path metacharacters.
[[ "${SANDBOX_USER}" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || {
    echo "error: invalid --user value: ${SANDBOX_USER}" >&2
    exit 1
}
HOME_AGENT="/home/${SANDBOX_USER}"

# 3. Ensure host directories exist
mkdir -p "${PI_DIR}/agent/sessions" "${WORKSPACE}"

# 4. bwrap requires absolute paths
WORKSPACE="$(abs "${WORKSPACE}")" || { echo "error: cannot resolve workspace: ${WORKSPACE}" >&2; exit 1; }

# 5. Dotdirs into the sandbox home
declare -a HOME_ARGS=()
have_userlocal=0
if [[ -d "${USER_LOCAL}" ]]; then
    USER_LOCAL="$(abs "${USER_LOCAL}")" || { echo "error: cannot resolve ${USER_LOCAL}" >&2; exit 1; }
    HOME_ARGS+=(--dir "${HOME_AGENT}/.local" --ro-bind "${USER_LOCAL}" "${HOME_AGENT}/.local")
    have_userlocal=1
fi

if [[ -d "${PI_DIR}" ]]; then
    PI_DIR="$(abs "${PI_DIR}")" || { echo "error: cannot resolve ${PI_DIR}" >&2; exit 1; }
    HOME_ARGS+=(--dir "${HOME_AGENT}/.pi" --ro-bind "${PI_DIR}" "${HOME_AGENT}/.pi")
    if [[ -w "${PI_DIR}/agent" ]]; then
        HOME_ARGS+=(--dir "${HOME_AGENT}/.pi/agent" --bind "${PI_DIR}/agent" "${HOME_AGENT}/.pi/agent")
    fi
fi

# 6. Resolve the active nvm node install (host side) and bind nvm read-only
resolve_nvm_node_bin() {
    local candidate
    if [[ -s "${NVM_DIR_HOST}/nvm.sh" ]]; then
        candidate="$(
            set +eu
            export NVM_DIR="${NVM_DIR_HOST}"
            # shellcheck disable=SC1090
            . "$NVM_DIR/nvm.sh" >/dev/null 2>&1
            nvm which default 2>/dev/null || true
        )"
        if [[ -n "${candidate:-}" && -x "${candidate:-}" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    fi
    local -a nodes
    shopt -s nullglob
    nodes=("${NVM_DIR_HOST}"/versions/node/*/bin/node)
    shopt -u nullglob
    if (( ${#nodes[@]} )); then
        printf '%s\n' "${nodes[@]}" | sort -V | tail -n1
        return 0
    fi
    return 1
}

declare -a NVM_ARGS=()
have_nvm=0
NODE_BIN_DIR_SANDBOX=""
if [[ -d "${NVM_DIR_HOST}" ]]; then
    NVM_DIR_HOST="$(abs "${NVM_DIR_HOST}")" || { echo "error: cannot resolve ${NVM_DIR_HOST}" >&2; exit 1; }
    NVM_ARGS=(--dir "${HOME_AGENT}/.nvm" --ro-bind "${NVM_DIR_HOST}" "${HOME_AGENT}/.nvm")
    have_nvm=1
    NODE_BIN="$(resolve_nvm_node_bin || true)"
    if [[ -n "${NODE_BIN}" ]]; then
        NODE_BIN_DIR="$(dirname "${NODE_BIN}")"
        if [[ "${NODE_BIN_DIR}" == "${NVM_DIR_HOST}"/* ]]; then
            NODE_BIN_DIR_SANDBOX="${HOME_AGENT}/.nvm/${NODE_BIN_DIR#"${NVM_DIR_HOST}"/}"
        fi
    else
        echo "warning: nvm found at ${NVM_DIR_HOST} but no node install detected" >&2
    fi
fi

# 7. Reserved sandbox-home paths that this script itself binds. -d specs
#    are not allowed to target these (they'd silently shadow the mounts
#    set up above); everything else under home is fair game.
declare -a RESERVED_HOME_PATHS=("${HOME_AGENT}/workspace")
(( have_userlocal )) && RESERVED_HOME_PATHS+=("${HOME_AGENT}/.local")
[[ -d "${PI_DIR}" ]] && RESERVED_HOME_PATHS+=("${HOME_AGENT}/.pi")
(( have_nvm )) && RESERVED_HOME_PATHS+=("${HOME_AGENT}/.nvm")

is_protected_guest() {
    local guest="$1" reserved
    case "${guest}" in
        /|/usr|/usr/*|/etc|/etc/*|/proc|/proc/*|/dev|/dev/*|/sys|/sys/*|/tmp|/tmp/*|/run|/run/*|/boot|/boot/*)
            return 0 ;;
    esac
    [[ "${guest}" == "${HOME_AGENT}" ]] && return 0
    for reserved in "${RESERVED_HOME_PATHS[@]}"; do
        [[ "${guest}" == "${reserved}" || "${guest}" == "${reserved}/"* ]] && return 0
    done
    return 1
}

# 8. Resolve the extra directory binds (-d) into bwrap arguments
declare -a BIND_ARGS=()
for spec in "${EXTRA_BINDS[@]}"; do
    mode=--bind
    if [[ "${spec}" == ro:* ]]; then
        mode=--ro-bind
        spec="${spec#ro:}"
    fi

    if [[ "${spec}" == *:* ]]; then
        host="${spec%%:*}"
        guest="${spec#*:}"
    else
        # Bare "-d /host/path": mirror it at the SAME absolute path
        # inside the sandbox, instead of an arbitrary /mnt/name.
        host="${spec}"
        guest=""
    fi

    [[ -n "${host}" ]] || { echo "error: empty host path in -d spec: ${spec}" >&2; exit 1; }
    [[ -d "${host}" ]] || { echo "error: not a directory: ${host}" >&2; exit 1; }
    host="$(abs "${host}")" || { echo "error: cannot resolve: ${host}" >&2; exit 1; }

    [[ -n "${guest}" ]] || guest="${host}"
    guest="$(realpath -m -- "${guest}")"   # normalize; blocks "../.." tricks

    [[ "${guest}" == /* ]] || { echo "error: sandbox path must be absolute: ${guest}" >&2; exit 1; }
    if is_protected_guest "${guest}"; then
        echo "error: refusing to bind over protected path: ${guest}" >&2
        exit 1
    fi

    BIND_ARGS+=(--dir "$(dirname "${guest}")" "${mode}" "${host}" "${guest}")
done

# 9. Build the in-sandbox PATH
declare -a PATH_PARTS=()
[[ -n "${NODE_BIN_DIR_SANDBOX}" ]] && PATH_PARTS+=("${NODE_BIN_DIR_SANDBOX}")
(( have_userlocal )) && PATH_PARTS+=("${HOME_AGENT}/.local/bin")
PATH_PARTS+=(/usr/local/bin /usr/bin /bin)
SANDBOX_PATH="$(IFS=:; printf '%s' "${PATH_PARTS[*]}")"

# 10. Environment for the sandbox (explicit whitelist; --clearenv below)
declare -a ENV_ARGS=(
    --setenv PATH "${SANDBOX_PATH}"
    --setenv HOME "${HOME_AGENT}"
    --setenv USER "${SANDBOX_USER}"
    --setenv LOGNAME "${SANDBOX_USER}"
    --setenv TERM "${TERM:-dumb}"
    --setenv npm_config_cache /tmp/.npm
)
if (( have_nvm )); then
    ENV_ARGS+=(--setenv NVM_DIR "${HOME_AGENT}/.nvm")
    [[ -n "${NODE_BIN_DIR_SANDBOX}" ]] && ENV_ARGS+=(--setenv NVM_BIN "${NODE_BIN_DIR_SANDBOX}")
fi
if [[ -n "${PI_PROXY:-}" ]]; then
    ENV_ARGS+=(--setenv HTTP_PROXY "${PI_PROXY}" --setenv HTTPS_PROXY "${PI_PROXY}"
               --setenv NO_PROXY "localhost,127.0.0.1")
fi

# 11. Execute the sandbox
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
    --ro-bind /opt/ros /opt/ros \
    --proc /proc \
    --dev /dev \
    --size 2147483648 \
    --tmpfs /tmp \
    --tmpfs /home \
    --tmpfs "${HOME_AGENT}" \
    --bind "${WORKSPACE}" "${HOME_AGENT}/workspace" \
    "${HOME_ARGS[@]}" \
    "${NVM_ARGS[@]}" \
    "${BIND_ARGS[@]}" \
    --clearenv \
    "${ENV_ARGS[@]}" \
    --chdir "${HOME_AGENT}/workspace" \
    "${AGENT_ARGS[@]}"
