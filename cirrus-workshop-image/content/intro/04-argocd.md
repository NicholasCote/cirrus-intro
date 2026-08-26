# 4. Introduction to Argo CD

← [Helm](03-helm.md) · next: [CIRRUS itself](05-cirrus.md)

Pages 2 and 3 both ended in the same place: you have a declared desired state,
and nothing is making sure the cluster still matches it. You ran `kubectl apply`
once. You ran `helm upgrade` once. In between, anyone with access — including
you at 3 a.m. — can change the cluster, and nothing will notice or object.

Argo CD closes that loop. **Git becomes the desired state, and an agent in the
cluster continuously reconciles reality against it.**

---

## The idea, and why it is not just "CI that runs kubectl"

The usual pipeline *pushes*: CI builds, then CI authenticates to the cluster and
applies. That means your CI system holds cluster credentials, the pipeline only
converges when it happens to run, and a change made by hand afterwards survives
indefinitely.

GitOps *pulls*:

```
   git repo  ◀────── you open a PR, someone reviews, it merges
      │
      │  (the cluster reads; git never reaches out)
      ▼
  Argo CD in the cluster ──▶ observe → compare → act ──▶ the cluster
        (the same control loop as page 2, one level up)
```

Four properties fall out of that inversion, and they are the actual reason
people adopt it:

* **The repository is the audit log.** "Why is production like this" is answered
  by `git log`, with the review attached.
* **No outside system holds cluster credentials.** The agent is inside, using its
  own ServiceAccount. Nothing needs an inbound path to the API server.
* **Drift is visible and, optionally, self-correcting.** A hand-edited resource
  shows as `OutOfSync` and can be reverted automatically.
* **Rollback is `git revert`.** The same review path forward and back.

Argo CD is one implementation; Flux is the other common one. The model is the
same and the concepts transfer.

---

## What is running when Argo CD is installed

Four components, worth knowing by name because their logs are where answers
live:

| component | job |
| --- | --- |
| **application-controller** | the reconcile loop: compare desired vs live, sync, report health |
| **repo-server** | clones git, renders manifests (runs `helm template`, `kustomize build`) |
| **api-server** | the API behind the web UI and the `argocd` CLI |
| **redis** | a cache for rendered manifests and cluster state |

Note where the rendering happens: **in the cluster, by repo-server**. Argo CD
does not run `helm install`, so there is no Helm release and `helm list` shows
nothing. It runs `helm template` and applies the result, which is why Argo CD's
own state is the answer to "what is deployed", not Helm's.

---

## The Application

One custom resource ties a git path to a cluster destination. This is the whole
interface:

```bash
mkdir -p ~/cirrus-workshop/gitops && cd ~/cirrus-workshop/gitops

cat > application.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: hello
  namespace: argocd            # where Argo CD runs, NOT where the app lands
spec:
  project: default

  source:
    repoURL: https://github.com/YOUR-ORG/YOUR-REPO.git
    targetRevision: main       # a branch, tag, or commit SHA
    path: helm/hello           # the chart directory inside the repo
    helm:
      valueFiles:
        - values.yaml
        - prod-values.yaml

  destination:
    server: https://kubernetes.default.svc
    namespace: NAMESPACE       # where the objects are created

  syncPolicy:
    automated:
      prune: true              # delete objects removed from git
      selfHeal: true           # revert changes made outside git
    syncOptions:
      - CreateNamespace=false
EOF
sed -i "s|NAMESPACE|${CIRRUS_NAMESPACE}|" application.yaml
```

Read it field by field, because each one is a decision:

* **`source`** — *where the truth is*. `repoURL` + `path` + `targetRevision`.
  Pinning `targetRevision` to a tag or SHA rather than `main` is the difference
  between "deploys when someone merges" and "deploys when someone promotes".
* **`destination`** — *where it goes*. Argo CD can manage many clusters;
  `https://kubernetes.default.svc` means the one it is running in.
* **`syncPolicy.automated`** — absent, syncing is a button someone presses.
  Present, it happens on its own.
* **`prune`** — without it, deleting a file from git leaves the object running
  forever. With it, deleting a file deletes the object. Both are surprising the
  first time; `prune: true` is surprising less often.
* **`selfHeal`** — without it, drift is reported and left alone. With it, a
  manual `kubectl edit` is reverted within minutes.

