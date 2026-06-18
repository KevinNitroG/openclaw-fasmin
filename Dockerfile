# syntax=docker/dockerfile:1

# Plain Debian base — node is provided by mise (single, renovate-tracked source of truth),
# not by the base image. Pinned by digest; Renovate's docker manager keeps it current.
FROM debian:bookworm-slim@sha256:96e378d7e6531ac9a15ad505478fcc2e69f371b10f5cdf87857c4b8188404716

# --- build args ---
# renovate: datasource=github-releases depName=jdx/mise
ARG MISE_VERSION=v2026.6.10
ARG OPENCLAW_INSTALL_BROWSER=1
ARG TZ=Asia/Ho_Chi_Minh

# --- baked environment ---
# OpenClaw path vars (OPENCLAW_STATE_DIR / OPENCLAW_CONFIG_PATH / OPENCLAW_WORKSPACE_DIR)
# are intentionally LEFT UNSET so OpenClaw uses its own defaults under HOME (/root):
# state /root/.openclaw, config /root/.openclaw/openclaw.json, workspace /root/.openclaw/workspace.
# An operator can override any one of them independently at runtime.
# mise's shims dir is on PATH on purpose: the gateway is launched NON-interactively
# (entrypoint -> supervisor -> openclaw), so `mise activate` in .bashrc never runs for it.
# Per mise docs, putting the shims dir on PATH is the way to resolve tools in init-script
# / non-interactive contexts. .local/bin holds the mise binary itself.
ENV TZ=${TZ} \
  NODE_ENV=production \
  EDITOR=vim \
  DO_NOT_TRACK=1 \
  NEXT_TELEMETRY_DISABLED=1 \
  CLAWHUB_DISABLE_TELEMETRY=1 \
  OPENCLAW_DISABLE_BONJOUR=1 \
  PATH=/root/.local/bin:/root/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- layer 1: system packages (changes rarely) ---
COPY scripts/setup/10-apt.sh /tmp/setup/10-apt.sh
RUN OPENCLAW_INSTALL_BROWSER=${OPENCLAW_INSTALL_BROWSER} /tmp/setup/10-apt.sh \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /root

# --- layer 2: mise binary ---
COPY scripts/setup/20-mise.sh /tmp/setup/20-mise.sh
RUN MISE_VERSION=${MISE_VERSION} /tmp/setup/20-mise.sh

# --- layer 3: tools (re-runs only when mise.claw.toml changes) ---
COPY mise.claw.toml /root/.config/mise/config.toml
RUN mise install

# Pre-generate bash completion once at build (after openclaw is installed). NOT --write-state:
# that targets the volume-backed state dir, which the runtime mount would hide. Bake it to a
# fixed home path instead; .bashrc sources this so shells don't invoke openclaw on every start.
RUN mkdir -p /root/.local/share/bash-completion \
  && mise exec -- openclaw completion --shell bash \
  > /root/.local/share/bash-completion/openclaw.bash

# --- layer 4: config + runtime scripts (changes most often) ---
COPY config/bashrc  /root/.bashrc
COPY config/profile /root/.profile
COPY config/vimrc   /root/.vimrc
COPY scripts/entrypoint.sh scripts/gateway-supervisor.sh scripts/claw-gateway-restart \
  /usr/local/bin/

# No /etc/profile.d env snapshot is needed: the image runs entirely as root with no `su -`
# switch, so interactive shells (Railway shell, `docker exec`) inherit the baked ENV directly.
# (PATH is the one exception — Debian's /etc/profile resets it for login shells — which is why
# config/profile re-adds the mise shims.)

EXPOSE 18789
ENTRYPOINT ["tini", "-s", "--"]
CMD ["/usr/local/bin/entrypoint.sh"]
