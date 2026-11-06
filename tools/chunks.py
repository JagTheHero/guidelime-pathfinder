"""Chunked-file helpers for WoW formats (reversed 4-char chunk ids)."""
import struct


def iter_chunks(data, start=0, end=None):
    end = len(data) if end is None else end
    pos = start
    while pos + 8 <= end:
        cid = data[pos:pos + 4][::-1].decode("latin1")
        size = struct.unpack_from("<I", data, pos + 4)[0]
        yield cid, pos + 8, size
        pos += 8 + size


def chunk_map(data, start=0, end=None):
    """First occurrence of each chunk id -> (offset, size)."""
    out = {}
    for cid, off, size in iter_chunks(data, start, end):
        out.setdefault(cid, (off, size))
    return out
