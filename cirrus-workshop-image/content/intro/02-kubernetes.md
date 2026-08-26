# 2. Introduction to Kubernetes

← [Containers](01-containers.md) · next: [Helm](03-helm.md)

Page 1 was one container, running because something started it. Kubernetes is
what you use when you want *many* containers, running because you said they
should be, and staying that way without you watching.

Everything on this page is typed into a terminal and applied to a real cluster.
Work in your working directory:

```bash
mkdir -p ~/cirrus-workshop/k8s && cd ~/cirrus-workshop/k8s
```

---

## The one idea

You do not tell Kubernetes what to do. You tell it **what you want to be true**,
and it works continuously to make reality match.

```
  you ──▶ API server ──▶ etcd            "I want 3 replicas of this"
                │
                ▼
          controllers  ──── loop ────▶  observe → compare → act
```

Every controller runs the same loop: look at desired state, look at actual
state, take one step to close the gap, repeat forever. Delete a pod and a
controller notices the gap and makes another. A node dies and its pods are
recreated elsewhere. Nobody scripted that recovery; it falls out of the loop.

This is why Kubernetes is *declarative*, and why `kubectl apply -f` on a file
you keep in git is the way to use it, rather than a series of imperative
commands nobody can reconstruct later. Hold that thought until page 4.

---

## Your namespace

A namespace is a scope for names and a boundary for policy. You have exactly
one, and your kubeconfig already points at it:

```bash
kubectl config view --minify -o jsonpath='{.contexts[0].context}{"\n"}'
echo "$CIRRUS_NAMESPACE"
```

It is `ood-<your-username>`, on the `mlc1` cluster. Because the context sets it,
you never need `-n` — every command below acts in your namespace. Try leaving it
off and looking somewhere else and you will get a `Forbidden`, which is correct:

```bash
kubectl get pods -n kube-system     # expect: Forbidden
```

More on the boundary and what it means on [page 5](05-cirrus.md).

---

## What is in the cluster

```bash
kubectl api-resources | head -30          # every kind of object this cluster knows
kubectl explain deployment.spec.replicas  # the field docs, from the server itself
kubectl get all                           # the common kinds, in your namespace
```

`kubectl explain` is worth the habit. It reads the schema out of the live API
server, so it is right for *this* cluster's version — unlike a web search, which
may describe a field that does not exist here yet or was removed.

---

## An image reference the cluster can definitely pull

Rather than assume this cluster can reach Docker Hub, the demos below use the
same image your session is running. Ask the cluster for it:

```bash
IMG=$(kubectl get pod "$(hostname)" -o jsonpath='{.spec.containers[0].image}')
echo "$IMG"
```

`$(hostname)` is your pod's own name — page 1. Keep that terminal; `$IMG` is
used by every manifest that follows.

---

## A Pod

A Pod is the smallest thing Kubernetes schedules: one or more containers that
share a network namespace and a lifetime. Containers in the same pod reach each
other on `localhost`; that is the reason to put two in one pod, and the only
reason.

```bash
cat > pod.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: hello-pod
  labels:
    app: hello
spec:
  containers:
    - name: hello
      image: IMAGE
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: "50m"
          memory: "64Mi"
        limits:
          cpu: "200m"
          memory: "256Mi"
EOF
sed -i "s|image: IMAGE|image: $IMG|" pod.yaml
kubectl apply -f pod.yaml
```

Four fields carry almost all the meaning:

* **`apiVersion` / `kind`** — which schema this object is. Together they tell the
  API server what to validate against.
* **`metadata.name`** — unique within the namespace and kind.
* **`metadata.labels`** — arbitrary key/value tags. They look decorative and are
  in fact the load-bearing part; see *Labels* below.
* **`spec`** — the desired state. Everything else in the object is bookkeeping.

Watch it start:

```bash notebook-timeout=30
kubectl get pods -w        # Ctrl-C when it reaches Running
kubectl get pod hello-pod -o wide
```

