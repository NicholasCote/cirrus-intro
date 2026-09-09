# 10. Specialized workloads

← [Observability](09-observability.md) · [Troubleshooting](99-troubleshooting.md)

Everything so far assumed the same shape: a long-running server, described as a
Deployment, published through a Service and an Ingress. Most of CIRRUS is that
shape, and if it fits your work you can stop here.

Four things do not fit it, and each has a purpose-built answer on the platform.
This page is a map rather than a walkthrough — enough to know which one you want
and where the real documentation is.

| you have | the answer | requires |
| --- | --- | --- |
| interactive analysis, notebooks, GPUs | **JupyterHub** | nothing — just log in |
| small pieces of code triggered by requests | **Fission** (functions as a service) | a ticket |
| multi-node MPI, distributed training | **MPI Operator** | `kubectl` access |
| an LLM for coding or chat | **Open WebUI / qwen3-coder** | nothing — just log in |

---

## Jupyter on CIRRUS

<https://jupyter.k8s.ucar.edu/> — UCAR network or VPN, UCAR CIT credentials.
**Anyone with a CIT account already has access.** No ticket, no namespace, no
`kubectl`.

This is the lowest-effort thing on the whole platform and the one most worth
knowing about, because it turns "I need a machine with a GPU and xarray" into a
browser tab.

### Choosing a server

The Server Options page after login offers:

* **NSF NCAR CPU notebooks**, in three resource tiers.
* **NSF NCAR GPU notebooks** — PyTorch and TensorFlow images, with kernels
  `cirrus-pytorch-base` and `cirrus-tensorflow-base` already populated. GPUs are
  shared using NVIDIA **time slicing**, so several people run on one physical GPU
  concurrently; it is fair-shared rather than exclusive, which is the right
  trade-off for interactive work and the wrong one for a benchmark.
* **Custom environment** — a community scientific image, your own image, or a
  repository built on demand.

The base environments are `cirrus-base` (Python, assembled from user input and
maintained by the CCPP team) and `r-4.4` (mirroring the package set on the HPC
JupyterHub).

### Your own environment, three ways

**A conda environment that persists.** `/home/jovyan` is a persistent volume, so
an environment created under `/home/jovyan/my-conda-envs` survives between
sessions and appears in the kernel menu — `nb_conda_kernels` does that
automatically:

```bash notebook-skip
conda env create -f environment.yml
conda activate my-env
```

**Binder, from a repository.** *Choose Your Environment → Build your own image*,
give it a repository URL and optionally a branch, tag or commit. If the repo has
an `environment.yml` or `requirements.txt`, Binder builds a container from it and
launches JupyterLab inside it. This is the answer to "send my collaborator
something that just runs", and it is the same mechanism as public mybinder.org,
running on NCAR hardware.

**Your own image**, if you have already built one for Harbor
([page 2](02-containers.md)) — the Custom Environment option takes an image
reference.

### Scaling out with Dask

One notebook is one pod, so `LocalCluster` is limited by the resources you asked
for at launch. Start there anyway:

```python
from dask.distributed import Client, LocalCluster

cluster = LocalCluster("cluster-name", n_workers=4)
client = Client(cluster)
client
```

When that is not enough, **`dask-gateway`** provisions workers as their own pods
with their own resources:

```python
from dask.distributed import Client
from dask_gateway import GatewayCluster

cluster = GatewayCluster(
    "http://traefik-dask-gateway/services/dask-gateway/",
    public_address="https://jupyter.k8s.ucar.edu/services/dask-gateway/",
    auth="jupyterhub",
)
cluster.adapt(minimum=2, maximum=20)      # scale with the work
client = Client(cluster)
client
```

Two things to hold on to:

* **`dask-jobqueue` does not work here.** It provisions through PBS or Slurm, and
  there is no batch scheduler on CIRRUS. `PBSCluster` belongs on the HPC
  JupyterHub; `dask-gateway` is its counterpart on Kubernetes. Mixing them up is
  the most common Dask question on this platform.
* **`cluster.close()` when you are done.** Idle clusters are reaped
  automatically, but workers you have forgotten are quota nobody else can use.

