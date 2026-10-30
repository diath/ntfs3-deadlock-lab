#!/usr/bin/env python3
"""Read-only: dump MFT records from an NTFS device and replay ntfs3's
mi_enum_attr() checks (fs/ntfs3/record.c, Linux 7.2.11) on each attribute.

usage: mftcheck.py <device> <mft-record-number>...   (numbers may be 0x...)
       mftcheck.py <device> --scan    (check every in-use record)
"""
import os
import struct
import sys

ATTR_NAMES = {0x10: "$STANDARD_INFORMATION", 0x20: "$ATTRIBUTE_LIST", 0x30: "$FILE_NAME",
              0x40: "$OBJECT_ID", 0x50: "$SECURITY_DESCRIPTOR", 0x60: "$VOLUME_NAME",
              0x70: "$VOLUME_INFORMATION", 0x80: "$DATA", 0x90: "$INDEX_ROOT",
              0xA0: "$INDEX_ALLOCATION", 0xB0: "$BITMAP", 0xC0: "$REPARSE_POINT",
              0xD0: "$EA_INFORMATION", 0xE0: "$EA", 0x100: "$LOGGED_UTILITY_STREAM"}
F_COMPRESSED, F_ENCRYPTED, F_SPARSE = 0x0001, 0x4000, 0x8000
FIXUP_OFFSET_1 = 0x2A


def u16(b, o): return struct.unpack_from("<H", b, o)[0]
def u32(b, o): return struct.unpack_from("<I", b, o)[0]
def u64(b, o): return struct.unpack_from("<Q", b, o)[0]


class Vol:
    def __init__(self, dev):
        self.fd = os.open(dev, os.O_RDONLY)
        bs = os.pread(self.fd, 512, 0)
        assert bs[3:11] == b"NTFS    ", "not an NTFS boot sector"
        self.sector = u16(bs, 0x0B)
        self.cluster = self.sector * bs[0x0D]
        self.total_clusters = u64(bs, 0x28) * self.sector // self.cluster
        self.volume_size = u64(bs, 0x28) * self.sector
        self.mft_lcn = u64(bs, 0x30)
        c = struct.unpack_from("<b", bs, 0x40)[0]
        self.rec_size = c * self.cluster if c > 0 else 1 << -c
        rec0 = self.fixup(os.pread(self.fd, self.rec_size, self.mft_lcn * self.cluster))
        self.mft_runs = None
        for a in self.attrs(rec0):
            if a["type"] == 0x80 and a["nonres"]:
                self.mft_runs = self.runlist(rec0, a)
        assert self.mft_runs, "no $MFT $DATA runlist"

    def fixup(self, rec):
        rec = bytearray(rec)
        ofs, cnt = u16(rec, 4), u16(rec, 6)
        usn = rec[ofs:ofs + 2]
        for i in range(1, cnt):
            end = i * self.sector - 2
            if rec[end:end + 2] != usn:
                raise ValueError("fixup mismatch (torn or not-yet-written record)")
            rec[end:end + 2] = rec[ofs + 2 * i:ofs + 2 * i + 2]
        return bytes(rec)

    def runlist(self, rec, a):
        o = a["off"] + u16(rec, a["off"] + 32)
        runs, lcn = [], 0
        vcn = u64(rec, a["off"] + 16)
        while rec[o]:
            h = rec[o]
            ln, lo = h & 0xF, h >> 4
            length = int.from_bytes(rec[o + 1:o + 1 + ln], "little")
            delta = int.from_bytes(rec[o + 1 + ln:o + 1 + ln + lo], "little", signed=True) if lo else None
            if delta is not None:
                lcn += delta
            runs.append((vcn, length, lcn if delta is not None else None))
            vcn += length
            o += 1 + ln + lo
        return runs

    def read_record(self, num):
        byte = num * self.rec_size
        vcn, inner = divmod(byte, self.cluster)
        for start, length, lcn in self.mft_runs:
            if start <= vcn < start + length:
                pos = (lcn + vcn - start) * self.cluster + inner
                return self.fixup(os.pread(self.fd, self.rec_size, pos))
        raise ValueError(f"record {num:#x} beyond the first $MFT extent")

    def attrs(self, rec):
        off = u16(rec, 20)
        used = u32(rec, 24)
        out = []
        while off + 8 <= used and u32(rec, off) != 0xFFFFFFFF:
            t, asize = u32(rec, off), u32(rec, off + 4)
            a = {"off": off, "type": t, "size": asize, "nonres": rec[off + 8],
                 "name_len": rec[off + 9], "name_off": u16(rec, off + 10), "flags": u16(rec, off + 12)}
            out.append(a)
            if asize == 0:
                break
            off += asize
        return out


