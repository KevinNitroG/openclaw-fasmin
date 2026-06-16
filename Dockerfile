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
ENV TZ=${TZ} \
    NODE_ENV=production \
    EDITOR=vim \
    DO_NOT_TRACK=1 \
    NEXT_TELEMETRY_DISABLED=1 \
    CLAWHUB_DISABLE_TELEMETRY=1 \
    OPENCLAW_DISABLE_BONJOUR=1 \
    OPENCLAW_STATE_DIR=/home/claw/data/openclaw \
    OPENCLAW_CONFIG_PATH=/home/claw/data/openclaw/openclaw.json \
    OPENCLAW_WORKSPACE_DIR=/home/claw/data/openclaw-workspace \
    PATH=/home/claw/.local/bin:/home/claw/.local/share/mise/shims:/home/linuxbrew/.linuxbrew/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- user: claw (uid 1000) with passwordless sudo ---
RUN set -eux; \
    useradd -m -u 1000 -s /bin/bash claw; \
    mkdir -p /etc/sudoers.d; \
    echo 'claw ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/claw; \
    chmod 0440 /etc/sudoers.d/claw

# --- layer 1: system packages (changes rarely) ---
COPY scripts/setup/10-apt.sh /tmp/setup/10-apt.sh
RUN OPENCLAW_INSTALL_BROWSER=${OPENCLAW_INSTALL_BROWSER} /tmp/setup/10-apt.sh \
    && rm -rf /var/lib/apt/lists/*

# --- switch to claw for user-space installs ---
USER claw
WORKDIR /home/claw

# --- layer 2: mise binary ---
COPY --chown=claw:claw scripts/setup/20-mise.sh /tmp/setup/20-mise.sh
RUN MISE_VERSION=${MISE_VERSION} /tmp/setup/20-mise.sh

# --- layer 3: tools (re-runs only when mise.claw.toml changes) ---
COPY --chown=claw:claw mise.claw.toml /home/claw/.config/mise/config.toml
RUN mise install

# --- layer 4: Homebrew (agent availability) ---
COPY --chown=claw:claw scripts/setup/30-brew.sh /tmp/setup/30-brew.sh
RUN /tmp/setup/30-brew.sh

# --- layer 5: config + runtime scripts (changes most often) ---
COPY --chown=claw:claw config/bashrc  /home/claw/.bashrc
COPY --chown=claw:claw config/profile /home/claw/.profile
COPY --chown=claw:claw config/vimrc   /home/claw/.vimrc
COPY scripts/entrypoint.sh scripts/gateway-supervisor.sh scripts/claw-gateway-restart \
     /usr/local/bin/

# scripts copied as root-owned + executable; entrypoint runs as root (see below)
USER root
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/gateway-supervisor.sh \
             /usr/local/bin/claw-gateway-restart

EXPOSE 18789
# tini as PID 1; entrypoint runs as root, fixes the volume, drops to claw.
ENTRYPOINT ["tini", "-s", "--"]
CMD ["/usr/local/bin/entrypoint.sh"]
