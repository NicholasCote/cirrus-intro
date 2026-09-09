# 8. GitHub Actions on CIRRUS

← [Storage](07-storage.md) · next: [Observability](09-observability.md)

[Page 5](05-argocd.md) split deployment in two: something builds the image and
pushes it, and something else decides when the cluster runs it. Argo CD is the
second half. This page is the first — and the part of it that is specific to
CIRRUS, which is that the runners can be *inside* the cluster.

---

## Why run CI here at all

GitHub's hosted runners are free, adequate and someone else's problem to
maintain, so the bar for moving off them should be high. Four things clear it:

* **GPUs.** GitHub does not give you one. CIRRUS does, which makes "test the
  training loop on every PR" and "verify the CUDA build" possible rather than
  aspirational.
* **More resources than the free tier.** Larger CPU and memory, for test suites
  that are currently timing out.
* **Proximity to the data and the registry.** A runner in the cluster pushes to
  Harbor over the local network and can be given access to GLADE. A hosted runner
  pulls the whole dataset over the internet, if it can reach it at all.
* **Private repositories without minute-counting.** Cluster runners do not
  consume Actions minutes.

If none of those apply, stay on `ubuntu-latest`. The workflow on
[page 2](02-containers.md#pushing-from-ci) is complete as it stands.

---

## Runner scale sets

CIRRUS uses GitHub's **Actions Runner Controller**: a *scale set* watches a
repository or organisation for queued jobs and creates a runner pod per job,
which is destroyed afterwards. There is no long-lived machine, which is why each
job starts clean and why nothing you install in one job is there in the next.

### Getting one, for an NCAR organisation repository

The easy path. Open a ticket with your repository URL and the CIRRUS team adds a
runner group; no token of yours is involved. Then:

```yaml
jobs:
  testing:
    runs-on:
      group: CIRRUS-4x8
```

Note the `group:` form rather than a plain label — organisation runners are
addressed by group.

One caveat, and it is a security boundary rather than a preference: **if the
runners need access to GLADE, they must be provisioned for an individual
repository** rather than shared across the organisation. A shared runner group
with a data mount would let any workflow in the organisation read it.

### Getting one, for a personal or individual repository

This needs a token, because the controller has to register runners with a
repository you own. Three steps.

**1. Create a fine-grained Personal Access Token.**

*GitHub → Settings → Developer Settings → Personal Access Tokens → Fine-grained
tokens.*

| field | value |
| --- | --- |
| name | `<repository name>-cirrus-runner` |
| expiration | 1 year |
| repository access | **Only select repositories** → the one repository |
| permissions | Metadata: **read**. Actions: **read and write**. Administration: **read and write**. |

Nothing broader. A token with organisation-wide access, or one that never
expires, is the thing this whole arrangement is trying to avoid.

**2. Put it in OpenBao.**

Sign in at <https://bao.k8s.ucar.edu> with OIDC, choose `kv`, and create a secret
at:

```
<your ucar email address>/github_pat
```

with the **key set to the repository name** and the value set to the token. One
path, one key per repository — so adding a second repository later is adding a
key, not a path. ([Page 6](06-secrets.md) is the full tour of OpenBao.)

**3. Ask for the scale set.**

A ticket referencing the repository URL, confirming the credential is in OpenBao.
You get back a scale set name, which becomes your label:

```yaml
jobs:
  testing:
    runs-on: gh-arc-myrepo-scale-set
```

**When the token expires, the runners stop.** Put a reminder somewhere real: mint
a new token, update the same OpenBao key, and the controller picks it up.

---

## Building images on a cluster runner

The one thing that genuinely differs, and it will be your first failure if nobody
warns you: **scale-set runners are not privileged, so there is no Docker daemon
to build with.** `docker build` fails.

The answer is a shared BuildKit service in the cluster. Point buildx at it:

```yaml
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3
        with:
          platforms: linux/amd64
          driver: remote
          endpoint: tcp://buildkitd.arc-systems.svc:1234
```

Everything after that is ordinary `docker/build-push-action`. Putting it together
with Harbor, this is the CIRRUS build workflow end to end:

```yaml
# .github/workflows/build.yaml
name: build and push

on:
  push:
    branches: [main]
  workflow_dispatch:          # always worth having: a button to re-run by hand

jobs:
  build:
    runs-on: gh-arc-myrepo-scale-set
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v4

      - name: Short SHA
        run: echo "SHORT_SHA=$(echo $GITHUB_SHA | cut -c1-7)" >> $GITHUB_ENV

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3
        with:
          platforms: linux/amd64
          driver: remote
          endpoint: tcp://buildkitd.arc-systems.svc:1234

      - name: Log in to Harbor
        uses: docker/login-action@v3
        with:
          registry: hub.k8s.ucar.edu
          username: ${{ secrets.HARBOR_USERNAME }}    # a robot account
          password: ${{ secrets.HARBOR_PASSWORD }}

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          push: true
          file: Dockerfile
          tags: hub.k8s.ucar.edu/<project>/<name>:${{ env.SHORT_SHA }}
          cache-from: type=registry,ref=hub.k8s.ucar.edu/<project>/<name>:cache
          cache-to: type=registry,ref=hub.k8s.ucar.edu/<project>/<name>:cache,image-manifest=true,mode=max
```

Two details in there are worth more than they look:

* **`cache-from` / `cache-to` against Harbor.** Runner pods are destroyed after
  each job, so there is no local layer cache and every build would otherwise be
  cold. Storing the cache as an artifact in Harbor turns a ten-minute rebuild into
  a one-minute one. `image-manifest=true` is required for Harbor to accept it.
* **The tag is the short SHA.** One build, one immutable name — the
  [page 2](02-containers.md#tags-say-which-build) rule, and the thing that makes
  the next section possible.

### Closing the loop to Argo CD

CI has built and pushed an image. Nothing is deployed yet, and that is correct —
the cluster follows git, not the registry. So the last step of the workflow edits
git:

```yaml
      - name: Pin the new tag in the chart
        run: |
          yq -i '.webapp.container.image = "hub.k8s.ucar.edu/<project>/<name>:${{ env.SHORT_SHA }}"' \
            helm/values.yaml
          git config user.name  "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add helm/values.yaml
          git diff --cached --quiet || git commit -m "deploy ${{ env.SHORT_SHA }} [skip ci]"
          git push
```

That commit is the deployment. Argo CD sees the change and syncs it.

Two things to get right, and both bite exactly once:

* **`[skip ci]` in the message**, because the commit is itself a push to `main`
  and would otherwise trigger the workflow that made it — forever.
* **`concurrency: {group: release, cancel-in-progress: false}`** on the workflow,
  so two pushes landing together cannot race on the commit-back.

The full worked version of this pattern is the
[GitOps and Harbor workshop](../README.md#going-further).

---

## Running against the cluster from a workflow

A runner in the cluster can also *talk* to it, which is how CI submits batch-style
work — an MPI job, a data conversion — rather than only building images. Use an
image with `kubectl` and give the runner's ServiceAccount a Role scoped to exactly
what it needs:

```yaml
jobs:
  submit:
    runs-on: gha-runner-actions-test
    container:
      image: docker.io/bitnami/kubectl:latest
    steps:
      - run: kubectl apply -f job.yaml
      - run: kubectl wait --for=condition=complete job/my-job --timeout=30m
      - run: kubectl logs -l job-name=my-job --tail=-1
      - if: always()
        run: kubectl delete -f job.yaml
```

The shape to copy: **submit, wait, collect logs, clean up — with the cleanup
guarded by `if: always()`** so a failed job does not leave objects behind eating
your quota. [Page 10](10-workloads.md) has the MPI version.

Note the tension with [page 5](05-argocd.md): a workflow that applies manifests
is a *push*, not GitOps, and for anything long-lived Argo CD is the better answer.
This pattern is for genuinely imperative work — run this job, once, with these
arguments.

---

## Best practices

CI has your source, your credentials and, here, a route to the cluster. It is
worth hardening deliberately. The CIRRUS documentation's list, in rough order of
value:

**Pin third-party actions by commit SHA.** `uses: actions/checkout@v4` resolves a
*tag*, and tags can be moved — including to compromised code — without you doing
anything. `uses: actions/checkout@<full-sha>` cannot change under you. Do this
for every action you do not control.

**Give `GITHUB_TOKEN` the least it needs.** Declare it per workflow or per job
rather than relying on the repository default:

```yaml
permissions:
  contents: read
```

Add `contents: write` only on the job that actually commits back.

**Protect the branch Argo CD watches.** That branch *is* production. Require pull
request reviews and passing status checks, and restrict who can push:
*Settings → Branches → Add branch protection rule*.

**Use `CODEOWNERS`.** `.github/CODEOWNERS` requests the right reviewers
automatically:

```
/helm/    @your-org/platform-team
/src/     @your-org/backend-team
```

**Restrict what Actions may run.** *Settings → Actions → General*: allow only the
actions your workflows need, and make sure *Require approval for all outside
collaborators* is on for fork pull requests. Without it, a fork PR can run
arbitrary code with your runner's access.

**Turn on the repository security features.** *Settings → Code security*:
Dependabot alerts, code scanning, and **secret scanning with push protection** —
the last of which blocks a credential from being committed at all, which is worth
more than any process you can write down.

**Put the security tools in the pipeline.** Static analysis (CodeQL, Bandit,
ESLint), dependency scans (`pip-audit`, `npm audit`), and image scans (Trivy,
Grype) as PR checks, so a new Critical fails a check rather than waiting to be
noticed in Harbor ([page 2](02-containers.md#vulnerability-information-and-sbom)).

**Treat secrets as single values.** Rotate them; never store YAML or JSON in one,
because Actions masks secret values in logs and a structured blob gets
reformatted past the mask. One credential per secret.

GitHub's own guide is the fuller version:
<https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions>.

---

## When it does not work

| symptom | cause |
| --- | --- |
| job stuck in **Queued** forever | the scale set is not running, or `runs-on` does not match its name |
| `docker build`: no daemon | scale-set runners are unprivileged — use the BuildKit endpoint above |
| `access denied` pushing to Harbor | the robot account lacks push on that project, or its secret expired |
| runners vanished after months | the PAT in OpenBao expired — mint a new one, same key |
| `kubectl`: `Forbidden` from a workflow | the runner's ServiceAccount has no Role for that verb |
| image pulls crawling | pulling from Docker Hub; pull from `hub.k8s.ucar.edu` |

---

## Check yourself

1. Name two reasons to move a workflow off `ubuntu-latest` onto a CIRRUS runner,
   and one reason not to.
2. `docker build` fails on a cluster runner. Why, and what replaces it?
3. Why does a build on a cluster runner need `cache-to`/`cache-from` more than a
   hosted one does?
4. Your workflow commits a new image tag to `main`. What two things stop that
   from looping or racing?
5. Your runners worked for a year and then stopped. What expired, and where do
   you replace it?
6. Why pin an action to a SHA rather than `@v4`?

---

← [7. Storage](07-storage.md) · next: [9. Observability](09-observability.md)
