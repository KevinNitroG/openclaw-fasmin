# Agent guidance

This repo builds a self-contained Docker image (OpenClaw gateway + CLI toolbelt) for Railway.
It runs entirely as **root**; `HOME` is `/root` and all state lives under `/root/.openclaw`.

## Working on the host

- **Do not run tests or any scripts on the host machine during development.** This includes
  `scripts/`, `scripts/setup/*`, and anything that builds or runs the image. Edit files and
  reason about them statically (read, `grep`, `bash -n` syntax checks) instead.
- **`test/smoke.sh` is very slow** — it builds the full Docker image and boots a container.
  Run it only when necessary (e.g. after substantive changes to the Dockerfile, entrypoint,
  setup scripts, or shell config), not as a routine check.
