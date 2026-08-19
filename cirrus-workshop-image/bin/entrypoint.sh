#!/usr/bin/env bash
#
# CIRRUS workshop entrypoint.  Usage: entrypoint.sh {jupyter|code}
#
# Both apps share this image and this entrypoint. The common bootstrap runs
# first -- runtime uid, home isolation, kubeconfig -- and then the requested
# server is exec'd so it becomes PID 1 and gets the pod's signals directly.

set -euo pipefail

PROG="cirrus-entrypoint"
# Diagnostics go to stderr, always. In the OOD path both streams land in the
# pod log either way, and `entrypoint.sh bootstrap <cmd>` has to leave stdout
# clean for <cmd> -- otherwise a bootstrap log line ends up inside whatever the
# caller was capturing.
log()  { printf '%s: %s\n' "$PROG" "$*" >&2; }
warn() { printf '%s: WARNING: %s\n' "$PROG" "$*" >&2; }

usage() {
    cat >&2 <<USAGE
usage: entrypoint.sh {jupyter|code}
       entrypoint.sh bootstrap [command...]

  jupyter     JupyterLab   (OOD app: CIRRUS Workshop (Jupyter))
  code        code-server  (OOD app: CIRRUS Workshop (VS Code))

  bootstrap   Run the common bootstrap only -- runtime uid, home isolation,
              kubeconfig -- then exec command... if one was given, or print a
              summary and exit. This is what the tests drive, and it is the way
              to reproduce a session's environment by hand without starting a
              server.
USAGE
}

MODE="${1:-}"
case "$MODE" in
    jupyter|code|bootstrap) shift ;;
    ""|-h|--help) usage; exit 2 ;;
    *) printf '%s: ERROR: unknown mode: %s\n' "$PROG" "$MODE" >&2; usage; exit 2 ;;
esac

# ===========================================================================
# Common bootstrap
# ===========================================================================

STATE_DIR="${CIRRUS_STATE_DIR:-/tmp/cirrus}"
export CIRRUS_STATE_DIR="$STATE_DIR"

# $HOME is the user's GLADE home in the OOD path. Standalone (docker run
# --user 54321:54321) there may be no $HOME at all, so give it somewhere
# writable rather than letting every ~-relative path expand to "/".
if [ -n "${HOME:-}" ] && [ ! -d "$HOME" ]; then
    mkdir -p -- "$HOME" 2>/dev/null || true
fi
if [ -z "${HOME:-}" ] || [ ! -d "${HOME:-}" ]; then
    warn "\$HOME is unset or unusable (${HOME:-<unset>}); using ${STATE_DIR}/home"
    HOME="${STATE_DIR}/home"
    export HOME
fi

mkdir -p \
    "${STATE_DIR}" \
    "${STATE_DIR}/kube" \
    "${STATE_DIR}/cache" \
    "${STATE_DIR}/data" \
    "${STATE_DIR}/config" \
    "${STATE_DIR}/state" \
    "${STATE_DIR}/pythonuserbase" \
    "${STATE_DIR}/jupyter/data" \
    "${STATE_DIR}/jupyter/runtime" \
    "${STATE_DIR}/ipython" \
    "${STATE_DIR}/helm/cache" \
    "${STATE_DIR}/helm/config" \
    "${STATE_DIR}/helm/data" \
    "${STATE_DIR}/code-server" \
    "${HOME}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Runtime uid.
#
# OOD sets runAsUser/runAsGroup to the user's real NFS uid/gid, which has no
# /etc/passwd entry here. Most things do not care; git ("fatal: unable to look
# up current user"), ssh, and some shell prompts do. nss_wrapper answers the
# lookup from a writable copy of /etc/passwd instead of us pretending we can
# write to /etc.
# ---------------------------------------------------------------------------
setup_nss_wrapper() {
    local uid gid lib name passwd_file group_file
    uid="$(id -u)"
    gid="$(id -g)"

    if getent passwd "$uid" >/dev/null 2>&1; then
        return 0
    fi

    lib="$(cat /opt/cirrus/nss_wrapper_lib 2>/dev/null || true)"
    if [ -z "$lib" ] || [ ! -r "$lib" ]; then
        warn "uid ${uid} has no passwd entry and libnss_wrapper.so was not found;"
        warn "tools that call getpwuid() (git, ssh) may report a failed user lookup."
        return 0
    fi

    name="${USER:-${NB_USER:-cirrus}}"
    if getent passwd "$name" >/dev/null 2>&1; then
        name="cirrus-${uid}"
    fi

    passwd_file="${STATE_DIR}/passwd"
    group_file="${STATE_DIR}/group"
    cp /etc/passwd "$passwd_file"
    cp /etc/group  "$group_file"
    printf '%s:x:%s:%s:CIRRUS workshop user:%s:/bin/bash\n' \
        "$name" "$uid" "$gid" "$HOME" >> "$passwd_file"
    if ! getent group "$gid" >/dev/null 2>&1; then
        printf '%s:x:%s:\n' "$name" "$gid" >> "$group_file"
    fi

    export NSS_WRAPPER_PASSWD="$passwd_file"
    export NSS_WRAPPER_GROUP="$group_file"
    export LD_PRELOAD="${lib}${LD_PRELOAD:+:${LD_PRELOAD}}"
    export USER="${USER:-$name}"
    export LOGNAME="${LOGNAME:-$name}"
    log "uid ${uid} has no passwd entry; answering lookups via nss_wrapper as '${name}'"
}
setup_nss_wrapper