The two fields people get wrong: `metadata.namespace` is where the *Application
object* lives (Argo CD's namespace, usually `argocd`), while
`spec.destination.namespace` is where the *workload* lands. They are almost
never the same.

---

## Reconciliation, in three lines and no Argo CD

You do not need a server running to understand the loop — you can *be* the loop.
This is genuinely what the application-controller does, minus the reporting, the
caching and the health assessment.

Compare desired against live:

```bash
cd ~/cirrus-workshop/helm
helm template gitops ./hello > /tmp/desired.yaml
kubectl diff -f /tmp/desired.yaml || true      # this is "OutOfSync"
```

Sync:

```bash
kubectl apply -f /tmp/desired.yaml             # this is "Sync"
kubectl get deploy,svc -l app.kubernetes.io/instance=gitops
```

Now be `selfHeal: true`. In one terminal, run the loop:

```bash notebook-skip
while true; do
  helm template gitops ~/cirrus-workshop/helm/hello | kubectl apply -f - >/dev/null
  sleep 10
done
```

In a **second terminal**, drift the cluster by hand and watch:

```bash notebook-skip
kubectl scale deployment gitops --replicas=7
kubectl get deploy gitops -w        # back to 2 within ten seconds
```

Stop the loop with `Ctrl-C` in the first terminal.

Ten seconds is impatient on purpose. Argo CD's own default reconcile interval is
**three minutes** (`timeout.reconciliation` in the `argocd-cm` ConfigMap), so in
a real setup a change lands within about that long rather than instantly — and a
repository webhook is what makes it feel immediate. If you push a commit and
nothing happens, wait three minutes before assuming it is broken, or press *Sync*
in the UI.

That is the entire mechanism. Everything Argo CD adds — the UI, health checks,
sync waves, multi-cluster, RBAC, notifications — is scaffolding around this
loop. Understanding the loop is what stops Argo CD from feeling like magic when
it does something you did not expect.

Clean up:

```bash
kubectl delete -f /tmp/desired.yaml
```

---

## Sync status, health status, and the difference

Argo CD reports two independent things and confusing them wastes a lot of time.

* **Sync status** — does the cluster match git? `Synced` / `OutOfSync`. It is a
  comparison of manifests and says nothing about whether the app works.
* **Health status** — is the workload actually healthy? `Healthy` / `Progressing`
  / `Degraded` / `Missing`. Argo CD knows how to assess built-in kinds: a
  Deployment is `Healthy` when its updated replicas are available, a Service with
  no endpoints is not.

`Synced` + `Degraded` is the common and instructive combination: git got exactly
what it asked for, and what it asked for is broken. That is a code or config
problem, not a delivery problem.

---

## Using the CLI

The `argocd` CLI is installed:

```bash
argocd version --client
```

Everything past that needs a server, and **the Argo CD endpoint on CIRRUS is
site-specific** — this image does not presume one. Get the server address and
your access from the platform team or the NCAR HPC documentation, then:

```bash notebook-skip
argocd login <argocd-server>            # SSO, or --sso, depending on the install
argocd app list
argocd app get hello
argocd app diff hello                   # what git wants vs what is running
argocd app sync hello
argocd app history hello
argocd app rollback hello <revision>
argocd app logs hello --follow
```

The habit worth forming: `argocd app diff` before `argocd app sync`, for the
same reason `kubectl diff` comes before `kubectl apply` and `helm template`
comes before `helm upgrade`. Three tools, one discipline — *look at the change
before you make it.*

### The web UI

Most people meet Argo CD through its UI, and it is genuinely the better first
tool: the resource tree makes the Deployment → ReplicaSet → Pod ownership from
page 2 visible, and clicking a pod gets you its logs and events without a
command. Sync, diff, history and rollback are all there.

If it is not published at a URL, reach it the same way you reached your own
Service on page 2:

```bash notebook-skip
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

then open `https://localhost:8080` — from a session terminal that address is the
*pod's* localhost, so in this environment prefer the CLI, or ask where the UI is
published.

Note that `argocd app sync` and `argocd app rollback` are both, strictly,
escape hatches. In a healthy GitOps setup you change git and let the controller
act. Reaching for the CLI to change the cluster is how the repository stops
being the truth.

---

## Patterns you will meet

**App of apps.** An Application whose source is a directory of *other*
Application manifests. Bootstrapping a whole cluster becomes one `kubectl apply`
of a single root Application, and adding a service to the platform becomes a PR
adding one file.

**ApplicationSet.** A generator that produces Applications from a list, a
directory glob, a set of clusters, or pull requests. This is how "the same app in
dev, staging and prod" is expressed without three near-identical copies.

**Sync waves.** `argocd.argoproj.io/sync-wave: "-1"` as an annotation orders
resources within a sync — CRDs before the things that use them, a migration Job
before the Deployment. Lower numbers first.

**Hooks.** `argocd.argoproj.io/hook: PreSync` on a Job runs it before the sync
proper — the standard home for database migrations.

**Secrets.** Git is public-ish and Kubernetes Secrets are base64, so plaintext
secrets in git are simply out. The three real answers: **Sealed Secrets**
(encrypt to a key only the cluster holds, commit the ciphertext), **External
Secrets Operator** (commit a *reference*, the operator fetches from Vault or a
cloud secret store), **SOPS** with the Argo CD plugin. All three share a shape:
what is in git is useless without something the cluster has.

---

## When GitOps is the wrong shape

Worth saying, because it is oversold:

* **Anything genuinely imperative.** A one-off data migration, a debugging
  session, a batch job you run once with different arguments — those are `kubectl`
  and Argo Workflows territory, not a reconciliation loop.
* **Fast local iteration.** A commit-push-wait cycle per change is miserable
  while you are still figuring out what the manifest should say. Use
  `helm template` and `kubectl apply` until it works, *then* commit it.
* **Things the cluster legitimately owns.** A HorizontalPodAutoscaler changes
  `replicas`; if `replicas` is also in git with `selfHeal: true`, the two fight
  forever. Remove the field from git and let the autoscaler own it.

---

## Check yourself

1. Argo CD needs no inbound access to the cluster and holds no credentials in
   CI. Why does the pull model give you both of those for free?
2. `helm list` shows nothing, but the app is running and Argo CD says `Synced`.
   Why is that expected?
3. An Application is `Synced` and `Degraded`. Where is the problem — the
   repository, the controller, or the application?
4. What does `prune: false` cost you when someone deletes a manifest from git?
5. You put a Deployment's `replicas` in git with `selfHeal: true`, and also
   installed an HPA for it. What happens, and what is the fix?

---

## Where to go deeper

This page is the concepts and the loop. Two full hands-on workshops build the
whole pipeline around a small Flask application — CI building an image, pushing
it to Harbor, and Argo CD deploying it — and both are listed under
[Going further](../README.md#going-further) on the start page.

---

← [3. Helm](03-helm.md) · next: [5. CIRRUS itself](05-cirrus.md)
