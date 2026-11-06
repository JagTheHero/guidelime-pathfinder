"""Write test points for tests/test_ground.lua: grid points of the height map with every layer, straight from
navbuild's .hgt (before packing), around random path nodes.

usage: ground_points.py <out.tsv> <name>:<instance> ...   (reads data/graph/<name>.hgt and .graph)
"""
import random
import sys

from graphio import read_graph
from hgtio import PER, grid, read_hgt

HS, OFF = 8, 17100


def main():
    out = open(sys.argv[1], "w")
    out.write("# instance\tx\ty\tlayers... (HereBeDragons coords, grid points of the 8-yard height map)\n")
    rnd = random.Random(7)
    for arg in sys.argv[2:]:
        name, instance = arg.split(":")
        g = grid(read_hgt("data/graph/%s.hgt" % name))
        nodes, _ = read_graph("data/graph/%s.graph" % name)
        picked = 0
        while picked < 1500:
            nd = nodes[rnd.randrange(len(nodes))]
            hx, hy = float(nd["y"]), float(nd["x"])  # HBD x = world Y, y = world X
            sx, sy = int((hx + OFF) // HS), int((hy + OFF) // HS)
            hs = g.get((sx, sy))
            if not hs:
                continue
            out.write("%s\t%d\t%d\t%s\n" % (instance, sx * HS - OFF, sy * HS - OFF, "\t".join("%.3f" % h for h in hs)))
            picked += 1
    out.close()


if __name__ == "__main__":
    main()