def check(vol, rec, a, prev_type):
    """Return the first mi_enum_attr() check this attribute fails, or None."""
    o, t32, asize, used = a["off"], a["type"], a["size"], u32(rec, 24)
    if not t32 or t32 & 0xF or t32 > 0x100:
        return "type 0 / unaligned / > 0x100"
    if t32 < prev_type:
        return f"attributes not sorted by type ({t32:#x} after {prev_type:#x})"
    if asize % 8:
        return "attribute size not 8-aligned"
    if o + asize > used:
        return "attribute runs past record 'used'"
    name_bytes = 2 * a["name_len"]
    if not a["nonres"]:
        if asize < 0x18:
            return "resident attribute smaller than header"
        data_off, data_size = u16(rec, o + 20), u32(rec, o + 16)
        if data_off > asize:
            return "resident data_off > attribute size"
        if data_size > asize - data_off:
            return "resident data_size overruns attribute"
        if name_bytes and a["name_off"] + name_bytes > data_off:
            return "name overlaps resident data"
        return None
    if a["nonres"] != 1:
        return f"non_res byte is {a['nonres']}, not 0/1"
    if asize < 0x40:
        return "non-resident attribute smaller than 0x40 header"
    run_off = u16(rec, o + 32)
    if run_off > asize:
        return "run_off > attribute size"
    if name_bytes and a["name_off"] + name_bytes > run_off:
        return "name overlaps runs"
    svcn, evcn = u64(rec, o + 16), u64(rec, o + 24)
    if svcn > (evcn + 1) & 0xFFFFFFFFFFFFFFFF:
        return f"svcn {svcn} > evcn+1 ({evcn})"
    ext = bool(a["flags"] & (F_SPARSE | F_COMPRESSED))
    if ext:
        if evcn != 2**64 - 1 and evcn >= 1 << 32:
            return "sparse/compressed evcn >= 2^32"
    elif evcn != 2**64 - 1 and evcn >= vol.total_clusters:
        return f"evcn {evcn} beyond volume ({vol.total_clusters} clusters)"
    alloc, data, valid = u64(rec, o + 40), u64(rec, o + 48), u64(rec, o + 56)
    if valid > data:
        return f"valid_size {valid} > data_size {data}"
    if data > alloc:
        return f"data_size {data} > alloc_size {alloc}"
    if alloc % vol.cluster:
        return f"alloc_size {alloc} not cluster-aligned"
    c_unit = rec[o + 34]
    if svcn == 0 and ext:
        if asize < 0x48:
            return "first sparse/compressed segment without total_size (header < 0x48)"
        tot = u64(rec, o + 64)
        if tot % vol.cluster:
            return f"total_size {tot} not cluster-aligned"
        if tot > alloc:
            return f"total_size {tot} > alloc_size {alloc}"
    else:
        if c_unit:
            what = "non-first segment" if svcn else "not sparse/compressed"
            return f"compression unit {c_unit} set on a {what} attribute (flags {a['flags']:#06x})"
        if alloc > vol.volume_size:
            return f"alloc_size {alloc} > volume size"
    return None