# ---------------------------------------------------------------------------
# Home directory isolation.
#
# $HOME is shared with Casper and Derecho. Caches, per-session state and
# anything pip might install go to $STATE_DIR; we do not write to $HOME/.local,
# $HOME/.jupyter or $HOME/.config at all. PIP_USER is forced off rather than
# defaulted, because that is the one that quietly poisons the user's HPC
# sessions with wheels built for this image's glibc and CPU features.
# ---------------------------------------------------------------------------
export PIP_USER=false
export PYTHONUSERBASE="${PYTHONUSERBASE:-${STATE_DIR}/pythonuserbase}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${STATE_DIR}/cache}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-${STATE_DIR}/data}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${STATE_DIR}/config}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-${STATE_DIR}/state}"
export JUPYTER_DATA_DIR="${JUPYTER_DATA_DIR:-${STATE_DIR}/jupyter/data}"
export JUPYTER_RUNTIME_DIR="${JUPYTER_RUNTIME_DIR:-${STATE_DIR}/jupyter/runtime}"
export IPYTHONDIR="${IPYTHONDIR:-${STATE_DIR}/ipython}"
export HELM_CACHE_HOME="${HELM_CACHE_HOME:-${STATE_DIR}/helm/cache}"
export HELM_CONFIG_HOME="${HELM_CONFIG_HOME:-${STATE_DIR}/helm/config}"
export HELM_DATA_HOME="${HELM_DATA_HOME:-${STATE_DIR}/helm/data}"

# ---------------------------------------------------------------------------
# Working directory. The one place in $HOME this image writes, by design:
# notebooks and manifests the user makes during the workshop should still be
# there next session.
# ---------------------------------------------------------------------------
export CIRRUS_WORKDIR="${CIRRUS_WORKDIR:-${HOME}/cirrus-workshop}"
if ! mkdir -p -- "$CIRRUS_WORKDIR" 2>/dev/null; then
    warn "could not create ${CIRRUS_WORKDIR}; falling back to ${STATE_DIR}/cirrus-workshop"
    warn "(files saved there do NOT persist past this session)"
    CIRRUS_WORKDIR="${STATE_DIR}/cirrus-workshop"
    mkdir -p -- "$CIRRUS_WORKDIR"
fi

# Where workshop state persists. Deliberately NOT derived from CIRRUS_WORKDIR:
# that is the directory the editor opens, which is a user choice on the launch
# form, and deriving this from it meant someone who set the working directory to
# their home turned JUPYTER_CONFIG_DIR into $HOME/.jupyter -- the shared dotfile
# this image exists to stay out of. Two different concepts, two variables.
export CIRRUS_PERSIST_DIR="${CIRRUS_PERSIST_DIR:-${HOME}/cirrus-workshop}"
if ! mkdir -p -- "$CIRRUS_PERSIST_DIR" 2>/dev/null; then
    warn "could not create ${CIRRUS_PERSIST_DIR}; settings will not persist past this session"
    CIRRUS_PERSIST_DIR="${STATE_DIR}/persist"
    export CIRRUS_PERSIST_DIR
    mkdir -p -- "$CIRRUS_PERSIST_DIR"
fi

# JUPYTER_CONFIG_DIR is the one Jupyter path worth keeping between sessions: it
# holds the user's Lab settings and workspace layout. jupyter_core writes a
# "migrated" marker into it on the very first command, so it has to be set before
# anything Jupyter-related runs.
export JUPYTER_CONFIG_DIR="${JUPYTER_CONFIG_DIR:-${CIRRUS_PERSIST_DIR}/.jupyter}"

