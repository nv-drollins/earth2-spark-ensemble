#!/usr/bin/env bash
# Run CorrDiff downscaling on one node and collect the result.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DATE="${DATE:-$(date -u -d '2 days ago' +%Y-%m-%d)}"
[[ "${1:-}" == "--date" ]] && { DATE="$2"; shift 2; }
OUTDIR="${OUTDIR:-$HOME/e2out}"
RUNDIR="${RUNDIR:-$HOME/e2run}"
LOCAL="${E2_DATA:-$HOME/e2viz/data}"

node="${NODE_ARR[0]}"
DP=$(docker_prefix_for "$node")
[[ "$DP" == "NEEDS_PASSWORD" ]] && { err "docker not usable on $node"; exit 1; }

on_node "$node" "mkdir -p '$OUTDIR' '$RUNDIR'"
scp -o BatchMode=yes -q "$REPO_ROOT/ensemble/run_corrdiff.py" "$node:$RUNDIR/run_corrdiff.py"

# Keep the progress lines, but never swallow a hard failure: piping straight
# into `grep CORRDIFF_DONE` hides docker errors (a wrong IMAGE tag surfaced
# only as "nothing collected", which reads like a CorrDiff bug, not a typo).
LOG=$(mktemp); trap 'rm -f "$LOG"' EXIT
if ! on_node "$node" "${DP}docker run --rm --gpus all --ipc=host \
  -v '$CACHE_DIR':/root/.cache -v '$OUTDIR':/out \
  -v '$RUNDIR/run_corrdiff.py':/run_corrdiff.py \
  '$IMAGE' python /run_corrdiff.py --date '$DATE' --outdir /out" >"$LOG" 2>&1; then
  err "CorrDiff failed on $node:"; tail -5 "$LOG" | sed 's/^/       /'
  grep -q 'Unable to find image' "$LOG" && \
    echo "       IMAGE='$IMAGE' is not on $node -- check: docker images | grep earth2"
  exit 1
fi
grep -E "CORRDIFF_DONE|corrdiff" "$LOG" | tail -2

mkdir -p "$LOCAL"
scp -o BatchMode=yes -q "$node:$OUTDIR/corrdiff*" "$LOCAL/" 2>/dev/null \
  && ok "collected" || { err "ran but collected nothing from $node:$OUTDIR"; exit 1; }
