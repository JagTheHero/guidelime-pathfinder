"""Route endpoints for tools/simdots.lua: random walks on each continent, half of them in hard places (indoors,
stacked floors, bridges), plus fixed routes through cities and down to dungeon entrances.

usage: simroutes.py <out.txt> <count per continent> [seed]
Lines: instance sx sy tx ty sz name (sz: the start's height, nan for the fixed ones) (HereBeDragons coords: x = world Y, y = world X).
"""
import random
import sys

import numpy as np

from graphio import read_graph

MAPS = {0: "Azeroth", 1: "Kalimdor"}
MIN_D, MAX_D = 120, 700

# (instance, from HBD x, y, to HBD x, y, name): world points from the game (HBD x = world Y, y = world X)
FIXED = [
    (0, -857, -5018, -932.0, -4821.6, "Ironforge gates to the Hall of Thanes"),  # entrance at Ironforge 27.6, 47.8
    (0, -1166.4, -4808.5, -932.0, -4821.6, "Ironforge Great Forge to the Hall of Thanes"),
    (0, -1166.4, -4808.5, -857, -5018, "Ironforge Great Forge to the gates"),
    (0, 536.7, -8859.8, 478.5, -8834.25, "Stormwind Trade District through the probe room"),
    (0, 536.7, -8859.8, 819, -8494, "Stormwind Trade District to the Cathedral"),
    (0, -2776.6, -5649.6, -2784, -6049.5, "Loch Modan road south of Thelsamar"),
    (0, 240, 1596, 393.5, 1429.8, "Undercity Trade Quarter to the Apothecarium"),
    (0, -133, -8914, 62, -9465, "Northshire Abbey to Goldshire"),
    (1, -4410, 1525.6, -4522, 1759, "Orgrimmar Valley of Strength to the Drag"),
    (1, 47, -1232.7, -266, -1058.7, "Thunder Bluff to the Elder Rise"),
    (1, 2303, 9956, 2515, 9673.7, "Darnassus to the Temple of the Moon"),
]


def main():
    out = open(sys.argv[1], "w")
    count = int(sys.argv[2])
    rnd = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 11)
    for inst, name in MAPS.items():
        nodes, _ = read_graph("data/graph/%s.graph" % name)
        hx, hy, z = nodes["y"].astype(float), nodes["x"].astype(float), nodes["z"].astype(float)
        indoor = nodes["area"] & 0x7F == 3
        # stacked: another node within 12 yd across and 4+ yd above or below
        key = np.floor(hx / 12) * 100000 + np.floor(hy / 12)
        stacked = np.zeros(len(nodes), bool)
        cells = {}
        for i, k in enumerate(key):
            cells.setdefault(k, []).append(i)
        for ids in cells.values():
            if len(ids) > 1:
                zs = z[ids]
                if zs.max() - zs.min() > 4:
                    stacked[ids] = True
        hard = np.nonzero(indoor | stacked)[0]
        print("%s: %d nodes, %d indoors or stacked" % (name, len(nodes), len(hard)))
        made = 0
        while made < count:
            a = int(rnd.choice(hard)) if made % 2 == 0 and len(hard) else rnd.randrange(len(nodes))
            d = rnd.uniform(MIN_D, MAX_D)
            ang = rnd.uniform(0, 2 * np.pi)
            tx, ty = hx[a] + d * np.sin(ang), hy[a] + d * np.cos(ang)
            near = np.nonzero((np.abs(hx - tx) < 30) & (np.abs(hy - ty) < 30))[0]
            if not len(near):
                continue
            b = int(rnd.choice(near))
            out.write("%d %.2f %.2f %.2f %.2f %.2f random%s\n" % (inst, hx[a], hy[a], hx[b], hy[b], z[a], "-hard" if made % 2 == 0 else ""))
            made += 1
    for f in FIXED:
        out.write("%d %.2f %.2f %.2f %.2f nan %s\n" % f)
    out.close()


if __name__ == "__main__":
    main()
