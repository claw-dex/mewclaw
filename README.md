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
         │ (every 15 min)     │ (every 4 hrs)
    ┌────┴────────────────────┴────┐
    │  orchestrator.sh (on host)   │
    └──────────────────────────────┘
```

## Quick Start

### 1. Initialize the DNA submodule

MewClaw uses the [claw-dna](https://github.com/claw-dex/claw-dna) repository as a submodule for its agent initial base state. It act like a DNA for the agent to evolve from. You can customize it or even change to a different DNA by set the `AGENT_DNA` dockerfile argument to a different base directory contain the new DNA.

```bash
git submodule update --init --recursive
```

### 2. Build the seed image

```bash
docker build -t myagent:seed .
```

### 3. First run — start the container

```bash
docker run -d --name myagent -p 8080:8080 myagent:seed
```

The container starts and waits for authentication. Check the logs:

```bash
docker logs -f myagent
```

Alternatively can mount the existing credential file to skip Claude authentication on first run:

```bash
docker run -d --name myagent -p 8080:8080 -v ~/.claude/credentials.json:/home/agent/.claude/credentials.json myagent:seed
```

### 4. Authenticate Claude Code

In a **second terminal**, open the Claude CLI interactively:

```bash
docker exec -it myagent claude
```

Complete the authentication flow inside the CLI, then exit (`/exit`).
The bootstrap detects the auth automatically and finishes setup —
no restart needed.

> **Ports:** 8080 (Caddy gateway), 8081 (Streamlit at /app/), 8082 (webhook_receiver — auto-starts each heartbeat).
> 8083-8090 are available for additional services the agent may create.

### 5. Open the web portal

Visit **<http://localhost:8080/>** and follow instructions to bootstrap the agent.

### 6. Start automatic heartbeats

```bash
chmod +x orchestrator.sh
./orchestrator.sh
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
./orchestrator.sh                          # defaults: 15min heartbeat, 4hr snapshot
./orchestrator.sh --interval 60            # heartbeat every 60 seconds
./orchestrator.sh --snapshot-interval 7200 # snapshot every 2 hours
./orchestrator.sh --snapshot               # manual snapshot now
./orchestrator.sh --agent-sleep            # enable sleep mode (skips cycles between 00-08 unless inbox has pending items)
```

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

### Via CLI

```bash
# Send a goal
docker exec myagent bash -c 'echo "[{\"type\":\"goal\",\"content\":\"Build a calculator app\",\"timestamp\":\"$(date -Is)\"}]" > /agent/messages/inbox.json'

# Read agent status
docker exec myagent cat /agent/memory/state.json | jq .

# Read journal
docker exec myagent cat /agent/memory/journal.json
```

## File Structure

```
mewclaw/
├── Dockerfile          # Seed image definition
├── orchestrator.sh     # Host-side heartbeat loop & snapshot manager
├── docker-compose.yml  # Development mode with volume mounts
├── README.md
└── v1/base/            # DNA submodule (from claw-dex/claw-dna)
    ├── bootstrap.sh    # First-run setup & entrypoint
    ├── heartbeat.sh    # Single cycle runner (called via docker exec)
    ├── agent.sh        # Agent execution wrapper
    ├── Caddyfile       # Caddy gateway configuration (production)
    ├── Caddyfile.setup # Caddy configuration for first-run setup mode
    ├── setup.html      # First-run authentication guide page
    ├── index.html      # Portal redirect page
    ├── server.py       # Streamlit web portal (managed by bootstrap.sh)
    ├── constitution.md # Immutable rules (read-only inside container)
    ├── pyproject.toml  # Python dependencies
    ├── scripts/        # Utility scripts
    │   ├── service-manager.py  # Background service lifecycle manager
    │   ├── scheduler.py        # Scheduled task runner
    │   ├── notes.py            # Persistent notes store
    │   ├── reminder.py         # Reminder management
    │   ├── keepass.py          # Credential store access
    │   └── ...                 # Other utility scripts
    ├── services/       # Long-running background services
    │   ├── webhook_receiver.py # Incoming webhook handler (port 8082, auto-start)
    │   ├── telegram_bridge.py  # Telegram messaging bridge
    │   └── whatsapp_bridge.py  # WhatsApp messaging bridge
    ├── skills/         # Agent skill definitions (SKILL.md files)
    │   ├── service-manager/    # Background service management
    │   ├── scheduler/          # Task scheduling
    │   ├── notes/              # Notes management
    │   ├── reminder/           # Reminder management
    │   ├── caddy/              # Caddy gateway configuration
    │   └── ...                 # Other skills
    ├── seed/           # Installation scripts
    └── prompts/
        ├── bootstrap.md # First cycle: build the web portal
        ├── self-heal.md # Portal broken: diagnose & fix
        ├── goal.md      # User assigned a task
        └── evolve.md    # No task: self-improve
```

## How Prompt Selection Works

Each heartbeat, the agent runs the following steps (implemented in [v1/base/heartbeat.sh](v1/base/heartbeat.sh)):

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
