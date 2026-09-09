# 5. GitOps with Argo CD

← [Helm](04-helm.md) · next: [Secret Manager](06-secrets.md)

Pages 3 and 4 both ended in the same place: you have a declared desired state,
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
        (the same control loop as page 3, one level up)
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

Note where the rendering happens: **in the cluster, by repo-server** — and with
`helm template`, not `helm install`, so there is no Helm release at all. The
consequences of that are set out in full on
[page 4](04-helm.md#how-argo-cd-renders-your-chart-template-not-install); the
short version is that Argo CD's own state, not Helm's, is the answer to "what is
deployed".

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

Everything past that needs a server. On CIRRUS there is one Argo CD per cluster:

| cluster | Argo CD |
| --- | --- |
| `mlc1` (Mesa Lab) | <https://mlc1-argo.k8s.ucar.edu/> |
| `nwc1` (NWSC) | <https://nwc1-argo.k8s.ucar.edu/> |

Access is **read-only and granted per project** — ask for it in your onboarding
ticket, with the project name and the UCAR email addresses that need it. That is
enough to watch sync status, resource health, events and logs, and not enough to
change configuration, which is the right split.

```bash notebook-skip
argocd login mlc1-argo.k8s.ucar.edu --sso    # or nwc1-argo.k8s.ucar.edu
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
[page 3](03-kubernetes.md) visible, and clicking a pod gets you its logs and events without a
command. Sync, diff, history and rollback are all there.

The UI is published at the addresses above, so from a browser on the UCAR network
you simply open it. For a self-hosted Argo CD with no published address, the
fallback is the same trick you used for your own Service on
[page 3](03-kubernetes.md):

```bash notebook-skip
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

then open `https://localhost:8080` — from a session terminal that address is the
*pod's* localhost, so in this environment prefer the CLI, or ask where the UI is
published.

Note that `argocd app sync` and `argocd app rollback` are both, strictly,
escape hatches — and with read-only access on CIRRUS you will not have them
anyway. In a healthy GitOps setup you change git and let the controller act.
Reaching for the CLI to change the cluster is how the repository stops being the
truth.

---

## Onboarding an application on CIRRUS

Everything above is Argo CD in general. This is the part that is specific to
CIRRUS, and it is short: **you do not create the Application object; the CIRRUS
team does.** Argo CD runs in a namespace you cannot write to, which is the
correct arrangement — an Application can name any destination in the cluster, so
being able to create one is close to being an administrator.

What you do is: get the chart into a repository, then ask.

### What to have ready

```
your-repo/
├── app/                      your application code
├── Dockerfile
├── helm/                     ← the path you will name in the ticket
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── deployment.yaml
│       ├── service.yaml
│       └── ingress.yaml
└── .github/workflows/
    └── build.yaml            builds the image, pins the tag in values.yaml
```

Four things in the ticket, and getting them right first time saves a round trip:

| what they need | notes |
| --- | --- |
| the **repository URL** | Argo CD must be able to read it. A private repo needs credentials arranged. |
| the **branch** | `main` for a single environment; see *test and production* below |
| the **Helm chart folder** | the directory containing `Chart.yaml` — `helm/`, `k8s/`, whatever you called it |
| the **URL you want** | must be unique and end in `.k8s.ucar.edu`, and say whether it should be reachable **internally (UCAR network / VPN) or externally (public internet)** |

Mention at the same time, if they apply, so they are set up in one pass rather
than three:

* **secrets** — the names, and the OpenBao path and property for each
  ([page 6](06-secrets.md))
* **storage** — a PVC, its size, and whether it needs `ReadWriteMany`
  ([page 7](07-storage.md))
* **read-only Argo CD access** for you and your colleagues, with UCAR email
  addresses — so you can watch syncs without being able to change anything
* **alerting** — which application, and which addresses (below)

The forms are at <https://cirrus.k8s.ucar.edu/request-app>, or the New Service
Request in Jira. The team reviews the chart, creates the Application, and wires
up monitoring, logging and alerting. Expect a day or two.

### Test and production from one repository

The recommended shape, and it is worth setting up before you need it: a second
branch with its own chart folder and its own FQDN.

| | production | test |
| --- | --- | --- |
| branch | `main` | `test` |
| chart folder | `helm/app-helm` | `helm/app-helm-test` |
| FQDN | `app.k8s.ucar.edu` | `test-app.k8s.ucar.edu` |

Two Applications, tracking different branches. Changes land in `test`, get looked
at through a real URL, and then merge. It costs one extra ticket at the start and
it is the difference between "deploying is routine" and "deploying is an event".

---

## What Argo CD owns, and what you can still touch

Once your application is onboarded, the rule is short and worth internalising
because breaking it produces confusing rather than dramatic failures: **anything
Argo CD created belongs to Argo CD.**

With `selfHeal: true`, a change you make by hand to a managed object survives
until the next reconcile — up to about three minutes — and is then reverted. With
`prune: true`, deleting a file from git deletes the object. Neither is an error
condition; both are the loop doing its job.

| you want to | how |
| --- | --- |
| change replicas, image tag, env var, resources | edit the values file, commit, push |
| roll back | `git revert`, push |
| add an Ingress, a PVC, an ExternalSecret | add the template, commit, push |
| **read** anything at all | `kubectl get/describe/logs`, `stern`, freely |
| restart a Deployment | `kubectl rollout restart` — safe; it changes an annotation, not the spec |
| delete a wedged pod | safe; the ReplicaSet makes another and git is unchanged |
| port-forward to debug | safe; changes nothing |
| scale for ten minutes to test something | it will be reverted. Change git, or accept that. |
| `kubectl edit` a managed object | do not. It will be reverted, and you will spend the interval confused. |
| `helm upgrade` a managed release | do not — see [page 4](04-helm.md#uninstall-before-you-hand-it-over) |

Note the pattern in the safe list: **reads are always fine, and so is anything
that acts on a pod rather than on a spec.** Killing a pod, restarting a rollout,
exec'ing in to look around — none of those contradict git. Editing the desired
state outside git is the only thing that does.

There is one category worth calling out because the fight is invisible: a field
that something else in the cluster legitimately owns. A
HorizontalPodAutoscaler changes `replicas`; if `replicas` is also in git with
`selfHeal: true`, the two overwrite each other forever. Remove the field from git
and let the autoscaler own it. The same applies to anything a mutating webhook
injects.

---

## Alerts and notifications

An application nobody is watching is an application whose outage you hear about
from a user. Two separate mechanisms, and it is worth knowing which one you are
asking for.

**Argo CD notifications** tell you about *delivery*: a sync failed, an
application went `Degraded`. Ask for these when you onboard — the team wires up
alerts on sync failure and unhealthy state to the addresses you name. This is the
one to have on from day one, because it is what tells you a push did not land.

**Prometheus alerts** tell you about *behaviour*: the pod is down, memory is at
90% of its limit, your error rate has tripled. These you write yourself, as two
manifests in your own chart, and they are covered on
[page 9](09-observability.md#alerting-on-your-own-application). The short version:
a `PrometheusRule` says what condition matters, an `AlertmanagerConfig` says where
the notification goes.

One piece of hard-won advice from the CIRRUS documentation, worth repeating here
because it will save you a day: **Alertmanager is not exposed to users.** You
cannot open its UI or read its logs to find out why a notification did not
arrive. So when you set alerting up, start with a rule that always fires —
`expr: vector(1)` — confirm the mail actually reaches you, and only then write the
real conditions and delete the test rule.

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
secrets in git are simply out. The three general answers are **Sealed Secrets**
(encrypt to a key only the cluster holds, commit the ciphertext), the **External
Secrets Operator** (commit a *reference*, the operator fetches from a secret
store), and **SOPS** with an Argo CD plugin. All three share a shape: what is in
git is useless without something the cluster has. **CIRRUS uses the second one**,
backed by OpenBao — [page 6](06-secrets.md).

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
6. Four things go in an onboarding ticket. Name them.
7. Which of these are safe on an Argo-managed application, and why:
   `kubectl delete pod`, `kubectl rollout restart`, `kubectl scale`,
   `kubectl logs`?
8. Your notification never arrived and you cannot read Alertmanager's logs. What
   should you have done first?

---

## Where to go deeper

This page is the concepts and the loop. Two full hands-on workshops build the
whole pipeline around a small Flask application — CI building an image, pushing
it to Harbor, and Argo CD deploying it — and both are listed under
[Going further](../README.md#going-further) on the start page.

---

← [4. Helm](04-helm.md) · next: [6. Secret Manager](06-secrets.md)
