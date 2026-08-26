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
[page 5](05-cirrus.md#your-namespace-and-the-fence-around-it).

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

Work down this list; the answer is almost always in `describe`.

```bash
kubectl get pods
kubectl describe pod <name>          # read the Events section at the bottom
kubectl logs <name>
kubectl logs <name> --previous       # if it restarted
```

| status | cause | fix |
| --- | --- | --- |
| `Pending` | no node can satisfy `requests`, or quota is exhausted | lower `requests`; `kubectl describe resourcequota` |
| `ImagePullBackOff` | wrong reference, or the cluster cannot reach that registry | check the exact string; prefer `hub.k8s.ucar.edu` |
| `ErrImagePull` + `TooManyRequests` | Docker Hub anonymous rate limit | push to Harbor and pull from there |
| `CrashLoopBackOff` | the container starts and exits | `logs --previous`; usually the command is wrong or PID 1 exits |
| `OOMKilled` | over `limits.memory` | raise the limit, or use less |
| `Running` but not `Ready` | readiness probe failing | `describe` shows the probe's error; check path and port |
| `Completed` | the command returned | fine for a Job, wrong for a server — your process is not staying up |

---

## `kubectl` hangs in a notebook

The credential plugin wants to print a device-code prompt and a kernel has
nowhere to print it, so it waits until it times out.

**Run one `kubectl` in a terminal first.** That does the sign-in and caches the
token; the notebook then finds a valid credential and returns immediately. Same
for the `kubernetes` Python client.

---

## I cannot save an edit to these pages

Correct — `~/cirrus-workshop/README.md` and everything under `intro/` are
read-only, and both are replaced from the image at every launch. That is what
keeps them current without anyone copying anything.

If you want to annotate them, copy first:

```bash
cp ~/cirrus-workshop/intro/02-kubernetes.md ~/cirrus-workshop/my-notes.md
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
*deployed* workload, put it in an image ([page 1](01-containers.md)).

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

← [Start here](../README.md) · [5. CIRRUS itself](05-cirrus.md)
