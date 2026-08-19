# CIRRUS workshop environment, csh/tcsh dialect.
#
# A separate file because tcsh cannot source cirrus.sh: `export VAR=value` and
# ${VAR:-default} are not csh syntax. This must stay in step with cirrus.sh --
# same variables, same "only if unset" discipline, so that opening a tcsh
# terminal inside a session cannot discard what the entrypoint set.
#
# There is no completion here. kubectl, helm, argocd and stern emit bash and zsh
# completions only; tcsh users get the `k` alias and the environment.

# Every reference below is guarded. csh aborts the whole file at the first
# undefined variable -- so an unset PATH would silently cost the session all of
# these settings, not just its PATH entry.
if ( ! $?CIRRUS_STATE_DIR ) setenv CIRRUS_STATE_DIR /tmp/cirrus
if ( ! $?PATH ) setenv PATH /usr/local/bin:/usr/bin:/bin
if ( ! $?HOME ) setenv HOME "${CIRRUS_STATE_DIR}/home"

foreach _cirrus_dir ( /opt/venv/bin /opt/code-server/bin /usr/local/bin )
    if ( "${PATH}" !~ "*${_cirrus_dir}*" ) setenv PATH "${_cirrus_dir}:${PATH}"
end
unset _cirrus_dir

if ( ! $?VIRTUAL_ENV )        setenv VIRTUAL_ENV       /opt/venv

# Home directory isolation -- see cirrus.sh for why each of these exists.
if ( ! $?PIP_USER )           setenv PIP_USER          false
if ( ! $?PYTHONUSERBASE )     setenv PYTHONUSERBASE    "${CIRRUS_STATE_DIR}/pythonuserbase"
if ( ! $?XDG_CACHE_HOME )     setenv XDG_CACHE_HOME    "${CIRRUS_STATE_DIR}/cache"
if ( ! $?XDG_DATA_HOME )      setenv XDG_DATA_HOME     "${CIRRUS_STATE_DIR}/data"
if ( ! $?XDG_CONFIG_HOME )    setenv XDG_CONFIG_HOME   "${CIRRUS_STATE_DIR}/config"
if ( ! $?XDG_STATE_HOME )     setenv XDG_STATE_HOME    "${CIRRUS_STATE_DIR}/state"
if ( ! $?JUPYTER_DATA_DIR )   setenv JUPYTER_DATA_DIR  "${CIRRUS_STATE_DIR}/jupyter/data"
if ( ! $?JUPYTER_RUNTIME_DIR ) setenv JUPYTER_RUNTIME_DIR "${CIRRUS_STATE_DIR}/jupyter/runtime"
if ( ! $?IPYTHONDIR )         setenv IPYTHONDIR        "${CIRRUS_STATE_DIR}/ipython"
if ( ! $?HELM_CACHE_HOME )    setenv HELM_CACHE_HOME   "${CIRRUS_STATE_DIR}/helm/cache"
if ( ! $?HELM_CONFIG_HOME )   setenv HELM_CONFIG_HOME  "${CIRRUS_STATE_DIR}/helm/config"
if ( ! $?HELM_DATA_HOME )     setenv HELM_DATA_HOME    "${CIRRUS_STATE_DIR}/helm/data"

if ( ! $?KUBECONFIG )         setenv KUBECONFIG        "${CIRRUS_STATE_DIR}/kube/config"
if ( ! $?CIRRUS_WORKDIR )     setenv CIRRUS_WORKDIR    "${HOME}/cirrus-workshop"
if ( ! $?JUPYTER_CONFIG_DIR ) setenv JUPYTER_CONFIG_DIR "${CIRRUS_WORKDIR}/.jupyter"
if ( ! $?CIRRUS_KUBECONFIG_SRC ) setenv CIRRUS_KUBECONFIG_SRC `cirrus-kubeconfig-src`

alias k kubectl
