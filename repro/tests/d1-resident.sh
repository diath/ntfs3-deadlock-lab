#!/bin/bash
# D1: resident->nonresident conversion racing an uncached reader.
exec /run/lab/repro/ntfs3-stress resident "$MNT/d1" -p "${PAIRS:-4}" -t "${SECS:-120}"
