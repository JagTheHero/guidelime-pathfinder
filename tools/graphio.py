"""Read navbuild's .graph output."""
import struct
import numpy as np


def read_graph(path):
    d = open(path, 'rb').read()
    assert d[:4] == b'GRF1'
    nn, ne = struct.unpack_from('<II', d, 4)
    p = 12
    nodes = np.frombuffer(d, np.dtype([('x', '<f4'), ('y', '<f4'), ('z', '<f4'), ('area', 'u1')]), nn, p)
    p += nn * 13
    edges = np.frombuffer(d, np.dtype([('a', '<i4'), ('b', '<i4'), ('flags', 'u1')]), ne, p)
    return nodes, edges


def components(n, edges):
    parent = np.arange(n)
    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    for a, b in zip(edges['a'], edges['b']):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb
    return np.array([find(i) for i in range(n)])
