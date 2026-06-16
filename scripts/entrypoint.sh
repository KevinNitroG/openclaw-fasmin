#!/usr/bin/env bash
# Runtime bootstrap. Runs as root so it can fix ownership of the runtime-mounted
# Railway volume, then drops to the unprivileged claw user to run the gateway.
set -euo pipefail

STATE_DIR="${OPENCLAW_STATE_DIR:-/home/claw/data/openclaw}"
WS_DIR="${OPENCLAW_WORKSPACE_DIR:-/home/claw/data/openclaw-workspace}"
CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$STATE_DIR/openclaw.json}"

mkdir -p "$STATE_DIR" "$WS_DIR"
# The volume mounts at runtime, often root-owned; hand it to claw.
chown -R claw:claw /home/claw/data

# Best-effort hardening of any existing secrets.
[ -d "$STATE_DIR/credentials" ] && chmod 700 "$STATE_DIR/credentials" || true
[ -f "$CONFIG_PATH" ] && chmod 600 "$CONFIG_PATH" || true

exec gosu claw /usr/local/bin/gateway-supervisor.sh
