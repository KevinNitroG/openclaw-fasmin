# Root-only Container Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the OpenClaw Railway image from a mixed root+`claw`-user build (which existed only to install Homebrew) into a clean, single-purpose root-only image with the home directory at `/root`.

**Architecture:** Remove the `claw` user, its passwordless sudo, Homebrew, and the root↔claw shell hand-off. Every build layer and runtime script runs as root. The persisted data root moves from `/home/claw/data` to `/root/data`. The mise shims stay on `ENV PATH` (required for the non-interactive gateway launch); only the linuxbrew PATH segment is removed.

**Tech Stack:** Docker (Debian bookworm-slim base), mise (tool version manager), OpenClaw gateway, bash.

**Spec:** `docs/superpowers/specs/2026-06-17-root-only-container-design.md`

**Verification model:** This is an infrastructure refactor (Dockerfile + shell scripts + config), not application code with a unit-test suite. Each task verifies via static checks (`grep`, `bash -n` syntax check, `hadolint` if available). The final task builds the image end-to-end and smoke-tests the running container — that is the real integration test.

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `Dockerfile` | Image build | Heavy edit: drop user/sudo/brew/hand-off, retarget to `/root` |
| `scripts/setup/10-apt.sh` | System packages | Remove `sudo`, `build-essential` |
| `scripts/setup/20-mise.sh` | mise binary install | No change (uses `$HOME`) |
| `scripts/setup/30-brew.sh` | Homebrew install | **Delete** |
| `scripts/entrypoint.sh` | Runtime bootstrap | Drop sudo volume-claim; retarget `/root/data` |
| `config/bashrc` | Interactive shell setup | Drop linuxbrew from PATH; comment → `/root` |
| `config/profile` | Login shell env | Drop linuxbrew from PATH; comment → `/root` |
| `config/root-bashrc` | root→claw shell bounce | **Delete** |
| `config/vimrc` | vim config | No change |
| `mise.claw.toml` | Pinned tool versions | Comment path → `/root/.config/mise/config.toml` |
| `railway.toml` | Railway build/deploy | Comment volume path → `/root/data` |
| `README.md` | Docs | Rewrite references to root-only / `/root/data` |

---

### Task 1: Delete the Homebrew install script

**Files:**
- Delete: `scripts/setup/30-brew.sh`

- [ ] **Step 1: Delete the file**

```bash
git rm scripts/setup/30-brew.sh
```

- [ ] **Step 2: Verify nothing else references it**

Run: `grep -rn "30-brew" . --exclude-dir=.git`
Expected: only matches inside `docs/superpowers/` (spec/plan) — NO matches in `Dockerfile` yet (the Dockerfile is edited in Task 3). If `Dockerfile` shows up here, that's expected at this point; it will be removed in Task 3.

- [ ] **Step 3: Commit**

```bash
git commit -m "chore: drop Homebrew install script (root-only image)"
```

---

### Task 2: Remove sudo and build-essential from apt packages

**Files:**
- Modify: `scripts/setup/10-apt.sh`

- [ ] **Step 1: Edit the `base_packages` array**

In `scripts/setup/10-apt.sh`, the current array is:

```bash
base_packages=(
  # essential: TLS certs, fetch, gpg, vcs, init, sudo, pager, core utils
  ca-certificates curl gnupg git tini sudo less coreutils procps file
  # homebrew build deps
  build-essential
  # cli toolbelt
  ripgrep fzf vim zoxide fd-find jq ffmpeg
)
```

Replace it with (remove `sudo`, remove the `build-essential` line and its comment, update the essential comment to drop "sudo"):

```bash
base_packages=(
  # essential: TLS certs, fetch, gpg, vcs, init, pager, core utils
  ca-certificates curl gnupg git tini less coreutils procps file
  # cli toolbelt
  ripgrep fzf vim zoxide fd-find jq ffmpeg
)
```

- [ ] **Step 2: Syntax-check the script**

Run: `bash -n scripts/setup/10-apt.sh`
Expected: no output (exit 0).

