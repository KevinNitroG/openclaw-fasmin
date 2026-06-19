# Local Audio Transcription Design

**Date**: 2026-06-19
**Goal**: Enable agents to transcribe voice messages locally without calling external APIs.

## Summary

Add whisper-cpp with the base model to the Docker image so OpenClaw auto-detects local transcription. No API keys or network calls needed at runtime.

## Components

### 1. `scripts/setup/10-apt.sh` — add whisper-cpp package

Add `whisper-cpp` to the `base_packages` array. This installs the `whisper-cli` binary that OpenClaw's auto-detection looks for.

### 2. `scripts/setup/25-audio.sh` — new setup script

Handles model download during image build:

- Downloads `ggml-base.bin` from Hugging Face (whisper.cpp official converted model)
- Places it at `/root/.openclaw/models/whisper/ggml-base.bin`
- Creates the directory structure under the OpenClaw state dir

### 3. `Dockerfile` — wire up the new script

Add after the `20-mise.sh` block:

```dockerfile
COPY scripts/setup/25-audio.sh /tmp/setup/25-audio.sh
RUN /tmp/setup/25-audio.sh
```

### 4. Environment variable

Set `WHISPER_CPP_MODEL` in the Dockerfile ENV block:

```
WHISPER_CPP_MODEL=/root/.openclaw/models/whisper/ggml-base.bin
```

This ensures OpenClaw's auto-detection finds the model without explicit config.

## Auto-detection flow

OpenClaw checks in order:
1. Active reply model (if it supports audio)
2. Local CLIs — `whisper-cli` is found on PATH, model located via `WHISPER_CPP_MODEL`
3. Provider APIs (fallback)

With this setup, local transcription is tried before any paid API.

## Image size impact

- whisper-cpp package: ~50MB
- base model: ~142MB
- Total: ~192MB added to image

## What's NOT in scope

- No OpenClaw config changes needed (auto-detection handles it)
- No provider API keys required
- No runtime network calls for transcription
- Model size is fixed at build time (base model)

## Verification

After building, run:
```bash
whisper-cli --help  # binary exists
ls -la /root/.openclaw/models/whisper/ggml-base.bin  # model exists
```

OpenClaw should auto-detect without config. Test by sending a voice message to the agent.
