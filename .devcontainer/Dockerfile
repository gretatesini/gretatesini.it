# [vscode-dev-setup:START]
ARG DEVCONTAINER_VERSION=trixie
ARG UV_VERSION=latest
ARG NODE_VERSION=24

FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv-src
FROM node:${NODE_VERSION}-slim AS node-src

# ── Base stage: OS packages + language runtimes ───────────────────────────────
FROM mcr.microsoft.com/devcontainers/base:${DEVCONTAINER_VERSION} AS base

USER root

# Docker BuildKit populates TARGETARCH (amd64|arm64) and TARGETOS (linux) at build time
ARG TARGETARCH=arm64
ARG TARGETOS=linux

RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    curl \
    jq \
    just \
    git \
    cmake \
    build-essential \
    pkg-config \
    ccache \
    htop \
    sysstat \
    procps \
    pciutils \
    hyperfine \
    unzip \
    && wget -qO /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/latest/download/yq_${TARGETOS}_${TARGETARCH}" \
    && chmod +x /usr/local/bin/yq \
    && rm -rf /var/lib/apt/lists/*

ARG PYTHON_VERSION=3.13
# Install interpreters under /opt, not /root: /root is mode 700, so symlinks
# resolving into it (venvs, /usr/local/bin/python3) break for non-root users
# at runtime with "Permission denied". Scoped to this RUN (not ENV) so that
# runtime `uv python install` by devuser falls back to its writable home.
COPY --from=uv-src --chown=root: /uv /uvx /bin/
RUN export UV_PYTHON_INSTALL_DIR=/opt/uv/python \
    && uv python install "${PYTHON_VERSION}" \
    && chmod -R a+rX /opt/uv/python \
    && ln -sf $(uv python find "${PYTHON_VERSION}") /usr/local/bin/python3 \
    && ln -sf /usr/local/bin/python3 /usr/local/bin/python

COPY --from=node-src /usr/local/bin/node /usr/local/bin/node
COPY --from=node-src /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -sf /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
    && ln -sf /usr/local/lib/node_modules/corepack/dist/corepack.js /usr/local/bin/corepack

# ── Tools stage: optional ARG-gated tools ────────────────────────────────────
FROM base AS tools

USER root

# Redeclare platform args each stage has its own scope in Docker BuildKit
ARG TARGETARCH=arm64
ARG TARGETOS=linux

## [TOOLS] Enable or disable tools with build args
ARG CLAUDE_CLI_ENABLE=false
ARG OPENCODE_ENABLE=false
ARG OPENSPEC_ENABLE=false
ARG AWS_CLI_ENABLE=false
ARG GITHUB_COPILOT_CLI_ENABLE=false
ARG GH_CLI_ENABLE=false
ARG KIND_ENABLE=false
ARG LLAMA_CPP_ENABLE=false
ARG TERRAFORM_ENABLE=false
ARG TERRAFORM_VERSION=1.14.8

ENV CLAUDE_CLI_ENABLE=${CLAUDE_CLI_ENABLE}
ENV GITHUB_COPILOT_CLI_ENABLE=${GITHUB_COPILOT_CLI_ENABLE}
ENV OPENCODE_ENABLE=${OPENCODE_ENABLE}
ENV OPENSPEC_ENABLE=${OPENSPEC_ENABLE}
ENV AWS_CLI_ENABLE=${AWS_CLI_ENABLE}
ENV GH_CLI_ENABLE=${GH_CLI_ENABLE}
ENV KIND_ENABLE=${KIND_ENABLE}
ENV LLAMA_CPP_ENABLE=${LLAMA_CPP_ENABLE}
ENV TERRAFORM_ENABLE=${TERRAFORM_ENABLE}
ENV TFENV_ROOT=/opt/tfenv

