# CIRRUS workshop image

One container image behind two Open OnDemand apps:

| OOD app | entrypoint arg | server |
| --- | --- | --- |
| CIRRUS Workshop (Jupyter) | `jupyter` | JupyterLab |
| CIRRUS Workshop (VS Code) | `code` | code-server |

It carries the Kubernetes tooling for the workshop labs, pre-pointed at the
`mlc1` cluster and the user's own `ood-<user>` namespace, using the Capsule OIDC
kubeconfig they already have.

Published to `hub.k8s.ucar.edu/ncote/cirrus-workshop`.

## What is in it

Pinned as Docker `ARG`s — nothing is `latest`. The resolved set is written to
`/opt/cirrus/versions.txt` at build time; `cirrus-versions` prints it and
`cirrus-versions --check` re-runs every tool and diffs the reported version
against it.

| | version | why this one |
| --- | --- | --- |
| kubectl | v1.35.7 | Tracks the CIRRUS control plane minor (1.35.6) and never leads it. Bump *after* a cluster upgrade, not before. |
| kubelogin | v0.2.19 | **Azure/kubelogin**, the flavor the CIRRUS kubeconfig's `exec` block calls. Not `int128/kubelogin`. |
| helm | v3.21.4 | Helm 4 is out, but the workshop material and CIRRUS docs are written against 3. |
| argocd | v3.5.1 | Argo CD (GitOps). The `argo` CLI is a *different* project — Argo Workflows — and is not shipped; see below |
| stern | v1.34.0 | multi-pod log tailing |
| yq | v4.53.3 | mikefarah |
| code-server | 4.133.0 | with `redhat.vscode-yaml` and `ms-kubernetes-tools.vscode-kubernetes-tools` pre-installed from Open VSX |
| JupyterLab | 4.6.3 | plus `notebook`, `jupyterlab-git`, `ipykernel`, `pyyaml`, `kubernetes`, `requests` in `/opt/venv` |

Plus `git`, `curl`, `wget`, `jq`, `vim`, `nano`, `less`, `bash-completion`,
`openssh-client`, `unzip`, `tree`, `rsync`.

### What is deliberately not here

`kustomize`, `k9s` and `argo` (Argo Workflows) were dropped after the first OOD
trial. The labs are kubectl-centric, the CIRRUS clusters take plain manifests,
and k9s is a lot of interface for someone meeting Kubernetes for the first time.

That was also the largest security change available. From the Harbor SBOM, the
image's ~1270 vendored Go modules broke down as k9s 369, argocd 265, argo 243,
helm 102, kubectl 81, stern 72, kubelogin 72, kustomize 28, yq 27 — so those
three carried roughly **640 of them**. Dropping kustomize also removed the only
Critical in the scan: its newest release, v5.8.1, is built with Go 1.24.0 and
carries CVE-2025-68121 in the Go standard library, with no upstream rebuild
available.

Note that `kubectl` embeds kustomize anyway (`kubectl kustomize`, v5.7.1 in
kubectl v1.35.7), so nothing was actually lost there.

Adding `argo` back when workflows enter the curriculum is one `ARG`, one `RUN`
and one line in the versions block.

The Python layer is deliberately thin. This is a Kubernetes workshop, not a data
science environment; anyone who needs the scientific stack should build a venv
of their own under `$HOME`.

Completion for kubectl, helm, argocd and stern is generated at
build time into `/etc/bash_completion.d` and wired up by
`/etc/profile.d/cirrus.sh`, including the `k` alias (`complete -o default -F
__start_kubectl k`, so completion works on the alias and not just on the full
name).

### Why not a Jupyter Docker Stacks base

The stacks bake a `jovyan` user at uid 1000, a conda prefix owned by that uid,
and a `fix-permissions`/`start.sh` chain that assumes it can chown things at
startup. OOD runs this pod as the user's real NFS uid/gid with their GLADE home
mounted, so none of that applies and all of it can fail. A plain `ubuntu:24.04`
with a root-owned venv at `/opt/venv` has nothing to fix up.

## Environment

Everything is read from the environment with a default, so the image runs
standalone and the OOD pod spec overrides what it needs to. The `ENV` defaults
in the Dockerfile exist for local testing and CI only.

