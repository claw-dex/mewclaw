# ══════════════════════════════════════════════════════════════
#  MewClaw — Seed Image
#  Based on Debian Bookworm
# ══════════════════════════════════════════════════════════════

FROM debian:bookworm-slim

LABEL maintainer="0xgosu@gmail.com"
LABEL description="MewClaw is a lightweight alternative to OpenClaw that runs in containers for security. Has long-term memory, scheduled jobs, credentials store, interactive Web UI Portal. Connects to Telegram, Gmail and other messaging apps. It's powered by Anthropic's Agents SDK (require Claude Code Subscription) and can self-evolve to serve you better."
LABEL version="1.0.0"

# ── Build arguments ────────────────────────────────────────
ARG AGENT_DNA

# ── Avoid interactive prompts during build ───────────────────
ARG DEBIAN_FRONTEND=noninteractive

# ── System packages ──────────────────────────────────────────
# Core utilities the agent needs from birth.
# The agent can install more packages as it evolves — they'll
# persist across heartbeats and survive docker commit snapshots.
# Note: grep/sed are already in bookworm-slim base.
# Note: python3-pip/python3-venv omitted — uv handles both.
# Note: gnupg is installed with Node.js below (needed for apt keys).
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Essential tools
    curl \
    ca-certificates \
    git \
    jq \
    openssh-client \
    # Process & network diagnostics (for self-heal)
    procps \
    net-tools \
    # Python (for web server + agent workspace)
    python3 \
    # Text processing (useful for the agent)
    gawk \
    # File utilities
    unzip \
    less \
    tree \
    # Sudo (so agent user can install packages during evolution)
    sudo \
    # C build tools (required by Rust linker and native extensions)
    build-essential \
    # Headless Chromium dependencies (for agent-browser)
    libnss3 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libdrm2 \
    libxkbcommon0 \
    libxcomposite1 \
    libxdamage1 \
    libxrandr2 \
    libgbm1 \
    libpango-1.0-0 \
    libcairo2 \
    libasound2 \
    libxshmfence1 \
    libx11-xcb1 \
    fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

# ── Caddy binary (gateway) ─────────────────────────────────────
COPY --from=caddy:2-alpine /usr/bin/caddy /usr/bin/caddy

# ── Install Node.js 22 ────────────────────────────────────────
# Required for agent-browser CLI and used by various skills/scripts.
RUN apt-get update \
    && apt-get install -y --no-install-recommends gnupg \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && node --version && npm --version

# ── Install uv (fast Python package manager) ─────────────────
# The agent manages Python deps via /agent/pyproject.toml.
# uv is written in Rust — installs packages in seconds.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# ── Create non-root agent user ────────────────────────────────
# --dangerously-skip-permissions requires a non-root user.
# Grant passwordless sudo so the agent can still install packages.
RUN useradd -m -s /bin/bash agent \
    && echo "agent ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agent \
    && chmod 0440 /etc/sudoers.d/agent

# ── Create /agent directory with proper ownership ─────────────
RUN mkdir -p /agent && chown -R agent:agent /agent

# ── Switch to agent user for git clone & runtime ──────────────
USER agent

# ── Clone agent DNA repository ────────────────────────────────
# Clone the agent DNA from the source repository, then later COPY
# commands will override files with local uncommitted changes for
# development and testing.
RUN git config --global user.email "bot@0xgosu.dev" \
    && git config --global user.name "MewClaw-Agent" \
    && git clone --branch ${AGENT_DNA} --single-branch --depth=1 \
       https://github.com/claw-dex/claw-dna.git /agent

WORKDIR /agent

# ── Create additional agent directories ───────────────────────
# Ensure required directories exist (some may not be in the DNA repo).
RUN mkdir -p \
    /agent/memory/logs \
    /agent/messages \
    /agent/web \
    /agent/workspace \
    /agent/prompts \
    /agent/.claude \
    /agent/.streamlit \
    /home/agent/.config \
    /home/agent/.keepass \
    /home/agent/.ssh \
    && chmod 700 /home/agent/.ssh

# ── Install agent-browser, Google Cloud CLI, Google Workspace CLI ──
# All bundled in a single seed script for cleaner caching.
# agent user has passwordless sudo for system-level installs.
COPY --chown=agent:agent ${AGENT_DNA}/seed/ /agent/seed/
RUN chmod +x /agent/seed/*.sh && sudo /agent/seed/install.sh \
    && sudo rm -rf /var/lib/apt/lists/* \
    && sudo npm cache clean --force 2>/dev/null
ENV PATH="/opt/google-cloud-sdk/bin:${PATH}"

# ── Copy pyproject.toml & sync dependencies ──────────────────
COPY --chown=agent:agent ${AGENT_DNA}/pyproject.toml /agent/pyproject.toml
RUN cd /agent && uv sync

# ── Install AI coding agent CLI (Claude Code — default backend) ──
# The installer may place the binary at ~/.claude/bin or ~/.local/bin
# depending on the version. We cover both and verify the result.
# Timeout prevents the known hang bug on minimal images (GH #5209).
RUN timeout 120 bash -c 'curl -fsSL https://claude.ai/install.sh | bash'

# Locate the binary and ensure it is on PATH
# The installer has used different locations across versions.
ENV PATH="/home/agent/.claude/bin:/home/agent/.local/bin:${PATH}"

# Fail the build early if claude didn't actually install
RUN claude --version

# ── Copy claude-code config ──────────────────────────────────
COPY --chown=agent:agent claude-code/.claude.json   /home/agent/.claude.json
COPY --chown=agent:agent claude-code/claude-system-prompt.md /home/agent/claude-system-prompt.md

# ── Override with local changes for development ──────────────
# These COPY commands override the cloned DNA files with local
# uncommitted changes, allowing development and testing.
COPY --chown=agent:agent Dockerfile      /agent/Dockerfile
COPY --chown=agent:agent ${AGENT_DNA}/            /agent/

# ── Generate seed .md memory files from JSON data ─────────────
RUN cd /agent && uv run python scripts/memory_sync.py

# ── Set permissions, init message queues, link files ────────────
RUN chmod +x /agent/bootstrap.sh /agent/heartbeat.sh /agent/agent.sh /agent/scripts/*.sh \
    && chmod 444 /agent/constitution.md \
    && echo '[]' > /agent/messages/inbox.json \
    && echo '[]' > /agent/messages/outbox.json \
    && ln -s /agent/skills /agent/.claude/skills \
    && ln -s /agent/AGENTS.md /agent/.claude/CLAUDE.md

# ── Health check ─────────────────────────────────────────
# Caddy listens on :8080 — probe the root endpoint.
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -fs http://localhost:8080/ || exit 1

# ── Expose port ──────────────────────────────────────────
# 8080 = Caddy gateway
EXPOSE 8080

# ── Bootstrap is the entrypoint ──────────────────────────────
ENTRYPOINT ["/agent/bootstrap.sh"]
