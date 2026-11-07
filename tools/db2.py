"""Minimal WDC5 reader: record IDs and the raw bytes of each record, string lookup, and decoded fields."""
import struct


class WDC5:
    def __init__(self, data):
        assert data[:4] == b"WDC5"
        self.d = data
        p = 4 + 4 + 128
        (self.record_count, self.field_count, self.record_size, self.string_table_size, _th, _lh, self.min_id, self.max_id,
         _loc) = struct.unpack_from("<9I", data, p)
        p += 36
        self.flags, self.id_index = struct.unpack_from("<HH", data, p)
        p += 4
        (self.total_field_count, self.bitpacked_offset, self.lookup_cols, self.fsi_size, self.common_size, self.pallet_size,
         self.section_count) = struct.unpack_from("<7I", data, p)
        p += 28
        self.sections = []
        for _ in range(self.section_count):
            s = struct.unpack_from("<QIIIIIIII", data, p)
            self.sections.append(dict(key=s[0], offset=s[1], records=s[2], strings=s[3], records_end=s[4], id_list=s[5],
                                      rel=s[6], offset_map=s[7], copy=s[8]))
            p += 40
        self.fields = [struct.unpack_from("<hH", data, p + i * 4) for i in range(self.total_field_count)]
        p += self.total_field_count * 4
        self.fsi = []
        for i in range(self.fsi_size // 24):
            self.fsi.append(struct.unpack_from("<HHIII3I", data, p + i * 24)[:5] + (struct.unpack_from("<3I", data, p + i * 24 + 12),))
        p += self.fsi_size
        # pallet and common blocks, one per field that uses them, in field order
        self.pallet, self.common = {}, {}
        for i, f in enumerate(self.fsi):
            if f[3] in (3, 4):
                self.pallet[i] = p
                p += f[2]
        for i, f in enumerate(self.fsi):
            if f[3] == 2:
                self.common[i] = dict(struct.unpack_from("<%dI" % (f[2] // 4), data, p)[k:k + 2] for k in range(0, f[2] // 4, 2))
                p += f[2]
        self.records = []
        self.parent = {}  # record start -> foreign key from the relationship map
        for s in self.sections:
            if s["key"] and s["records"] == 0:
                continue
            base = s["offset"]
            rec_bytes = s["records"] * self.record_size
            strings = base + rec_bytes
            idl = strings + s["strings"]
            ids = struct.unpack_from("<%dI" % (s["id_list"] // 4), data, idl) if s["id_list"] else None
            if s["rel"]:
                rp = idl + s["id_list"] + s["copy"] * 8 + s["offset_map"] * 6
                n = struct.unpack_from("<I", data, rp)[0]
                for k in range(n):
                    fk, idx = struct.unpack_from("<II", data, rp + 12 + k * 8)
                    self.parent[base + idx * self.record_size] = fk
            for i in range(s["records"]):
                rstart = base + i * self.record_size
                rid = ids[i] if ids else None
                self.records.append((rid, rstart))

    def string_at(self, rstart, field_index):
        off = self.fields[field_index][1] if field_index < len(self.fields) else 0
        val = struct.unpack_from("<I", self.d, rstart + off)[0]
        pos = rstart + off + val
        end = self.d.index(b"\0", pos)
        return self.d[pos:end].decode("utf-8", "replace")

    def u32(self, rstart, byte_offset):
        return struct.unpack_from("<I", self.d, rstart + byte_offset)[0]

    def _bits(self, rstart, offset, size):
        b = int.from_bytes(self.d[rstart + offset // 8: rstart + (offset + size + 7) // 8 + 1], "little")
        return (b >> (offset % 8)) & ((1 << size) - 1)

    def field(self, rstart, i, rid=None, fmt="I"):
        """Field i of a record, decoded from its storage. Plain fields wider than 32 bits come back as a tuple of fmt."""
        off, size, _add, comp, _v, (v1, _, v3) = self.fsi[i]
        if comp == 0:
            n = max(1, size // 32)
            vals = struct.unpack_from("<%d%s" % (n, fmt), self.d, rstart + off // 8)
            return vals if n > 1 else vals[0]
        if comp == 2:
            return self.common[i].get(rid, v1)
        val = self._bits(rstart, off, size)
        if comp == 5 and v3 & 1 and val >> (size - 1):
            val -= 1 << size
        if comp == 3:
            val = struct.unpack_from("<I", self.d, self.pallet[i] + val * 4)[0]
        elif comp == 4:
            val = struct.unpack_from("<%dI" % v3, self.d, self.pallet[i] + val * 4 * v3)
        if fmt == "f" and comp == 3:
            val = struct.unpack("<f", struct.pack("<I", val))[0]
        return val
