#!/bin/bash
# readdir of a directory larger than one getdents buffer (the dir_context
# fills, so ntfs_read_hdr() returns +1 mid-walk), with concurrent lookups.
D=$MNT/big
mkdir -p "$D"
for i in $(seq 3000); do : >"$D/file-with-a-longish-name-$i"; done
for r in $(seq 20); do
	ls -f "$D" | wc -l
	stat "$D/file-with-a-longish-name-$((RANDOM % 3000 + 1))" >/dev/null &
done
wait
echo "done, no hang"
