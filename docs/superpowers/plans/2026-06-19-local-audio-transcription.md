# Local Audio Transcription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add whisper-cpp with base model to the Docker image so OpenClaw auto-detects local voice transcription.

**Architecture:** Three small changes: apt package addition, new setup script for model download, Dockerfile wiring. OpenClaw auto-detection handles the rest — no config file changes.

**Tech Stack:** whisper-cpp (Debian package), ggml-base.bin model, bash setup scripts, Dockerfile

---

## File Structure

| File | Action | Purpose |
|------|--------|---------|
| `scripts/setup/10-apt.sh` | Modify | Add `whisper-cpp` to base_packages |
| `scripts/setup/25-audio.sh` | Create | Download base model to `/root/.openclaw/models/whisper/` |
| `Dockerfile` | Modify | Add COPY+RUN for 25-audio.sh, add `WHISPER_CPP_MODEL` env var |

---

### Task 1: Add whisper-cpp to apt packages

**Files:**
- Modify: `scripts/setup/10-apt.sh:8-17`

- [ ] **Step 1: Add whisper-cpp to base_packages array**

In `scripts/setup/10-apt.sh`, add `whisper-cpp` to the `base_packages` array. Place it after the existing cli toolbelt comment group, as a new comment group for audio:

```bash
base_packages=(
  # essential: TLS certs, fetch, gpg, vcs, init, pager, core utils
  ca-certificates curl gnupg git tini less coreutils procps file
  # cli toolbelt
  ripgrep fzf vim zoxide fd-find jq ffmpeg tmux
  # shell completion framework (not present in bookworm-slim by default)
  bash-completion
  # runtime lib required by pnpm (libatomic.so.1)
  libatomic1
  # audio transcription (whisper-cpp for OpenClaw local voice notes)
  whisper-cpp
)
```

- [ ] **Step 2: Verify script syntax**

Run: `bash -n scripts/setup/10-apt.sh`
Expected: no output (clean exit)

---

### Task 2: Create audio model setup script

**Files:**
- Create: `scripts/setup/25-audio.sh`

- [ ] **Step 1: Write the setup script**

Create `scripts/setup/25-audio.sh`:

```bash
#!/usr/bin/env bash
# Download whisper-cpp base model for local audio transcription.
# The model is placed under the OpenClaw state dir so WHISPER_CPP_MODEL
# points to a stable, operator-owned path.
set -euo pipefail

MODEL_DIR="/root/.openclaw/models/whisper"
MODEL_FILE="${MODEL_DIR}/ggml-base.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"

# Skip if already present (idempotent rebuilds).
if [ -f "${MODEL_FILE}" ]; then
  echo "whisper base model already exists at ${MODEL_FILE}, skipping download"
  exit 0
fi

mkdir -p "${MODEL_DIR}"
echo "Downloading whisper base model to ${MODEL_FILE}..."
curl -fsSL "${MODEL_URL}" -o "${MODEL_FILE}"
echo "Downloaded whisper base model ($(du -h "${MODEL_FILE}" | cut -f1))"
```

- [ ] **Step 2: Make script executable**

Run: `chmod +x scripts/setup/25-audio.sh`

- [ ] **Step 3: Verify script syntax**

Run: `bash -n scripts/setup/25-audio.sh`
Expected: no output (clean exit)

---

### Task 3: Wire up in Dockerfile

**Files:**
- Modify: `Dockerfile:24-31` (ENV block)
- Modify: `Dockerfile:39-40` (after 20-mise.sh block)

- [ ] **Step 1: Add WHISPER_CPP_MODEL to ENV block**

In the Dockerfile, add `WHISPER_CPP_MODEL` to the existing ENV block. Add it after `OPENCLAW_DISABLE_BONJOUR=1`:

```dockerfile
ENV TZ=${TZ} \
  NODE_ENV=production \
  EDITOR=vim \
  DO_NOT_TRACK=1 \
  NEXT_TELEMETRY_DISABLED=1 \
  CLAWHUB_DISABLE_TELEMETRY=1 \
  OPENCLAW_DISABLE_BONJOUR=1 \
  WHISPER_CPP_MODEL=/root/.openclaw/models/whisper/ggml-base.bin \
  PATH=/root/.local/bin:/root/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

- [ ] **Step 2: Add COPY+RUN for 25-audio.sh**

After the `20-mise.sh` block (line 40), before `COPY mise.claw.toml`, add:

```dockerfile
COPY scripts/setup/25-audio.sh /tmp/setup/25-audio.sh
RUN /tmp/setup/25-audio.sh
```

- [ ] **Step 3: Verify Dockerfile syntax**

Run: `docker build --check .` or `hadolint Dockerfile` (if available)
If neither available, manually review line continuity and escaping.

---

### Task 4: Static verification

- [ ] **Step 1: Check all modified scripts pass bash syntax check**

Run: `bash -n scripts/setup/10-apt.sh && bash -n scripts/setup/25-audio.sh && echo "OK"`
Expected: `OK`

- [ ] **Step 2: Verify Dockerfile has no obvious issues**

Run: `grep -n 'WHISPER_CPP_MODEL\|25-audio' Dockerfile`
Expected output should show the env var and the COPY+RUN lines.

- [ ] **Step 3: Verify 25-audio.sh is executable**

Run: `ls -la scripts/setup/25-audio.sh`
Expected: `-rwxr-xr-x` permissions

---

**Note:** Full image build + runtime testing is done via `test/smoke.sh` per AGENTS.md. This plan covers the static changes only.
