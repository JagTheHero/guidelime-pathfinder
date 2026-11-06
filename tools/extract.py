"""Pass 1: write every ADT tile's collision geometry to data/geo/<map>/<col>_<row>.geo.

.geo layout (little endian): b"GEO1", nv u32, nt u32, verts f32[nv*3] (world X north, Y west, Z up),
tris i32[nt*3], area u8[nt] (0 obstacle, 1 ground, 2 swim, 3 indoor ground), key i64[nt] (-1 terrain,
else a placement key so objects referenced by several tiles can be de-duplicated).
"""
import json
import multiprocessing as mp
import os
import struct
import sys
import time

import numpy as np

from casc import Casc
from chunks import chunk_map
import wowgeo

MAPS = {"Azeroth": 775971, "Kalimdor": 782779}
OUT = os.path.join(os.path.dirname(__file__), "..", "data", "geo")
AREA_INDOOR = 3

_casc = None
_models = None


def tiles_of(casc, wdt):
    d = casc.read_fdid(wdt)
    off, _ = chunk_map(d)["MAID"]
    ids = struct.unpack_from("<%dI" % (4096 * 8), d, off)
    out = []
    for i in range(4096):
        fd = ids[i * 8:i * 8 + 8]
        if fd[0]:
            out.append((i % 64, i // 64, fd[0], fd[1]))
    return out


def work(job):
    global _casc, _models
    if _casc is None:
        _casc = Casc()
        _models = wowgeo.ModelCache(_casc)
        wowgeo.load_hazard_types(_casc)
    mapname, col, row, root_id, obj_id = job
    path = os.path.join(OUT, mapname, "%d_%d.geo" % (col, row))
    if os.path.exists(path):
        return mapname, col, row, "skip", {}
    liquid_types = {}
    ter = wowgeo.terrain(_casc, root_id, liquid_types)
    m2s, wmos = wowgeo.placements(_casc, obj_id)
    obj = wowgeo.object_meshes(_models, m2s, wmos)
    V, T, A, K = [], [], [], []
    base = 0
    if ter is not None:
        v, t, a = ter
        V.append(v); T.append(t); A.append(a); K.append(np.full(len(t), -1, np.int64))
        base = len(v)
    if obj is not None:
        v, t, a, indoor, key = obj
        a = np.where(indoor == 1, AREA_INDOOR, a).astype(np.uint8)
        V.append(v); T.append(t + base); A.append(a); K.append(key)
    if not V:
        return mapname, col, row, "empty", liquid_types
    V = np.concatenate(V).astype(np.float32)
    T = np.concatenate(T).astype(np.int32)
    A = np.concatenate(A).astype(np.uint8)
    K = np.concatenate(K).astype(np.int64)
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(b"GEO1" + struct.pack("<II", len(V), len(T)))
        f.write(V.tobytes()); f.write(T.tobytes()); f.write(A.tobytes()); f.write(K.tobytes())
    os.replace(tmp, path)
    return mapname, col, row, "%d tris" % len(T), liquid_types


def main():
    workers = int(sys.argv[1]) if len(sys.argv) > 1 else 8
    only = sys.argv[2:] or list(MAPS)
    casc = Casc()
    jobs = []
    for name in only:
        os.makedirs(os.path.join(OUT, name), exist_ok=True)
        # rows in order so each worker's model cache sees neighbouring tiles
        for col, row, root_id, obj_id in sorted(tiles_of(casc, MAPS[name]), key=lambda t: (t[1], t[0])):
            jobs.append((name, col, row, root_id, obj_id))
    del casc
    t0 = time.time()
    liquids = {}
    done = 0
    with mp.Pool(workers) as pool:
        for name, col, row, msg, lt in pool.imap_unordered(work, jobs, chunksize=4):
            done += 1
            for k, v in lt.items():
                liquids[k] = liquids.get(k, 0) + v
            if done % 50 == 0 or done == len(jobs):
                print("%d/%d tiles  %.0fs  last %s %d_%d %s" % (done, len(jobs), time.time() - t0, name, col, row, msg), flush=True)
    with open(os.path.join(OUT, "liquid_types.json"), "w") as f:
        json.dump(liquids, f, indent=1)
    print("done", time.time() - t0)


if __name__ == "__main__":
    main()
