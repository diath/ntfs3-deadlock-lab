#!/bin/bash
# PID 1 of the ntfs3 test VM.  The root fs is the host's / exported read-only
# over virtio-9p; the lab dir is exported read-write at /run/lab.
#
# Kernel cmdline parameters consumed here:
#   lab.test=<path>     test script to run (path inside the guest)
#   lab.tag=<name>      result tag (results go to /run/lab/share/<tag>.*)
#   lab.timeout=<sec>   overall test timeout (default 600)
#   lab.mount=<opts>    ntfs3 mount options (default: none)
#   lab.fs=<type>       filesystem type to mount (default: ntfs3)

export PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
mount -t tmpfs tmpfs /run
mkdir -p /run/lab /run/tmp /run/home /run/mnt /dev/shm
mount -t tmpfs tmpfs /dev/shm
mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000 lab /run/lab
export HOME=/run/home TMPDIR=/run/tmp LANG=C.UTF-8
ln -sf /proc/self/fd /dev/fd

TEST= TAG=run TIMEOUT=600 MOPTS= FSTYPE=ntfs3
for arg in $(</proc/cmdline); do
	case $arg in
	lab.test=*) TEST=${arg#lab.test=} ;;
	lab.tag=*) TAG=${arg#lab.tag=} ;;
	lab.timeout=*) TIMEOUT=${arg#lab.timeout=} ;;
	lab.mount=*) MOPTS=${arg#lab.mount=} ;;
	lab.fs=*) FSTYPE=${arg#lab.fs=} ;;
	esac
done
OUT=/run/lab/share/$TAG
mkdir -p /run/lab/share
: >"$OUT.result"

echo 20 >/proc/sys/kernel/hung_task_timeout_secs
echo -1 >/proc/sys/kernel/hung_task_warnings
echo 1 >/proc/sys/kernel/sysrq
echo 8 >/proc/sys/kernel/printk

finish() {
	echo "RESULT: $*" | tee -a "$OUT.result" >/dev/console
	dmesg >"$OUT.dmesg"
	sync
	echo o >/proc/sysrq-trigger
	while :; do :; done
}

opts=()
[[ -n $MOPTS ]] && opts=(-o "$MOPTS")
if ! mount -t "$FSTYPE" "${opts[@]}" /dev/vda /run/mnt; then
	finish "MOUNT_FAILED"
fi
echo "mounted /dev/vda ($FSTYPE ${MOPTS:-defaults}); running $TEST" >/dev/console

export MNT=/run/mnt
setsid bash -c "cd /run/mnt && exec \"$TEST\"" </dev/null >"$OUT.log" 2>&1 &
pid=$!

start=$SECONDS
while kill -0 "$pid" 2>/dev/null; do
	sleep 2
	if dmesg | grep -q 'blocked for more than'; then
		sleep 3
		echo w >/proc/sysrq-trigger  # stacks of all D-state tasks
		echo d >/proc/sysrq-trigger  # all locks held (lockdep)
		sleep 2
		finish "HUNG after $((SECONDS - start))s"
	fi
	if ((SECONDS - start > TIMEOUT)); then
		kill -TERM -- -"$pid" 2>/dev/null
		sleep 5
		if dmesg | grep -q 'blocked for more than'; then
			echo w >/proc/sysrq-trigger
			echo d >/proc/sysrq-trigger
			finish "HUNG (at timeout)"
		fi
		break
	fi
done
wait "$pid" 2>/dev/null
rc=$?

verdict=PASS
if dmesg | grep -qE 'possible circular locking|possible recursive locking|inconsistent lock state|possible irq lock inversion|lock held when returning'; then
	verdict=LOCKDEP
elif dmesg | grep -qE 'BUG:|WARNING:|Oops|general protection'; then
	verdict=KERNEL_WARNING
fi
if ! timeout 60 umount /run/mnt; then
	echo w >/proc/sysrq-trigger
	verdict="$verdict UMOUNT_HUNG"
fi
finish "$verdict test_rc=$rc elapsed=$((SECONDS - start))s"
