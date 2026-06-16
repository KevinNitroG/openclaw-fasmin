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
   - Optional: `OPENCLAW_GATEWAY_BIND` — gateway bind mode (`loopback`/`lan`/`tailnet`/`auto`/
     `custom`). Defaults to **`lan`** so the gateway is reachable on Railway's network.
4. **Set the health check path** (Service → Settings → Deploy → Healthcheck Path) to
   **`/healthz`** so Railway marks a deploy healthy only once the gateway is serving.
5. **Enable Image Auto Updates** (Service → Settings → Deploy) so Railway redeploys when a new
   image is pushed to the `:latest` tag (or bumps a semver tag).

**Port:** the image `EXPOSE`s **`18789`** and the gateway listens on `$PORT` (Railway injects
this) or `18789` by default. Railway usually auto-detects the exposed port; if it doesn't,
set the service's target/HTTP port to **`18789`**. Generate a public domain (Service →
Settings → Networking) to reach the Control UI / gateway.

The container comes up on an **empty volume** without any pre-supplied config — the gateway
boots `--allow-unconfigured` (secured by `OPENCLAW_GATEWAY_TOKEN`) and stays up so `/healthz`
responds. You then onboard once (below), which writes the real config to the volume and
hot-reloads it.

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
- **opencode** (or any OpenAI/Anthropic-compatible endpoint): configure it as a custom provider.
  During `openclaw onboard`, choose the custom / "Unknown" provider path and give it opencode's
  base URL + API key; or add it directly under `models.providers.*` in `openclaw.json` (with the
  base URL and an `apiKey` referencing a Railway env var). Set that key env var in Railway. See
  <https://docs.openclaw.ai/gateway/configuration> for the provider config shape.

## Browser

The agent uses a browser through OpenClaw's browser tool.

- **Default: local chromium** baked into the image at `/usr/bin/chromium` (verified: Chromium
  149 on bookworm), run headless. OpenClaw auto-detects it; if it doesn't, set
  `browser.executablePath: "/usr/bin/chromium"` in `openclaw.json`. In a container you will
  typically also want `browser.noSandbox: true`. The agent's browser profile is stored under
  the state dir (on the volume), so logins persist. Controlled by the `OPENCLAW_INSTALL_BROWSER`
  build arg (default on; set to `0` to build without chromium).
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

## Backup & restore

Persistence is **Railway-volume-only**: everything (config, sessions, credentials, auth
profiles, browser profile, workspace) lives under **`/home/claw/data`**. To back up or migrate
to a new deployment, you copy that one directory.

### Back up (from a running service)

Open the Railway shell for the service and stream a tarball out:

```bash
# inside the Railway shell
tar czf - -C /home/claw/data . > /tmp/claw-backup.tgz
```
Download `/tmp/claw-backup.tgz` (or pipe it through `railway ssh ... > claw-backup.tgz` from
your machine). Railway also offers its own volume snapshots/backups — either works.

### Restore into a NEW deployment

1. Create the new service from the image and **attach a fresh volume at `/home/claw/data`**
   (see [Deploy](#deploy-on-railway)). Let it boot once so the volume exists.
2. Copy your backup in and unpack it over the volume, then fix ownership and restart:
   ```bash
   # from your machine: push the archive into the new container's shell, or upload it first
   # then, inside the new service's Railway shell:
   tar xzf /tmp/claw-backup.tgz -C /home/claw/data
   sudo chown -R claw:claw /home/claw/data
   claw-gateway-restart
   ```
3. The restored `openclaw.json` + credentials are picked up on restart (config also
   hot-reloads). No re-onboarding needed — your state, sessions, and logins come back.

> Tip: keep the same `OPENCLAW_GATEWAY_TOKEN` and provider env vars on the new service as the
> old one, so existing clients and auth keep working unchanged.

Locally (e.g. moving between docker hosts) the same archive restores into a docker volume:
```bash
docker run --rm -v <newvol>:/data -v "$PWD":/b alpine \
  sh -c 'tar xzf /b/claw-backup.tgz -C /data && chown -R 1000:1000 /data'
```

## Development / testing

The image is built in CI and pushed to public GHCR. `test/smoke.sh` builds the image and runs
it in a **real temporary docker container**, waits for `/healthz`, asserts the toolbelt
(openclaw, rg, fzf, yazi, vim, gh, uv, chromium, sudo) and the data dirs/ownership, then tears
everything down. Run it with `./test/smoke.sh`.

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
