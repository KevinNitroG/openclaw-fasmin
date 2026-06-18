#!/usr/bin/env bash
# Runtime bootstrap. The container runs as root with HOME=/root. OpenClaw resolves and
# creates its own state and workspace dirs on boot (defaults: /root/.openclaw and
# /root/.openclaw/workspace), so no per-path mkdir/chmod is needed here. The persisted
# volume is mounted at the state dir and is fully readable/writable as root regardless of
# on-disk ownership. Just hand off to the gateway supervisor.
set -euo pipefail

exec /usr/local/bin/gateway-supervisor.sh