The dashboard URL printed by the client works with the Dask JupyterLab extension
in the sidebar — paste it in and you can tile the task stream and worker panels
beside the notebook, which is genuinely the fastest way to find out why a
computation is slow.

Docs: <https://ncar-hpc-docs.readthedocs.io/en/latest/compute-systems/cirrus/guides/06-jupyter-on-cirrus/jupyterhub/>

---

## Functions as a Service

Sometimes the unit of work is smaller than a server. A function that subsets a
dataset when someone asks, a webhook receiver, a small conversion endpoint — all
of those are a handful of lines of Python, and wrapping each one in a Deployment
that idles 24 hours a day is disproportionate.

CIRRUS runs **[Fission](https://fission.io/docs/)** for this. You supply a
function; Fission keeps a warm pool of runtime pods, routes an HTTP request to
one, and executes it. No Dockerfile, no Service, no Ingress.

**Access is a ticket** — ask for the FaaS provider, and you get API server access
with it if you do not have it. There is no GUI; everything is the `fission` CLI
or manifests.

### The three objects

| object | what it is |
| --- | --- |
| **Environment** | the language runtime. One per language, shared by all your functions in it. |
| **Function** | your code, bound to an entrypoint. |
| **HTTPTrigger** (route) | the URL that invokes it. |

```bash notebook-skip
# once per language, per namespace
fission env create --name python --poolsize=1 \
  --image ghcr.io/fission/python-env \
  --builder ghcr.io/fission/python-builder \
  -n <your-namespace>

# a function with no dependencies
fission fn create --name hello --env python --code hello.py -n <your-namespace>

# a function with pip dependencies, as an archive
zip -r src.zip myfunc.py requirements.txt
fission fn create --name myfunc --env python --src src.zip \
  --entrypoint myfunc.main -n <your-namespace>
fission pkg list -n <your-namespace>        # BUILD_STATUS must reach "succeeded"

# expose it
fission route create --function hello --name hello --url /<username>/hello \
  --route-provider gateway --gateway traefik/traefik-gateway \
  --route-host=fn.k8s.ucar.edu -n <your-namespace>
```

Then `https://fn.k8s.ucar.edu/<username>/hello`.

Python, Ruby, NodeJS, PHP, Bash, Go, Java and plain binaries are supported.

### The four things to know before you start

* **URL paths are global and first-come, first-served.** Every route shares the
  `fn.k8s.ucar.edu` host across every user and namespace. **Prefix your paths
  with your username, team or project.** A route whose path is already claimed
  does not error usefully — it shows `READY False` in `fission route list`, and a
  route stuck at `False` with nothing else wrong is almost always a taken path.
* **Build status lives on the *package*, not the function.** `fission pkg list`
  and `fission pkg info --name <pkg>` are where build logs are. A function that
  never becomes ready is usually a package that never built.
* **Environments are shared infrastructure**, and each keeps `poolsize` warm pods
  running against your namespace quota. One per language, reused — not one per
  function.
* **Bake complex dependencies into an image** rather than using the builder.
  Fission's builder is fine for a few simple pip packages; a scientific stack or
  conda wants a custom runtime image extending `ghcr.io/fission/python-env`,
  pushed to Harbor. The deployment archive then stays tiny.

### Functions under GitOps

Everything above is imperative, which sits badly with [page 5](05-argocd.md). It
does not have to: every Fission object has a manifest equivalent, so the whole
thing can live in git and be reconciled by Argo CD.

| CLI | manifest |
| --- | --- |
| `fission env create` | `Environment` |
| `fission fn create --src` | `Package` |
| `fission fn create` | `Function` |
| `fission route create` | `HTTPTrigger` |

Two details in that setup are non-obvious and both cost an afternoon if you meet
them cold:

* **Pin the archive by immutable URL and checksum.** A `Package` points at a zip
  by `spec.deployment.url` plus `checksum.sum`. Use a GitHub *release asset*, not
  a `github.com/.../archive/...` auto-generated zip — those are not byte-stable
  and the checksum will break.
* **Change something on the `Function` every release.** Warm pool pods cache
  their specialisation, so if the `Function` spec is byte-identical the executor
  has no reason to re-specialise and **your old code keeps serving**. The CIRRUS
  pattern is an annotation carrying the archive checksum, bumped by CI. "I
  deployed and nothing changed" is this, every time.

Once the manifests are in a repository, onboarding is the same ticket as any
other application ([page 5](05-argocd.md#onboarding-an-application-on-cirrus)) — and after
that, `fission` commands that *modify* objects only hold until the next sync.
Reads are unaffected.

Docs: <https://ncar-hpc-docs.readthedocs.io/en/latest/compute-systems/cirrus/guides/12-faas/faas/>

---

## MPI

Yes, you can run MPI on CIRRUS. Read [page 1](01-orientation.md) again first:
**for a large tightly-coupled job, Derecho is the right machine** — its
interconnect and its scheduler exist for exactly that, and Kubernetes is not
going to beat them.

What the MPI support here is genuinely good for is MPI work that needs to live
*next to something else*: a CI pipeline that runs a multi-node test on every pull
request, a distributed training job triggered by an API call, a workflow that
mixes a short parallel step with services.

The mechanism is the **[Kubeflow MPI Operator](https://github.com/kubeflow/mpi-operator)**,
which adds an `MPIJob` resource. You describe the job; the operator creates the
launcher and worker pods, distributes SSH keys between them, and cleans up.

```yaml
apiVersion: kubeflow.org/v2beta1
kind: MPIJob
metadata:
  name: pi
spec:
  slotsPerWorker: 1
  mpiReplicaSpecs:
    Launcher:                       # runs mpirun; your program lives here
      replicas: 1
      template:
        spec:
          containers:
            - image: docker.io/mpioperator/mpi-pi:openmpi
              name: mpi-launcher
              command: ["mpirun"]
              args: ["-n", "2", "/home/mpiuser/pi"]
    Worker:                         # runs sshd and waits to be told what to do
      replicas: 2
      template:
        spec:
          containers:
            - image: docker.io/mpioperator/mpi-pi:openmpi
              name: mpi-worker
              command: ["/usr/sbin/sshd", "-De", "-f", "/home/mpiuser/.sshd_config"]
```

```bash notebook-skip
kubectl apply -f mpijob.yaml
kubectl get mpijob pi -w
kubectl logs -l training.kubeflow.org/job-name=pi -c mpi-launcher
kubectl delete mpijob pi
```

### The four things that actually go wrong

* **SSH is the whole mechanism, and most failures are SSH failures.** The
  launcher `ssh`es into the workers to start ranks. So workers must run `sshd` as
  their main process, the image must have host keys, and `sshAuthMountPath`
  (default `/root/.ssh`) must be where the image expects them. `Connection timed
  out` means the worker is not running `sshd`; `Permission denied (publickey)`
  means the keys are not where they should be; `no hostkeys available` means the
  image is missing `/etc/ssh/ssh_host_*_key`.
* **The image must contain MPI.** `command not found` on `mpirun` is not a
  Kubernetes problem. Start from `mpioperator/mpi-pi:openmpi` or
  `mpioperator/mpi-horovod-mnist` to prove the plumbing, then build your own on
  OpenMPI, Intel MPI or MVAPICH.
* **Read the launcher's logs, not the workers'.** `mpirun`'s output — and your
  program's — appears on the launcher. The workers mostly log `sshd`.
* **`Pending` means resources, as always.** `kubectl describe mpijob` and
  `kubectl describe pod <worker>`; usually the total request across all workers
  exceeds the quota.

Two flags worth knowing: `slotsPerWorker` should match the ranks you want per pod
(for GPU work, the GPU count), and `runPolicy.cleanPodPolicy: Running` keeps the
pods after completion so you can inspect them — then delete the MPIJob by hand.

For GPUs, request them like any other resource, and use the framework's own
launcher inside `mpirun`:

```yaml
          resources:
            limits:
              nvidia.com/gpu: 1
```

For large shared datasets, mount them rather than copying — see
[page 7](07-storage.md).

Submitting an MPIJob from a GitHub Actions workflow is the CI pattern, and it is
the same submit / wait / collect / clean-up shape as
[page 8](08-github-actions.md#running-against-the-cluster-from-a-workflow).

Docs: <https://ncar-hpc-docs.readthedocs.io/en/latest/compute-systems/cirrus/guides/13-mpi/mpi/>

---

## LLM services

CIRRUS hosts a local LLM service — on NCAR hardware, so prompts and code do not
leave the network. UCAR network or VPN required.

**Chat:** <https://llm.k8s.ucar.edu> — sign in with the *Log in with Microsoft*
button. The interface is Open WebUI; the model is **`qwen3-coder-next`**, tuned
for code, and it is selected by default. Sessions are saved between logins. Web
search is available but off by default, per chat session.

**In an editor or a terminal**, the same service speaks a compatible API, so
existing tools point at it. Get an API key first: *profile icon → Settings →
Account → API Keys*.

For Claude Code:

```bash notebook-skip
export ANTHROPIC_BASE_URL=https://llm.k8s.ucar.edu/api
export ANTHROPIC_API_KEY=dummy
export ANTHROPIC_AUTH_TOKEN=<your Open WebUI token>
export ANTHROPIC_DEFAULT_OPUS_MODEL=qwen3-coder-next
export ANTHROPIC_DEFAULT_SONNET_MODEL=qwen3-coder-next
export ANTHROPIC_DEFAULT_HAIKU_MODEL=qwen3-coder-next
```

For VS Code, the **Cline** extension: install it, choose *Bring my own API key*,
set the base URL to `https://llm.k8s.ucar.edu/api` and paste the token.

`Connection refused` almost always means you are off the VPN.

### Read this part

An agent with permission to read, edit and run commands is a real hazard, and the
CIRRUS documentation is blunt about it. Three specifics, and the third is the one
that matters on this platform:

* **Open only the project you are working on.** Not your whole home directory. An
  agent given a large tree will explore it.
* **Do not run an agent from a privileged shell.** If your session is `sudo`'d,
  the commands it runs are root's.
* **If your shell has CIRRUS credentials, the agent has CIRRUS credentials.**
  Depending on your `kubectl` context and `helm` configuration, an agent that
  decides to be helpful can run commands against a **production deployment.**
  Check `kubectl config current-context` before you start, and prefer letting
  Argo CD apply changes from git — which is one more argument for
  [page 5](05-argocd.md).

Use plan mode before act mode, and read what it intends to do.

Docs: <https://ncar-hpc-docs.readthedocs.io/en/latest/compute-systems/cirrus/guides/14-llm/llm/>

---

## Also on the platform

Two more things worth knowing exist, in case they save you building one:

* **CloudNativePG** — a Kubernetes operator that runs a highly-available
  PostgreSQL cluster with automated backups and failover. If your application
  needs a database, ask for this rather than running a `postgres` container with a
  PVC bolted on. The
  [`postgres-helm`](https://github.com/NCAR/cirrus-examples/tree/main/helm/postgres-helm)
  example wires it up with TLS and OpenBao-supplied credentials.
* **Dask outside Jupyter** — a scheduler and workers as ordinary Deployments,
  which is how a dashboard gets a persistent cluster to compute against rather
  than one tied to a notebook session. See
  [`dask-helm`](https://github.com/NCAR/cirrus-examples/tree/main/helm/dask-helm).

---

## Check yourself

1. You want a GPU and xarray for an afternoon's exploration. What is the
   fastest route, and what do you have to request?
2. Why does `dask-jobqueue` not work on CIRRUS, and what replaces it?
3. Your Fission route shows `READY False` and nothing else is wrong. What is the
   most likely cause?
4. You deploy new function code and the old code keeps serving. Why?
5. Your MPIJob fails with `Permission denied (publickey)`. Which pod's
   configuration is wrong?
6. You have a 500-node coupled model run. Is CIRRUS the right platform? Why not?
7. An LLM agent is running in your terminal and your kubeconfig points at
   production. What is the risk?

---

← [9. Observability](09-observability.md) · [Start here](../README.md) · [Troubleshooting](99-troubleshooting.md)
