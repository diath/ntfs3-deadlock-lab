#!/bin/bash
# D1 via ftruncate-grow (setattr path)
exec /run/lab/repro/ntfs3-stress resident "$MNT/d1" -p 4 -g t -t 120
