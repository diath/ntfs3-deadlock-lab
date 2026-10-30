#!/bin/bash
# D7: write into the holes of files that ntfs-3g left sparse (image from
# repro/mkimg-sparse.sh; run with -i img/sparse-ntfs3g.img).  Stock ntfs3
# over-counts the sparse total_size, then rejects the record (mi_enum_attr),
# marks the inode bad and the volume dirty.
#
#   pwrite     rewrite the whole file with new data via pwrite()
#   mmapwrite  the same through a shared writable mapping
#   onehole    pwrite() 4 KiB into the first hole, which starts a frame
#   midhole    pwrite() 4 KiB into the second hole, in the middle of a
#              16-cluster frame: stock ntfs3 reallocates the whole frame and
#              zeroes the 14 clusters of data around the hole
#   control    untouched
#
# Then drop the caches and read everything back.  Exit 1 on any error,
# rejected record or data mismatch.
cd "$MNT" || exit 2
python3 -I - <<'PY'
import mmap, os, sys
size = os.path.getsize("control")
new = os.urandom(size)
want = {"control": open("control", "rb").read()}
want["onehole"] = bytearray(want["control"])
want["onehole"][1 << 20:(1 << 20) + 4096] = new[:4096]
MID = (4 << 20) + 4096
want["midhole"] = bytearray(want["control"])
want["midhole"][MID:MID + 4096] = new[:4096]
rc = 0
def step(name, fn):
    global rc
    try:
        fn()
        print(f"{name}: written")
    except OSError as e:
        print(f"{name}: write FAILED: {e}")
        rc = 1
def do_pwrite():
    fd = os.open("pwrite", os.O_RDWR)
    try: os.pwrite(fd, new, 0)
    finally: os.close(fd)
def do_mmap():
    with open("mmapwrite", "r+b") as f:
        m = mmap.mmap(f.fileno(), 0)
        m[:] = new
        m.flush()
        m.close()
def do_onehole():
    fd = os.open("onehole", os.O_RDWR)
    try: os.pwrite(fd, new[:4096], 1 << 20)
    finally: os.close(fd)
def do_midhole():
    fd = os.open("midhole", os.O_RDWR)
    try: os.pwrite(fd, new[:4096], MID)
    finally: os.close(fd)
want["pwrite"] = want["mmapwrite"] = new
step("pwrite", do_pwrite)
step("mmapwrite", do_mmap)
step("onehole", do_onehole)
step("midhole", do_midhole)
os.sync()
open("/proc/sys/vm/drop_caches", "w").write("3\n")
for name in ("pwrite", "mmapwrite", "onehole", "midhole", "control"):
    try:
        st = os.stat(name)
        got = open(name, "rb").read()
        ok = got == bytes(want[name])
        print(f"{name}: size={st.st_size} blocks={st.st_blocks} {'data ok' if ok else 'DATA MISMATCH'}")
        rc |= not ok
    except OSError as e:
        print(f"{name}: read back FAILED: {e}")
        rc = 1
sys.exit(rc)
PY
rc=$?
if dmesg | grep -E 'ntfs3.*(mi_enum_attr|attr_set_size|dirty)'; then
	rc=1
fi
exit $rc
