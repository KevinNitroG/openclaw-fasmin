# OpenClaw on Railway — "fasmin" deployment image — Design

- **Date:** 2026-06-16
- **Owner:** KevinNitroG
- **Status:** Approved design (pre-implementation)
- **Claw name:** fasmin
- **Image:** `ghcr.io/kevinnitrog/openclaw-fasmin` (public)
- **Repo:** `KevinNitroG/openclaw-fasmin`

## 1. Goal

Build a self-contained, declarative Docker image that runs an [OpenClaw](https://docs.openclaw.ai)
gateway, bundled with a personal CLI toolbelt for the agent to use, and deploy it on
Railway with persistent state on a single volume. The image is built in CI, published to
public GHCR, and pulled by Railway via its Image Auto Updates feature.

Design priorities, in order:
1. **Declarative** — tool versions live in `mise.claw.toml`, renovate-tracked.
2. **Railway-agnostic image** — the `Dockerfile` has no Railway coupling; all Railway
   specifics live in `railway.toml`. The image runs anywhere a container does.
3. **Reproducible** — pinned versions, CI-built artifact, cache-optimized layers.
4. **Low-ceremony runtime** — gateway comes up on an empty volume; onboarding is a
   one-time interactive step, not synthetic config we have to maintain.

## 2. Non-goals / explicitly out of scope

- **SSH into the container** — dropped. Use Railway's built-in shell. No `sshd`, no keys.
- **Git backup/restore of state+workspace** — deferred. Railway volume is the only
  persistence today. README notes git-backup as a future option.
- **The `undetectable-ai` humanizer skill** — declined (its purpose is evading AI/plagiarism
  detectors; not baked in). Unrelated to the antidetect-browser item below.
- **Baking in undetectable.io the antidetect browser** — impossible: it is a desktop GUI
  app, not a headless Linux daemon. It is supported only as an optional *remote-CDP browser
  profile* pointing at an instance running elsewhere (README only).
- **A test suite** — this is infra/Dockerfile work and is largely not unit-testable.
  Verification is build-time + smoke checks (see §13). The one genuinely logic-bearing
  piece (the entrypoint/bootstrap script) gets light shell-level checks, not full coverage.

## 3. Key facts established during research

OpenClaw runtime (from official docs + Dockerfile/compose):
- Node 24 app, distributed as a **self-contained npm package** `openclaw`
  (calver, e.g. `2026.6.6`): `bin: openclaw → openclaw.mjs`, `postinstall` bundles plugins,
  ~85 MB unpacked, includes the gateway + LLM provider integrations. `npm i -g openclaw`
  yields a working gateway daemon — not a thin wrapper.
- Gateway run command: `openclaw gateway run --bind <addr> --port <port>` (default `18789`).
  Health endpoints `/healthz`, `/readyz`. Derived browser-control ports near `gateway.port`.
- **All persistent data lives under `OPENCLAW_STATE_DIR` (`~/.openclaw`)** — there is **no**
  separate `~/.config/openclaw` auth dir (the docker-compose summary that suggested one is
  not authoritative). Specifically:
  - Config: `~/.openclaw/openclaw.json` (`OPENCLAW_CONFIG_PATH`)
  - Auth profiles (API keys + OAuth): `~/.openclaw/agents/<agent>/agent/auth-profiles.json`;
    newer installs read each agent's `openclaw-agent.sqlite` (also under state).
  - Legacy/import: `~/.openclaw/credentials/oauth.json`; WhatsApp: `~/.openclaw/credentials/whatsapp/…`
  - Sessions: `~/.openclaw/agents/<agent>/sessions/`; env fallback: `~/.openclaw/.env`
  - Docs: <https://docs.openclaw.ai/concepts/oauth>, <https://docs.openclaw.ai/gateway/configuration>
- **Config must not be symlinked** — atomic writes can clobber a symlinked `openclaw.json`.
  Relocation is done via env vars (`OPENCLAW_STATE_DIR` / `OPENCLAW_CONFIG_PATH`), never symlink.
- Gateway **hot-reloads** `openclaw.json`; most changes apply with no restart.
- Browser model: OpenClaw launches a **local** Chromium-based binary located via
  `browser.executablePath` (agent profile/user-data persisted **under the state dir**, so no
  `PLAYWRIGHT_BROWSERS_PATH` is needed), OR attaches to a **remote** browser via
  `browser.profiles.<name>.cdpUrl` + `attachOnly: true` (Browserless/Browserbase/Notte/undetectable.io).
  Docs: <https://docs.openclaw.ai/tools/browser>
- Onboarding (`openclaw onboard`) is the supported setup path; supports a fully
  `--non-interactive` mode. Its "install daemon" step targets systemd/launchd and is
  **not used here** (our supervisor is the daemon). Docs: <https://docs.openclaw.ai/cli/onboard>,
  <https://docs.openclaw.ai/reference/wizard>

Railway facts:
- **One volume per service**, mounted **at runtime only** (build-time writes to the mount
  path are discarded → bootstrap must run in the entrypoint, not the Dockerfile).
  Docs: <https://docs.railway.com/volumes/reference>
- **Image Auto Updates**: Railway polls the registry; for dynamic tags (`:latest`) it
  redeploys on new SHA, for semver tags it bumps versions. Public images need no auth.
  Docs: <https://docs.railway.com/deployments/image-auto-updates>

## 4. Decisions (locked)

| Area | Decision |
|------|----------|
| Base image | `FROM node:24-bookworm` (pinned by digest ARG); **not** the official ghcr image |
| OpenClaw install | via mise (npm backend), pinned in `mise.claw.toml` |
| User | non-root `claw` (uid 1000) + passwordless sudo; `HOME=/home/claw` |
| Tool manager | **mise** primary (declarative, renovate-tracked); Homebrew installed for *agent* use only |
| Build/deploy | GitHub Actions → public GHCR → Railway Image Auto Updates |
| Persistence | single Railway volume at `/home/claw/data`; state + workspace under it |
| Backup | volume-only (git-backup deferred) |
| Browser | system **chromium** baked in (default-on, ARG-toggle), headless; remote-CDP optional |
| Gateway lifecycle | `tini` (PID 1) → supervisor script → gateway; in-container restart helper |
| Auth | `OPENCLAW_GATEWAY_TOKEN` mandatory (env-referenced); bind `0.0.0.0` on Railway `$PORT` |

## 5. Repository layout

```
openclaw-fasmin/
├── Dockerfile                  # generic, Railway-agnostic
├── mise.claw.toml              # declarative tools (renamed so host mise won't auto-adopt it)
├── railway.toml                # the ONLY Railway-coupled file
├── renovate.json
├── .github/workflows/
│   └── build.yml               # build + push to public GHCR
├── scripts/
│   ├── entrypoint.sh           # runtime bootstrap (runs at container start)
│   ├── gateway-supervisor.sh   # supervises gateway; enables in-container restart
│   ├── claw-gateway-restart    # helper on PATH to cycle the gateway in-place
│   └── setup/                  # build-time scripts, COPYed in then executed
│       ├── 10-apt.sh           # apt deps + yazi apt repo
│       ├── 20-mise.sh          # install mise + `mise install`
│       ├── 30-brew.sh          # Homebrew (agent availability only)
│       └── 40-vim.sh           # install replicated vim config
├── config/
│   ├── bashrc                  # → /home/claw/.bashrc
│   ├── profile                 # → /home/claw/.profile
│   └── vimrc                   # trimmed, plugin-free (replicated from ~/.vim)
├── docs/superpowers/specs/…    # this document
└── README.md
```

## 6. The image (Dockerfile)

### 6.1 Base & user
- `FROM node:24-bookworm` (full Debian; build tooling needed for Homebrew + native deps),
  pinned by digest via `ARG NODE_BASE_DIGEST` (renovate-tracked).
- Create user **`claw`** (uid 1000), grant **passwordless sudo** (`/etc/sudoers.d/claw`).
  `HOME=/home/claw`, `WORKDIR /home/claw`. The agent gets root on demand via `sudo`.

### 6.2 Build ARGs (renovate-trackable) & ENVs
- ARGs: `NODE_BASE_DIGEST`, `MISE_VERSION`, `OPENCLAW_INSTALL_BROWSER=1` (default install
  chromium; set `0` to skip), `TZ=Asia/Ho_Chi_Minh`.
- ENVs baked in:
  - Telemetry/quiet: `CLAWHUB_DISABLE_TELEMETRY=1`, `OPENCLAW_DISABLE_BONJOUR=1`,
    `DO_NOT_TRACK=1`, `NEXT_TELEMETRY_DISABLED=1`
  - Runtime: `NODE_ENV=production`, `TZ`, `EDITOR=vim`
  - Paths: `OPENCLAW_STATE_DIR=/home/claw/data/openclaw`,
    `OPENCLAW_CONFIG_PATH=/home/claw/data/openclaw/openclaw.json`,
    `OPENCLAW_WORKSPACE_DIR=/home/claw/data/openclaw-workspace`
  - mise shims on `PATH` (so the non-interactive gateway *and* agent-spawned shells resolve tools)
  - **No** `PLAYWRIGHT_BROWSERS_PATH` (system chromium; profile under state dir)

### 6.3 Tooling

**mise (`mise.claw.toml`)** — exact pins, renovate-tracked. Copied in the image to mise's
global config path `/home/claw/.config/mise/config.toml`. Named `mise.claw.toml` in the repo
so a host/agent `mise` does not auto-detect and try to install it.

```toml
[tools]
node          = "24"            # exact pin at implementation
"npm:openclaw" = "2026.6.6"
"npm:pnpm"    = "<pinned>"
uv            = "<pinned>"
gh            = "<pinned>"            # confirmed mise name; provides the `gh` binary
"github:openclaw/gogcli" = "<pinned>"
```
> Open item: confirm the exact `github:openclaw/gogcli` backend spec at implementation.

**mise binary**: installed via the official install script pinned to `ARG MISE_VERSION`
(renovate-tracked). Activation: shims on `PATH` via `ENV` (reliable for non-interactive
processes) **plus** `eval "$(mise activate bash)"` in `~/.bashrc` for interactive shells.

**apt (system deps, unpinned/untracked)** — Debian repos drop old versions, so these float:
`ca-certificates curl git tini less coreutils build-essential ripgrep fzf vim` + **yazi**
(via the griffo.io apt repo + its dependencies) + **chromium** and its runtime libs/fonts
(when `OPENCLAW_INSTALL_BROWSER=1`). `ripgrep`/`fzf` come from apt (yazi depends on them).

**Homebrew** — installed under the `claw` user (works now that the default user is non-root).
Purpose: availability so the agent can `brew install` later. Not used to provision our tools.

**vim** — at implementation, a subagent reads `~/.vim/` and replicates only the necessary,
**plugin-free** config into `config/vimrc`. Installed to `/home/claw/.vimrc`. `EDITOR=vim`.

**bash** — `config/bashrc` → `/home/claw/.bashrc`, `config/profile` → `/home/claw/.profile`.
Contents: `mise activate bash`, `source <(openclaw completion bash)`, `EDITOR=vim`, `TZ`.

### 6.4 Layer ordering (cache-optimized)
1. apt system deps (changes rarely)
2. mise binary install
3. `COPY mise.claw.toml` → `mise install` (re-runs only when a tool version bumps)
4. Homebrew install
5. `COPY` config + scripts + vim (changes most often)

A tool-version bump therefore busts only layer 3+, not the apt/brew layers.

### 6.5 Entrypoint / CMD
```
ENTRYPOINT ["tini", "-s", "--"]
CMD ["/usr/local/bin/entrypoint.sh"]
```

## 7. Runtime data layout (single Railway volume → `/home/claw/data`)

```
/home/claw/data/
├── openclaw/             # OPENCLAW_STATE_DIR — config, agents, sessions, credentials,
│   └── openclaw.json     #   auth profiles, browser profile, .env  (OPENCLAW_CONFIG_PATH)
└── openclaw-workspace/   # OPENCLAW_WORKSPACE_DIR
```
No `openclaw-config` dir; no symlinks. Relocation is purely via the env vars in §6.2.

## 8. Bootstrap & onboarding

**Entrypoint (`scripts/entrypoint.sh`)** — idempotent, runs at container start:
1. Ensure `OPENCLAW_STATE_DIR` and `OPENCLAW_WORKSPACE_DIR` exist; fix ownership to `claw`.
2. Tighten perms where present (`credentials/` 700, `openclaw.json` 600) — best-effort.
3. Hand off to `gateway-supervisor.sh` (does **not** write synthetic config).

**Gateway start** — the supervisor `exec`s:
```
openclaw gateway run --bind 0.0.0.0 --port "${PORT:-18789}"
```
Config is optional; the gateway starts on an empty volume and stays up, secured by
`OPENCLAW_GATEWAY_TOKEN` (referenced from env). No crash-loop on first deploy.

**One-time onboarding** (operator, via Railway shell) — writes a schema-valid config to the
volume, which persists and hot-reloads:
- Interactive: `openclaw onboard` (skip the daemon-install step — not applicable here).
- Or non-interactive (scriptable), **without** `--install-daemon`:
  ```
  openclaw onboard --non-interactive --mode local \
    --auth-choice apiKey --<provider>-api-key "$KEY" \
    --gateway-auth token --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN \
    --skip-health --skip-skills
  ```

Provider API keys are supplied via Railway env vars (or `~/.openclaw/.env` on the volume),
referenced from config via env substitution / SecretRef — never baked into the image.

## 9. Gateway supervision & in-container restart

- `tini` (PID 1) → `gateway-supervisor.sh` → `exec` gateway; the supervisor respawns the
  gateway if it exits, so the container stays alive across an in-place gateway restart.
- `claw-gateway-restart` (on `PATH`) signals the supervisor to cycle the gateway **without
  killing the container**. Use this rather than `openclaw gateway restart` (that command
  targets an installed systemd/launchd daemon, which this container does not have).
- Most config changes need no restart at all (gateway hot-reloads `openclaw.json`).

### 9.1 Daemon caveats (must be documented in README)

OpenClaw's own "daemon" concept assumes a host init system (systemd user unit on Linux,
LaunchAgent on macOS, Scheduled Task on Windows). **This container does not use it.** The
gateway runs in the foreground (`openclaw gateway run`) under our `tini`+supervisor, which
*is* the process manager here. Consequences to call out in the README:
- Onboarding's **"install daemon"** step is skipped / not applicable. Never pass
  `--install-daemon`. If interactive onboarding offers it, choose "later"/skip.
