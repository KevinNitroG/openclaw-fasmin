#!/usr/bin/env bash

mkdir -p /root/.local/share/bash-completion
openclaw completion --shell bash >"${HOME}/.local/share/bash-completion/openclaw"
gog completion bash >"${HOME}/.local/share/bash-completion/gog"
gh completion -s bash >"${HOME}/.local/share/bash-completion/gh"
pnpm completion bash >"${HOME}/.local/share/bash-completion/pnpm"
uv generate-shell-completion bash >"${HOME}/.local/share/bash-completion/uv"
uvx --generate-shell-completion bash >"${HOME}/.local/share/bash-completion/completions/uvx"
opencode completion bash >"${HOME}/.local/share/bash-completion/opencode"
npm completion bash >"${HOME}/.local/share/bash-completion/npm"
