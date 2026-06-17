# Root-only container refactor

**Date:** 2026-06-17
**Status:** Approved

## Goal

The image currently splits the build between `root` (apt) and a `claw` user
(uid 1000, passwordless sudo) purely so Homebrew can be installed (Homebrew
refuses to run as root). We are dropping Homebrew. With it gone, the `claw`
user, its sudo grant, and the root↔claw shell hand-off are all dead weight.

Make this a clean, single-purpose **root-only** image: every build step and
every runtime script runs as root, and the home directory moves from
`/home/claw` to `/root`.

## Decisions

- **Naming:** drop the `CLAW_HOME` build arg entirely; reference `/root`
  directly. `DATA_DIR` becomes `/root/data` (hardcoded — `/root` is fixed).
- **`mise.claw.toml`:** keep the filename. The rename-from-`mise.toml` exists so
  a host/agent `mise` never auto-detects it; that reason is independent of which
  user runs the container.
- **`build-essential`:** drop it. It was only present as a Homebrew build
  dependency.
- **`sudo`:** drop the package. Root needs no sudo, and there is no other user.
- **PATH / mise:** keep the shims directory on the image `ENV PATH`. Per mise
  docs, baking `~/.local/share/mise/shims` into PATH is the recommended way to
  make tools resolvable in **non-interactive / init-script** contexts — which is
  exactly how the gateway is launched (entrypoint → supervisor, no interactive
  shell, so `mise activate` in `.bashrc` never runs for it). Interactive shells
  still get `eval "$(mise activate bash)"` via `.bashrc`. The only PATH entry
  removed is the linuxbrew path.

## Changes

### Dockerfile

- **Build args:** remove `CLAW_HOME` and `DATA_DIR` derivation from it. Set
  `ARG DATA_DIR=/root/data`. Keep `MISE_VERSION`, `OPENCLAW_INSTALL_BROWSER`,
  `TZ`.
- **ENV:** remove `CLAW_HOME`. `OPENCLAW_*` paths derive from `DATA_DIR`.
  New `PATH`:
  `/root/.local/bin:/root/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`
  (linuxbrew removed).
- **Remove the user block:** no `useradd`, no `/etc/sudoers.d/claw`.
- **Remove every `USER claw` / `USER root` switch and all `--chown=claw:claw`** —
  the build runs as root throughout (implicit default).
- **Remove the Homebrew layer** (`COPY scripts/setup/30-brew.sh` + its `RUN`).
- **Config copies retarget to `/root`:** `config/bashrc → /root/.bashrc`,
  `config/profile → /root/.profile`, `config/vimrc → /root/.vimrc`, mise config →
  `/root/.config/mise/config.toml`, completion →
  `/root/.local/share/bash-completion/openclaw.bash`.
- **Remove the `root-bashrc` + `/root/.bash_profile` bounce block** — root is now
  the only user; there is nothing to hand off to.
- **Keep** the `/etc/profile.d/10-openclaw-env.sh` generation: a root *login*
  shell (Railway shell, `su -`) still resets the environment, so the snapshot
  keeps interactive shells pointed at the gateway's state dir/config.
- **Final stage:** no `USER` line. `ENTRYPOINT`/`CMD` unchanged.

### scripts/setup/

- **`10-apt.sh`:** remove `sudo` and `build-essential` from `base_packages`;
  everything else unchanged.
- **`20-mise.sh`:** no change — already uses `$HOME` (now `/root`).
- **`30-brew.sh`:** **delete.**

### scripts/entrypoint.sh

- `DATA_DIR` default → `/root/data`.
- **Remove the sudo-based volume-claim block** (the `stat`/`chown` dance). As
  root the gateway can read/write the volume regardless of file ownership, so the
  ownership check and the `sudo chown -R` are no longer needed.
- Keep `mkdir -p` for the state/workspace dirs and the best-effort
  `chmod 700/600` hardening of `credentials/` and the config file.
- Rewrite the header comment to describe the root-only model.

### config/

- **`bashrc`:** drop the linuxbrew segment from `PATH`; update the header comment
  to `/root`.
- **`profile`:** drop the linuxbrew segment from `PATH`; update the header
  comment to `/root`.
- **`root-bashrc`:** **delete** (no longer referenced).
- **`vimrc`:** no change.

### mise.claw.toml

- Keep filename. Update the comment's path reference to
  `/root/.config/mise/config.toml`.

### railway.toml

- Update the comment that documents the volume mount path:
  `/home/claw/data → /root/data`. No build/deploy stanza changes needed.

### README

- Update all references to reflect the root-only model and the `/root/data`
  volume path. Document it as if root-only is the design — **do not** describe a
  migration from the `claw` user.

## Out of scope / operator action

- **Railway volume:** the operator must re-point the service's volume mount path
  to `/root/data` in the Railway dashboard. Existing data under the old mount is
  not moved automatically. (Acknowledged by the user.)

## Risks (accepted)

- The OpenClaw gateway and the agent (including the browser) run as **root**
  inside the container. Acceptable for this single-tenant, niche deployment.
- Losing Homebrew means the agent cannot `brew install` at runtime; it has mise
  and apt instead. Intended.
