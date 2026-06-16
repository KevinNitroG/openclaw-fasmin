#!/usr/bin/env bash
# Runtime bootstrap. The container runs as claw (uid 1000) — Railway honours USER claw.
# The volume mounts at runtime owned by root, and files from a prior root session can be
# root-owned and unreadable to claw (crash-looping the gateway). Claim the volume via the
# passwordless sudo claw has, then start the gateway.
set -euo pipefail

DATA_DIR="${DATA_DIR:-/home/claw/data}"
STATE_DIR="${OPENCLAW_STATE_DIR:-$DATA_DIR/openclaw}"
WS_DIR="${OPENCLAW_WORKSPACE_DIR:-$DATA_DIR/openclaw-workspace}"
CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$STATE_DIR/openclaw.json}"

# Take ownership only when the volume isn't already ours — the mount root OR the config file
# is owned by someone other than uid 1000. Cheap to check, so steady-state boots skip the
# recursive chown; a root-tainted volume self-heals on the next start.
mkdir -p "$DATA_DIR"
if [ "$(stat -c %u "$DATA_DIR" 2>/dev/null || echo 0)" != 1000 ] \
   || { [ -e "$CONFIG_PATH" ] && [ "$(stat -c %u "$CONFIG_PATH")" != 1000 ]; }; then
  sudo chown -R claw:claw "$DATA_DIR"
fi

mkdir -p "$STATE_DIR" "$WS_DIR"

# Best-effort hardening of any existing secrets.
[ -d "$STATE_DIR/credentials" ] && chmod 700 "$STATE_DIR/credentials" || true
[ -f "$CONFIG_PATH" ] && chmod 600 "$CONFIG_PATH" || true

exec /usr/local/bin/gateway-supervisor.sh