- **`openclaw gateway restart` / `stop` / `start`** (daemon-manager commands) are not the
  right tools here — they expect an installed unit. Use `claw-gateway-restart`, or let
  Railway restart the container, or rely on hot-reload.
- **`openclaw gateway status`** (reachability probe) and `openclaw status` are fine to use.
- Railway treats the **container process** as the service; if the gateway exits and the
  supervisor cannot respawn it, the container exits and Railway restarts it (outer safety net).

## 10. Security

- **`OPENCLAW_GATEWAY_TOKEN` is mandatory** (set in Railway env, referenced in config). The
  gateway is exposed publicly on Railway; without a stable shared secret OpenClaw only mints
  a runtime-only token, which is unsafe across restarts. README makes setting this step #1.
- Bind `0.0.0.0` on Railway's `$PORT` (Railway routes its public URL to that port).
- No secrets in the image (public). All secrets live in Railway env vars / on the volume.
- Browser control is loopback-only inside the container and rides the gateway's auth.

## 11. Browser

- Default: **local system chromium** (`/usr/bin/chromium`), headless (no DISPLAY), with
  in-container sandbox flags as required. OpenClaw auto-detects `/usr/bin/chromium`, or we set
  `browser.executablePath` explicitly. Agent browser profile persists under the state dir.
  > Open items (implementation): confirm the exact `executablePath` wiring and the
  > `noSandbox`/headless flags needed for chromium in a container; xvfb is likely unnecessary
  > under headless and is omitted unless a headed path is needed.