Now interrogate it. These four commands are 90% of debugging Kubernetes:

```bash
kubectl describe pod hello-pod    # fields, conditions, and recent events
kubectl logs hello-pod            # stdout/stderr of the container
kubectl get events --sort-by=.lastTimestamp | tail -20
```

and one that needs a terminal, because it hands you an interactive shell:

```bash notebook-skip
kubectl exec -it hello-pod -- bash    # a shell inside it
```

`describe` is the one to reach for first. Its **Events** section at the bottom
is where the scheduler, the kubelet and the image puller say what actually
happened — "insufficient memory", "ImagePullBackOff", "OOMKilled". A pod that is
not Running has a reason, and the reason is nearly always printed there.

### `spec.resources`, and why it is not optional

* **`requests`** is what the scheduler reserves. It decides *where* your pod can
  fit, and a pod whose requests no node can satisfy stays `Pending` forever.
* **`limits`** is the cgroup ceiling from page 1. Over the CPU limit you are
  throttled; over the memory limit you are `OOMKilled`.

Requesting far more than you use wastes a shared cluster. Requesting far less
than you use gets you evicted when the node fills up. Measure, then set both.

---

## Why nobody creates Pods directly

Delete that pod:

```bash
kubectl delete pod hello-pod
kubectl get pods
```

It is gone, and it stays gone. Nothing was watching it. A bare Pod is a
*fact*, not a *desire* — which makes it useful for a one-off debug shell and
useless for running anything you care about.

What you want is a controller holding a desire on your behalf.

---

## A Deployment

A Deployment says "keep N pods matching this template running, and when the
template changes, roll from the old set to the new one without dropping
everything at once".

```bash
cat > deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello
  labels:
    app: hello
spec:
  replicas: 3
  selector:
    matchLabels:
      app: hello
  template:
    metadata:
      labels:
        app: hello
    spec:
      containers:
        - name: hello
          image: IMAGE
          command: ["sh", "-c"]
          args:
            - >-
              mkdir -p /tmp/www &&
              echo "hello from $(hostname)" > /tmp/www/index.html &&
              cd /tmp/www &&
              exec python3 -m http.server 8080
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 2
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "200m"
              memory: "256Mi"
EOF
sed -i "s|image: IMAGE|image: $IMG|" deployment.yaml
kubectl apply -f deployment.yaml
kubectl get deploy,rs,pods
```

Note what came back: a Deployment, a **ReplicaSet** you never asked for, and
three Pods. Three controllers in a chain — the Deployment owns ReplicaSets, a
ReplicaSet owns Pods — and each layer only knows about the one below it. The
ReplicaSet exists so that a rollout is expressible: a new template means a new
ReplicaSet, scaled up while the old one scales down.

`readinessProbe` is the other piece worth noticing. A container that is
*running* is not necessarily *ready to serve*. Until that probe passes, the pod
receives no traffic — which is what makes the rollout below safe rather than a
brief outage.

### Self-healing, watched live

```bash notebook-timeout=30
kubectl get pods -w
```

In a **second terminal**, kill one:

```bash
kubectl delete pod "$(kubectl get pods -l app=hello -o name | head -1 | cut -d/ -f2)"
```

The first terminal shows the replacement appearing within seconds. Nothing
retried; the ReplicaSet controller simply observed 2 where it wanted 3.

### Scaling

```bash
kubectl scale deployment hello --replicas=5
kubectl get pods -l app=hello
```

Then put it back in the file rather than leaving the cluster disagreeing with
your manifest — `kubectl scale` is a fine thing to do at 3 a.m. and a bad thing
to leave behind:

```bash
sed -i 's/replicas: 3/replicas: 5/' deployment.yaml
kubectl diff -f deployment.yaml      # nothing, now that they agree
```

`kubectl diff` is the command that makes `apply` safe. Run it before every
apply and you will never again be surprised by what you changed.

### Rollout and rollback

Change something about the template and watch the roll:

