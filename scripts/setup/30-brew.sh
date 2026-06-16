#!/usr/bin/env bash
# Install Homebrew non-interactively. Purpose: availability for the agent at runtime.
# Runs as the non-root claw user (Homebrew refuses root); claw has passwordless sudo,
# which the installer uses to create /home/linuxbrew.
set -euo pipefail
NONINTERACTIVE=1 /bin/bash -c \
  "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
/home/linuxbrew/.linuxbrew/bin/brew --version