- Optional **remote CDP** (README): point `browser.profiles.<name>.cdpUrl` (+ `attachOnly: true`)
  at undetectable.io / Browserless / Browserbase running elsewhere. Pure runtime config.

## 12. Build, publish & deploy

**CI (`.github/workflows/build.yml`)**
- `docker buildx`, GitHub Actions layer cache.
- Push to **public** `ghcr.io/kevinnitrog/openclaw-fasmin` (owner lowercased in CI; repo is
  `KevinNitroG/openclaw-fasmin`).
- Tags: `latest` + a calver/semver tag + commit SHA.
- Pass build ARGs (digest, `MISE_VERSION`, `TZ`, browser toggle) so renovate can bump them.

**`railway.toml`** (only Railway-coupled file)
- `[deploy] image = "ghcr.io/kevinnitrog/openclaw-fasmin:<tag>"`
- Volume mount at `/home/claw/data`; service port = gateway port.
- **Health check** → `[deploy] healthcheckPath = "/healthz"` (the gateway's liveness
  endpoint) with a generous `healthcheckTimeout`, so Railway gates a deploy as healthy only
  once the gateway is actually serving. `/readyz` is available too if a readiness gate is wanted.
- Railway **Image Auto Updates** polls GHCR and redeploys on a new `latest` SHA (or bumps a
  semver tag) — satisfying "wait and pull the latest tag" natively.

