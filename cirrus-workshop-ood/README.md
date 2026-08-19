# CIRRUS Workshop — Open OnDemand app

One Batch Connect app that launches the workshop image as either JupyterLab or
VS Code, with the shell chosen on the form.

```
manifest.yml     app name, category, description
form.yml         editor, shell, working dir, cpu, memory
submit.yml.erb   pod spec: image, env, mounts, init containers
view.html.erb    the Connect button (picks /node/ vs /rnode/)
info.md.erb      session card: which editor and shell were chosen
```

Deploy as any other OOD app — this directory is the app root, so it is normally
its own repository (as `cirrus-ood-vscode` is) or a directory under
`/var/www/ood/apps/sys/`. It lives here for now so it versions alongside the
image it launches.

## The one structural decision

OOD ships two proxies and they are **not** interchangeable:

| proxy | behaviour | who needs it |
| --- | --- | --- |
| `/node/HOST/PORT/` | forwards the whole path, prefix included | JupyterLab, told the prefix via `CIRRUS_BASE_URL_FILE` |
| `/rnode/HOST/PORT/` | strips the prefix | code-server, which has no base-path setting and emits relative roots |

Cross them and the session comes up **blank** rather than erroring.

`view.html.erb` builds that URL, and it cannot see the launch form: its binding
has the connection info and the keys of `<pod>-secret`, nothing else.
(`info.md.erb` *can* see the form via `user_context` — a different binding — which
is why the editor is shown on the card but cannot be read by the button.)

So `add-proxy-to-secret` writes `proxy=node|rnode` into the pod's Secret, which
the kubernetes adapter surfaces to the view. If that key is ever missing the view
offers both buttons with an explanation rather than raising and leaving the user
no way in.

## Why an init container computes the base URL

JupyterLab must know it is serving under `/node/<nodeName>/<nodePort>/`. The node
name is only known once the pod is scheduled and the NodePort once the service is
created, so neither can be written into the pod spec. `add-baseurl-to-cfg`
computes it with `kubectl` and appends it to a configmap file the container reads
via `CIRRUS_BASE_URL_FILE`. The image takes the last path-looking line of that
file, so a re-append cannot produce a nonsense prefix.

That init container is only added for the Jupyter path — code-server needs none of
it.

## What the app sets, and what it deliberately does not

Set, because OOD knows them for certain and the container does not:

* `CIRRUS_NAMESPACE=ood-<user>` — otherwise the image infers it from `$USER` and
  warns on every line that it guessed.
* `CIRRUS_CONTEXT=mlc1` — so a kubeconfig with several contexts can never resolve
  to the wrong cluster.
* `CIRRUS_SHELL` — from the form; the image falls back to bash if it is not
  installed rather than handing out a session with no usable terminal.

**Not** set: `CIRRUS_KUBECONFIG_SRC`. Left alone, the image searches
`~/.kube/cirrus-config`, then `~/.kube/config`, then the kubeconfig baked into the
image, and takes the first that can actually work in a container. Pinning it here
would turn the common case — an attendee with no kubeconfig of their own — from a
working session into a hard failure.

No `/etc/passwd` configmap either, unlike the other CIRRUS OOD apps: the image
handles an unknown uid itself with `nss_wrapper`.

## Assumptions to verify on first launch

Two things are load-bearing and cannot be checked from outside a real session:

1. **The pod's service account can `get pods` and `get services` in its own
   namespace**, and `patch` its Secret. The Jupyter BYO-image app already relies on
   the first for exactly the same computation. If the RBAC is not there, the base
   URL comes up empty (Jupyter serves at `/`, page blank, and the entrypoint logs a
   warning saying so) and the proxy key is missing (the view offers both buttons).
   Both degrade rather than crash — check `kubectl logs <pod> -c add-baseurl-to-cfg`.
2. **This OOD version surfaces non-`password` Secret keys to `view.html.erb`.**
   The other CIRRUS apps get `password` this way and their comments say every key
   is exposed; `proxy` is the same mechanism with a different key.

## First-run check

In a session terminal:

```bash
cirrus-check        # 20 checks: kubeconfig, isolation, shell, identity, authorization
kubectl get pods    # device-code sign-in on the first call, then cached
```
