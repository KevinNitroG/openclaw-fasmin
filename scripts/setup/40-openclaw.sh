#!/usr/bin/env bash

OFFICIAL_VERSION="2026.6.10"

declare -A PACKAGES=(
  ["@martian-engineering/lossless-claw"]="0.13.1"
)

for package in "${!PACKAGES[@]}"; do
  version="${PACKAGES[$package]}"
  echo "Installing OpenClaw $package@$version..."
  openclaw plugins install "$package@$version"
done
