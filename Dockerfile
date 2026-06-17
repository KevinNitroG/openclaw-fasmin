# syntax=docker/dockerfile:1

# Plain Debian base — node is provided by mise (single, renovate-tracked source of truth),
# not by the base image. Pinned by digest; Renovate's docker manager keeps it current.
FROM debian:bookworm-slim@sha256:96e378d7e6531ac9a15ad505478fcc2e69f371b10f5cdf87857c4b8188404716

# --- build args ---
# Single source for the persisted data root; the OPENCLAW paths below derive from it.
# This image runs entirely as root; HOME is /root.
ARG DATA_DIR=/root/data
# renovate: datasource=github-releases depName=jdx/mise
ARG MISE_VERSION=v2026.6.10
ARG OPENCLAW_INSTALL_BROWSER=1
ARG TZ=Asia/Ho_Chi_Minh

# --- baked environment (OPENCLAW paths + PATH derive from DATA_DIR / /root) ---
# mise's shims dir is on PATH on purpose: the gateway is launched NON-interactively
# (entrypoint -> supervisor -> openclaw), so `mise activate` in .bashrc never runs for it.
# Per mise docs, putting the shims dir on PATH is the way to resolve tools in init-script
# / non-interactive contexts. .local/bin holds the mise binary itself.
ENV DATA_DIR=${DATA_DIR} \
    TZ=${TZ} \
    NODE_ENV=production \
    EDITOR=vim \
    DO_NOT_TRACK=1 \
    NEXT_TELEMETRY_DISABLED=1 \
    CLAWHUB_DISABLE_TELEMETRY=1 \
    OPENCLAW_DISABLE_BONJOUR=1 \
    OPENCLAW_STATE_DIR=${DATA_DIR}/openclaw \
    OPENCLAW_CONFIG_PATH=${DATA_DIR}/openclaw/openclaw.json \
    OPENCLAW_WORKSPACE_DIR=${DATA_DIR}/openclaw-workspace \
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
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/gateway-supervisor.sh \
             /usr/local/bin/claw-gateway-restart

# Login shells (Railway shell, `su -`) reset the environment, dropping vars set only via ENV.
# Snapshot the OPENCLAW/runtime env into a profile.d script so interactive login shells point
# at the same state dir/config as the gateway (else `openclaw onboard` writes to ~/.openclaw).
# Generated FROM the ENV above — single source of truth, no hardcoded duplication. Each var is
# emitted as `${VAR:-<baked>}` so a runtime `-e VAR=...` override still wins in the shell (e.g.
# `-e TZ=...`), matching what the gateway process sees instead of clobbering it back.
RUN for v in TZ DATA_DIR OPENCLAW_STATE_DIR OPENCLAW_CONFIG_PATH OPENCLAW_WORKSPACE_DIR \
             DO_NOT_TRACK NEXT_TELEMETRY_DISABLED CLAWHUB_DISABLE_TELEMETRY OPENCLAW_DISABLE_BONJOUR; do \
      printf 'export %s="${%s:-%s}"\n' "$v" "$v" "$(printenv "$v")"; \
    done > /etc/profile.d/10-openclaw-env.sh

EXPOSE 18789
ENTRYPOINT ["tini", "-s", "--"]
CMD ["/usr/local/bin/entrypoint.sh"]
