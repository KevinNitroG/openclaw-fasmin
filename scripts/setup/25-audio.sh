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
