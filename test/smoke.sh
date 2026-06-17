#!/usr/bin/env bash
# Build the image and exercise it in a REAL temporary container, then tear down.
# Usage: test/smoke.sh           (builds the image first)
#        SKIP_BUILD=1 test/smoke.sh   (reuse an already-built IMAGE)
#        IMAGE=foo:bar test/smoke.sh  (use a specific image tag)
set -euo pipefail

IMAGE="${IMAGE:-openclaw-fasmin:smoke}"
NAME="claw-smoke-$$"
VOL="claw-smoke-$$"

cleanup() {
  docker rm -f "$NAME"  >/dev/null 2>&1 || true
  docker volume rm "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  echo "== build =="
  docker build -t "$IMAGE" .
fi

echo "== run =="
docker volume create "$VOL" >/dev/null
docker run -d --name "$NAME" \
  -e OPENCLAW_GATEWAY_TOKEN=smoke-token \
  -v "$VOL:/root/data" \
  -p 18789 "$IMAGE" >/dev/null

echo "== wait for /healthz =="
ok=0
for i in $(seq 1 60); do
  if docker exec "$NAME" curl -fsS http://127.0.0.1:18789/healthz >/dev/null 2>&1; then
    ok=1; echo "gateway healthy after ${i} tries"; break
  fi
  sleep 2
done
if [ "$ok" != "1" ]; then
  echo "FAIL: gateway never became healthy"; docker logs "$NAME"; exit 1
fi

echo "== runs as root =="
docker exec "$NAME" bash -lc 'test "$(id -un)" = root && echo ROOT_OK'

echo "== toolbelt =="
docker exec "$NAME" bash -lc '
  set -e
  openclaw --version
  rg --version | head -1
  fzf --version
  yazi --version
  vim --version | head -1
  gh --version | head -1
  uv --version
'

# Every tool declared in mise.claw.toml must be on PATH and resolve under mise's data
# dir (shims at /root/.local/share/mise/shims, installs at .../installs). We prefix-match
# that dir rather than asserting `mise which` so the check holds however PATH is wired.
echo "== mise-managed tools =="
docker exec "$NAME" bash -lc '
  set -eu
  prefix=/root/.local/share/mise
  # command name <- mise.claw.toml entry:
  #   node, openclaw(npm), ctx7(npm), pnpm, uv, gh, gog(github:openclaw/gogcli), lazygit, htmlq, opencode, python
  tools="node openclaw ctx7 pnpm uv gh gog lazygit htmlq opencode python"
  fail=0
  for t in $tools; do
    if ! p="$(command -v "$t" 2>/dev/null)"; then
      echo "  MISSING: $t (not on PATH)"; fail=1; continue
    fi
    # resolve symlinks too, so the assertion survives either shim or install layout
    rp="$(readlink -f "$p" 2>/dev/null || echo "$p")"
    if [ "${p#"$prefix"/}" != "$p" ] || [ "${rp#"$prefix"/}" != "$rp" ]; then
      echo "  ok: $t -> $p"
    else
      echo "  WRONG PREFIX: $t -> $p (resolved $rp; expected under $prefix)"; fail=1
    fi
  done
  [ "$fail" = 0 ] && echo MISE_TOOLS_OK || { echo "FAIL: mise tool check"; exit 1; }
'

echo "== browser (informational) =="
docker exec "$NAME" bash -lc 'command -v chromium && chromium --version' \
  || echo "chromium absent (ok only if built with OPENCLAW_INSTALL_BROWSER=0)"

echo "== data dirs =="
docker exec "$NAME" bash -lc '
  test -d /root/data/openclaw &&
  test -d /root/data/openclaw-workspace &&
  echo DIRS_OK
'

echo "ALL SMOKE CHECKS PASSED"
