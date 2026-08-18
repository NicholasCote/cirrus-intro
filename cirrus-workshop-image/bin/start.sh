#!/bin/sh
#
# Docker-Stacks-shaped launcher, for OOD apps that run this image with an
# explicit `command:` and so never reach the image's ENTRYPOINT.
#
# The BYO-image Jupyter app (ondemand-jupyter-k8s-image) launches
#
#   /bin/sh /ood-launch/launch.sh lab --config=/ood/ondemand_config.py ...
#
# and launch.sh probes /usr/local/bin/start.sh then /srv/start for a wrapper,
# calling it as `start.sh <jupyter> <args...>`. Without a wrapper at one of
# those paths it execs jupyter directly -- which starts a server, but with none
# of the CIRRUS bootstrap: no session kubeconfig, no home isolation, no uid
# lookup. kubectl in a terminal would then point at a KUBECONFIG that does not
# exist.
#
# So: run the common bootstrap, then exec whatever we were handed. Jupyter's
# own settings (base_url, password, root_dir) stay entirely with the app's
# mounted config -- this adds the environment and takes no opinion on the
# server's arguments.
exec /usr/local/bin/entrypoint.sh bootstrap "$@"
