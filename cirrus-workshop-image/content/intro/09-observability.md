# 9. Observability: logs, metrics and alerts

← [GitHub Actions](08-github-actions.md) · next: [Specialized workloads](10-workloads.md)

`kubectl logs` is the right tool while you are watching. It is the wrong tool for
"what happened at 3 a.m. on Tuesday", because the pod that knew is gone, and it
is no tool at all for "is this getting slower". Both of those need something
outside the pod that was already collecting.

CIRRUS runs that something: **Prometheus** for metrics, **Loki** for logs, and
**Grafana** in front of both, at <https://grafana.k8s.ucar.edu/>.

---

## Two questions, two systems

Keeping these apart makes Grafana much easier to use, because it is one interface
over two quite different stores:

| | **Prometheus** (metrics) | **Loki** (logs) |
| --- | --- | --- |
| holds | numbers over time, per label set | lines of text, indexed by label |
| answers | is it up, how much, how fast, what trend | what did it say, and when |
| query language | PromQL | LogQL |
| good at | trends, thresholds, alerting | one specific incident |
| bad at | "what was the error message" | "was this worse than last week" |

The order to reach for them in is almost always: **a metric tells you something
is wrong and roughly when; the logs from that window tell you what.**

Neither is retained forever. Assume days-to-weeks rather than months, and if you
need something kept longer than an incident, that is a conversation.

---

## Finding your logs

### While you are watching: `kubectl` and `stern`

Still the fastest path, and worth exhausting first:

```bash notebook-skip
kubectl logs deploy/my-app                  # one of its pods
kubectl logs deploy/my-app -f                # follow
kubectl logs <pod> --previous                # the container that just died
kubectl logs <pod> --since=15m
kubectl logs <pod> --timestamps
stern my-app                                 # ALL matching pods, coloured per pod
stern my-app --since 10m
```

`stern` is the one people miss. With three replicas, `kubectl logs` makes you
pick one and the interesting line is in another; `stern my-app` tails all of them
at once. It takes a regular expression, so `stern '.'` tails the whole namespace.

The limit is the point of the rest of this page: **`kubectl logs` can only show
you a container that still exists.** Once a pod is replaced — a rollout, an
eviction, an OOM kill — its logs are gone from the API, and only Loki has them.

### Afterwards: Grafana and Loki

Open <https://grafana.k8s.ucar.edu/>, go to **Explore**, and select the **Loki**
data source. The query language is LogQL and the shape is: pick a stream with
labels in `{}`, then filter it.

```logql
{namespace="my-namespace"}
```

```logql
{namespace="my-namespace", app="my-app"}
```

```logql
{namespace="my-namespace", app="my-app"} |= "error"
```

```logql
{namespace="my-namespace", app="my-app"} != "healthz" |= "Traceback"
```

Four operators cover most of what you need:

| | |
| --- | --- |
| `\|=` | line contains |
| `!=` | line does not contain — invaluable for silencing health checks |
| `\|~` | line matches a regular expression |
| `\| json` | parse JSON lines, then filter on fields: `\| json \| level="error"` |

Two habits make this much more useful:

**Always start from `{namespace=...}`.** Label selectors are what Loki indexes;
the text filters are applied after. A query with no label selector is slow and
may be refused outright.

**Set the time range before you write the query.** Top right. Narrowing to the
fifteen minutes around an incident does more for query speed than any amount of
cleverness in the filter.

Counting is where Loki earns its place — this turns logs into a metric you can
graph next to everything else:

```logql
sum(count_over_time({namespace="my-namespace", app="my-app"} |= "error" [5m]))
```

### Make your logs worth collecting

Three things, done at the application level, that decide whether any of this
works:

* **Log to stdout and stderr.** Not to a file. A file inside a container is
  invisible to the collector and goes with the pod. This is the single most
  common reason an application has no logs in Grafana.
* **One event per line.** A stack trace spread over forty lines arrives as forty
  unrelated entries. Most languages' logging libraries can be told to serialise
  exceptions onto one line; do it.
* **Consider structured logging.** JSON lines cost you nothing in readability if
  you view them through `| json`, and they let you filter on
  `level`, `request_id` or `user` rather than grepping for substrings.

---

## Finding your metrics

Grafana's Kubernetes dashboards give you the basics for free, without your
application doing anything: **CPU, memory, network, restarts, and pod state**, per
namespace and per pod. Filter to your namespace and you have enough to answer the
most common questions.

