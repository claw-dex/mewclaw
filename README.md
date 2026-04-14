# MewClaw

MewClaw is a lightweight alternative to OpenClaw that runs in containers for security. Has long-term memory, scheduled jobs, credentials store, interactive Web UI Portal. Connects to Telegram, Gmail and other messaging apps. It's powered by Anthropic's Agents SDK (require Claude Code Subscription) and can self-evolve to serve you better.

## Architecture

```
┌─────────────────────────────────────────┐
│  Agent Container (always running)       │
│                                         │
│  PID 1: bootstrap.sh (process manager)  │
│    ├── Caddy (port 8080, gateway)       │
│    └── Streamlit (port 8081, /app/)     │
│                                         │
│  Heartbeat (docker exec, ephemeral):    │
│    - Claude Code CLI in YOLO mode       │
│    - Reads memory → works → writes state│
│    - Exits after each cycle             │
│                                         │
│  Filesystem (persists across cycles):   │
│    /agent/ — memory, web, workspace     │
└─────────────────────────────────────────┘
         ▲                    ▲
         │ docker exec        │ docker commit
         │ (every 15 min)     │ (every 8 hrs)
    ┌────┴────────────────────┴────┐
    │  orchestrator.sh (on host)   │
    └──────────────────────────────┘
```

## Quick Start

### Available agents

| Image | Port | Description |
|-------|------|-------------|
| `ghcr.io/claw-dex/codasst:latest` | 8080 | Coding assistant — reviews code, writes features, manages GitHub PRs |
| `ghcr.io/claw-dex/engagius:latest` | 8180 | Marketing agent — creates content, tracks campaigns, manages outreach |
| `ghcr.io/claw-dex/proximate:latest` | 8280 | Personal assistant — manages calendar, email, tasks, and daily briefings |
| `ghcr.io/claw-dex/base:latest` | 8xxx | Generic agent — customizable for various tasks |

### 1. Start an agent

Pick the agent you want to run and start it with `docker run`:

```bash
# Coding assistant
docker run -d --name myagent -p 8080:8080 \
  ghcr.io/claw-dex/codasst:latest

# Marketing agent
docker run -d --name myagent2 -p 8180:8180 \
  ghcr.io/claw-dex/engagius:latest

# Personal assistant
docker run -d --name myagent3 -p 8280:8280 \
  ghcr.io/claw-dex/proximate:latest

# Generic agent
docker run -d --name myagent -p 8080:8080 \
  ghcr.io/claw-dex/base:latest
```

Check the logs:

```bash
docker logs -f myagent
```

### 2. Authenticate Claude Code

Choose one of the following options:

**Option A — Interactive login (default)**

```bash
docker exec -it myagent claude
```

Complete the authentication flow, then exit (`/exit`). The bootstrap detects the auth automatically — no restart needed.

**Option B — OAuth token via environment variable**

Pass a Claude OAuth token at startup to skip the interactive flow entirely:

```bash
docker run -d --name myagent -p 8080:8080 \
  -e CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-xxxxxx \
  ghcr.io/claw-dex/codasst:latest
```

**Option C — Mount local credentials (reuse host auth)**

If you are already authenticated on the host, mount the credential file so the container reuses it without any additional login:

```bash
docker run -d --name myagent -p 8080:8080 \
  -v ~/.claude/.credentials.json:/home/agent/.claude/.credentials.json:ro \
  ghcr.io/claw-dex/codasst:latest
```

> **Tip:** Ports 8080 / 8180 / 8280 is used for the web portal of the agent. Different ports are used to allow running multiple agents simultaneously without conflicts.

### 3. Open the web portal

| Agent | URL |
|-------|-----|
| codasst | <http://localhost:8080/> |
| engagius | <http://localhost:8180/> |
| proximate | <http://localhost:8280/> |

### 4. Start automatic heartbeats

```bash
./orchestrator.sh  # use container name "myagent" as default
./orchestrator.sh --container myagent2  # specify container name if running multiple agents
```

## Development

For local development — building images from source and running with live bind mounts.

### 1. Initialize submodules

```bash
git submodule update --init --recursive
```

### 2. Build and start all agents

```bash
docker compose build
docker compose up -d
```

### 3. Watch logs

```bash
docker compose logs -f
# or for a specific agent:
docker compose logs -f codasst
```

### 4. Authenticate Claude Code

```bash
docker exec -it mewclaw-codasst claude
```

### 5. Rebuild a single agent after changes

```bash
docker compose build codasst
docker compose up -d codasst
```

### Tear down

```bash
docker compose down       # stop & remove containers
docker compose down -v    # also wipe named volumes (credentials, config)
```

## Start in background

```bash
nohup ./orchestrator.sh > output.log 2>&1 & echo $! > orchestrator.pid
# with custom arguments:
nohup ./orchestrator.sh --agent-sleep > output.log 2>&1 & echo $! > orchestrator.pid
```

To stop:

```bash
kill $(cat orchestrator.pid)
```

## Orchestrator Options

