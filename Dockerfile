# ══════════════════════════════════════════════════════════════
#  MewClaw — Seed Image
#  Based on Debian Bookworm
# ══════════════════════════════════════════════════════════════

FROM debian:bookworm-slim

LABEL maintainer="0xgosu@gmail.com"
LABEL description="MewClaw is a lightweight alternative to OpenClaw that runs in containers for security. Has long-term memory, scheduled jobs, credentials store, interactive Web UI Portal. Connects to Telegram, Gmail and other messaging apps. It's powered by Anthropic's Agents SDK (require Claude Code Subscription) and can self-evolve to serve you better."
LABEL version="1.0.0"

# ── Build arguments ────────────────────────────────────────
ARG AGENT_DNA=v1/base

# ── Avoid interactive prompts during build ───────────────────
ENV DEBIAN_FRONTEND=noninteractive

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

# ── Create non-root agent user ────────────────────────────────
# --dangerously-skip-permissions requires a non-root user.
# Grant passwordless sudo so the agent can still install packages.
RUN useradd -m -s /bin/bash agent \
    && echo "agent ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agent \
    && chmod 0440 /etc/sudoers.d/agent

# ── Agent directory structure ────────────────────────────────
# This is the agent's "body" — each directory is an organ.
RUN mkdir -p \
    /agent/memory/logs \
    /agent/messages \
    /agent/web \
    /agent/workspace \
    /agent/prompts \
    /agent/.claude \
    /agent/.streamlit \
    /home/agent/.keepass \
    /home/agent/.ssh \
    && chown -R agent:agent /agent \
    && chown -R agent:agent /home/agent/.keepass \
    && chown agent:agent /home/agent/.ssh \
    && chmod 700 /home/agent/.ssh

# ── Switch to agent user for CLI install & runtime ────────────
USER agent
WORKDIR /agent

# ── Install Node.js 22 ────────────────────────────────────────
# Required for agent-browser CLI and used by various skills/scripts.
RUN sudo apt-get update \
    && sudo apt-get install -y --no-install-recommends gnupg \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash - \
    && sudo apt-get install -y --no-install-recommends nodejs \
    && sudo rm -rf /var/lib/apt/lists/* \
    && node --version && npm --version

# ── Install uv (fast Python package manager) ─────────────────
# The agent manages Python deps via /agent/pyproject.toml.
# uv is written in Rust — installs packages in seconds.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# ── Install agent-browser, Google Cloud CLI, Google Workspace CLI ──
# All bundled in a single seed script for cleaner caching.
COPY --chown=agent:agent ${AGENT_DNA}/seed/ /tmp/seed/
RUN chmod +x /tmp/seed/*.sh && /tmp/seed/install.sh && rm -rf /tmp/seed/ \
    && sudo rm -rf /var/lib/apt/lists/* \
    && npm cache clean --force 2>/dev/null || true
ENV PATH="/opt/google-cloud-sdk/bin:${PATH}"

# ── Copy pyproject.toml & sync dependencies ──────────────────
COPY --chown=agent:agent ${AGENT_DNA}/pyproject.toml /agent/pyproject.toml
RUN cd /agent && uv sync

# ── Install AI coding agent CLI (Claude Code — default backend) ──
# The installer may place the binary at ~/.claude/bin or ~/.local/bin
# depending on the version. We cover both and verify the result.
# Timeout prevents the known hang bug on minimal images (GH #5209).
RUN timeout 120 bash -c 'curl -fsSL https://claude.ai/install.sh | bash' \
    || true

# Locate the binary and ensure it is on PATH
# The installer has used different locations across versions.
ENV PATH="/home/agent/.claude/bin:/home/agent/.local/bin:${PATH}"

# Fail the build early if claude didn't actually install
RUN claude --version

# ── Copy claude-code config ──────────────────────────────────
COPY --chown=agent:agent claude-code/.claude.json   /home/agent/.claude.json
COPY --chown=agent:agent claude-code/claude-system-prompt.md /tmp/claude-system-prompt.md

# ── Copy agent files (last COPY for cache optimisation) ──────
COPY --chown=agent:agent Dockerfile      /agent/Dockerfile
COPY --chown=agent:agent ${AGENT_DNA}/            /agent/
RUN cat /tmp/claude-system-prompt.md >> /agent/system.md && rm /tmp/claude-system-prompt.md

# ── Symlink Claude Code auto-memory to agent memory dir ────
RUN mkdir -p /home/agent/.claude/projects/-agent \
    && ln -s /agent/memory /home/agent/.claude/projects/-agent/memory

# ── Generate seed .md memory files from JSON data ─────────────
RUN cd /agent && uv run python scripts/memory-sync.py

# ── Set permissions, init message queues, init git ────────────
RUN chmod +x /agent/bootstrap.sh /agent/heartbeat.sh /agent/agent.sh /agent/scripts/*.sh \
    && chmod 444 /agent/constitution.md \
    && echo '[]' > /agent/messages/inbox.json \
    && echo '[]' > /agent/messages/outbox.json \
    && ln -s /agent/skills /agent/.claude/skills \
    && ln -s /agent/AGENTS.md /agent/.claude/CLAUDE.md

# ── Expose port range ──────────────────────────────────────────
# 8080 = Caddy gateway
EXPOSE 8080

# ── Bootstrap is the entrypoint ──────────────────────────────
ENTRYPOINT ["/agent/bootstrap.sh"]
