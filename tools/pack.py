"""Pack a navbuild .graph into the addon's Lua data file (format documented in Graph.lua).

usage: pack.py <graph> <instance id> <map name> <out.lua> [min component nodes] [--walk <file.hgt2>] [--links <links.json>]
               [--mobs <file.mobs>]

Coordinates go to HereBeDragons world space (x = world Y, y = world X). Small disconnected pieces
(mountain ledges, roofs) and swim nodes far out at sea are dropped. With --walk, the walk grid (navbuild walkgrid:
ground every 2 yards, every layer, tools/walkpack.py) of the cells near the kept nodes is packed too. With --links, this
continent's flight paths, boats, lifts and portals (tools/links.py) are written as a plain table. With --mobs,
the hostile mobs and patrol points (tools/mobs.py) in the kept cells and around them, by cell.
"""
import datetime
import json
import sys

import numpy as np

from graphio import read_graph
from walkpack import pack_walk

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


def near_cells(node_keys):
    """The cells within HEIGHT_REACH of a cell with kept nodes."""
    near = set()
    for k in node_keys:
        cx, cy = k % 1024, k // 1024
        for dx in range(-HEIGHT_REACH, HEIGHT_REACH + 1):
            for dy in range(-HEIGHT_REACH, HEIGHT_REACH + 1):
                near.add((cx + dx) + (cy + dy) * 1024)
    return near