```bash
./orchestrator.sh                          # defaults: 15min heartbeat, 8hr snapshot
./orchestrator.sh --interval 60            # heartbeat every 60 seconds
./orchestrator.sh --snapshot-interval 7200 # snapshot every 2 hours
./orchestrator.sh --snapshot               # manual snapshot now
./orchestrator.sh --agent-sleep            # enable sleep mode (skips cycles between 00-08 unless inbox has pending items)
```

## Cloudflare Tunnel (External Access)

To expose the portal publicly, set up a Cloudflare Tunnel so the agent is reachable at a custom domain.

### 1. Install cloudflared

On Debian/Ubuntu:

```bash
bash scripts/installer/install_cloudflared_debian.sh
```

Otherwise install from the [Cloudflare downloads page](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/).

### 2. Run the tunnel setup script

```bash
bash scripts/setup_cloudflare_tunnel.sh
```

The script will:
1. Verify `cloudflared` is installed
2. Log you in to Cloudflare (opens a browser)
3. Prompt for a tunnel name and create it
4. Prompt for a hostname (e.g. `agent.example.com`) and generate `cloudflared/config.yml`
5. Route DNS for the hostname to the tunnel

### 3. Start the tunnel

```bash
# Manually
cloudflared tunnel --config cloudflared/config.yml run

# As a systemd service
sudo mkdir -p /etc/cloudflared/
sudo cp cloudflared/config.yml /etc/cloudflared/config.yml
sudo cloudflared service install
sudo systemctl start cloudflared
```

### 4. Configure the portal hostname

Once the tunnel is running, tell the agent its public URL so it uses it in links and the system prompt.

**Via the web portal (recommended):** Open the **System** tab → expand **Run Script** → select `portal_config.py` → set subcommand to `hostname` → enter your URL in `--set` → click Run.

**Via CLI:**

```bash
docker exec myagent bash -c \
  'uv run python scripts/portal_config.py hostname --set https://agent.example.com'
```

> The hostname is stored in `/agent/memory/portal_config.json` and injected into the agent's system prompt each heartbeat.

---

## Rollback

If an evolution goes wrong:

```bash
# List available snapshots
docker images myagent

# Roll back
docker stop myagent
docker rm myagent
docker run -d --name myagent -p 8080:8080 myagent:<tag-to-restore>
```

## Communicating with the Agent

### Via Web Portal (<http://localhost:8080/app/>)

Use the command center to send goals, abort tasks, or give feedback.

### Via Telegram

The Telegram bridge polls your bot for incoming messages and forwards the agent's outbox replies back to you.

**1. Create a bot**

Open Telegram, message [@BotFather](https://t.me/BotFather), and run `/newbot`. Copy the token it gives you.

**2. Store the token in the agent's credential store**

```bash
# One-time: initialise the credential database if it doesn't exist yet
docker exec -it myagent bash -c \
  'cd /agent && uv run python scripts/keepass.py init'

# Store the bot token
docker exec -it myagent bash -c \
  'cd /agent && uv run python scripts/keepass.py store \
   --title TELEGRAM_BOT_TOKEN --username bot --password "<your-token>"'
```

**3. Start the bridge service**

```bash
docker exec -it myagent bash -c \
  'cd /agent && uv run python scripts/service_manager.py restart telegram_bridge'
```

**4. Send the bot a message on Telegram**

The bridge auto-discovers your chat ID from your first message — no manual configuration needed. After that, every message you send the bot lands in the agent's inbox, and the agent's outbox replies are forwarded back to you.

## File Structure

```
mewclaw/
├── Dockerfile          # Seed image definition
├── orchestrator.sh     # Host-side heartbeat loop & snapshot manager
├── docker-compose.yml  # Development mode with volume mounts
├── README.md
├── v1/                 # Agent base state (DNA) 
│   ├── codasst/         # Custom DNA for Coding Assistant agent
│   ├── engagius/         # Custom DNA for Marketing Agent
│   └── proximate/         # Another custom DNA for Personal Assistant
|── scripts/            # Utility scripts (e.g. installer, Cloudflare setup)

```

## How Prompt Selection Works

Each heartbeat, the agent runs the following steps (implemented in `heartbeat.sh`):

**Pre-cycle steps (before prompt selection):**
- **Scheduled tasks** — due tasks from `scheduled_tasks.json` are injected into inbox
- **Auto-start services** — any service with `"auto_start": true` in `services.json` that is not running is restarted (`service-manager.py auto-start`)

**Prompt selection priority:**

1. **No state.json exists OR cycle_number == 0** → `bootstrap.md` (build portal from scratch)
2. **Portal health check fails** → `self-heal.md` with symptom details:
   - Streamlit health endpoint not returning "ok" → `heal:server_down`
   - App render check fails (syntax/import/runtime errors) → `heal:app_error`
3. **Force evolve if no evolve in last 5 cycles** → `evolve.md` (prevents starvation by goals/inbox)
4. **Commands in inbox.json OR active goals pending/in-progress** → `goal.md` (process user commands)
5. **Last N consecutive cycles were all evolve** → skip cycle (prevents evolve loop)
6. **Everything healthy, no tasks** → `evolve.md` (self-improve)

The agent also supports **sleep mode** (via `--agent-sleep` flag) which skips cycles during 00:00–08:00 user timezone unless inbox has pending items.
