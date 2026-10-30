# ntfs3 deadlock lab

Reproducers, a QEMU/KVM test harness and fixes for the ntfs3 hangs seen
when many agents / git worktrees work on the same tree on an NTFS volume.
Tested on Linux 7.3 (mainline, 2026-10-18) and 7.2.11 (the Arch kernel this
was investigated on).

## Layout

```
repro/
  ntfs3-stress.c        the reproducer (build: gcc -O2 -pthread -o ntfs3-stress ntfs3-stress.c)
  tests/*.sh            test scripts run inside the VM ($MNT = mounted test volume)
  run-vm.sh             boot one kernel in QEMU, run one test, collect console/dmesg/verdict
  run-matrix.sh         run every test against one kernel and print a summary table
  live-test.sh          run the reproducers on the running kernel (loop image, root)
  guest-init.sh         PID 1 in the VM: mounts, runs the test, detects hung tasks,
                        dumps sysrq-w (blocked stacks) + sysrq-d (held locks)
  kconfig-debug.sh      kernel config: KVM guest + ntfs3 (or DRIVER=ntfs) + lockdep,
                        hung-task detector (20 s), 9p root
  mkimg-sparse.sh       image with ntfs-3g-written sparse files for tests/sparse-rewrite.sh (D7)
patches/7.3/            first 6-patch series against v7.3 (git am / patch -p1)
patches/7.2.11/         the same fixes as one patch against v7.2.11
outgoing/v1/            the series for upstream, against ntfs3 master (ee1cb3443cff):
                        D1, D3, D4, D6, D5, D7 + cover letter; see "Upstream" below
outgoing/*.eml          other mails to send (Tested-by for a pending fix)
outgoing/b4-cover-template.txt  b4 cover template (b4.prep-cover-template), no extra signature
module-7.2.11/          patched fs/ntfs3 for 7.2.11, buildable as an out-of-tree module
                        (first series: D1-D6, not D7)
tools/
  mftcheck.py           read-only: replay ntfs3's mi_enum_attr() checks on MFT records
                        (<dev> <rec>... or <dev> --scan), print the $Volume dirty flag
  ntfs3g-leftovers.py   find and convert what ntfs-3g leaves behind (Interix symlinks,
                        sparse files): see "Moving a volume from ntfs-3g"
results/                consoles, logs and summaries of the runs quoted below

Created by the quick start (not in git):
src/                    kernel sources        build-<version>/   kernel build trees
kernels/                test bzImages         img/               NTFS test volume
share/                  run output
```

The VM uses the host's `/` read-only over virtio-9p (so git, bash, python
come from the host) and a fresh copy of an `mkntfs` image as `/dev/vda`.
Nothing touches real disks; a deadlock only wedges the VM.

## Quick start

Requirements: qemu-system-x86_64 with KVM access (`/dev/kvm`), gcc, make,
flex, bison, bc, libelf, pahole, mkntfs (ntfs-3g), curl.  Each kernel takes
about 5 GB in `src/` + `build-*/` and ~10 minutes on 16 cores.

Build a stock and a patched 7.2.11 test kernel, then run every reproducer
against both:

```sh
cd ntfs3-deadlock-lab
V=7.2.11                  # or 7.3 (uses the patch series in patches/7.3/)

# 1. kernel source, checked against kernel.org's signed checksum list
mkdir -p src kernels
curl -fL --output-dir src -O https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-$V.tar.xz
curl -fL --output-dir src -O https://cdn.kernel.org/pub/linux/kernel/v7.x/sha256sums.asc
(cd src && grep " linux-$V.tar.xz\$" sha256sums.asc | sha256sum -c -)
tar -xf src/linux-$V.tar.xz -C src

# 2. stock kernel: KVM guest + ntfs3 + lockdep + 20 s hung-task detector
repro/kconfig-debug.sh $PWD/src/linux-$V $PWD/build-$V
make -C src/linux-$V O=$PWD/build-$V -j$(nproc) bzImage
cp build-$V/arch/x86/boot/bzImage kernels/bzImage-$V-ntfs3-debug

# 3. patched kernel: apply the fixes to the same tree and rebuild
for p in patches/$V/*.patch; do patch -d src/linux-$V -p1 < "$p"; done
make -C src/linux-$V O=$PWD/build-$V -j$(nproc) bzImage
cp build-$V/arch/x86/boot/bzImage kernels/bzImage-$V-ntfs3-patched-debug

# 4. test volume and reproducer binary
mkdir -p img && truncate -s 4G img/ntfs-pristine.img
mkntfs -F -Q -L ntfs3test img/ntfs-pristine.img
gcc -O2 -pthread -o repro/ntfs3-stress repro/ntfs3-stress.c

# 5. run (about 5 minutes each; -m full adds dirstorm + git agents, ~20 min)
repro/run-matrix.sh kernels/bzImage-$V-ntfs3-debug stock
repro/run-matrix.sh kernels/bzImage-$V-ntfs3-patched-debug patched
```

