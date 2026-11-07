"""Pack a navbuild .graph into the addon's Lua data file (format documented in Graph.lua).

usage: pack.py <graph> <instance id> <map name> <out.lua> [min component nodes] [--heights <file.hgt>] [--links <links.json>]

Coordinates go to HereBeDragons world space (x = world Y, y = world X). Small disconnected pieces
(mountain ledges, roofs) and swim nodes far out at sea are dropped. With --heights, the ground heights
(navbuild heights) of the cells near the kept nodes are packed too, for the ground dots. With --links, this
continent's flight paths, boats, lifts and portals (tools/links.py) are written as a plain table.
"""
import datetime
import json
import sys

import numpy as np

from graphio import read_graph
from hgtio import read_hgt, PER

ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
OFFSET_XY, OFFSET_Z, Q = 17100, 4000, 4
CS = 64  # lookup cell size, yards
HEIGHT_REACH = 2  # height cells are kept within this many cells of a kept node (edges are up to 143 yd long)
SEA_RANGE = 120  # swim nodes farther than this from any ground node are dropped
NODE_INDOOR, NODE_SWIM, NODE_POI = 1, 2, 4
EDGE_FLAGS = 3  # 1 swims, 2 crosses a narrow walkway (navbuild F_SWIM, F_NARROW)
AREA_SWIM, AREA_INDOOR = 2, 3


def b64(values, width):
    """Encode non-negative ints as fixed-width base-64 strings, concatenated."""
    v = np.asarray(values, np.int64)
    assert v.min(initial=0) >= 0 and v.max(initial=0) < 64 ** width, (v.min(), v.max(), width)
    digits = np.stack([(v >> (6 * (width - 1 - k))) & 63 for k in range(width)], 1)
    table = np.frombuffer(ALPHA.encode(), np.uint8)
    return table[digits].tobytes().decode()


def components(n, a, b):
    parent = np.arange(n)
    def find(x):
        root = x
        while parent[root] != root:
            root = parent[root]
        while parent[x] != root:
            parent[x], x = root, parent[x]
        return root
    for u, v in zip(a.tolist(), b.tolist()):
        ru, rv = find(u), find(v)
        if ru != rv:
            parent[ru] = rv
    return np.array([find(i) for i in range(n)])


