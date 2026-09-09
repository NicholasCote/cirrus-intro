# Troubleshooting

← [Start here](../README.md)

Ordered by how often they happen. Two commands come before everything on this
page:

```bash
cirrus-check                  # 20 checks on the session itself
cat /tmp/cirrus/bootstrap.log # what the session said while starting up
```

`cirrus-check` turns "Kubernetes is broken" into a line naming what is wrong, and
`bootstrap.log` is where the startup explained itself — including things you
cannot see from a browser.

---

## I am asked to sign in again

Expected, roughly hourly. The access token has a lifetime of about an hour and
there is no refresh token to renew from silently.

Why: `kubelogin` keeps tokens in the Azure SDK's persistent cache, which on Linux
is libsecret over DBus. A pod has no Secret Service, so that cache does not
exist. This image works around it with a wrapper that caches the credential
`kubelogin` prints and replays it until just before expiry — that is what turns
*one sign-in per `kubectl` invocation* into one per token lifetime. When the
token itself expires, there is nothing cached to replay.

Check the wrapper is actually in play:

```bash
kubectl config view --minify -o jsonpath='{.users[0].user.exec.command}{"\n"}'
```

It should print `cirrus-kubelogin`, not `kubelogin`. If it prints `kubelogin`,
token caching is off (`CIRRUS_TOKEN_CACHE=off`) and *every* command will prompt.

---

## Every single `kubectl` asks me to sign in

Not expected. Either the cache is disabled or it cannot be written.

```bash
echo "${CIRRUS_TOKEN_CACHE:-on}"     # should be "on" or unset
ls -la "${CIRRUS_TOKEN_CACHE_DIR:-/tmp/cirrus/kube/token-cache}"
cirrus-kubeconfig-init               # safe to re-run; rebuilds the session config
```

---

## `Forbidden`, and the name is not mine

```
Error from server (Forbidden): pods is forbidden:
User "system:serviceaccount:ood-you:default" cannot list resource "pods"
```

That `system:serviceaccount:` identity means **your kubeconfig is not being
used**. `kubectl` found no usable config and fell back to the pod's in-cluster
service account, which is nobody.

```bash
echo "$KUBECONFIG"        # must be a real file, not /dev/null
ls -l "$KUBECONFIG"
kubectl auth whoami       # should show your NCAR identity
cirrus-kubeconfig-init
```

Note the trap: `KUBECONFIG=/dev/null` is the OnDemand default for session pods,
and kubectl treats an empty config exactly like a missing one — silently. The
entrypoint redirects it to `/tmp/cirrus/kube/config` for this reason; if you set
`KUBECONFIG` by hand in a terminal, set it to that.

## `Forbidden`, and the name *is* mine

Then it is genuinely a permissions question, and the answer is authoritative:

```bash
kubectl auth can-i --list
kubectl auth can-i <verb> <resource>
```

