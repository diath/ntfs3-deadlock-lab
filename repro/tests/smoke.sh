#!/bin/bash
set -x
uname -r
grep /run/mnt /proc/mounts
nproc; free -m
cd "$MNT"
mkdir d && echo hello > d/f && cat d/f && ls -la d
git --version && git init -q repo && cd repo && echo x > a && git add a && git -c user.name=t -c user.email=t@t commit -qm init && git log --oneline
