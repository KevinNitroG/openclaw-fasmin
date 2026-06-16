# openclaw-fasmin

A self-contained Docker image that runs an [OpenClaw](https://docs.openclaw.ai) gateway
("fasmin") with a personal CLI toolbelt baked in, designed to deploy on
[Railway](https://railway.com) with persistent state on a single volume.

- **Image:** `ghcr.io/kevinnitrog/openclaw-fasmin` (public)
- **Image is Railway-agnostic** — it runs anywhere a container does. All Railway-specific
  wiring lives in [`railway.toml`](./railway.toml).
- **Declarative tooling** — versions are pinned in [`mise.claw.toml`](./mise.claw.toml) and
  bumped by Renovate. System packages (chromium, yazi, …) come from apt and float.

> Status: the image and scripts are being implemented. The design lives in
> [`docs/superpowers/specs/`](./docs/superpowers/specs/). This README documents the intended
> operation and is the source of truth for *how to run it*.

## What's inside

- **OpenClaw** gateway (installed via mise / npm, pinned).
- **Tools** (via mise): `node`, `pnpm`, `uv`, `gh`, `gogcli`, plus `openclaw` itself.
- **System tools** (via apt): `git`, `ripgrep`, `fzf`, `vim`, `yazi`, `less`, and **chromium**
  (for the agent's browser; installed by default, see below).
- **Homebrew** — installed so the agent can `brew install` more tools at runtime. Not used to
  provision the baked-in tools.
- Runs as a non-root user **`claw`** with **passwordless sudo** (so the agent has root on
  demand via `sudo`, while Homebrew — which refuses to run as root — still works).

## Deploy on Railway

1. **Create a service from the image.** New service → Deploy from Docker image →
   `ghcr.io/kevinnitrog/openclaw-fasmin:latest` (public, no registry auth needed).
2. **Attach a volume** and set its mount path to **`/home/claw/data`**. This is the single
   persisted location (state + workspace live under it).
3. **Set environment variables** (Service → Variables):
   - `OPENCLAW_GATEWAY_TOKEN` — **required.** A long random secret. The gateway is publicly
     reachable on Railway; without a stable token it is not safely authenticated. Set this first.
   - Your model provider key(s), e.g. `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, or an
     OpenAI/Anthropic-compatible endpoint's key (see [Providers](#providers)).
   - Optional: `TZ` (defaults to `Asia/Ho_Chi_Minh`).
4. **Enable Image Auto Updates** (Service → Settings → Deploy) so Railway redeploys when a new
   image is pushed to the `:latest` tag (or bumps a semver tag).
5. Railway routes its public URL to the gateway port and health-checks `/healthz`.

The container comes up on an **empty volume** without any pre-supplied config — the gateway
starts (secured by `OPENCLAW_GATEWAY_TOKEN`) and waits. You then onboard once (below).

## First-run onboarding

Onboarding is a **one-time** step done from Railway's shell. It writes a schema-valid
`openclaw.json` to the volume, which persists across redeploys and **hot-reloads** (no restart
needed for most changes).

Open the Railway shell for the service, then either:

**Interactive (guided TUI):**
```bash
openclaw onboard
# When it offers to "install a daemon", choose later / skip — see Daemon notes below.
```

**Non-interactive (scriptable):**
```bash
openclaw onboard --non-interactive --mode local \
  --auth-choice apiKey --openai-api-key "$OPENAI_API_KEY" \
  --gateway-auth token --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN \
  --skip-health --skip-skills
# NOTE: do NOT pass --install-daemon.
```

Provider keys are read from environment variables (set in Railway) or from
`~/.openclaw/.env` on the volume — never baked into the image.

## Daemon notes (important)

OpenClaw's "daemon" feature manages the gateway via a host init system (systemd user unit on
Linux, LaunchAgent on macOS, Scheduled Task on Windows). **This container does not use it** —
the gateway runs in the foreground under `tini` + a small supervisor, which *is* the process
manager here. Therefore:

- **Never `--install-daemon`** during onboarding. There is no systemd in the container.
- **Do not use `openclaw gateway restart` / `stop` / `start`** — those target an installed
  daemon unit that does not exist here. To restart the gateway in place, use:
  ```bash
  claw-gateway-restart
  ```
  which cycles the gateway via the supervisor **without killing the container**.
- **`openclaw gateway status`**, **`openclaw status`**, and **`openclaw logs`** work fine.
- Most config edits need no restart at all — the gateway watches and hot-reloads `openclaw.json`.
- If the gateway exits and the supervisor cannot respawn it, the container exits and Railway
  restarts it (the outer safety net).

## Providers

OpenClaw can use any supported provider; keys/endpoints are runtime config, not part of the
image.

- **API-key providers** (OpenAI, Anthropic, Google, OpenRouter, …): set the provider's API key
  env var in Railway and select it during onboarding, or reference it from `openclaw.json`.
- **opencode** (or any OpenAI/Anthropic-compatible endpoint): configure it as a custom provider
  — base URL + API key via env vars — during onboarding (choose the custom/compatible provider
  path) or in `models.providers.*` in `openclaw.json`. Set the corresponding key env var in
  Railway. _(Exact field names to be filled in once verified during implementation.)_

## Browser

The agent uses a browser through OpenClaw's browser tool.

- **Default: local chromium** baked into the image, run headless. The agent's browser profile
  is stored under the state dir (on the volume), so logins persist. Controlled by the
  `OPENCLAW_INSTALL_BROWSER` build arg (default on; set to `0` to build without chromium).
- **Optional: remote CDP browser.** Point OpenClaw at a browser running elsewhere via
  `browser.profiles.<name>.cdpUrl` + `attachOnly: true`. This is how you'd use
  [undetectable.io](https://undetectable.io) (a desktop antidetect browser that can't run
  inside this Linux container), [Browserless](https://browserless.io), or Browserbase — run it
  on your own machine/host and give OpenClaw the CDP endpoint + token. Pure runtime config; no
  image change. See <https://docs.openclaw.ai/tools/browser>.

## Operating

- **Logs:** `openclaw logs --follow`
- **Health:** `openclaw gateway status`; HTTP `/healthz` (liveness) and `/readyz` (readiness).
- **Restart gateway:** `claw-gateway-restart` (not `openclaw gateway restart`).
- **Shell in:** use Railway's built-in service shell.

## Versioning & updates

Renovate keeps things current:
- **mise tools** (`mise.claw.toml`): node, openclaw, pnpm, uv, gh, gogcli.
- **Dockerfile**: base image digest + `MISE_VERSION` arg.
- **GitHub Actions** versions.

apt packages (chromium, yazi, …) are intentionally **not** version-pinned — the Debian repos
drop old versions, so pinning would break builds. They track the distro.

## Backup

Today, persistence is **Railway-volume-only**. Treat the volume as the source of truth for
state + workspace. A git-based backup/restore of the data dirs is a possible future addition.

## Development / testing

The image is built in CI and pushed to public GHCR. A `test/` smoke script builds the image
and runs it in a **temporary docker container**, polling `/healthz` and asserting the toolbelt
and bootstrap behavior, then tears everything down. See `test/` (added during implementation).

## Layout

```
Dockerfile          # generic, Railway-agnostic
mise.claw.toml      # declarative tool versions (renovate-tracked)
railway.toml        # the only Railway-coupled file (image, volume, port, healthcheck)
renovate.json
.github/workflows/  # CI: build + push to GHCR
scripts/            # entrypoint, gateway supervisor, build-time setup scripts
config/             # bashrc / profile / vimrc copied into the image
test/               # smoke test against a real temporary container
docs/superpowers/specs/  # design document
```
