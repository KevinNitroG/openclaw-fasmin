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
  -v "$VOL:/home/claw/data" \
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

echo "== toolbelt =="
docker exec -u claw "$NAME" bash -lc '
  set -e
  openclaw --version
  rg --version | head -1
  fzf --version
  yazi --version
  vim --version | head -1
  gh --version | head -1
  uv --version
  brew --version | head -1
  sudo -n true && echo SUDO_OK
'

echo "== browser (informational) =="
docker exec "$NAME" bash -lc 'command -v chromium && chromium --version' \
  || echo "chromium absent (ok only if built with OPENCLAW_INSTALL_BROWSER=0)"

echo "== data dirs =="
docker exec "$NAME" bash -lc '
  test -d /home/claw/data/openclaw &&
  test -d /home/claw/data/openclaw-workspace &&
  stat -c "%U" /home/claw/data/openclaw | grep -qx claw &&
  echo DIRS_OK
'

echo "ALL SMOKE CHECKS PASSED"
