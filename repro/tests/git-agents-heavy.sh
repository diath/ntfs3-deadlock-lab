#!/bin/bash
# Heavier run: 16 agents, 6 watchers, ~8 min; run it with a small VM (-m 1024)
# so real reclaim evicts inodes/page cache (files go cold, fs_reclaim paths run).
AGENTS=16 WATCHERS=6 DUR=480 DROP=0 exec /run/lab/repro/tests/git-agents-common.sh