# Backstop, whoever set it and however: $HOME/.jupyter is read by the user's
# Casper and Derecho sessions, and a config written by this image can break them.
# CIRRUS_ALLOW_HOME_JUPYTER=1 for anyone who genuinely wants that.
if [ "$JUPYTER_CONFIG_DIR" = "${HOME}/.jupyter" ] && [ "${CIRRUS_ALLOW_HOME_JUPYTER:-0}" != "1" ]; then
    warn "JUPYTER_CONFIG_DIR was \$HOME/.jupyter, which your Casper and Derecho sessions read."
    warn "Using ${STATE_DIR}/jupyter/config for this session instead (settings will not persist)."
    warn "Set CIRRUS_ALLOW_HOME_JUPYTER=1 if you really want the shared one."
    export JUPYTER_CONFIG_DIR="${STATE_DIR}/jupyter/config"
fi
mkdir -p -- "$JUPYTER_CONFIG_DIR" 2>/dev/null || \
    warn "could not create ${JUPYTER_CONFIG_DIR}; JupyterLab settings will not persist"

# ---------------------------------------------------------------------------
# kubeconfig. A failure here is loud but not fatal: a session that refuses to
# start is a crashloop the user cannot read, while a session that starts with a
# broken kubeconfig shows them the error in a terminal and lets them re-run
# cirrus-kubeconfig-init once it is fixed.
# ---------------------------------------------------------------------------
export KUBECONFIG="${KUBECONFIG:-${STATE_DIR}/kube/config}"
# Deliberately NOT defaulted here. Setting it would make the bootstrap think an
# operator chose this path, and would beat the preference order in
# cirrus-kubeconfig-src -- which is exactly the bug that had OOD sessions using
# the Casper kubeconfig. It is exported after the bootstrap, below, so terminals
# and cirrus-check see the same resolved value.

# The OOD session pod arrives with KUBECONFIG=/dev/null. Writing the session
# copy there means kubectl finds an empty config and silently authenticates as
# the pod's service account instead of as the user. Redirect to somewhere a file
# can actually live, and export it so Jupyter, code-server and every terminal
# they spawn agree on the path.
if [ -e "$KUBECONFIG" ] && [ ! -f "$KUBECONFIG" ]; then
    warn "KUBECONFIG=${KUBECONFIG} cannot hold a file (it is not a regular file)."
    warn "Using ${STATE_DIR}/kube/config for this session's kubeconfig instead."
    export KUBECONFIG="${STATE_DIR}/kube/config"
fi

# Terminals get their shell from $SHELL, and both jupyter_server_terminals and
# code-server fall back to "sh" when it is unset -- which is dash, which has no
# readline, so the arrow keys emit ^[[A instead of walking history. OOD's
# BYO-image app sets no SHELL at all, and a login shell of /bin/tcsh is common
# on this platform and is not in this image. Either way, land on a shell that
# exists here and can edit a line.
#
# Three things conspire here, and the obvious version of this code is wrong on
# all three:
#
#   1. When SHELL is absent from the environment, bash assigns it from the
#      passwd entry -- as a *shell* variable, never an exported one. So a guard
#      of the form "if SHELL is empty, set it" sees a healthy-looking value, does
#      nothing, and children still inherit no SHELL at all.
#   2. When that passwd lookup fails -- an arbitrary uid with no entry, which is
#      this image's whole premise, and nss_wrapper is not loaded yet when bash
#      starts -- bash falls back to SHELL=/bin/sh.
#   3. /bin/sh here is dash, which has no readline. It is perfectly executable
#      and completely unusable interactively: the arrow keys emit ^[[A instead of
#      walking history.
#
# So the test is "can this shell edit a line", not "does this file exist", and
# the export is unconditional. CIRRUS_SHELL overrides all of it, verbatim.
cirrus_shell="${CIRRUS_SHELL:-${SHELL:-}}"
if [ -z "${CIRRUS_SHELL:-}" ]; then
    case "$(basename -- "${cirrus_shell:-none}")" in
        bash|zsh|tcsh|csh|fish) ;;
        *) cirrus_shell="" ;;
    esac
fi
if [ -z "$cirrus_shell" ] || [ ! -x "$cirrus_shell" ]; then
    # /bin/sh is bash's own fallback, not a choice anyone made, so replacing it
    # is not worth a warning. A login shell of /bin/tcsh is a real setting that
    # this image cannot honour, and that is worth saying out loud.
    case "${SHELL:-}" in
        ''|/bin/sh) ;;
        *) warn "login shell ${SHELL} is not usable in this image; terminals will use /bin/bash" ;;
    esac
    cirrus_shell=/bin/bash
fi
SHELL="$cirrus_shell"
export SHELL

