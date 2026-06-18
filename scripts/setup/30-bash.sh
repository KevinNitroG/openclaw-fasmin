#!/usr/bin/env bash
# Bake shell completions. The bash-completion framework (installed via apt) lazy-loads
# these on demand by command name from the per-user completions dir.
set -euo pipefail

completions_dir="${HOME}/.local/share/bash-completion/completions"
mkdir -p "${completions_dir}"

openclaw completion --shell bash >"${completions_dir}/openclaw"
gog completion bash >"${completions_dir}/gog"
gh completion -s bash >"${completions_dir}/gh"
pnpm completion bash >"${completions_dir}/pnpm"
uv generate-shell-completion bash >"${completions_dir}/uv"
uvx --generate-shell-completion bash >"${completions_dir}/uvx"
opencode completion bash >"${completions_dir}/opencode"
npm completion bash >"${completions_dir}/npm"
