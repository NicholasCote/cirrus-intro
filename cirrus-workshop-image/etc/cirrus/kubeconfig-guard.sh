# Keep interactive shells pointed at the session kubeconfig. bash and zsh.
#
# The workshop has to run against CIRRUS, not whatever cluster a user's own
# dotfiles select. /etc/profile.d and /etc/bash.bashrc run *before* ~/.bashrc,
# so anything they export is one `export KUBECONFIG=...` away from being
# replaced -- and a KUBECONFIG naming the user's own file also bypasses the
# session copy's token cache, so every kubectl call asks them to sign in again.
# A prompt hook runs after all of that, before the first command.
#
# It runs before every prompt, not just the first, so an `unset KUBECONFIG`
# (which would fall back to ~/.kube/config, the Casper one) or a kind/minikube
# setup script is corrected too. It speaks only when it changes something.
# To point a shell at another cluster deliberately:
#
#   export CIRRUS_KUBECONFIG_OVERRIDE=1 KUBECONFIG=/path/to/config
#
# Sourced from cirrus.sh (interactive bash) and /etc/zsh/zshrc, both of which run
# before the user's own rc file. POSIX in the function body; the registration is
# per shell.

__cirrus_kubeconfig_guard() {
    [ -n "${CIRRUS_KUBECONFIG_OVERRIDE:-}" ] && return 0
    [ -n "${CIRRUS_SESSION_KUBECONFIG:-}" ] || return 0
    [ "${KUBECONFIG-}" = "$CIRRUS_SESSION_KUBECONFIG" ] && return 0
    printf 'cirrus: KUBECONFIG was %s; this workshop session uses %s (CIRRUS).\n' \
        "$([ -n "${KUBECONFIG:-}" ] && printf 'set to %s' "$KUBECONFIG" || printf 'unset')" \
        "$CIRRUS_SESSION_KUBECONFIG" >&2
    printf 'cirrus: reset it. To use another config on purpose: export CIRRUS_KUBECONFIG_OVERRIDE=1\n' >&2
    KUBECONFIG="$CIRRUS_SESSION_KUBECONFIG"
    export KUBECONFIG
}

if [ -n "${BASH_VERSION:-}" ]; then
    # An array element of its own (bash >= 5.1 runs each one), at an index well
    # clear of 0: a PROMPT_COMMAND="..." in ~/.bashrc assigns element 0 only, so
    # this survives the usual idioms. Appending would not -- with PROMPT_COMMAND
    # unset beforehand, += lands on element 0 and the first assignment erases it.
    PROMPT_COMMAND[100]=__cirrus_kubeconfig_guard
elif [ -n "${ZSH_VERSION:-}" ]; then
    case " ${precmd_functions[*]-} " in
        *" __cirrus_kubeconfig_guard "*) ;;
        *) precmd_functions+=(__cirrus_kubeconfig_guard) ;;
    esac
fi
