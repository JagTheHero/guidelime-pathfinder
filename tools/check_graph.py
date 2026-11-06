"""Draw a path graph over the minimaps of a block of ADT tiles: largest component green, others red, swim edges blue.

usage: check_graph.py <map 0|1> <col0> <row0> <cols> <rows> <graph> <out.png> [tile px]
"""
import struct, sys
import numpy as np
from PIL import Image, ImageDraw
from casc import Casc
from chunks import chunk_map
from graphio import read_graph, components
import wowgeo, blp

WDT = {0: 775971, 1: 782779}


def main():
    mapid, col0, row0, cols, rows = map(int, sys.argv[1:6])
    graph, out = sys.argv[6], sys.argv[7]
    S = int(sys.argv[8]) if len(sys.argv) > 8 else 768
    c = Casc()
    d = c.read_fdid(WDT[mapid])
    off, _ = chunk_map(d)['MAID']
    ids = struct.unpack_from('<%dI' % (4096 * 8), d, off)
    img = Image.new('RGBA', (cols * S, rows * S), (0, 0, 0, 255))
    for r in range(rows):
        for q in range(cols):
            fd = ids[((row0 + r) * 64 + col0 + q) * 8:((row0 + r) * 64 + col0 + q) * 8 + 8]
            if fd[7]:
                tile = Image.fromarray(blp.decode(c.read_fdid(fd[7]))[:, :, :3]).resize((S, S)).convert('RGBA')
                img.paste(tile, (q * S, r * S))
    T = wowgeo.TILE
    X0, Y0 = (32 - row0) * T, (32 - col0) * T

    def px(x, y):  # world X north, Y west
        return (Y0 - y) / T * S, (X0 - x) / T * S

    nodes, edges = read_graph(graph)
    comp = components(len(nodes), edges)
    uc, cc = np.unique(comp, return_counts=True)
    main_c = uc[np.argmax(cc)]
    ov = Image.new('RGBA', img.size, (0, 0, 0, 0))
    dr = ImageDraw.Draw(ov)
    for e in edges:
        a, b = nodes[e['a']], nodes[e['b']]
        col = (60, 140, 255, 220) if e['flags'] & 1 else ((80, 255, 80, 200) if comp[e['a']] == main_c else (255, 60, 60, 220))
        dr.line([px(a['x'], a['y']), px(b['x'], b['y'])], fill=col, width=1)
    for i, n in enumerate(nodes):
        x, y = px(n['x'], n['y'])
        col = (255, 150, 0, 255) if n['area'] == 3 else ((255, 255, 255, 230) if comp[i] == main_c else (255, 60, 60, 255))
        dr.ellipse([x - 1.5, y - 1.5, x + 1.5, y + 1.5], fill=col)
    Image.alpha_composite(img, ov).convert('RGB').save(out)
    print('nodes', len(nodes), 'edges', len(edges), 'components', len(uc), 'main', cc.max())


if __name__ == '__main__':
    main()
