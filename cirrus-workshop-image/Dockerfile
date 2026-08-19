# CIRRUS workshop image
#
# One image, two Open OnDemand apps: JupyterLab and code-server. Everything
# lives under /opt and /usr/local, root-owned and world-readable, because the
# pod runs as the user's real NFS uid/gid and nothing in the image may need to
# be chowned or written to at startup.
#
# Deliberately not a Jupyter Docker Stacks base: those bake a jovyan user at
# uid 1000, a conda prefix owned by that uid, and a fix-permissions/start.sh
# chain that assumes it can chown at startup. All of that fights an arbitrary
# runtime uid with a GLADE home over NFS.

ARG UBUNTU_VERSION=24.04

# --------------------------------------------------------------------------
# Pinned tool versions.
#
# Deliberately a short list. kustomize, k9s and the argo (Argo Workflows) CLI were
# dropped after the first OOD trial: the labs are kubectl-centric, the CIRRUS
# clusters accept plain manifests, and k9s is a lot of interface for someone
# meeting Kubernetes for the first time. That also removed ~640 of the ~1270
# vendored Go modules in the image, and with kustomize went the only Critical in
# the scan (its newest release is built with Go 1.24.0). Adding argo back later is
# one ARG, one RUN and one versions.txt line. Nothing here is :latest or "stable" -- a session that
# worked at the last workshop has to work at the next one, and the versions
# baked in are recorded in /opt/cirrus/versions.txt so a bug report can name
# them.
# --------------------------------------------------------------------------

# kubectl tracks the CIRRUS control plane minor and never leads it. mlc1/nwc1
# are on 1.35.6 as of 2026-08-18 and are upgraded roughly quarterly, so this
# is the ARG to bump right after a control plane upgrade -- not before.
ARG KUBECTL_VERSION=v1.35.7

# Azure/kubelogin, NOT int128/kubelogin. The CIRRUS kubeconfig's exec block is
#   command: kubelogin
#   args: get-token --environment AzurePublicCloud --server-id ... --client-id ... --tenant-id ...
# which is the Azure flavor (see the CIRRUS docs, guides/10-kubectl). int128's
# oidc-login plugin takes --oidc-issuer-url/--oidc-client-id and would reject
# every one of those flags.
ARG KUBELOGIN_VERSION=v0.2.19

ARG HELM_VERSION=v3.21.4
ARG ARGOCD_VERSION=v3.5.1
ARG STERN_VERSION=v1.34.0
ARG YQ_VERSION=v4.53.3
ARG CODE_SERVER_VERSION=4.133.0

# Python. Kept deliberately small: this is a Kubernetes workshop, not a data
# science environment. Anyone who needs the scientific stack builds a venv of
# their own in $HOME.
ARG JUPYTERLAB_VERSION=4.6.3
ARG NOTEBOOK_VERSION=7.6.2
ARG JUPYTERLAB_GIT_VERSION=0.54.1
ARG IPYKERNEL_VERSION=7.3.0
ARG PYYAML_VERSION=6.0.3
ARG KUBERNETES_PY_VERSION=36.0.3
ARG REQUESTS_VERSION=2.34.2

# code-server extensions, from Open VSX (code-server's default marketplace;
# the Microsoft marketplace is not licensed for use here).
ARG EXT_YAML_VERSION=1.25.2026081408
ARG EXT_K8S_VERSION=1.4.1

# ==========================================================================
# tools -- download and unpack every pinned binary in one throwaway stage so
# the runtime image never carries the archives.
# ==========================================================================
FROM ubuntu:${UBUNTU_VERSION} AS tools

ARG KUBECTL_VERSION
ARG KUBELOGIN_VERSION
ARG HELM_VERSION
ARG ARGOCD_VERSION
ARG STERN_VERSION
ARG YQ_VERSION
ARG CODE_SERVER_VERSION

# buildx sets TARGETARCH; default it so a plain `docker build` also works.
ARG TARGETARCH=amd64

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl unzip tar gzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /dl
RUN mkdir -p /out/bin

# kubectl
RUN set -eu; \
    curl -fsSL -o kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl"; \
    install -m 0755 kubectl /out/bin/kubectl

# kubelogin -- ships as a zip with the binary at bin/linux_<arch>/kubelogin
RUN set -eu; \
    curl -fsSL -o kubelogin.zip "https://github.com/Azure/kubelogin/releases/download/${KUBELOGIN_VERSION}/kubelogin-linux-${TARGETARCH}.zip"; \
    unzip -q kubelogin.zip; \
    install -m 0755 "bin/linux_${TARGETARCH}/kubelogin" /out/bin/kubelogin

