#!/bin/bash
# D1 writeback side (mmap-dirtied resident file + fdatasync + grow), with data check
exec /run/lab/repro/ntfs3-stress resmmap "$MNT/d1m" -p 4 -t 120
