#!/bin/bash
# Run the D1..D6 reproducers on the RUNNING kernel against a throwaway NTFS
# image (never a real partition), one fresh copy of the image per test.
#
# usage: sudo repro/live-test.sh [-i image] [-t secs] [-s stall] [-o dir] ntfs-3g|ntfs3|ntfs [test...]
#
#   ntfs-3g | ntfs3 | ntfs   driver to mount the image with (ntfs = fs/ntfs)
#   -i image   pristine image, created with mkntfs if missing
#              (default /var/tmp/ntfs3-live-test.img, 4 GiB sparse)
#   -t secs    run time per test (default 60)
#   -s secs    no progress for this long while threads are in D state = hung
#              (default 30)
#   -o dir     results directory (default <lab>/share/live-<driver>-<time>)
#   test...    any of: resident resident-t resident-f resmmap (default: all)
#
# On a hang it dumps blocked-task stacks (sysrq-w) to the kernel log, saves
# them, and stops: the stuck tasks cannot be killed and the image cannot be
# unmounted until reboot.  Exit status: 0 all passed, 1 failures, 3 hung.
set -uo pipefail
LAB=$(cd "$(dirname "$0")/.." && pwd)
STRESS=$LAB/repro/ntfs3-stress
IMG=/var/tmp/ntfs3-live-test.img SECS=60 STALL=30 OUT=
MNT=/run/ntfs3-live-test

while getopts i:t:s:o: opt; do
	case $opt in
	i) IMG=$OPTARG ;; t) SECS=$OPTARG ;; s) STALL=$OPTARG ;; o) OUT=$OPTARG ;;
	*) exit 2 ;;
	esac
done
shift $((OPTIND - 1))
DRIVER=${1:-}
shift || true
TESTS=("$@")
((${#TESTS[@]})) || TESTS=(resident resident-t resident-f resmmap)

die() { echo "live-test: $*" >&2; exit 2; }
[[ $DRIVER == ntfs-3g || $DRIVER == ntfs3 || $DRIVER == ntfs ]] ||
	die "first argument must be ntfs-3g, ntfs3 or ntfs"
((EUID == 0)) || die "run as root (sudo), it mounts a loop image"
[[ -x $STRESS ]] || die "build $STRESS first: gcc -O2 -pthread -o $STRESS $STRESS.c"
findmnt -rn "$MNT" >/dev/null && die "$MNT is still mounted - a previous run hung? reboot first"
case $(findmnt -n -o FSTYPE -T "$(dirname "$IMG")") in
fuseblk | ntfs3 | ntfs) die "put the image on a non-NTFS filesystem, not $(dirname "$IMG")" ;;
esac

if [[ ! -f $IMG ]]; then
	echo "creating $IMG"
	truncate -s 4G "$IMG" && mkntfs -F -Q -L ntfs3live "$IMG" >/dev/null 2>&1 ||
		die "mkntfs failed"
fi

OUT=${OUT:-$LAB/share/live-$DRIVER-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT" "$MNT"
SUMMARY=$OUT/summary.txt
log() { echo "$*" | tee -a "$SUMMARY"; }

# Which module will actually run the test?
log "kernel: $(uname -r)   driver: $DRIVER   $(date -Is)"
if [[ $DRIVER != ntfs-3g ]] && ! modinfo -n "$DRIVER" >/dev/null 2>&1 &&
	grep -qw "$DRIVER" /proc/filesystems; then
	log "module: $DRIVER is built into this kernel"
elif [[ $DRIVER != ntfs-3g ]]; then
	modprobe "$DRIVER" || die "modprobe $DRIVER failed"
	file=$(modinfo -n "$DRIVER" 2>/dev/null)
	want=$(modinfo -F srcversion "$DRIVER" 2>/dev/null)
	have=$(cat "/sys/module/$DRIVER/srcversion" 2>/dev/null)
	if [[ $file == *.zst ]]; then
		patched=$(zstd -dcq "$file" | grep -ac 'folio 0 locked under ni_lock')
	else
		patched=$(grep -ac 'folio 0 locked under ni_lock' "$file")
	fi
	log "module: $file (srcversion $have)"
	[[ $DRIVER == ntfs3 ]] && log "patched (lab fixes present): $([[ $patched -gt 0 ]] && echo yes || echo no)"
	[[ -n $want && $want != "$have" ]] &&
		log "WARNING: the loaded $DRIVER is not the file above (installed after it was loaded?) - reboot first"
fi
log ""

stress_args() {
	case $1 in
	resident) echo "resident $MNT/t -p 4" ;;
	resident-t) echo "resident $MNT/t -p 4 -g t" ;;
	resident-f) echo "resident $MNT/t -p 4 -g f" ;;
	resmmap) echo "resmmap $MNT/t -p 4" ;;
	*) die "unknown test $1" ;;
	esac
}

