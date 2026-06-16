# OpenClaw "fasmin" Railway Image — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a self-contained, Railway-agnostic Docker image that runs an OpenClaw gateway ("fasmin") with a declarative mise-managed toolbelt, published to public GHCR and deployed on Railway with a single persistent volume.

**Architecture:** `node:24-bookworm` base; system tools via apt; language tools + openclaw via mise (`mise.claw.toml`); Homebrew for agent use; non-root `claw` user with passwordless sudo; container starts as root, an entrypoint fixes volume ownership and drops to `claw` via `gosu` to run a small bash supervisor that runs `openclaw gateway run` (and allows in-place restart). CI (GitHub Actions) builds and pushes to public GHCR; Railway pulls via Image Auto Updates.

**Tech Stack:** Docker, Debian bookworm, Node 24, mise, Homebrew, OpenClaw (npm), bash, GitHub Actions, Renovate, Railway.

**Verification model:** No unit tests. Each task is verified by building/running in a **real temporary docker container**. `test/smoke.sh` (Task 11) is the integration harness. All docker commands run on the host's docker daemon but the *workload* runs inside containers — never install/run the toolchain directly on the host.

**Note on deviations from the spec:** (1) No separate `40-vim.sh` — `config/vimrc` is copied directly. (2) Base image digest is pinned directly in the `FROM` line (Renovate's docker manager tracks it) instead of a `NODE_BASE_DIGEST` ARG. (3) `railway.toml` applies only to the "Railway builds the Dockerfile" path; for the prebuilt-image path (our default) the same settings are entered in the Railway dashboard — both are documented.

---

## File structure

| File | Responsibility |
|------|----------------|
| `.dockerignore` | Keep build context small (exclude git, docs, tests). |
| `mise.claw.toml` | Declarative pinned tool versions (renovate-tracked). Copied to mise global config in image. |
| `scripts/setup/10-apt.sh` | Install system packages (toolbelt, yazi + deps, chromium, build deps, gosu, tini). |
| `scripts/setup/20-mise.sh` | Install the mise binary (pinned). |
| `scripts/setup/30-brew.sh` | Install Homebrew non-interactively (agent availability). |
| `scripts/entrypoint.sh` | Runtime bootstrap: ensure dirs, fix volume ownership/perms, drop to `claw`. |
| `scripts/gateway-supervisor.sh` | Run `openclaw gateway run`; respawn; handle in-place restart signal. |
| `scripts/claw-gateway-restart` | Helper on PATH to signal the supervisor to cycle the gateway. |
| `config/bashrc` | `claw` interactive shell: mise activate, openclaw completion, EDITOR. |
| `config/profile` | `claw` login shell env. |
| `config/vimrc` | Trimmed, plugin-free vim config (replicated from `~/.vim`). |
| `Dockerfile` | Assemble the image (cache-optimized layer order). |
| `railway.toml` | Railway deploy settings (repo-build path); documented for dashboard otherwise. |
| `renovate.json` | Track mise tools (renamed file), Dockerfile digest + mise ARG, GH Actions. |
| `.github/workflows/build.yml` | Build + push to public GHCR. |
| `test/smoke.sh` | Build the image, run it in a temp container, assert health + toolbelt, tear down. |
| `README.md` | Already written; finalize provider/browser details after verification. |

---

## Task 1: Repo hygiene files

**Files:**
- Create: `.dockerignore`
- Create: `.gitattributes` (ensure shell scripts keep LF)

- [ ] **Step 1: Create `.dockerignore`**

```
.git
.github
docs
test
README.md
*.md
.gitignore
.gitattributes
```

- [ ] **Step 2: Create `.gitattributes`** (so scripts stay LF even if edited on Windows)

```
*.sh text eol=lf
scripts/claw-gateway-restart text eol=lf
```

- [ ] **Step 3: Commit**

```bash
git add .dockerignore .gitattributes
git commit -m "chore: add dockerignore and gitattributes"
```

---

## Task 2: Declarative tool manifest (`mise.claw.toml`)

**Files:**
- Create: `mise.claw.toml`

- [ ] **Step 1: Create `mise.claw.toml`** with exact pins (Renovate maintains these going forward)

```toml
# Renamed from mise.toml on purpose: a host/agent `mise` must NOT auto-detect
# this file. It is copied to /home/claw/.config/mise/config.toml in the image.
[tools]
node                     = "24"
"npm:openclaw"           = "2026.6.6"
"npm:pnpm"               = "10.5.2"
uv                       = "0.6.0"
gh                       = "2.67.0"
"github:openclaw/gogcli" = "latest"
```

- [ ] **Step 2: Resolve the gogcli pin** (replace `latest` with the newest real tag)

Run (inside a throwaway container so the host stays clean):
```bash
docker run --rm jdxcode/mise:latest sh -lc 'mise ls-remote "github:openclaw/gogcli" | tail -1'
```
Expected: prints a version/tag (e.g. `v0.4.2`). Edit `mise.claw.toml` and replace
`"github:openclaw/gogcli" = "latest"` with that exact tag. If the repo publishes no
release tags, keep `"latest"` and note it in a comment — Renovate cannot pin a tagless repo.

- [ ] **Step 3: Commit**

```bash
git add mise.claw.toml
git commit -m "feat: add pinned mise tool manifest"
```

---

## Task 3: Build-time setup scripts

**Files:**
- Create: `scripts/setup/10-apt.sh`
- Create: `scripts/setup/20-mise.sh`
- Create: `scripts/setup/30-brew.sh`

- [ ] **Step 1: Create `scripts/setup/10-apt.sh`**

```bash
#!/usr/bin/env bash
# System packages: toolbelt + yazi (+deps) + chromium + build/runtime deps.
# apt versions are intentionally unpinned (Debian repos drop old versions).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
# init, privilege drop, build deps for Homebrew, and the base toolbelt
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg git tini gosu less coreutils \
  build-essential procps file \
  ripgrep fzf vim

# yazi via the griffo.io apt repo
curl -sS https://debian.griffo.io/EA0F721D231FDD3A0A17B9AC7808B4DD62C41256.asc \
  | gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/debian.griffo.io.gpg
echo "deb https://debian.griffo.io/apt $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
  > /etc/apt/sources.list.d/debian.griffo.io.list
apt-get update
# yazi + the previewers/extractors it integrates with
apt-get install -y --no-install-recommends \
  yazi ffmpegthumbnailer p7zip-full jq poppler-utils fd-find zoxide imagemagick

# chromium for the agent browser (default on; toggled by the build arg)
if [ "${OPENCLAW_INSTALL_BROWSER:-1}" = "1" ]; then
  apt-get install -y --no-install-recommends chromium fonts-liberation
fi

apt-get clean
```

- [ ] **Step 2: Create `scripts/setup/20-mise.sh`**

```bash
#!/usr/bin/env bash
# Install the mise binary, pinned to $MISE_VERSION, into the claw user's ~/.local/bin.
set -euo pipefail
curl -fsSL https://mise.run | \
  MISE_VERSION="${MISE_VERSION}" MISE_INSTALL_PATH="${HOME}/.local/bin/mise" sh
mkdir -p "${HOME}/.config/mise"
"${HOME}/.local/bin/mise" --version
```

- [ ] **Step 3: Create `scripts/setup/30-brew.sh`**

```bash
#!/usr/bin/env bash
# Install Homebrew non-interactively. Purpose: availability for the agent at runtime.
# Runs as the non-root claw user (Homebrew refuses root); claw has passwordless sudo,
# which the installer uses to create /home/linuxbrew.
set -euo pipefail
NONINTERACTIVE=1 /bin/bash -c \
  "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
/home/linuxbrew/.linuxbrew/bin/brew --version
```

- [ ] **Step 4: Mark scripts executable + commit**

```bash
chmod +x scripts/setup/10-apt.sh scripts/setup/20-mise.sh scripts/setup/30-brew.sh
git add scripts/setup
git commit -m "feat: add build-time setup scripts (apt, mise, brew)"
```

---

## Task 4: Shell + vim config files

**Files:**
- Create: `config/profile`
- Create: `config/bashrc`
- Create: `config/vimrc`

- [ ] **Step 1: Create `config/profile`**

```bash
# /home/claw/.profile — login shell environment for the claw user
export EDITOR=vim
export PAGER=less
# mise binary + shims on PATH (also set via Dockerfile ENV; kept here for SSH/login shells)
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:/home/linuxbrew/.linuxbrew/bin:$PATH"
[ -n "${BASH_VERSION:-}" ] && [ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
```

- [ ] **Step 2: Create `config/bashrc`**

```bash
# /home/claw/.bashrc — interactive shell setup for the claw user
case $- in *i*) ;; *) return ;; esac   # only for interactive shells

export EDITOR=vim
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:/home/linuxbrew/.linuxbrew/bin:$PATH"

# mise activation (adds tools to PATH dynamically for this shell)
if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate bash)"
fi

# openclaw bash completion
if command -v openclaw >/dev/null 2>&1; then
  source <(openclaw completion bash) 2>/dev/null || true
fi

alias ll='ls -alh'
```

- [ ] **Step 3: Create a baseline `config/vimrc`** (plugin-free)

```vim
" fasmin container vimrc — plugin-free baseline
set nocompatible
set encoding=utf-8
set number
set ruler
set hidden
set incsearch
set hlsearch
set ignorecase
set smartcase
set expandtab
set shiftwidth=2
set softtabstop=2
set tabstop=2
set autoindent
set backspace=indent,eol,start
set mouse=a
set clipboard=unnamedplus
set undofile
set undodir=$HOME/.vim/undo
syntax on
filetype plugin indent on
```

- [ ] **Step 4: Enrich `config/vimrc` from the user's real config** (replication, plugin-free)

Dispatch a subagent (the user explicitly asked for this) to read the user's vim config and
merge in the non-plugin settings:

> Dispatch `Explore` (or `general-purpose`) agent with: "Read `~/.vim/vimrc`, `~/.vim/core/`,
> and `~/.vim/vim-specific/`. Extract ONLY settings that work in plain vim with NO external
> plugins (options, mappings, autocommands, colorscheme if built-in). Ignore anything that
> references `plug#`, `Plug`, `plugged/`, or plugin-provided commands. Return a consolidated
> plugin-free vimrc snippet to append to `config/vimrc`."

Append the returned settings to `config/vimrc` (keep the baseline above; drop duplicates).
If the subagent finds nothing safe to add, the baseline stands.

- [ ] **Step 5: Commit**

```bash
git add config
git commit -m "feat: add claw shell + plugin-free vim config"
```

---

## Task 5: Runtime scripts (entrypoint, supervisor, restart helper)

**Files:**
- Create: `scripts/entrypoint.sh`
- Create: `scripts/gateway-supervisor.sh`
- Create: `scripts/claw-gateway-restart`

- [ ] **Step 1: Create `scripts/entrypoint.sh`** (runs as root under tini)

```bash
#!/usr/bin/env bash
# Runtime bootstrap. Runs as root so it can fix ownership of the runtime-mounted
# Railway volume, then drops to the unprivileged claw user to run the gateway.
set -euo pipefail

STATE_DIR="${OPENCLAW_STATE_DIR:-/home/claw/data/openclaw}"
WS_DIR="${OPENCLAW_WORKSPACE_DIR:-/home/claw/data/openclaw-workspace}"
CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$STATE_DIR/openclaw.json}"

mkdir -p "$STATE_DIR" "$WS_DIR"
# The volume mounts at runtime, often root-owned; hand it to claw.
chown -R claw:claw /home/claw/data

# Best-effort hardening of any existing secrets.
[ -d "$STATE_DIR/credentials" ] && chmod 700 "$STATE_DIR/credentials" || true
[ -f "$CONFIG_PATH" ] && chmod 600 "$CONFIG_PATH" || true

exec gosu claw /usr/local/bin/gateway-supervisor.sh
```

- [ ] **Step 2: Create `scripts/gateway-supervisor.sh`** (runs as claw)

```bash
#!/usr/bin/env bash
# Supervises the OpenClaw gateway: runs it in the foreground, respawns if it exits,
# and cycles it in place on SIGHUP (used by claw-gateway-restart) so the container
# itself stays alive. This is the "daemon" for this container — OpenClaw's own
# systemd/launchd daemon is intentionally NOT used here.
set -uo pipefail

PORT="${PORT:-18789}"
GW_PID=""

on_hup()  { [ -n "$GW_PID" ] && kill "$GW_PID" 2>/dev/null || true; }   # restart request
on_term() { [ -n "$GW_PID" ] && kill "$GW_PID" 2>/dev/null || true; exit 0; }  # shutdown
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
```

- [ ] **Step 3: Create `scripts/claw-gateway-restart`** (helper on PATH)

```bash
#!/usr/bin/env bash
# Restart the gateway in place without killing the container.
set -euo pipefail
if pkill -HUP -f '/usr/local/bin/gateway-supervisor.sh'; then
  echo "gateway restart signaled"
else
  echo "supervisor not found — is the gateway running under the supervisor?" >&2
  exit 1
fi
```

- [ ] **Step 4: Mark executable + commit**

```bash
chmod +x scripts/entrypoint.sh scripts/gateway-supervisor.sh scripts/claw-gateway-restart
git add scripts/entrypoint.sh scripts/gateway-supervisor.sh scripts/claw-gateway-restart
git commit -m "feat: add entrypoint, gateway supervisor, and restart helper"
```

---

## Task 6: Dockerfile

**Files:**
- Create: `Dockerfile`

- [ ] **Step 1: Resolve the base image digest** (pin `node:24-bookworm`)

Run:
```bash
docker pull node:24-bookworm
docker inspect --format='{{index .RepoDigests 0}}' node:24-bookworm
```
Expected: `node@sha256:<64hex>`. Use that digest in the `FROM` line below.

- [ ] **Step 2: Create `Dockerfile`** (substitute the digest from Step 1)

```dockerfile
# syntax=docker/dockerfile:1

# Pinned base; Renovate's docker manager keeps the digest current.
FROM node:24-bookworm@sha256:REPLACE_WITH_DIGEST_FROM_STEP_1

# --- build args ---
# renovate: datasource=github-releases depName=jdx/mise
ARG MISE_VERSION=v2025.5.0
ARG OPENCLAW_INSTALL_BROWSER=1
ARG TZ=Asia/Ho_Chi_Minh

# --- baked environment ---
ENV TZ=${TZ} \
    NODE_ENV=production \
    EDITOR=vim \
    DO_NOT_TRACK=1 \
    NEXT_TELEMETRY_DISABLED=1 \
    CLAWHUB_DISABLE_TELEMETRY=1 \
    OPENCLAW_DISABLE_BONJOUR=1 \
    OPENCLAW_STATE_DIR=/home/claw/data/openclaw \
    OPENCLAW_CONFIG_PATH=/home/claw/data/openclaw/openclaw.json \
    OPENCLAW_WORKSPACE_DIR=/home/claw/data/openclaw-workspace \
    PATH=/home/claw/.local/bin:/home/claw/.local/share/mise/shims:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin

# --- user: claw (uid 1000) with passwordless sudo ---
RUN set -eux; \
    useradd -m -u 1000 -s /bin/bash claw; \
    echo 'claw ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/claw; \
    chmod 0440 /etc/sudoers.d/claw

# --- layer 1: system packages (changes rarely) ---
COPY scripts/setup/10-apt.sh /tmp/setup/10-apt.sh
RUN OPENCLAW_INSTALL_BROWSER=${OPENCLAW_INSTALL_BROWSER} /tmp/setup/10-apt.sh \
    && rm -rf /var/lib/apt/lists/*

# --- switch to claw for user-space installs ---
USER claw
WORKDIR /home/claw

# --- layer 2: mise binary ---
COPY --chown=claw:claw scripts/setup/20-mise.sh /tmp/setup/20-mise.sh
RUN MISE_VERSION=${MISE_VERSION} /tmp/setup/20-mise.sh

# --- layer 3: tools (re-runs only when mise.claw.toml changes) ---
COPY --chown=claw:claw mise.claw.toml /home/claw/.config/mise/config.toml
RUN mise install

# --- layer 4: Homebrew (agent availability) ---
COPY --chown=claw:claw scripts/setup/30-brew.sh /tmp/setup/30-brew.sh
RUN /tmp/setup/30-brew.sh

# --- layer 5: config + runtime scripts (changes most often) ---
COPY --chown=claw:claw config/bashrc  /home/claw/.bashrc
COPY --chown=claw:claw config/profile /home/claw/.profile
COPY --chown=claw:claw config/vimrc   /home/claw/.vimrc
COPY scripts/entrypoint.sh scripts/gateway-supervisor.sh scripts/claw-gateway-restart \
     /usr/local/bin/

# scripts copied as root-owned + executable; entrypoint runs as root (see below)
USER root
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/gateway-supervisor.sh \
             /usr/local/bin/claw-gateway-restart

EXPOSE 18789
# tini as PID 1; entrypoint runs as root, fixes the volume, drops to claw.
ENTRYPOINT ["tini", "-s", "--"]
CMD ["/usr/local/bin/entrypoint.sh"]
```

- [ ] **Step 3: Build the image** (first full build)

Run:
```bash
docker build -t openclaw-fasmin:test .
```
Expected: build completes. If `mise install` fails on a version that doesn't exist, bump that
pin in `mise.claw.toml` and rebuild (expected, normal). If the griffo yazi repo codename has
no packages, confirm `VERSION_CODENAME` is `bookworm`.

- [ ] **Step 4: Commit**

```bash
git add Dockerfile
git commit -m "feat: add Dockerfile (cache-ordered, root-entrypoint drops to claw)"
```

---

## Task 7: First container smoke (resolve open items)

No new files — this task runs the freshly built image and records answers to the spec's open
items so later docs are accurate.

- [ ] **Step 1: Run the container against a temp volume**

```bash
docker volume create claw-tmp
docker run -d --name claw-tmp -e OPENCLAW_GATEWAY_TOKEN=dev-token \
  -v claw-tmp:/home/claw/data -p 18789:18789 openclaw-fasmin:test
```

- [ ] **Step 2: Wait for health and confirm the gateway serves**

```bash
for i in $(seq 1 60); do
  docker exec claw-tmp curl -fsS http://127.0.0.1:18789/healthz && break || sleep 2
done
```
Expected: a `/healthz` success response. If it never comes, inspect `docker logs claw-tmp`.

- [ ] **Step 3: Confirm the toolbelt + privilege model**

```bash
docker exec -u claw claw-tmp bash -lc \
  'openclaw --version; rg --version | head -1; fzf --version; yazi --version; \
   vim --version | head -1; gh --version | head -1; uv --version; gogcli --version || true; \
   brew --version | head -1; sudo -n true && echo SUDO_OK'
```
Expected: every tool prints a version; `SUDO_OK` prints.

- [ ] **Step 4: Record the chromium path** (open item §16.1)

```bash
docker exec claw-tmp bash -lc 'command -v chromium; chromium --version'
```
Expected: `/usr/bin/chromium` and a version. Note this path; it is the value the README's
browser section references (OpenClaw auto-detects `/usr/bin/chromium`; if it does not, set
`browser.executablePath: "/usr/bin/chromium"` and `browser.noSandbox: true` in `openclaw.json`).

- [ ] **Step 5: Confirm data dirs + ownership**

```bash
docker exec claw-tmp bash -lc 'ls -ld /home/claw/data/openclaw /home/claw/data/openclaw-workspace'
```
Expected: both exist, owned by `claw`.

- [ ] **Step 6: Tear down**

```bash
docker rm -f claw-tmp && docker volume rm claw-tmp
```

- [ ] **Step 7: Update README open items if findings differ** (e.g. chromium needs
`noSandbox`/explicit `executablePath`, or gogcli binary name differs). Commit only if changed:

```bash
git add README.md && git commit -m "docs: record verified browser/tool details" || true
```

---

## Task 8: Railway config

**Files:**
- Create: `railway.toml`

- [ ] **Step 1: Create `railway.toml`**

```toml
# Applies when Railway BUILDS this repo's Dockerfile (alternative path).
# For our default path (prebuilt GHCR image), enter the same settings in the
# Railway dashboard: Source = Docker image, Volume mount = /home/claw/data,
# Healthcheck path = /healthz, and the env vars from the README.
[build]
builder = "DOCKERFILE"
dockerfilePath = "Dockerfile"

[deploy]
healthcheckPath = "/healthz"
healthcheckTimeout = 300
restartPolicyType = "ON_FAILURE"
restartPolicyMaxRetries = 10
```

- [ ] **Step 2: Commit**

```bash
git add railway.toml
git commit -m "feat: add railway.toml (healthcheck + restart policy)"
```

---

## Task 9: Renovate config

**Files:**
- Create: `renovate.json`

- [ ] **Step 1: Create `renovate.json`**

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended"],
  "mise": {
    "fileMatch": ["(^|/)mise\\.claw\\.toml$"]
  },
  "packageRules": [
    {
      "matchManagers": ["mise"],
      "groupName": "mise tools"
    },
    {
      "matchManagers": ["dockerfile"],
      "groupName": "docker base + args"
    }
  ]
}
```

> Key detail: the `mise.fileMatch` override is REQUIRED — Renovate's mise manager would
> otherwise ignore the non-standard `mise.claw.toml` filename. The Dockerfile manager tracks
> the pinned `FROM` digest and the `# renovate:`-annotated `MISE_VERSION` ARG automatically.
> The github-actions manager (in `config:recommended`) tracks the workflow in Task 10.

