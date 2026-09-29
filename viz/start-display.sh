#!/usr/bin/env bash
# Start the booth display server on THIS machine (the workstation driving the
# booth monitor -- NOT one of the Spark nodes).
#
# Idempotent: if the port is already serving, it says so and exits 0 rather
# than starting a second copy.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

PORT="${E2_PORT:-8500}"
HOST="${E2_HOST:-0.0.0.0}"
export E2_FRAMES="${E2_FRAMES:-$HOME/e2viz/frames}"

c_grn() { printf '\033[32m%s\033[0m\n' "$*"; }
c_red() { printf '\033[31m%s\033[0m\n' "$*"; }
c_ylw() { printf '\033[33m%s\033[0m\n' "$*"; }

# Already up?
if curl -s -o /dev/null --max-time 3 "http://127.0.0.1:${PORT}/api/state" 2>/dev/null; then
  c_ylw "Already serving on port ${PORT} -- nothing to do."
  ip -4 -br addr 2>/dev/null | awk '$1!="lo" && $2=="UP" {split($3,a,"/"); if (a[1]!="") print "  http://" a[1] ":'"${PORT}"'/display"}'
  exit 0
fi

# Deps present?
missing=$(python3 - <<'PY'
# NOTE: `import importlib` alone does NOT expose importlib.util -- the submodule
# must be imported explicitly, or this raises
# AttributeError: module 'importlib' has no attribute 'util'
# and the dependency check silently stops catching missing packages.
import importlib.util
need = {"fastapi":"fastapi","uvicorn":"uvicorn","jinja2":"jinja2","PIL":"pillow","numpy":"numpy"}
print(" ".join(p for m,p in need.items() if importlib.util.find_spec(m) is None))
PY
)
if [[ -n "${missing// /}" ]]; then
  c_red "Missing Python packages: $missing"
  echo "Install them with:"
  echo "    pip install -r $REPO/viz/requirements.txt"
  exit 1
fi

# Frames rendered?
if [[ ! -f "$E2_FRAMES/manifest.json" ]]; then
  c_ylw "No rendered frames at $E2_FRAMES"
  echo "The display will come up empty. To populate it:"
  echo "    $REPO/scripts/collect.sh        # pull member output from the nodes"
  echo "    python3 $REPO/viz/render.py     # render globes + spread maps"
  echo
fi

c_grn "Starting booth display on port ${PORT} (frames: $E2_FRAMES)"
cd "$REPO" || exit 1
nohup python3 -m uvicorn viz.server:app --host "$HOST" --port "$PORT" \
  > /tmp/e2-display.log 2>&1 &
disown

for _ in $(seq 1 20); do
  sleep 0.5
  if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${PORT}/api/state" 2>/dev/null; then
    c_grn "Up. Open these:"
    ip -4 -br addr 2>/dev/null | awk '$1!="lo" && $2=="UP" {split($3,a,"/"); if (a[1]!="") {print "  display : http://" a[1] ":'"${PORT}"'/display"; print "  operator: http://" a[1] ":'"${PORT}"'/operator"}}'
    echo "  log     : /tmp/e2-display.log"
    exit 0
  fi
done

c_red "Server did not come up. Last 20 lines of /tmp/e2-display.log:"
tail -20 /tmp/e2-display.log
exit 1
