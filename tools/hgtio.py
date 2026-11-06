"""Read navbuild's .hgt ground heights into a dict of global grid points -> sorted layer heights."""
import struct

import numpy as np

PER = 8  # samples per cell side


def read_hgt(path):
    d = open(path, "rb").read()
    assert d[:4] == b"HGT1"
    (nc,) = struct.unpack_from("<I", d, 4)
    p = 8
    cells = []
    for _ in range(nc):
        cx, cy = struct.unpack_from("<ii", d, p)
        p += 8
        n = np.frombuffer(d, np.uint8, PER * PER, p)
        p += PER * PER
        h = np.frombuffer(d, "<f4", int(n.sum()), p)
        p += 4 * int(n.sum())
        cells.append((cx, cy, n, h))
    return cells


def grid(cells):
    """(sx, sy) global sample index -> list of heights; sample world pos = s * 8 - 17100 (HBD coords)."""
    g = {}
    for cx, cy, n, h in cells:
        k = 0
        for idx in range(PER * PER):
            c = int(n[idx])
            if c:
                g[(cx * PER + idx % PER, cy * PER + idx // PER)] = [float(v) for v in h[k:k + c]]
            k += c
    return g
