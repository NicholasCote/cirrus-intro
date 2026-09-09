# 2. Containers, and the registries that hold them

← [Orientation](01-orientation.md) · next: [Kubernetes](03-kubernetes.md)

You do not need to install anything to see a container. You are in one.

---

## What a container is

A container is **one or more processes on a normal Linux kernel, given a
deliberately narrowed view of the machine.** That is the whole idea. There is no
guest kernel, no emulated hardware, no boot sequence. When this session started,
a process was launched on some node in the CIRRUS cluster and told:

* your root filesystem is *this* directory tree, not the node's — **mount namespace**
* the only processes you can see are your own — **PID namespace**
* you get *this* network interface and IP, not the node's — **network namespace**
* you may use this much CPU and this much memory, and no more — **cgroups**
* you may not do these privileged things — **capabilities, seccomp**

Every one of those is a kernel feature that predates the word "container".
Docker's contribution was not the isolation; it was making the *filesystem* part
shareable and reproducible — the image.

The practical difference from a VM: a VM virtualises a *machine*, so it costs a
kernel, a boot, and a fixed slice of RAM. A container virtualises a *view*, so it
costs approximately nothing and starts in the time it takes to `fork`. That is
why a cluster can run thousands of them and why Kubernetes can afford to throw
one away and start another the moment something looks wrong.

---

## Why anyone bothers

Four reasons, in the order they usually start to matter:

* **The dependencies travel with the code.** "Works on my laptop" becomes
  "works", because the laptop's Python, its shared libraries and its `LD_PATH`
  are all inside the artifact. This is the one that sells it: no `module load`,
  no conda environment that resolved differently on Tuesday.
* **It is reproducible by reference.** An image digest names one exact set of
  bytes forever. A paper can cite it; a rollback can name it; two people can be
  certain they ran the same thing.
* **It is the unit every scheduler now understands.** Kubernetes, CI runners,
  serverless functions, another institution's cluster — they all take an image.
  Containerising is what makes work portable off CIRRUS as well as onto it.
* **It is cheap.** No guest kernel and no boot, so a node runs hundreds of them
  and the platform can afford to destroy and recreate one the moment it looks
  unhealthy. Self-healing is only affordable because containers are cheap.

## When not to

Containers are oversold, and there are shapes they fit badly:

* **A one-off analysis you will run once.** The image is overhead with no payoff.
  Run it on Casper and move on.
* **Tightly-coupled MPI at scale.** It can be done, and on CIRRUS there is an
  operator for it ([page 10](10-workloads.md)), but Derecho's interconnect and
  scheduler exist for a reason. Containerising does not make a fabric faster.
* **Anything that needs the host kernel bent to its will.** A custom kernel
  module, a privileged device, raw host networking — the isolation you are
  buying is exactly what is in the way, and admission policy will refuse it.
* **Interactive desktop work, or an editor's worth of state.** Possible; rarely
  worth it.
* **Large mutable state kept inside the image.** An image is immutable and
  shared. Data belongs in a volume or in object storage
  ([page 7](07-storage.md)), never baked in — and a 40 GB image is a 40 GB pull
  on every node that runs it.

A useful test: *if it finishes, think twice; if it serves, containerise it.*

---

## Look at the one you are in

Run these in a terminal. Each one shows a different piece of the narrowing.

### The filesystem is not the node's

```bash
cat /etc/os-release
```

Ubuntu 24.04 — regardless of what the CIRRUS node itself runs. That is the
image's root filesystem, not the host's.

```bash
ls /
```

A complete, ordinary Linux tree. Nothing here came from the node except the
kernel that is running it.

### The process table is nearly empty

```bash
ps -ef
```

On the node there are hundreds of processes. Here you see a handful, and PID 1
is not `systemd` — it is the editor server this session started with:

```bash
cat /proc/1/cmdline | tr '\0' ' '; echo
```

PID 1 in a container is *the thing the container was started to run*. This
matters more than it looks: when Kubernetes wants to stop a container it signals
PID 1, so PID 1 has to be a process that handles signals rather than a shell
that ignores them.

### The limits are real, and `nproc` lies about them

```bash
nproc
```

That is very likely wrong. It reports the *node's* CPU count, because
`sched_getaffinity` has nothing to do with cgroups. The truth is in the cgroup:

```bash
cat /sys/fs/cgroup/memory.max     # bytes, or "max" for unlimited
cat /sys/fs/cgroup/cpu.max        # "<quota> <period>", both in microseconds
```

