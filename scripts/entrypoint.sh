#!/usr/bin/env bash
# Runtime bootstrap. Default user is claw; it claims the (often root-owned) volume mount
# root via passwordless sudo, then runs the gateway as claw. A root-guard re-execs as claw
# if the platform ever launches the container as root, so the gateway never runs as root.
set -euo pipefail

DATA_DIR="${DATA_DIR:-/home/claw/data}"
STATE_DIR="${OPENCLAW_STATE_DIR:-$DATA_DIR/openclaw}"
WS_DIR="${OPENCLAW_WORKSPACE_DIR:-$DATA_DIR/openclaw-workspace}"
CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$STATE_DIR/openclaw.json}"

# If launched as root: claim the mount root, then drop to claw and re-run.
if [ "$(id -u)" -eq 0 ]; then
  mkdir -p "$DATA_DIR"
  chown claw:claw "$DATA_DIR"
  exec gosu claw "$0" "$@"
fi

# Running as claw. Only chown the volume mount ROOT, and only when it isn't already ours —
# non-recursive + conditional so startup is not slowed by a deep chown of all state.
if [ "$(stat -c %U "$DATA_DIR" 2>/dev/null || echo root)" != claw ]; then
  sudo chown claw:claw "$DATA_DIR"
fi

mkdir -p "$STATE_DIR" "$WS_DIR"

# Best-effort hardening of any existing secrets.
[ -d "$STATE_DIR/credentials" ] && chmod 700 "$STATE_DIR/credentials" || true
[ -f "$CONFIG_PATH" ] && chmod 600 "$CONFIG_PATH" || true

exec /usr/local/bin/gateway-supervisor.sh
