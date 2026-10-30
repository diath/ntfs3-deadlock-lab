#!/usr/bin/env python3
"""Find and convert what ntfs-3g leaves on a volume that ntfs3 handles badly.

  symlinks  ntfs-3g writes symlinks as Interix files: a small regular file
            holding "IntxLNK\\1" and the UTF-16 target.  ntfs3 shows them
            as regular files, so "node_modules/.bin/x" fails with "Exec
            format error" and a symlinked CLAUDE.md reads as garbage.
            fix: replace each with a real symlink (an NTFS reparse point,
            which ntfs3, ntfs-3g and Windows all read).
  sparse    ntfs-3g makes a file sparse with compression unit 4 whenever a
            write leaves a gap.  Writing into such a hole with a stock
            ntfs3 zeroes the data next to it and can get the file rejected
            (D7 in the README).  fix: rewrite it as a normal file (a copy
            that ntfs3 creates, renamed over the original).

usage:
  sudo tools/ntfs3g-leftovers.py scan /dev/disk/by-uuid/<uuid> > leftovers.tsv
  tools/ntfs3g-leftovers.py fix <mountpoint> leftovers.tsv [--apply]
                            [--only symlinks|sparse] [--exclude <path>]...

scan reads the raw device read-only (it may be mounted).  fix runs as the
user that owns the files, on the mounted volume; without --apply it only
prints what it would do.  Every change is appended to <tsv>.log.
"""
import importlib.util
import os
import shutil
import sys

sys.dont_write_bytecode = True  # run with sudo: keep root-owned caches out of tools/

