# syntax=docker/dockerfile:1

# Plain Debian base — node is provided by mise (single, renovate-tracked source of truth),
# not by the base image. Pinned by digest; Renovate's docker manager keeps it current.
FROM debian:bookworm-slim@sha256:96e378d7e6531ac9a15ad505478fcc2e69f371b10f5cdf87857c4b8188404716

SHELL ["/bin/bash", "-c"]

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

COPY scripts/setup/10-apt.sh /tmp/setup/10-apt.sh
RUN OPENCLAW_INSTALL_BROWSER=${OPENCLAW_INSTALL_BROWSER} /tmp/setup/10-apt.sh \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /root

COPY scripts/setup/20-mise.sh /tmp/setup/20-mise.sh
RUN MISE_VERSION=${MISE_VERSION} /tmp/setup/20-mise.sh

COPY mise.claw.toml /root/.config/mise/config.toml
RUN mise install

COPY scripts/setup/30-bash.sh /tmp/setup/30-bash.sh
RUN /tmp/setup/30-bash.sh

COPY config/bashrc /root/.bashrc
COPY config/profile /root/.profile
COPY config/vimrc /root/.vimrc
COPY scripts/entrypoint.sh scripts/gateway-supervisor.sh scripts/claw-gateway-restart \
  /usr/local/bin/

EXPOSE 18789
ENTRYPOINT ["tini", "-s", "--"]
CMD ["/usr/local/bin/entrypoint.sh"]
