# Default OpenClaw Paths Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the baked `DATA_DIR` and the three derived `OPENCLAW_*` path vars so the image relies on OpenClaw's native `/root/.openclaw` defaults, while keeping each path independently overridable.

**Architecture:** Pure subtraction plus reference updates. Strip four `ENV` vars from the Dockerfile, strip the dir-bootstrap block from the entrypoint, and repoint every `/root/data` reference (smoke test volume + assertions, railway/AGENTS/README docs) to `/root/.openclaw`. No new logic; OpenClaw creates and resolves its own dirs.

**Tech Stack:** Docker (Debian base), Bash (entrypoint/supervisor/smoke), Railway.

## Global Constraints

- **Do NOT build the image or run any script on the host during development.** `test/smoke.sh` builds the full image and is very slow — it is the final integration gate, run by the user, not a per-task check. Per-task verification is static only: `bash -n <script>` for shell syntax and `grep` for reference checks. (Source: `CLAUDE.md`.)
- **Container is root-only; `HOME=/root`.** All persisted state lives under `/root/.openclaw` (the new volume mount root).
- **Ship the `OPENCLAW_*` path vars unset.** Do not bake `OPENCLAW_STATE_DIR`, `OPENCLAW_CONFIG_PATH`, or `OPENCLAW_WORKSPACE_DIR`. Operators may set any one independently at runtime; unset ones use OpenClaw defaults: `/root/.openclaw`, `/root/.openclaw/openclaw.json`, `/root/.openclaw/workspace`.
- **Branch:** work happens on `default-openclaw-paths` (already created off `root-only-container`). Do not target `main` yet.
- **Out of scope (do not touch):** `config/bashrc`, `config/profile`, `config/vimrc` (PATH re-export is owned by PR #1 and references none of these vars), `scripts/gateway-supervisor.sh`, `scripts/setup/*`, `mise.claw.toml`, the historical specs/plans under `docs/superpowers/`.

---

### Task 1: Remove `DATA_DIR` and the derived path vars from the Dockerfile

**Files:**
- Modify: `Dockerfile` (the `ARG DATA_DIR` line, the `--- baked environment ---` comment block, and the `ENV` block)

**Interfaces:**
- Consumes: nothing.
- Produces: an image whose `ENV` no longer defines `DATA_DIR`, `OPENCLAW_STATE_DIR`, `OPENCLAW_CONFIG_PATH`, or `OPENCLAW_WORKSPACE_DIR`. Later tasks (entrypoint, smoke test) rely on these being unset so OpenClaw defaults apply.

- [ ] **Step 1: Remove the `DATA_DIR` build arg**

Delete these two lines (currently around `Dockerfile:8-10`):

```dockerfile
# Single source for the persisted data root; the OPENCLAW paths below derive from it.
# This image runs entirely as root; HOME is /root.
ARG DATA_DIR=/root/data
```

The remaining args (`MISE_VERSION`, `OPENCLAW_INSTALL_BROWSER`, `TZ`) stay. Keep the `# --- build args ---` header line.

- [ ] **Step 2: Replace the `ENV`-block comment**

Replace the comment block currently at `Dockerfile:16-20`:

```dockerfile
# --- baked environment (OPENCLAW paths + PATH derive from DATA_DIR / /root) ---
# mise's shims dir is on PATH on purpose: the gateway is launched NON-interactively
# (entrypoint -> supervisor -> openclaw), so `mise activate` in .bashrc never runs for it.
# Per mise docs, putting the shims dir on PATH is the way to resolve tools in init-script
# / non-interactive contexts. .local/bin holds the mise binary itself.
```

with:

```dockerfile
# --- baked environment ---
# OpenClaw path vars (OPENCLAW_STATE_DIR / OPENCLAW_CONFIG_PATH / OPENCLAW_WORKSPACE_DIR)
# are intentionally LEFT UNSET so OpenClaw uses its own defaults under HOME (/root):
# state /root/.openclaw, config /root/.openclaw/openclaw.json, workspace /root/.openclaw/workspace.
# An operator can override any one of them independently at runtime.
# mise's shims dir is on PATH on purpose: the gateway is launched NON-interactively
# (entrypoint -> supervisor -> openclaw), so `mise activate` in .bashrc never runs for it.
# Per mise docs, putting the shims dir on PATH is the way to resolve tools in init-script
# / non-interactive contexts. .local/bin holds the mise binary itself.
```

- [ ] **Step 3: Remove the four path vars from the `ENV` block**

The `ENV` block currently (`Dockerfile:21-32`) reads:

```dockerfile
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
```

Replace it with (drop the first line and the three `OPENCLAW_*` path lines; `TZ` becomes the first entry):

```dockerfile
ENV TZ=${TZ} \
  NODE_ENV=production \
  EDITOR=vim \
  DO_NOT_TRACK=1 \
  NEXT_TELEMETRY_DISABLED=1 \
  CLAWHUB_DISABLE_TELEMETRY=1 \
  OPENCLAW_DISABLE_BONJOUR=1 \
  PATH=/root/.local/bin:/root/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

- [ ] **Step 4: Verify no stale references remain in the Dockerfile**

Run: `grep -n "DATA_DIR\|OPENCLAW_STATE_DIR\|OPENCLAW_CONFIG_PATH\|OPENCLAW_WORKSPACE_DIR\|/root/data" Dockerfile`
Expected: no output (exit status 1). If anything prints, remove it.

- [ ] **Step 5: Commit**

```bash
git add Dockerfile
git commit -m "feat: drop DATA_DIR and baked OPENCLAW path vars from image

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Strip dir bootstrap from the entrypoint

**Files:**
- Modify: `scripts/entrypoint.sh` (full rewrite of the body — it is 18 lines)

**Interfaces:**
- Consumes: the unset `OPENCLAW_*` vars from Task 1 (the entrypoint no longer reads them).
- Produces: an entrypoint that does no path derivation, `mkdir`, or `chmod` — it just execs the supervisor. The gateway creates its own state/workspace dirs.

- [ ] **Step 1: Rewrite `scripts/entrypoint.sh`**

Replace the entire file contents with:

```bash
#!/usr/bin/env bash
# Runtime bootstrap. The container runs as root with HOME=/root. OpenClaw resolves and
# creates its own state and workspace dirs on boot (defaults: /root/.openclaw and
# /root/.openclaw/workspace), so no per-path mkdir/chmod is needed here. The persisted
# volume is mounted at the state dir and is fully readable/writable as root regardless of
# on-disk ownership. Just hand off to the gateway supervisor.
set -euo pipefail

exec /usr/local/bin/gateway-supervisor.sh
```

- [ ] **Step 2: Verify shell syntax**

Run: `bash -n scripts/entrypoint.sh`
Expected: no output, exit status 0.

- [ ] **Step 3: Verify no stale references remain**

Run: `grep -n "DATA_DIR\|STATE_DIR\|WS_DIR\|CONFIG_PATH\|mkdir\|chmod\|/root/data" scripts/entrypoint.sh`
Expected: no output (exit status 1).

- [ ] **Step 4: Commit**

```bash
git add scripts/entrypoint.sh
git commit -m "refactor: entrypoint no longer bootstraps state dirs (OpenClaw does)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Repoint the smoke test to `/root/.openclaw`

**Files:**
- Modify: `test/smoke.sh` (the volume mount at line ~27, and the `== data dirs ==` block at lines ~87-92)

**Interfaces:**
- Consumes: the image from Tasks 1-2 (path vars unset, entrypoint creates nothing).
- Produces: a smoke test that mounts the volume at `/root/.openclaw` and asserts the gateway actually uses that dir, rather than asserting pre-created subdirs.

- [ ] **Step 1: Repoint the volume mount**

In the `docker run` invocation (currently `test/smoke.sh:25-28`), change the mount line:

```bash
  -v "$VOL:/root/data" \
```

to:

```bash
  -v "$VOL:/root/.openclaw" \
```

- [ ] **Step 2: Replace the `== data dirs ==` assertion block**

Replace the block currently at `test/smoke.sh:87-92`:

```bash
echo "== data dirs =="
docker exec "$NAME" bash -lc '
  test -d /root/data/openclaw &&
  test -d /root/data/openclaw-workspace &&
  echo DIRS_OK
'
```

with a probe that confirms the image ships the path vars unset and that the gateway is using `/root/.openclaw` (it runs after the gateway is already healthy, so the gateway has written runtime state under the state dir):

```bash
echo "== state dir (default /root/.openclaw, vars unset) =="
docker exec "$NAME" bash -lc '
  set -eu
  # Image must NOT bake the OpenClaw path vars — OpenClaw defaults must apply.
  [ -z "${OPENCLAW_STATE_DIR:-}" ]     || { echo "FAIL: OPENCLAW_STATE_DIR is set ($OPENCLAW_STATE_DIR)"; exit 1; }
  [ -z "${OPENCLAW_CONFIG_PATH:-}" ]   || { echo "FAIL: OPENCLAW_CONFIG_PATH is set ($OPENCLAW_CONFIG_PATH)"; exit 1; }
  [ -z "${OPENCLAW_WORKSPACE_DIR:-}" ] || { echo "FAIL: OPENCLAW_WORKSPACE_DIR is set ($OPENCLAW_WORKSPACE_DIR)"; exit 1; }
  # The mounted state dir must exist, be writable, and be in use by the (healthy) gateway.
  test -d /root/.openclaw && test -w /root/.openclaw || { echo "FAIL: /root/.openclaw missing or not writable"; exit 1; }
  [ -n "$(ls -A /root/.openclaw)" ] || { echo "FAIL: /root/.openclaw is empty — gateway did not write state there"; exit 1; }
  echo STATE_DIR_OK
'
```

- [ ] **Step 3: Verify shell syntax**

Run: `bash -n test/smoke.sh`
Expected: no output, exit status 0.

- [ ] **Step 4: Verify no stale references remain**

Run: `grep -n "/root/data\|openclaw-workspace" test/smoke.sh`
Expected: no output (exit status 1).

- [ ] **Step 5: Commit**

```bash
git add test/smoke.sh
git commit -m "test: mount volume at /root/.openclaw; assert default state dir in use

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Update docs and config comments

**Files:**
- Modify: `railway.toml` (comment at line ~3)
- Modify: `AGENTS.md` (line 4)
- Modify: `README.md` (volume mount, persistence line, backup/restore tar paths, Variables note)

**Interfaces:**
- Consumes: nothing (documentation only).
- Produces: operator-facing docs consistent with the new `/root/.openclaw` mount and the optional per-var overrides.

- [ ] **Step 1: Update `railway.toml` comment**

Change the line (currently `railway.toml:3`):

```toml
# Railway dashboard: Source = Docker image, Volume mount = /root/data,
```

to:

```toml
# Railway dashboard: Source = Docker image, Volume mount = /root/.openclaw,
```

- [ ] **Step 2: Update `AGENTS.md` line 4**

Change:

```
It runs entirely as **root**; `HOME` is `/root` and all state lives under `/root/data`.
```

to:

```
It runs entirely as **root**; `HOME` is `/root` and all state lives under `/root/.openclaw`.
```

- [ ] **Step 3: Update the `README.md` volume instruction**

Change (currently `README.md:18`):

```markdown
2. **Volume:** mount at **`/root/data`** (single persisted location).
```

to:

```markdown
2. **Volume:** mount at **`/root/.openclaw`** (OpenClaw's state dir — config, credentials, sessions, and workspace all live here).
```

- [ ] **Step 4: Add the optional-overrides note to the `README.md` Variables list**

In the `## Deploy on Railway` Variables list, the optional line currently (`README.md:22`) reads:

```markdown
   - Optional: `TZ` (default `Asia/Ho_Chi_Minh`), `OPENCLAW_GATEWAY_BIND` (default `lan`).
```

Append a second optional bullet immediately after it:

```markdown
   - Optional path overrides (independent; unset → OpenClaw defaults under `/root/.openclaw`):
     `OPENCLAW_STATE_DIR` (→ `/root/.openclaw`), `OPENCLAW_CONFIG_PATH` (→ `/root/.openclaw/openclaw.json`),
     `OPENCLAW_WORKSPACE_DIR` (→ `/root/.openclaw/workspace`). If you relocate the state dir, mount the volume there instead.
```

- [ ] **Step 5: Update the Backup & restore section**

Replace the block currently at `README.md:100-114`. The persistence line:

```markdown
Persistence is **volume-only**: everything lives under `/root/data`.
```

becomes:

```markdown
Persistence is **volume-only**: everything lives under `/root/.openclaw`.
```

The backup command:

```bash
tar czf - -C /root/data . > /tmp/claw-backup.tgz   # then download it
```

becomes:

```bash
tar czf - -C /root/.openclaw . > /tmp/claw-backup.tgz   # then download it
```

The restore intro line:

```markdown
Restore into a **new** deployment (fresh volume at `/root/data`, booted once):
```

becomes:

```markdown
Restore into a **new** deployment (fresh volume at `/root/.openclaw`, booted once):
```

The restore command:

```bash
tar xzf /tmp/claw-backup.tgz -C /root/data
```

becomes:

```bash
tar xzf /tmp/claw-backup.tgz -C /root/.openclaw
```

- [ ] **Step 6: Verify no stale references remain in touched files**

Run: `grep -rn "/root/data\|openclaw-workspace" README.md railway.toml AGENTS.md`
Expected: no output (exit status 1).

- [ ] **Step 7: Commit**

```bash
git add README.md railway.toml AGENTS.md
git commit -m "docs: volume mounts at /root/.openclaw; document optional path overrides

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Final integration gate — full repo sweep + smoke test (user-run)

**Files:** none modified.

**Interfaces:**
- Consumes: all prior tasks.
- Produces: confidence that nothing stale remains and the image boots with the new layout.

- [ ] **Step 1: Repo-wide sweep for stale references (excluding historical docs)**

Run:

```bash
grep -rn "DATA_DIR\|/root/data\|openclaw-workspace" \
  --exclude-dir=.git \
  --exclude-dir=plans --exclude-dir=specs .
```

Expected: no output. The only legitimate remaining matches live under `docs/superpowers/plans/` and `docs/superpowers/specs/` (historical records, deliberately untouched), which the `--exclude-dir` flags skip. If anything else prints, fix it.

- [ ] **Step 2: (USER-RUN) Full smoke test**

> This step builds the image and boots a container — slow, and per `CLAUDE.md` it is not run by the agent during development. Hand off to the user.

Run: `./test/smoke.sh`
Expected: ends with `ALL SMOKE CHECKS PASSED`, including the new `STATE_DIR_OK` line. If `/root/.openclaw is empty` fails, the gateway is not writing state to the default dir on boot — investigate whether OpenClaw needs the dir pre-created (would reopen the Task 2 decision) before proceeding.

- [ ] **Step 3: No commit** (verification only).

---

## Self-Review

**Spec coverage:**
- Drop `DATA_DIR` + three path vars from image → Task 1. ✓
- Ship path vars unset, OpenClaw defaults apply → Task 1 (Step 3) + smoke assertion (Task 3). ✓
- Per-var independent override → documented in Task 4 Step 4; image-side requires only "unset," done in Task 1. ✓
- Workspace left at default inside state dir → no var baked (Task 1); not asserted as pre-created (Task 3). ✓
- Volume mount → `/root/.openclaw` → Task 3 (smoke), Task 4 (railway, README). ✓
- Entrypoint drops mkdir/chmod → Task 2. ✓
- Smoke test repoint + assertion rewrite → Task 3. ✓
- railway.toml / AGENTS.md / README updates → Task 4. ✓
- Migration / operator-action note → already in the spec's "Out of scope" section; no code task needed. ✓

**Placeholder scan:** No TBD/TODO; every code/edit step shows exact content. The one deferred item from the spec (the smoke probe) is now fully specified in Task 3 Step 2. ✓

**Type/string consistency:** Mount path `/root/.openclaw` used identically across Tasks 3 and 4. Var names `OPENCLAW_STATE_DIR` / `OPENCLAW_CONFIG_PATH` / `OPENCLAW_WORKSPACE_DIR` spelled consistently across Tasks 1, 3, 4. Default paths (`/root/.openclaw/openclaw.json`, `/root/.openclaw/workspace`) consistent between spec and Task 4. ✓