Expect the stock kernel to report `HUNG` for `d1-resident`, `d1-resident-f`
and `d1-resmmap` and `KERNEL_WARNING` for `d1-resident-t`, and the patched
one to pass all four (see Results below).  Step 3 relies on `patch` giving
the touched files new mtimes so `make` rebuilds them; if you copy patched
files in instead, `touch` them, or the "patched" kernel is the stock one.

Single tests and variants:

```sh
repro/run-vm.sh -k kernels/bzImage-$V-ntfs3-debug -t 150 mytag repro/tests/d1-resident.sh
repro/run-vm.sh -k ... -o delalloc ...    # pass ntfs3 mount options

# the other in-kernel driver (fs/ntfs, "mount -t ntfs") for comparison
DRIVER=ntfs repro/kconfig-debug.sh $PWD/src/linux-$V $PWD/build-ntfs
make -C src/linux-$V O=$PWD/build-ntfs -j$(nproc) bzImage
repro/run-matrix.sh -f ntfs build-ntfs/arch/x86/boot/bzImage fsntfs
```

Results: `share/<tag>.{console,log,result,dmesg}`; the console has the
hung-task reports plus sysrq-w (blocked task stacks) and sysrq-d (held
locks) dumps.

| test | what it does | reproduces |
|---|---|---|
| `d1-resident` | 4 writer/reader pairs: writer creates a file and appends 64-byte chunks to 4 KiB; reader does `fadvise(DONTNEED)` + `pread` | D1 (read side) |
| `d1-resident-t` | same, growing with `ftruncate` | D1, D4 |
| `d1-resident-f` | same, growing with `fallocate` | D1, D6 |
| `d1-resmmap` | write 300 B, overwrite via shared mmap, append 2000 B, fsync, verify; another thread `fdatasync`s in a loop | D1 (writeback side), D3, D5 |
| `dirstorm` | 12 threads, random create/unlink/rename/link/symlink/mkdir/rmdir/readdir/chmod/xattr/truncate/append/mmap/fallocate/fsync on 4 shared dirs | D2 (lockdep) |
| `git-agents-*` | 8-16 "agents", each with its own worktree of one repo: edit/append/rewrite files, add, commit, status, reflog, diff, remove+re-add worktree; 3-6 grep/find watchers | realistic load |
| `bigdir` | `ls -f` a 3000-entry directory 20x with concurrent `stat` | linux-next readdir double unlock |

## Findings

All of these are in **7.2.11 and 7.3** (same code), and D1, D3, D4, D5 are
still in linux-next (next-20261029).

### D1 - deadlock: folio 0 vs ni_lock/run_lock when a small file grows (the hang)

NTFS keeps small files (up to ~700 bytes with a 1 KiB MFT record) inside the
MFT record ("resident").  When one grows past that, `attr_make_nonresident()`
moves the data out into clusters, copying it into page-cache folio 0 - and
locks that folio **while holding `ni_lock` and `run_lock`**:

```
writer (append / ftruncate / fallocate)        reader (cold page cache)
  ntfs_file_write_iter   [i_rwsem]               filemap_read_folio   [folio 0 LOCKED]
   ntfs_set_size         [ni_lock, run_lock W]    iomap_read_folio
    attr_set_size_ex                               ntfs_iomap_begin
     attr_make_nonresident                          attr_data_get_block
      __filemap_get_folio(0, FGP_LOCK)  <-wait->     down_read(run_lock) / ni_lock
```