The three that matter most, in PromQL, if you want to build your own panel:

```promql
# memory as a fraction of the limit -- the OOMKilled early-warning
container_memory_usage_bytes{namespace="my-namespace"}
  / container_spec_memory_limit_bytes{namespace="my-namespace"}
```

```promql
# CPU cores actually used
rate(container_cpu_usage_seconds_total{namespace="my-namespace"}[5m])
```

```promql
# restarts -- a rising line here is a crash loop
kube_pod_container_status_restarts_total{namespace="my-namespace"}
```

The first is the one to look at habitually. [Page 2](02-containers.md) explained
why: over the CPU limit you are throttled and slow, but over the memory limit the
kernel kills you instantly with no warning. A memory-usage line creeping toward
1.0 over a week is a pod that *will* be OOMKilled, and it is visible days
beforehand.

`kubectl top` gives you a snapshot of the same thing without leaving the
terminal:

```bash
kubectl top pods
kubectl top pods --containers
```

### Metrics from your own application

Container metrics tell you the pod is healthy. They cannot tell you that requests
are failing, or that your queue is backing up, or that the last successful data
refresh was eleven hours ago. For that your application has to publish its own
numbers.

The convention is a plain HTTP endpoint, usually `/metrics`, in Prometheus text
format. Every language has a library: `prometheus_client` for Python,
`prom-client` for Node, Micrometer for Java, `client_golang` for Go. Many
off-the-shelf images already have an exporter — check before you write one.

```python
# the whole of it, for a Flask app
from prometheus_client import Counter, make_wsgi_app
from werkzeug.middleware.dispatcher import DispatcherMiddleware

requests_total = Counter("requests_total", "Requests", ["endpoint", "status"])
app.wsgi_app = DispatcherMiddleware(app.wsgi_app, {"/metrics": make_wsgi_app()})
```

Then two chart changes. Expose the port on the Service:

```yaml
# templates/service.yaml
  ports:
    - name: http
      port: 80
      targetPort: {{ .Values.containerPort }}
    - name: metrics                  # ← named "metrics"; the monitor looks for this
      port: 9090
      targetPort: 9090
```

And add a **ServiceMonitor**, which is how you tell Prometheus to come and
scrape it:

```yaml
# templates/service-monitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ .Values.appName }}-metrics
  labels:
    app: {{ .Values.appName }}
    release: kube-prometheus-stack        # ← required: how Prometheus finds it
spec:
  selector:
    matchLabels:
      app: {{ .Values.appName }}          # ← must match your Service's labels
  endpoints:
    - port: metrics                       # ← the *name* from the Service, not a number
      path: /metrics
      interval: 30s
```

Three fields there are load-bearing and all three are silent when wrong:

* **`release: kube-prometheus-stack`** — Prometheus only picks up monitors
  carrying this label. Omit it and your ServiceMonitor exists, is valid, and is
  ignored.
* **`spec.selector.matchLabels`** — must match the labels on your **Service**, not
  your pods. This is the usual mistake.
* **`endpoints.port`** — the *name* of the port in the Service. A number here
  does not work.

Use `PodMonitor` instead if you have no Service in front of the thing you want
scraped.

---

## Alerting on your own application