def pack_mobs(path, node_keys):
    """Mobs (tools/mobs.py) in HBD coordinates, sorted by 64-yard cell, in cells with path nodes or next to them:
    mobs: m records of 14 chars x(3) y(3) z(3) minLevel(1) maxLevel(1) detection(1) wander(1) flags(1);
    mcells: records of 10 chars cellKey(4) firstMob(3) count(3)."""
    rows = np.loadtxt(path, ndmin=2)
    x, y, z = rows[:, 1], rows[:, 0], rows[:, 2]  # HBD x = world Y, y = world X
    cx = np.floor((x + OFFSET_XY) / CS).astype(np.int64)
    cy = np.floor((y + OFFSET_XY) / CS).astype(np.int64)
    near = set()
    for k in node_keys:
        for d in (-1025, -1024, -1023, -1, 0, 1, 1023, 1024, 1025):
            near.add(k + d)
    key = cx + cy * 1024
    keep = np.isin(key, list(near))
    rows, x, y, z, key = rows[keep], x[keep], y[keep], z[keep], key[keep]
    o = np.argsort(key, kind="stable")
    rows, x, y, z, key = rows[o], x[o], y[o], z[o], key[o]
    cols = [b64(np.round((x + OFFSET_XY) * Q), 3), b64(np.round((y + OFFSET_XY) * Q), 3),
            b64(np.round((np.clip(z, -OFFSET_Z, 60000) + OFFSET_Z) * Q), 3)]
    cols += [b64(np.clip(rows[:, k], 0, 63), 1) for k in range(3, 8)]
    widths = [3, 3, 3, 1, 1, 1, 1, 1]
    mob_str = "".join("".join(c[i * w:(i + 1) * w] for c, w in zip(cols, widths)) for i in range(len(rows)))
    ukeys, ufirst, ucount = np.unique(key, return_index=True, return_counts=True)
    c0, c1, c2 = b64(ukeys, 4), b64(ufirst, 3), b64(ucount, 3)
    mcell_str = "".join(c0[i * 4:i * 4 + 4] + c1[i * 3:i * 3 + 3] + c2[i * 3:i * 3 + 3] for i in range(len(ukeys)))
    return len(rows), mob_str, mcell_str


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
    walk = links = None
    if "--walk" in args:
        i = args.index("--walk")
        walk = args[i + 1]
        del args[i:i + 2]
    if "--links" in args:
        i = args.index("--links")
        links = args[i + 1]
        del args[i:i + 2]
    mobs = None
    if "--mobs" in args:
        i = args.index("--mobs")
        mobs = args[i + 1]
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
    # an edge's neighbour: 18 bits in 3 chars, the rest in its flag char above the 2 flag bits
    if n > 64 ** 3 * 16:
        raise SystemExit("%d nodes: an edge's neighbour has 22 bits (at most %d nodes)" % (n, 64 ** 3 * 16))
    flags = (np.where(area[old] == AREA_INDOOR, NODE_INDOOR, 0) | np.where(area[old] == AREA_SWIM, NODE_SWIM, 0)
             | np.where(poi[old] > 0, NODE_POI, 0))
    qx = np.round((hx[old] + OFFSET_XY) * Q).astype(np.int64)
    qy = np.round((hy[old] + OFFSET_XY) * Q).astype(np.int64)
    qz = np.round((np.clip(hz[old], -OFFSET_Z, 60000) + OFFSET_Z) * Q).astype(np.int64)
    rec = [b64(qx, 3), b64(qy, 3), b64(qz, 3), b64(flags, 1), b64(first, 4)]
    node_str = "".join("".join(r[i * w:(i + 1) * w] for r, w in zip(rec, (3, 3, 3, 1, 4))) for i in range(n))
    edge_rec = [b64(dst & (64 ** 3 - 1), 3), b64(fl | (dst >> 18) << 2, 1)]
    edge_str = "".join(edge_rec[0][i * 3:i * 3 + 3] + edge_rec[1][i] for i in range(len(dst)))

    # walkable pieces: 0 for the biggest, then by size; links tell which piece a dock or landing is on
    comp = components(n, ea, eb)
    _, inv, cnt = np.unique(comp, return_inverse=True, return_counts=True)
    rank = np.empty(len(cnt), np.int64)
    rank[np.argsort(-cnt, kind="stable")] = np.arange(len(cnt))
    comp_str = b64(rank[inv], 2)

    ukeys, ufirst, ucount = np.unique(key, return_index=True, return_counts=True)
    c0, c1, c2 = b64(ukeys, 4), b64(ufirst, 4), b64(ucount, 2)
    cell_str = "".join(c0[i * 4:i * 4 + 4] + c1[i * 4:i * 4 + 4] + c2[i * 2:i * 2 + 2] for i in range(len(ukeys)))

    windex = wdata = ""
    wcount = 0
    if walk:
        windex, wdata, wcount, share = pack_walk(walk, near_cells(set(ukeys.tolist())))
        print("walk grid: %d cells, %.0f%% of 8-yard blocks in full, %.1f MB" % (wcount, 100 * share, (len(windex) + len(wdata)) / 1e6))

    built = datetime.date.today().isoformat()
    with open(out, "w") as f:
        f.write("-- Pathfinding graph for %s, generated by tools/pack.py from the game's terrain and buildings. Do not edit.\n" % name)
        f.write("local _, ns = ...\n")
        f.write("ns.Graph.Register(%d, {\n" % instance)
        f.write('\tn = %d, e = %d, c = %d, cs = %d, built = "%s",\n' % (n, len(dst), len(ukeys), CS, built))
        f.write('\tnodes = "%s",\n' % node_str)
        f.write('\tedges = "%s",\n' % edge_str)
        f.write('\tcells = "%s",\n' % cell_str)
        if wcount:
            f.write('\twc = %d,\n' % wcount)
            f.write('\twcells = "%s",\n' % windex)
            f.write('\twalk = "%s",\n' % wdata)
        f.write('\tcomps = "%s",\n' % comp_str)
        if mobs:
            m, mob_str, mcell_str = pack_mobs(mobs, set(ukeys.tolist()))
            f.write('\tm = %d,\n' % m)
            f.write('\tmobs = "%s",\n' % mob_str)
            f.write('\tmcells = "%s",\n' % mcell_str)
            print("mobs: %d, %.2f MB" % (m, (len(mob_str) + len(mcell_str)) / 1e6))
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
