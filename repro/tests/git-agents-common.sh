#!/bin/bash
# "Many agents + worktrees on one repo" workload on ntfs3.
# Each agent owns a worktree and loops: append lines to small files, rewrite
# files editor-style (write tmp + rename), git add/commit/status, read the
# reflog, occasionally remove + re-add its worktree.  Watchers re-read the
# whole tree like an IDE / file indexer.  If DROP=1, page cache is dropped
# periodically (memory pressure: small files go cold).
set -u
AGENTS=${AGENTS:-8} WATCHERS=${WATCHERS:-3} DUR=${DUR:-150} DROP=${DROP:-0}
R=$MNT/proj
export GIT_AUTHOR_NAME=a GIT_AUTHOR_EMAIL=a@a GIT_COMMITTER_NAME=a GIT_COMMITTER_EMAIL=a@a
export GIT_CONFIG_GLOBAL=/run/tmp/gitconfig
git config --global safe.directory '*'
git config --global gc.auto 0
git init -q "$R" && cd "$R" || exit 1
for d in src lib docs; do
	mkdir -p $d
	for i in $(seq 100); do printf 'line %d\n' "$i" >"$d/f$i.txt"; done
done
git add -A && git commit -qm seed
echo "seeded repo"

end=$((SECONDS + DUR))
agent() {
	local n=$1 wt=$MNT/wt$1 it=0
	git -C "$R" worktree add -q -b "br$n" "$wt" || return
	while ((SECONDS < end)); do
		local f=$wt/src/f$((RANDOM % 100 + 1)).txt
		local g=$wt/lib/f$((RANDOM % 100 + 1)).txt
		for k in 1 2 3; do echo "agent $n edit $RANDOM $RANDOM $RANDOM" >>"$f"; done
		{ cat "$g"; echo "agent $n rewrite $RANDOM"; } >"$g.tmp" && mv -f "$g.tmp" "$g"
		echo "note $n $it $RANDOM" >>"$wt/docs/notes-$n.md"
		git -C "$wt" add -A
		git -C "$wt" commit -qm "agent $n step $it" >/dev/null 2>&1
		git -C "$wt" status --porcelain >/dev/null
		((RANDOM % 4 == 0)) && git -C "$wt" log -g --oneline -3 >/dev/null 2>&1
		((RANDOM % 6 == 0)) && git -C "$wt" diff HEAD~1 --stat >/dev/null 2>&1
		if ((RANDOM % 25 == 0)); then
			git -C "$R" worktree remove --force "$wt" &&
				git -C "$R" worktree add -q "$wt" "br$n" 2>/dev/null
		fi
		it=$((it + 1))
	done
	echo "agent $n done after $it iterations"
}
watcher() {
	while ((SECONDS < end)); do
		grep -rq --include='*.txt' --include='*.md' zzzz "$MNT" 2>/dev/null
		find "$MNT" -newer "$R/.git/HEAD" -type f >/dev/null 2>&1
	done
}
for n in $(seq "$AGENTS"); do agent "$n" & done
for n in $(seq "$WATCHERS"); do watcher & done
if ((DROP)); then
	while ((SECONDS < end)); do echo 1 >/proc/sys/vm/drop_caches; sleep 0.5; done &
fi
while ((SECONDS < end)); do
	sleep 10
	echo "t=$SECONDS commits=$(git -C "$R" rev-list --all --count 2>/dev/null)"
done
wait
echo "done, no hang"
