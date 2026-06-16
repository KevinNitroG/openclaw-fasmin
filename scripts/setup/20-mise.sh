#!/usr/bin/env bash
# Install the mise binary, pinned to $MISE_VERSION, into the claw user's ~/.local/bin.
set -euo pipefail
curl -fsSL https://mise.run | \
  MISE_VERSION="${MISE_VERSION}" MISE_INSTALL_PATH="${HOME}/.local/bin/mise" sh
mkdir -p "${HOME}/.config/mise"
"${HOME}/.local/bin/mise" --version