# helm
RUN set -eu; \
    curl -fsSL -o helm.tgz "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz"; \
    tar -xzf helm.tgz; \
    install -m 0755 "linux-${TARGETARCH}/helm" /out/bin/helm

# argocd
RUN set -eu; \
    curl -fsSL -o argocd "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-${TARGETARCH}"; \
    install -m 0755 argocd /out/bin/argocd

# stern -- asset name carries the version without the leading v
RUN set -eu; \
    v="${STERN_VERSION#v}"; \
    curl -fsSL -o stern.tgz "https://github.com/stern/stern/releases/download/${STERN_VERSION}/stern_${v}_linux_${TARGETARCH}.tar.gz"; \
    tar -xzf stern.tgz stern; \
    install -m 0755 stern /out/bin/stern

# yq (mikefarah)
RUN set -eu; \
    curl -fsSL -o yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${TARGETARCH}"; \
    install -m 0755 yq /out/bin/yq

# code-server -- installed as a tree, not a single binary
RUN set -eu; \
    mkdir -p /out/code-server; \
    curl -fsSL -o code-server.tgz "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server-${CODE_SERVER_VERSION}-linux-${TARGETARCH}.tar.gz"; \
    tar -xzf code-server.tgz -C /out/code-server --strip-components=1

# ==========================================================================
# runtime -- the image itself. Single stage: the throwaway `tools` stage above
# keeps the download archives out of it, and there is nothing else to derive.
# ==========================================================================
FROM ubuntu:${UBUNTU_VERSION} AS runtime

