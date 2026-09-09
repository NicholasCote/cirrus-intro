# 1. Orientation: what CIRRUS is

← [Start here](../README.md) · next: [Containers](02-containers.md)

Before any of the tooling, the shape of the thing. This page is what CIRRUS is,
where it runs, when it is the right answer, how you get on it, and what comes
with access. Nothing here is hard, and skipping it is the reason people spend a
week deploying something to the wrong system.

---

## What CIRRUS is

**CIRRUS is NCAR's Kubernetes platform** — *Cloud Infrastructure for Remote
Research, Universities, and Scientists* — run by CISL for workloads that fit
containers better than they fit a batch queue.

The point is not Kubernetes for its own sake. It is that a certain kind of
research output is a *service* rather than a job: a dashboard over model output,
an API in front of a dataset, a documentation site, a data-download endpoint, a
JupyterHub for a project team. Those things have to be up at 3 a.m. on a Sunday,
they have to come back on their own when a node reboots, and they need a URL and
a certificate. A scheduler is the wrong tool for all of that; that is the gap
CIRRUS fills.

What people actually run on it today is public, and worth two minutes of
browsing before you design anything: <https://cirrus.k8s.ucar.edu/apps>.

Because it is standard Kubernetes and standard Helm, what you build here also
runs on any other Kubernetes — a cloud provider, a colleague's cluster, a laptop
with `kind`. That portability is deliberate and it is the strongest argument for
learning the platform rather than a bespoke deployment process.

---

## Kubernetes, at two sites

CIRRUS is not one cluster. It is a **cluster at each of NCAR's two machine
rooms**, which is what makes "the site is down" survivable:

| cluster | site | Argo CD |
| --- | --- | --- |
| **`mlc1`** | Mesa Lab (ML), Boulder | <https://mlc1-argo.k8s.ucar.edu/> |
| **`nwc1`** | NWSC, Cheyenne | <https://nwc1-argo.k8s.ucar.edu/> |

Roughly 18 nodes between them — AMD EPYC CPU nodes plus NVIDIA GPU nodes (A10 at
ML, A2 at NWSC), on the order of 800 CPU cores, 9 TB of memory and 240 TB of
NVMe, on a 25 Gb interconnect. Object storage is replicated *between* the two
sites, so an S3 bucket survives losing one of them
([page 7](07-storage.md)).

Your session is on `mlc1`. Ask, rather than assume:

```bash
kubectl config current-context
kubectl version
```

The control plane is on a recent 1.3x minor and is upgraded roughly quarterly.
The `kubectl` in this image tracks that minor and never leads it, which is why
`cirrus-versions` pins it rather than fetching `stable`.

Two practical consequences of there being two clusters:

* **A deployment lives on one of them.** Running in both is a choice you make
  explicitly — two Argo CD Applications, one hostname in front — not something
  that happens for free.
* **Which one you get is a conversation.** If your application needs to be near
  data that only exists at one site, say so when you ask for it.

---

## When CIRRUS, and when Casper or Derecho

This is the single most useful thing on the page. CIRRUS is a *complement* to
the HPC systems, not a replacement, and the dividing line is sharp: **HPC runs
jobs that finish; CIRRUS runs services that do not.**

| you want to | use |
| --- | --- |
| serve a dashboard, API, website or data portal | **CIRRUS** |
| run something that must stay up, restart itself, survive a node failing | **CIRRUS** |
| deploy from git, continuously, with review | **CIRRUS** |
| host a JupyterHub or a notebook service for a team | **CIRRUS** |
| run CI that needs more than GitHub's free runners, or a GPU | **CIRRUS** ([page 8](08-github-actions.md)) |
| run a coupled model, or MPI across many nodes at scale | **Derecho** |
| run a big single-node analysis, or hold a GPU for hours | **Casper** |
| push a queue of independent batch jobs through | **Casper / Derecho**, via PBS |

The overlap is real but small. There *is* an MPI operator on CIRRUS
([page 10](10-workloads.md)) — it exists for multi-node work that belongs next to
a service or a CI pipeline, not to compete with Derecho's interconnect. If your
question is "how many nodes for how many hours", you want the scheduler.

