#!/bin/bash
# Run the ntfs3 reproducer matrix against one kernel and print a summary.
#
# usage: run-matrix.sh [-f fstype] [-j parallel] [-m quick|full] <bzImage> <prefix>
#
#   -f ntfs3|ntfs   driver to mount the test image with (default ntfs3)
#   -j N            VMs to run at once, 4 vCPUs each (default 3)
#   -m quick        D1..D5 reproducers only (default)
#   -m full         also dirstorm and the git agents workloads
#
# Each test's artifacts land in $LAB/share/<prefix>-<test>.{console,log,result}.
set -uo pipefail
LAB=$(cd "$(dirname "$0")/.." && pwd)
FS=ntfs3 PAR=3 MODE=quick
while getopts f:j:m: opt; do
	case $opt in
	f) FS=$OPTARG ;; j) PAR=$OPTARG ;; m) MODE=$OPTARG ;; *) exit 2 ;;
	esac
done
shift $((OPTIND - 1))
KERNEL=$(realpath "$1") PREFIX=$2

# test-script:timeout   (what it reproduces)
TESTS=(
	d1-resident:150    # D1 read side: append crosses resident limit vs cold reader
	d1-resident-t:150  # D1 via ftruncate grow; also D4 (EIO + iomap WARN)
	d1-resident-f:150  # D1 via fallocate; also writeback E_NTFS_NONRESIDENT WARN
	d1-resmmap:150     # D1 writeback side; D3 mmap data loss; D5 bad inode
)
if [[ $MODE == full ]]; then
	TESTS+=(
		dirstorm:150         # D2 lockdep splat (readdir faults under ni_lock)
		git-agents-pressure:220
		git-agents-heavy:560 # 16 agents, 8 min; slow
	)
fi

run_one() {
	local t=${1%%:*} to=${1##*:} opts=()
	[[ $t == git-agents-heavy ]] && opts=(-c 8 -m 1024)
	"$LAB/repro/run-vm.sh" -k "$KERNEL" -f "$FS" -t "$to" "${opts[@]}" \
		"$PREFIX-$t" "$LAB/repro/tests/$t.sh" >"$LAB/share/$PREFIX-$t.runner" 2>&1
}

running=0
for t in "${TESTS[@]}"; do
	run_one "$t" &
	if ((++running >= PAR)); then
		wait -n
		running=$((running - 1))
	fi
done
wait

printf '\n%-22s %-34s %s\n' TEST VERDICT NOTES
for t in "${TESTS[@]}"; do
	t=${t%%:*}
	b=$LAB/share/$PREFIX-$t
	v=$(sed -n 's/^RESULT: //p' "$b.result" 2>/dev/null | head -1)
	notes=$(
		c=$(grep -c 'blocked for more than' "$b.console" 2>/dev/null)
		((c)) && printf 'hung-task x%s; ' "$c"
		grep -q 'possible circular locking' "$b.console" 2>/dev/null && printf 'lockdep circular; '
		grep -oE 'WARNING: [^ ]+' "$b.console" 2>/dev/null | sort -u | tr '\n' ' '
		m=$(grep -c 'DATA MISMATCH\|inside i_size' "$b.log" 2>/dev/null)
		((m)) && printf 'data errors x%s; ' "$m"
		grep -oE '^[a-z]+: (Input/output error|Invalid argument)' "$b.log" 2>/dev/null | sort -u | tr '\n' ' '
		grep -q 'mi_enum_attr' "$b.console" 2>/dev/null && printf 'inode marked bad; '
	)
	printf '%-22s %-34s %s\n' "$t" "${v:-NO RESULT}" "$notes"
done
