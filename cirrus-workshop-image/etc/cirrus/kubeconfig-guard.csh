# Keep interactive tcsh shells pointed at the session kubeconfig -- the csh
# dialect of kubeconfig-guard.sh, which explains why this exists. Sourced from
# the precmd alias that cirrus.csh sets, so it runs before every prompt, after
# the user's own ~/.tcshrc.
if ( ! $?CIRRUS_KUBECONFIG_OVERRIDE && $?CIRRUS_SESSION_KUBECONFIG ) then
    if ( ! $?KUBECONFIG ) then
        setenv KUBECONFIG "${CIRRUS_SESSION_KUBECONFIG}"
    else if ( "${KUBECONFIG}" != "${CIRRUS_SESSION_KUBECONFIG}" ) then
        setenv KUBECONFIG "${CIRRUS_SESSION_KUBECONFIG}"
    endif
endif