The writeback side is the same shape: `ntfs_writepages()` holds folio 0 and
takes `ni_lock` for resident files (flusher kworker, `fsync`, `sync`).
Lockdep does not track folio locks, so it never sees this; the hung-task
detector does:

```
task:ntfs3-stress state:D   __filemap_get_folio_mpol <- attr_make_nonresident <- attr_set_size_ex <- ntfs_set_size <- ntfs_file_write_iter
task:ntfs3-stress state:D   down_read <- attr_data_get_block <- ntfs_iomap_begin <- iomap_read_folio <- ntfs_read_folio <- filemap_read_folio
task:kworker/u16:3 state:D  __folio_lock <- writeback_iter <- ntfs_writepages <- wb_workfn
task:sync state:D           ...
```

Once two tasks are stuck, the writer still holds `i_rwsem` + `ni_lock` of the
file: renames/unlinks in that directory, `sync`, and the bdi flusher (so all
dirty data on that volume) block behind it, and it spreads from there - the
"whole system freezes" effect.  Triggers in agent/worktree workloads: any
small file being appended to or extended (git reflogs `.git/logs/*`, notes,
logs, `ftruncate` up) while something else (IDE/file watcher, `git status`,
grep, another agent) reads it with a cold page cache, or while writeback of
an mmap-dirtied small file runs.  Reproduces in < 1 minute, every run.

Fix (patch 1): lock folio 0 **before** `ni_lock` in every path that can
convert (`ntfs_set_size`, fallocate, insert-range) and pass it down - the order
ext4 uses for inline data.

### D2 - readdir holds the directory's ni_lock across copy_to_user (lockdep)

`ntfs_readdir()` keeps `ni_lock` of the directory over the whole walk,
including `dir_emit()` -> `copy_to_user()`, which can page-fault; lockdep:
`mapping.invalidate_lock --> &mm->mmap_lock --> vm_lock` via `filldir64 <-
ntfs_readdir` and `attr_data_get_block <- ntfs_read_folio`.  While the
fault waits, every lookup in that directory waits too (`ntfs_lookup` takes
`ni_lock_dir`), so it turns a stuck file into a stuck directory.  Seen once in
the dirstorm runs (timing dependent).

Fix (patch 5): collect entries under the lock, emit after dropping it.
linux-next has its own attempt at this which **double-unlocks `ni_lock`**
whenever the user buffer fills (any large directory) - lockdep:
`WARNING: bad unlock balance detected! ... release lock (&ni->ni_lock) at
ntfs_readdir` (results/consoles/bigdir-next.console).  On a non-debug kernel
that can release a mutex another task holds.  Worth reporting upstream.

### D3 - data loss: mmap writes to a small file are dropped when it grows

The conversion overwrites an uptodate (mmap-dirty) folio 0 with the stale
resident copy: write 300x'A', overwrite via mmap with 'B', append 2000x'C' ->
the file reads back 'A'x300 + 'C'x2000.  383 of 384 iterations on stock 7.3
(484/487 on 7.2.11) before D1 hung the run.
Fix: patch 3.

### D4 - spurious EIO + kernel WARNING when a file is extended with ftruncate

`ntfs_setattr()` publishes the new `i_size` before growing the resident
attribute; a concurrent read gets `WARNING: fs/iomap/buffered-io.c:431 at
iomap_read_inline_data` and `-EIO`.  Within 2 seconds.  Fix: patch 4.

### D5 - fsync can mark a healthy file bad (and the volume dirty)

`ni_write_parents()` (fsync) walks the MFT record without `ni_lock`; if another
thread rearranges it at that moment, it follows garbage
(`MFT: r=0, expect seq=0 instead of 1!`) or `mi_enum_attr` decides the record
is corrupt, marks the inode bad and the volume dirty (Windows will want
chkdsk), and the file returns `EINVAL` until evicted.  Was hidden behind D1 on
stock kernels.  Fix: patch 6.

### D6 - writeback drops data when it races with a conversion