Anything outside your own namespace will be forbidden, by design — see
[page 3](03-kubernetes.md#your-namespace-and-what-you-may-do-in-it).

---

## The kubeconfig is missing entirely

```
cirrus-kubeconfig-init: ERROR: no kubeconfig found
```

You have never set up CIRRUS access. The session deliberately does not invent a
config, because a fabricated one fails later and more confusingly. Follow the
CIRRUS `kubectl` guide to get one into `~/.kube/config`:

<https://ncar-hpc-docs.readthedocs.io/en/latest/compute-systems/cirrus/guides/10-kubectl/kubectl/>

Then, in the session:

```bash
cirrus-kubeconfig-init
cirrus-check
```

The session never writes to `~/.kube/config` — it copies it. Your Casper and
Derecho sessions read the same file and are unaffected by anything done here.

---

## The context `mlc1` does not exist

```bash
kubectl --kubeconfig ~/.kube/config config get-contexts
```

Your config has contexts, just not that one. The session refuses to fall back to
a different cluster rather than silently pointing you at the wrong one. Either
get an `mlc1` context, or override for one session:

```bash
CIRRUS_CONTEXT=<the-one-you-have> cirrus-kubeconfig-init
```

---

## The page is blank when I connect

A proxy mismatch, and there is nothing to fix from inside the session. OnDemand
has two proxies: `/node/` forwards the whole path (JupyterLab needs it) and
`/rnode/` strips it (VS Code needs it). Crossed, the server responds and every
asset request goes to a path it does not serve — a blank page rather than an
error.

If the session card offers two Connect buttons with an explanation, use the one
matching the editor you picked on the form. Otherwise relaunch and pick the
editor you want. If it recurs, it is worth reporting with the pod name.

---

## Arrow keys print `^[[A` in the terminal

The terminal got `/bin/sh` — dash, which has no readline. Start a real shell:

```bash
exec bash -l
```

The entrypoint tries hard to prevent this; if it happens, note what you chose for
**Shell** on the launch form and report it. `tcsh` is a common NCAR login shell
and is available on the form, but a login shell the image does not carry falls
back to `bash` by design.

---

## Tab completion does not work

You are in `tcsh`, or in a shell started in a way that skipped the environment.
`kubectl`, `helm`, `argocd` and `stern` publish `bash` and `zsh` completions
only; `tcsh` gets the `k` alias and the environment but no completion. Either
pick `bash` or `zsh` on the launch form, or:

```bash
exec bash -l
```

---

## `git` says "unable to look up current user"

Your uid has no `/etc/passwd` entry — the normal state of affairs when a pod runs
as your real NFS uid. The image loads `nss_wrapper` to answer the lookup; if you
are seeing this, that failed.

```bash
id
whoami                        # should be your username, NOT a number
echo "$LD_PRELOAD"            # should name libnss_wrapper.so
```

If `whoami` prints a number, report it with the output of those three commands.
Meanwhile, `git` works if you tell it who you are explicitly:

```bash
git config --global user.name "Your Name"
git config --global user.email "you@ucar.edu"
```

---

## A pod is not Running

Start here, always. **The answer is in `describe`**, in the Events section at the
bottom, and the whole of the rest of this section is elaboration on that:

```bash
kubectl get pods
kubectl describe pod <name>          # read the Events at the bottom
kubectl logs <name>
kubectl logs <name> --previous       # if it restarted
```

| status | cause | fix |
| --- | --- | --- |
| `Pending` | nothing can satisfy `requests`, or quota is exhausted | below |
| `ImagePullBackOff` | wrong reference, or unreachable registry | below |
| `ErrImagePull` + `TooManyRequests` | Docker Hub anonymous rate limit | push to Harbor and pull from there |
| `CrashLoopBackOff` | the container starts and exits | below |
| `OOMKilled` | over `limits.memory` | raise the limit, or use less memory |
| `Running` but not `Ready` | readiness probe failing | `describe` shows the probe's error; check path and port |
| `ContainerCreating`, stuck | usually a volume that cannot attach | below, under *quota and volumes* |
| `Completed` | the command returned | fine for a Job, wrong for a server — your process is not staying up |

### `ImagePullBackOff`

The kubelet could not fetch the image. `describe` names which of these it is:

```bash
kubectl describe pod <name> | grep -A5 Events
```

* **`not found` / `manifest unknown`** — the reference is wrong. Check it
  character by character: registry, project, repository, tag. A tag that does not
  exist looks identical to a typo. Confirm in Harbor's UI that the tag is
  actually there.
* **`unauthorized`** — a private Harbor project with no pull secret, or an expired
  one. Ask for the pull secret to be added to your namespace.
* **`TooManyRequests`** — Docker Hub's anonymous rate limit. Mirror the image into
  `hub.k8s.ucar.edu` and pull from there. This is also the answer to "pulls are
  extremely slow".
* **`no such host` / a timeout** — the cluster has no route to that registry.
  Prefer Harbor; it is on the local network.
* **It pulled yesterday and not today** — someone deleted or re-tagged the image.
  A reference by digest cannot have this happen; a floating tag can.

### `CrashLoopBackOff`

The container is starting and exiting, and Kubernetes is restarting it with an
increasing back-off. The *pod* is not broken — your process is. Its last words
are the answer:

```bash
kubectl logs <name> --previous       # THE command here: the container that died
kubectl describe pod <name> | grep -i -A3 'last state'
```

In rough order of frequency:

* **The command or entrypoint is wrong.** Wrong path, missing interpreter,
  arguments the program does not accept. `--previous` shows the error.
* **A missing environment variable or config.** The process starts, fails to find
  what it needs, exits non-zero. The fix is a ConfigMap or an ExternalSecret,
  not a restart.
* **The process is not staying in the foreground.** A server that daemonises and
  returns leaves PID 1 exited, so the container is `Completed` or looping. Run it
  in the foreground; that is what containers want.
* **`OOMKilled` between restarts.** Check `Last State` in `describe`. Startup
  memory spikes are easy to miss because average usage looks fine.
* **A dependency is not up yet.** A database that is not ready, and the process
  exits rather than retrying. Restarting *is* the retry, so this one self-heals —
  if it does not settle within a minute or two, it is not this.

If the container dies too fast to inspect, override the command to keep it alive
and go and look:

```bash notebook-skip
kubectl run debug --rm -it --image=<your image> --command -- bash
```

### `Pending`, quota, and volumes

`Pending` means nothing has been scheduled. Two families of cause, and
`describe` distinguishes them:

```bash
kubectl describe pod <name> | tail -20     # the scheduler explains itself here
kubectl describe resourcequota
kubectl get limitrange -o yaml
```

* **"Insufficient cpu" / "Insufficient memory"** — no node has room for your
  `requests`. Requests are a reservation, not a prediction: asking for 32 GB
  because it might be needed means waiting for a node with 32 GB free. Ask for
  what you use.
* **`exceeded quota`, at *creation* time** — the namespace is full. This one is
  rejected outright with a message naming the quota, which is friendlier than it
  looks. `kubectl describe resourcequota` shows used against hard for every
  counted thing, **including storage and object counts** — a forgotten PVC or a
  pile of completed Jobs can exhaust a quota with nothing running.
* **A LimitRange rejection** — the manifest has no `requests`/`limits`, or asks
  for more than a single object may. The message names the LimitRange. Add the
  fields; every manifest in this material has them for exactly this reason.
* **Stuck in `ContainerCreating` with a volume in the events** — a
  `ReadWriteOnce` PVC already attached to another node. This is the multi-replica
  RWO trap from [page 7](07-storage.md#access-modes-are-the-decision-that-matters).
  One writer, or `ReadWriteMany`.

Clean up before asking for more quota; it is usually enough:

```bash
kubectl delete pod --field-selector=status.phase==Succeeded
kubectl get pvc                     # anything bound and unused?
helm list                           # any releases you forgot?
```

---

## Nothing reaches my application

Debug **backwards**, from the outside in. Each step tells you whether to keep
going out or start looking in:

```bash
kubectl get ingress                                   # 1. does the rule exist
kubectl get svc <name>                                # 2. does the Service exist
kubectl get endpointslices -l kubernetes.io/service-name=<name>   # 3. ANY endpoints?
kubectl get pods -l <your selector>                   # 4. are pods Ready
kubectl port-forward deploy/<name> 8080:8080          # 5. does the app answer at all
```

Step 3 is where the answer usually is. **An empty endpoint list means the Service
matches nothing**, and there are only two reasons: the selector does not match
the pod labels (a typo, or the labels changed), or the pods are running but not
`Ready` — an unready pod is deliberately kept out of the endpoint list.

A 503 from the Ingress with a healthy-looking Ingress object is this, every time.
Symptom-to-cause:

| what you see | where to look |
| --- | --- |
| Ingress 404 | the host or path in the rule does not match the request |
| Ingress 503 | Service has no endpoints — step 3 |
| works via `port-forward`, not via the Service | `targetPort` does not match `containerPort` |
| works in-cluster, not from outside | `ingressClassName` — `traefik-internal` needs the UCAR network |
| certificate warning | cert-manager has not issued yet, or the `secretName` is wrong |
| the app answers `127.0.0.1` only | it is bound to loopback — bind to `0.0.0.0` |

---

## Argo CD says `OutOfSync` and will not settle

```bash notebook-skip
argocd app diff <app>                   # or the UI's DIFF button
```

* **A hand-edited object.** With `selfHeal: true` it is reverted, but if something
  keeps re-editing it the loop never converges. The usual culprit is a field
  something else owns — an HPA writing `replicas`, or a mutating webhook adding
  something. Remove that field from git.
* **A manifest outside `templates/`.** Argo CD renders the chart; a file next to
  `Chart.yaml` is not part of it and is silently ignored.
* **A release you never uninstalled.** Two owners for one Deployment —
  [page 4](04-helm.md#uninstall-before-you-hand-it-over).
* **`Synced` and `Degraded` together** is not a delivery problem: git got exactly
  what it asked for, and what it asked for is broken. Read the pod logs.
* **Nothing happens after a push.** The default reconcile interval is three
  minutes. Wait, then look.

## I pushed a new image and nothing changed

Two independent causes, and it is usually the first:

1. **The tag did not change.** `:latest`, or any reused tag. Kubernetes will not
   re-pull an unchanged tag and Argo CD will not sync unchanged text. Use a
   commit SHA — [page 2](02-containers.md#tags-say-which-build).
2. **The chart was not updated.** CI pushed the image but nothing edited
   `values.yaml`, so git still names the old tag and the cluster is correct to
   keep running it — [page 8](08-github-actions.md#closing-the-loop-to-argo-cd).

## My ExternalSecret produces nothing

```bash notebook-skip
kubectl get externalsecret <name> -o yaml | tail -20     # status and conditions
kubectl get secretstores -o name
```

* **The wrong `secretStoreRef.name`.** The store's name varies by namespace —
  `user-ro` in the example chart, `openbao-backend` in the docs. Read it from your
  own namespace rather than copying.
* **The path or property does not exist.** Both are case-sensitive and the path
  includes your full email address.
* **The store's own credential expired.** If it worked for months and then
  stopped, check the token at `you@ucar.edu/bao` in OpenBao —
  [page 6](06-secrets.md#authentication-how-the-cluster-gets-in).
* **The Secret updated and the pods did not.** Expected: an env var is read once
  at start. Restart the Deployment, or mount the Secret as a file.

## An alert never arrived

You cannot read Alertmanager's logs on CIRRUS, so this is diagnosed by
elimination — and it is much easier if you tested with an always-firing rule
first. [Page 9](09-observability.md#when-an-alert-does-not-arrive) has the
ordered list.

---

## `kubectl` hangs in a notebook

The credential plugin wants to print a device-code prompt and a kernel has
nowhere to print it, so it waits until it times out.

**Run one `kubectl` in a terminal first.** That does the sign-in and caches the
token; the notebook then finds a valid credential and returns immediately. Same
for the `kubernetes` Python client.

---

## I cannot save an edit to these pages

Correct — `~/cirrus-workshop/README.md` and everything under `cirrus-intro/` are
read-only, and both are replaced from the image at every launch. That is what
keeps them current without anyone copying anything.

If you want to annotate them, copy first:

```bash
cp ~/cirrus-workshop/cirrus-intro/03-kubernetes.md ~/cirrus-workshop/my-notes.md
```

Anything else in `~/cirrus-workshop/` is on your GLADE home and persists. If you
want the working directory's `README.md` to be *yours*, just overwrite it — once
its first line no longer carries the `cirrus-content:` marker, the session leaves
it alone and says so in the startup log. Delete it and the material comes back.

---

## `pip install` disappeared between sessions

By design. Python packages installed here go to the session's own directory, not
to `~/.local`, because a wheel built inside this container can break your Casper
and Derecho logins outright — different glibc, different CPU features.

For something you need every session, build a venv on your GLADE home from a
Casper or Derecho login and activate it here. For something you need in a
*deployed* workload, put it in an image ([page 2](02-containers.md)).

---

## My editor lost files / the session ended unexpectedly

Only `~/cirrus-workshop/` is on persistent storage. Everything under
`/tmp/cirrus/` — editor state, extension installs, caches, tokens — is on the
pod and goes with it.

Sessions also end when their wall-clock time runs out, and a pod can be evicted
if the node comes under pressure. Save into `~/cirrus-workshop/`, and for
anything you care about, `git commit`.

---

## Reporting something

Include these four things and the answer usually comes back first try:

```bash
cirrus-check          2>&1 | tail -40
cirrus-versions
kubectl config current-context; echo "$CIRRUS_NAMESPACE"
hostname              # the pod name, which is how the logs are found
```

Plus what you chose for **Editor** and **Shell** on the launch form.

---

← [Start here](../README.md) · [1. Orientation](01-orientation.md)
