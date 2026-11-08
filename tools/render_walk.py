"""Top-down picture of the walk grid around a route: each grid point on the layer nearest the route's height at its
nearest point, shaded by height, dark blue where the only ground is on another level, black where there is none; the route in white
with its corners, optional extra polylines in other colours.

usage: render_walk.py <name.hgt2> <out.png> <route: x,y,z;x,y,z;...> [--extra x,y;x,y;...]... [--pad yards]
(HereBeDragons coordinates: x = world Y, y = world X; north is up, west is left)
"""
import sys

import numpy as np
from PIL import Image, ImageDraw

from walkpack import PER, read_hgt2

OFF, WS = 17100, 2
SCALE = 6  # pixels per grid point


def parse(s):
    return [tuple(float(v) for v in p.split(",")) for p in s.split(";") if p]


def main():
    args = sys.argv[1:]
    extras, pad = [], 24.0
    while "--extra" in args:
        i = args.index("--extra")
        extras.append(parse(args[i + 1]))
        del args[i:i + 2]
    if "--pad" in args:
        i = args.index("--pad")
        pad = float(args[i + 1])
        del args[i:i + 2]
    cells = read_hgt2(args[0])
    route = parse(args[2])
    xs = [p[0] for p in route] + [p[0] for e in extras for p in e]
    ys = [p[1] for p in route] + [p[1] for e in extras for p in e]
    x0, x1 = min(xs) - pad, max(xs) + pad
    y0, y1 = min(ys) - pad, max(ys) + pad
    sx0, sx1 = int((x0 + OFF) // WS), int((x1 + OFF) // WS) + 1
    sy0, sy1 = int((y0 + OFF) // WS), int((y1 + OFF) // WS) + 1
    W, H = sx1 - sx0 + 1, sy1 - sy0 + 1
    # reference height per point: the nearest route corner's height (piecewise along the route)
    rz = np.array([p[2] for p in route])
    rx = np.array([p[0] for p in route])
    ry = np.array([p[1] for p in route])
    ax, ay, az = rx[:-1], ry[:-1], rz[:-1]
    bx, by, bz = rx[1:], ry[1:], rz[1:]

    def ref_at(x, y):
        """the route's height at its point nearest (x, y)"""
        dx, dy = bx - ax, by - ay
        L2 = np.maximum(dx * dx + dy * dy, 1e-9)
        t = np.clip(((x - ax) * dx + (y - ay) * dy) / L2, 0, 1)
        d2 = (ax + dx * t - x) ** 2 + (ay + dy * t - y) ** 2
        k = int(np.argmin(d2))
        return az[k] + (bz[k] - az[k]) * t[k]
    img = np.zeros((H, W, 3), np.uint8)
    zmin, zmax = rz.min() - 5, rz.max() + 5
    for sy in range(sy0, sy1 + 1):
        for sx in range(sx0, sx1 + 1):
            key = sx // PER + (sy // PER) * 1024
            if key not in cells:
                continue
            n, h = cells[key]
            idx = (sy % PER) * PER + sx % PER
            c = int(n[idx])
            if not c:
                continue
            st = int(np.sum(n[:idx].astype(np.int64)))
            layers = h[st:st + c]
            x, y = sx * WS - OFF, sy * WS - OFF
            ref = ref_at(x, y)
            z = layers[np.argmin(np.abs(layers - ref))]
            if abs(z - ref) > 12:
                img[sy1 - sy, sx1 - sx] = (40, 40, 70)  # ground only on another level
                continue
            t = (z - zmin) / max(1, zmax - zmin)
            img[sy1 - sy, sx1 - sx] = (int(60 + 160 * t), int(120 + 100 * (1 - abs(t - 0.5) * 2)), int(220 - 160 * t))
    im = Image.fromarray(img).resize((W * SCALE, H * SCALE), Image.NEAREST)
    d = ImageDraw.Draw(im)

    def px(p):  # x is west-positive: west on the left means larger x to the left
        return ((sx1 - (p[0] + OFF) / WS) * SCALE + SCALE / 2, (sy1 - (p[1] + OFF) / WS) * SCALE + SCALE / 2)
    for col, line in zip([(255, 80, 80), (80, 255, 255), (255, 255, 0)], extras):
        d.line([px(p) for p in line], fill=col, width=3)
    d.line([px(p) for p in route], fill=(255, 255, 255), width=2)
    for p in route:
        cx, cy = px(p)
        d.ellipse([cx - 4, cy - 4, cx + 4, cy + 4], outline=(255, 255, 255))
        d.text((cx + 6, cy - 6), "%.0f" % p[2], fill=(255, 255, 255))
    im.save(args[1])
    print("%s: %d x %d px, heights %.0f-%.0f" % (args[1], im.width, im.height, zmin, zmax))


if __name__ == "__main__":
    main()
