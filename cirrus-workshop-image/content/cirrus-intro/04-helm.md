# 4. Introduction to Helm

← [Kubernetes](03-kubernetes.md) · next: [Argo CD](05-argocd.md)

[Page 3](03-kubernetes.md) left you with three YAML files and a problem. They contain the same
strings in several places, they hard-code one environment, and installing or
removing "the application" means remembering which files were part of it.

Helm is the package manager that fixes exactly those three things: **templates**,
**values**, and **releases**.

```bash
mkdir -p ~/cirrus-workshop/helm && cd ~/cirrus-workshop/helm
helm version
```

> Helm 4 exists; this image pins Helm 3, because the CIRRUS documentation and
> the workshop material are written against 3. The `helm` commands below are the
> stable subset either way.

---

## What Helm actually is

Three pieces, and it helps to keep them separate in your head:

1. **A chart** — a directory of Go templates plus a default `values.yaml`. On its
   own it is inert text.
2. **A render** — chart + values → plain Kubernetes manifests. `helm template`
   does exactly this and stops, which makes it the most useful command in Helm.
3. **A release** — a named installation of a render into a namespace. Helm
   remembers each one, which is what makes `upgrade`, `rollback` and `uninstall`
   possible as single operations.

Helm 3 has **no cluster-side component**. There is no Tiller, no operator,
nothing with permissions of its own. It renders locally and then does the same
API calls `kubectl apply` would, as *you*, subject to the same RBAC. If you can
do it with `kubectl`, you can do it with Helm, and not otherwise.

---

## Look at the scaffold, then throw it away

```bash
helm create scaffold
find scaffold -type f | sort
```

That is the full-featured starting point — ingress, autoscaling, service
accounts, a `_helpers.tpl` of naming conventions. It is a lot to read before
anything makes sense, so look at it, note that it exists, and build a small one
by hand instead:

```bash
rm -rf scaffold
mkdir -p hello/templates
```

---

## Chart.yaml — the identity

```bash
cat > hello/Chart.yaml <<'EOF'
apiVersion: v2
name: hello
description: The page-3 application, packaged
type: application
version: 0.1.0
appVersion: "1.0.0"
EOF
```

Two versions, and confusing them causes real trouble:

* **`version`** is the version of *the chart* — the templates. Bump it whenever
  you change anything in the chart. Helm requires it to be semver.
* **`appVersion`** is the version of the *software* the chart deploys. It is a
  free-form string and it is only a label.

---

## values.yaml — the knobs, and their defaults

```bash
cat > hello/values.yaml <<'EOF'
replicaCount: 2

image:
  repository: IMAGE_REPO
  tag: IMAGE_TAG
  pullPolicy: IfNotPresent

service:
  port: 8080

welcomeMessage: "hello from Helm"

resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 256Mi
EOF

# Same trick as page 3: the image your own session runs, split into repo and tag.
IMG=$(kubectl get pod "$(hostname)" -o jsonpath='{.spec.containers[0].image}')
sed -i "s|IMAGE_REPO|${IMG%:*}|; s|IMAGE_TAG|${IMG##*:}|" hello/values.yaml
grep -A3 '^image:' hello/values.yaml
```

`values.yaml` is documentation as much as configuration. Every knob the chart
has should appear here with a sensible default, because this file is the only
thing a user of your chart is guaranteed to read.

---

## templates/ — the manifests, with holes in them

```bash
cat > hello/templates/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
  labels:
    app.kubernetes.io/name: {{ .Chart.Name }}
    app.kubernetes.io/instance: {{ .Release.Name }}
    helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ .Chart.Name }}
      app.kubernetes.io/instance: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {{ .Chart.Name }}
        app.kubernetes.io/instance: {{ .Release.Name }}
    spec:
      containers:
        - name: hello
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          command: ["sh", "-c"]
          args:
            - >-
              mkdir -p /tmp/www &&
              echo "$WELCOME_MESSAGE (from $(hostname))" > /tmp/www/index.html &&
              cd /tmp/www &&
              exec python3 -m http.server {{ .Values.service.port }}
          env:
            - name: WELCOME_MESSAGE
              value: {{ .Values.welcomeMessage | quote }}
          ports:
            - name: http
              containerPort: {{ .Values.service.port }}
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 2
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
EOF

cat > hello/templates/service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
  labels:
    app.kubernetes.io/name: {{ .Chart.Name }}
    app.kubernetes.io/instance: {{ .Release.Name }}
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: {{ .Chart.Name }}
    app.kubernetes.io/instance: {{ .Release.Name }}
  ports:
    - name: http
      port: {{ .Values.service.port }}
      targetPort: http
EOF

cat > hello/templates/NOTES.txt <<'EOF'
{{ .Chart.Name }} {{ .Chart.Version }} installed as release {{ .Release.Name }}.

Try it from a session terminal:

    curl -s http://{{ .Release.Name }}.{{ .Release.Namespace }}.svc.cluster.local:{{ .Values.service.port }}/

Replicas: {{ .Values.replicaCount }}
EOF
```