## 13. Verification (no test suite)

- **Build**: image builds; `mise install` resolves all pinned tools; `openclaw --version` runs.
- **Smoke**: container starts on an empty volume; gateway answers `/healthz` and `/readyz`;
  `chromium --version` present when `OPENCLAW_INSTALL_BROWSER=1`; `rg`, `fzf`, `yazi`, `vim`,
  `gh`, `uv`, `gogcli` resolve on `PATH`; `sudo -n true` works for `claw`.
- **Entrypoint logic**: light shell-level checks of idempotency (re-run leaves dirs/perms
  consistent; empty-volume path comes up without synthetic config).
- All build/verification runs happen **inside a container**, not on the host.

### 13.1 Test script (deliverable: `test/`)

After implementation, write a `test/` script (e.g. `test/smoke.sh`) that exercises the image
against a **real temporary docker container**:
1. `docker build` the image with a throwaway tag.
2. `docker run` it with a temp volume mounted at `/home/claw/data`.
3. Poll `/healthz` until the gateway is up (or fail after a timeout).
4. `docker exec` the smoke assertions from §13 (tools on `PATH`, `chromium --version`,
   `sudo -n true`, gateway reachable, dirs/perms correct).
5. Tear down the container + temp volume.

This is a smoke/integration script, not a unit-test suite. It runs locally and can be wired
into CI as a post-build gate.