spec = importlib.util.spec_from_file_location(
    "mftcheck", os.path.join(os.path.dirname(os.path.abspath(__file__)), "mftcheck.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

ROOT = 5  # MFT record of the root directory
F_SPARSE, F_COMPRESSED = 0x8000, 0x0001


def scan(dev):
    vol = m.Vol(dev)
    dirs, names, links, sparse = {}, {}, {}, {}
    chunk = 1024 * vol.rec_size
    for start, length, lcn in vol.mft_runs:
        base_rec = start * vol.cluster // vol.rec_size
        nbytes = length * vol.cluster
        for pos in range(0, nbytes, chunk):
            buf = os.pread(vol.fd, min(chunk, nbytes - pos), lcn * vol.cluster + pos)
            for i in range(0, len(buf), vol.rec_size):
                raw = buf[i:i + vol.rec_size]
                if raw[:4] != b"FILE" or not m.u16(raw, 22) & 1:
                    continue
                num = base_rec + (pos + i) // vol.rec_size
                try:
                    rec = vol.fixup(raw)
                except ValueError:
                    continue
                base = m.u64(rec, 32) & 0xFFFFFFFFFFFF or num
                isdir = bool(m.u16(rec, 22) & 2)
                for a in vol.attrs(rec):
                    t, o = a["type"], a["off"]
                    if t == 0x30 and not a["nonres"]:
                        vo = o + m.u16(rec, o + 20)
                        if rec[vo + 65] == 2:  # DOS 8.3 alias of another name
                            continue
                        name = rec[vo + 66:vo + 66 + 2 * rec[vo + 64]].decode("utf-16-le", "replace")
                        parent = m.u64(rec, vo) & 0xFFFFFFFFFFFF
                        if isdir:
                            dirs[base] = (name, parent)
                        else:
                            names.setdefault(base, []).append((name, parent))
                    elif t == 0x80 and not a["name_len"] and not isdir:
                        if not a["nonres"]:
                            vo = o + m.u16(rec, o + 20)
                            val = rec[vo:vo + m.u32(rec, o + 16)]
                            if val[:8] == b"IntxLNK\x01":
                                links[base] = val[8:].decode("utf-16-le", "replace")
                        elif m.u64(rec, o + 16) == 0 and a["flags"] & F_SPARSE \
                                and not a["flags"] & F_COMPRESSED and rec[o + 34]:
                            sparse[base] = (m.u64(rec, o + 48), m.u64(rec, o + 64))

    def path(name, parent):
        parts = [name]
        for _ in range(256):
            if parent == ROOT:
                return "/".join(reversed(parts))
            if parent not in dirs:
                return None
            name, parent = dirs[parent]
            parts.append(name)
        return None

    out, lost = [], 0
    for kind, recs in (("symlink", links), ("sparse", sparse)):
        for num, info in recs.items():
            paths = [p for p in (path(n, par) for n, par in names.get(num, [])) if p]
            if not paths:
                lost += 1
                continue
            if kind == "symlink" and not info.isprintable():
                print(f"scan: not listed, target {info!r} has control characters: "
                      f"{', '.join(paths)}", file=sys.stderr)
                continue
            for p in paths:
                if kind == "symlink":
                    out.append(f"symlink\t{p}\t{len(paths)}\t{info}")
                else:
                    out.append(f"sparse\t{p}\t{len(paths)}\t{info[0]}\t{info[1]}")
    out.sort()
    print("\n".join(out))
    nl = sum(1 for line in out if line.startswith("symlink"))
    ns = len(out) - nl
    print(f"scan: {nl} Interix symlinks, {ns} ntfs-3g sparse files"
          f"{f', {lost} without a resolvable path' if lost else ''}", file=sys.stderr)


def fix(mnt, tsv, apply, only, excludes):
    log = open(tsv + ".log", "a") if apply else None
    done = skipped = 0
    need = 0
    for line in open(tsv):
        f = line.rstrip("\n").split("\t")
        kind, rel, nlinks = f[0], f[1], int(f[2])
        if only and kind != only.rstrip("s"):
            continue
        if any(rel == e or rel.startswith(e.rstrip("/") + "/") for e in excludes):
            continue
        p = os.path.join(mnt, rel)
        try:
            st = os.lstat(p)
        except OSError as e:
            print(f"skip {rel}: {e.strerror}")
            skipped += 1
            continue
        if not os.path.isfile(p) or os.path.islink(p):
            print(f"skip {rel}: no longer a regular file")
            skipped += 1
            continue
        if kind == "symlink":
            target = f[3]
            with open(p, "rb") as fh:
                head = fh.read(4096)
            if head[:8] != b"IntxLNK\x01" or head[8:].decode("utf-16-le", "replace") != target:
                print(f"skip {rel}: contents changed since the scan")
                skipped += 1
                continue
            if not target or ":" in target:
                print(f"skip {rel}: target {target!r} (ntfs3 mangles ':' in targets)")
                skipped += 1
                continue
            print(f"symlink {rel} -> {target}")
            if apply:
                tmp = os.path.join(os.path.dirname(p), f".{os.path.basename(p)}.ntfs3-tmp")
                os.symlink(target, tmp)
                os.utime(tmp, ns=(st.st_atime_ns, st.st_mtime_ns), follow_symlinks=False)
                os.rename(tmp, p)
                log.write(f"symlink\t{rel}\t{target}\n")
                log.flush()
        else:
            if nlinks > 1 or st.st_nlink > 1:
                print(f"skip {rel}: has {max(nlinks, st.st_nlink)} hard links")
                skipped += 1
                continue
            if st.st_size != int(f[3]):
                print(f"skip {rel}: size changed since the scan")
                skipped += 1
                continue
            free = shutil.disk_usage(mnt).free
            if st.st_size > free - min(1 << 30, free // 10):
                print(f"skip {rel}: {st.st_size >> 20} MiB would leave too little of "
                      f"{free >> 20} MiB free")
                skipped += 1
                continue
            print(f"rewrite {rel} ({st.st_size >> 20} MiB, {int(f[4]) >> 20} MiB allocated)")
            need += st.st_size - int(f[4])
            if apply:
                tmp = os.path.join(os.path.dirname(p), f".{os.path.basename(p)}.ntfs3-tmp")
                with open(p, "rb") as src, open(tmp, "wb") as dst:
                    while chunk := src.read(1 << 20):
                        dst.write(chunk)
                    dst.flush()
                    os.fsync(dst.fileno())
                shutil.copystat(p, tmp)
                if os.stat(tmp).st_size != st.st_size:
                    os.unlink(tmp)
                    print(f"  FAILED: copy of {rel} has the wrong size, original kept")
                    skipped += 1
                    continue
                os.rename(tmp, p)
                log.write(f"sparse\t{rel}\n")
                log.flush()
        done += 1
    what = "changed" if apply else "would change"
    print(f"{what} {done}, skipped {skipped}"
          + (f"; rewriting sparse files needs about {need >> 20} MiB more space" if need else ""))


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == "scan":
        scan(a[1])
    elif len(a) >= 3 and a[0] == "fix":
        rest, excludes, only, apply = a[3:], [], None, False
        while rest:
            opt = rest.pop(0)
            if opt == "--apply":
                apply = True
            elif opt == "--only" and rest:
                only = rest.pop(0)
            elif opt == "--exclude" and rest:
                excludes.append(rest.pop(0).strip("/"))
            else:
                sys.exit(f"unknown option {opt}\n{__doc__}")
        fix(a[1], a[2], apply, only, excludes)
    else:
        sys.exit(__doc__)