def keep_mask(hx, hy, area, a, b, min_comp):
    n = len(hx)
    keep = np.ones(n, bool)
    # swim nodes far from any ground node
    ground = area != AREA_SWIM
    G = 128.0
    cells = {}
    for i in np.nonzero(ground)[0].tolist():
        cells.setdefault((int(hx[i] // G), int(hy[i] // G)), []).append(i)
    for i in np.nonzero(~ground)[0].tolist():
        cx, cy = int(hx[i] // G), int(hy[i] // G)
        near = False
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for j in cells.get((cx + dx, cy + dy), ()):
                    if (hx[j] - hx[i]) ** 2 + (hy[j] - hy[i]) ** 2 < SEA_RANGE ** 2:
                        near = True
                        break
                if near:
                    break
            if near:
                break
        keep[i] = near
    # small components (after the sea cut)
    m = keep[a] & keep[b]
    comp = components(n, a[m], b[m])
    _, inv, cnt = np.unique(comp, return_inverse=True, return_counts=True)
    keep &= cnt[inv] >= min_comp
    return keep


def pack_heights(cells, node_keys):
    """Per cell: base(3), 64 first-layer codes in serpentine order, extra-layer count(2), extras (index(1) height(2)).
    A code c < 62 is the previous value + (c - 31) / 2 yards, 62 is no ground, 63 is followed by an absolute
    height(2). Absolute heights are quarter yards above the base, which is (lowest height + 4000) * 4.
    Returns the index string (key(4) offset(4), sorted by key) and the data string."""
    near = set()
    for k in node_keys:
        cx, cy = k % 1024, k // 1024
        for dx in range(-HEIGHT_REACH, HEIGHT_REACH + 1):
            for dy in range(-HEIGHT_REACH, HEIGHT_REACH + 1):
                near.add((cx + dx) + (cy + dy) * 1024)
    blocks = []
    for cx, cy, n, h in cells:
        key = cx + cy * 1024
        if key not in near:
            continue
        layers, k = [], 0
        for idx in range(PER * PER):
            layers.append([float(v) for v in h[k:k + int(n[idx])]])
            k += int(n[idx])
        base = int(np.floor((min(h) + OFFSET_Z) * Q))
        def rel(z):
            return int(min(4094, max(0, round((z + OFFSET_Z) * Q) - base)))
        def absz(r):
            return (base + r) / Q - OFFSET_Z
        codes, extras = [], []
        last = absz(0)
        for j in range(PER):
            for ii in range(PER):
                idx = j * PER + (ii if j % 2 == 0 else PER - 1 - ii)
                ls = layers[idx]
                if not ls:
                    codes.append(62)
                    continue
                first = min(ls, key=lambda z: abs(z - last))
                c = int(round((first - last) * 2)) + 31
                if 0 <= c <= 61:
                    codes.append(c)
                    last = last + (c - 31) / 2
                else:
                    r = rel(first)
                    codes += [63, r >> 6, r & 63]
                    last = absz(r)
                for z in ls:
                    if z is not first:
                        r = rel(z)
                        extras += [idx, r >> 6, r & 63]
        block = b64([base], 3) + b64(codes, 1) + b64([len(extras) // 3], 2) + b64(extras, 1)
        blocks.append((key, block))
    blocks.sort()
    index, data, offset = [], [], 0
    for key, block in blocks:
        index.append(b64([key], 4) + b64([offset], 4))
        data.append(block)
        offset += len(block)
    return "".join(index), "".join(data), len(blocks)


def lua_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, str):
        return '"%s"' % v.replace("\\", "\\\\").replace('"', '\\"')
    return repr(v)


def lua_links(d, instance, piece_at):
    """The links table; each flight master and ride end on this continent also gets its walkable piece (the
    piece of a ride's far end on another continent is left false: the far continent's reverse ride has it)."""
    if not d:
        return ""
    out = ["\tlinks = {\n", "\t\ttaxi = {\n"]
    for node, pos in sorted(d["taxi"].items(), key=lambda kv: int(kv[0])):
        out.append("\t\t\t[%s] = { %s },\n" % (node, ", ".join(map(lua_value, pos + [piece_at(*pos)]))))
    out.append("\t\t},\n\t\tflights = {\n")
    for f in d["flights"]:
        out.append("\t\t\t%s,\n" % ", ".join(map(lua_value, f)))
    out.append("\t\t},\n\t\trides = {\n")
    for r in d["rides"]:
        far = piece_at(*r[6:9]) if r[5] == instance else False
        out.append("\t\t\t{ %s },\n" % ", ".join(map(lua_value, r + [piece_at(*r[2:5]), far])))
    out.append("\t\t},\n\t},\n")
    return "".join(out)


def main():
    args = sys.argv[1:]
    heights = links = None
    if "--heights" in args:
        i = args.index("--heights")
        heights = args[i + 1]
        del args[i:i + 2]
    if "--links" in args:
        i = args.index("--links")
        links = args[i + 1]
        del args[i:i + 2]
    path, instance, name, out = args[0], int(args[1]), args[2], args[3]
    min_comp = int(args[4]) if len(args) > 4 else 25
    nodes, edges = read_graph(path)
    hx = nodes['y'].astype(np.float64)  # HBD x = world Y
    hy = nodes['x'].astype(np.float64)  # HBD y = world X
    hz = nodes['z'].astype(np.float64)
    area = nodes['area'] & 0x7f
    poi = nodes['area'] >> 7  # navbuild's high bit: where a quest giver, quest object or town service stands
    a, b, ef = edges['a'].astype(np.int64), edges['b'].astype(np.int64), edges['flags']

    keep = keep_mask(hx, hy, area, a, b, min_comp)
    em = keep[a] & keep[b]
    print("%s: %d -> %d nodes, %d -> %d edges" % (name, len(hx), keep.sum(), len(a), em.sum()))

    old = np.nonzero(keep)[0]
    cx = np.floor((hx[old] + OFFSET_XY) / CS).astype(np.int64)
    cy = np.floor((hy[old] + OFFSET_XY) / CS).astype(np.int64)
    assert cx.max() < 1024 and cy.max() < 1024
    key = cx + cy * 1024
    order = np.lexsort((hy[old], hx[old], key))
    old = old[order]
    key = key[order]
    new_id = np.full(len(hx), -1, np.int64)
    new_id[old] = np.arange(len(old))

    # directed adjacency, sorted by source then neighbour
    ea, eb, efl = new_id[a[em]], new_id[b[em]], ef[em].astype(np.int64)
    src = np.concatenate([ea, eb])
    dst = np.concatenate([eb, ea])
    fl = np.concatenate([efl, efl]) & EDGE_FLAGS
    o = np.lexsort((dst, src))
    src, dst, fl = src[o], dst[o], fl[o]
    first = np.searchsorted(src, np.arange(len(old)))

    n = len(old)
    flags = (np.where(area[old] == AREA_INDOOR, NODE_INDOOR, 0) | np.where(area[old] == AREA_SWIM, NODE_SWIM, 0)
             | np.where(poi[old] > 0, NODE_POI, 0))
    qx = np.round((hx[old] + OFFSET_XY) * Q).astype(np.int64)
    qy = np.round((hy[old] + OFFSET_XY) * Q).astype(np.int64)
    qz = np.round((np.clip(hz[old], -OFFSET_Z, 60000) + OFFSET_Z) * Q).astype(np.int64)
    rec = [b64(qx, 3), b64(qy, 3), b64(qz, 3), b64(flags, 1), b64(first, 4)]
    node_str = "".join("".join(r[i * w:(i + 1) * w] for r, w in zip(rec, (3, 3, 3, 1, 4))) for i in range(n))
    edge_rec = [b64(dst, 3), b64(fl, 1)]
    edge_str = "".join(edge_rec[0][i * 3:i * 3 + 3] + edge_rec[1][i] for i in range(len(dst)))

    # walkable pieces: 0 for the biggest, then by size; links tell which piece a dock or landing is on
    comp = components(n, ea, eb)
    _, inv, cnt = np.unique(comp, return_inverse=True, return_counts=True)
    rank = np.empty(len(cnt), np.int64)
    rank[np.argsort(-cnt, kind="stable")] = np.arange(len(cnt))
    comp_str = b64(rank[inv], 2)

    ukeys, ufirst, ucount = np.unique(key, return_index=True, return_counts=True)
    c0, c1, c2 = b64(ukeys, 4), b64(ufirst, 3), b64(ucount, 3)
    cell_str = "".join(c0[i * 4:i * 4 + 4] + c1[i * 3:i * 3 + 3] + c2[i * 3:i * 3 + 3] for i in range(len(ukeys)))

    hindex = hdata = ""
    hcount = 0
    if heights:
        hindex, hdata, hcount = pack_heights(read_hgt(heights), set(ukeys.tolist()))
        print("heights: %d cells, %.1f MB" % (hcount, (len(hindex) + len(hdata)) / 1e6))

    built = datetime.date.today().isoformat()
    with open(out, "w") as f:
        f.write("-- Pathfinding graph for %s, generated by tools/pack.py from the game's terrain and buildings. Do not edit.\n" % name)
        f.write("local _, ns = ...\n")
        f.write("ns.Graph.Register(%d, {\n" % instance)
        f.write('\tn = %d, e = %d, c = %d, cs = %d, built = "%s",\n' % (n, len(dst), len(ukeys), CS, built))
        f.write('\tnodes = "%s",\n' % node_str)
        f.write('\tedges = "%s",\n' % edge_str)
        f.write('\tcells = "%s",\n' % cell_str)
        if hcount:
            f.write('\thc = %d, hs = 8,\n' % hcount)
            f.write('\thcells = "%s",\n' % hindex)
            f.write('\theights = "%s",\n' % hdata)
        f.write('\tcomps = "%s",\n' % comp_str)
        if links:
            kx, ky, kz, kp = hx[old], hy[old], hz[old], rank[inv]

            def piece_at(x, y, z):
                d2 = np.hypot(kx - x, ky - y)
                d3 = np.where((d2 < 60) & (kz <= z + 5), np.sqrt(d2 ** 2 + (kz - z) ** 2), np.inf)
                j = int(d3.argmin())
                return int(kp[j]) if np.isfinite(d3[j]) else False  # not on the ground (a ship route's node)
            with open(links) as lf:
                f.write(lua_links(json.load(lf).get(str(instance)), instance, piece_at))
        f.write("})\n")
    print("wrote %s: %d nodes, %d directed edges, %d cells, %.1f MB" % (out, n, len(dst), len(ukeys),
          (len(node_str) + len(edge_str) + len(cell_str)) / 1e6))


if __name__ == "__main__":
    main()
