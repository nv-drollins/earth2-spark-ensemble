#!/usr/bin/env bash
# Copy the image bundle from the build node to every other node and load it.
# Idempotent: skips any node that already has the image, so it is also a safe
# no-op verification pass after loading every node from USB.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
FAIL=0

TARNAME="$(echo "$IMAGE" | tr ':/' '__').tar.zst"
DP_BUILD=$(docker_prefix_for "$BUILD_NODE")

# Each node resolves its own $HOME -- see common.sh remote_path().
R_BUNDLE_BUILD=$(remote_path "$BUILD_NODE" "$BUNDLE_DIR") || exit 1
TARBALL="$R_BUNDLE_BUILD/$TARNAME"

# Do NOT demand the tarball up front. After the USB path (INSTALL.md 3.0) the
# image is loaded on every node and no tarball exists anywhere -- this script
# then has nothing to do, and exiting here meant a complete, correct install
# reported "bundle missing ... run scripts/build.sh". Decide per node instead,
# and only complain if a node that actually NEEDS the tarball cannot get it.
HAVE_TARBALL=0
on_node "$BUILD_NODE" "test -f '$TARBALL'" && HAVE_TARBALL=1

for node in "${NODE_ARR[@]}"; do
  hdr "$node"
  DP=$(docker_prefix_for "$node")
  [[ "$DP" == "NEEDS_PASSWORD" ]] && { err "docker not usable -- run scripts/preflight.sh"; continue; }

  R_BUNDLE=$(remote_path "$node" "$BUNDLE_DIR") || { err "path resolve failed"; continue; }
  NODE_TARBALL="$R_BUNDLE/$TARNAME"
  if on_node "$node" "${DP}docker image inspect '$IMAGE' >/dev/null 2>&1"; then
    ok "already has $IMAGE -- skipping"; continue
  fi

  # This node needs the image and does not have it, so now the tarball matters.
  if [[ $HAVE_TARBALL -eq 0 ]]; then
    err "$node lacks $IMAGE and no tarball exists on $BUILD_NODE:"
    echo "       $TARBALL"
    echo "       Either load it on this node from USB (INSTALL.md 3.0):"
    echo "         zstd -dc <usb>/e2bundle/e2dist/$TARNAME | docker load"
    echo "       or copy the tarball to $BUILD_NODE and re-run (INSTALL.md 3.1)."
    FAIL=1; continue
  fi

  if [[ "$node" == "$BUILD_NODE" ]]; then
    # NORMAL on a from-USB install: the tarball was copied here rather than
    # built here, so the image is not loaded yet. (After scripts/build.sh the
    # image IS already present and this node is skipped above.) Not a warning
    # -- say what is happening so an operator following INSTALL.md does not
    # read it as a fault.
    echo "  first node: loading from the tarball already on this node"
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

hdr "Result"
if [[ $FAIL -eq 0 ]]; then
  c_grn "All nodes have $IMAGE."
  echo "Next:  scripts/stage-offline.sh --verify   then   scripts/verify.sh"
else
  c_red "One or more nodes do NOT have $IMAGE -- see above."
  exit 1
fi
