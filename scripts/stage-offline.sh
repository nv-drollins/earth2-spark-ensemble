#!/usr/bin/env bash
# Stage EVERYTHING the demo downloads, while you still have internet, and
# write a checksummed manifest so you can prove the USB copy survived.
#
# fetch-models.sh stages SFNO and nothing else. Three further downloads happen
# LATER, at run time, and each one fails silently-ish at an offline venue:
#
#   1. CorrDiff weights  -- run_corrdiff.py calls CorrDiffTaiwan.load_default_package()
#                           at RUN time. Missing => no rainfall panel, and
#                           render.py just omits it with no error.
#   2. GFS initial conds -- ensemble.sh fetches ic_$DATE.nc live from NOAA, and
#                           DATE defaults to "2 days ago", so it changes daily.
#                           Missing => every member silently falls back to its
#                           own GFS() call (see PITFALLS: corruption #2).
#   3. The agent LLM     -- ~30 GB of NVFP4 weights into ~/.cache/huggingface on
#                           the agent node, plus the vllm/vllm-openai image
#                           itself. Neither is in $BUNDLE_DIR or $CACHE_DIR.
#
# Usage:
#   ./scripts/stage-offline.sh                 # forecast stack (1 + 2)
#   ./scripts/stage-offline.sh --with-agent    # also the LLM image + weights
#   ./scripts/stage-offline.sh --date 2026-10-13
#   ./scripts/stage-offline.sh --verify        # re-check manifests, download nothing
#
# Everything is idempotent: already-staged artifacts are skipped, so this is
# safe to re-run the morning you leave.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

WITH_AGENT=0
VERIFY_ONLY=0
# Pin the IC date. Default matches ensemble.sh so the staged file is the one it
# will look for -- but pass --date explicitly if you are staging today for a
# show next week, and use the SAME date on the floor:
#   DATE=2026-10-13 ./scripts/ensemble.sh
STAGE_DATE="${E2_STAGE_DATE:-$(date -u -d '2 days ago' +%Y-%m-%d)}"
AGENT_MODEL="${E2_AGENT_MODEL:-nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4}"
VLLM_IMAGE="${E2_VLLM_IMAGE:-vllm/vllm-openai:latest}"
HF_CACHE="${E2_HF_CACHE:-\$HOME/.cache/huggingface}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-agent) WITH_AGENT=1; shift ;;
    --verify)     VERIFY_ONLY=1; shift ;;
    --date)       STAGE_DATE="${2:?--date needs YYYY-MM-DD}"; shift 2 ;;
    -h|--help)
      sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
    *) err "unknown argument: $1"; exit 1 ;;
  esac
done

AGENT_NODE="${E2_AGENT_NODE:-}"
TARBALL="$BUNDLE_DIR/$(echo "$IMAGE" | tr ':/' '__').tar.zst"

# ---------------------------------------------------------------------------
# Manifest helpers.
#
# Checksum the FILES THAT MATTER, not every file in the tree: the SFNO package
# alone is thousands of small entries and a full sha256 sweep of 7 GB over SSH
# is slow enough that operators skip it. One checksum per large artifact is
# what actually catches a truncated USB copy.
# ---------------------------------------------------------------------------
manifest_for() {
  # $1 = node, $2 = root dir, $3 = manifest path, rest = find expressions
  # Returns non-zero if the manifest was not actually written. Reporting "OK"
  # for a manifest that failed to write is worse than no manifest at all: the
  # whole point is to prove the USB copy is intact, and --verify would later
  # fail with a confusing "no manifest" on a bundle that staged fine.
  local node="$1" root="$2" mf="$3"; shift 3
  on_node "$node" "cd '$root' 2>/dev/null || exit 1
    find . -type f \\( $* \\) -size +1M -print0 2>/dev/null \\
      | sort -z | xargs -0 -r sha256sum > '$mf' || exit 1
    printf 'files=%s bytes=%s\n' \\
      \"\$(find . -type f 2>/dev/null | wc -l)\" \"\$(du -sb . 2>/dev/null | cut -f1)\" >> '$mf' || exit 1
    test -s '$mf'"
}

