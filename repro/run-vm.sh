#!/bin/bash
# Boot the test kernel in QEMU/KVM against a fresh copy of the NTFS image and
# run one test script inside it.
#
# usage: run-vm.sh [-k bzImage] [-c cpus] [-m mem] [-t timeout] [-o mountopts]
#                  [-f fstype] [-i image] <tag> <test-script>
#
# The test script path must be inside $LAB (it is accessed as /run/lab/...
# in the guest).  Results:
#   $LAB/share/<tag>.console   serial console (hung task + sysrq-w/d dumps)
#   $LAB/share/<tag>.result    verdict line(s)
#   $LAB/share/<tag>.log       test stdout/stderr
#   $LAB/share/<tag>.dmesg     final dmesg
set -euo pipefail
LAB=$(cd "$(dirname "$0")/.." && pwd)
KERNEL=$LAB/build-debug/arch/x86/boot/bzImage
CPUS=4 MEM=4096 TIMEOUT=600 MOPTS= FSTYPE=ntfs3 IMAGE=$LAB/img/ntfs-pristine.img
while getopts k:c:m:t:o:f:i: opt; do
	case $opt in
	k) KERNEL=$OPTARG ;; c) CPUS=$OPTARG ;; m) MEM=$OPTARG ;;
	t) TIMEOUT=$OPTARG ;; o) MOPTS=$OPTARG ;; f) FSTYPE=$OPTARG ;;
	i) IMAGE=$OPTARG ;; *) exit 2 ;;
	esac
done
shift $((OPTIND - 1))
TAG=$1 TEST=$(realpath "$2")
[[ $TEST == "$LAB"/* ]] || { echo "test must live under $LAB" >&2; exit 2; }
GUEST_TEST=/run/lab/${TEST#"$LAB"/}

mkdir -p "$LAB/share" "$LAB/img/run"
DISK=$LAB/img/run/$TAG.img
cp --sparse=always "$IMAGE" "$DISK"
rm -f "$LAB/share/$TAG".{console,result,log,dmesg}

# Host-side backstop: guest init powers off on its own, this only catches a
# guest that wedged so hard its watchdog loop could not run.
timeout --foreground $((TIMEOUT + 240)) \
qemu-system-x86_64 \
	-enable-kvm -cpu host -smp "$CPUS" -m "$MEM" \
	-kernel "$KERNEL" \
	-append "rootfstype=9p root=/dev/root rootflags=trans=virtio,version=9p2000.L,cache=loose,msize=512000 ro console=ttyS0 nokaslr panic=-1 init=$LAB/repro/guest-init.sh lab.test=$GUEST_TEST lab.tag=$TAG lab.timeout=$TIMEOUT lab.fs=$FSTYPE ${MOPTS:+lab.mount=$MOPTS}" \
	-fsdev local,id=root,path=/,security_model=none,readonly=on,multidevs=remap \
	-device virtio-9p-pci,fsdev=root,mount_tag=/dev/root \
	-fsdev local,id=lab,path="$LAB",security_model=none,multidevs=remap \
	-device virtio-9p-pci,fsdev=lab,mount_tag=lab \
	-drive file="$DISK",if=virtio,format=raw,cache=unsafe \
	-display none -monitor none -serial file:"$LAB/share/$TAG.console" \
	-no-reboot || true
# The image copy is only needed while the VM runs; set KEEP_IMAGE=1 to keep
# it (e.g. to inspect the volume with ntfsfix/ntfsinfo afterwards).
[[ ${KEEP_IMAGE:-0} == 1 ]] || rm -f "$DISK"

cat "$LAB/share/$TAG.result" 2>/dev/null || echo "RESULT: NO_RESULT (guest wedged or failed to boot)"
grep -E 'blocked for more than|possible (circular|recursive) locking|BUG:|WARNING:' "$LAB/share/$TAG.console" | sort | uniq -c | head -20 || true
