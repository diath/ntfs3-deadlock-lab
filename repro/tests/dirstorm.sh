#!/bin/bash
# Mixed namespace/data storm on a shared tree (lockdep coverage).
exec /run/lab/repro/ntfs3-stress dirstorm "$MNT/storm" -j "${JOBS:-12}" -n "${NAMES:-24}" -t "${SECS:-120}"
