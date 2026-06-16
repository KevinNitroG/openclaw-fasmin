#!/usr/bin/env bash
# System packages: toolbelt + yazi (+deps) + chromium + build/runtime deps.
# apt versions are intentionally unpinned (Debian repos drop old versions).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
# init, privilege drop, build deps for Homebrew, and the base toolbelt
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg git tini gosu sudo less coreutils \
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
