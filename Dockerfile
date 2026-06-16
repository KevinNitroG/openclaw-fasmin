# syntax=docker/dockerfile:1

# Plain Debian base — node is provided by mise (single, renovate-tracked source of truth),
# not by the base image. Pinned by digest; Renovate's docker manager keeps it current.
FROM debian:bookworm-slim@sha256:96e378d7e6531ac9a15ad505478fcc2e69f371b10f5cdf87857c4b8188404716

# --- build args ---
# Single source for the user home + persisted data root; everything below derives from these.
ARG CLAW_HOME=/home/claw
ARG DATA_DIR=${CLAW_HOME}/data
# renovate: datasource=github-releases depName=jdx/mise
ARG MISE_VERSION=v2026.6.10
ARG OPENCLAW_INSTALL_BROWSER=1
ARG TZ=Asia/Ho_Chi_Minh

# --- baked environment (OPENCLAW paths + PATH derive from CLAW_HOME / DATA_DIR) ---
ENV CLAW_HOME=${CLAW_HOME} \
    DATA_DIR=${DATA_DIR} \
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
    PATH=${CLAW_HOME}/.local/bin:${CLAW_HOME}/.local/share/mise/shims:/home/linuxbrew/.linuxbrew/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- user: claw (uid 1000) with passwordless sudo ---
RUN set -eux; \
    useradd -m -d "${CLAW_HOME}" -u 1000 -s /bin/bash claw; \
    mkdir -p /etc/sudoers.d; \
    echo 'claw ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/claw; \
    chmod 0440 /etc/sudoers.d/claw

# --- layer 1: system packages (changes rarely) ---
COPY scripts/setup/10-apt.sh /tmp/setup/10-apt.sh
RUN OPENCLAW_INSTALL_BROWSER=${OPENCLAW_INSTALL_BROWSER} /tmp/setup/10-apt.sh \
    && rm -rf /var/lib/apt/lists/*

# --- switch to claw for user-space installs ---
USER claw
WORKDIR ${CLAW_HOME}

# --- layer 2: mise binary ---
COPY --chown=claw:claw scripts/setup/20-mise.sh /tmp/setup/20-mise.sh
RUN MISE_VERSION=${MISE_VERSION} /tmp/setup/20-mise.sh

# --- layer 3: tools (re-runs only when mise.claw.toml changes) ---
COPY --chown=claw:claw mise.claw.toml ${CLAW_HOME}/.config/mise/config.toml
RUN mise install

# Pre-generate bash completion once at build (after openclaw is installed). NOT --write-state:
# that targets the volume-backed state dir, which the runtime mount would hide. Bake it to a
# fixed home path instead; .bashrc sources this so shells don't invoke openclaw on every start.
RUN mkdir -p "${CLAW_HOME}/.local/share/bash-completion" \
    && mise exec -- openclaw completion --shell bash \
       > "${CLAW_HOME}/.local/share/bash-completion/openclaw.bash"

# --- layer 4: Homebrew (agent availability) ---
COPY --chown=claw:claw scripts/setup/30-brew.sh /tmp/setup/30-brew.sh
RUN /tmp/setup/30-brew.sh

# --- layer 5: config + runtime scripts (changes most often) ---
COPY --chown=claw:claw config/bashrc  ${CLAW_HOME}/.bashrc
COPY --chown=claw:claw config/profile ${CLAW_HOME}/.profile
COPY --chown=claw:claw config/vimrc   ${CLAW_HOME}/.vimrc
COPY scripts/entrypoint.sh scripts/gateway-supervisor.sh scripts/claw-gateway-restart \
     /usr/local/bin/

# Make the runtime scripts executable (needs root); the default USER is set to claw below.
USER root
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/gateway-supervisor.sh \
             /usr/local/bin/claw-gateway-restart

# Railway/`docker exec` open shells as root, bypassing USER claw; hand interactive root
# shells to claw so they get the toolbelt. Covers both login and non-login bash.
COPY config/root-bashrc /root/.bashrc
RUN printf '[ -f ~/.bashrc ] && . ~/.bashrc\n' > /root/.bash_profile

# Login shells (su - claw, Railway shell) reset the environment, dropping vars set only via
# ENV. Snapshot the OPENCLAW/runtime env into a profile.d script so interactive shells point
# at the same state dir/config as the gateway (else `openclaw onboard` writes to ~/.openclaw).
# Generated FROM the ENV above — single source of truth, no hardcoded duplication.
RUN for v in TZ DATA_DIR OPENCLAW_STATE_DIR OPENCLAW_CONFIG_PATH OPENCLAW_WORKSPACE_DIR \
             DO_NOT_TRACK NEXT_TELEMETRY_DISABLED CLAWHUB_DISABLE_TELEMETRY OPENCLAW_DISABLE_BONJOUR; do \
      printf 'export %s="%s"\n' "$v" "$(printenv "$v")"; \
    done > /etc/profile.d/10-openclaw-env.sh

# Run as claw: the gateway and interactive shells (Railway shell / docker exec) get claw's
# full config (mise, brew, zoxide, vim, openclaw completion). The entrypoint claims the
# runtime volume via claw's passwordless sudo.
USER claw
EXPOSE 18789
ENTRYPOINT ["tini", "-s", "--"]
CMD ["/usr/local/bin/entrypoint.sh"]