## 14. Renovate (`renovate.json`)

- **mise manager** → bumps everything in `mise.claw.toml` (node, openclaw, pnpm, uv, gh, gogcli).
- **dockerfile manager** → base image digest + `MISE_VERSION` ARG.
- **github-actions manager** → action versions.
- apt packages are intentionally **not** tracked (Debian repos drop old versions).

## 15. README outline

1. What this is (fasmin / OpenClaw on Railway).
2. Deploy on Railway: create service from the public image → attach a volume at
   `/home/claw/data` → set `OPENCLAW_GATEWAY_TOKEN` + provider env vars → enable Image Auto Updates.
3. First-run onboarding via Railway shell (interactive `openclaw onboard`, or the
   non-interactive one-liner); note the skipped daemon step.
4. Providers: how to configure any provider; **opencode** specifics (endpoint/base URL + key
   as env vars) — purely runtime, set in Railway.
5. Browser: default local chromium; optional remote-CDP profiles (undetectable.io / Browserless).
6. Operating it: restarting the gateway (`claw-gateway-restart`), hot-reload, logs.
7. Versioning: what renovate tracks (mise tools, base digest, actions); apt floats.
8. Backup: volume-only today; git-backup as a future option.

## 16. Open verification items (resolve during implementation, not blockers)

1. Exact `browser.executablePath` + `noSandbox`/headless flags for chromium in-container.
2. Exact `github:openclaw/gogcli` mise backend spec (the `gh` tool name is confirmed).
3. Confirm `OPENCLAW_WORKSPACE_DIR` is the correct env var name (seen in compose) vs. setting
   workspace via config.
4. Whether `XDG_CONFIG_HOME`/`OPENCLAW_HOME` affect any path we care about (expected: no,
   since everything lives under `OPENCLAW_STATE_DIR`).
5. Supervisor restart signal mechanism (signal vs. flag-file) for `claw-gateway-restart`.
