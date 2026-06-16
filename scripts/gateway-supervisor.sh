#!/usr/bin/env bash
# Supervises the OpenClaw gateway: runs it in the foreground, respawns if it exits,
# and cycles it in place on SIGHUP (used by claw-gateway-restart) so the container
# itself stays alive. This is the "daemon" for this container — OpenClaw's own
# systemd/launchd daemon is intentionally NOT used here.
set -uo pipefail

PORT="${PORT:-18789}"
GW_PID=""

on_hup()  { [ -n "$GW_PID" ] && kill "$GW_PID" 2>/dev/null || true; }            # restart request
on_term() { [ -n "$GW_PID" ] && kill "$GW_PID" 2>/dev/null || true; exit 0; }    # shutdown
trap on_hup SIGHUP
trap on_term SIGTERM SIGINT

while true; do
  echo "[supervisor] starting gateway on 0.0.0.0:${PORT}" >&2
  openclaw gateway run --bind 0.0.0.0 --port "$PORT" &
  GW_PID=$!
  wait "$GW_PID"
  code=$?
  echo "[supervisor] gateway exited (code ${code}); restarting in 2s" >&2
  sleep 2
done
