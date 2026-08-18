# CIRRUS workshop environment.
#
# Sourced from /etc/profile.d (login shells) and from /etc/bash.bashrc
# (interactive non-login shells, which is what Jupyter and code-server
# terminals open). It therefore runs *after* the entrypoint has already set up
# the session, possibly several times.
#
# Every assignment here uses ${VAR:-default}. That is not a style preference:
# an unconditional KUBECONFIG= in this file would silently discard whatever the
# entrypoint or the OOD pod spec set, and the first terminal the user opened
# would be pointed at a config that does not exist.

CIRRUS_STATE_DIR="${CIRRUS_STATE_DIR:-/tmp/cirrus}"
export CIRRUS_STATE_DIR

# ---------------------------------------------------------------------------
# PATH -- prepend ours, but only once, so re-sourcing does not grow it.
# ---------------------------------------------------------------------------
for _cirrus_dir in /opt/venv/bin /opt/code-server/bin /usr/local/bin; do
    case ":${PATH}:" in
        *":${_cirrus_dir}:"*) ;;
        *) PATH="${_cirrus_dir}:${PATH}" ;;
    esac
done
unset _cirrus_dir
export PATH

export VIRTUAL_ENV="${VIRTUAL_ENV:-/opt/venv}"

# ---------------------------------------------------------------------------
# Home directory isolation.
#
# $HOME here is the user's GLADE home, shared with Casper and Derecho. A wheel
# installed from this container into ~/.local, or a Jupyter runtime dir left
# behind in ~/.jupyter, is visible to their HPC sessions -- and binary wheels
# built against this image's glibc and CPU features can break them outright.
# Caches and per-session state go to $CIRRUS_STATE_DIR instead. Anything worth
# keeping belongs in $HOME/cirrus-workshop.
# ---------------------------------------------------------------------------
export PIP_USER="${PIP_USER:-false}"
export PYTHONUSERBASE="${PYTHONUSERBASE:-${CIRRUS_STATE_DIR}/pythonuserbase}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${CIRRUS_STATE_DIR}/cache}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-${CIRRUS_STATE_DIR}/data}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${CIRRUS_STATE_DIR}/config}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-${CIRRUS_STATE_DIR}/state}"
export JUPYTER_DATA_DIR="${JUPYTER_DATA_DIR:-${CIRRUS_STATE_DIR}/jupyter/data}"
export JUPYTER_RUNTIME_DIR="${JUPYTER_RUNTIME_DIR:-${CIRRUS_STATE_DIR}/jupyter/runtime}"
export IPYTHONDIR="${IPYTHONDIR:-${CIRRUS_STATE_DIR}/ipython}"
export HELM_CACHE_HOME="${HELM_CACHE_HOME:-${CIRRUS_STATE_DIR}/helm/cache}"
export HELM_CONFIG_HOME="${HELM_CONFIG_HOME:-${CIRRUS_STATE_DIR}/helm/config}"
export HELM_DATA_HOME="${HELM_DATA_HOME:-${CIRRUS_STATE_DIR}/helm/data}"

# ---------------------------------------------------------------------------
# Kubernetes. KUBECONFIG is the session's working copy; CIRRUS_KUBECONFIG_SRC
# is the user's real config, which is only ever read.
# ---------------------------------------------------------------------------
export KUBECONFIG="${KUBECONFIG:-${CIRRUS_STATE_DIR}/kube/config}"
# Via the helper, not a hardcoded path: ~/.kube/cirrus-config is preferred over
# ~/.kube/config, and that rule lives in one place.
export CIRRUS_KUBECONFIG_SRC="${CIRRUS_KUBECONFIG_SRC:-$(cirrus-kubeconfig-src 2>/dev/null)}"
export CIRRUS_WORKDIR="${CIRRUS_WORKDIR:-${HOME}/cirrus-workshop}"

# Not /tmp: this one holds the user's JupyterLab settings, which are worth
# keeping. Just not in $HOME/.jupyter, where the HPC sessions would see it.
export JUPYTER_CONFIG_DIR="${JUPYTER_CONFIG_DIR:-${CIRRUS_WORKDIR}/.jupyter}"

# ---------------------------------------------------------------------------
# Completion and the k alias. Bash-only and interactive-only: a completion
# script sourced into a non-interactive shell is wasted work, and `complete` is
# not a POSIX sh builtin.
# ---------------------------------------------------------------------------
case "$-" in
    *i*)
        if [ -n "${BASH_VERSION:-}" ]; then
            if ! type __load_completion >/dev/null 2>&1 && [ -r /usr/share/bash-completion/bash_completion ]; then
                . /usr/share/bash-completion/bash_completion
            fi
            for _cirrus_comp in kubectl helm argocd stern; do
                if [ -r "/etc/bash_completion.d/${_cirrus_comp}" ]; then
                    . "/etc/bash_completion.d/${_cirrus_comp}"
                fi
            done
            unset _cirrus_comp

            # `k` is the alias the CIRRUS docs tell people to make, with
            # completion wired to it rather than left half-working.
            alias k=kubectl
            if type __start_kubectl >/dev/null 2>&1; then
                complete -o default -F __start_kubectl k
            fi
        fi
        ;;
esac
