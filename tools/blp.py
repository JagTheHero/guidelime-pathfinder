"""BLP2 texture decoding (DXT1/3/5, palettized, raw BGRA) to an RGBA numpy array (top mip only)."""
import struct

import numpy as np


def _565(c):
    r = ((c >> 11) & 31) * 255 // 31
    g = ((c >> 5) & 63) * 255 // 63
    b = (c & 31) * 255 // 31
    return np.stack([r, g, b], -1).astype(np.int32)


def _dxt_colors(blocks, dxt1):
    c0 = blocks[:, 0].astype(np.int32) | (blocks[:, 1].astype(np.int32) << 8)
    c1 = blocks[:, 2].astype(np.int32) | (blocks[:, 3].astype(np.int32) << 8)
    p0, p1 = _565(c0), _565(c1)
    four = (c0 > c1) | (not dxt1)
    p2 = np.where(four[:, None], (2 * p0 + p1) // 3, (p0 + p1) // 2)
    p3 = np.where(four[:, None], (p0 + 2 * p1) // 3, 0)
    pal = np.stack([p0, p1, p2, p3], 1)  # (n, 4, 3)
    idx = blocks[:, 4:8].astype(np.uint32)
    bits = idx[:, 0] | (idx[:, 1] << 8) | (idx[:, 2] << 16) | (idx[:, 3] << 24)
    sel = np.stack([(bits >> (2 * k)) & 3 for k in range(16)], 1)  # (n, 16)
    rgb = np.take_along_axis(pal, sel[:, :, None].astype(np.int64).repeat(3, 2), 1)
    alpha = np.where(four[:, None] | (sel != 3), 255, 0) if dxt1 else np.full(sel.shape, 255)
    return rgb, alpha


def _assemble(px, w, h):
    bw, bh = max(1, w // 4), max(1, h // 4)
    px = px.reshape(bh, bw, 4, 4, -1).transpose(0, 2, 1, 3, 4).reshape(bh * 4, bw * 4, -1)
    return px[:h, :w]


def decode(data):
    assert data[:4] == b"BLP2", data[:4]
    comp, adepth, atype, mips = struct.unpack_from("<BBBB", data, 8)
    w, h = struct.unpack_from("<II", data, 12)
    offs = struct.unpack_from("<16I", data, 20)
    sizes = struct.unpack_from("<16I", data, 84)
    raw = np.frombuffer(data, np.uint8, sizes[0], offs[0])
    if comp == 2:
        nblocks = max(1, w // 4) * max(1, h // 4)
        if atype == 0:  # DXT1
            blocks = raw[: nblocks * 8].reshape(-1, 8)
            rgb, a = _dxt_colors(blocks, True)
        else:  # DXT3 / DXT5: 8 alpha bytes then a colour block
            blocks = raw[: nblocks * 16].reshape(-1, 16)
            rgb, _ = _dxt_colors(blocks[:, 8:], False)
            if atype == 1:
                ab = blocks[:, :8]
                nib = np.stack([(ab[:, k // 2] >> (4 * (k % 2))) & 15 for k in range(16)], 1)
                a = nib.astype(np.int32) * 17
            else:
                a0, a1 = blocks[:, 0].astype(np.int32), blocks[:, 1].astype(np.int32)
                bits = np.zeros(len(blocks), np.uint64)
                for k in range(6):
                    bits |= blocks[:, 2 + k].astype(np.uint64) << np.uint64(8 * k)
                sel = np.stack([((bits >> np.uint64(3 * k)) & np.uint64(7)).astype(np.int32) for k in range(16)], 1)
                pal = np.zeros((len(blocks), 8), np.int32)
                pal[:, 0], pal[:, 1] = a0, a1
                gt = a0 > a1
                for k in range(2, 8):
                    pal[:, k] = np.where(gt, ((8 - k) * a0 + (k - 1) * a1) // 7, 0)
                for k in range(2, 6):
                    pal[:, k] = np.where(gt, pal[:, k], ((6 - k) * a0 + (k - 1) * a1) // 5)
                pal[:, 6] = np.where(gt, pal[:, 6], 0)
                pal[:, 7] = np.where(gt, pal[:, 7], 255)
                a = np.take_along_axis(pal, sel, 1)
        px = np.concatenate([rgb, a[:, :, None]], -1).astype(np.uint8)
        return _assemble(px, w, h)
    if comp == 1:
        pal = np.frombuffer(data, np.uint8, 1024, 148).reshape(256, 4)[:, [2, 1, 0, 3]].copy()
        img = pal[raw[: w * h]].reshape(h, w, 4)
        img[:, :, 3] = 255
        return img
    if comp == 3:
        return raw[: w * h * 4].reshape(h, w, 4)[:, :, [2, 1, 0, 3]]
    raise ValueError("unsupported BLP compression %d" % comp)