ARG KUBECTL_VERSION
ARG KUBELOGIN_VERSION
ARG HELM_VERSION
ARG ARGOCD_VERSION
ARG STERN_VERSION
ARG YQ_VERSION
ARG CODE_SERVER_VERSION
ARG JUPYTERLAB_VERSION
ARG NOTEBOOK_VERSION
ARG JUPYTERLAB_GIT_VERSION
ARG IPYKERNEL_VERSION
ARG PYYAML_VERSION
ARG KUBERNETES_PY_VERSION
ARG REQUESTS_VERSION
ARG EXT_YAML_VERSION
ARG EXT_K8S_VERSION

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# libnss-wrapper is here for the arbitrary-uid case: the runtime uid has no
# /etc/passwd entry, and anything that calls getpwuid() (git, ssh, some shells)
# fails on the lookup. The entrypoint LD_PRELOADs it over a writable copy of
# /etc/passwd. Everything else is workshop tooling.
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash-completion \
        ca-certificates \
        curl \
        git \
        jq \
        less \
        libnss-wrapper \
        nano \
        openssh-client \
        procps \
        python3 \
        python3-venv \
        rsync \
        tcsh \
        tree \
        unzip \
        vim \
        wget \
        zsh \
    && rm -rf /var/lib/apt/lists/*

# Kubernetes tooling and code-server, root-owned and world-executable.
COPY --from=tools --chmod=0755 /out/bin/ /usr/local/bin/
COPY --from=tools /out/code-server/ /opt/code-server/
RUN chmod -R a+rX /opt/code-server

# --------------------------------------------------------------------------
# Python. A root-owned venv at /opt/venv on PATH -- no conda, no per-user
# prefix, nothing that wants chowning. PIP_USER is forced off here as well as
# in the entrypoint so that a `pip install` inside the image can never land in
# the user's shared $HOME/.local (which Casper and Derecho also read).
# --------------------------------------------------------------------------
ENV VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:/opt/code-server/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
    PIP_USER=false \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN set -eu; \
    python3 -m venv /opt/venv; \
    /opt/venv/bin/pip install --upgrade pip setuptools wheel; \
    /opt/venv/bin/pip install \
        "jupyterlab==${JUPYTERLAB_VERSION}" \
        "notebook==${NOTEBOOK_VERSION}" \
        "jupyterlab-git==${JUPYTERLAB_GIT_VERSION}" \
        "ipykernel==${IPYKERNEL_VERSION}" \
        "pyyaml==${PYYAML_VERSION}" \
        "kubernetes==${KUBERNETES_PY_VERSION}" \
        "requests==${REQUESTS_VERSION}"; \
    /opt/venv/bin/python -m ipykernel install --prefix=/opt/venv --name python3 --display-name "Python 3 (CIRRUS)"; \
    chmod -R a+rX /opt/venv; \
    # Only needed to bootstrap the venv above, and years behind what the venv
    # ended up with (pip 24.0 / setuptools 68.1.2 vs pip 26.x / setuptools 84.x).
    # Dead weight that scanners correctly report.
    rm -rf /usr/share/python-wheels

# --------------------------------------------------------------------------
# code-server extensions, pre-installed into a system directory so nobody is
# prompted on first launch. The entrypoint seeds a writable per-session copy
# from here, so users can still add extensions of their own.
# --------------------------------------------------------------------------
ENV CIRRUS_SYS_EXTENSIONS_DIR=/opt/cirrus/code-server-extensions

RUN set -eu; \
    mkdir -p "${CIRRUS_SYS_EXTENSIONS_DIR}"; \
    /opt/code-server/bin/code-server \
        --user-data-dir /tmp/build-code-user-data \
        --extensions-dir "${CIRRUS_SYS_EXTENSIONS_DIR}" \
        --disable-telemetry --disable-update-check \
        --install-extension "redhat.vscode-yaml@${EXT_YAML_VERSION}" \
        --install-extension "ms-kubernetes-tools.vscode-kubernetes-tools@${EXT_K8S_VERSION}"; \
    rm -rf /tmp/build-code-user-data; \
    chmod -R a+rX "${CIRRUS_SYS_EXTENSIONS_DIR}"

# --------------------------------------------------------------------------
# Shell completion. Generated at build time into /etc/bash_completion.d so a
# login shell does not pay to regenerate it, and wired up (including the `k`
# alias) by /etc/profile.d/cirrus.sh.
# --------------------------------------------------------------------------
RUN set -eu; \
    mkdir -p /etc/bash_completion.d; \
    kubectl completion bash    > /etc/bash_completion.d/kubectl; \
    helm completion bash       > /etc/bash_completion.d/helm; \
    argocd completion bash     > /etc/bash_completion.d/argocd; \
    stern --completion bash    > /etc/bash_completion.d/stern; \
    chmod a+r /etc/bash_completion.d/*

RUN set -eu; \
    mkdir -p /usr/local/share/zsh/site-functions; \
    kubectl completion zsh > /usr/local/share/zsh/site-functions/_kubectl; \
    helm completion zsh    > /usr/local/share/zsh/site-functions/_helm; \
    argocd completion zsh  > /usr/local/share/zsh/site-functions/_argocd; \
    stern --completion zsh > /usr/local/share/zsh/site-functions/_stern; \
    chmod a+r /usr/local/share/zsh/site-functions/*

COPY --chmod=0644 etc/profile.d/cirrus.sh /etc/profile.d/cirrus.sh
COPY --chmod=0644 etc/profile.d/cirrus.csh /etc/profile.d/cirrus.csh

# zsh does not read /etc/profile.d at all. /etc/zsh/zshenv is read by every zsh,
# so the CIRRUS environment is sourced there (cirrus.sh is POSIX-compatible in
# everything except its bash-only completion block, which is guarded on
# BASH_VERSION), and completion is initialised for interactive shells only.
RUN set -eu; \
    mkdir -p /etc/zsh; \
    { \
      echo '# CIRRUS workshop environment'; \
      echo 'if [ -r /etc/profile.d/cirrus.sh ]; then emulate sh -c ". /etc/profile.d/cirrus.sh"; fi'; \
    } >> /etc/zsh/zshenv; \
    { \
      echo '# CIRRUS workshop: completion for the workshop tools, plus the k alias'; \
      echo 'fpath=(/usr/local/share/zsh/site-functions $fpath)'; \
      echo 'autoload -Uz compinit && compinit -u'; \
      echo 'alias k=kubectl'; \
      echo 'compdef k=kubectl'; \
    } >> /etc/zsh/zshrc

# tcsh gets the environment but not completion: kubectl and friends emit bash and
# zsh completions only, and hand-writing tcsh `complete` rules for them is a
# maintenance burden nobody asked for.
#
# /etc/csh.cshrc, not /etc/csh.login: cshrc is read by every csh invocation,
# login or not, and code-server's terminals are non-login. Wiring this into
# csh.login gave tcsh users in VS Code no CIRRUS environment at all.
RUN set -eu; \
    { \
      echo '# CIRRUS workshop environment (paths and per-session dirs)'; \
      echo 'if ( -r /etc/profile.d/cirrus.csh ) source /etc/profile.d/cirrus.csh'; \
    } >> /etc/csh.cshrc

# Jupyter and code-server terminals open interactive non-login shells, which
# read /etc/bash.bashrc and never /etc/profile.d. cirrus.sh is idempotent and
# assigns only with ${VAR:-default}, so sourcing it from both is safe.
RUN printf '\n# CIRRUS workshop environment (interactive non-login shells)\nif [ -r /etc/profile.d/cirrus.sh ]; then . /etc/profile.d/cirrus.sh; fi\n' \
      >> /etc/bash.bashrc

COPY --chmod=0755 bin/ /usr/local/bin/

# The fallback kubeconfig, so a session works with an empty GLADE home. Contains
# no per-user material -- see the header in the file itself.
COPY --chmod=0444 etc/cirrus/kubeconfig.yaml /opt/cirrus/kubeconfig.yaml

# --------------------------------------------------------------------------
# Resolved versions, recorded once at build time. cirrus-versions prints this
# file; `cirrus-versions --check` re-runs each binary and diffs against it.
# --------------------------------------------------------------------------
RUN set -eu; \
    mkdir -p /opt/cirrus/labs; \
    { \
      echo "# CIRRUS workshop image -- resolved tool versions"; \
      echo "# name<TAB>expected version"; \
      printf 'kubectl\t%s\n'      "${KUBECTL_VERSION}"; \
      printf 'kubelogin\t%s\n'    "${KUBELOGIN_VERSION}"; \
      printf 'helm\t%s\n'         "${HELM_VERSION}"; \
      printf 'argocd\t%s\n'       "${ARGOCD_VERSION}"; \
      printf 'stern\t%s\n'        "${STERN_VERSION}"; \
      printf 'yq\t%s\n'           "${YQ_VERSION}"; \
      printf 'code-server\t%s\n'  "${CODE_SERVER_VERSION}"; \
      printf 'jupyterlab\t%s\n'   "${JUPYTERLAB_VERSION}"; \
      printf 'notebook\t%s\n'     "${NOTEBOOK_VERSION}"; \
      printf 'jupyterlab-git\t%s\n' "${JUPYTERLAB_GIT_VERSION}"; \
      printf 'ipykernel\t%s\n'    "${IPYKERNEL_VERSION}"; \
      printf 'pyyaml\t%s\n'       "${PYYAML_VERSION}"; \
      printf 'kubernetes\t%s\n'   "${KUBERNETES_PY_VERSION}"; \
      printf 'requests\t%s\n'     "${REQUESTS_VERSION}"; \
      printf 'ext:redhat.vscode-yaml\t%s\n' "${EXT_YAML_VERSION}"; \
      printf 'ext:ms-kubernetes-tools.vscode-kubernetes-tools\t%s\n' "${EXT_K8S_VERSION}"; \
    } > /opt/cirrus/versions.txt; \
    lib="$(ldconfig -p | awk -F'=> ' '/libnss_wrapper/ {print $2; exit}' | tr -d ' ')"; \
    if [ -z "$lib" ] || [ ! -r "$lib" ]; then \
        lib="$(find /usr/lib /lib -name 'libnss_wrapper.so*' -print -quit 2>/dev/null)"; \
    fi; \
    test -n "$lib" && test -r "$lib"; \
    echo "$lib" > /opt/cirrus/nss_wrapper_lib; \
    chmod -R a+rX /opt/cirrus

# --------------------------------------------------------------------------
# Runtime defaults.
# --------------------------------------------------------------------------
# Defaults exist so the image runs standalone for local testing and CI. In the
# OOD path submit.yml.erb overrides them; pod-spec env is inherited by the
# entrypoint and every process it spawns.
#
# CIRRUS_PORT     8080 matches the fixed containerPort/NodePort of the existing
#                 CIRRUS OOD apps.
# CIRRUS_BASE_URL "/" is correct behind OOD's /rnode/ proxy, which strips the
#                 prefix. Jupyter is served through /node/, which does not, so
#                 the erb's init container computes /node/<host>/<nodePort>/
#                 and passes it in here.
# KUBECONFIG      the session's working copy, mutated freely. Never the user's.
#
# CIRRUS_KUBECONFIG_SRC is deliberately not set: it defaults to
# $HOME/.kube/config, and $HOME is only known at runtime.
# CIRRUS_BASE_URL is deliberately NOT set here. The entrypoint defaults it to "/"
# on its own, and an ENV value of "/" is indistinguishable from an operator saying
# "serve at the root" -- which suppressed CIRRUS_BASE_URL_FILE entirely and left
# Jupyter serving at / behind a /node/ proxy, i.e. a blank page.
ENV CIRRUS_PORT=8080 \
    CIRRUS_STATE_DIR=/tmp/cirrus \
    KUBECONFIG=/tmp/cirrus/kube/config \
    CIRRUS_JUPYTER_AUTH=none

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["jupyter"]
