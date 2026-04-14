#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  orchestrator.sh — External heartbeat & snapshot manager
#
#  Runs on the HOST machine (not inside the container).
#  Triggers agent heartbeats via docker exec.
#  Creates snapshots via docker commit on a schedule.
#
#  Usage:
#    ./orchestrator.sh --container <name>  # default: container name="myagent" heartbeat every 15min, snapshot every 8hr
#    ./orchestrator.sh --interval 300 --snapshot-interval 7200 # heartbeat every 5min, snapshot every 2hr
#    ./orchestrator.sh --snapshot   # run manual snapshot only then exit
#    ./orchestrator.sh --agent-sleep # when enabled, skip heartbeat cycles between 00:00 and 08:00 unless the agent's inbox has items.
# ══════════════════════════════════════════════════════════════

set -uo pipefail

# ── Cross-platform ISO 8601 timestamp ─────────────────────────
# macOS BSD date doesn't support -Is; use -u with explicit format.
ts_now() { date -u +"%Y-%m-%dT%H:%M:%S+00:00"; }

# ── Defaults ─────────────────────────────────────────────────
CONTAINER="myagent"
HEARTBEAT_INTERVAL=900      # seconds (15 minutes)
SNAPSHOT_INTERVAL=28800     # seconds (8 hours)
IMAGE_NAME=""               # derived from container image after arg parsing if not set via --image
AGENT_SLEEP=false           # sleep mode (skip cycles 00:00–08:00 unless inbox has items)
MAX_CONSECUTIVE_EVOLVE=""   # max consecutive evolve cycles before skipping (default: heartbeat.sh default)

# ── Colors ───────────────────────────────────────────────────
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# ── Parse arguments ──────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval)       HEARTBEAT_INTERVAL="$2"; shift 2 ;;
        --snapshot-interval) SNAPSHOT_INTERVAL="$2"; shift 2 ;;
        --container)      CONTAINER="$2"; shift 2 ;;
        --image)          IMAGE_NAME="$2"; shift 2 ;;
        --agent-sleep)    AGENT_SLEEP=true; shift ;;
        --max-evolve)     MAX_CONSECUTIVE_EVOLVE="$2"; shift 2 ;;
        --snapshot)
            # Manual snapshot and exit
            TAG="manual-$(date +%Y%m%d-%H%M%S)"
            echo -e "${CYAN}Creating snapshot: ${IMAGE_NAME}:${TAG}${NC}"
            docker commit "$CONTAINER" "${IMAGE_NAME}:${TAG}"
            echo -e "${GREEN}✔ Snapshot saved: ${IMAGE_NAME}:${TAG}${NC}"
            exit 0
            ;;
        --help|-h)
            echo "Usage: ./orchestrator.sh [options]"
            echo ""
            echo "Options:"
            echo "  --interval N          Heartbeat interval in seconds (default: 900)"
            echo "  --snapshot-interval N Snapshot interval in seconds (default: 28800)"
            echo "  --container NAME      Container name (default: myagent)"
            echo "  --image NAME          Image name for snapshots (default: derived from container image)"
            echo "  --agent-sleep         Enable sleep mode (skip cycles 00:00–08:00 unless inbox has items)"
            echo "  --max-evolve N        Max consecutive evolve cycles before skipping (default: 5)"
            echo "  --snapshot            Take a manual snapshot and exit"
            echo "  --help                Show this help"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Derive IMAGE_NAME from container if not explicitly set ───
if [[ -z "$IMAGE_NAME" ]]; then
    _raw=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || true)
    IMAGE_NAME="${_raw%%:*}"   # strip tag (e.g. "myagent:seed" → "myagent")
    IMAGE_NAME="${IMAGE_NAME:-myagent}"  # fallback if container not found yet
    unset _raw
fi

# ── Pre-flight check ─────────────────────────────────────────
echo -e "${BOLD}${CYAN}MewClaw — Orchestrator${NC}"
echo -e "${DIM}$(printf '%.0s─' {1..50})${NC}"
echo -e "  Container:          ${BOLD}${CONTAINER}${NC}"
echo -e "  Image name:         ${BOLD}${IMAGE_NAME}${NC}"
echo -e "  Heartbeat interval: ${BOLD}${HEARTBEAT_INTERVAL}s${NC} ($(( HEARTBEAT_INTERVAL / 60 ))min)"
echo -e "  Snapshot interval:  ${BOLD}${SNAPSHOT_INTERVAL}s${NC} ($(( SNAPSHOT_INTERVAL / 3600 ))hr)"
echo -e "  Sleep mode:         ${BOLD}$( $AGENT_SLEEP && echo "ON (00:00–08:00)" || echo "OFF" )${NC}"
echo -e "  Max evolve cycles:  ${BOLD}${MAX_CONSECUTIVE_EVOLVE:-5 (default)}${NC}"
echo ""

# Check container is running
if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q "true"; then
    echo -e "${RED}✘ Container '${CONTAINER}' is not running.${NC}"
    echo ""
    echo "  Start it with:"
    echo "    docker start ${CONTAINER}"
    echo ""
    echo "  Or first-time setup:"
    echo "    docker run -it --name ${CONTAINER} -p 8080:8080 ${IMAGE_NAME}:seed"
    exit 1
