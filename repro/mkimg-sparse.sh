#!/bin/bash
# Build an NTFS image whose files were written by ntfs-3g with holes, the way
# ntfs-3g leaves linker output (cargo target/ .so files): sparse $DATA with
# compression unit 4.  Used by repro/tests/sparse-rewrite.sh (D7).
#
# usage: sudo repro/mkimg-sparse.sh [image]   (default <lab>/img/sparse-ntfs3g.img)
set -euo pipefail
LAB=$(cd "$(dirname "$0")/.." && pwd)
IMG=${1:-$LAB/img/sparse-ntfs3g.img}
((EUID == 0)) || { echo "run as root (sudo), it mounts the image with ntfs-3g" >&2; exit 2; }
command -v ntfs-3g >/dev/null || { echo "ntfs-3g is not installed" >&2; exit 2; }

MNT=$(mktemp -d) SRC=$(mktemp)
trap 'umount "$MNT" 2>/dev/null || true; rmdir "$MNT"; rm -f "$SRC"' EXIT

# 9324792 bytes of random data with four all-zero, cluster-aligned gaps.
python3 -I - "$SRC" <<'PY'
import os, sys
size = 9324792
b = bytearray(os.urandom(size))
for off, ln in ((1 << 20, 16384), ((4 << 20) + 4096, 8192), (9199616, 32768), (9248768, 20480)):
    b[off:off + ln] = bytes(ln)
open(sys.argv[1], "wb").write(b)
PY

mkdir -p "$(dirname "$IMG")"
rm -f "$IMG"
truncate -s 256M "$IMG"
mkntfs -F -Q -L sparse "$IMG" >/dev/null 2>&1
ntfs-3g "$IMG" "$MNT"
for f in pwrite mmapwrite onehole midhole control; do
	cp --sparse=always "$SRC" "$MNT/$f"
done
umount "$MNT"
[[ -n ${SUDO_UID:-} ]] && chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$IMG"
echo "$IMG"