mount_img() {
	cp --sparse=always "$IMG" "$IMG.run" || return 1
	case $DRIVER in
	ntfs-3g) ntfs-3g "$IMG.run" "$MNT" ;;
	*) mount -t "$DRIVER" -o loop "$IMG.run" "$MNT" ;;
	esac
}

d_threads() { grep -ls '^State:[[:space:]]*D' /proc/"$1"/task/*/status 2>/dev/null | wc -l; }

rc_all=0
for t in "${TESTS[@]}"; do
	args=$(stress_args "$t")
	mount_img || die "could not mount a copy of $IMG"
	kmsg0=$(dmesg | wc -l)
	# shellcheck disable=SC2086
	"$STRESS" $args -t "$SECS" >"$OUT/$t.log" 2>&1 &
	pid=$!
	last= since=$SECONDS verdict=
	while kill -0 "$pid" 2>/dev/null; do
		sleep 2
		cur=$(grep -ao 'files=[0-9]*' "$OUT/$t.log" | tail -1)
		if [[ $cur != "$last" ]]; then
			last=$cur since=$SECONDS
		elif ((SECONDS - since >= STALL)) && (($(d_threads "$pid") > 0)); then
			verdict="HUNG ($(d_threads "$pid") threads in D state, no progress for ${STALL}s)"
			break
		fi
	done
	if [[ -n $verdict ]]; then
		echo w >/proc/sysrq-trigger
		sleep 2
		dmesg | tail -n +"$((kmsg0 + 1))" >"$OUT/$t.dmesg"
		log "$(printf '%-12s %s' "$t" "$verdict")"
		log ""
		log "Blocked-task stacks: $OUT/$t.dmesg"
		log "The image stays mounted at $MNT; the stuck tasks cannot be killed."
		log "Avoid a plain 'sync' (it can block on this volume too).  To reboot:"
		log "  sync -f /home; sync -f /     # flush the real filesystems only"
		log "  systemctl reboot             # if that hangs: echo b > /proc/sysrq-trigger"
		rc_all=3
		break
	fi
	wait "$pid"
	rc=$?
	dmesg | tail -n +"$((kmsg0 + 1))" >"$OUT/$t.dmesg"
	notes=$(
		grep -ao 'DATA MISMATCH' "$OUT/$t.log" | wc -l | awk '$1 {printf "%s corrupt files; ", $1}'
		grep -aoE '(Input/output error|Invalid argument|Operation not supported)' "$OUT/$t.log" | sort -u | tr '\n' ';'
		grep -oE 'WARNING: [^ ]+' "$OUT/$t.dmesg" | sort -u | tr '\n' ' '
		grep -oE 'ntfs3?\([^)]*\): .*' "$OUT/$t.dmesg" | sort -u | head -3 | tr '\n' ';'
	)
	case $rc in
	0) v=PASS ;;
	*) v="FAIL rc=$rc"; rc_all=1 ;;
	esac
	grep -q 'Operation not supported' "$OUT/$t.log" && v="N/A (not supported by $DRIVER)"
	[[ $v == PASS && -n $notes ]] && v="PASS with kernel messages" && rc_all=1
	log "$(printf '%-12s %-30s %s' "$t" "$v" "$notes")"
	if ! timeout 60 umount "$MNT"; then
		log "umount of $MNT failed or hung - reboot before the next run"
		rc_all=3
		break
	fi
	rm -f "$IMG.run"
done

[[ -n ${SUDO_UID:-} ]] && chown -R "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$OUT"
echo "results: $OUT"
exit $rc_all