Four template features carry the weight:

| | what it does |
| --- | --- |
| `.Values.x` | the merged values — defaults overridden by whatever the user passed |
| `.Release.Name` / `.Release.Namespace` | who is installing this, and where. Using `.Release.Name` in object names is what lets the same chart install twice side by side |
| `.Chart.Name` / `.Chart.Version` | from `Chart.yaml` |
| `\| quote`, `\| toYaml`, `\| nindent N` | pipeline functions from Sprig |

`{{- toYaml .Values.resources | nindent 12 }}` deserves a closer look, because it
is the idiom you will copy most and the one that breaks most often. Helm
templates YAML as **text** — it has no idea about structure. So injecting a
nested block means producing correctly indented text yourself: `toYaml` turns the
value into YAML, `nindent 12` prefixes a newline and indents every line by 12
spaces, and the `{{-` eats the preceding whitespace so you do not get a blank
line and a broken indent. Get the number wrong and you get a YAML parse error
pointing at a line you did not write.

`| quote` on `welcomeMessage` matters for the same reason. A value of `yes`, `no`,
`on`, `off`, `null` or `3.0` unquoted in YAML is a boolean, a null or a float —
not the string you meant. Quote strings that come from values.

Note also that `$WELCOME_MESSAGE` and `$(hostname)` in `args` are *not* Helm syntax;
Helm passes them through untouched and the container's shell expands them at
runtime. Helm's delimiters are `{{ }}` and nothing else.

---

## Render before you install

```bash
helm lint hello
helm template demo ./hello
```

Read that output. It is exactly what would be sent to the API server — no
surprises, no cluster contacted, nothing created. `helm template` is how you
answer "what will this actually do", and it is the difference between using Helm
and hoping.

Try the knobs without installing anything:

```bash
helm template demo ./hello --set replicaCount=5 | grep -E 'replicas|image:'
helm template demo ./hello --set welcomeMessage="different" | grep -A1 WELCOME_MESSAGE
```

---

## Install, and what a release is

```bash
helm install demo ./hello
helm list
```

`demo` is the release name, and it is why every object is called `demo`:

```bash
kubectl get deploy,svc,pods -l app.kubernetes.io/instance=demo
curl -s "http://demo:8080/"
```

Install the *same chart* a second time under a different name and both exist,
independently — this is the payoff for using `.Release.Name` in the templates:

```bash
helm install other ./hello --set replicaCount=1 --set welcomeMessage="the other one"
helm list
curl -s "http://other:8080/"
helm uninstall other
```

Where does Helm keep the release? In your namespace, as a Secret — nowhere else:

```bash
kubectl get secrets -l owner=helm
helm get values demo            # the values that were used
helm get manifest demo | head   # exactly what was applied
helm get all demo | head -30
```

That is worth knowing for two reasons. It means Helm state lives with the
application rather than in your laptop, so a colleague with access to the
namespace can `helm upgrade` what you installed. And it means deleting that
namespace deletes the release history along with everything else.

---

## Upgrade, and rollback

```bash
helm upgrade demo ./hello --set replicaCount=4
helm list                       # revision 2
kubectl get pods -l app.kubernetes.io/instance=demo
```

Render the upgrade before you send it, always. There is no `helm diff` plugin
in this image, so `--dry-run` plus `helm get manifest` is the comparison:

```bash
helm get manifest demo                             > /tmp/current.yaml
helm template demo ./hello --set welcomeMessage="careful" > /tmp/next.yaml
diff -u /tmp/current.yaml /tmp/next.yaml
```

`helm get manifest` is what is deployed; `helm template` is what would be. That
pair is the comparison, and it is the same one `kubectl diff` and `argocd app
diff` make.

Now break it deliberately and watch Helm decline to leave you broken:

```bash
helm upgrade demo ./hello \
  --set image.repository=hub.k8s.ucar.edu/nope/nothere \
  --set image.tag=v1 \
  --atomic --timeout 60s
```

That fails — and `--atomic` rolls the release back to revision 2 on the way out,
so you end up where you started rather than half-upgraded. Without `--atomic`
you would be left at a revision whose pods never became ready.

```bash
helm history demo
helm rollback demo 1
helm history demo               # rollback is itself a new revision
```

Rollback is not time travel: it re-applies an earlier revision's manifests as a
*new* revision. Anything outside those manifests — a database migration, a
mutated PersistentVolume — does not come back.

### Where values come from, in order

Later wins:

1. the chart's `values.yaml`
2. `-f my-values.yaml` (repeatable; later files win)
3. `--set` / `--set-string` / `--set-file`

