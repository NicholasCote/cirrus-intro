# 5. CIRRUS itself

← [Argo CD](04-argocd.md) · [Troubleshooting](99-troubleshooting.md)

Pages 1–4 are true of any Kubernetes cluster. This page is about *this* one:
what CIRRUS is, what your slice of it looks like, and where the edges are.

---

## What CIRRUS is

CIRRUS is NCAR's Kubernetes platform — a set of clusters run by CISL for
services and workloads that fit containers better than they fit a batch
scheduler. It sits alongside Casper and Derecho rather than replacing them.

The rough division of labour:

| you want to | use |
| --- | --- |
| run a long-lived service — an API, a dashboard, a data portal | CIRRUS |
| run something that should restart itself and survive a node failing | CIRRUS |
| deploy from git, continuously, with review | CIRRUS |
| run an MPI job across many nodes | Derecho |
| run a big single-node analysis, or need a GPU for hours | Casper |
| run a batch queue of independent jobs | Casper / Derecho, or PBS |

The clusters you will hear named are **`mlc1`** and **`nwc1`**. Your session is
pointed at `mlc1`:

```bash
kubectl config current-context
kubectl version
```

The control plane is on a recent 1.3x minor and is upgraded roughly quarterly.
The `kubectl` in this image tracks that minor and never leads it, which is why
`cirrus-versions` pins it rather than fetching `stable`.

---

## Who you are

Authentication is **OIDC against NCAR's Microsoft Entra ID**, not a certificate
and not a service account token. `kubelogin` is the credential plugin that
obtains the token, and because there is no browser in this container it uses the
device-code flow — the URL and code you pasted on the start page.

```bash
kubectl auth whoami
```

That prints the identity the API server actually attributed the call to, which
is the only answer that matters when something says `Forbidden`. If it shows a
`system:serviceaccount:...` name, your kubeconfig is not being used at all —
see [Troubleshooting](99-troubleshooting.md).

Two consequences of OIDC worth internalising:

* **Your permissions are your own.** Nothing you deploy inherits them. A pod runs
  as a ServiceAccount, and by default that ServiceAccount can do almost nothing.
  This is correct, and it is why a pod that needs to talk to the API needs an
  explicit Role and RoleBinding.