```bash
kubectl set env deployment/hello WELCOME_MESSAGE=hi
kubectl rollout status deployment/hello
kubectl get rs -l app=hello           # two ReplicaSets now: old at 0, new at 5
kubectl rollout history deployment/hello
kubectl rollout undo deployment/hello
```

Then make a *broken* change on purpose, so you see what a failed rollout looks
like:

```bash
kubectl set image deployment/hello hello=hub.k8s.ucar.edu/nope/nothere:v1
kubectl rollout status deployment/hello --timeout=60s     # will not complete
kubectl get pods -l app=hello                             # ImagePullBackOff
kubectl describe pod -l app=hello | tail -20              # the reason, in Events
kubectl rollout undo deployment/hello
kubectl rollout status deployment/hello
```

The important part: your *old* pods kept serving the whole time. The Deployment
would not tear down a working ReplicaSet for a new one whose pods never became
ready. That behaviour is `maxUnavailable`, and it is why the readiness probe was
worth writing.

---

## A Service

Pod IPs are ephemeral — every replacement pod gets a new one. A Service is a
stable name and address in front of a *set* of pods, chosen by label.

```bash
cat > service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: hello
spec:
  type: ClusterIP
  selector:
    app: hello
  ports:
    - name: http
      port: 8080
      targetPort: http
EOF
kubectl apply -f service.yaml
kubectl get svc hello
kubectl get endpointslices -l kubernetes.io/service-name=hello
```

Those endpoints are the Service's whole mechanism: a controller watches for pods
matching `selector` **that are ready**, and keeps their IPs in that list. No
label match, no endpoints, no traffic — and a Service with an empty endpoint
list is the single most common "why does nothing reach my app".

Your session pod is on the same cluster network and in the same namespace, so
you can just call it:

```bash
curl -s http://hello:8080/
for i in 1 2 3 4 5; do curl -s http://hello:8080/; done
```

Different pod names come back — the Service is load-balancing across replicas.
The short name works because your pod's DNS search path includes your namespace;
the fully qualified form is `hello.<namespace>.svc.cluster.local`:

```bash
curl -s "http://hello.${CIRRUS_NAMESPACE}.svc.cluster.local:8080/"
```

If DNS or the pod network is restricted for you, `port-forward` gets there
through the API server instead:

```bash
kubectl port-forward svc/hello 18080:8080 &
curl -s http://127.0.0.1:18080/
kill %1
```

Service types, briefly: **ClusterIP** is in-cluster only and is what you want
almost always. **NodePort** opens a high port on every node — this is how your
own OnDemand session is reached. **LoadBalancer** asks the platform for an
external address. Exposing something to the outside on CIRRUS is a conversation
with the platform team, not a field you set; see [page 5](05-cirrus.md).

---

## Labels and selectors

This is the mechanism the whole system is built on, and it is worth being
explicit about because it is invisible until it breaks.

```bash
kubectl get pods --show-labels
kubectl get pods -l app=hello
kubectl label pod "$(kubectl get pods -l app=hello -o name | head -1 | cut -d/ -f2)" app=quarantined --overwrite
kubectl get pods -l app=hello        # one fewer
kubectl get pods                     # but it still exists
```

Watch what just happened: relabelling one pod dropped it out of the
ReplicaSet's selector, so the ReplicaSet saw a shortfall and made a new pod —
while the relabelled one kept running, now owned by nothing and receiving no
Service traffic. That is a real debugging technique (detach a misbehaving pod
and keep it for inspection), and it is also exactly how a typo in a selector
produces a Service that reaches nothing.

Clean it up:

```bash
kubectl delete pod -l app=quarantined
```

---

## Configuration: ConfigMaps and Secrets

Configuration does not belong in the image. Page 1's rule — an image is
immutable and shared — means anything site-specific has to arrive at runtime.

