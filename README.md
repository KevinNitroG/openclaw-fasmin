# openclaw-fasmin

Self-contained Docker image running an [OpenClaw](https://docs.openclaw.ai) gateway ("fasmin")
with a personal CLI toolbelt, built for [Railway](https://railway.com) with state on one volume.

- **Image:** `ghcr.io/kevinnitrog/openclaw-fasmin` (public)
- **Railway-agnostic** — runs anywhere; Railway specifics live only in [`railway.toml`](./railway.toml).
- **Declarative tooling** — versions pinned + renovate-tracked.
- **Runs as root** — a single-purpose, single-tenant image; the agent has full access inside the container.

**Where things are declared:**
- Language tools / CLIs (node, openclaw, pnpm, uv, gh, gogcli): [`mise.claw.toml`](./mise.claw.toml)
- System packages (toolbelt, yazi + deps, chromium): [`scripts/setup/10-apt.sh`](./scripts/setup/10-apt.sh)

## Deploy on Railway

1. **Service from image:** `ghcr.io/kevinnitrog/openclaw-fasmin:latest` (public — no auth).
2. **Volume:** mount at **`/root/.openclaw`** (OpenClaw's state dir — config, credentials, sessions, and workspace all live here).
3. **Variables:**
   - `OPENCLAW_GATEWAY_TOKEN` — **required**, a long random secret (gateway is publicly reachable).
   - Provider key(s), e.g. `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` (see [Providers](#providers)).
   - Optional: `TZ` (default `Asia/Ho_Chi_Minh`), `OPENCLAW_GATEWAY_BIND` (default `lan`).
   - Optional path overrides (independent; unset → OpenClaw defaults under `/root/.openclaw`):
     `OPENCLAW_STATE_DIR` (→ `/root/.openclaw`), `OPENCLAW_CONFIG_PATH` (→ `/root/.openclaw/openclaw.json`),
     `OPENCLAW_WORKSPACE_DIR` (→ `/root/.openclaw/workspace`). If you relocate the state dir, mount the volume there instead.
4. **Healthcheck path:** `/healthz`.
5. **Port:** the gateway binds Railway's injected `$PORT` automatically (falls back to `18789`
   locally). Generate a public domain; no manual port config needed.
6. **Enable Image Auto Updates** so Railway redeploys on a new `:latest` push.

The gateway boots `--allow-unconfigured` on an empty volume and stays up; you onboard once (below).

## First-run onboarding

One-time, from the Railway shell. The shell opens as root with the full toolbelt on PATH.
Writes `openclaw.json` to the volume (persists + hot-reloads).

```bash
openclaw onboard                 # interactive — skip the "install daemon" step
```
or non-interactive:
```bash
openclaw onboard --non-interactive --mode local \
  --auth-choice apiKey --openai-api-key "$OPENAI_API_KEY" \
  --gateway-auth token --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN \
  --skip-health --skip-skills     # do NOT pass --install-daemon
```

## Web Control UI (CORS)

The gateway only trusts loopback origins by default, so opening the Control UI from your
Railway public domain is **blocked** ("origin not allowed") until you whitelist it. Add the
full origin (scheme + host, **no trailing slash**) to `openclaw.json`:

```json5
{
  gateway: {
    controlUi: {
      allowedOrigins: ["https://<your-app>.up.railway.app"]
    }
  }
}
```

Then `claw-gateway-restart`. Use the exact public URL Railway assigned; add more entries for any
other origins. Avoid `["*"]` (allows any origin). See
[Control UI docs](https://docs.openclaw.ai/web/control-ui).

## Daemon notes

OpenClaw's daemon (systemd/launchd) is **not** used — the gateway runs under `tini` + a supervisor.

- Never `--install-daemon`.
- Restart in place: `claw-gateway-restart` (not `openclaw gateway restart`).
- `openclaw gateway status` / `openclaw status` / `openclaw logs` work normally.
- Config edits hot-reload; no restart needed for most changes.

## Providers

Runtime config only — keys go in Railway env vars, never the image.

- **API-key providers:** set the key env var, select it during onboarding.
- **opencode / any OpenAI- or Anthropic-compatible endpoint:** add as a custom provider (base URL
  + key) during `openclaw onboard` or under `models.providers.*` in `openclaw.json`. See
  [config docs](https://docs.openclaw.ai/gateway/configuration).

## Browser

- **Default:** local chromium at `/usr/bin/chromium`, headless; profile persists under the state
  dir. If not auto-detected, set `browser.executablePath: "/usr/bin/chromium"` (and usually
  `browser.noSandbox: true`) in `openclaw.json`. Toggle off with build arg `OPENCLAW_INSTALL_BROWSER=0`.
- **Remote CDP (optional):** point `browser.profiles.<name>.cdpUrl` + `attachOnly: true` at a
  browser elsewhere (undetectable.io / Browserless / Browserbase). See
  [browser docs](https://docs.openclaw.ai/tools/browser).

## Operating

- Logs: `openclaw logs --follow`
- Health: `openclaw gateway status`; HTTP `/healthz`, `/readyz`
- Restart gateway: `claw-gateway-restart`
- Shell in: Railway's built-in service shell (lands as root, with full config)

## Backup & restore

Persistence is **volume-only**: everything lives under `/root/.openclaw`.

Back up (from the Railway shell):
```bash
tar czf - -C /root/.openclaw . > /tmp/claw-backup.tgz   # then download it
```

Restore into a **new** deployment (fresh volume at `/root/.openclaw`, booted once):
```bash
tar xzf /tmp/claw-backup.tgz -C /root/.openclaw
claw-gateway-restart
```
Keep the same `OPENCLAW_GATEWAY_TOKEN` + provider vars so clients/auth keep working.

## Versioning

Renovate tracks: mise tools ([`mise.claw.toml`](./mise.claw.toml)), the base image digest +
`MISE_VERSION` ([`Dockerfile`](./Dockerfile)), and GitHub Actions. apt packages float (Debian
drops old versions, so they aren't pinned).

## Development

`./test/smoke.sh` builds the image, runs it in a throwaway container, waits for `/healthz`,
asserts the toolbelt + data dirs, then tears down.

## Layout

```
Dockerfile          mise.claw.toml      railway.toml       renovate.json
.github/workflows/  scripts/ (entrypoint, supervisor, setup/)
config/ (bashrc, profile, vimrc)        test/smoke.sh      docs/superpowers/
```