`memory.max` should match the **Memory (GB)** you chose on the launch form, in
bytes — 4 GB is `4294967296`. `cpu.max` of `200000 100000` means 200 000 µs of
CPU per 100 000 µs of wall clock: **2 CPUs**, which is what the form's default
asks for.

Those two numbers are the ones that bite. Exceed `cpu.max` and you are throttled
— slow, but alive. Exceed `memory.max` and the kernel OOM-kills the process
immediately, with no warning and no chance to clean up; Kubernetes reports it as
`OOMKilled` and restarts the container. Almost every "my pod keeps
restarting" turns out to be this. Ask for the memory you need on the form.

### You are yourself, not root

```bash
id
```

Your real NCAR uid and gid — not `root`, and not the `uid 1000` that most
container images assume. That is why your GLADE home mounts with the right
ownership and why files you create here look right from Casper.

It is also unusual. A stock container image bakes a user into `/etc/passwd` at
build time and expects to run as it; run it as an arbitrary uid instead and
`getpwuid()` fails, which makes `git` refuse to commit ("unable to look up
current user") and shell prompts show a bare number. This image works around
that; images you build yourself may need to as well.

### The network is its own

```bash
hostname
hostname -i
```

The hostname is the *pod* name, and the IP is a pod IP from the cluster network,
not the node's address. Remember the hostname — [page 3](03-kubernetes.md) uses it.

### Your home is mounted in from outside

```bash
df -h ~ | tail -1
mount | grep -c nfs || true      # || true: a count of zero is an answer, not an error
```

Your GLADE home is an NFS mount handed to the container. Everything *else* you
can see is either the image (read-only, shared with every other session running
it) or the pod's own scratch space.

This is the container split worth remembering: **the image is what you built,
the mounts are what you were given, and everything else vanishes.**

---

## Images and layers

An image is a stack of tarballs plus a JSON document saying how to start it. Each
instruction in a `Dockerfile` that changes the filesystem produces one layer:

```dockerfile
FROM ubuntu:24.04                     # layer(s): the base
RUN apt-get update && apt-get install -y curl   # layer: whatever that changed
COPY bin/ /usr/local/bin/             # layer: those files
ENV PATH=/opt/venv/bin:$PATH          # no layer: metadata only
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]     # no layer: metadata only
```

Layers are content-addressed and shared. If ten images are built `FROM
ubuntu:24.04`, the node stores that base once. That is also why layer *order*
matters: put the thing that changes most often last, or every build re-does
everything after it.

Two consequences people learn the hard way:

**A layer is never edited, only covered.** `RUN rm /secret` does not remove the
file from the image — it adds a layer that hides it. The bytes are still in the
earlier layer and anyone with the image can read them. Secrets must never enter
a build.

**A tag is a pointer, not a version.** `:latest` means whatever was pushed last.
The image running this session pins every tool to an explicit version for exactly
that reason:

```bash
cat /opt/cirrus/versions.txt
```

## How to create one

There is no `docker` or `podman` in this session, and that is deliberate:
building an image needs privileges that a workshop pod should not have.

Build images where you have a builder:

* on a laptop or workstation with Docker or Podman installed;
* in CI. This very image is built by a GitHub Actions workflow that pushes to
  Harbor on a tag — which is the pattern to copy for anything you intend other
  people to run.

The parts you need to know are portable regardless:

```bash notebook-skip
docker build -t hub.k8s.ucar.edu/<project>/<name>:<version> .
docker push  hub.k8s.ucar.edu/<project>/<name>:<version>
```

and then Kubernetes pulls it by that exact reference — which is
[page 3](03-kubernetes.md).

### The Dockerfile, and the five things worth getting right

A small web application is genuinely this short:

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8080
USER 1001
CMD ["python3", "app.py"]
```

Five decisions in there earn their keep, and each of them is something people
get wrong once and then debug for an afternoon:

1. **Pin the base, and prefer `-slim` or `-alpine`.** `FROM python:3.12-slim`
   rather than `python` or `python:latest`. A floating base means an image that
   builds differently next month and a CVE report you cannot reason about.
2. **Copy the dependency manifest before the source.** `requirements.txt` first,
   then `pip install`, *then* `COPY . .`. Layers are cached in order, so this way
   editing your code does not reinstall NumPy. Reversed, every build is a cold
   build.
3. **Bind to `0.0.0.0`, not `127.0.0.1`.** Inside the container `localhost` means
   the container, so a server bound to loopback is reachable from nothing. This
   is the single most common reason a container that works locally serves nothing
   on the cluster.
4. **Run as a non-root user.** `USER 1001` — an unprivileged uid. Admission
   policy on CIRRUS is not friendly to root containers, and the fix is one line
   at build time rather than an argument later. Note the corollary from *You are
   yourself, not root* above: your image may be run as an arbitrary uid it has
   never heard of, so make the paths it writes to group-writable rather than
   owned by one user.
5. **Do not run a development server in production.** Flask's built-in server
   says so itself on startup; use `gunicorn` or `uvicorn`. It is one line in
   `CMD` and it is the difference between a dashboard that survives being linked
   in a paper and one that does not.

Two more, once the image works: use a **multi-stage build** when the toolchain is
only needed to build (compile in one stage, `COPY --from=` the result into a
clean base), and add a **`.dockerignore`** so `COPY . .` does not sweep your
`.git`, your virtualenv and your data into a layer.

### Where to learn this properly

This page is enough to read a Dockerfile and reason about one. The CIRRUS
containerisation workshop is the hands-on version, and it is the right next step
if containers are the new part for you:

**[nbviz-to-container](https://github.com/NicholasCote/nbviz-to-container)** —
takes a real interactive Jupyter visualisation and turns it into a containerised
web server, then automates the build with GitHub Actions. It runs in a
Codespace with Podman available, so you get a builder without installing
anything, and it ends exactly where [page 3](03-kubernetes.md) begins.

The CIRRUS documentation's own container guidance is at
<https://ncar-hpc-docs.readthedocs.io/en/latest/compute-systems/cirrus/guides/03-deploying-applications/containerize/>.

---

## Container registries

A registry is where images are stored and fetched from — a content-addressed
store plus an HTTP API that `docker push`, `docker pull` and every kubelet in the
cluster speak. Public ones you will see: `docker.io` (Docker Hub), `quay.io`,
`ghcr.io`, `registry.k8s.io`.

NCAR runs its own: **Harbor, at `hub.k8s.ucar.edu`**, which is where this
session's image lives. Every part of a reference means something:

```
hub.k8s.ucar.edu / ncote  / cirrus-workshop : dev-v1.10
^registry          ^project ^repository       ^tag
```

The exact reference this session is running is not something to memorise — ask
the cluster for it, which is a trick [page 3](03-kubernetes.md) leans on:

```bash
kubectl get pod "$(hostname)" -o jsonpath='{.spec.containers[0].image}{"\n"}'
```

**Prefer Harbor for anything you deploy on CIRRUS.** Three concrete reasons:

* It is inside NCAR, so pulls are fast and do not depend on the cluster having a
  route to the public internet — which is not a given.
* It is not subject to Docker Hub's anonymous pull rate limit, which surfaces as
  `ErrImagePull` with `TooManyRequests` at exactly the wrong moment. "Image pulls
  are very slow" and "the pull failed for no reason" are both usually this.
* It scans what you push and tells you what is in it. See below.

### Signing in, and what a project is

Harbor's web UI takes your UCAR credentials through Microsoft with Duo. The CLI
does **not** take your password: Harbor issues a separate *CLI secret*.

*Top right → User Profile → copy the CLI secret*, then:

```bash notebook-skip
docker login hub.k8s.ucar.edu
# Username: your UCAR email address
# Password: the CLI secret, not your password
```

A **project** is Harbor's unit of access control — it is the second path segment,
and it holds repositories. Projects are created by Harbor administrators, so
*getting somewhere to push is a ticket*: ask for a project and for `Developer`,
`Maintainer` or `Project Admin` on it. A project can be public (anyone pulls, no
login) or private (a pull secret is needed, which is another thing to mention
when you ask).

Then the ordinary two commands:

```bash notebook-skip
docker tag  local-image:tag hub.k8s.ucar.edu/<project>/<repo>:<tag>
docker push               hub.k8s.ucar.edu/<project>/<repo>:<tag>
```

### Robot accounts

**Never put your own credentials in CI.** Harbor issues *robot accounts* for
exactly this: *Project → Robot Accounts → + NEW ROBOT ACCOUNT*, which asks for a
name, an expiry, and the permissions you want — `push` and `pull` is enough for a
build. The name comes out as `robot$<project>+<name>` and the secret is shown
**once**.

A robot account is scoped to one project, revocable on its own, carries none of
your personal access, and does not break when your password changes. The secret
can be regenerated from the ACTIONS dropdown if it leaks or expires.

### Tags: say which build

`:latest` costs you more on CIRRUS than it does elsewhere, and it is worth being
blunt about why. **`:latest` breaks GitOps outright.** Kubernetes will not pull an
image whose tag has not changed, and Argo CD will not sync a manifest whose text
has not changed — so pushing new bytes under the same tag deploys nothing, and
you will spend an hour looking for the bug. Then, separately: `:latest` gives you
no way to say which bytes are running and nothing to roll back *to*.

Use something that means one specific build — a commit SHA, a date, a semantic
version — and change the tag in the chart when you want the cluster to move. The
workflow below does that automatically.

### Vulnerability information and SBOM

Harbor runs **Trivy** against what you push. This is not box-ticking: your image
contains a Linux distribution and every transitive dependency of your language's
package manager, and CVEs are published against those continuously. An image that
was clean when you built it is not clean six months later, and nothing tells you
unless you look.

In the UI: your project → the repository → the **Artifacts** tab → tick the
artifact → **Scan**. It moves through *Queued → Scanning → a report*. Hover the
result for a summary by severity, or click the artifact for the full report:
each CVE, its severity, the package and version that introduced it, and the
version that fixes it — which is the column that matters, because it turns
"insecure" into a one-line change to a base image or a pin.

Beside *Scan* is **Generate SBOM**, which produces a software bill of materials —
a machine-readable inventory of every package in the image, downloadable from the
artifact view. It answers a different question from the scan: not "what is
known-bad today" but "what is in here at all", which is what you need when a new
CVE lands and someone asks whether you are affected. If your project has a
compliance requirement or an external collaborator asking what your image
contains, the SBOM is the artifact to hand them.

Three habits that follow from having a scanner:

* **Scan before you deploy, not after.** Trivy also runs as a GitHub Action
  ([page 8](08-github-actions.md)), so a pull request can fail on a new Critical
  rather than a person noticing one in the UI later.
* **Rebuild on a schedule, not only on a change.** Most fixes arrive in the base
  image, so a weekly rebuild of unchanged code genuinely reduces your CVE count.
* **Read the fix column, and triage.** A Critical in a library your code never
  calls is real but not urgent; a High in your TLS stack is. The report gives you
  enough to tell the difference.

### Pushing from CI

Putting the last three sections together — a robot account, a meaningful tag, and
a scan — this is the whole workflow:

```yaml
# .github/workflows/build.yml
on:
  push:
    branches: [main]
    tags: ['v*']

jobs:
  build-push:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: hub.k8s.ucar.edu
          username: ${{ secrets.HARBOR_LOGIN }}     # the robot account name
          password: ${{ secrets.HARBOR_SECRET }}
      - uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: |
            hub.k8s.ucar.edu/<project>/<name>:${{ github.sha }}
```

`HARBOR_LOGIN` is the robot account's name (`robot$<project>+ci`) and
`HARBOR_SECRET` its one-time secret, both stored as repository Actions secrets.
The tag is the commit SHA — one build, one name, nothing floating.

That is the shape of the workflow that builds *this* image. Two CIRRUS-specific
variations are worth knowing about and both live on
[page 8](08-github-actions.md): running the job on a **CIRRUS runner** rather than
`ubuntu-latest`, which needs a remote BuildKit endpoint because the runners are
not privileged, and using Harbor as a **layer cache** so rebuilds are minutes
rather than tens of minutes.

This is also the first half of [page 5](05-argocd.md): CI builds and pushes the
image, and then something else decides when the cluster starts running it.

---

## Check yourself

You should be able to answer these from the commands above, without looking
anything up:

1. Why is `nproc` the wrong way to ask how many CPUs you have?
2. What happens to your process if it allocates past `memory.max`? How is that
   different from exceeding `cpu.max`?
3. You delete a credentials file in a `RUN` line. Is it gone from the image?
4. Which parts of what you can see right now survive this session ending?
5. Your container works locally and serves nothing on the cluster. What is the
   first line of the Dockerfile-or-code to check?
6. You push new bytes under the same tag and the cluster keeps running the old
   ones. Name both reasons.
7. A scan is clean today. Why is that not an answer six months from now, and what
   does the SBOM tell you that the scan does not?

---

← [1. Orientation](01-orientation.md) · next: [3. Kubernetes](03-kubernetes.md)
