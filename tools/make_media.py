"""Writes the addon's small TGA textures (soft ground dot)."""
import math, struct, sys

def tga(path, w, h, pixels):
    # uncompressed 32-bit BGRA, top-left origin
    hdr = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 0x28)
    with open(path, "wb") as f:
        f.write(hdr)
        for r, g, b, a in pixels:
            f.write(bytes((b, g, r, a)))

def dot(n=64):
    px = []
    c = (n - 1) / 2
    for y in range(n):
        for x in range(n):
            d = math.hypot(x - c, y - c) / (n / 2)
            core = max(0.0, 1 - d) ** 0.6
            rim = math.exp(-((d - 0.78) / 0.09) ** 2)
            a = min(1.0, core * 0.55 + rim * 0.9) if d < 1 else 0.0
            px.append((255, 255, 255, int(a * 255)))
    return px

out = sys.argv[1]
tga(out + "/dot.tga", 64, 64, dot())
