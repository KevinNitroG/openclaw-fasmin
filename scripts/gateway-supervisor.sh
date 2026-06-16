#!/usr/bin/env bash
# Supervises the OpenClaw gateway: runs it in the foreground, respawns if it exits,
# and cycles it in place on SIGHUP (used by claw-gateway-restart) so the container
# itself stays alive. This is the "daemon" for this container — OpenClaw's own
# systemd/launchd daemon is intentionally NOT used here.
set -uo pipefail

PORT="${PORT:-18789}"
# OpenClaw bind is a MODE, not an IP: loopback | lan | tailnet | auto | custom.
# Default to "lan" so the gateway is reachable on Railway's network (not just loopback).
BIND="${OPENCLAW_GATEWAY_BIND:-lan}"
GW_PID=""

on_hup()  { [ -n "$GW_PID" ] && kill "$GW_PID" 2>/dev/null || true; }            # restart request
on_term() { [ -n "$GW_PID" ] && kill "$GW_PID" 2>/dev/null || true; exit 0; }    # shutdown
trap on_hup SIGHUP
trap on_term SIGTERM SIGINT

while true; do
  echo "[supervisor] starting gateway (bind=${BIND} port=${PORT})" >&2
  # --allow-unconfigured lets the gateway boot on a fresh volume (no openclaw.json yet)
  # so it stays up for onboarding; once config exists it is read/hot-reloaded normally.
  openclaw gateway run --bind "$BIND" --port "$PORT" --allow-unconfigured &
  GW_PID=$!
  wait "$GW_PID"
  code=$?
  echo "[supervisor] gateway exited (code ${code}); restarting in 2s" >&2
  sleep 2
done
