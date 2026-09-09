# 6. Secret Manager: OpenBao

← [Argo CD](05-argocd.md) · next: [Storage](07-storage.md)

[Page 3](03-kubernetes.md#secrets) ended on an unresolved problem: a Kubernetes
Secret is base64, not encryption, and [page 5](05-argocd.md) then made git the
only route into the cluster. Those two facts together mean there has to be
somewhere else for credentials to live.

On CIRRUS that somewhere is **OpenBao** — an encrypted secret store with a web
UI, at <https://bao.k8s.ucar.edu>. Nothing on this page requires `kubectl`.

---

## The shape of the answer

Four moving parts. It looks like a lot until you see that you only ever touch the
first and the last:

```
   you ──▶ OpenBao                         you put the value here, once, in a browser
              ▲
              │  (the operator authenticates and reads)
        SecretStore                        created for your namespace by the CIRRUS team
              ▲
              │  (names a path, holds no value — this is the part you commit)
        ExternalSecret                     a template in your Helm chart
              │
              ▼
     a Kubernetes Secret                   produced in your namespace, refreshed on a timer
              │
              ▼
        your container                     reads it as an env var, unaware of any of the above
```

The property that makes the whole arrangement work: **what is in git names a
location, never a value.** Someone who clones your repository learns that your
application needs a token called `api-token` from a path called
`you@ucar.edu/my-app`, and learns nothing they could use.

---

## Putting a secret in OpenBao

1. Go to <https://bao.k8s.ucar.edu>.
2. In the **Authentication Method** dropdown, choose **OIDC**.
3. Sign in with your UCAR CIT credentials.
4. Choose **`kv`** — the key/value engine.
5. **Create Secret**, top right.
6. For **Path**, use `<your ucar email address>/<name>`, for example
   `you@ucar.edu/my-app`.
7. Add key/value pairs under it: the key is a short name
   (`GITHUB_TOKEN`, `api-token`, `db-password`), the value is the actual secret.
8. **Save.**

One path can hold as many key/value pairs as you like, which is usually what you
want: one path per application, one key per credential.

To update one later — and you should, on a schedule — sign in the same way, put
your path in the **View Secret** field (`you@ucar.edu/`) to list what you have,
and edit it. Rotating a value in OpenBao is enough: the operator picks up the new
value on its next refresh, without a deploy.

### Path layout

The layout is a convention rather than a schema, and picking one now saves an
unpleasant tidy-up later.

| path | who can read it | use it for |
| --- | --- | --- |
| `you@ucar.edu/<app>` | you | anything personal, and everything while you are developing |
| `you@ucar.edu/bao` | you | the token that authenticates the store itself — see below |
| `<shared-path>/<app>` | the people named on the ticket | anything a team or an application shares |

**Personal paths are automatic**; your email address is your own namespace in the
store and you can create anything under it without asking.

**Shared paths are created by the CIRRUS team.** Ask for one as soon as a
credential matters to more than one person, with three things in the ticket:

* the **path name** — descriptive, e.g. `team-alpha/database-credentials` or
  `project-weather/api-tokens`
* the **UCAR email addresses** that need access
* what it is **for**

Then everyone named can write secrets under
`<shared-path-name>/<new-secret>`. Adding or removing a person later is an
updated ticket. The reason to bother: a production credential living under one
individual's personal path is a credential that becomes unreachable when that
person changes role, and there is no good day to discover that.

---

## Authentication: how the cluster gets in

Two hops, and it is worth understanding which is which because they fail
differently.

**Your hop** is OIDC — the browser sign-in above. That is how *you* read and
write secrets.

**The cluster's hop** is a machine credential. The External Secrets Operator is
a process; it has no browser and no CIT password, so it authenticates to OpenBao
with a **token** or **AppRole** credential that the CIRRUS team configures into a
`SecretStore` object in your namespace. An AppRole is the pattern for this: a
role id plus a secret id, issued to one workload, scoped to one policy, revocable
on its own — the same idea as a Harbor robot account from
[page 2](02-containers.md#robot-accounts), applied to secrets.

One step of that setup is yours, and it is the one people miss. When you request
secrets for an application, the current CIRRUS documented flow asks you to hand
over a token of your own:

1. In OpenBao, click the **person icon** in the upper left, then **Copy token**.
2. Store that token in OpenBao itself, under your personal path
   `you@ucar.edu/bao`, with the key **`token`** and the copied token as the value.

That token is what the store uses to read on your behalf. Two consequences worth
knowing: it is scoped to *your* access, so an application configured this way can
read what you can read; and it expires, so **if secrets stop refreshing months
later, a stale `you@ucar.edu/bao` token is the first thing to check.** For
anything long-lived, ask for a shared path and a store scoped to it instead.

### The SecretStore

```bash
kubectl get secretstores
kubectl get clustersecretstores 2>/dev/null || echo "not permitted to list cluster-scoped stores"
```

Expect nothing in this workshop namespace. A `SecretStore` is namespaced, and it
is created for a project namespace when you ask for secrets during onboarding
([page 5](05-argocd.md#onboarding-an-application-on-cirrus)).

**Its name is what you reference, and it varies.** The CIRRUS documentation's
example uses `openbao-backend`; the `external-secret-helm` example chart uses
`user-ro`. Do not guess — `kubectl get secretstores -o name` in your own
namespace is the authority, or ask when the store is created. A wrong
`secretStoreRef` is the most common cause of an ExternalSecret that never
produces anything.

---

## Adding an ExternalSecret to your chart

Two files. First the ExternalSecret itself, which goes in `templates/` alongside
your Deployment:

```yaml
# templates/external-secret.yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: {{ .Values.webapp.name }}-esos
  namespace: {{ .Release.Namespace }}
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: user-ro                                # your namespace's store
    kind: SecretStore
  target:
    name: {{ .Values.webapp.name }}-esos         # the Secret this creates
  data:
    - secretKey: {{ .Values.webapp.secret.secretKey }}   # key in the new Secret
      remoteRef:
        key: {{ .Values.webapp.secret.secretPath }}      # path in OpenBao
        property: {{ .Values.webapp.secret.secretKey }}  # key at that path
```

Then consume it in the Deployment, which is ordinary Kubernetes —
`secretKeyRef` against the Secret the operator produced:

```yaml
# templates/deployment.yaml, inside the container spec
env:
  - name: {{ .Values.webapp.secret.envVar }}
    valueFrom:
      secretKeyRef:
        name: {{ .Values.webapp.name }}-esos
        key: {{ .Values.webapp.secret.secretKey }}
```

And the three values that make it configurable:

```yaml
# values.yaml
webapp:
  secret:
    secretPath: you@ucar.edu/my-app   # path in OpenBao
    secretKey: api-token              # key at that path
    envVar: API_TOKEN                 # what the container sees
```

That is the complete pattern, and it is worth noticing how little of it is
special: **your application code reads an environment variable.** It does not
know about OpenBao, it has no client library, and it will run unchanged on a
laptop with that variable exported by hand. The whole mechanism is invisible from
inside the container, which is the point.

The working example is
[`external-secret-helm`](https://github.com/NCAR/cirrus-examples/tree/main/helm/external-secret-helm)
in `cirrus-examples`.

### Three fields worth a second look

* **`refreshInterval: 1h`** — how often the operator re-reads OpenBao. Rotating
  the value in OpenBao takes up to this long to reach the cluster, and note that
  the *Secret* updating does not restart your pods. A container that read the env
  var at startup keeps the old value until it restarts. If you need rotation
  without a restart, mount the Secret as a file and re-read it.
* **`target.name`** — the Secret that gets created. It is managed by the
  operator, so do not create one with the same name by hand; you will get a
  conflict rather than a merge.
* **`secretKey` vs `property`** — `property` is the key *in OpenBao*, `secretKey`
  is the key *in the Kubernetes Secret*. They are usually the same string, which
  is exactly why the one time they differ is confusing. Read the block as
  "take `remoteRef.key`/`remoteRef.property` from the store, call it
  `secretKey` here".

---

## Asking for it

When you request an application, or an update to one, include:

* the **names of the secrets** the application needs
* the **OpenBao path and property** for each
* whether the path is **personal or shared** (and if it should be shared, that
  request too)

For an application that already exists, adding a secret is its own short ticket.
The reason it is a ticket at all is the `SecretStore`: the credential that lets
the cluster read your secrets has to be installed by someone who can write to
your namespace's store, and that is not you.

---

## Rules that are worth being absolute about

* **Nothing secret in git. Ever.** Not in a values file, not base64-encoded, not
  in a comment, not "temporarily". Git has no delete — a secret pushed once is in
  every clone and in the reflog, and the only real remedy is rotating it.
* **Nothing secret in an image.** [Page 2](02-containers.md#images-and-layers): a
  layer is never edited, only covered, so `RUN rm /secret` hides the file and
  keeps the bytes.
* **Nothing secret in a log line, or an error message, or a `kubectl describe`
  you paste into a ticket.** Env vars appear in `describe` output for a Pod's
  spec if they are literal values — which is another argument for `secretKeyRef`,
  since that shows a reference instead.
* **Never in a GitHub Actions secret that holds structured data.** Actions masks
  secret *values* in logs; a JSON or YAML blob gets reformatted and the masking
  misses the pieces. One credential per secret.
* **Rotate on a schedule, and rotate immediately on any doubt.** Rotation is
  cheap here — change the value in OpenBao, and the cluster follows.

---

## Check yourself

1. An ExternalSecret is safe to commit to a public repository. Why?
2. Where does the *value* of a secret live, and where does the *reference* live?
3. Your ExternalSecret produces nothing and reports an error about the store.
   What is the first thing to check, and which command answers it?
4. You rotate a password in OpenBao. What happens in the cluster, and how long
   does it take? Will your running pods see it?
5. Why is a shared path a better home for a production credential than your own
   email path?
6. What is the difference between `remoteRef.property` and `secretKey`?

---

← [5. Argo CD](05-argocd.md) · next: [7. Storage](07-storage.md)
