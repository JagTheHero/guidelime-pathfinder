"""Close-up of navmesh, graph and routes around one point (HereBeDragons coordinates: x = world Y, y = world X).

usage: check_spot.py <nav_dir> <graph> <hbdX> <hbdY> <radius yd> <out.png> [routes.tsv] [zmin zmax]
Walkable navmesh is grey (indoor orange, swim blue), graph edges green, nodes white, routes pink.
"""
import math, os, sys
from PIL import Image, ImageDraw
import numpy as np
from check_nav import polys
from graphio import read_graph
import wowgeo

AREA = {1: (90, 90, 90), 2: (40, 70, 140), 3: (120, 80, 30)}


def main():
    nav_dir, graph, cx, cy, radius, out = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5]), sys.argv[6]
    routes = sys.argv[7] if len(sys.argv) > 7 and sys.argv[7] != "-" else None
    zmin, zmax = (float(sys.argv[8]), float(sys.argv[9])) if len(sys.argv) > 9 else (-1e9, 1e9)
    S = 1000 / (2 * radius)
    T = wowgeo.TILE
    img = Image.new("RGB", (1000, 1000), (15, 15, 20))
    dr = ImageDraw.Draw(img, "RGBA")

    def px(hx, hy):  # east is right: HBD x grows west
        return (cx - hx) * S + 500, (cy - hy) * S + 500

    col, row = int(math.floor(32 - cx / T)), int(math.floor(32 - cy / T))
    for dc in (-1, 0, 1):
        for dr_ in (-1, 0, 1):
            f = os.path.join(nav_dir, "%d_%d.nav" % (col + dc, row + dr_))
            if not os.path.exists(f):
                continue
            for v, area in polys(f):
                if not zmin <= v[:, 1].mean() <= zmax:
                    continue
                pts = [px(p[0], p[2]) for p in v]  # recast x = world Y = HBD x, z = world X = HBD y
                if all(abs(a - 500) > 600 or abs(b - 500) > 600 for a, b in pts):
                    continue
                dr.polygon(pts, fill=AREA.get(area, (150, 0, 0)), outline=(40, 40, 45))
    nodes, edges = read_graph(graph)
    hx, hy = nodes["y"], nodes["x"]
    near = (np.abs(hx - cx) < radius * 1.2) & (np.abs(hy - cy) < radius * 1.2) & (nodes["z"] >= zmin) & (nodes["z"] <= zmax)
    for e in edges:
        if near[e["a"]] and near[e["b"]]:
            dr.line([px(hx[e["a"]], hy[e["a"]]), px(hx[e["b"]], hy[e["b"]])], fill=(80, 255, 80, 200), width=2)
    for i in np.nonzero(near)[0]:
        x, y = px(hx[i], hy[i])
        dr.ellipse([x - 4, y - 4, x + 4, y + 4], fill=(255, 255, 255))
    if routes:
        for line in open(routes):
            f = line.rstrip("\n").split("\t")
            pts = [px(*map(float, p.split(","))) for p in f[2:]]
            dr.line(pts, fill=(255, 40, 200), width=3)
    dr.text((10, 10), "%.0f yd across, north up" % (2 * radius), fill=(255, 255, 255))
    img.save(out)


if __name__ == "__main__":
    main()