# Tee the bootstrap's own output to a file. In OOD this is otherwise only in the
# pod log, which is precisely what a workshop user in a browser cannot read --
# and it is the one place the real reason is written down.
CIRRUS_BOOTSTRAP_LOG="${STATE_DIR}/bootstrap.log"
export CIRRUS_BOOTSTRAP_LOG
: > "$CIRRUS_BOOTSTRAP_LOG" 2>/dev/null || true

if cirrus-kubeconfig-init 2> >(tee -a "$CIRRUS_BOOTSTRAP_LOG" >&2); then
    :
else
    rc=$?
    warn "cirrus-kubeconfig-init failed (exit ${rc}). Kubernetes access is NOT set up."
    warn "The session will still start. Fix the problem above, then run:"
    warn "    cirrus-kubeconfig-init"

    # With no file at $KUBECONFIG, client-go falls back to the pod's in-cluster
    # service account, and the user's first kubectl reports a Forbidden for
    # system:serviceaccount:<ns>:default -- an identity that has nothing to do
    # with their problem. Write a config whose credential plugin only ever fails,
    # with the real explanation, so the error arrives where they can act on it.
    #
    # The test is whether kubectl can do anything with what is there -- not
    # whether a file exists. A bootstrap that dies after copying leaves a config
    # that may have no current context at all, and kubectl treats that exactly
    # like a missing config: it falls back to the pod's in-cluster service
    # account. A copy that *does* resolve a context is left alone, because it
    # holds the user's real clusters and is still a usable fallback for them.
    if ! kubectl --kubeconfig "$KUBECONFIG" config current-context >/dev/null 2>&1; then
        warn "the session kubeconfig resolves no context; installing one that explains"
        warn "the problem rather than letting kubectl use the pod service account."
        if mkdir -p -- "$(dirname -- "$KUBECONFIG")" 2>/dev/null && cat > "$KUBECONFIG" <<GUARD
apiVersion: v1
kind: Config
clusters:
- name: cirrus-unconfigured
  cluster:
    server: https://cirrus-kubeconfig-not-configured.invalid
contexts:
- name: cirrus-unconfigured
  context:
    cluster: cirrus-unconfigured
    user: cirrus-unconfigured
current-context: cirrus-unconfigured
users:
- name: cirrus-unconfigured
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: cirrus-no-credentials
      interactiveMode: Never
GUARD
        then
            chmod 0600 "$KUBECONFIG" 2>/dev/null || true
            warn "kubectl will explain this rather than silently using the pod's service account."
        fi
    fi
fi

# Now that the bootstrap has run and reported honestly which config it chose,
# publish that choice to everything the session spawns.
export CIRRUS_KUBECONFIG_SRC="${CIRRUS_KUBECONFIG_SRC:-$(cirrus-kubeconfig-src)}"

# ---------------------------------------------------------------------------
# Proxy parameters. CIRRUS_PORT and CIRRUS_BASE_URL come from the OOD pod spec;
# the ENV defaults in the Dockerfile only exist so the image runs standalone.
# ---------------------------------------------------------------------------
PORT="${CIRRUS_PORT:-8080}"
BASE_URL="${CIRRUS_BASE_URL:-}"

# Jupyter behind OOD's /node/ proxy has to be told the prefix it lives under, and
# that prefix is /node/<nodeName>/<nodePort>/ -- neither of which exists until the
# pod is scheduled and its service assigned a NodePort. So it cannot come from the
# pod spec; an init container computes it and writes it here, and this reads it.
#
# Env wins if set, so local testing stays a one-liner.
if [ -z "$BASE_URL" ] && [ -n "${CIRRUS_BASE_URL_FILE:-}" ]; then
    if [ -r "$CIRRUS_BASE_URL_FILE" ]; then
        # Last path-looking line, not the whole file: the init container appends
        # to a configmap key, so a seeded comment or a second append would
        # otherwise be concatenated into a nonsense prefix.
        BASE_URL="$(grep -oE '^[[:space:]]*/[^[:space:]]*' "$CIRRUS_BASE_URL_FILE" 2>/dev/null | tr -d '[:space:]' | tail -1)"
        log "base URL read from ${CIRRUS_BASE_URL_FILE}: ${BASE_URL:-<empty>}"
    else
        warn "CIRRUS_BASE_URL_FILE=${CIRRUS_BASE_URL_FILE} is not readable."
        warn "Serving at / instead. Behind OOD's /node/ proxy that yields a blank page,"
        warn "because every asset request will be sent to a path this server does not serve."
    fi
fi
[ -n "$BASE_URL" ] || BASE_URL="/"