For anything you will run more than once, use a file, not `--set`. A values file
is reviewable, diffable and can live in git — and [page 5](05-argocd.md) needs it to.

```bash
cat > prod-values.yaml <<'EOF'
replicaCount: 4
welcomeMessage: "hello from the values file"
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
EOF
helm upgrade demo ./hello -f prod-values.yaml
curl -s http://demo:8080/
```

---

## Charts other people wrote

Most real Helm use is installing someone else's chart with your own values.

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami   # needs egress
helm search repo bitnami/postgresql
helm show values bitnami/postgresql | head -40
```

If those hang or fail, this cluster's pods have no direct route to the public
internet — which is normal for an HPC-adjacent platform and not something you
can fix from here. Ask the platform team where the mirrored charts are.
Everything above works with a local chart directory regardless, and
`helm show values <chart>` is the command to run before installing any chart
you did not write.

A chart can also depend on other charts, declared in `Chart.yaml`:

```yaml
dependencies:
  - name: postgresql
    version: "16.x.x"
    repository: https://charts.bitnami.com/bitnami
    condition: postgresql.enabled
```

`helm dependency update` vendors them into `charts/`, and `condition` lets a
user of your chart switch a dependency off and point at an external database
instead.

---

## The CIRRUS example charts

`hello` above is deliberately minimal, so that every line of it is explainable.
A chart for an application you actually want hosted needs three more things —
an Ingress, a place for storage, and a place for secrets — and rather than
inventing that shape you should start from the platform's own:

**<https://github.com/NCAR/cirrus-examples>**

```
helm/
├── web-app-helm/          a container with an internal or external URL  ← start here
├── service-helm/          a service with no external exposure
├── cirrus-vol-helm/       + Ceph persistent volumes (RWO and RWX)
├── nfs-vol-helm/          + a read-only GLADE mount
├── external-secret-helm/  + a secret from OpenBao as an env var
├── postgres-helm/         a CloudNativePG cluster with TLS
├── dask-helm/             a Dask scheduler, workers and a web app
└── alerts-helm/           Prometheus rules and Alertmanager routing
```

Each is a normal chart — `Chart.yaml`, `values.yaml`, `templates/` — and each
`values.yaml` is commented line by line. **`web-app-helm` is the one to read
first**, because it is the minimum viable hosted CIRRUS application and it is
four objects: a Deployment, a Service, an Ingress, and the values that name them.

What is worth stealing from it, beyond the templates:

* **The values file is the interface.** Everything a deployer needs to change —
  image, FQDN, port, replica count, internal vs external, resource requests — is
  at the top level of `values.yaml` with a comment. Nobody should have to open
  `templates/` to deploy your application.
* **`{{ .Release.Namespace }}` rather than a hardcoded namespace.** The same
  chart then works in your test namespace and in the production one.
* **The chart layout the platform expects.** Argo CD is pointed at a *directory*
  in your repository, so `Chart.yaml` must be at the top of that directory and
  every manifest must be inside `templates/`. A manifest sitting next to
  `Chart.yaml` instead of inside `templates/` is silently ignored — this is a
  common and mystifying first failure.

Read them, then diff yours against them:

```bash notebook-skip
git clone https://github.com/NCAR/cirrus-examples ~/cirrus-workshop/cirrus-examples
helm template my-app ~/cirrus-workshop/cirrus-examples/helm/web-app-helm \
  --set webapp.name=my-app \
  --set webapp.tls.fqdn=my-app.k8s.ucar.edu
```

(That clone needs a route to GitHub, which pods here may not have. The charts
are short and readable in a browser either way.)

---

## Testing in your own namespace

This is the step people skip, and it is the cheapest one in the whole workflow.
Before a chart goes anywhere near git and Argo CD, it should have been installed,
upgraded and uninstalled at least once by hand, in a namespace where breaking it
costs nothing. Yours.

The ladder, in increasing cost of being wrong:

```bash
helm lint ./hello                          # 1. is it even valid YAML and Go template
helm template demo ./hello                 # 2. what exactly would be applied
helm template demo ./hello | kubectl apply --dry-run=server -f -   # 3. would the API accept it
helm install demo ./hello                  # 4. do it
```

Step 3 is the one worth adopting as a habit. `--dry-run=server` sends the
manifests to the API server for full validation — schema, admission webhooks,
LimitRange, quota — and creates nothing. It is how you find out that your chart
violates the namespace's LimitRange *before* a rollout half-succeeds, and it
catches things `helm lint` cannot possibly know about.

Then, once it is running, check the things a render cannot tell you:

```bash
kubectl get all -l app.kubernetes.io/instance=demo
kubectl describe deploy demo | tail -20      # events: did it schedule, did it pull
kubectl logs deploy/demo --tail=20           # did it start, or start and exit
```

A chart that installs cleanly in your namespace can still be wrong for
production — the FQDN differs, the quota differs, the secret does not exist yet.
But a chart that does *not* install cleanly here will not install cleanly there,
and finding that out from `helm install` takes seconds where finding it out from
an Argo CD sync failure takes a ticket.

---

## Package it

```bash
helm package hello
ls *.tgz
```

That tarball is the distributable unit — the thing you would push to a chart
repository or an OCI registry (`helm push hello-0.1.0.tgz oci://hub.k8s.ucar.edu/<project>`).
Version it by bumping `Chart.yaml`'s `version` and never by re-pushing the same
one; a chart version, like an image tag, should mean one specific set of bytes.