`ntfs_writepages()` decides "resident" once, then a conversion slips in:
`attr_data_write_resident()` returns the positive internal code 556, which
trips `WARNING: lib/errseq.c:75` and `WARNING: mm/page-writeback.c` and the
already-cleaned folio is never written.  linux-next maps it to `-EIO` (no
WARN, data still dropped).  Fix (patch 2): redirty and write via iomap.

### D7 - data loss: filling a hole in an ntfs-3g sparse file zeroes its neighbours

ntfs-3g makes a file sparse whenever a write leaves a gap, which is what
linkers do, so cargo/CMake output written under ntfs-3g is sparse with
compression unit 4 (16-cluster frames), with holes of any length at any
offset.  ntfs3 assumes a frame is either fully allocated or fully sparse:
`attr_data_get_block_locked()` fills a hole by allocating the whole frame
around it and maps the new, zeroed clusters over the ones the frame already
has.  Writing 4 KiB into a 2-cluster hole in the middle of a frame:

- 14 clusters of existing data read back as zeros (silent data loss);
- the old clusters stay marked in use, referenced by nothing (chkdsk finds them);
- `total_size` grows by 16 clusters; once it passes `alloc_size`,
  `mi_enum_attr()` rejects the record, the inode goes bad (`stat`/`open`
  return `EINVAL`) and the volume is marked dirty, so the next rw mount is
  refused until chkdsk / `ntfsfix -d`.

As old as the driver (5.15 rounded the length up to a frame instead of
aligning the start, same effect).  Same on stock 7.2.11, 7.3 and ntfs3
master, with or without `prealloc`; the first series did not fix it.
Files that ntfs3 or ntfs.sys create keep frames whole, so only files left
over from ntfs-3g are exposed.  Fix (patch 6 in `outgoing/v1`): allocate only
the hole.  Repro: `sudo repro/mkimg-sparse.sh`, then
`repro/run-vm.sh -k <bzImage> -i img/sparse-ntfs3g.img d7 repro/tests/sparse-rewrite.sh`.

Also when moving from ntfs-3g: ntfs-3g writes symlinks in the Interix format
(a small file starting with `IntxLNK\1`).  ntfs3 does not understand those
and shows them as regular files, so `node_modules/.bin/*` fails with "Exec
format error" and symlinked files read as garbage.  `tools/ntfs3g-leftovers.py`
converts both kinds of leftovers; see "Moving a volume from ntfs-3g".

## Results

`run-matrix.sh -m full`, 4 vCPU VMs (git-agents-heavy: 8 vCPU, 1 GiB),
lockdep + 20 s hung-task detector.  Full output in `results/`.

| test | 7.2.11 stock | 7.2.11 patched | 7.3 stock | 7.3 patched |
|---|---|---|---|---|
| d1-resident (append) | **HUNG 46 s** | pass 120 s | **HUNG 45 s** | pass 120 s |
| d1-resident-t (ftruncate) | **EIO + WARN 2 s** | pass | **EIO + WARN 2 s** | pass |
| d1-resident-f (fallocate) | **HUNG 45 s** + WARNs | pass | **HUNG 45 s** | pass |
| d1-resmmap | **HUNG 45 s**, 484/487 files corrupt | pass, 0/176509 corrupt | **HUNG 46 s**, 383/384 corrupt | pass, 0/58036 corrupt |
| dirstorm (7M ops) | - | - | pass (lockdep splat in 1 of 2 runs) | pass x3, no lockdep |
| git-agents, 8 agents + pressure | - | - | pass | pass |
| git-agents, 16 agents, 8 min | - | - | pass (20k commits) | pass |

The git workloads alone did not hang in these runs: D1 needs the
cold-read/grow coincidence, which the targeted reproducer forces and a real
desktop with many agents hits eventually.  If your freezes have another
cause, these tests did not find it; capture `echo w > /proc/sysrq-trigger`
output (or the hung-task reports in `journalctl -k`) next time it happens,
the stacks will say which.

fs/ntfs (the other in-kernel driver, `mount -t ntfs`): no hangs, no lockdep
reports, but it lost appended data in 12 of ~99k `d1-resmmap` iterations and
does not support plain `fallocate`.  See `results/7.3-fsntfs-driver.summary`.