verify_manifest() {
  # Returns 0 only if every checksummed file still matches.
  #
  # A MISSING manifest is usually NOT a failure. $BUNDLE_DIR is a STAGING
  # directory, and two supported installs leave it without one -- or empty:
  #   * LAN install: distribute.sh streams only the tarball to nodes 2..N
  #     (ssh cat | ssh cat), so MANIFEST.sha256 never arrives.
  #   * USB install (INSTALL.md 3.0): the image is loaded straight off the
  #     stick and NOTHING is ever written to $BUNDLE_DIR on any node.
  # Demanding a manifest made both of those report "Verification FAILED" on a
  # complete, correct cluster.
  #
  # What actually proves a node is good is that $IMAGE is LOADED. A corrupt
  # archive cannot `docker load`, and a staging file that has since been
  # deleted says nothing either way. So: check the image first, and only fall
  # back to file checks when the image is genuinely absent.
  local node="$1" root="$2" mf="$3"
  if ! on_node "$node" "test -s '$mf'"; then
    # No manifest. Is this the bundle dir, and is the image already loaded?
    if [[ "$root" == "$(remote_path "$node" "$BUNDLE_DIR")" ]]; then
      local dp; dp=$(docker_prefix_for "$node")
      if [[ "$dp" != "NEEDS_PASSWORD" ]] && \
         on_node "$node" "${dp}docker image inspect '$IMAGE' >/dev/null 2>&1"; then
        ok "$(basename "$root"): $IMAGE is loaded -- staging dir not needed"
        return 0
      fi
    fi
    if on_node "$node" "ls '$root'/*.tar.zst >/dev/null 2>&1"; then
      ok "$(basename "$root"): no manifest here (streamed by distribute.sh) -- archive present"
      return 0
    fi
    warn "no manifest, no archive, and $IMAGE not loaded at $root -- stage first"
    return 1
  fi
  local out
  out=$(on_node "$node" "cd '$root' && grep -v '^files=' '$mf' | sha256sum -c --quiet 2>&1")
  if [[ -z "$out" ]]; then
    ok "$(basename "$root"): all checksums match"
    return 0
  fi
  err "$(basename "$root"): checksum MISMATCH"
  sed 's/^/       /' <<< "$out" | head -10
  return 1
}

human() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}"; }

# ---------------------------------------------------------------------------
# Verify mode -- no downloads, no containers. Run this AFTER the USB copy,
# on the machine you copied TO.
# ---------------------------------------------------------------------------
if [[ "$VERIFY_ONLY" -eq 1 ]]; then
  FAIL=0
  for node in "${NODE_ARR[@]}"; do
    hdr "$node"
    R_CACHE=$(remote_path "$node" "$CACHE_DIR")   || { FAIL=1; continue; }
    R_BUNDLE=$(remote_path "$node" "$BUNDLE_DIR") || { FAIL=1; continue; }
    verify_manifest "$node" "$R_BUNDLE" "$R_BUNDLE/MANIFEST.sha256" || FAIL=1
    verify_manifest "$node" "$R_CACHE"  "$R_CACHE/MANIFEST.sha256"  || FAIL=1
    if on_node "$node" "test -s '$R_CACHE/ic/ic_${STAGE_DATE}.nc'"; then
      ok "initial conditions for $STAGE_DATE present"
    else
      err "no staged IC for $STAGE_DATE -- ensemble.sh will try to fetch it from NOAA"
      FAIL=1
    fi
  done
  hdr "Result"
  [[ $FAIL -eq 0 ]] && { c_grn "Offline bundle verified."; exit 0; }
  c_red "Verification FAILED -- re-copy the flagged directories."; exit 1
fi

hdr "Staging offline bundle (IC date: $STAGE_DATE)"
echo "Nodes: ${NODE_ARR[*]}"
echo "This needs internet. Run it at the office, not at the venue."

FAIL=0
for node in "${NODE_ARR[@]}"; do
  hdr "$node"
  DP=$(docker_prefix_for "$node")
  [[ "$DP" == "NEEDS_PASSWORD" ]] && { err "docker not usable -- run scripts/preflight.sh"; FAIL=1; continue; }
  R_CACHE=$(remote_path "$node" "$CACHE_DIR") || { err "path resolve failed on $node"; FAIL=1; continue; }

  if ! on_node "$node" "${DP}docker image inspect '$IMAGE' >/dev/null 2>&1"; then
    err "$IMAGE missing -- run scripts/build.sh then scripts/distribute.sh first"
    FAIL=1; continue
  fi
  # $CACHE_DIR is bind-mounted into a container that runs as ROOT, so after the
  # first fetch everything in it is root-owned on the host and a plain
  # `mkdir`/redirect fails with Permission denied. Hand it back before doing
  # anything else; fall back to creating ic/ inside the container when there is
  # no passwordless sudo, so an unprivileged node still works.
  if on_node "$node" "sudo -n true" 2>/dev/null; then
    on_node "$node" "sudo mkdir -p '$R_CACHE/ic' && sudo chown -R \"\$(id -u):\$(id -g)\" '$R_CACHE'" \
      || warn "could not reclaim ownership of $CACHE_DIR"
  elif ! on_node "$node" "mkdir -p '$R_CACHE/ic' 2>/dev/null"; then
    # No sudo: let the (root) container create it on the shared mount instead.
    on_node "$node" "${DP}docker run --rm -v '$R_CACHE':/root/.cache '$IMAGE' \
        mkdir -p /root/.cache/ic" >/dev/null 2>&1 \
      || { err "cannot create $CACHE_DIR/ic (root-owned, no passwordless sudo)"; FAIL=1; continue; }
    warn "$CACHE_DIR is root-owned and sudo needs a password -- rsync to USB will need sudo too"
  fi

  # --- 1. SFNO -----------------------------------------------------------
  if on_node "$node" "test -s '$R_CACHE/earth2studio/sfno/best_ckpt_mp0.tar'"; then
    ok "SFNO weights already cached"
  else
    echo "  fetching SFNO (~6.9 GB)..."
    if on_node "$node" "${DP}docker run --rm --gpus all --ipc=host \
        -v '$R_CACHE':/root/.cache '$IMAGE' python -c \"
