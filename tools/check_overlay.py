"""Close-up of object collision (M2 yellow, WMO magenta) over the minimap, for checking placement."""
import struct, sys
from PIL import Image, ImageDraw
from casc import Casc
from chunks import chunk_map
import wowgeo, blp

WDT = {0: 775971, 1: 782779}

def render(mapid, cx, cy, half, out, S=900):
    c = Casc()
    d = c.read_fdid(WDT[mapid])
    off, _ = chunk_map(d)['MAID']
    ids = struct.unpack_from('<%dI' % (4096 * 8), d, off)
    T = wowgeo.TILE
    col, row = int(32 - cy / T), int(32 - cx / T)
    fd = ids[(row * 64 + col) * 8:(row * 64 + col) * 8 + 8]
    mm = blp.decode(c.read_fdid(fd[7]))
    X0, Y0 = (32 - row) * T, (32 - col) * T
    mpx = mm.shape[0] / T
    u0, v0 = (Y0 - (cy + half)) * mpx, (X0 - (cx + half)) * mpx
    crop = Image.fromarray(mm[:, :, :3]).crop((int(u0), int(v0), int(u0 + 2 * half * mpx), int(v0 + 2 * half * mpx))).resize((S, S), Image.BICUBIC)
    models = wowgeo.ModelCache(c)
    m2s, wmos = wowgeo.placements(c, fd[1])
    ov = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    dr = ImageDraw.Draw(ov)
    for lst_m2, lst_wmo, color in ((m2s, [], (255, 255, 0, 140)), ([], wmos, (255, 0, 255, 45))):
        obj = wowgeo.object_meshes(models, lst_m2, lst_wmo)
        if obj is None:
            continue
        V, Tr = obj[0], obj[1]
        u = (cy + half - V[:, 1]) / (2 * half) * S
        v = (cx + half - V[:, 0]) / (2 * half) * S
        for t in Tr:
            pts = [(u[k], v[k]) for k in t]
            if max(p[0] for p in pts) < 0 or min(p[0] for p in pts) > S or max(p[1] for p in pts) < 0 or min(p[1] for p in pts) > S:
                continue
            dr.polygon(pts, fill=color)
    side = Image.new('RGB', (2 * S, S))
    side.paste(crop, (0, 0))
    side.paste(Image.alpha_composite(crop.convert('RGBA'), ov).convert('RGB'), (S, 0))
    side.save(out)

if __name__ == '__main__':
    m, x, y, h = int(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
    render(m, x, y, h, sys.argv[5])
