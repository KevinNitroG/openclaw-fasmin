#!/usr/bin/env bash
# Runtime bootstrap. The container runs as root, so the persisted volume is fully
# readable/writable regardless of its on-disk ownership — no chown dance is needed.
# Ensure the state/workspace dirs exist, harden any existing secrets, then start the gateway.
set -euo pipefail

DATA_DIR="${DATA_DIR:-/root/data}"
STATE_DIR="${OPENCLAW_STATE_DIR:-$DATA_DIR/openclaw}"
WS_DIR="${OPENCLAW_WORKSPACE_DIR:-$DATA_DIR/openclaw-workspace}"
CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$STATE_DIR/openclaw.json}"

mkdir -p "$STATE_DIR" "$WS_DIR"

# Best-effort hardening of any existing secrets.
[ -d "$STATE_DIR/credentials" ] && chmod 700 "$STATE_DIR/credentials" || true
[ -f "$CONFIG_PATH" ] && chmod 600 "$CONFIG_PATH" || true

exec /usr/local/bin/gateway-supervisor.sh