---

## Clean up

```bash
helm uninstall demo
helm list
kubectl get all
```

Keep `~/cirrus-workshop/helm/hello/` — [page 5](05-argocd.md) puts it in git and hands it to
Argo CD.

---

## Handing the chart to Argo CD

Two things about this transition are counter-intuitive enough that they cause a
real, confusing failure the first time. Both are worth reading now, before
[page 5](05-argocd.md), because they change what you should leave behind here.

### Uninstall before you hand it over

When Argo CD takes ownership of your chart, it will apply the same objects your
`helm install` created. If your release is still installed, two things now
believe they own the Deployment named `demo`, and you get some mixture of
`OutOfSync` that will not resolve, ownership-metadata conflicts, and a `prune`
that deletes something you did not expect.

So: **`helm uninstall` first, then onboard.**

```bash notebook-skip
helm list                    # is anything of mine still installed here?
helm uninstall demo
kubectl get all              # confirm it is gone before Argo CD is pointed at it
```

The same applies in reverse and less obviously: once Argo CD owns an application,
running `helm upgrade` against it by hand does not "win". It holds until the next
reconcile, which reverts it. Change the values file in git instead.

### How Argo CD renders your chart: `template`, not `install`

Argo CD does **not** run `helm install`. Its repo-server runs the equivalent of
`helm template` and applies the resulting manifests directly. That single fact
explains a set of otherwise baffling observations:

| what you notice | why |
| --- | --- |
| `helm list` shows nothing, but the app is running | there is no release — nothing wrote a release Secret |
| `helm history` and `helm rollback` do not work | both read release history, which does not exist |
| `helm get values` cannot tell you what is deployed | Argo CD's own diff is the answer instead |
| a `helm.sh/hook` never fires | Helm hooks are a release-lifecycle feature; Argo CD has its own `argocd.argoproj.io/hook` |
| `.Release.Name` is the Application's name | Argo CD supplies it, and it is not something you chose per-install |
| `lookup` in a template returns nothing | rendering happens without a cluster connection |

None of that is a limitation to work around; it is the model being consistent.
**Git is the release history**, so `git revert` is the rollback, and it goes
through the same review as the change did. Helm's own history would be a second,
competing record of the truth — which is exactly what GitOps sets out to remove.

The practical consequences for how you write the chart:

* **Everything must be derivable from the chart plus its values.** No `lookup`,
  no dependence on what happens to already exist in the namespace.
* **`Chart.yaml` at the top of the path Argo CD is given**, and every manifest
  inside `templates/`.
* **Keep a values file per environment**, checked in. `--set` has nowhere to live
  in a GitOps repository; `valueFiles` in the Application does.
* **Bump `Chart.yaml`'s `version`** when you change templates. It is not enforced
  here, but it is the only version number a reviewer can see.

---

## Where Helm ends

Helm knows what it *installed*. It does not know what the cluster looks like
now. `kubectl scale deployment demo --replicas=9` and Helm still reports
revision 4 with `replicaCount: 4`, perfectly happy, because nothing is watching.
The next `helm upgrade` will quietly correct it — or quietly not, depending on
the field.

That gap between "what I declared" and "what is actually running" is the problem
[page 5](05-argocd.md) exists to solve.

---

## Check yourself

1. What is the difference between `version` and `appVersion` in `Chart.yaml`?
2. Why does `nindent` exist? What is the failure mode if you get its argument
   wrong?
3. Where does Helm store the fact that release `demo` is at revision 4?
4. What does `--atomic` change about a failed upgrade?
5. `helm rollback` restores the manifests of an earlier revision. Name something
   it cannot restore.
6. Which single command validates a chart against the *live* cluster's admission
   policy without creating anything?
7. Your chart is synced by Argo CD and `helm list` is empty. Why is that
   expected, and what is your rollback mechanism instead?
8. What must you do to a hand-installed release before Argo CD is pointed at the
   same chart, and what happens if you forget?

---

← [3. Kubernetes](03-kubernetes.md) · next: [5. Introduction to Argo CD](05-argocd.md)