ntfs-3g (FUSE, what this system uses today), via `live-test.sh` in a 7.2.11
VM: no hangs, but the same `d1-resmmap` check lost the appended bytes (read
back as zeros) in 6 of 76008 iterations - the same symptom as fs/ntfs.  Not
investigated further (ntfs-3g or the FUSE layer).  Only patched ntfs3 had
zero bad iterations on this test.

### ntfs3 master (7.4 queue, ee1cb3443cff) on 7.3

| test | ntfs3 master | + outgoing/v1 + readdir fix |
|---|---|---|
| d1-resident (append) | **HUNG 46 s** | pass, 491k files |
| d1-resident-t (ftruncate) | **HUNG 46 s**, EIO + WARN | pass, 589k files |
| d1-resident-f (fallocate) | **HUNG 46 s** | pass, 714k files |
| d1-resmmap | **HUNG 45 s**, 10 corrupt | pass, 192k files |
| dirstorm | pass | pass, 5.1M ops |
| bigdir | **bad unlock balance** | pass |
| sparse-rewrite (D7) | record rejected, 14 clusters zeroed | pass |
| git-agents, 8 agents + pressure | - | pass, 4486 commits |
| git-agents, 16 agents, 8 min | - | pass, 30815 commits |

"readdir fix" is Christian Aurich Zanettini Martins' pending
"fs/ntfs3: fix double ni_unlock() in ntfs_readdir()" v2
(<20261029052102.1585462-1-christian.aurichzm@gmail.com>); master's readdir
rework (7a5aa6c45072) already fixes D2 but unlocks twice without it.  6.18.59
(LTS) hangs on d1-resident and d1-resmmap after 45 s, like 7.x.

## Upstream

Checked against the ntfs3 list archive (lore.kernel.org/ntfs3) and the
maintainer tree on 2026-10-29: D2 is fixed in ntfs3_for_7.4 (plus the pending
double-unlock fix above), D6 is only turned into -EIO there (2727ac2ba87a),
and D1, D3, D4, D5 and D7 had not been reported.  `outgoing/v1` is the
series for ntfs3 master; each patch has a verified Fixes: tag, Cc: stable and
Assisted-by, builds with W=1 on its own, and passes checkpatch --strict
(apart from "unknown commit id" in a tree without history).  It has no
Signed-off-by: the submitter adds it (`git commit --amend -s`) after reviewing
every patch, as Documentation/process/coding-assistants.rst requires.

## Testing on your live system (Arch, 7.2.x)

Run the reproducers on a throwaway image, never on a real NTFS partition:
on stock ntfs3 they deadlock the running kernel (the stuck tasks cannot be
killed, the volume cannot be unmounted until reboot) and several of the bugs
corrupt data.  `repro/live-test.sh` mounts a fresh copy of
`/var/tmp/ntfs3-live-test.img` (created on first use, 4 GiB sparse) per test,
runs the four reproducers for 60 s each, detects a hang itself (no progress
for 30 s with threads in D state), dumps the blocked-task stacks
(`sysrq-w`) into the results and stops.  Results go to
`share/live-<driver>-<time>/`.

```sh
gcc -O2 -pthread -o repro/ntfs3-stress repro/ntfs3-stress.c   # once
```

**Phase 1 - baseline on ntfs-3g (what fstab uses now).**  No reboot needed.

```sh
sudo repro/live-test.sh ntfs-3g
```

Expected (VM run): `resident` and `resident-t` pass, `resident-f` N/A
(ntfs-3g has no plain fallocate), `resmmap` may report a few corrupt files
(6 of 76008 in the VM - see Results).

**Phase 2 - stock ntfs3.**  No reboot needed first: nothing on this system
loads ntfs3 yet, and the test does not touch the ntfs-3g mounts.

```sh
sudo repro/live-test.sh ntfs3          # prints "patched ...: no"
```

