"""Pack navbuild's walk grid (.hgt3: ground points every 2 yards, every walkable layer with where it ends, and the
steep ground beside it) for the addon.

The format is documented in Graph.lua (wcells, walk, scells, steep). An 8-yard block whose points are all
single-layer ground within TOL of the bilinear blend of its four corner points, with no edge, keeps only its
corner; any other block keeps all 16 of its points.
"""
import struct

import numpy as np

PER, BS, NB = 32, 4, 8  # points per cell side, points per block side, blocks per cell side
QZ, OFF_Z = 4, 4000     # heights in quarter yards above -4000
TOL = 0.25              # yards a smooth block's points may be off the blend of its corners
ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
# a chain of points (the block corners, then each full block's other points) is coded as steps from the point
# before, in quarter yards: codes 0-48 are two points' steps a, b in -3..3 (code (a + 3) * 7 + b + 3); 49-55 one
# point's step in -3..3; 56-59 one point's step of -5, -4, 4 or 5; 60 one point without ground; 61 four points
# without ground; 62 a step in -32..31 in the next char (+32); 63 an absolute height in the next 3 chars
PAIR, SMALL, MID, HOLE, HOLE4, WIDE, ABSOLUTE = 0, 49, 56, 60, 61, 62, 63
MIDS = [-5, -4, 4, 5]
SERP = [(oj, oi if oj % 2 == 0 else BS - 1 - oi) for oj in range(BS) for oi in range(BS)][1:]  # a block's points after its corner


NO_EDGE = 0xFFF  # a layer's edges: 3 bits per direction (+x, -x, +y, -y from the low bits), 7 for none


def read_grid(path):
    """{key: (counts[1024], heights[] float32, edges[] uint16 or None, steep counts[1024], steep heights[])} with
    key = cx + cy * 1024, from an .hgt3 (or an older .hgt2: no edges, no steep ground)."""
    d = open(path, "rb").read()
    v3 = d[:4] == b"HGT3"
    assert v3 or d[:4] == b"HGT2"
    (nc,) = struct.unpack_from("<I", d, 4)
    p, out = 8, {}
    none = np.zeros(PER * PER, np.uint8)
    for _ in range(nc):
        cx, cy = struct.unpack_from("<ii", d, p)
        p += 8
        n = np.frombuffer(d, np.uint8, PER * PER, p)
        p += PER * PER
        k = int(n.sum())
        h = np.frombuffer(d, "<f4", k, p)
        p += 4 * k
        e, sn, sh = None, none, np.zeros(0, np.float32)
        if v3:
            e = np.frombuffer(d, "<u2", k, p)
            p += 2 * k
            sn = np.frombuffer(d, np.uint8, PER * PER, p)
            p += PER * PER
            ks = int(sn.sum())
            sh = np.frombuffer(d, "<f4", ks, p)
            p += 4 * ks
        out[cx + cy * 1024] = (n, h, e, sn, sh)
    return out


def read_hgt2(path):
    """{key: (counts[1024], heights[] float32)} of the walkable layers, with key = cx + cy * 1024."""
    return {k: (c[0], c[1]) for k, c in read_grid(path).items()}


def first_layer(cell):
    """Each point's lowest layer (NaN without ground) as a PER x PER array, and the layer counts."""
    n, h = cell
    z = np.full(PER * PER, np.nan)
    at = np.concatenate([[0], np.cumsum(n.astype(np.int64))[:-1]])
    z[n > 0] = h[at[n > 0]]
    return z.reshape(PER, PER), n.reshape(PER, PER)


def b64(v, width):
    assert 0 <= v < 64 ** width, (v, width)
    return "".join(ALPHA[(v >> (6 * (width - 1 - k))) & 63] for k in range(width))


