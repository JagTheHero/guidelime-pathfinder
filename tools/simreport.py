"""Summarise navbuild simtruth output: how far the addon's player height and ground dots are from the true ground.

usage: simreport.py <sim.tsv> <truth.tsv> [worst N] [walk grid .hgt2, to say why dots are off]
The error that shows on screen is a dot's height error relative to the player's (the camera is solved from the
player's height), so both are reported: absolute and relative to the player.
"""
import sys
from collections import defaultdict

import numpy as np


def main():
    names, inst, unsure, dots, blocked = {}, {}, 0, 0, 0
    for line in open(sys.argv[1]):
        if line[0] == "R":
            f = line.split()
            names[int(f[1])], inst[int(f[1])] = f[3], int(f[2])
        elif line[0] == "U":
            unsure += 1
        elif line[0] == "D":
            dots += 1
        elif line[0] == "B":
            blocked += 1
    P, D = {}, []
    for line in open(sys.argv[2]):
        f = line.split()
        if f[0] == "P":
            P[(int(f[1]), int(f[2]))] = (float(f[3]), float(f[4]), float(f[6]), float(f[7]), float(f[5]), int(f[8]) if len(f) > 8 else 0)
        else:
            D.append((int(f[1]), int(f[2]), float(f[3]), float(f[4]), float(f[5]), float(f[6]), float(f[7]), float(f[8])))
    worstN = int(sys.argv[3]) if len(sys.argv) > 3 else 15
    walk = sys.argv[4] if len(sys.argv) > 4 else None
    perr = np.array([v[2] - v[3] for v in P.values() if v[2] == v[2] and v[3] == v[3]])
    solved = sum(1 for v in P.values() if v[5] > 0)
    print("steps %d, of them with the dots' own way around something to the end of the leg: %d (%.1f%%)" % (len(P), solved, 100 * solved / max(1, len(P))))
    rows = []
    print("dots left out over no known ground: %d (%.2f%% of %d)" % (unsure, 100 * unsure / max(1, unsure + dots), unsure + dots))
    print("steps where a player could not walk the route line: %d (%.2f%%)" % (blocked, 100 * blocked / max(1, len(P))))
    for r, s, a, x, y, z, zt, zn in D:
        if (r, s) not in P:
            continue
        px, py, pz, pt, along, nlc = P[(r, s)]
        if zt != zt or pz != pz:
            continue
        rows.append((abs(z - zt), abs((z - zt) - (pz - pt)), r, s, a, x, y, z, zt, zn, pz, pt))
    A = np.array([(r[0], r[1]) for r in rows])

    def pct(v, name):
        qs = np.percentile(v, [50, 90, 99, 99.9]) if len(v) else [0] * 4
        print("%-34s n %7d | median %.2f  90%% %.2f  99%% %.2f  99.9%% %.2f  max %.2f | over 0.3 yd %.2f%%  0.5 %.2f%%  1 %.2f%%  3 %.2f%%" % (
            name, len(v), *qs, v.max() if len(v) else 0, *(100 * np.mean(v > t) if len(v) else 0 for t in (0.3, 0.5, 1, 3))))

    pct(np.abs(perr), "player height")
    pct(A[:, 0], "dot height")
    pct(A[:, 1], "dot height relative to the player")
    zn = np.array([r[9] for r in rows]); zd = np.array([r[7] for r in rows])
    off = np.where(zn == zn, np.abs(zd - zn), 99)
    pct(off, "dot off any surface (99: none near)")
    if walk:
        # why a dot is off: no ground in the walk grid near its height (the walk kept its height over a hole or a
        # slope too steep for the navmesh), or walk grid ground the real one is not under (past an edge)
        sys.path.insert(0, __file__.rsplit("/", 1)[0])
        from walkpack import PER, read_hgt2
        cells = read_hgt2(walk)

        def grid_fits(x, y, z):
            gx, gy = (x + 17100) / 2, (y + 17100) / 2
            for sy in (int(gy), int(gy) + 1):
                for sx in (int(gx), int(gx) + 1):
                    c = cells.get(sx // PER + (sy // PER) * 1024)
                    if c is None:
                        continue
                    n, h = c
                    idx = (sy % PER) * PER + sx % PER
                    st = int(n[:idx].astype(np.int64).sum())
                    if any(abs(float(v) - z) < 2 for v in h[st:st + int(n[idx])]):
                        return True
            return False
        kinds = defaultdict(int)
        big = [(o, r) for o, r in zip(off, rows) if o > 1]
        for o, r in big:
            kinds[("no walk grid ground" if not grid_fits(r[5], r[6], r[7]) else "walk grid ground, none real") + (" (over 3 yd)" if o > 3 else "")] += 1
        print("\ndots off any surface by more than a yard, by cause (share of all dots):")
        for k, v in sorted(kinds.items()):
            print("  %-45s %7d  %.2f%%" % (k, v, 100 * v / len(rows)))
    by = defaultdict(list)
    for r in rows:
        by[r[2]].append(r[1])
    print("\nroutes by share of dots off by more than half a yard (relative):")
    ranked = sorted(by.items(), key=lambda kv: -np.mean(np.array(kv[1]) > 0.5))
    for rid, v in ranked[:12]:
        v = np.array(v)
        print("  %4d %-55s dots %5d  over 0.5 yd %5.1f%%  worst %.1f" % (rid, names.get(rid, "?")[:55], len(v), 100 * np.mean(v > 0.5), v.max()))
    print("\nplaces with the most dots off any surface by more than a yard (16-yard squares): count, median off | where | route")
    places = defaultdict(list)
    for r, o in zip(rows, off):
        if o > 1:
            places[(inst.get(r[2], -1), round(r[5] / 16), round(r[6] / 16))].append((o, r))
    for key, v in sorted(places.items(), key=lambda kv: -len(kv[1]))[:worstN]:
        o = np.array([e[0] for e in v])
        r = v[len(v) // 2][1]
        print("  %6d  %6.1f | %d %9.2f %9.2f  z %7.2f near %7.2f | %s" % (len(v), np.median(o), key[0], r[5], r[6], r[7], r[9], names.get(r[2], "?")[:40]))
    print("\nworst dots (relative error): route step along | dot x y | addon z, true z, nearest ground to addon z | player addon, true")
    seen = set()
    for r in sorted(rows, key=lambda r: -r[1]):
        key = (r[2], round(r[5] / 8), round(r[6] / 8))
        if key in seen:
            continue
        seen.add(key)
        print("  %4d %4d %5.1f | %9.2f %9.2f | %7.2f %7.2f %7.2f | %7.2f %7.2f  %s" % (r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10], r[11], names.get(r[2], "?")[:40]))
        if len(seen) >= worstN:
            break


if __name__ == "__main__":
    main()
