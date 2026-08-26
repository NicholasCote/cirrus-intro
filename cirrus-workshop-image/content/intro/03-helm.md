# 3. Introduction to Helm

← [Kubernetes](02-kubernetes.md) · next: [Argo CD](04-argocd.md)

Page 2 left you with three YAML files and a problem. They contain the same
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
description: The page-2 application, packaged
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

# Same trick as page 2: the image your own session runs, split into repo and tag.
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
| `| quote`, `| toYaml`, `| nindent N` | pipeline functions from Sprig |

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
is reviewable, diffable and can live in git — and page 4 needs it to.

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

Keep `~/cirrus-workshop/helm/hello/` — page 4 puts it in git and hands it to
Argo CD.

---

## Where Helm ends

Helm knows what it *installed*. It does not know what the cluster looks like
now. `kubectl scale deployment demo --replicas=9` and Helm still reports
revision 4 with `replicaCount: 4`, perfectly happy, because nothing is watching.
The next `helm upgrade` will quietly correct it — or quietly not, depending on
the field.

That gap between "what I declared" and "what is actually running" is the problem
[page 4](04-argocd.md) exists to solve.

---

## Check yourself

1. What is the difference between `version` and `appVersion` in `Chart.yaml`?
2. Why does `nindent` exist? What is the failure mode if you get its argument
   wrong?
3. Where does Helm store the fact that release `demo` is at revision 4?
4. What does `--atomic` change about a failed upgrade?
5. `helm rollback` restores the manifests of an earlier revision. Name something
   it cannot restore.

---

← [2. Kubernetes](02-kubernetes.md) · next: [4. Introduction to Argo CD](04-argocd.md)