- [ ] **Step 3: Verify the packages are gone**

Run: `grep -nE '\bsudo\b|build-essential' scripts/setup/10-apt.sh`
Expected: no matches (exit 1, empty output).

- [ ] **Step 4: Commit**

```bash
git add scripts/setup/10-apt.sh
git commit -m "chore: drop sudo and build-essential from apt (root-only image)"
```

---

### Task 3: Rewrite the Dockerfile for root-only

**Files:**
- Modify: `Dockerfile`

This task replaces the whole Dockerfile. Read the existing one first to confirm it matches the base below, then replace its full contents with this:

- [ ] **Step 1: Replace the Dockerfile contents**

```dockerfile
# syntax=docker/dockerfile:1

# Plain Debian base — node is provided by mise (single, renovate-tracked source of truth),
# not by the base image. Pinned by digest; Renovate's docker manager keeps it current.
FROM debian:bookworm-slim@sha256:96e378d7e6531ac9a15ad505478fcc2e69f371b10f5cdf87857c4b8188404716

# --- build args ---
# Single source for the persisted data root; the OPENCLAW paths below derive from it.
# This image runs entirely as root; HOME is /root.
ARG DATA_DIR=/root/data
# renovate: datasource=github-releases depName=jdx/mise
ARG MISE_VERSION=v2026.6.10
ARG OPENCLAW_INSTALL_BROWSER=1
ARG TZ=Asia/Ho_Chi_Minh

# --- baked environment (OPENCLAW paths + PATH derive from DATA_DIR / /root) ---
# mise's shims dir is on PATH on purpose: the gateway is launched NON-interactively
# (entrypoint -> supervisor -> openclaw), so `mise activate` in .bashrc never runs for it.
# Per mise docs, putting the shims dir on PATH is the way to resolve tools in init-script
# / non-interactive contexts. .local/bin holds the mise binary itself.
ENV DATA_DIR=${DATA_DIR} \
    TZ=${TZ} \
    NODE_ENV=production \
    EDITOR=vim \
    DO_NOT_TRACK=1 \
    NEXT_TELEMETRY_DISABLED=1 \
    CLAWHUB_DISABLE_TELEMETRY=1 \
    OPENCLAW_DISABLE_BONJOUR=1 \
    OPENCLAW_STATE_DIR=${DATA_DIR}/openclaw \
    OPENCLAW_CONFIG_PATH=${DATA_DIR}/openclaw/openclaw.json \
    OPENCLAW_WORKSPACE_DIR=${DATA_DIR}/openclaw-workspace \
    PATH=/root/.local/bin:/root/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- layer 1: system packages (changes rarely) ---
COPY scripts/setup/10-apt.sh /tmp/setup/10-apt.sh
RUN OPENCLAW_INSTALL_BROWSER=${OPENCLAW_INSTALL_BROWSER} /tmp/setup/10-apt.sh \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /root

# --- layer 2: mise binary ---
COPY scripts/setup/20-mise.sh /tmp/setup/20-mise.sh
RUN MISE_VERSION=${MISE_VERSION} /tmp/setup/20-mise.sh

# --- layer 3: tools (re-runs only when mise.claw.toml changes) ---
COPY mise.claw.toml /root/.config/mise/config.toml
RUN mise install

# Pre-generate bash completion once at build (after openclaw is installed). NOT --write-state:
# that targets the volume-backed state dir, which the runtime mount would hide. Bake it to a
# fixed home path instead; .bashrc sources this so shells don't invoke openclaw on every start.
RUN mkdir -p /root/.local/share/bash-completion \
    && mise exec -- openclaw completion --shell bash \
       > /root/.local/share/bash-completion/openclaw.bash

# --- layer 4: config + runtime scripts (changes most often) ---
COPY config/bashrc  /root/.bashrc
COPY config/profile /root/.profile
COPY config/vimrc   /root/.vimrc
COPY scripts/entrypoint.sh scripts/gateway-supervisor.sh scripts/claw-gateway-restart \
     /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/gateway-supervisor.sh \
             /usr/local/bin/claw-gateway-restart

# Login shells (Railway shell, `su -`) reset the environment, dropping vars set only via ENV.
# Snapshot the OPENCLAW/runtime env into a profile.d script so interactive login shells point
# at the same state dir/config as the gateway (else `openclaw onboard` writes to ~/.openclaw).
# Generated FROM the ENV above — single source of truth, no hardcoded duplication.
RUN for v in TZ DATA_DIR OPENCLAW_STATE_DIR OPENCLAW_CONFIG_PATH OPENCLAW_WORKSPACE_DIR \
             DO_NOT_TRACK NEXT_TELEMETRY_DISABLED CLAWHUB_DISABLE_TELEMETRY OPENCLAW_DISABLE_BONJOUR; do \
      printf 'export %s="%s"\n' "$v" "$(printenv "$v")"; \
    done > /etc/profile.d/10-openclaw-env.sh

EXPOSE 18789
ENTRYPOINT ["tini", "-s", "--"]
CMD ["/usr/local/bin/entrypoint.sh"]
```

