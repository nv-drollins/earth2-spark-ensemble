#!/usr/bin/env bash
# Copy the image bundle from the build node to every other node and load it.
# Idempotent: skips any node that already has the image.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

TARNAME="$(echo "$IMAGE" | tr ':/' '__').tar.zst"
DP_BUILD=$(docker_prefix_for "$BUILD_NODE")

# Each node resolves its own $HOME -- see common.sh remote_path().
R_BUNDLE_BUILD=$(remote_path "$BUILD_NODE" "$BUNDLE_DIR") || exit 1
TARBALL="$R_BUNDLE_BUILD/$TARNAME"

on_node "$BUILD_NODE" "test -f '$TARBALL'" || { err "bundle missing on $BUILD_NODE: $TARBALL -- run scripts/build.sh"; exit 1; }

for node in "${NODE_ARR[@]}"; do
  hdr "$node"
  DP=$(docker_prefix_for "$node")
  [[ "$DP" == "NEEDS_PASSWORD" ]] && { err "docker not usable -- run scripts/preflight.sh"; continue; }

  R_BUNDLE=$(remote_path "$node" "$BUNDLE_DIR") || { err "path resolve failed"; continue; }
  NODE_TARBALL="$R_BUNDLE/$TARNAME"
  if on_node "$node" "${DP}docker image inspect '$IMAGE' >/dev/null 2>&1"; then
    ok "already has $IMAGE -- skipping"; continue
  fi

  if [[ "$node" == "$BUILD_NODE" ]]; then
    warn "build node lacks its own image; loading from local tarball"
  else
    echo "  copying bundle (~14 GB over LAN)..."
    on_node "$node" "mkdir -p '$R_BUNDLE'"
    # Stream build-node -> here -> target. Avoids requiring node-to-node SSH
    # keys, which are often absent on a fresh cluster.
    if ! ssh -o BatchMode=yes "$BUILD_NODE" "cat '$TARBALL'" | \
         ssh -o BatchMode=yes "$node" "cat > '$NODE_TARBALL'"; then
      err "copy failed"; continue
    fi
    ok "copied"
  fi

  echo "  loading image (~2-3 min)..."
  if on_node "$node" "zstd -dc '$NODE_TARBALL' | ${DP}docker load"; then
    ok "loaded $IMAGE"
  else
    err "docker load failed"
  fi
done

hdr "Done"
echo "Next:  scripts/fetch-models.sh   # pre-stage SFNO weights (needs internet ONCE)"