log "mode=${MODE} port=${PORT} base_url=${BASE_URL} workdir=${CIRRUS_WORKDIR}"

# ===========================================================================
# Servers
# ===========================================================================

case "$MODE" in
bootstrap)
    if [ "$#" -gt 0 ]; then
        exec "$@"
    fi
    log "bootstrap complete"
    log "  HOME               : ${HOME}"
    log "  CIRRUS_STATE_DIR   : ${STATE_DIR}"
    log "  CIRRUS_WORKDIR     : ${CIRRUS_WORKDIR}"
    log "  KUBECONFIG         : ${KUBECONFIG}"
    log "  user               : $(id -un 2>/dev/null || echo '<no passwd entry>') (uid $(id -u), gid $(id -g))"
    exit 0
    ;;

jupyter)
    # OOD serves Jupyter through /node/<host>/<port>/, which forwards the whole
    # path, so the server has to be told the prefix it lives under -- that is
    # what CIRRUS_BASE_URL carries.
    args=(
        --ServerApp.ip=0.0.0.0
        --ServerApp.port="${PORT}"
        --ServerApp.port_retries=0
        --ServerApp.base_url="${BASE_URL}"
        --ServerApp.root_dir="${CIRRUS_WORKDIR}"
        --ServerApp.preferred_dir="${CIRRUS_WORKDIR}"
        --ServerApp.open_browser=False
        --ServerApp.quit_button=False
        # Behind a reverse proxy every request arrives from a non-local address
        # and carries the proxy's Origin, not the server's. allow_remote_access
        # lets it serve them at all; allow_origin is what the websocket origin
        # check consults, and without it /api/kernels/<id>/channels is refused
        # with a 403 and the notebook never gets a kernel.
        --ServerApp.allow_remote_access=True
        --ServerApp.allow_origin='*'
        --ServerApp.trust_xheaders=True
        # Terminals open a login shell so /etc/profile.d/cirrus.sh applies.
        --ServerApp.terminado_settings='{"shell_command":["/bin/bash","-l"]}'
    )

    # OOD authenticates the user before the proxy ever reaches this pod, so the
    # app-level token is off by default. CIRRUS_JUPYTER_AUTH=token restores it
    # for local testing, where nothing else is guarding the port.
    case "${CIRRUS_JUPYTER_AUTH:-none}" in
        none)
            args+=(
                --IdentityProvider.token=''
                --ServerApp.password=''
                --ServerApp.disable_check_xsrf=True
            )
            ;;
        token)
            log "CIRRUS_JUPYTER_AUTH=token: JupyterLab will require its own token"
            ;;
        *)
            warn "unrecognised CIRRUS_JUPYTER_AUTH='${CIRRUS_JUPYTER_AUTH}'; treating it as 'token'"
            ;;
    esac

    exec jupyter lab "${args[@]}"
    ;;

code)
    # code-server has no base-path setting for itself: it emits relative roots
    # and assumes it is mounted at /. OOD's /rnode/<host>/<port>/ proxy strips
    # the prefix, which is exactly that. --abs-proxy-base-path only fixes up
    # code-server's own /absproxy/<port> URLs, so it is passed just when a
    # prefix is actually in play.
    DATA_DIR="${STATE_DIR}/code-server/data"
    EXT_DIR="${CIRRUS_EXTENSIONS_DIR:-${STATE_DIR}/code-server/extensions}"
    mkdir -p "$DATA_DIR" "$EXT_DIR"

    # Seed the session's extension dir from the read-only system one, so the
    # YAML and Kubernetes extensions are present without a first-launch prompt
    # and the user can still install more of their own.
    SYS_EXT_DIR="${CIRRUS_SYS_EXTENSIONS_DIR:-/opt/cirrus/code-server-extensions}"
    if [ -d "$SYS_EXT_DIR" ] && [ -z "$(ls -A "$EXT_DIR" 2>/dev/null)" ]; then
        cp -a "${SYS_EXT_DIR}/." "${EXT_DIR}/" 2>/dev/null || \
            warn "could not seed extensions from ${SYS_EXT_DIR}"
    fi

    args=(
        --bind-addr "0.0.0.0:${PORT}"
        --auth none
        --disable-telemetry
        --disable-update-check
        --disable-workspace-trust
        --app-name "CIRRUS Workshop"
        --user-data-dir "$DATA_DIR"
        --extensions-dir "$EXT_DIR"
    )
    if [ "$BASE_URL" != "/" ]; then
        args+=(--abs-proxy-base-path "$BASE_URL")
    fi

    exec /opt/code-server/bin/code-server "${args[@]}" "$CIRRUS_WORKDIR"
    ;;
esac
