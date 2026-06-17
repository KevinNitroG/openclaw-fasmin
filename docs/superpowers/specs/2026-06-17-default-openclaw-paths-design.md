# Drop `DATA_DIR`, use OpenClaw's native default paths

**Date:** 2026-06-17
**Status:** Approved
**Builds on:** branch `root-only-container` (PR #1). This work branches off that
branch, not `main`.

## Goal

Stop inventing a custom data layout. Today the image bakes a single
`DATA_DIR=/root/data` and derives three `OPENCLAW_*` path vars under it. Remove
all four and let OpenClaw fall back to its own defaults rooted at `/root/.openclaw`.
Operators keep the ability to override each path **individually**, but the image
ships with none of them set.

## Background: OpenClaw's default paths

When the `OPENCLAW_*` path vars are unset, OpenClaw resolves
(`HOME=/root`, no `OPENCLAW_PROFILE`):

| Var | Default when unset |
|---|---|
| `OPENCLAW_STATE_DIR` | `/root/.openclaw` |
| `OPENCLAW_CONFIG_PATH` | `/root/.openclaw/openclaw.json` |
| `OPENCLAW_WORKSPACE_DIR` | `/root/.openclaw/workspace` |

The workspace is a **subdirectory of the state dir** (per
<https://docs.openclaw.ai/concepts/agent-workspace>), not a sibling as in the old
`DATA_DIR` layout. So a single volume mounted at `/root/.openclaw` captures
config, credentials, sessions, **and** workspace.

## Decisions

- **No grouping var.** `DATA_DIR` is removed entirely; nothing derives from it.
- **Ship the path vars unset.** The image does not bake `OPENCLAW_STATE_DIR`,
  `OPENCLAW_CONFIG_PATH`, or `OPENCLAW_WORKSPACE_DIR`. OpenClaw's defaults apply.
- **Per-var override.** An operator may set any of the three as a Railway env var
  to relocate that one path; unset ones keep the OpenClaw default. They are
  independent — setting `OPENCLAW_STATE_DIR` does not move the others unless the
  operator also sets them.
- **Don't customize the workspace.** Leave `OPENCLAW_WORKSPACE_DIR` unset so the
  workspace stays at its default inside the state dir.
- **Volume mount path becomes `/root/.openclaw`** (was `/root/data`).
- **Entrypoint stops managing dirs.** Drop the `mkdir -p` and `chmod 700/600`
  hardening; the gateway creates its own state/workspace dirs on boot. The
  hardening was redundant: this is a root-only, single-tenant container, so
  everything under `/root` is already root-only via home-dir permissions.

## Changes

### Dockerfile

- Remove `ARG DATA_DIR=/root/data`.
- Remove the four `ENV` lines: `DATA_DIR`, `OPENCLAW_STATE_DIR`,
  `OPENCLAW_CONFIG_PATH`, `OPENCLAW_WORKSPACE_DIR`. Leave all unset.
- Keep the rest of the `ENV` block unchanged: `TZ`, `NODE_ENV`, `EDITOR`,
  `DO_NOT_TRACK`, `NEXT_TELEMETRY_DISABLED`, `CLAWHUB_DISABLE_TELEMETRY`,
  `OPENCLAW_DISABLE_BONJOUR`, and `PATH`.
- Update the `--- baked environment ---` comment: drop the "OPENCLAW paths +
  PATH derive from DATA_DIR" wording; note that OpenClaw path vars are
  intentionally left unset so OpenClaw's `/root/.openclaw` defaults apply, and
  that `PATH` is still baked for the non-interactive gateway launch.

### scripts/entrypoint.sh

- Remove the `DATA_DIR` / `STATE_DIR` / `WS_DIR` / `CONFIG_PATH` derivation, the
  `mkdir -p`, and the `chmod 700/600` hardening block.
- Rewrite the header comment to the new model: container runs as root; OpenClaw
  resolves and creates its own state/workspace dirs (default `/root/.openclaw`);
  no per-path bootstrap is needed.
- Keep `set -euo pipefail` and `exec /usr/local/bin/gateway-supervisor.sh`.

### test/smoke.sh

- Change the volume mount `-v "$VOL:/root/data"` → `-v "$VOL:/root/.openclaw"`.
- Replace the `== data dirs ==` block. It currently asserts
  `/root/data/openclaw` and `/root/data/openclaw-workspace` exist (which the
  entrypoint used to pre-create). The entrypoint no longer pre-creates dirs and
  the workspace may be created lazily, so instead assert that the gateway is
  actually **using** `/root/.openclaw`: confirm `/root/.openclaw` exists and is
  writable, and verify OpenClaw resolves its state dir there (e.g. an
  `openclaw`-reported path, or a file OpenClaw writes under it on boot). The
  exact probe is finalized during plan-writing, since the smoke test cannot be
  run on the host during development.

### railway.toml

- Update the comment documenting the volume mount path: `/root/data` →
  `/root/.openclaw`. No build/deploy stanza changes.

### AGENTS.md

- Line 4: "all state lives under `/root/data`" → "all state lives under
  `/root/.openclaw`".

### README.md

- Volume mount instruction: mount at `/root/.openclaw` (was `/root/data`).
- "Persistence is volume-only: everything lives under `/root/data`" →
  `/root/.openclaw`.
- Backup/restore `tar` commands: `-C /root/data` → `-C /root/.openclaw`.
- In the Variables section, add a short note: `OPENCLAW_STATE_DIR`,
  `OPENCLAW_CONFIG_PATH`, and `OPENCLAW_WORKSPACE_DIR` are optional, independent
  overrides; left unset, OpenClaw uses its `~/.openclaw` layout
  (`/root/.openclaw`, `/root/.openclaw/openclaw.json`, `/root/.openclaw/workspace`).

## Out of scope / operator action

- Existing deployments must re-point the Railway service's volume mount from
  `/root/data` to `/root/.openclaw`. Existing data under the old mount is not
  moved automatically. To preserve it, copy the old `openclaw/` contents up one
  level into the new mount root and `openclaw-workspace/` → `workspace/`.

## Risks (accepted)

- Losing the entrypoint `chmod 700/600` hardening: acceptable because the
  container is root-only and single-tenant; `/root` perms already restrict
  access, and OpenClaw manages its own credential file permissions.
- Workspace moving under the state dir changes the on-volume layout vs. the
  prior `DATA_DIR` scheme — relevant only to the migration note above.
