<!-- cirrus-content: installed from the workshop image; replaced at every session start -->
# CIRRUS workshop: start here

You are inside a container running on a Kubernetes cluster, with a terminal, an
editor, and the tools to talk to that cluster as *yourself*. Nothing here is a
simulation — the commands on these pages act on a real cluster, in a namespace
that belongs to you.

These pages are meant to be read in order the first time and used as a reference
afterwards.

---

## Three things first

Do these before anything else. Each of the later pages assumes they worked.

### 1. Open a terminal

* **JupyterLab** — *File → New → Terminal*, or the `+` launcher, then *Terminal*.
* **VS Code** — *Terminal → New Terminal*, or `Ctrl`+`` ` ``.

### 2. Sign in to the cluster

Your first `kubectl` command triggers a sign-in. Run it in the terminal, not in
a notebook — the prompt has nowhere to appear inside a kernel and will simply
time out.

```bash
kubectl get pods
```

It prints something like:

```
To sign in, use a web browser to open the page https://microsoft.com/devicelogin
and enter the code XXXXXXXXX to authenticate.
```

Open that URL in a **new browser tab**, enter the code, and finish the sign-in
with your normal NCAR credentials. There is no browser inside this container,
which is why it hands you a code instead of opening one for you.

The command then completes. The token is cached for about an hour, so the next
`kubectl` will not ask again. When it expires you sign in once more — see
[Troubleshooting](intro/99-troubleshooting.md#i-am-asked-to-sign-in-again) for why
there is no silent refresh.

### 3. Check the session

```bash
cirrus-check
```

Twenty checks: is there a session kubeconfig, is it pointed at the workshop
cluster and *your* namespace, is your home directory being kept out of harm's
way, can a token be obtained, does an authorized call come back. Every line
should say `PASS`. If any say `FAIL`, the message names what to fix — and
[Troubleshooting](intro/99-troubleshooting.md) covers the ones that come up.

---

## The pages

Every lesson comes in two editions with the same content — **read** it as a page,
or **run** it as a notebook. Pick whichever you prefer; they are generated from
the same source, so neither is behind the other.

| | lesson | read | run | what it covers |
| --- | --- | --- | --- | --- |
| 1 | Containers | [md](intro/01-containers.md) | [ipynb](intro/01-containers.ipynb) | What a container actually is, and how to inspect the one you are sitting in |
| 2 | Kubernetes | [md](intro/02-kubernetes.md) | [ipynb](intro/02-kubernetes.ipynb) | Pods, Deployments, Services, ConfigMaps — written and applied by hand |
| 3 | Helm | [md](intro/03-helm.md) | [ipynb](intro/03-helm.ipynb) | Packaging those manifests into something installable, upgradeable, and reversible |
| 4 | Argo CD | [md](intro/04-argocd.md) | [ipynb](intro/04-argocd.ipynb) | GitOps: the cluster pulling its own desired state from a repository |
| 5 | CIRRUS itself | [md](intro/05-cirrus.md) | [ipynb](intro/05-cirrus.ipynb) | The clusters, your namespace, what you may and may not do in it |
| — | Troubleshooting | [md](intro/99-troubleshooting.md) | — | The failures people actually hit here |

Lessons 1 through 4 build on each other: the application you deploy by hand in
lesson 2 is the one you package in lesson 3 and hand to Argo CD in lesson 4.
Troubleshooting is a lookup table rather than a walkthrough, so it has no
notebook edition.

### Which edition?

**Notebooks** run the commands for you — click a cell, see the output, and it
stays there as a record of what happened. Two things to know: sign in from a
**terminal** first (`kubectl get pods`), because a credential prompt cannot be
shown inside a kernel and will only time out; and a handful of steps are
terminal-only by nature — an interactive shell, watching two things at once —
which appear as plain code blocks rather than runnable cells.

**Pages** are better if you would rather type the commands yourself, which is
how you will actually work afterwards. Put the page and a terminal side by side:
drag a tab to the right-hand edge in either editor and you get a split view.

Notebooks are yours to scribble in — they persist between sessions once you have
run them. The pages are read-only and refresh from the image every launch.

---

## Where things live

| path | what it is | survives the session? |
| --- | --- | --- |
| `~/cirrus-workshop/` | your working directory — the editor opens here | **yes**, it is on your GLADE home |
| `~/cirrus-workshop/README.md` | this page | replaced from the image every launch |
| `~/cirrus-workshop/intro/` | the lessons, both editions | pages refresh every launch; notebooks you have run are kept |
| `/tmp/cirrus/` | caches, tokens, editor state | no, it is the pod's own disk |
| `/opt/cirrus/` | the read-only bits the image ships | it is the image |

Two consequences worth internalising:

**Put your work in `~/cirrus-workshop/`, not below `intro/`.** This page and the
Markdown lessons are replaced from the image at every launch — that is how you
get corrections without re-copying anything — so they are read-only, and your
editor will refuse to save over one rather than let you lose an edit. Notebooks
are the exception: once you have run one it is yours, and it is kept across
launches instead of being replaced. Any *other* file you leave in `intro/` is
gone next session. Everything else in `~/cirrus-workshop/` is yours and
persists.

**Your home directory is shared with Casper and Derecho.** This session
deliberately writes almost nothing to it: caches, Python packages and editor
state all go to `/tmp/cirrus/` instead. A wheel built inside this container and
installed into `~/.local` can break your HPC logins outright — different glibc,
different CPU features. If you `pip install` something here, it lands in the
session, not in your home, and it is gone next launch. That is intentional.

---

## What is installed

```bash
cirrus-versions          # every pinned tool and its version
cirrus-versions --check  # re-run each one and diff against the pin
```

The short list: `kubectl`, `helm`, `argocd`, `stern`, `kubelogin`, `yq`, `jq`,
`git`, plus Python with `kubernetes` and `pyyaml`. Nothing is `latest` — a
session that worked at the last workshop works at the next one.

`kubectl`, `helm`, `argocd` and `stern` have tab completion in `bash` and `zsh`,
and `k` is an alias for `kubectl` with completion wired to it too:

```bash
k get po        # same as kubectl get pods
k get <TAB>     # completes resource types
```

`tcsh` gets the alias and the environment but no completion — those tools only
publish `bash` and `zsh` completions.

---

## Reading these pages

They are Markdown, and they are set up to open **rendered** rather than as
source in both editors.

* **JupyterLab** — this page opened on launch; links between pages open in a new
  tab. To see the raw Markdown: right-click the file in the browser → *Open With*
  → *Editor*.
* **VS Code** — this page opened as the folder's README; links between pages open
  in the same preview. To see the raw Markdown: right-click the file → *Open
  With…* → *Text Editor*.

From a terminal, in any editor:

```bash
cirrus-intro          # list the lessons
cirrus-intro 2        # read lesson 2 in the pager
```

(That reads the Markdown edition — a notebook is not much use in a pager.)

---

## Going further

These pages are an introduction: enough of each idea to use it, and enough
vocabulary to read the real documentation. When you want a full hands-on
workshop on one of them, these are the CIRRUS ones, and they fit together:

| workshop | what it adds |
| --- | --- |
| [nbviz-to-container](https://github.com/NicholasCote/nbviz-to-container) | takes a Jupyter notebook visualisation and turns it into a containerised web server — the natural sequel to [page 1](intro/01-containers.md), and the one to do first if containers are the new part |
| [k8s-argo-codespace](https://github.com/NicholasCote/k8s-argo-codespace) | Argo CD end to end against a real Flask application and Helm chart: install it, deploy through it, change a value in git and watch it sync, then break the image tag and watch it hold |
| [gitops-harbor-workshop](https://github.com/NicholasCote/gitops-harbor-workshop) | the CI half — GitHub Actions building an image, a Harbor robot account, pushing to `hub.k8s.ucar.edu`, and Argo CD picking it up |

Each runs in a GitHub Codespace with its own cluster, so you can work through
them without needing CIRRUS access.

---

## Getting help

* `cirrus-check` first, always. It turns "Kubernetes is broken" into a line
  naming what is wrong.
* [Troubleshooting](intro/99-troubleshooting.md) for the specific failures this
  environment produces.
* NCAR HPC documentation:
  <https://ncar-hpc-docs.readthedocs.io/en/latest/compute-systems/cirrus/>
* At a live workshop: ask. That is what the room is for.

Ready — [Introduction to containers](intro/01-containers.md).
