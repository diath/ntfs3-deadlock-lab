#!/bin/bash
# D1 via fallocate (attr_force_nonresident path)
exec /run/lab/repro/ntfs3-stress resident "$MNT/d1" -p 4 -g f -t 120