- [ ] **Step 2: Commit**

```bash
git add renovate.json
git commit -m "feat: add renovate config (mise renamed file, docker, actions)"
```

---

## Task 10: CI — build & push to public GHCR

**Files:**
- Create: `.github/workflows/build.yml`

- [ ] **Step 1: Create `.github/workflows/build.yml`**

```yaml
name: build

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read
  packages: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/kevinnitrog/openclaw-fasmin
          tags: |
            type=raw,value=latest
            type=sha,format=short

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

- [ ] **Step 2: Note for the operator** (one-time, manual — not a code step)

After the first successful push, make the GHCR package **public**:
GitHub → your profile → Packages → `openclaw-fasmin` → Package settings → Change visibility →
Public. (Public is required so Railway can pull without credentials.)

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci: build and push image to public GHCR"
```

---

## Task 11: Smoke test harness

**Files:**
- Create: `test/smoke.sh`

- [ ] **Step 1: Create `test/smoke.sh`**

```bash
#!/usr/bin/env bash
# Build the image and exercise it in a REAL temporary container, then tear down.
# Usage: test/smoke.sh   (set IMAGE=... to skip building and reuse an image)
set -euo pipefail

IMAGE="${IMAGE:-openclaw-fasmin:smoke}"
NAME="claw-smoke-$$"
VOL="claw-smoke-$$"

cleanup() {
  docker rm -f "$NAME"  >/dev/null 2>&1 || true
  docker volume rm "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  echo "== build =="
  docker build -t "$IMAGE" .
fi

echo "== run =="
docker volume create "$VOL" >/dev/null
docker run -d --name "$NAME" \
  -e OPENCLAW_GATEWAY_TOKEN=smoke-token \
  -v "$VOL:/home/claw/data" \
  -p 18789 "$IMAGE" >/dev/null

echo "== wait for /healthz =="
ok=0
for i in $(seq 1 60); do
  if docker exec "$NAME" curl -fsS http://127.0.0.1:18789/healthz >/dev/null 2>&1; then
    ok=1; echo "gateway healthy after ${i} tries"; break
  fi
  sleep 2
done
if [ "$ok" != "1" ]; then
  echo "FAIL: gateway never became healthy"; docker logs "$NAME"; exit 1
fi

echo "== toolbelt =="
docker exec -u claw "$NAME" bash -lc '
  set -e
  openclaw --version
  rg --version | head -1
  fzf --version
  yazi --version
  vim --version | head -1
  gh --version | head -1
  uv --version
  brew --version | head -1
  sudo -n true && echo SUDO_OK
'

echo "== browser (informational) =="
docker exec "$NAME" bash -lc 'command -v chromium && chromium --version' \
  || echo "chromium absent (ok only if built with OPENCLAW_INSTALL_BROWSER=0)"

echo "== data dirs =="
docker exec "$NAME" bash -lc '
  test -d /home/claw/data/openclaw &&
  test -d /home/claw/data/openclaw-workspace &&
  stat -c "%U" /home/claw/data/openclaw | grep -qx claw &&
  echo DIRS_OK
'

echo "ALL SMOKE CHECKS PASSED"
```