| variable | default | set by |
| --- | --- | --- |
| `CIRRUS_PORT` | `8080` | pod spec (matches the existing CIRRUS OOD apps' fixed containerPort) |
| `CIRRUS_BASE_URL` | `/` | pod spec / init container, for Jupyter |
| `KUBECONFIG` | `/tmp/cirrus/kube/config` | pod spec — the session's **working copy** |
| `CIRRUS_KUBECONFIG_SRC` | `$HOME/.kube/config` | pod spec — the user's real config, read-only |
| `CIRRUS_NAMESPACE` | inferred, loudly | `submit.yml.erb`, as `ood-<%= user %>` |
| `CIRRUS_CONTEXT` | `mlc1` | override only to test another cluster |
| `CIRRUS_WORKDIR` | `$HOME/cirrus-workshop` | |
| `JUPYTER_CONFIG_DIR` | `$CIRRUS_WORKDIR/.jupyter` | not `$HOME/.jupyter`; see below |
| `CIRRUS_STATE_DIR` | `/tmp/cirrus` | root of all per-session state |
| `CIRRUS_JUPYTER_AUTH` | `none` | set to `token` to re-enable JupyterLab's own token |
| `CIRRUS_KUBELOGIN_LOGIN` | `devicecode` | Azure kubelogin `--login` method |
| `CIRRUS_KUBELOGIN_CACHE_DIR` | `$HOME/.kube/cache/kubelogin` | point at `/tmp` if writing to the shared home is a problem |
| `CIRRUS_TOKEN_CACHE` | `on` | `off` uses plain kubelogin — and then *every* kubectl call asks you to sign in |
| `CIRRUS_TOKEN_CACHE_DIR` | `$CIRRUS_STATE_DIR/kube/token-cache` | where the session's bearer token is cached |
| `CIRRUS_KUBECTL_TIMEOUT` | `300s` | `cirrus-check`'s API timeout; long enough for a human to complete a device-code sign-in |
| `CIRRUS_EXTENSIONS_DIR` | `$CIRRUS_STATE_DIR/code-server/extensions` | |

`CIRRUS_KUBECONFIG_SRC` has no `ENV` default in the Dockerfile because it
depends on `$HOME`, which is only known at runtime; the scripts default it.

## OOD integration notes

**Port.** The existing CIRRUS OOD apps use a fixed `8080` containerPort exposed
as a NodePort, so `CIRRUS_PORT` normally does not need setting at all.

**Base URL, and the two proxies.** OnDemand ships both, and they are not
interchangeable:

* `/node/HOST/PORT/...` forwards the whole path, prefix included. The backend
  has to be told the prefix it lives under. That is what `CIRRUS_BASE_URL` is
  for, and Jupyter consumes it as `ServerApp.base_url`. As in
  `ondemand-jupyter-k8s-image`, the value is not knowable at submit time — an
  init container has to query the pod's `nodeName` and the service's `nodePort`
  and compute `/node/<host>/<nodePort>/`.
* `/rnode/HOST/PORT/...` strips the prefix. **code-server needs this one.** It
  has no base-path setting for itself: it emits relative roots and assumes it is
  mounted at `/`. Served through `/node/`, it comes up blank.

`--abs-proxy-base-path` is *not* the flag that fixes that — in code-server
4.133.0 it only prefixes code-server's own `/absproxy/<port>` URLs. The
entrypoint passes it only when `CIRRUS_BASE_URL` is not `/`.

**Username.** `CIRRUS_NAMESPACE` should be templated as `ood-<%= user %>`. OOD
knows the authenticated username with certainty; the container does not. Without
it the bootstrap falls back to `$USER`, `$LOGNAME`, `id -un`, then the leaf of
`$HOME`, and warns on every line that the value was inferred. `id -un` is
deliberately *not* first: with no `/etc/passwd` entry it prints the uid as a
number and still exits 0, and `ood-54321` is not a namespace anyone has, so a
purely numeric candidate is rejected.

**Authentication.** JupyterLab's token and code-server's password are off:
`CIRRUS_JUPYTER_AUTH=none` and `--auth none`. That assumes the OOD proxy is the
only route to the port. The existing CIRRUS OOD apps instead generate a
per-session password in an init container and POST it from `view.html.erb`; if
you want that belt-and-braces behaviour here, set `CIRRUS_JUPYTER_AUTH=token`
for Jupyter and drop `--auth none` from the `code` branch of the entrypoint.

## kubeconfig bootstrap

`cirrus-kubeconfig-init` runs from the entrypoint before either server starts,
and is safe to re-run by hand mid-session.

The user's `$HOME/.kube/config` is **read and never written** — it is shared with
their Casper and Derecho sessions. Everything happens on a copy at `$KUBECONFIG`,
which is ephemeral by design: it is derived state, rebuilt every launch, so it
always reflects the current source config.

What it does:

1. Refuses a `KUBECONFIG` containing `:`. kubectl treats that as a merge list and
   writes only to the first entry, so mutations would land somewhere the session
   does not read from.
2. Errors out, naming the CIRRUS docs, if the source config is missing. It does
   not synthesise one.
3. Refuses to proceed if `KUBECONFIG` and `CIRRUS_KUBECONFIG_SRC` are the same
   file — compared by resolved path *and* `device:inode`, so a symlink or a
   differently-expanded `~` cannot slip past.
4. Copies the source to `$KUBECONFIG` at mode 0600.
5. Sets the current context to `mlc1`, or exits non-zero listing the contexts it
   did find. It never falls back to another cluster.
6. Sets the namespace from `CIRRUS_NAMESPACE`, validated as a DNS-1123 label — a
   silently normalised value would point the session at a namespace the user
   cannot access.
7. Rewrites the kubelogin `exec` args (with `yq`, not `sed`) to `--login
   devicecode`. There is no browser in this container, so nothing that wants a
   localhost redirect can work; device code prints a URL and a code to the
   terminal instead. It is also Azure kubelogin's default, which is what the
   CIRRUS kubeconfig has been using all along — so the public-client flow the
   Entra app registration needs is already known to work.
8. Points `--cache-dir` at the user's real `$HOME/.kube/cache/kubelogin` and
   points `exec.command` at `cirrus-kubelogin` — see below, because the token
   reuse story is not the one the design assumed.
9. Prints cluster, context, namespace and identity source.

If it fails, the session still starts. A pod that refuses to come up is a
crashloop the user cannot read; a session that starts with a broken kubeconfig
shows them the error and lets them fix it and re-run.

> **First call authenticates.** With a cold token cache, the first `kubectl` in a
> terminal prints a device-code URL. Run one there before using the `kubernetes`
> Python client from a notebook — the exec plugin's prompt has nowhere to go
> inside a kernel, so it will just time out.

### Token caching, and why `exec.command` is a wrapper

The original plan was to point `--cache-dir` at the user's existing
`~/.kube/cache/` and let an unexpired token from their HPC session carry over.
That does not work, and it is worth writing down why.

kubelogin ≥ 0.2 keeps tokens in the Azure SDK's persistent cache
(`pkg/internal/token/persistentcache.go` → `azidentity/cache.New`), which on
Linux is **libsecret over DBus**. A pod has no Secret Service, so that cache
silently does not exist. `--cache-dir` holds only `auth.json`, the *account
record* — not a token. On a workstation the tokens live in
`~/.IdentityService/msal.cache`, encrypted (a JWE, `alg:dir`) with a key from
the keyring, so copying that file into a container achieves nothing either;
verified by doing it, and kubelogin still started a fresh device-code flow.

The visible symptom is severe: the credential plugin runs once per `kubectl`
invocation, so **every command starts a new device-code sign-in**. Two
`kubectl get pods` in a row means signing in twice.

So `cirrus-kubeconfig-init` rewrites `exec.command` in the *copy* to
`/usr/local/bin/cirrus-kubelogin`, which caches the ExecCredential kubelogin
prints — it already carries `status.expirationTimestamp` — keyed by the exec
args, and replays it until just before expiry. `flock` around the sign-in keeps
a notebook and a terminal reaching for a token at the same moment from
producing two prompts. The result is one sign-in per token lifetime (about an
hour) instead of one per command.

The cached file is a bearer token at mode 0600 under `$CIRRUS_STATE_DIR`, on the
pod's own tmpfs, never the shared home, gone when the session ends — the same
thing a keyring would be holding if there were one. `CIRRUS_TOKEN_CACHE=off`
disables all of it and puts plain `kubelogin` back in the config.

When the access token does expire, the user signs in again: without a keyring
there is no refresh token to work from. If a whole workshop of hourly re-auths
is too much, the options are a Secret Service in the pod (dbus + gnome-keyring,
unlocked at startup), Azure CLI as the login method (`--login azurecli`, whose
cache *is* a plaintext file), or workload identity — each a bigger change than
this wrapper, and each needing something from the cluster side.

## Running it in the BYO-image Jupyter OOD app

`ondemand-jupyter-k8s-image` can launch this image today, with no change to that
app — but only because of one file in here. That app sets an explicit pod
`command:`

    /bin/sh /ood-launch/launch.sh lab --config=/ood/ondemand_config.py --ServerApp.port=8080 --ServerApp.ip=0.0.0.0

and a `command:` overrides the image's `ENTRYPOINT`, so `entrypoint.sh` never
runs. `launch.sh` probes `/usr/local/bin/start.sh` then `/srv/start` for a
wrapper and, finding neither, execs `jupyter` straight from `$PATH`. That does
start a server — with no session kubeconfig, no home isolation and no uid
lookup, and with `KUBECONFIG` inherited from the image `ENV` pointing at a file
that was never created.

So the image ships `/usr/local/bin/start.sh`: run the common bootstrap, then
`exec` whatever `launch.sh` handed it. Jupyter's own settings — `base_url`,
password, `root_dir` — stay entirely with that app's mounted config, which is
what makes it work behind `/node/`.

To try it:

1. Push the image, since the cluster cannot pull from a laptop:
   `docker tag cirrus-workshop:dev hub.k8s.ucar.edu/ncote/cirrus-workshop:test && docker push …`
   (or push a branch and let CI do it).
2. Launch the app with that image reference.
3. In a session terminal: `cirrus-check`. `CIRRUS_NAMESPACE` is not set by that
   app, so the namespace is inferred from `$USER`/`id -un` — that app mounts a
   synthesized `/etc/passwd`, so the lookup resolves and `ood-<user>` comes out
   right. Set it explicitly for the dedicated apps.

## Home directory isolation

`$HOME` is the user's GLADE home, shared with Casper and Derecho. A wheel
installed from this image into `~/.local` can break their HPC sessions outright:
different glibc, different CPU features. So the entrypoint redirects everything
cache-like into `$CIRRUS_STATE_DIR` (`/tmp/cirrus`) — `PIP_USER`,
`PYTHONUSERBASE`, `XDG_*`, `JUPYTER_DATA_DIR`, `JUPYTER_RUNTIME_DIR`,
`IPYTHONDIR`, `HELM_*` — and writes nothing to `$HOME/.local`, `$HOME/.jupyter`
or `$HOME/.config`.

`JUPYTER_CONFIG_DIR` is the one that needs care rather than redirection to
`/tmp`: it holds the user's Lab settings and workspace layout, which are worth
keeping between sessions. Its default is `$HOME/.jupyter`, and `jupyter_core`
writes a `migrated` marker into it on the very first command — so it is pointed
at `$CIRRUS_WORKDIR/.jupyter` instead, which persists without putting anything
new in the shared home's dotfiles.

Only three things in `$HOME` are touched: `$HOME/cirrus-workshop` (the working
directory, so the user's own files and Lab settings survive the session), the
kubelogin token cache, and `$HOME/.kube/cache` — kubectl's discovery cache,
which it writes next to the kubeconfig no matter what and which their HPC
sessions already share. Neither is a dotfile that can break a Casper or Derecho
login.

`/etc/profile.d/cirrus.sh` assigns every variable as `${VAR:-default}`. Terminals
opened inside a session re-source it, and an unconditional `KUBECONFIG=` there
would silently discard what OOD set at launch.

## Local testing

```bash
# build
docker build -t cirrus-workshop:dev cirrus-workshop-image/

# JupyterLab, as a uid that exists nowhere in the image, with a read-only
# kubeconfig mounted the way OOD mounts the user's home
docker run --rm -p 8888:8080 \
  --user 54321:54321 \
  -e HOME=/tmp/cirrus/home \
  -e CIRRUS_NAMESPACE=ood-$(id -un) \
  -e CIRRUS_KUBECONFIG_SRC=/mnt/kubeconfig \
  -v "$HOME/.kube/config:/mnt/kubeconfig:ro" \
  cirrus-workshop:dev jupyter
# -> http://localhost:8888/

# code-server
docker run --rm -p 8888:8080 --user 54321:54321 \
  -e HOME=/tmp/cirrus/home cirrus-workshop:dev code

# reproduce a session's environment without starting a server
docker run --rm -it --user 54321:54321 -e HOME=/tmp/cirrus/home \
  cirrus-workshop:dev bootstrap bash -l
```

Behind a real OOD `/node/` prefix, pass it in:

```bash
docker run --rm -p 8888:8080 -e CIRRUS_BASE_URL=/node/host/8080/ \
  cirrus-workshop:dev jupyter   # -> http://localhost:8888/node/host/8080/
```

## Verification helper

`cirrus-check [lab-number]` checks the session itself: kubeconfig present,
readable, and not the user's own file; context is `mlc1`; namespace matches
`ood-<user>`; the isolation variables really do point outside `$HOME`; a token
can be obtained (`kubectl auth whoami`); and an authorized call comes back
(`kubectl auth can-i list pods -n <ns>`). Pass/fail per check, non-zero exit if
any failed. `CIRRUS_SKIP_CLUSTER_CHECKS=1` runs the local half only.

Per-lab assertions drop in as `/opt/cirrus/labs/lab<N>.sh`, each defining a
`lab_checks()` function built from the same helpers:

```bash
# /opt/cirrus/labs/lab3.sh
lab_checks() {
    check    "lab 3 deployment exists"  kubectl get deploy/hello -n "$NAMESPACE"
    check_eq "lab 3 replica count" "3"  "$(kubectl get deploy/hello -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}')"
    check_out "lab 3 service is a ClusterIP" "ClusterIP" kubectl get svc/hello -n "$NAMESPACE"
}
```

`cirrus-check 3` runs the environment checks and then that file. A lab number
with no module installed is a failure, not a silent pass.

## Vulnerability scanning

`.github/workflows/build.yml` runs Trivy on the built image before the push, and
`build-push` will not run unless it passes. The gate is **CRITICAL only**, with
HIGH reported but not blocking: most HIGHs in an image like this are Go
standard-library findings inside third-party CLIs, fixable only by an upstream
rebuild, and gating on them produces a red pipeline nobody can turn green.

Two HIGHs are known and expected in the report: `msgpack` vendored inside pip
(whose HTTP cache this image disables via `PIP_NO_CACHE_DIR=1`) and `js-yaml`
inside code-server's own node tree (fixed in 4.3.1; code-server 4.133.0 is the
latest release and still bundles 4.3.0).

Two hardening steps came out of that scan: `apt-get upgrade` runs before the
package install so base-image patches are picked up, and
`/usr/share/python-wheels` is deleted after the venv is built -- the deb ships pip
24.0 and setuptools 68.1.2 wheels there purely to bootstrap `venv`, years behind
what the venv ends up with, and scanners correctly flag them.

## CI

`.github/workflows/build.yml` -- at the **repository root**, not in this
directory: GitHub only reads workflows from `<repo-root>/.github/workflows/`, and
one nested in a subdirectory is silently ignored, which looks exactly like a repo
with no CI. The image lives in `cirrus-workshop-image/` and the workflow points at
it via `CONTEXT`.

Following `cirrus-jhub-images`: the `CIRRUS-4x8` runner group, buildx against
`tcp://buildkitd.arc-systems:1234`, Harbor login from
`HARBOR_LOGIN`/`HARBOR_SECRET`, registry layer cache with
`image-manifest=true,mode=max`. `DOCKER_BUILD_SUMMARY` and
`DOCKER_BUILD_RECORD_UPLOAD` are off, as the daemonless buildkitd runners here
require.

Two jobs. `scan` builds the image to a local tarball -- these runners have no
docker daemon, so there is nothing to `docker run` against, but buildx can write
an OCI tar and Trivy reads it directly -- and fails on CRITICAL. `build-push`
runs only if that passed, and pushes the short SHA plus either the semver tag (on
a `x.y.z` tag push) or `:latest` (on `main`).

## Bumping versions

1. Change the `ARG` in the `Dockerfile`. Nothing else hardcodes a version.
2. Build, then run `cirrus-versions --check` in the image — it re-runs every tool
   and fails if any reports something other than the recorded pin.
3. Tag `x.y.z` to publish.

kubectl is the one with a rule attached: it must match the CIRRUS control plane
minor and must not lead it. The clusters are upgraded roughly quarterly, so bump
it after an upgrade lands, never in anticipation of one.
