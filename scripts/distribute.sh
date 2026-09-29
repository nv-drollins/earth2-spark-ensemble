#!/usr/bin/env bash
# Copy the image bundle from the build node to every other node and load it.
# Idempotent: skips any node that already has the image.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

TARBALL="$BUNDLE_DIR/$(echo "$IMAGE" | tr ':/' '__').tar.zst"
DP_BUILD=$(docker_prefix_for "$BUILD_NODE")

on_node "$BUILD_NODE" "test -f '$TARBALL'" || { err "bundle missing on $BUILD_NODE: $TARBALL -- run scripts/build.sh"; exit 1; }

for node in "${NODE_ARR[@]}"; do
  hdr "$node"
  DP=$(docker_prefix_for "$node")
  [[ "$DP" == "NEEDS_PASSWORD" ]] && { err "docker not usable -- run scripts/preflight.sh"; continue; }

  if on_node "$node" "${DP}docker image inspect '$IMAGE' >/dev/null 2>&1"; then
    ok "already has $IMAGE -- skipping"; continue
  fi

  if [[ "$node" == "$BUILD_NODE" ]]; then
    warn "build node lacks its own image; loading from local tarball"
  else
    echo "  copying bundle (~14 GB over LAN)..."
    on_node "$node" "mkdir -p '$BUNDLE_DIR'"
    # Stream build-node -> here -> target. Avoids requiring node-to-node SSH
    # keys, which are often absent on a fresh cluster.
    if ! ssh -o BatchMode=yes "$BUILD_NODE" "cat '$TARBALL'" | \
         ssh -o BatchMode=yes "$node" "cat > '$TARBALL'"; then
      err "copy failed"; continue
    fi
    ok "copied"
  fi

  echo "  loading image (~2-3 min)..."
  if on_node "$node" "zstd -dc '$TARBALL' | ${DP}docker load"; then
    ok "loaded $IMAGE"
  else
    err "docker load failed"
  fi
done

hdr "Done"
echo "Next:  scripts/fetch-models.sh   # pre-stage SFNO weights (needs internet ONCE)"
