#!/usr/bin/env bash
# Copy the Earth-2 bundle from this workstation onto a USB drive.
#
# Run this ON THE WORKSTATION (spark-1589). It writes to the USB drive you
# name, then verifies what landed.
#
#   ./copy-bundle-to-usb.sh /media/nvidia/BOOTME_DATA
#
# WHY A TARBALL FOR THE LLM:
#   The HuggingFace cache is built from SYMLINKS (snapshots/*.json point at
#   ../../blobs/<sha>). Neither FAT32 nor NTFS can store a Unix symlink, so a
#   plain copy fails with "symlink ... Operation not permitted" and silently
#   leaves the model unusable. Packing it into a .tar preserves the links
#   exactly; it is unpacked on the Spark, which is Linux and handles them.
#
# WHY NOT FAT32 AT ALL:
#   FAT32 caps a single file at 4 GB. The image tarball is 15 GB, so it CANNOT
#   be written to a FAT32 stick by any means. Use NTFS or exFAT.
set -uo pipefail

SRC="${BUNDLE_SRC:-$HOME/e2bundle}"
DEST="${1:-}"

c_red(){ printf '\033[31m%s\033[0m\n' "$*"; }
c_grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
ok(){ c_grn "  OK   $*"; }
err(){ c_red "  FAIL $*"; }
hdr(){ printf '\n=== %s ===\n' "$*"; }

[[ -z "$DEST" ]] && {
  echo "usage: $0 /path/to/usb"; echo
  echo "Mounted removable drives:"
  df -hT /media/*/* 2>/dev/null | awk 'NR>1{printf "  %-30s %-8s avail=%s\n",$7,$2,$5}'
  exit 1; }

[[ -d "$SRC" ]]  || { err "source bundle not found: $SRC"; exit 1; }
[[ -d "$DEST" ]] || { err "destination not mounted: $DEST"; exit 1; }

# --- refuse FAT32 outright: the 15 GB tarball cannot be written there -------
FSTYPE=$(df -T "$DEST" | awk 'NR==2{print $2}')
hdr "Destination"
echo "  path:       $DEST"
echo "  filesystem: $FSTYPE"
case "$FSTYPE" in
  vfat|msdos)
    err "FAT32 cannot hold a file larger than 4 GB."
    echo "       The image tarball is ~15 GB, so this drive CANNOT work."
    echo "       Use an NTFS or exFAT drive. To reformat a spare stick:"
    echo "         sudo mkfs.exfat -n E2BUNDLE /dev/sdX1"
    exit 1 ;;
  ntfs|ntfs3|exfat|fuseblk)
    ok "$FSTYPE handles large files (symlinks are packed into a tar below)" ;;
  ext4|xfs|btrfs)
    ok "$FSTYPE is a Linux filesystem -- symlinks could be copied directly, but"
    echo "       this script still tars the LLM cache so the stick stays portable" ;;
  *) echo "  NOTE: unrecognised filesystem '$FSTYPE' -- continuing" ;;
esac

AVAIL_K=$(df -k "$DEST" | awk 'NR==2{print $4}')
NEED_K=$(du -sk "$SRC" | cut -f1)
echo "  need ~$((NEED_K/1024/1024)) GB, available $((AVAIL_K/1024/1024)) GB"
(( AVAIL_K < NEED_K )) && { err "not enough free space"; exit 1; }

mkdir -p "$DEST/e2bundle" || { err "cannot write to $DEST"; exit 1; }

# --- 1 & 2: plain dirs, no symlinks, copy directly -------------------------
for d in e2dist e2cache; do
  hdr "$d"
  echo "  copying $(du -sh "$SRC/$d" | cut -f1)..."
  if rsync -rt --no-links --info=progress2 "$SRC/$d/" "$DEST/e2bundle/$d/"; then
    ok "$d copied"
  else
    err "$d copy FAILED (rc=$?) -- do not trust this drive"; exit 1
  fi
done

# --- 3: the LLM cache, as a tar to survive a non-Unix filesystem -----------
hdr "hf-cache (packed as tar -- symlinks cannot live on $FSTYPE)"
if [[ -d "$SRC/hf-cache" ]]; then
  echo "  packing ~21 GB, this is the slow part..."
  if tar -cf "$DEST/e2bundle/hf-cache.tar" -C "$SRC" hf-cache; then
    ok "hf-cache.tar written ($(du -h "$DEST/e2bundle/hf-cache.tar" | cut -f1))"
  else
    err "tar FAILED -- the agent LLM will not be available"; exit 1
  fi
else
  err "no hf-cache in $SRC (forecast-only bundle)"
fi

sync

# --- verify ---------------------------------------------------------------
hdr "Verify what actually landed"
FAIL=0
for d in e2dist e2cache; do
  sn=$(find "$SRC/$d" -type f | wc -l);        dn=$(find "$DEST/e2bundle/$d" -type f | wc -l)
  sb=$(du -sb "$SRC/$d" | cut -f1);            db=$(du -sb "$DEST/e2bundle/$d" | cut -f1)
  if [[ "$sn" == "$dn" && "$sb" == "$db" ]]; then ok "$d: $dn files, $db bytes -- exact"
  else err "$d: src[$sn files/$sb B] dst[$dn files/$db B] MISMATCH"; FAIL=1; fi
done
if [[ -f "$DEST/e2bundle/hf-cache.tar" ]]; then
  tn=$(tar -tf "$DEST/e2bundle/hf-cache.tar" | wc -l)
  sn=$(find "$SRC/hf-cache" | wc -l)
  [[ "$tn" -ge $((sn - 1)) ]] && ok "hf-cache.tar: $tn entries -- readable and complete" \
    || { err "hf-cache.tar: $tn entries vs $sn on disk"; FAIL=1; }
fi

TARBALL=$(ls "$DEST/e2bundle/e2dist/"*.tar.zst 2>/dev/null | head -1)
if [[ -n "$TARBALL" ]]; then
  echo
  echo "  checksumming the 15 GB image tarball (~2 min, worth it)..."
  s=$(sha256sum "$SRC/e2dist/$(basename "$TARBALL")" | cut -d' ' -f1)
  d=$(sha256sum "$TARBALL" | cut -d' ' -f1)
  [[ "$s" == "$d" ]] && ok "image tarball sha256 matches" \
                     || { err "image tarball CORRUPT on the USB drive"; FAIL=1; }
fi

hdr "Result"
if [[ $FAIL -eq 0 ]]; then
  c_grn "Bundle is on $DEST/e2bundle and verified."
  cat <<EOF

  At the venue, unpack the LLM cache ON THE SPARK (Linux restores the
  symlinks; do NOT unpack it on the USB drive):

    ssh e2-spark-3 'mkdir -p ~/.cache'
    tar -xf $DEST/e2bundle/hf-cache.tar -C /tmp && \\
      rsync -a /tmp/hf-cache/ e2-spark-3:~/.cache/huggingface/

  or, straight from the stick on a machine that has it plugged in:

    tar -xf /path/to/hf-cache.tar -C ~/.cache && mv ~/.cache/hf-cache ~/.cache/huggingface

  e2dist and e2cache copy normally -- see INSTALL.md stage 3.
EOF
else
  c_red "Copy INCOMPLETE -- fix the above before relying on this drive."
  exit 1
fi
