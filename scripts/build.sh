#!/usr/bin/env bash
# Build the Earth-2 image ONCE on the build node, then export it as a
# compressed tarball for offline distribution to the other Sparks.
#
# Why build-once: the image is ~49 GB and pulls the 48 GB NGC base plus
# several git/PyPI sources. At a venue with poor or no internet, only the
# build node ever needs connectivity -- and ideally not even that, if you
# carry the bundle in on a USB stick.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DP=$(docker_prefix_for "$BUILD_NODE")
[[ "$DP" == "NEEDS_PASSWORD" ]] && { err "docker not usable on $BUILD_NODE -- run scripts/preflight.sh"; exit 1; }

TARBALL="$BUNDLE_DIR/$(echo "$IMAGE" | tr ':/' '__').tar.zst"

hdr "Building $IMAGE on $BUILD_NODE"
echo "This takes ~10-15 min cold (48 GB base pull) or ~3 min warm."

on_node "$BUILD_NODE" "mkdir -p '$BUNDLE_DIR'"
# Ship the build context (just the Dockerfile) to the node.
scp -o BatchMode=yes -q "$REPO_ROOT/docker/Dockerfile" "$BUILD_NODE:$BUNDLE_DIR/Dockerfile" || {
  err "failed to copy Dockerfile"; exit 1; }

if ! on_node "$BUILD_NODE" "cd '$BUNDLE_DIR' && ${DP}docker build \
      --build-arg BASE_IMAGE='$BASE_IMAGE' \
      --build-arg E2S_VERSION='$E2S_VERSION' \
      --build-arg MAKANI_REF='$MAKANI_REF' \
      --build-arg TH_REF='$TH_REF' \
      -f Dockerfile -t '$IMAGE' ."; then
  err "docker build failed on $BUILD_NODE"; exit 1
fi
ok "image built"

hdr "Exporting bundle"
echo "Note: layers are already-compressed wheels, so zstd only saves ~2%."
echo "Measured on GB10: 48.8 GB image -> 14.1 GB tarball in ~3 min."
on_node "$BUILD_NODE" "${DP}docker save '$IMAGE' | zstd -3 -T0 -o '$TARBALL'" || {
  err "docker save failed"; exit 1; }

size=$(on_node "$BUILD_NODE" "du -h '$TARBALL' | cut -f1")
ok "bundle: $TARBALL ($size)"
echo
echo "Next:  scripts/distribute.sh    # copy + load onto the remaining nodes"
