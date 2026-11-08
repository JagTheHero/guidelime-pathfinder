"""Write test points for tests/test_ground.lua: points of the walk grid with every layer, straight from navbuild's
.hgt2 (before packing), around random graph nodes.

usage: ground_points.py <out.tsv> <name>:<instance> ...   (reads build/wg/<name>.hgt2 and data/graph/<name>.graph)
"""
import random
import sys

import numpy as np

from graphio import read_graph
from walkpack import PER, read_hgt2

OFF, WS = 17100, 2


def main():
    out = open(sys.argv[1], "w")
    out.write("# instance\tx\ty\tlayers... (HereBeDragons coords, points of the 2-yard walk grid)\n")
    rnd = random.Random(7)
    for arg in sys.argv[2:]:
        name, instance = arg.split(":")
        cells = read_hgt2("build/wg/%s.hgt2" % name)
        nodes, _ = read_graph("data/graph/%s.graph" % name)
        picked = 0
        while picked < 2000:
            nd = nodes[rnd.randrange(len(nodes))]
            hx, hy = float(nd["y"]) + rnd.uniform(-20, 20), float(nd["x"]) + rnd.uniform(-20, 20)  # HBD x = world Y
            sx, sy = int((hx + OFF) // WS), int((hy + OFF) // WS)
            key = sx // PER + (sy // PER) * 1024
            if key not in cells:
                continue
            n, h = cells[key]
            idx = (sy % PER) * PER + sx % PER
            start = int(np.sum(n[:idx].astype(np.int64)))
            layers = h[start:start + int(n[idx])]
            if not len(layers):
                continue
            out.write("%s\t%d\t%d\t%s\n" % (instance, sx * WS - OFF, sy * WS - OFF, "\t".join("%.3f" % v for v in layers)))
            picked += 1
    out.close()


if __name__ == "__main__":
    main()