Once metrics exist, an alert is two more manifests in your chart. This is the
half of alerting you own; the Argo CD sync/health notifications are the other
half and they are on [page 5](05-argocd.md#alerts-and-notifications).

**A `PrometheusRule` says what condition matters:**

```yaml
# templates/prometheus-rule.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: {{ .Values.appName }}-alerts
  labels:
    prometheus: {{ .Values.appName }}
    release: kube-prometheus-stack
spec:
  groups:
    - name: {{ .Values.appName }}.rules
      interval: 30s
      rules:
        - alert: PodDown
          expr: up{namespace="{{ .Values.namespace }}"} == 0
          for: 5m
          labels:
            severity: critical
            namespace: {{ .Values.namespace }}
          annotations:
            summary: "Pod is down in {{ .Values.namespace }}"

        - alert: HighMemoryUsage
          expr: |
            container_memory_usage_bytes{namespace="{{ .Values.namespace }}"}
            / container_spec_memory_limit_bytes{namespace="{{ .Values.namespace }}"} > 0.9
          for: 10m
          labels:
            severity: warning
            namespace: {{ .Values.namespace }}
          annotations:
            summary: "Container is above 90% of its memory limit"
```

**An `AlertmanagerConfig` says where the notification goes:**

```yaml
# templates/alertmanager-config.yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: {{ .Values.appName }}-alerting
  labels:
    alertmanagerConfig: {{ .Values.appName }}
    release: kube-prometheus-stack
spec:
  route:
    receiver: {{ .Values.appName }}-notifications
    groupBy: [alertname]
    groupWait: 10s
    groupInterval: 1m
    repeatInterval: 60m
    matchers:
      - name: namespace
        value: {{ .Values.namespace }}
        matchType: "="
  receivers:
    - name: {{ .Values.appName }}-notifications
      emailConfigs:
        - to: {{ .Values.alerting.email }}
          from: alertmanager@k8s.ucar.edu
          smarthost: vdir.ucar.edu:25
```

`for: 10m` is the field that decides whether your alerting is useful or ignored:
the condition must hold for that long before anything is sent, which is what
stops a thirty-second blip from waking anyone. `repeatInterval` is how often an
unresolved alert reminds you.

Alertmanager also supports Slack, PagerDuty, Microsoft Teams, OpsGenie and plain
webhooks as receivers — the shape is the same, with `slackConfigs` in place of
`emailConfigs`.

The working chart is
[`alerts-helm`](https://github.com/NCAR/cirrus-examples/tree/main/helm/alerts-helm)
in `cirrus-examples`.

### Test with an alert that always fires

**This is not optional advice.** Alertmanager is not exposed to users on CIRRUS:
you cannot open its UI and you cannot read its logs, so if a notification does not
arrive you have no way to find out why. The only reliable way to know the pipeline
works is to make it fire on purpose.

```yaml
        - alert: TestAlert
          expr: vector(1)              # always true
          for: 1m
          labels:
            severity: info
            namespace: {{ .Values.namespace }}
          annotations:
            summary: "Test alert - always firing"
```

Deploy it, wait for the mail, check that the formatting and routing are what you
expected — **then delete the rule and deploy again.** Doing this first turns
"alerting is set up" from a hope into a fact.

### When an alert does not arrive

Work down in this order; the cause is nearly always in the first three:

1. **Is the metric there at all?** Query the `expr` in Grafana's Explore against
   the Prometheus data source. If it returns nothing, the problem is the
   ServiceMonitor, not the alert.
2. **Are the labels right?** `release: kube-prometheus-stack` on both manifests,
   and the `AlertmanagerConfig` matchers actually selecting your alerts' labels.
3. **Has `for:` elapsed?** A 10-minute `for` with a 3-minute outage sends nothing,
   correctly.
4. **Is `repeatInterval` suppressing it?** A repeat of the same alert inside the
   window is deliberately silent.
5. **Does the receiver work?** Email address, webhook URL. The `vector(1)` test
   above is how you separate this from everything else.

---

## Grafana, day to day

* **Explore** is where you go with a question. Data source picker top left —
  Prometheus for numbers, Loki for lines.
* **Dashboards** — the built-in Kubernetes ones cover cluster, namespace, pod and
  workload. Filter to your namespace and bookmark it; that link is what you send
  someone who says "the site is slow".
* **Your own dashboard** is worth building once your application publishes
  metrics, and worth keeping small: request rate, error rate, latency, and
  memory-against-limit is a genuinely good four-panel dashboard and better than a
  forty-panel one nobody reads.
* **Export it to git.** A dashboard's JSON can be committed, which means it
  survives, gets reviewed, and can be recreated. A dashboard that exists only in
  Grafana's database is one migration away from gone.

---

## Check yourself

1. A pod OOM-killed overnight and was replaced. Which tool has the logs, and
   which does not?
2. Write the LogQL to find lines containing `Traceback` from `app=my-app` in your
   namespace, excluding health checks.
3. Your ServiceMonitor is valid and Prometheus ignores it. Name the most likely
   missing label.
4. Which metric warns you days in advance of an `OOMKilled`, and what value are
   you watching for?
5. Why must you test alerting with an always-firing rule rather than waiting for
   a real problem?
6. Your application logs to `/var/log/app.log` inside the container. What is
   wrong with that?

---

← [8. GitHub Actions](08-github-actions.md) · next: [10. Specialized workloads](10-workloads.md)
