#!/usr/bin/env bash
set -euo pipefail

# ─── Configurable constants ───────────────────────────────────────────────────
TUNNEL_NAME="ai-agent-node-local0"
HOSTNAME="ai-agent-node-local0.0xgosu.dev"
CLOUDFLARED_HOME="${HOME}/.cloudflared"
# ──────────────────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║     Cloudflare Tunnel Setup — AI Agent          ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ─── Step 1: Check cloudflared is installed ───────────────────────────────────
echo "[step 1/6] Checking cloudflared is installed..."

if ! command -v cloudflared &>/dev/null; then
  echo "  ERROR: cloudflared is not installed or not in PATH."
  echo ""
  echo "  Install it from:"
  echo "    https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
  echo ""
  echo "  On Debian/Ubuntu:"
  echo "    bash scripts/install_cloudflared_debian.sh   (if available)"
  echo ""
  exit 1
fi

echo "  Found: $(command -v cloudflared)"
echo ""

# ─── Step 2: Login (if needed) ────────────────────────────────────────────────
echo "[step 2/6] Checking Cloudflare login..."

if [ -f "${CLOUDFLARED_HOME}/cert.pem" ]; then
  echo "  Already logged in (${CLOUDFLARED_HOME}/cert.pem exists)."
else
  echo "  No cert.pem found. Starting cloudflared login..."
  echo "  A browser window will open. Authenticate and select your zone."
  echo ""
  cloudflared tunnel login
  echo ""
  echo "  Login complete."
fi
echo ""

# ─── Step 3: Create tunnel ───────────────────────────────────────────────────
echo "[step 3/6] Creating tunnel..."

read -rp "  Tunnel name [${TUNNEL_NAME}]: " input_name
TUNNEL_NAME="${input_name:-${TUNNEL_NAME}}"

if [ -z "${TUNNEL_NAME}" ]; then
  echo "  ERROR: Tunnel name cannot be empty."
  exit 1
fi

echo "  Running: cloudflared tunnel create ${TUNNEL_NAME}"
CREATE_RC=0
CREATE_OUTPUT=$(cloudflared tunnel create "${TUNNEL_NAME}" 2>&1) || CREATE_RC=$?

if [ "${CREATE_RC}" -eq 0 ]; then
  echo "  ${CREATE_OUTPUT}"
  # Parse tunnel ID from output:
  TUNNEL_ID=$(echo "${CREATE_OUTPUT}" | grep -o 'with id [a-f0-9-]*' | sed 's/with id //' || true)
elif echo "${CREATE_OUTPUT}" | grep -qi "already exists"; then
  echo "  Tunnel '${TUNNEL_NAME}' already exists. Reusing existing tunnel..."
  LIST_OUTPUT=$(cloudflared tunnel list --name "${TUNNEL_NAME}" --output json 2>&1)
  TUNNEL_ID=$(echo "${LIST_OUTPUT}" | grep -o '"id" *: *"[a-f0-9-]*"' | head -1 | sed 's/.*"id" *: *"//;s/"//' || true)
else
  echo "  ${CREATE_OUTPUT}"
  echo ""
  echo "  ERROR: Failed to create tunnel (exit code ${CREATE_RC})."
  exit 1
fi

if [ -z "${TUNNEL_ID}" ]; then
  echo ""
  echo "  ERROR: Could not parse tunnel ID from output."
  echo "  Check the output above for errors."
  exit 1
fi

if [[ ! "${TUNNEL_ID}" =~ ^[a-f0-9-]+$ ]]; then
  echo ""
  echo "  ERROR: Tunnel ID has unexpected format: ${TUNNEL_ID}"
  exit 1
fi

echo "  Tunnel ID: ${TUNNEL_ID}"

# Verify credentials file — refetch if missing and tunnel was reused
CREDS_FILE="${CLOUDFLARED_HOME}/${TUNNEL_ID}.json"
if [ -f "${CREDS_FILE}" ]; then
  echo "  Credentials file: ${CREDS_FILE}"