Expected: `resident-t` fails with `Input/output error` and a
`WARNING: fs/iomap/buffered-io.c` (this sets the kernel's W taint flag), then
`resident` reports `HUNG` within about a minute and the script stops.  The
rest of the desktop keeps working, but do not run a plain `sync` (it can
block on the stuck volume).  Reboot:

```sh
sync -f /home; sync -f /       # flush the real filesystems only
systemctl reboot               # if it hangs: sudo sh -c 'echo b > /proc/sysrq-trigger'
```

**Phase 3 - patched ntfs3, after that reboot.**  Build and install the module
before anything loads ntfs3 (again, nothing does at boot with the current
fstab):

```sh
uname -r                              # module-7.2.11 is for 7.2.11-arch1-1, see below
cd module-7.2.11                      # = fs/ntfs3 of 7.2.11 + patches/7.2.11
make -C /lib/modules/$(uname -r)/build M=$PWD modules
sudo install -Dm644 ntfs3.ko /lib/modules/$(uname -r)/updates/ntfs3.ko
sudo depmod -a                        # updates/ takes priority over the stock module
modinfo -n ntfs3                      # -> .../updates/ntfs3.ko
cd .. && sudo repro/live-test.sh ntfs3          # prints "patched ...: yes"
sudo repro/live-test.sh -t 600 ntfs3            # optional: 10 min per test
```

Expected: all four pass.  The module is unsigned; this kernel does not
enforce signatures (no lockdown, `MODULE_SIG_FORCE` off), it only adds the E
taint flag.  If `live-test.sh` warns that the loaded module is not the
installed one, ntfs3 was loaded before the install: reboot and rerun.

Undo: `sudo rm /lib/modules/$(uname -r)/updates/ntfs3.ko && sudo depmod -a`.

**Other kernel versions.**  `module-7.2.11` is 7.2.11's `fs/ntfs3` plus the
fixes.  For another 7.2.y, take that version's `fs/ntfs3` from its source
tarball and apply `patches/7.2.11/ntfs3-fixes-7.2.11.patch` (it applies to
7.2.13 with 1-line offsets), then build as above.  An installed module only
covers the kernel it was built for: after a `linux` upgrade the stock ntfs3
is back.  Rebuild after every kernel update (or package it with DKMS), or
hold `linux` and `linux-headers` with `IgnorePkg` while you evaluate.

**Moving a volume from ntfs-3g.**  Two kinds of ntfs-3g leftovers need
converting once a volume is mounted with ntfs3: Interix symlinks (shown as
regular files) and sparse files with 16-cluster frames (D7, if the module
lacks patch 6).  Stop whatever writes to the volume, then:

```sh
sudo tools/ntfs3g-leftovers.py scan /dev/disk/by-uuid/<uuid> > ~/leftovers.tsv   # read-only
tools/ntfs3g-leftovers.py fix /mnt/X ~/leftovers.tsv            # dry run: what would change
tools/ntfs3g-leftovers.py fix /mnt/X ~/leftovers.tsv --apply    # as the owner of the files
```

Symlinks become NTFS reparse-point symlinks (ntfs3, ntfs-3g and Windows read
them); sparse files are copied to a normal file and renamed over the original.
`--exclude <path>` skips a subtree (large, mostly empty disk images cost their
full size), files with several hard links are skipped, and every change goes to
`leftovers.tsv.log`.  Afterwards `sudo tools/mftcheck.py <dev> --scan` should
report `rejected: 0`; then, with the volume unmounted, `ntfsfix -d <dev>`
clears a dirty flag left by earlier errors (plain `ntfsfix` would set it again).

The module in `/lib/modules/<version>/updates` only covers that kernel version:
a kernel update brings back the stock driver.  Hold the kernel
(`IgnorePkg = linux` in `/etc/pacman.conf`) until the module is rebuilt for it.

**Moving a real partition over** (only after phase 3 passes, with backups):
one volume at a time, e.g. `/mnt/Dev`, changing only the type in fstab -
ntfs3 understands the same `uid`, `gid`, `umask`, `windows_names` options:

```
UUID=06124A7C124A70AB  /mnt/Dev  ntfs3  rw,noatime,uid=1000,gid=1000,umask=022,windows_names,nofail,X-fstrim.notrim  0 0
```

Keep the old ntfs-3g line commented next to it.  Like ntfs-3g, ntfs3 will not
mount a volume read-write that Windows left hibernated (Fast Startup).
These patches are tested in VMs only.
