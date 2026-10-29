#!/bin/bash
# Configure a minimal KVM-guest kernel with ntfs3 + lockdep/hung-task debugging.
# usage: [DRIVER=ntfs3|ntfs] kconfig-debug.sh <kernel-src> <build-dir>
set -e
SRC=$1; OUT=$2
make -C "$SRC" O="$OUT" defconfig kvm_guest.config >/dev/null
C="$SRC/scripts/config --file $OUT/.config"
# filesystem under test (ntfs3 and ntfs cannot both be built in);
# DRIVER=ntfs builds the fs/ntfs driver instead of ntfs3
if [[ ${DRIVER:-ntfs3} == ntfs ]]; then
	$C -d NTFS3_FS -e NTFS_FS -e NTFS_FS_POSIX_ACL -d NTFS_DEBUG
else
	$C -e NTFS3_FS -e NTFS3_LZX_XPRESS -e NTFS3_FS_POSIX_ACL -d NTFS3_64BIT_CLUSTER
	$C -d NTFS_FS
fi
# host rootfs over 9p (virtme-style), block devices
$C -e NET_9P -e NET_9P_VIRTIO -e 9P_FS -e 9P_FS_POSIX_ACL -e VIRTIO_BLK -e VIRTIO_PCI -e DEVTMPFS -e DEVTMPFS_MOUNT
$C -e TMPFS -e TMPFS_POSIX_ACL -e FUSE_FS -e BLK_DEV_LOOP -e OVERLAY_FS
# debugging
$C -e DEBUG_KERNEL -e LOCKDEP -e PROVE_LOCKING -e DEBUG_LOCK_ALLOC -e DEBUG_MUTEXES -e DEBUG_RWSEMS -e DEBUG_SPINLOCK
$C -e DEBUG_ATOMIC_SLEEP -e LOCK_STAT
$C -e DETECT_HUNG_TASK --set-val DEFAULT_HUNG_TASK_TIMEOUT 20 --set-val BOOTPARAM_HUNG_TASK_PANIC 0
$C -e SOFTLOCKUP_DETECTOR -e WQ_WATCHDOG -e MAGIC_SYSRQ -e DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT -d DEBUG_INFO_BTF
$C -e KALLSYMS -e KALLSYMS_ALL -e FRAME_POINTER -e STACKTRACE -e PRINTK_TIME
$C --set-val LOCKDEP_BITS 17 --set-val LOCKDEP_CHAINS_BITS 18 --set-val LOCKDEP_STACK_TRACE_BITS 20
$C -d MODULES -d DRM -d SOUND -d USB_SUPPORT -d WIRELESS -d WLAN -d HID
make -C "$SRC" O="$OUT" olddefconfig >/dev/null