else
  echo "  Credentials file not found at ${CREDS_FILE}"
  echo "  Fetching credentials with: cloudflared tunnel token --cred-file ${CREDS_FILE} ${TUNNEL_ID}"
  if cloudflared tunnel token --cred-file "${CREDS_FILE}" "${TUNNEL_ID}" 2>&1; then
    echo "  Credentials file fetched: ${CREDS_FILE}"
  else
    echo "  WARNING: Failed to fetch credentials file."
    echo "  You may need to fetch it manually:"
    echo "    cloudflared tunnel token --cred-file ${CREDS_FILE} ${TUNNEL_ID}"
  fi
fi
echo ""

# ─── Step 4: Generate config.yml ─────────────────────────────────────────────
echo "[step 4/6] Generating config.yml..."

read -rp "  Hostname [${HOSTNAME}]: " input_hostname
HOSTNAME="${input_hostname:-${HOSTNAME}}"

CONFIG_DST="config.yml"

generate_config() {
  cat > "${CONFIG_DST}" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CLOUDFLARED_HOME}/${TUNNEL_ID}.json

ingress:
  - hostname: ${HOSTNAME}
    service: http://localhost:8080
    originRequest:
      # Timeout for establishing TCP connection to origin (default: 30s)
      connectTimeout: 10s
      # Keep-alive timeout for idle connections (important for WebSocket)
      keepAliveTimeout: 3600s

  # Catch-all rule (required by cloudflared)
  - service: http_status:404
EOF
  echo "  Generated ${CONFIG_DST} with tunnel ID ${TUNNEL_ID}."
  echo ""
}

if [ -f "${CONFIG_DST}" ]; then
  read -rp "  ${CONFIG_DST} already exists. Overwrite? [y/N]: " confirm
  if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
    echo "  Skipping config generation."
    echo ""
    # Still continue to DNS routing step
  else
    generate_config
  fi
else
  generate_config
fi

# ─── Step 5: Route DNS ───────────────────────────────────────────────────────
echo "[step 5/6] Routing DNS..."
echo "  Running: cloudflared tunnel route dns ${TUNNEL_ID} ${HOSTNAME}"

ROUTE_RC=0
ROUTE_OUTPUT=$(cloudflared tunnel route dns "${TUNNEL_ID}" "${HOSTNAME}" 2>&1) || ROUTE_RC=$?

if [ "${ROUTE_RC}" -eq 0 ]; then
  echo "  ${ROUTE_OUTPUT}"
elif echo "${ROUTE_OUTPUT}" | grep -qi "already exists"; then
  echo "  DNS route for '${HOSTNAME}' already exists."
  echo "  ${ROUTE_OUTPUT}"
  echo ""
  read -rp "  Remove existing route and re-configure? [y/N]: " confirm_route
  if [[ "${confirm_route}" =~ ^[Yy]$ ]]; then
    echo "  Re-routing with --overwrite-dns..."
    cloudflared tunnel route dns --overwrite-dns "${TUNNEL_ID}" "${HOSTNAME}" || {
      echo ""
      echo "  WARNING: DNS re-routing failed. You may need to set it up manually:"
      echo "    cloudflared tunnel route dns --overwrite-dns ${TUNNEL_ID} ${HOSTNAME}"
      echo ""
    }
  else
    echo "  Skipping DNS routing."
  fi
else
  echo "  ${ROUTE_OUTPUT}"
  echo ""
  echo "  WARNING: DNS routing failed. You may need to set it up manually:"
  echo "    cloudflared tunnel route dns ${TUNNEL_ID} ${HOSTNAME}"
  echo ""
fi

echo ""

# ─── Step 6: Summary ─────────────────────────────────────────────────────────
echo "[step 6/6] Setup complete!"
echo ""
echo "  Tunnel name:      ${TUNNEL_NAME}"
echo "  Tunnel ID:        ${TUNNEL_ID}"
echo "  Config file:      config.yml"
echo "  Credentials file: ${CLOUDFLARED_HOME}/${TUNNEL_ID}.json"
echo "  Hostname:         ${HOSTNAME}"
echo ""
echo "  To start the tunnel manually:"
echo ""
echo "    cloudflared tunnel --config config.yml run"
echo ""
echo "  To start the tunnel as a daemon (systemd service):"
echo ""
echo "    sudo mkdir -p /etc/cloudflared/"
echo "    sudo cp config.yml /etc/cloudflared/config.yml"
echo "    sudo cloudflared service install"
echo "    sudo systemctl start cloudflared"
echo ""