The combination is the common case, and it is worth designing for on purpose:
**run the model on Derecho, serve the results from CIRRUS.** Both can reach the
same GLADE data, so the handoff is a path, not a copy.

---

## Getting access

There is no self-service signup, and that is by design — every namespace on the
cluster has a person attached to it.

**Everything starts with a ticket.** The CIRRUS team works from a Jira Kanban
board, and a ticket is how requests get prioritised, tracked and answered.

* New service, application, or access → the **New Service Request** form
* Something broken → the **Report Issue** form
* Both are linked from <https://cirrus.k8s.ucar.edu/> under *Report Issue* and
  *Getting Started*, and there is a shorter application form at
  <https://cirrus.k8s.ucar.edu/request-app>
* Or email <cirrus-admin@ucar.edu>

Fill in **Reporter with your own name** — it is not filled automatically, and a
ticket with no reporter is a ticket nobody can follow up with. Leave *Assignee*
on `Automatic` and *Epic Link* on `User Requests`.

Some things you get without asking, because they follow your UCAR CIT account:

| already yours | not yet yours |
| --- | --- |
| JupyterHub (<https://jupyter.k8s.ucar.edu/>) | a namespace of your own |
| Harbor sign-in, and pulls from public projects | a Harbor *project* you can push to |
| OpenBao, under your own email path | a `SecretStore` wired into your namespace |
| the LLM service (<https://llm.k8s.ucar.edu/>) | `kubectl` access to the API server |
| S3, on first connection | an application hosted by Argo CD |
| this workshop session | a GitHub Actions runner scale set |

The right-hand column is one ticket each, and they are short conversations. What
to include when you ask for an application to be hosted is on
[page 5](05-argocd.md#onboarding-an-application-on-cirrus).

### Who you are, to the cluster

Authentication is **OIDC against NCAR's Microsoft Entra ID** — not a certificate,
not a service account token. `kubelogin` is the credential plugin that obtains
the token, and because there is no browser in this container it uses the
device-code flow: the URL and code you pasted on the start page.

```bash
kubectl auth whoami
```

That prints the identity the API server actually attributed the call to, which
is the only answer that matters when something says `Forbidden`. If it shows a
`system:serviceaccount:...` name, your kubeconfig is not being used at all — see
[Troubleshooting](99-troubleshooting.md).

Two consequences of OIDC worth internalising now, because both surprise people
later:

* **Your permissions are your own, and nothing inherits them.** A pod runs as a
  ServiceAccount, and by default that ServiceAccount can do almost nothing. This
  is correct. It is also why a workload that needs to talk to the API needs an
  explicit Role and RoleBinding written for it.
* **Tokens expire, in about an hour.** There is no keyring in this container, so
  there is no refresh token to renew from silently; you sign in again. See
  [Troubleshooting](99-troubleshooting.md#i-am-asked-to-sign-in-again).

---

## Your space on the cluster: namespaces

A **namespace** is Kubernetes' unit of ownership: a scope for names, a boundary
for policy, and the thing a quota is attached to. On CIRRUS it is also the unit
of *tenancy* — multi-tenancy is enforced with **Capsule**, which groups
namespaces into tenants and constrains what a tenant owner may do inside them.

Three shapes, and knowing which one you are asking for saves a round trip:

**An individual namespace.** Yours, named after you. This session has one:

```bash
echo "$CIRRUS_NAMESPACE"
kubectl get all
```

It is where you learn, prototype, and run `kubectl apply` against something real
without a review cycle. It is not where a service that other people depend on
should live.

**A team or project namespace.** Carved out and dedicated to one application or
one group, with several people as owners and its own quota. This is what a hosted
application gets, and it is what you should ask for once something has users.
Because ownership is per-namespace, a colleague added to it can debug your
deployment without being given access to anything else.

**A shared platform namespace.** Where the platform's own components live —
`argocd`, the ingress controllers, the monitoring stack. You will read about
these and you will not be in them.

The fence around your namespace is real, and it is better measured than guessed
at. [Page 3](03-kubernetes.md#your-namespace-and-what-you-may-do-in-it) does that
with `kubectl auth can-i`, quotas and limit ranges, in the context of the objects
they apply to.

---

## What else comes with access

CIRRUS is not only "somewhere to run a container". Six platform services come
with it, each covered by its own page later:

| service | what it is for | where |
| --- | --- | --- |
| **Harbor** | the container registry your images live in, with CVE scanning | <https://hub.k8s.ucar.edu/> · [page 2](02-containers.md#container-registries) |
| **Argo CD** | GitOps: the cluster continuously pulls its desired state from your repository | ML / NWSC, above · [page 5](05-argocd.md) |
| **OpenBao** | encrypted secret storage, injected into pods without ever touching git | <https://bao.k8s.ucar.edu/> · [page 6](06-secrets.md) |
| **Grafana** | metrics (Prometheus), logs (Loki), dashboards and alerts | <https://grafana.k8s.ucar.edu/> · [page 9](09-observability.md) |
| **GitHub Actions runners** | CI on cluster hardware, GPUs included | [page 8](08-github-actions.md) |
| **JupyterHub** | notebooks with GPUs, GLADE and Dask, no install | <https://jupyter.k8s.ucar.edu/> · [page 10](10-workloads.md) |

And three more things the platform does on your behalf, which is most of why
hosting an application here is worth the ticket:

* **DNS.** ExternalDNS creates the record for your hostname under
  `*.k8s.ucar.edu`. You pick the name; you do not file a DNS request.
* **TLS.** cert-manager issues and renews the certificate. Nobody has a calendar
  reminder to replace it.
* **Ingress.** Two paths — one for the public internet and one restricted to the
  UCAR network — and choosing between them is one value in your chart, not an
  infrastructure project. ([Page 3](03-kubernetes.md#ingress) has the object.)

CIRRUS is free to UCAR employees and collaborators. There is no cloud bill and
no credit card, which is a real advantage and also the reason quotas exist: the
constraint is a shared cluster rather than a budget.

### What the platform promises, and what stays yours

Worth reading once, because it sets expectations correctly. The full service
level agreement is at <https://cirrus.k8s.ucar.edu/sla>; the short version:

* **The team runs the platform.** Cluster availability, upgrades, the monitoring
  stack, backups of Argo CD projects and Harbor images.
* **You run your application.** Its code, its resource requests, its ability to
  survive a pod being moved. "Application owners are responsible for their
  applications" is the actual wording, and the design consequence is that
  **anything that cannot tolerate being restarted does not belong here** — write
  workloads that can be killed at any moment, because they will be.
* **Support is business hours**, Monday to Friday, 08:00–17:00 MST, with no
  after-hours on-call. Critical means a 2-hour response in that window.
* **Backups are the repository.** Applications are recovered by redeploying from
  git, not by restoring a machine. That is another argument for
  [page 5](05-argocd.md), and it means a PersistentVolume holding something
  irreplaceable needs an explicit conversation — replication across sites is
  available on request, not by default.

---

## The road from here

The remaining pages are in the order the work actually happens:

1. **[Containers](02-containers.md)** — package the thing, and put the image in a
   registry.
2. **[Kubernetes](03-kubernetes.md)** — describe how it should run, and apply it
   by hand once.
3. **[Helm](04-helm.md)** — turn those manifests into a chart you can configure
   and reuse.
4. **[Argo CD](05-argocd.md)** — hand the chart to git and stop applying anything
   by hand.
5. **[Secrets](06-secrets.md)**, **[storage](07-storage.md)**,
   **[CI](08-github-actions.md)** and **[observability](09-observability.md)** —
   the four things every real application needs shortly after it works.
6. **[Specialized workloads](10-workloads.md)** — Jupyter, functions, MPI, LLMs,
   for when a Deployment is not the right shape.

Pages 2 through 4 are true of any Kubernetes cluster. From page 5 on, it is
increasingly about *this* one.

---

## Check yourself

1. You have a model that runs for six hours on 40 nodes, and a dashboard that
   shows its output. Which goes where, and why?
2. CIRRUS has clusters at two sites. What does that get you for free, and what
   does it not?
3. Name two things you already have access to today, and two that need a ticket.
4. Your application must not lose data if a pod is killed without warning. What
   does the SLA imply you have to do about that?
5. Which command tells you the identity the API server thinks you are?

---

← [Start here](../README.md) · next: [2. Containers](02-containers.md)