- [ ] **Step 2: Confirm all `claw`/brew/user artifacts are gone**

Run: `grep -nE 'claw:|USER |useradd|sudoers|linuxbrew|30-brew|root-bashrc|bash_profile|CLAW_HOME' Dockerfile`
Expected: no matches (exit 1). Note: `mise.claw.toml` is referenced but that token contains `claw.` not `claw:`, so it won't match `claw:`; confirm the only place `claw` appears in the Dockerfile is the `mise.claw.toml` filename.

Run: `grep -n 'mise.claw.toml' Dockerfile`
Expected: one match (the COPY line).

- [ ] **Step 3: Lint the Dockerfile if hadolint is available**

Run: `command -v hadolint >/dev/null && hadolint Dockerfile || echo "hadolint not installed — skipping"`
Expected: no errors, or the skip message.

- [ ] **Step 4: Commit**

```bash
git add Dockerfile
git commit -m "refactor: root-only Dockerfile, home at /root, drop claw user + brew"
```

---

### Task 4: Simplify the entrypoint for root

**Files:**
- Modify: `scripts/entrypoint.sh`

- [ ] **Step 1: Replace the entrypoint contents**

```bash
#!/usr/bin/env bash
# Runtime bootstrap. The container runs as root, so the persisted volume is fully
# readable/writable regardless of its on-disk ownership — no chown dance is needed.
# Ensure the state/workspace dirs exist, harden any existing secrets, then start the gateway.
set -euo pipefail

DATA_DIR="${DATA_DIR:-/root/data}"
STATE_DIR="${OPENCLAW_STATE_DIR:-$DATA_DIR/openclaw}"
WS_DIR="${OPENCLAW_WORKSPACE_DIR:-$DATA_DIR/openclaw-workspace}"
CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$STATE_DIR/openclaw.json}"

mkdir -p "$STATE_DIR" "$WS_DIR"

# Best-effort hardening of any existing secrets.
[ -d "$STATE_DIR/credentials" ] && chmod 700 "$STATE_DIR/credentials" || true
[ -f "$CONFIG_PATH" ] && chmod 600 "$CONFIG_PATH" || true

exec /usr/local/bin/gateway-supervisor.sh
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n scripts/entrypoint.sh`
Expected: no output (exit 0).

- [ ] **Step 3: Confirm no sudo / claw / chown remains**

Run: `grep -nE 'sudo|claw|chown|stat ' scripts/entrypoint.sh`
Expected: no matches (exit 1).

- [ ] **Step 4: Commit**

```bash
git add scripts/entrypoint.sh
git commit -m "refactor: drop sudo volume-claim from entrypoint (root-only)"
```

---

### Task 5: Update shell config files

**Files:**
- Modify: `config/bashrc`
- Modify: `config/profile`
- Delete: `config/root-bashrc`

