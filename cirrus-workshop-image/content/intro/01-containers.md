# 1. Introduction to containers

← [Start here](../README.md) · next: [Kubernetes](02-kubernetes.md)

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
not the node's address. Remember the hostname — page 2 uses it.

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

## Images, layers, registries

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

A registry is where images are stored and fetched from. Public ones you will see:
`docker.io` (Docker Hub), `quay.io`, `ghcr.io`, `registry.k8s.io`. NCAR runs its
own — **Harbor, at `hub.k8s.ucar.edu`** — which is where this image lives:

```
hub.k8s.ucar.edu / ncote  / cirrus-workshop : dev-v1.10
^registry          ^project ^repository       ^tag
```

The exact reference this session is running is not something to memorise — ask
the cluster for it, which is a trick page 2 leans on:

```bash
kubectl get pod "$(hostname)" -o jsonpath='{.spec.containers[0].image}{"\n"}'
```

Prefer Harbor for anything you deploy on CIRRUS. It is inside NCAR, it is not
rate-limited the way Docker Hub is for anonymous pulls, and its scanner reports
CVEs in what you pushed.

---

## Building images — not here

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

and then Kubernetes pulls it by that exact reference — which is page 2.

### Pushing to Harbor from CI

Two details specific to NCAR's Harbor, and both are the kind of thing that is
easy to get wrong once and then live with:

**Authenticate with a robot account, never your own credentials.** In Harbor,
*Project → Robot Accounts → New Robot Account* issues a name and a secret scoped
to that project and to the permissions you pick (`push` and `pull` is enough for
a build). It can be revoked without touching your account, it does not carry your
personal access, and it does not break when your password changes. Put the name
and secret in the repository's Actions secrets.

**Tag with something that means one specific build.** A workflow that only ever
pushes `:latest` gives you no way to say which bytes are running, and no way to
roll back to the previous ones.

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
            hub.k8s.ucar.edu/<project>/<name>:latest
```

That is the shape of the workflow that builds *this* image, and of the one in the
[GitOps and Harbor workshop](../README.md#going-further). It is also the
first half of page 4: CI builds and pushes the image, and then something else
decides when the cluster starts running it.

---

## Check yourself

You should be able to answer these from the commands above, without looking
anything up:

1. Why is `nproc` the wrong way to ask how many CPUs you have?
2. What happens to your process if it allocates past `memory.max`? How is that
   different from exceeding `cpu.max`?
3. You delete a credentials file in a `RUN` line. Is it gone from the image?
4. Which parts of what you can see right now survive this session ending?

---

← [Start here](../README.md) · next: [2. Introduction to Kubernetes](02-kubernetes.md)