# [INSTALL] GitHub CLI
RUN if [ "$GH_CLI_ENABLE" = "true" ]; then \
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
        && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
            | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
        && apt-get update \
        && apt-get install -y --no-install-recommends gh \
        && rm -rf /var/lib/apt/lists/*; \
    fi
# ---

# [INSTALL] AWS CLI
# TARGETARCH amd64→x86_64, arm64→aarch64
RUN if [ "$AWS_CLI_ENABLE" = "true" ]; then \
        case "${TARGETARCH}" in \
            amd64)  AWS_ARCH="x86_64" ;; \
            arm64)  AWS_ARCH="aarch64" ;; \
            *)      echo "[ERROR] Unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
        esac && \
        curl -fsSL "https://awscli.amazonaws.com/awscli-exe-${TARGETOS}-${AWS_ARCH}.zip" \
            -o /tmp/awscliv2.zip \
        && unzip -q /tmp/awscliv2.zip -d /tmp/awscli \
        && /tmp/awscli/aws/install \
        && rm -rf /tmp/awscliv2.zip /tmp/awscli; \
    fi
# ---

# [INSTALL] Claude CLI
# The installer targets $HOME (/root, mode 700): relocate to /opt and expose
# via /usr/local/bin so the runtime non-root user can execute it.
RUN if [ "$CLAUDE_CLI_ENABLE" = "true" ]; then \
        for i in 1 2 3; do \
            curl -fsSL https://claude.ai/install.sh | bash && break; \
            echo "[WARN] Claude CLI install attempt ${i}/3 failed, retrying in 10s..."; \
            sleep 10; \
        done; \
        if [ -e /root/.local/bin/claude ]; then \
            mkdir -p /opt/claude \
            && CLAUDE_VERSION_BIN="$(readlink -f /root/.local/bin/claude)" \
            && mv /root/.local/share/claude /opt/claude/share \
            && ln -sf "/opt/claude/share/versions/$(basename "${CLAUDE_VERSION_BIN}")" /usr/local/bin/claude \
            && chmod -R a+rX /opt/claude \
            && rm -f /root/.local/bin/claude \
            && claude --version; \
        else \
            echo "[WARN] Claude CLI not installed after 3 attempts"; \
        fi; \
    fi
# ---

# [INSTALL] GitHub Copilot CLI
RUN if [ "$GITHUB_COPILOT_CLI_ENABLE" = "true" ]; then \
        for i in 1 2 3; do \
            curl -fsSL https://gh.io/copilot-install | bash && break; \
            echo "[WARN] Copilot CLI install attempt ${i}/3 failed, retrying in 10s..."; \
            sleep 10; \
        done; \
        command -v copilot >/dev/null 2>&1 \
            || echo "[WARN] Copilot CLI not installed after 3 attempts"; \
    fi
# ---

# [INSTALL] OpenCode
# The installer hardcodes $HOME/.opencode/bin: move the binary to
# /usr/local/bin so the runtime non-root user can execute it.
RUN if [ "$OPENCODE_ENABLE" = "true" ]; then \
        for i in 1 2 3; do \
            curl -fsSL https://opencode.ai/install | bash && break; \
            echo "[WARN] OpenCode install attempt ${i}/3 failed, retrying in 10s..."; \
            sleep 10; \
        done; \
        if [ -e /root/.opencode/bin/opencode ]; then \
            mv /root/.opencode/bin/opencode /usr/local/bin/opencode \
            && chmod 755 /usr/local/bin/opencode \
            && opencode --version; \
        else \
            echo "[WARN] OpenCode not installed after 3 attempts"; \
        fi; \
    fi
# ---

# [INSTALL] OpenSpec
ARG OPENSPEC_VERSION=latest
RUN if [ "$OPENSPEC_ENABLE" = "true" ]; then \
        npm install -g @fission-ai/openspec@${OPENSPEC_VERSION}; \
    fi
# ---

# [INSTALL] Kind
# TARGETARCH matches Kind's naming directly (amd64, arm64)
ARG KIND_VERSION="v0.31.0"
RUN if [ "$KIND_ENABLE" = "true" ]; then \
        apt-get update && apt-get install -y --no-install-recommends kubectx \
        && curl -fsSL \
            "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${TARGETOS}-${TARGETARCH}" \
            -o /usr/local/bin/kind \
        && chmod +x /usr/local/bin/kind \
        && rm -rf /var/lib/apt/lists/*; \
    fi
# ---

# [INSTALL] LLaMA.cpp
ARG LLAMA_CPP_HOME=/opt/llama.cpp
ARG LLAMA_CPP_REF=master
# Paths must live in the runtime user's home (mounted volume), not /root
ARG LLAMA_ROOT=/home/devuser/.llama
ARG LLAMA_CACHE=/home/devuser/.llama/cache
ARG LLAMA_MODELS=/home/devuser/.llama/models

ENV LLAMA_ROOT=${LLAMA_ROOT}
ENV LLAMA_CACHE=${LLAMA_CACHE}
ENV LLAMA_MODELS=${LLAMA_MODELS}

RUN if [ "$LLAMA_CPP_ENABLE" = "true" ]; then \
        git clone --depth 1 --branch "${LLAMA_CPP_REF}" \
            https://github.com/ggml-org/llama.cpp "${LLAMA_CPP_HOME}" \
        && cmake -S "${LLAMA_CPP_HOME}" -B "${LLAMA_CPP_HOME}/build" \
            -DBUILD_SHARED_LIBS=OFF -DGGML_CUDA=OFF \
        && cmake --build "${LLAMA_CPP_HOME}/build" --config Release \
            -j"$(nproc)" --target llama-cli llama-server \
        && ln -sf "${LLAMA_CPP_HOME}/build/bin/llama-cli" /usr/local/bin/llama-cli \
        && ln -sf "${LLAMA_CPP_HOME}/build/bin/llama-server" /usr/local/bin/llama-server \
        && mkdir -p "${LLAMA_ROOT}" "${LLAMA_CACHE}" "${LLAMA_MODELS}"; \
    fi
# ---

# [INSTALL] Terraform (via tfenv — allows switching versions inside the container)
RUN if [ "$TERRAFORM_ENABLE" = "true" ]; then \
        git clone --depth=1 https://github.com/tfutils/tfenv.git "${TFENV_ROOT}" \
        && ln -sf "${TFENV_ROOT}/bin/tfenv"     /usr/local/bin/tfenv \
        && ln -sf "${TFENV_ROOT}/bin/terraform" /usr/local/bin/terraform \
        && tfenv install "${TERRAFORM_VERSION}" \
        && tfenv use     "${TERRAFORM_VERSION}"; \
    fi
# ---

# [USER] Create devuser with host-matching UID/GID and passwordless sudo
ARG USER_NAME=devuser
ARG USER_GROUP=devuser
ARG USER_UID=1000
ARG USER_GID=1000

RUN set -eux; \
    existing_group="$(getent group "${USER_GID}" | cut -d: -f1 || true)"; \
    if [ -z "${existing_group}" ]; then \
        groupadd -g "${USER_GID}" devuser; \
    elif [ "${existing_group}" != "${USER_GROUP}" ]; then \
        groupmod -n "${USER_GROUP}" "${existing_group}"; \
    fi; \
    existing_user="$(getent passwd "${USER_UID}" | cut -d: -f1 || true)"; \
    if [ -z "${existing_user}" ]; then \
        useradd -u "${USER_UID}" -g "${USER_GID}" -m -s /bin/zsh "${USER_NAME}"; \
    elif [ "${existing_user}" != "${USER_NAME}" ]; then \
        usermod -l "${USER_NAME}" -g "${USER_GID}" -d /home/"${USER_NAME}" -m "${existing_user}"; \
    fi; \
    usermod -s /bin/zsh "${USER_NAME}"; \
    echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/"${USER_NAME}"; \
    chmod 0440 /etc/sudoers.d/"${USER_NAME}"; \
    chown -R "${USER_NAME}":"${USER_GROUP}" /home/"${USER_NAME}"; \
    mkdir -p /usr/local/lib/node_modules; \
    chown -R "${USER_NAME}":"${USER_GROUP}" /usr/local/lib/node_modules; \
    chown -R "${USER_NAME}":"${USER_GROUP}" /usr/local/bin; \
    if [ -d "${TFENV_ROOT}" ]; then \
        chown -R "${USER_NAME}":"${USER_GROUP}" "${TFENV_ROOT}"; \
    fi

ENV PATH=/home/"${USER_NAME}"/.local/bin:$PATH
# ---
# [vscode-dev-setup:END]

# ── Walle stage: design system tooling ───────────────────────────────────────
FROM tools AS vscode

USER root

COPY --from=ghcr.io/opentofu/opentofu:minimal /usr/local/bin/tofu /usr/local/bin/tofu

WORKDIR /workspace
