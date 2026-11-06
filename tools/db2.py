"""Minimal WDC5 reader: record IDs and the raw bytes of each record, plus string lookup."""
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
        p += self.fsi_size + self.pallet_size + self.common_size
        self.records = []
        for s in self.sections:
            if s["key"] and s["records"] == 0:
                continue
            base = s["offset"]
            rec_bytes = s["records"] * self.record_size
            strings = base + rec_bytes
            idl = strings + s["strings"]
            ids = struct.unpack_from("<%dI" % (s["id_list"] // 4), data, idl) if s["id_list"] else None
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
