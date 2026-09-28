# Keep interactive tcsh shells pointed at the session kubeconfig -- the csh
# dialect of kubeconfig-guard.sh, which explains why this exists. Sourced from
# the precmd alias that cirrus.csh sets, so it runs before every prompt, after
# the user's own ~/.tcshrc.
if ( ! $?CIRRUS_KUBECONFIG_OVERRIDE && $?CIRRUS_SESSION_KUBECONFIG ) then
    if ( ! $?KUBECONFIG ) then
        echo "cirrus: KUBECONFIG was unset; this workshop session uses ${CIRRUS_SESSION_KUBECONFIG} (CIRRUS)." > /dev/stderr
        echo "cirrus: reset it. To use another config on purpose: setenv CIRRUS_KUBECONFIG_OVERRIDE 1" > /dev/stderr
        setenv KUBECONFIG "${CIRRUS_SESSION_KUBECONFIG}"
    else if ( "${KUBECONFIG}" != "${CIRRUS_SESSION_KUBECONFIG}" ) then
        echo "cirrus: KUBECONFIG was set to ${KUBECONFIG}; this workshop session uses ${CIRRUS_SESSION_KUBECONFIG} (CIRRUS)." > /dev/stderr
        echo "cirrus: reset it. To use another config on purpose: setenv CIRRUS_KUBECONFIG_OVERRIDE 1" > /dev/stderr
        setenv KUBECONFIG "${CIRRUS_SESSION_KUBECONFIG}"
    endif
endif