- [ ] **Step 1: Edit `config/bashrc`**

Replace the header comment line and the PATH line. Current:

```bash
# /home/claw/.bashrc — interactive shell setup for the claw user
case $- in *i*) ;; *) return ;; esac # only for interactive shells

export EDITOR=vim
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:/home/linuxbrew/.linuxbrew/bin:$PATH"
```

New:

```bash
# /root/.bashrc — interactive shell setup (root-only image)
case $- in *i*) ;; *) return ;; esac # only for interactive shells

export EDITOR=vim
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
```

Leave the rest of the file (profile.d sourcing, mise activate, zoxide, completion, alias) unchanged.

- [ ] **Step 2: Edit `config/profile`**

Current:

```bash
# /home/claw/.profile — login shell environment for the claw user
export EDITOR=vim
export PAGER=less
# mise binary + shims on PATH (also set via Dockerfile ENV; kept here for login shells)
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:/home/linuxbrew/.linuxbrew/bin:$PATH"
[ -n "${BASH_VERSION:-}" ] && [ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
```

New:

```bash
# /root/.profile — login shell environment (root-only image)
export EDITOR=vim
export PAGER=less
# mise binary + shims on PATH (also set via Dockerfile ENV; kept here for login shells)
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
[ -n "${BASH_VERSION:-}" ] && [ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
```

- [ ] **Step 3: Delete `config/root-bashrc`**

```bash
git rm config/root-bashrc
```

- [ ] **Step 4: Verify no linuxbrew or claw home references remain in config**

Run: `grep -rnE 'linuxbrew|/home/claw' config/`
Expected: no matches (exit 1).

- [ ] **Step 5: Syntax-check the shell configs**

Run: `bash -n config/bashrc && bash -n config/profile`
Expected: no output (exit 0).

- [ ] **Step 6: Commit**

```bash
git add config/bashrc config/profile
git commit -m "refactor: point shell config at /root, drop linuxbrew + root-bashrc bounce"
```

---

### Task 6: Update mise.claw.toml and railway.toml comments

**Files:**
- Modify: `mise.claw.toml`
- Modify: `railway.toml`

- [ ] **Step 1: Update the `mise.claw.toml` comment**

Current first two comment lines:

```toml
# Renamed from mise.toml on purpose: a host/agent `mise` must NOT auto-detect
# this file. It is copied to /home/claw/.config/mise/config.toml in the image.
```

New:

```toml
# Renamed from mise.toml on purpose: a host/agent `mise` must NOT auto-detect
# this file. It is copied to /root/.config/mise/config.toml in the image.
```

- [ ] **Step 2: Update the `railway.toml` comment**

Current comment block:

```toml
# Applies when Railway BUILDS this repo's Dockerfile (alternative path).
# For our default path (prebuilt GHCR image), enter the same settings in the
# Railway dashboard: Source = Docker image, Volume mount = /home/claw/data,
# Healthcheck path = /healthz, and the env vars from the README.
```

New (only the volume mount path changes):

```toml
# Applies when Railway BUILDS this repo's Dockerfile (alternative path).
# For our default path (prebuilt GHCR image), enter the same settings in the
# Railway dashboard: Source = Docker image, Volume mount = /root/data,
# Healthcheck path = /healthz, and the env vars from the README.
```

- [ ] **Step 3: Verify no stale `/home/claw` paths remain in these files**

Run: `grep -rn '/home/claw' mise.claw.toml railway.toml`
Expected: no matches (exit 1).

- [ ] **Step 4: Commit**

```bash
git add mise.claw.toml railway.toml
git commit -m "docs: update mise/railway path comments to /root"
```

---

### Task 7: Update the README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Find every reference that needs updating**

Run: `grep -nE '/home/claw|claw user|USER claw|homebrew|brew|sudo|linuxbrew' README.md`
Expected: a list of line numbers. Each `/home/claw` path becomes `/root` (e.g. `/home/claw/data` → `/root/data`). Any prose describing the `claw` user, its sudo, or Homebrew is reworded to describe the root-only model, OR removed if it only existed to explain those.

