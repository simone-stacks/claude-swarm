ARG DEBIAN_IMAGE=debian:trixie-slim@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258
FROM ${DEBIAN_IMAGE}

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    clang \
    make \
    jq \
    sudo \
    unzip \
    xz-utils \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Claude Code refuses --dangerously-skip-permissions as root.
RUN useradd -m -s /bin/bash agent \
    && echo "agent ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agent
USER agent

# Language toolchains are installed by SWARM_SETUP, not here.

# Comma-separated list of drivers whose CLIs should be installed.
# launch.sh derives this from the config and passes it as --build-arg.
ARG SWARM_AGENTS=claude-code

# --- Claude Code CLI (default) ---
ARG CLAUDE_CODE_VERSION
ARG CLAUDE_INSTALL_SHA256
RUN if echo ",$SWARM_AGENTS," | grep -q ",claude-code,"; then \
        curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh \
        && echo "${CLAUDE_INSTALL_SHA256}  /tmp/claude-install.sh" | sha256sum -c - \
        && bash /tmp/claude-install.sh "$CLAUDE_CODE_VERSION" \
        && rm /tmp/claude-install.sh; \
    fi
ENV PATH="/home/agent/.local/bin:${PATH}"

# --- Node.js (shared by Gemini CLI and Codex CLI) ---
USER root
ARG TARGETARCH
ARG NODE_VERSION
ARG NODE_SHA256_AMD64
ARG NODE_SHA256_ARM64
RUN if echo ",$SWARM_AGENTS," | grep -qE ",(gemini-cli|codex-cli),"; then \
        case "$TARGETARCH" in \
          amd64) node_arch=x64; node_sha="$NODE_SHA256_AMD64" ;; \
          arm64) node_arch=arm64; node_sha="$NODE_SHA256_ARM64" ;; \
          *) echo "unsupported Node architecture: $TARGETARCH" >&2; exit 1 ;; \
        esac \
        && node_file="node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" \
        && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/${node_file}" -o "/tmp/${node_file}" \
        && echo "${node_sha}  /tmp/${node_file}" | sha256sum -c - \
        && tar -xJf "/tmp/${node_file}" -C /usr/local --strip-components=1 \
        && rm "/tmp/${node_file}"; \
    fi

# --- Gemini CLI ---
ARG GEMINI_CLI_VERSION
RUN if echo ",$SWARM_AGENTS," | grep -q ",gemini-cli,"; then \
        npm install -g "@google/gemini-cli@${GEMINI_CLI_VERSION}"; \
    fi

# --- Codex CLI ---
ARG CODEX_CLI_VERSION
RUN if echo ",$SWARM_AGENTS," | grep -q ",codex-cli,"; then \
        npm install -g "@openai/codex@${CODEX_CLI_VERSION}" \
        && mkdir -p /home/agent/.codex \
        && chown agent:agent /home/agent/.codex; \
    fi

# --- Kimi Code CLI ---
ARG KIMI_CLI_VERSION
ARG KIMI_INSTALL_SHA256
# Installs to /usr/local/bin so the agent user finds kimi on PATH
# without the script editing anyone's shell rc.
RUN if echo ",$SWARM_AGENTS," | grep -q ",kimi-cli,"; then \
        curl -fsSL https://code.kimi.com/kimi-code/install.sh -o /tmp/kimi-install.sh \
        && echo "${KIMI_INSTALL_SHA256}  /tmp/kimi-install.sh" | sha256sum -c - \
        && KIMI_INSTALL_DIR=/usr/local KIMI_NO_MODIFY_PATH=1 \
           KIMI_VERSION="$KIMI_CLI_VERSION" bash /tmp/kimi-install.sh \
        && rm /tmp/kimi-install.sh; \
    fi

# --- Qwen Code CLI (version and installer hash pinned by versions.env) ---
ARG QWEN_CLI_VERSION
ARG QWEN_INSTALL_SHA256
# Official standalone archive (no Node required).  Installs to
# /usr/local/bin so the agent user finds qwen on PATH without the
# script editing anyone's shell rc. The version is mandatory and pinned.
RUN if echo ",$SWARM_AGENTS," | grep -q ",qwen-cli,"; then \
        curl -fsSL https://qwen-code-assets.oss-cn-hangzhou.aliyuncs.com/installation/install-qwen-standalone.sh -o /tmp/qwen-install.sh \
        && echo "${QWEN_INSTALL_SHA256}  /tmp/qwen-install.sh" | sha256sum -c - \
        && QWEN_INSTALL_ROOT=/usr/local QWEN_NO_MODIFY_PATH=1 \
           QWEN_INSTALL_METHOD=standalone \
           QWEN_INSTALL_VERSION="${QWEN_CLI_VERSION}" \
           bash /tmp/qwen-install.sh \
        && rm /tmp/qwen-install.sh; \
    fi
USER agent

# Trust mounted bare repos and allow file:// transport for submodules.
RUN git config --global --add safe.directory '*' \
    && git config --global protocol.file.allow always

COPY --chmod=755 lib/harness.sh /harness.sh
COPY --chmod=755 lib/interactive.sh /interactive.sh
COPY --chmod=644 lib/upstream-clone.sh /upstream-clone.sh
COPY --chmod=755 lib/signing.sh /signing.sh
COPY --chmod=755 lib/activity-filter.sh /activity-filter.sh
COPY --chmod=644 lib/agent-system-prompt.md /agent-system-prompt.md
COPY --chmod=644 VERSION /swarm-version
COPY --chmod=755 lib/drivers/ /drivers/

WORKDIR /workspace

ENTRYPOINT ["/harness.sh"]
