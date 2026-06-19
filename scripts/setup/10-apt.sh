#!/usr/bin/env bash
# System packages. apt versions are intentionally unpinned (Debian repos drop old versions).
# Packages are grouped declaratively below — add/remove a line in the relevant array.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Packages from the base Debian repos (installed BEFORE the yazi apt repo is added).
base_packages=(
  # essential: TLS certs, fetch, gpg, vcs, init, pager, core utils
  ca-certificates curl gnupg git tini less coreutils procps file
  # cli toolbelt
  ripgrep fzf vim zoxide fd-find jq ffmpeg tmux
  # shell completion framework (not present in bookworm-slim by default)
  bash-completion
  # runtime lib required by pnpm (libatomic.so.1)
  libatomic1
)

# yazi + the previewers/extractors it integrates with (needs the griffo.io apt repo).
yazi_packages=(
  yazi ffmpegthumbnailer p7zip-full poppler-utils imagemagick
)

# browser for the agent (optional; toggled by OPENCLAW_INSTALL_BROWSER).
browser_packages=(
  chromium fonts-liberation
)

# --- base packages ---
apt-get update
apt-get install -y --no-install-recommends "${base_packages[@]}"

# --- yazi apt repo, then yazi + deps ---
curl -sS https://debian.griffo.io/EA0F721D231FDD3A0A17B9AC7808B4DD62C41256.asc \
  | gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/debian.griffo.io.gpg
echo "deb https://debian.griffo.io/apt $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
  > /etc/apt/sources.list.d/debian.griffo.io.list
apt-get update
apt-get install -y --no-install-recommends "${yazi_packages[@]}"

# --- browser (default on) ---
if [ "${OPENCLAW_INSTALL_BROWSER:-1}" = "1" ]; then
  apt-get install -y --no-install-recommends "${browser_packages[@]}"
fi

# --- whisper.cpp (audio transcription) from sid repo ---
# whisper.cpp-tools is only available in Debian sid (unstable), not in trixie.
# Add sid temporarily, pin to low priority so it doesn't pull in sid packages
# for anything else, install whisper.cpp-tools, then remove the repo.
echo "deb http://deb.debian.org/debian sid main" \
  > /etc/apt/sources.list.d/debian-sid.list
echo "Package: *\nPin: release a=unstable\nPin-Priority: 100" \
  > /etc/apt/preferences.d/pin-sid
apt-get update -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/debian-sid.list \
  -o Dir::Etc::sourceparts="-"
apt-get install -y --no-install-recommends -t unstable whisper.cpp-tools
rm -f /etc/apt/sources.list.d/debian-sid.list /etc/apt/preferences.d/pin-sid

apt-get clean