- [ ] **Step 2: Apply the edits**

For each match from Step 1:
- Replace `/home/claw/data` → `/root/data` (volume mount path documentation).
- Replace any other `/home/claw/...` path → `/root/...`.
- Reword/remove sentences about the `claw` user, passwordless sudo, or Homebrew.
- Write it as if root-only is the original design. **Do NOT** add any "migration from claw user" or "we changed from claw to root" narrative.

- [ ] **Step 3: Verify the stale references are gone**

Run: `grep -nE '/home/claw|claw user|passwordless sudo|homebrew|linuxbrew' README.md`
Expected: no matches (exit 1). (A bare `brew` mention is acceptable only if it's clearly absent — re-check any remaining `brew` hits by hand.)

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: update README for root-only image (/root/data)"
```

---

### Task 8: Build the image and smoke-test the container

This is the integration test for the whole refactor.

**Files:** none (verification only).

- [ ] **Step 1: Build the image**

Run: `docker build -t openclaw-railway:root-test .`
Expected: build completes successfully. Watch for failures in the apt layer (missing `sudo`/`build-essential` should be fine — nothing depends on them) and the `mise install` / completion-generation layers (these run as root and must succeed).

- [ ] **Step 2: Verify the toolbelt resolves in a non-interactive shell (shims on PATH)**

Run: `docker run --rm openclaw-railway:root-test bash -lc 'whoami; which openclaw node gh mise'`
Expected: prints `root`, then a resolved path for each of `openclaw`, `node`, `gh`, `mise` (under `/root/.local/...`). No "not found".

- [ ] **Step 3: Verify there is no claw user and no Homebrew**

Run: `docker run --rm openclaw-railway:root-test bash -lc 'id claw 2>&1 || true; command -v brew || echo "no brew (expected)"'`
Expected: `id: 'claw': no such user` (or similar) and `no brew (expected)`.

- [ ] **Step 4: Verify the OPENCLAW env points at /root/data in a login shell**

Run: `docker run --rm openclaw-railway:root-test bash -lc 'echo $OPENCLAW_STATE_DIR $OPENCLAW_WORKSPACE_DIR $DATA_DIR'`
Expected: `/root/data/openclaw /root/data/openclaw-workspace /root/data`.

- [ ] **Step 5: Smoke-test the gateway boots and the healthcheck passes**

Run:
```bash
docker run -d --name oc-smoke -p 18789:18789 openclaw-railway:root-test
sleep 8
curl -fsS http://localhost:18789/healthz && echo " <- healthz OK"
docker logs oc-smoke | tail -n 20
docker rm -f oc-smoke
```
Expected: `/healthz` returns success (`healthz OK`), and the logs show `[supervisor] starting gateway`. No permission-denied or sudo errors.

- [ ] **Step 6: Final commit (if any verification fixes were needed)**

If Steps 1–5 required changes, commit them. Otherwise nothing to commit — the refactor is complete and verified.

```bash
git status   # confirm clean tree if no fixes were needed
```

---

## Self-Review Notes

- **Spec coverage:** Every spec change item maps to a task — Dockerfile (T3), 10-apt (T2), 30-brew delete (T1), entrypoint (T4), bashrc/profile/root-bashrc (T5), mise.claw.toml + railway.toml (T6), README (T7). Operator Railway volume re-point is out-of-scope (manual) and noted in the spec, not a task.
- **PATH:** shims + `.local/bin` retained on `ENV PATH` (T3) and in `config/bashrc`/`config/profile` (T5); only linuxbrew removed. Consistent with the mise-docs finding in the spec.
- **No placeholders:** every code/edit step shows the full before/after content; every command shows expected output.
- **Naming consistency:** `DATA_DIR=/root/data`, `/root/.config/mise/config.toml`, `/root/.local/share/mise/shims` used identically across Dockerfile, entrypoint, config, and verification tasks.
