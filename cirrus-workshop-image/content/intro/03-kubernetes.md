# 3. Introduction to Kubernetes

← [Containers](02-containers.md) · next: [Helm](04-helm.md)

[Page 2](02-containers.md) was one container, running because something started it. Kubernetes is
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
commands nobody can reconstruct later. Hold that thought until [page 5](05-argocd.md).

---

## `kubectl`, and the kubeconfig behind it

`kubectl` is a client for one HTTPS API. That is worth saying plainly, because
almost every confusing thing about it follows from it: `kubectl get pods` is a
`GET`, `kubectl apply` is a `PATCH`, and anything that looks like magic is a
controller on the other end.

What it needs to make that call — the server address, the CA to trust, and how to
prove who you are — lives in a **kubeconfig**. Look at yours:

```bash
echo "$KUBECONFIG"
kubectl config view                   # credentials are redacted
kubectl config get-contexts
```

Three nested pieces, and naming them makes the error messages legible:

| piece | what it holds | when it is wrong |
| --- | --- | --- |
| **cluster** | the API server URL and its CA certificate | connection refused, or a TLS error |
| **user** | how to get a credential — here, an `exec` block that runs `kubelogin` | `Unauthorized`, or a sign-in prompt that never ends |
| **context** | a cluster + a user + a default namespace, under one name | commands land on the wrong cluster or in the wrong namespace |

```bash
kubectl config current-context
```

