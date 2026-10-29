#!/bin/bash
# dirstorm without mmap (op 14), so the readdir/mmap_lock lockdep splat (D2)
# does not switch lockdep off before it can find anything else.
exec /run/lab/repro/ntfs3-stress dirstorm "$MNT/storm" -j 12 -n 24 -t 150 -x 14