def pack_walk(cells, keep_keys, edges=None):
    """Returns (index string, data string, cell count, refined share) for the cells in keep_keys of cells ({key:
    (counts, heights)}), with each layer's edges ({key: edges[]}) if given."""
    firsts = {}

    def fl(key):
        if key not in firsts:
            firsts[key] = first_layer(cells[key]) if key in cells else (np.full((PER, PER), np.nan), np.zeros((PER, PER), np.uint8))
        return firsts[key]

    blocks = refined_blocks = 0
    index, data, offset = [], [], 0
    fy, fx = np.mgrid[0:BS, 0:BS] / BS
    for key in sorted(k for k in keep_keys if k in cells):
        Z, N = fl(key)
        # the points one past the cell's top and right edges (the next cells' first row and column)
        ZE = np.full((PER + 1, PER + 1), np.nan)
        NE = np.zeros((PER + 1, PER + 1), np.int64)
        ZE[:PER, :PER], NE[:PER, :PER] = Z, N
        zr, nr = fl(key + 1)
        ZE[:PER, PER], NE[:PER, PER] = zr[:, 0], nr[:, 0]
        zu, nu = fl(key + 1024)
        ZE[PER, :PER], NE[PER, :PER] = zu[0, :], nu[0, :]
        zd, nd = fl(key + 1025)
        ZE[PER, PER], NE[PER, PER] = zd[0, 0], nd[0, 0]
        e = edges.get(key) if edges else None
        edged = np.zeros(PER * PER, bool)
        if e is not None:
            nn = cells[key][0].astype(np.int64)
            owner = np.repeat(np.arange(PER * PER), nn)
            edged[owner[e != NO_EDGE]] = True
        edged = edged.reshape(PER, PER)
        refine = np.zeros((NB, NB), bool)
        for bj in range(NB):
            for bi in range(NB):
                j0, i0 = bj * BS, bi * BS
                pts, cnt = ZE[j0:j0 + BS, i0:i0 + BS], NE[j0:j0 + BS, i0:i0 + BS]
                cn = NE[[j0, j0, j0 + BS, j0 + BS], [i0, i0 + BS, i0, i0 + BS]]
                if (cnt == 0).all():
                    refine[bj, bi] = False  # no ground anywhere in it
                elif (cnt != 1).any() or (cn != 1).any() or edged[j0:j0 + BS, i0:i0 + BS].any():
                    refine[bj, bi] = True  # holes, edges, stacked layers
                else:
                    c = ZE[[j0, j0, j0 + BS, j0 + BS], [i0, i0 + BS, i0, i0 + BS]]
                    blend = c[0] * (1 - fx) * (1 - fy) + c[1] * fx * (1 - fy) + c[2] * (1 - fx) * fy + c[3] * fx * fy
                    refine[bj, bi] = np.abs(blend - pts).max() > TOL
        blocks += NB * NB
        refined_blocks += int(refine.sum())

        n, h = cells[key]
        start = np.concatenate([[0], np.cumsum(n.astype(np.int64))[:-1]])
        extras, first_of = [], {}

        def chain(points, prev):
            """codes for a chain of points from height prev (None: unknown); returns the codes and each point's
            height on the chain (None without ground)"""
            steps, heights = [], []  # steps: per point None (no ground) or (step, or None for absolute; height)
            for j, i in points:
                idx = j * PER + i
                c = int(n[idx])
                if c == 0:
                    steps.append(None)
                    heights.append(None)
                    continue
                layers = [int(round((float(z) + OFF_Z) * QZ)) for z in h[start[idx]:start[idx] + c]]
                first = layers[0] if prev is None else min(layers, key=lambda q: abs(q - prev))
                steps.append((None if prev is None or abs(first - prev) > 31 else first - prev, first))
                heights.append(first)
                first_of[idx] = first
                prev = first
                done = False
                for q in layers:
                    if q == first and not done:
                        done = True
                    else:
                        extras.append((idx, q - first))
            out, k = [], 0
            while k < len(steps):
                st = steps[k]
                if st is None:
                    run = k + 3 < len(steps) and steps[k + 1] is None and steps[k + 2] is None and steps[k + 3] is None
                    out.append(ALPHA[HOLE4 if run else HOLE])
                    k += 4 if run else 1
                    continue
                d, q = st
                nxt = steps[k + 1] if k + 1 < len(steps) else None
                if d is not None and abs(d) <= 3 and nxt is not None and nxt[0] is not None and abs(nxt[0]) <= 3:
                    out.append(ALPHA[PAIR + (d + 3) * 7 + nxt[0] + 3])
                    k += 2
                    continue
                if d is None:
                    out.append(ALPHA[ABSOLUTE] + b64(q, 3))
                elif abs(d) <= 3:
                    out.append(ALPHA[SMALL + d + 3])
                elif d in MIDS:
                    out.append(ALPHA[MID + MIDS.index(d)])
                else:
                    out.append(ALPHA[WIDE] + ALPHA[d + 32])
                k += 1
            return out, heights

        corners = [(bj * BS, (k if bj % 2 == 0 else NB - 1 - k) * BS) for bj in range(NB) for k in range(NB)]
        out, ch = chain(corners, None)
        corner_q = {(j // BS, i // BS): q for (j, i), q in zip(corners, ch)}
        bits = [int(refine[b // NB, b % NB]) for b in range(NB * NB)] + [0, 0]
        out.append("".join(ALPHA[sum(bits[c * 6 + k] << (5 - k) for k in range(6))] for c in range(11)))
        for bj in range(NB):
            for bi in range(NB):
                if refine[bj, bi]:
                    codes, _ = chain([(bj * BS + oj, bi * BS + oi) for oj, oi in SERP], corner_q[(bj, bi)])
                    out += codes
        # extra layers: point index as a step from the last one's (1 char 0-62, or 63 then 2 chars), then the
        # height above or below the point's first layer in quarter yards (2 chars, offset 2048; 4095 then the
        # absolute height in 3 chars when over 511 yards away)
        ex, last = [], -1
        for idx, dq in sorted(extras):
            gap = idx - last
            ex.append(ALPHA[gap] if gap < 63 else ALPHA[63] + b64(idx, 2))
            ex.append(b64(dq + 2048, 2) if -2048 <= dq < 2047 else b64(4095, 2) + b64(first_of[idx] + dq, 3))
            last = idx
        block = "".join(out) + b64(len(extras), 3) + "".join(ex)
        if edges is not None:
            # edges: count(3), then per layer with one: the point's index as a step from the last one's (1 char
            # below 62, else 62 and the index(2)), the edge bits (2), and the layer's rank from the lowest (1) at a
            # point with more than one layer
            rec, last, count = [], -1, 0
            if e is not None:
                for k in np.nonzero(e != NO_EDGE)[0]:
                    idx = int(owner[k])
                    gap = idx - last
                    rec.append(ALPHA[gap - 1] if 1 <= gap <= 62 else ALPHA[62] + b64(idx, 2))
                    rec.append(b64(int(e[k]), 2))
                    if n[idx] > 1:
                        rec.append(ALPHA[int(k - start[idx])])
                    last, count = idx, count + 1
            block += b64(count, 3) + "".join(rec)
        index.append(b64(key, 4) + b64(offset, 5))
        data.append(block)
        offset += len(block)
    return "".join(index), "".join(data), len(index), refined_blocks / max(1, blocks)
