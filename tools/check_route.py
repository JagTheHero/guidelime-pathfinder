"""Draw routes dumped by tests/test_graph.lua (PATH_DUMP=file) over the minimap, one PNG per route.

usage: check_route.py <dump> <out_dir>
"""
import math, os, struct, sys
from PIL import Image, ImageDraw
from casc import Casc
from chunks import chunk_map
import wowgeo, blp

WDT = {0: 775971, 1: 782779}
PX = 384  # pixels per ADT tile


def main():
    dump, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)
    c = Casc()
    maid = {}
    T = wowgeo.TILE
    for line in open(dump):
        f = line.rstrip("\n").split("\t")
        name, inst = f[0], int(f[1])
        pts = [tuple(map(float, p.split(","))) for p in f[2:]]  # HBD x = world Y, y = world X
        if inst not in maid:
            d = c.read_fdid(WDT[inst])
            off, _ = chunk_map(d)["MAID"]
            maid[inst] = struct.unpack_from("<%dI" % (4096 * 8), d, off)
        ids = maid[inst]
        # ADT col from world Y, row from world X
        cols = [32 - x / T for x, _ in pts]
        rows = [32 - y / T for _, y in pts]
        c0, c1 = int(math.floor(min(cols) - 0.15)), int(math.floor(max(cols) + 0.15))
        r0, r1 = int(math.floor(min(rows) - 0.15)), int(math.floor(max(rows) + 0.15))
        img = Image.new("RGB", ((c1 - c0 + 1) * PX, (r1 - r0 + 1) * PX))
        for r in range(r0, r1 + 1):
            for q in range(c0, c1 + 1):
                fd = ids[(r * 64 + q) * 8 + 7]
                if fd:
                    tile = Image.fromarray(blp.decode(c.read_fdid(fd))[:, :, :3]).resize((PX, PX))
                    img.paste(tile, ((q - c0) * PX, (r - r0) * PX))
        dr = ImageDraw.Draw(img)
        xy = [((cc - c0) * PX, (rr - r0) * PX) for cc, rr in zip(cols, rows)]
        dr.line(xy, fill=(255, 40, 200), width=3)
        for p in xy:
            dr.ellipse([p[0] - 3, p[1] - 3, p[0] + 3, p[1] + 3], fill=(255, 255, 255))
        dr.line([xy[0], xy[-1]], fill=(255, 255, 0), width=1)
        fn = os.path.join(out_dir, "".join(ch if ch.isalnum() else "_" for ch in name)[:60] + ".png")
        img.save(fn)
        print(fn, img.size)


if __name__ == "__main__":
    main()