fi

echo -e "${GREEN}✔ Container '${CONTAINER}' is running${NC}"
echo ""

# ── Functions ────────────────────────────────────────────────

heartbeat() {
    local ts=$(ts_now)
    echo -e "${CYAN}[${ts}]${NC} Heartbeat: waking agent..."

    # Run heartbeat, capture exit code
    local flags=""
    $AGENT_SLEEP && flags="--agent-sleep"
    [ -n "$MAX_CONSECUTIVE_EVOLVE" ] && flags="$flags --max-evolve $MAX_CONSECUTIVE_EVOLVE"
    if docker exec "$CONTAINER" /agent/heartbeat.sh $flags; then
        echo -e "${GREEN}[$(ts_now)]${NC} Heartbeat: cycle complete."
    else
        echo -e "${YELLOW}[$(ts_now)]${NC} Heartbeat: cycle exited with error (agent may self-heal next cycle)."
    fi
}

snapshot() {
    local tag="${1:-auto-$(date +%Y%m%d-%H%M%S)}"
    local ts=$(ts_now)

    echo -e "${CYAN}[${ts}]${NC} Snapshot: creating ${IMAGE_NAME}:${tag}..."
    docker commit "$CONTAINER" "${IMAGE_NAME}:${tag}" >/dev/null
    echo -e "${GREEN}[$(ts_now)]${NC} Snapshot saved: ${IMAGE_NAME}:${tag}"
}

cleanup_old_snapshots() {
    local max_age_secs=172800  # 48 hours
    local cleaned=0
    local now
    now=$(date +%s)

    while IFS= read -r tag; do
        [ -z "$tag" ] && continue
        local created
        created=$(docker inspect --format '{{.Created}}' "${IMAGE_NAME}:${tag}" 2>/dev/null || echo "")
        [ -z "$created" ] && continue
        local snap_ts
        snap_ts=$(python3 -c "
from datetime import datetime, timezone
ts = '$created'
try:
    ts = ts.split('.')[0]
    dt = datetime.strptime(ts, '%Y-%m-%dT%H:%M:%S').replace(tzinfo=timezone.utc)
    print(int(dt.timestamp()))
except Exception:
    print(0)
" 2>/dev/null || echo 0)
        if [ "$snap_ts" -gt 0 ] && (( now - snap_ts >= max_age_secs )); then
            echo -e "${DIM}[$(ts_now)] Cleanup: removing old snapshot ${IMAGE_NAME}:${tag}${NC}"
            docker rmi "${IMAGE_NAME}:${tag}" >/dev/null 2>&1 && cleaned=$((cleaned + 1)) || true
        fi
    done < <(docker images "${IMAGE_NAME}" --format "{{.Tag}}" 2>/dev/null | grep "^auto-")

    if [ "$cleaned" -gt 0 ]; then
        echo -e "${GREEN}[$(ts_now)] Cleanup: removed ${cleaned} old snapshot(s) (>48h)${NC}"
    fi
}

# ── Graceful shutdown ────────────────────────────────────────
RUNNING=true
trap 'echo -e "\n${YELLOW}Orchestrator stopping...${NC}"; RUNNING=false' INT TERM

# ── Main Loop ────────────────────────────────────────────────
# Track last snapshot start time; initialise to now so first snapshot fires
# after SNAPSHOT_INTERVAL, not immediately.
LAST_SNAPSHOT_START=$(date +%s)
CYCLE=0

echo -e "${DIM}Starting heartbeat loop. Press Ctrl+C to stop.${NC}"
echo ""

while $RUNNING; do
    CYCLE=$((CYCLE + 1))
    CYCLE_START=$(date +%s)

    # Run heartbeat (duration counted against the interval)
    heartbeat

    # Check if snapshot is due; snapshot duration is also counted against
    # the heartbeat interval since it runs sequentially in the same cycle.
    NOW=$(date +%s)
    if (( NOW - LAST_SNAPSHOT_START >= SNAPSHOT_INTERVAL )); then
        snapshot
        cleanup_old_snapshots
        LAST_SNAPSHOT_START=$(date +%s)
    fi

    # Compute how long the cycle took and sleep only the remaining time so
    # that heartbeats fire at true HEARTBEAT_INTERVAL cadence (start-to-start).
    NOW=$(date +%s)
    ELAPSED=$(( NOW - CYCLE_START ))
    SLEEP_TIME=$(( HEARTBEAT_INTERVAL - ELAPSED ))

    if (( SLEEP_TIME > 0 )); then
        echo -e "${DIM}Next heartbeat in ${SLEEP_TIME}s (cycle took ${ELAPSED}s)...${NC}"
        SLEPT=0
        while $RUNNING && (( SLEPT < SLEEP_TIME )); do
            sleep 1
            SLEPT=$((SLEPT + 1))
        done
    else
        echo -e "${YELLOW}[$(ts_now)] Cycle took ${ELAPSED}s (> ${HEARTBEAT_INTERVAL}s interval). Starting next heartbeat immediately.${NC}"
    fi
done

echo -e "${GREEN}Orchestrator stopped.${NC}"
