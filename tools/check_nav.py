"""Draw navmesh polygons (green walk, blue swim, orange indoor) over the minimap of one ADT tile."""
import struct, sys
import numpy as np
from PIL import Image, ImageDraw
from casc import Casc
from chunks import chunk_map
import wowgeo, blp

WDT = {0: 775971, 1: 782779}
COLORS = {1: (60, 255, 60, 70), 2: (40, 120, 255, 90), 3: (255, 150, 0, 90)}

def polys(navfile):
    data = open(navfile, 'rb').read()
    n = struct.unpack_from('<I', data, 0)[0]
    p = 4
    out = []
    for _ in range(n):
        tx, ty, size = struct.unpack_from('<3i', data, p)
        blob = data[p + 12:p + 12 + size]
        p += 12 + size
        h = struct.unpack_from('<15i', blob, 0)
        poly_count, vert_count = h[6], h[7]
        verts = np.frombuffer(blob, '<f4', vert_count * 3, 100).reshape(-1, 3)
        po = 100 + vert_count * 12
        for i in range(poly_count):
            rec = blob[po + i * 32: po + i * 32 + 32]
            vi = struct.unpack_from('<6H', rec, 4)
            nv, at = rec[30], rec[31]
            area = at & 0x3f
            out.append((verts[list(vi[:nv])], area))
    return out

def render(mapid, col, row, navfile, out, S=1024):
    c = Casc()
    d = c.read_fdid(WDT[mapid])
    off, _ = chunk_map(d)['MAID']
    ids = struct.unpack_from('<%dI' % (4096 * 8), d, off)
    fd = ids[(row * 64 + col) * 8:(row * 64 + col) * 8 + 8]
    img = Image.fromarray(blp.decode(c.read_fdid(fd[7]))[:, :, :3]).resize((S, S)).convert('RGBA')
    T = wowgeo.TILE
    X0, Y0 = (32 - row) * T, (32 - col) * T
    ov = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    dr = ImageDraw.Draw(ov)
    for v, area in polys(navfile):
        # recast x = world Y, z = world X
        pts = [((Y0 - p[0]) / T * S, (X0 - p[2]) / T * S) for p in v]
        dr.polygon(pts, fill=COLORS.get(area, (255, 0, 0, 90)), outline=(0, 0, 0, 60))
    Image.alpha_composite(img, ov).save(out)

if __name__ == '__main__':
    render(int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5])