- [ ] **Step 2: Run it**

Run:
```bash
chmod +x test/smoke.sh && ./test/smoke.sh
```
Expected: ends with `ALL SMOKE CHECKS PASSED`. Fix any failure before continuing.

- [ ] **Step 3: Commit**

```bash
git add test/smoke.sh
git commit -m "test: add container smoke harness"
```

---

## Task 12: Finalize README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Reconcile README with verified findings**

Update these spots in `README.md` using Task 7 results:
- Browser section: state the confirmed chromium path and whether `noSandbox`/explicit
  `executablePath` are needed in `openclaw.json`.
- Providers → opencode: fill in the concrete config (env var name + `models.providers.*`
  base URL field) once verified against a running gateway (`openclaw onboard` → custom
  provider, or the configuration docs). If still unverified, keep the explicit
  "set base URL + key as a custom OpenAI/Anthropic-compatible provider" wording — do not
  invent field names.
- Add the Railway **healthcheck path** (`/healthz`) to the dashboard deploy steps.

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: finalize README with verified browser/provider/healthcheck details"
```

---

## Self-review notes (already reconciled)

- **Spec coverage:** base+user (T6), mise tools incl. gogcli/gh (T2), apt incl. yazi+chromium
  (T3), brew (T3), shell+vim config (T4), entrypoint/supervisor/restart (T5), data layout +
  ownership (T5/T6/T7), telemetry envs (T6), security token via env (T7/README), CI public
  GHCR (T10), Railway healthcheck (T8/T12), renovate incl. renamed mise file (T9), smoke test
  in real container (T11), README incl. daemon notes (already written) — all covered.
- **Privilege model:** container ends as root so the entrypoint can chown the runtime-mounted
  volume, then drops to `claw` via `gosu`; the gateway (and the agent's `brew`) run as `claw`.
  `gosu` is installed in T3.
- **Naming consistency:** supervisor script path `/usr/local/bin/gateway-supervisor.sh` is the
  exact string `claw-gateway-restart` greps; PORT defaults to 18789 in supervisor, Dockerfile
  `EXPOSE`, and smoke test.
- **Known runtime-resolved values** (digest in T6.S1, gogcli tag in T2.S2, chromium specifics
  in T7) are resolved by explicit commands, not left as silent placeholders.