```bash
kubectl create configmap hello-config \
  --from-literal=WELCOME_MESSAGE="hello from a ConfigMap" \
  --dry-run=client -o yaml > configmap.yaml
cat configmap.yaml
kubectl apply -f configmap.yaml
```

`--dry-run=client -o yaml` is the trick worth stealing: let `kubectl create`
write the boilerplate, then keep the file. It works for most kinds.

Wire it in as an environment variable:

```bash
kubectl patch deployment hello --type=strategic -p '
spec:
  template:
    spec:
      containers:
        - name: hello
          envFrom:
            - configMapRef:
                name: hello-config
'
kubectl rollout status deployment/hello
kubectl exec deploy/hello -- printenv WELCOME_MESSAGE
```

The pods restarted, because changing the pod template is what a rollout *is*. A
ConfigMap mounted as a **volume** instead is updated in place without a restart
(eventually — it is a periodic sync, not instant), which is the usual reason to
prefer a file over an env var.

Secrets look identical and are *not* encrypted — only base64-encoded, which is
an encoding, not a protection. They are separate from ConfigMaps so that access
to them can be restricted separately, and so they do not get printed by accident:

```bash
kubectl create secret generic hello-secret --from-literal=token=not-a-real-token
kubectl get secret hello-secret -o jsonpath='{.data.token}' | base64 -d; echo
```

Never commit a Secret manifest to git. That is a real problem for page 4's
GitOps model and it has real answers — Sealed Secrets, the External Secrets
Operator, SOPS — all of which come down to putting something in git that is
useless without a key the cluster holds.

---

## Debugging, collected

```bash notebook-skip
kubectl describe pod <name>              # start here: conditions + events
kubectl logs <pod>                       # current container
kubectl logs <pod> --previous            # the one that crashed
kubectl logs -f deploy/hello             # follow, via one of its pods
stern hello                              # follow ALL matching pods at once
kubectl get events --sort-by=.lastTimestamp
kubectl exec -it <pod> -- bash           # look around inside
kubectl run tmp --rm -it --image="$IMG" --command -- bash   # a throwaway pod
kubectl top pods                         # actual CPU/memory, if metrics-server is up
```

`stern` is the one people do not know about and miss immediately once they do:
with five replicas, `kubectl logs` makes you pick one, and `stern hello` tails
all of them with the pod name coloured per pod.

A short table of what a status means:

| status | what it means | where to look |
| --- | --- | --- |
| `Pending` | not scheduled yet | `describe` → Events: usually resource requests no node can satisfy |
| `ImagePullBackOff` | the image reference is wrong or unreachable | `describe` → Events: typo, wrong registry, no pull secret |
| `CrashLoopBackOff` | the container starts and exits | `logs --previous` |
| `OOMKilled` | it went over `memory.max` | raise `limits.memory`, or use less |
| `Running`, not `Ready` | the readiness probe is failing | `describe` → the probe's error |
| `Completed` | it exited 0 — fine for a Job, wrong for a server | your command returned |

---

## Clean up

```bash
cd ~/cirrus-workshop/k8s
kubectl delete -f service.yaml -f deployment.yaml -f configmap.yaml
kubectl delete secret hello-secret
kubectl get all
```

Deleting by file rather than by name is the habit to build: it can only remove
what you declared. Keep the manifests — page 3 turns them into a chart.

---

## Check yourself

1. You `kubectl delete pod` one of a Deployment's pods and it comes back. You
   `kubectl delete pod` a bare Pod and it does not. Why, in terms of the control
   loop?
2. A Service exists, has the right port, and reaches nothing. What is the first
   thing you check?
3. What is the difference between `requests` and `limits`, and which one decides
   whether your pod schedules at all?
4. Why does changing a ConfigMap consumed via `envFrom` require a restart, while
   the same ConfigMap mounted as a volume does not?
5. You edited a Deployment with `kubectl scale` and also keep it in git. What is
   now wrong, and what does page 4 do about it?

---

← [1. Containers](01-containers.md) · next: [3. Introduction to Helm](03-helm.md)