On CIRRUS the *user* entry does not contain a token at all. It contains an
`exec` block: "run `kubelogin get-token` and use what it prints". That is why
your first command of the session pauses to hand you a device code, and why the
next one does not — the token is cached for about an hour. The mechanics and the
reason there is no silent refresh are on
[page 1](01-orientation.md#who-you-are-to-the-cluster).

The session's kubeconfig is a **working copy** at `/tmp/cirrus/kube/config`, not
your own file. Break it however you like; it is rebuilt next launch.

### The four verbs that do the work

Nearly all interactive Kubernetes is four commands, and it is worth learning them
as a sequence rather than a list — this is the order you use them in when
something is wrong:

```bash notebook-skip
kubectl get <kind>              # what exists, one line each
kubectl describe <kind>/<name>  # every field, conditions, and recent Events
kubectl logs <pod>              # what the process said
kubectl exec -it <pod> -- bash  # go and look
```

* **`get`** answers *does it exist and what state does it claim*. Add `-o wide`
  for nodes and IPs, `-o yaml` for the whole object, `-w` to watch it change.
* **`describe`** is the one people under-use. Its **Events** section at the
  bottom is where the scheduler, the kubelet and the image puller explain
  themselves in English. A pod that is not Running has a reason and the reason is
  printed there.
* **`logs`** takes `--previous` for the container that just died, `-f` to follow,
  and a Deployment instead of a pod (`kubectl logs deploy/hello`) when you do not
  care which replica.
* **`exec`** is a last resort and an excellent one. If the config is not what you
  think it is, go and read it.

Two more that pay for themselves: `kubectl explain <kind>.<field>` reads the
schema out of *this* cluster's API server, so it is right for this version
unlike a web search; and `kubectl api-resources` lists every kind the cluster
knows, including the custom ones the platform has added.

---

## Your namespace, and what you may do in it

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

That fence is enforced by **Capsule**, the multi-tenancy layer described on
[page 1](01-orientation.md#your-space-on-the-cluster-namespaces). You are an owner
of your own namespace and a stranger everywhere else.

Rather than guessing where the edges are, ask the API server:

```bash
kubectl auth can-i --list                  # everything you may do here
kubectl auth can-i create deployments      # yes
kubectl auth can-i get pods -n kube-system # no
kubectl auth can-i create namespaces       # almost certainly no
kubectl auth can-i list nodes              # probably no
```

`kubectl auth can-i --list` is the single most useful command on this page. It is
answered by the server against your actual token, so it is authoritative, current
and specific to you — no reading of policy documents required.

### Quota and limit ranges

Two objects constrain what you may *consume*, and both produce failures that are
much easier to read once you know they exist:

```bash
kubectl get resourcequota
kubectl describe resourcequota
kubectl get limitrange
kubectl describe limitrange
```

* A **ResourceQuota** caps the namespace in total — CPU, memory, storage, object
  counts. Exceed it and the *creation* is rejected with a message naming the
  quota, which is far friendlier than a pod that silently never schedules.
* A **LimitRange** constrains individual objects and can supply defaults. If one
  requires `requests` and `limits` on every container, a manifest without them is
  rejected outright — which is exactly why every manifest below has them.

Read the quota *before* you scale something up or ask for a large volume. `Pending`
pods with nothing obviously wrong are usually a quota that is already full.

---

## What is in the cluster

```bash
kubectl api-resources | head -30          # every kind of object this cluster knows
kubectl explain deployment.spec.replicas  # the field docs, from the server itself
kubectl get all                           # the common kinds, in your namespace
```

`kubectl get all` is a slight lie — it shows the common workload kinds and not,
for instance, ConfigMaps, Secrets, Ingresses or PVCs. Useful as a first look;
not an inventory.

---

## An image reference the cluster can definitely pull

Rather than assume this cluster can reach Docker Hub, the demos below use the
same image your session is running. Ask the cluster for it:

```bash
IMG=$(kubectl get pod "$(hostname)" -o jsonpath='{.spec.containers[0].image}')
echo "$IMG"
```

`$(hostname)` is your pod's own name — [page 2](02-containers.md). Keep that terminal; `$IMG` is
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
* **`limits`** is the cgroup ceiling from [page 2](02-containers.md). Over the CPU limit you are
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
with the platform team, not a field you set — and on CIRRUS the answer is
usually an Ingress rather than a LoadBalancer.

---

## Ingress

A Service gets you an address *inside* the cluster. An **Ingress** is how a
hostname on the outside gets routed to it, with TLS terminated on the way.

You will not be able to create one in this namespace, and you would not want to:
the hostname has to be assigned, the certificate has to be issued, and both are
platform-managed. But you will *write* one — it is the piece of your Helm chart
that turns a running Deployment into a URL — so it is worth reading closely.

This is the CIRRUS shape, from the platform's own
[cirrus-examples](https://github.com/NCAR/cirrus-examples) chart:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  annotations:
    cert-manager.io/cluster-issuer: "incommon"     # who issues the certificate
spec:
  ingressClassName: traefik-internal               # or traefik-external
  tls:
    - hosts:
        - my-app.k8s.ucar.edu                      # must end in .k8s.ucar.edu
      secretName: incommon-cert-my-app             # where the cert is stored
  rules:
    - host: my-app.k8s.ucar.edu
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app                       # the Service, by name
                port:
                  number: 8080
```

Four fields carry the CIRRUS-specific meaning:

* **`ingressClassName`** — which of the two ingress paths you want.
  `traefik-internal` is reachable from the UCAR network and the VPN;
  `traefik-external` is reachable from the public internet. **This is the whole
  public/private decision**, and it is one string. Choose deliberately, and say
  which you want in your onboarding ticket.
* **`host`** — your FQDN, which must be unique and must end in `.k8s.ucar.edu`.
  ExternalDNS sees this object and creates the DNS record. You do not file a DNS
  request.
* **`cert-manager.io/cluster-issuer`** — cert-manager sees the annotation and the
  `tls` block, obtains a certificate for that hostname, writes it into
  `secretName`, and renews it before it expires. Nobody has a calendar reminder.
* **`backend.service`** — the Service from the previous section, by name and port.
  If the Service has no endpoints, the Ingress returns a 503 and everything
  *looks* fine at the Ingress level. Debug backwards: Ingress → Service →
  endpoints → pod readiness.

You can still look at what exists:

```bash
kubectl get ingress
kubectl get ingressclass 2>/dev/null || echo "not permitted to list cluster-scoped IngressClasses"
```

The mental model to keep: **Deployment runs it, Service names it, Ingress
publishes it.** Three objects, and almost every hosted CIRRUS application is
exactly those three plus configuration.

---

## PersistentVolumeClaims

Everything so far vanishes with its pod. A **PersistentVolumeClaim** is how a
workload asks for storage that does not:

```bash
kubectl get pvc
kubectl get storageclass 2>/dev/null || echo "not permitted to list cluster-scoped StorageClasses"
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
spec:
  accessModes: ["ReadWriteOnce"]      # one node at a time
  storageClassName: ceph-kubepv       # CIRRUS: ceph-kubepv (RWO) or cephfs (RWX)
  resources:
    requests:
      storage: 5Gi
```

The claim is a *request*; a controller finds or creates a volume that satisfies
it and binds the two. A pod then mounts the claim by name, and the pod can be
destroyed and recreated a hundred times with the data still there.

Two things to know before you write one, and both are covered properly on
[page 7](07-storage.md):

* **`accessModes` is a real constraint, not a hint.** `ReadWriteOnce` means one
  node at a time — so a Deployment with three replicas sharing one RWO claim
  will not do what you expect. Many readers need a `ReadWriteMany` class.
* **Storage counts against your quota**, and a bound volume keeps counting
  whether anything is using it. `kubectl describe resourcequota` before you ask
  for something large.

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


Configuration does not belong in the image. [Page 2](02-containers.md)'s rule — an image is
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

### Secrets

A Secret is a ConfigMap with two differences: the values are base64-encoded, and
access to it can be restricted separately. Note what is *not* on that list —
**a Secret is not encrypted.** Base64 is an encoding, not a protection, and
anyone who can read the object can read the value:

```bash
kubectl create secret generic hello-secret --from-literal=token=not-a-real-token
kubectl get secret hello-secret -o jsonpath='{.data.token}' | base64 -d; echo
```

It is consumed exactly like a ConfigMap — `envFrom`, or a single key by name:

```yaml
env:
  - name: API_TOKEN
    valueFrom:
      secretKeyRef:
        name: hello-secret
        key: token
```

**You should almost never write one of these by hand**, and it is worth being
precise about why, because the reason is not "hand-editing is untidy":

* **A Secret manifest cannot go in git**, and from [page 5](05-argocd.md) onwards
  git is how everything reaches the cluster. A `data:` block is one `base64 -d`
  away from plaintext, in a repository, in every clone, in the reflog forever.
* **`kubectl create secret` is invisible.** It leaves no record of where the
  value came from, who set it, or when it should be rotated. Six months later
  nobody can answer any of those questions, and the credential is still live.
* **It drifts.** A Secret created by hand is the one object Argo CD did not
  install, so it survives a `prune`, misses every rotation, and quietly differs
  between the two clusters.

### ExternalSecret: the object that makes one for you

The answer is to commit a *reference* rather than a value. An **ExternalSecret**
is a custom resource that says "there is a secret at this path in the secret
store; fetch it and keep a Kubernetes Secret in sync with it":

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: my-app-esos
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: user-ro                 # created for your namespace by the CIRRUS team
    kind: SecretStore
  target:
    name: my-app-esos             # the Secret this produces
  data:
    - secretKey: api-token        # the key inside that Secret
      remoteRef:
        key: you@ucar.edu/my-app  # the path in OpenBao
        property: api-token       # the key at that path
```

That file is safe in git: it names a location, not a credential. The External
Secrets Operator reads it, authenticates to the store on the cluster's behalf,
writes a real Secret into your namespace, and refreshes it on the interval. Your
Deployment then uses `secretKeyRef` above, unchanged and unaware.

```bash
kubectl get externalsecrets 2>/dev/null || echo "no ExternalSecrets here yet"
kubectl get secretstores    2>/dev/null || echo "no SecretStore wired into this namespace"
```

Expect both to be empty in this workshop namespace — a `SecretStore` is created
for a project namespace when you ask for one. The store on CIRRUS is **OpenBao**,
and the whole flow — paths, authentication, and adding an ExternalSecret to your
chart — is [page 6](06-secrets.md).

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
what you declared. Keep the manifests — [page 4](04-helm.md) turns them into a chart.

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
   now wrong, and what does [page 5](05-argocd.md) do about it?
6. Which single field on an Ingress decides whether the world can reach your
   application, and which object turns the hostname into DNS?
7. Your Ingress returns 503. Name the chain of things to check, in order.
8. Give two reasons not to run `kubectl create secret`, beyond untidiness.
9. Which command answers "what am I actually allowed to do here", and why is it
   more trustworthy than reading a policy?

---

← [2. Containers](02-containers.md) · next: [4. Introduction to Helm](04-helm.md)