def describe(vol, num):
    rec = vol.read_record(num)
    if rec[:4] != b"FILE":
        print(f"record {num:#x}: no FILE signature")
        return
    flags, base = u16(rec, 22), u64(rec, 32) & 0xFFFFFFFFFFFF
    print(f"record {num:#x}: in_use={bool(flags & 1)} dir={bool(flags & 2)} "
          f"used={u32(rec, 24)}/{u32(rec, 28)} base={base:#x} seq={u16(rec, 16)}")
    prev, ext_records = 0, []
    for a in vol.attrs(rec):
        t = a["type"]
        line = f"  {ATTR_NAMES.get(t, hex(t)):24s} size={a['size']:<4} " \
               f"{'nonres' if a['nonres'] else 'res   '} flags={a['flags']:#06x}"
        if t == 0x30 and not a["nonres"]:
            vo = a["off"] + u16(rec, a["off"] + 20)
            nlen = rec[vo + 64]
            line += f" name={rec[vo + 66:vo + 66 + 2 * nlen].decode('utf-16-le', 'replace')!r}"
        if a["nonres"]:
            o = a["off"]
            line += (f" vcn={u64(rec, o + 16)}..{u64(rec, o + 24) if u64(rec, o + 24) < 2**63 else -1}"
                     f" cu={rec[o + 34]} alloc={u64(rec, o + 40)} data={u64(rec, o + 48)}"
                     f" valid={u64(rec, o + 56)}")
        if t == 0x20 and not a["nonres"]:
            vo, vl = a["off"] + u16(rec, a["off"] + 20), u32(rec, a["off"] + 16)
            p = vo
            while p < vo + vl:
                ref = u64(rec, p + 16) & 0xFFFFFFFFFFFF
                if ref != num and ref not in ext_records:
                    ext_records.append(ref)
                p += u16(rec, p + 4) or vl
        bad = check(vol, rec, a, prev)
        print(line + (f"\n    -> REJECTED by mi_enum_attr: {bad}" if bad else ""))
        if bad:
            break
        prev = t
    for e in ext_records:
        describe(vol, e)


if __name__ == "__main__":
    vol = Vol(sys.argv[1])
    print(f"cluster={vol.cluster} record={vol.rec_size} clusters={vol.total_clusters} "
          f"mft_lcn={vol.mft_lcn} mft_extents={len(vol.mft_runs)}")
    for n in ([] if sys.argv[2:3] == ["--scan"] else sys.argv[2:]):
        try:
            describe(vol, int(n, 0))
        except ValueError as e:
            print(f"record {n}: {e}")


def scan(vol):
    """Check every in-use record; print counts by reason and examples."""
    import collections
    reasons, examples, total, inuse = collections.Counter(), collections.defaultdict(list), 0, 0
    chunk = 1024 * vol.rec_size
    for start, length, lcn in vol.mft_runs:
        if lcn is None:
            continue
        base_rec = start * vol.cluster // vol.rec_size
        nbytes = length * vol.cluster
        for pos in range(0, nbytes, chunk):
            buf = os.pread(vol.fd, min(chunk, nbytes - pos), lcn * vol.cluster + pos)
            for i in range(0, len(buf), vol.rec_size):
                total += 1
                raw = buf[i:i + vol.rec_size]
                if raw[:4] != b"FILE" or not u16(raw, 22) & 1:
                    continue
                inuse += 1
                num = base_rec + (pos + i) // vol.rec_size
                try:
                    rec = vol.fixup(raw)
                except ValueError:
                    reasons["torn record (fixup mismatch)"] += 1
                    continue
                prev, name = 0, ""
                for a in vol.attrs(rec):
                    if a["type"] == 0x30 and not a["nonres"] and not name:
                        vo = a["off"] + u16(rec, a["off"] + 20)
                        name = rec[vo + 66:vo + 66 + 2 * rec[vo + 64]].decode("utf-16-le", "replace")
                    bad = check(vol, rec, a, prev)
                    if bad:
                        key = bad.split(" ")[0] if bad.startswith(("total_size", "valid_size", "data_size", "evcn", "alloc_size")) else bad
                        key = {"total_size": "sparse/compressed total_size > alloc_size or unaligned"}.get(key, key)
                        reasons[key] += 1
                        if len(examples[key]) < 8:
                            examples[key].append(f"{num:#x} {name!r} {ATTR_NAMES.get(a['type'], hex(a['type']))}: {bad}")
                        break
                    prev = a["type"]
    print(f"records scanned: {total}, in use: {inuse}, rejected: {sum(reasons.values())}")
    for k, v in reasons.most_common():
        print(f"  {v:7d}  {k}")
        for e in examples[k]:
            print(f"           {e}")
    vrec = vol.read_record(3)
    for a in vol.attrs(vrec):
        if a["type"] == 0x70:
            vo = a["off"] + u16(vrec, a["off"] + 20)
            print(f"$Volume: NTFS {vrec[vo + 8]}.{vrec[vo + 9]}, flags={u16(vrec, vo + 10):#06x} "
                  f"(dirty={bool(u16(vrec, vo + 10) & 1)})")


if __name__ == "__main__" and sys.argv[2:3] == ["--scan"]:
    scan(vol)
