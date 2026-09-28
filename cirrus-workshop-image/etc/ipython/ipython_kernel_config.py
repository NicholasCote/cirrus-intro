# Keep notebook kernels pointed at the session kubeconfig.
#
# The kernel-side twin of /etc/cirrus/kubeconfig-guard.sh. Terminals are held
# to CIRRUS_SESSION_KUBECONFIG by a prompt hook; a kernel has no prompt, and
# its environment is whatever the editor chose to launch it with -- which in
# VS Code is not necessarily the server's own. A kernel that reaches kubectl
# with KUBECONFIG unset falls back to ~/.kube/config (the user's own, HPC-side
# config), which does not go through cirrus-kubelogin's session token cache.
# The visible symptom: signed in fine in the terminal, but every %%bash kubectl
# in a notebook starts a new device-code sign-in.
#
# Installed into /opt/venv/etc/ipython, which IPython reads for every kernel
# started from this venv, in both editors. It runs once at kernel start; setting
# os.environ['KUBECONFIG'] in a cell afterwards still wins, as does
# CIRRUS_KUBECONFIG_OVERRIDE, the same escape hatch terminals have.

import os

if not os.environ.get("CIRRUS_KUBECONFIG_OVERRIDE"):
    _state_dir = os.environ.get("CIRRUS_STATE_DIR") or "/tmp/cirrus"
    _session = os.environ.get("CIRRUS_SESSION_KUBECONFIG") or os.path.join(_state_dir, "kube", "config")
    if os.path.isfile(_session):
        os.environ["CIRRUS_SESSION_KUBECONFIG"] = _session
        os.environ["KUBECONFIG"] = _session
    del _state_dir, _session