* **Tokens expire, in about an hour.** There is no keyring in this container, so
  there is no refresh token to renew from silently; you sign in again. See
  [Troubleshooting](99-troubleshooting.md#i-am-asked-to-sign-in-again) for the
  full explanation and the options.

---

## Your namespace, and the fence around it

```bash
echo "$CIRRUS_NAMESPACE"
kubectl get all
```

Multi-tenancy on CIRRUS is enforced with **Capsule**, which groups namespaces
into tenants and constrains what a tenant owner may do inside them. In practice:
you are an owner of your own namespace and a stranger everywhere else.

Find your actual edges rather than guessing at them:

```bash
kubectl auth can-i --list                  # everything you may do here
kubectl auth can-i create deployments      # yes
kubectl auth can-i get pods -n kube-system # no
kubectl auth can-i create namespaces       # almost certainly no
kubectl auth can-i list nodes              # probably no
```

`kubectl auth can-i --list` is the single most useful command on this page. It
asks the API server what your token is allowed to do, so it is authoritative,
current, and specific to you.

And the limits on what you may consume:

```bash
kubectl get resourcequota
kubectl describe resourcequota
kubectl get limitrange
kubectl describe limitrange
```

* A **ResourceQuota** caps the namespace in total — CPU, memory, object counts.
  Exceed it and the *creation* is rejected with a message naming the quota, which
  is a much friendlier failure than a pod that will not schedule.
* A **LimitRange** constrains individual objects, and can supply defaults. If one
  requires `requests` and `limits` on every container, a manifest without them is
  rejected outright — which is why every manifest on pages 2 and 3 has them.

---

## Storage

Three quite different things, and picking the wrong one is a common early
mistake.

**Your GLADE home** is mounted into this session at `~`. It is NFS, it is shared
with Casper and Derecho, and it is *not* generally available to workloads you
deploy — this OnDemand session has it because the session's pod spec asks for it.
Do not assume a Deployment you write can see it.

**The pod's own filesystem** is scratch. `/tmp/cirrus` and anything else outside
a mount vanishes when the pod does — and pods are replaced routinely. Never keep
anything there you would miss.

**PersistentVolumeClaims** are how a workload asks for storage that outlives its
pods:

```bash
kubectl get storageclass 2>/dev/null || echo "not permitted to list cluster-scoped StorageClasses"
kubectl get pvc
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 5Gi
  # storageClassName: <from the list above; omit to use the default>
```

`ReadWriteOnce` means one node at a time — which is what most storage classes
support, and it means a Deployment with more than one replica sharing one PVC
will not work the way you expect. If you need many readers, you need a class
that supports `ReadWriteMany`, and that is a question for the platform team.

Storage counts against your quota. Check `kubectl describe resourcequota` before
asking for a large volume.

---

## Images: use Harbor

NCAR runs a Harbor registry at **`hub.k8s.ucar.edu`**. Prefer it for anything you
deploy on CIRRUS:

* it is inside NCAR, so pulls are fast and do not depend on the cluster having a
  route to the public internet;
* it is not subject to Docker Hub's anonymous pull rate limits, which produce a
  `TooManyRequests` on `ImagePullBackOff` at exactly the wrong moment;
* it scans what you push and reports CVEs, which is how you find out that the
  base image you pinned six months ago now has a Critical.

The image running this session lives there:

```bash
kubectl get pod "$(hostname)" -o jsonpath='{.spec.containers[0].image}{"\n"}'
```

Push to it from CI with a **robot account** — *Project → Robot Accounts* in the
Harbor UI — rather than your own credentials: scoped to one project, revocable on
its own, and unaffected by your password changing. See
[page 1](01-containers.md#pushing-to-harbor-from-ci) for the workflow.

If you need a project in Harbor, or a pull secret for a private one, that is a
request to the platform team.

---

## Getting something onto CIRRUS, end to end

Putting the five pages together, the shape of real work here is:

1. **Build an image** somewhere with a builder — CI for anything shared — and
   push it to Harbor with an explicit version tag. Never `:latest`.
   ([page 1](01-containers.md))
2. **Write the manifests**, with `requests` and `limits`, a readiness probe, and
   configuration in a ConfigMap rather than the image.
   ([page 2](02-kubernetes.md))
3. **Package them as a chart** once there is more than one environment or more
   than one person. ([page 3](03-helm.md))
4. **Put it in git and let Argo CD apply it**, so the repository is the record and
   drift is visible. ([page 4](04-argocd.md))
5. **Ask for what you cannot do yourself** — an external address, a
   `ReadWriteMany` volume, a Harbor project, more quota, the Argo CD endpoint.
   Those are all platform-team conversations, and they are short ones.

---

## Things you cannot do from here, and who to ask

| you want | why not | what to do |
| --- | --- | --- |
| a namespace of your own beyond `ood-<user>` | Capsule tenancy is assigned, not self-serve | ask CISL |
| an externally reachable URL | Ingress/LoadBalancer and DNS are platform-managed | ask CISL |
| more CPU/memory/storage than your quota | it is a shared cluster | ask CISL, with numbers |
| to look at nodes or other namespaces | tenancy boundary | it is not needed for your workload |
| to build container images in this session | needs privileges a workshop pod should not have | build in CI or on a workstation |
| to run privileged or host-networked pods | admission policy | rethink the workload; usually there is a way |

---

## Documentation

* CIRRUS documentation:
  <https://ncar-hpc-docs.readthedocs.io/en/latest/compute-systems/cirrus/>
* `kubectl` on CIRRUS, including the kubeconfig you are using:
  <https://ncar-hpc-docs.readthedocs.io/en/latest/compute-systems/cirrus/guides/10-kubectl/kubectl/>
* Kubernetes upstream reference: <https://kubernetes.io/docs/>
* Helm: <https://helm.sh/docs/> · Argo CD: <https://argo-cd.readthedocs.io/>

---

## Check yourself

1. Which single command tells you exactly what you are allowed to do in your
   namespace?
2. Your Deployment's pods cannot see your GLADE home. Why is that not a bug?
3. Why is pulling from `hub.k8s.ucar.edu` a better default than `docker.io`?
4. A `kubectl apply` is rejected with a message about a LimitRange. What is
   missing from your manifest?
5. You need a URL other people can open. What is the next step?

---

← [4. Argo CD](04-argocd.md) · [Start here](../README.md) · [Troubleshooting](99-troubleshooting.md)