from earth2studio.models.px import SFNO
SFNO.load_model(SFNO.load_default_package())
print('FETCH_OK')\"" | grep -q FETCH_OK; then
      ok "SFNO cached"
    else
      err "SFNO fetch failed"; FAIL=1
    fi
  fi

  # --- 2. CorrDiff -------------------------------------------------------
  # Cache path comes from Package.default_cache("corrdiff_taiwan") in
  # earth2studio 0.18 -> $EARTH2STUDIO_CACHE/corrdiff_taiwan, and
  # EARTH2STUDIO_CACHE defaults to ~/.cache/earth2studio, which is the
  # bind-mounted $CACHE_DIR.
  if on_node "$node" "test -d '$R_CACHE/earth2studio/corrdiff_taiwan' && \
                      test -n \"\$(ls -A '$R_CACHE/earth2studio/corrdiff_taiwan' 2>/dev/null)\""; then
    ok "CorrDiff weights already cached"
  else
    echo "  fetching CorrDiff Taiwan package..."
    if on_node "$node" "${DP}docker run --rm --gpus all --ipc=host \
        -v '$R_CACHE':/root/.cache '$IMAGE' python -c \"
from earth2studio.models.dx import CorrDiffTaiwan
CorrDiffTaiwan.load_model(CorrDiffTaiwan.load_default_package())
print('FETCH_OK')\"" | grep -q FETCH_OK; then
      ok "CorrDiff cached"
    else
      err "CorrDiff fetch failed -- the rainfall panel will be absent at the venue"
      FAIL=1
    fi
  fi

  # --- 3. Initial conditions --------------------------------------------
  # Written into $CACHE_DIR (which travels on the stick), NOT $OUTDIR (which
  # ensemble.sh wipes). ensemble.sh copies it out of here when present and
  # skips the NOAA fetch entirely.
  if on_node "$node" "test -s '$R_CACHE/ic/ic_${STAGE_DATE}.nc'"; then
    ok "initial conditions for $STAGE_DATE already staged"
  else
    echo "  fetching GFS initial conditions for $STAGE_DATE..."
    if on_node "$node" "${DP}docker run --rm --gpus all --ipc=host \
        -v '$R_CACHE':/root/.cache '$IMAGE' python -c \"
import numpy as np
from earth2studio.data import GFS
from earth2studio.models.px import SFNO
m = SFNO.load_model(SFNO.load_default_package())
v = list(m.input_coords()['variable'])
da = GFS()(np.datetime64('${STAGE_DATE}T00'), v)
da.to_netcdf('/root/.cache/ic/ic_${STAGE_DATE}.nc')
print('FETCH_OK', da.shape)\"" | grep -q FETCH_OK; then
      ok "initial conditions staged"
    else
      err "IC fetch failed for $STAGE_DATE (is the GFS archive still serving that date?)"
      FAIL=1
    fi
  fi

  # --- 4. Agent: vLLM image + LLM weights --------------------------------
  # Only on the agent node. The LLM is ~30 GB and lives in ~/.cache/huggingface,
  # NOT in $CACHE_DIR -- a separate directory for the stick.
  if [[ "$WITH_AGENT" -eq 1 ]] && { [[ -z "$AGENT_NODE" ]] || [[ "$node" == "$AGENT_NODE" ]]; }; then
    if on_node "$node" "${DP}docker image inspect '$VLLM_IMAGE' >/dev/null 2>&1"; then
      ok "vLLM image present"
    else
      echo "  pulling $VLLM_IMAGE..."
      on_node "$node" "${DP}docker pull '$VLLM_IMAGE'" >/dev/null 2>&1 \
        && ok "vLLM image pulled" || { err "vLLM pull failed"; FAIL=1; }
    fi

    # HF_TOKEN is not auth-only: the Hub throttles anonymous downloads and says
    # so. Forward it when set; the pull still works without one, just slower.
    HFE=""
    [[ -n "${HF_TOKEN:-}" ]] && HFE="-e HF_TOKEN=$HF_TOKEN"
    # Do NOT set HF_HUB_ENABLE_HF_TRANSFER here: hf_transfer is not installed in
    # the NGC/vLLM image and the flag is a HARD failure when absent.
    echo "  staging $AGENT_MODEL (~30 GB; progress is silent without a TTY --"
    echo "  watch with: ssh $node 'du -sh ~/.cache/huggingface')"
    # --entrypoint python3: the image's ENTRYPOINT is ["vllm","serve"], so a bare
    # command argument is parsed as serve's argv and dies on "unrecognized
    # arguments". It must be python3 -- vllm/vllm-openai ships /usr/bin/python3
    # with NO `python` alias, and the wrong name fails inside runc with
    # "exec: \"python\": executable file not found in $PATH", which reads like a
    # broken image rather than a typo.
    if on_node "$node" "${DP}docker run --rm --entrypoint python3 $HFE \
        -v \"$HF_CACHE\":/root/.cache/huggingface '$VLLM_IMAGE' -c \"
from huggingface_hub import snapshot_download
snapshot_download('$AGENT_MODEL')
print('FETCH_OK')\"" | grep -q FETCH_OK; then
      ok "LLM weights staged"
    else
      err "LLM weight staging failed (set HF_TOKEN if the repo is gated)"
      FAIL=1
    fi
  fi

  # --- 5. Manifests ------------------------------------------------------
  echo "  writing manifests..."
  R_BUNDLE=$(remote_path "$node" "$BUNDLE_DIR") || { err "path resolve failed"; FAIL=1; continue; }
  if manifest_for "$node" "$R_BUNDLE" "$R_BUNDLE/MANIFEST.sha256" "-name '*.tar.zst'" \
     && manifest_for "$node" "$R_CACHE" "$R_CACHE/MANIFEST.sha256" \
          "-name '*.tar' -o -name '*.nc' -o -name '*.mdlus' -o -name '*.pt' -o -name '*.ckpt' -o -name '*.zip'"; then
    ok "manifests written"
  else
    err "manifest write FAILED on $node -- --verify cannot check this node's copy"
    FAIL=1
  fi
done

# ---------------------------------------------------------------------------
# Report. Sizes come from the nodes, not from estimates.
# ---------------------------------------------------------------------------
hdr "What to carry on the USB stick"
REF="${NODE_ARR[0]}"
printf '  %-28s %-10s %s\n' "DIRECTORY" "SIZE" "WHAT"
for spec in \
  "$BUNDLE_DIR|image tarball ($IMAGE)" \
  "$CACHE_DIR|SFNO + CorrDiff weights + IC $STAGE_DATE"; do
  d="${spec%%|*}"; what="${spec#*|}"
  sz=$(on_node "$REF" "du -sh '$d' 2>/dev/null | cut -f1" | tr -d '\r')
  printf '  %-28s %-10s %s\n' "$d" "${sz:-?}" "$what"
done
if [[ "$WITH_AGENT" -eq 1 ]]; then
  AN="${AGENT_NODE:-$REF}"
  sz=$(on_node "$AN" "du -sh \"$HF_CACHE\" 2>/dev/null | cut -f1" | tr -d '\r')
  printf '  %-28s %-10s %s\n' "~/.cache/huggingface" "${sz:-?}" "agent LLM ($AGENT_MODEL), from $AN"
  printf '  %-28s %-10s %s\n' "(vLLM image)" "-" "already loaded on $AN; docker save it if that node is reimaged"
fi

hdr "Next"
cat <<EOF
  Copy from a node to the stick, then verify what landed:

    rsync -a --info=progress2 <node>:$BUNDLE_DIR/ /media/usb/e2dist/
    rsync -a --info=progress2 <node>:$CACHE_DIR/  /media/usb/e2cache/
    ./scripts/stage-offline.sh --verify --date $STAGE_DATE

  At the venue, pin the SAME date -- ensemble.sh defaults to "2 days ago",
  which will be wrong by then and will try to reach NOAA:

    DATE=$STAGE_DATE MEMBERS=6 STEPS=20 ./scripts/ensemble.sh
    DATE=$STAGE_DATE ./scripts/corrdiff.sh
EOF

hdr "Result"
[[ $FAIL -eq 0 ]] && { c_grn "Offline bundle staged."; exit 0; }
c_red "Staging incomplete -- fix the above before you leave the office."; exit 1
