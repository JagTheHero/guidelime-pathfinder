"""Collision geometry for one ADT tile of a WoW map, in game world coordinates (X north, Y west, Z up).

Terrain (with holes), liquids, WMO buildings (with their doodad sets) and M2 doodad collision meshes.
Per-triangle area: 0 = obstacle / unwalkable, 1 = solid ground (walkable if not too steep), 2 = swim surface.
"""
import math
import struct
from functools import lru_cache

import numpy as np

from chunks import chunk_map, iter_chunks

TILE = 1600.0 / 3.0
CHUNK = TILE / 16.0
UNIT = CHUNK / 8.0
MID = 32 * TILE

AREA_NULL, AREA_GROUND, AREA_SWIM = 0, 1, 2
SWIM_DEPTH = 1.4           # yards of water before the player swims instead of walking
HAZARD_WORDS = ("magma", "lava", "slime", "fel", "tar pit", "acid", "poison")
HAZARD_TYPES = set()       # LiquidType ids to avoid; filled by load_hazard_types()


def load_hazard_types(casc):
    """Liquid types that hurt or trap the player, from LiquidType.db2 names."""
    from db2 import WDC5
    table = WDC5(casc.read_fdid(1371380))
    for rid, rstart in table.records:
        if any(w in table.string_at(rstart, 0).lower() for w in HAZARD_WORDS):
            HAZARD_TYPES.add(rid)


# ------------------------------------------------------------------------------------- transforms
def placement_matrix(rot_deg, scale):
    """Model -> world rotation*scale for MDDF/MODF placements (TrinityCore's convention)."""
    rx, ry, rz = (math.radians(a) for a in rot_deg)
    # R = Rz(rot.y) * Ry(rot.x) * Rx(rot.z), then a 180 degree turn from TrinityCore's internal frame
    cz, sz = math.cos(ry), math.sin(ry)
    cy, sy = math.cos(rx), math.sin(rx)
    cx, sx = math.cos(rz), math.sin(rz)
    Rz = np.array([[cz, -sz, 0], [sz, cz, 0], [0, 0, 1]])
    Ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    Rx = np.array([[1, 0, 0], [0, cx, -sx], [0, sx, cx]])
    D = np.diag([-1.0, -1.0, 1.0])
    return D @ Rz @ Ry @ Rx * scale


def placement_pos(pos):
    return np.array([MID - pos[2], MID - pos[0], pos[1]])


def quat_matrix(x, y, z, w):
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])


# --------------------------------------------------------------------------------------------- M2
class ModelCache:
    def __init__(self, casc):
        self.casc = casc
        self.m2 = {}
        self.wmo = {}
        self.missing = set()

    def m2_collision(self, fdid):
        """(verts Nx3 float, tris Mx3 int) of an M2's collision mesh, or None."""
        if fdid in self.m2:
            return self.m2[fdid]
        res = None
        data = self.casc.read_fdid(fdid)
        if data:
            md20 = None
            if data[:4] == b"MD20":
                md20 = data
            else:
                # M2 chunk tags are stored in reading order, unlike ADT/WMO chunks
                pos = 0
                while pos + 8 <= len(data):
                    tag, size = data[pos:pos + 4], struct.unpack_from("<I", data, pos + 4)[0]
                    if tag == b"MD21":
                        md20 = data[pos + 8:pos + 8 + size]
                        break
                    pos += 8 + size
            if md20 and md20[:4] == b"MD20":
                ni, oi = struct.unpack_from("<II", md20, 0xD8)
                nv, ov = struct.unpack_from("<II", md20, 0xE0)
                if ni >= 3 and nv >= 3 and oi + 2 * ni <= len(md20) and ov + 12 * nv <= len(md20):
                    idx = np.frombuffer(md20, "<u2", ni, oi).astype(np.int32)
                    v = np.frombuffer(md20, "<f4", nv * 3, ov).reshape(-1, 3).astype(np.float64)
                    idx = idx[: len(idx) // 3 * 3].reshape(-1, 3)
                    if idx.max() < nv:
                        res = (v, idx)
        else:
            self.missing.add(fdid)
        self.m2[fdid] = res
        return res

    def wmo_root(self, fdid):
        if fdid in self.wmo:
            return self.wmo[fdid]
        res = None
        data = self.casc.read_fdid(fdid)
        if data:
            res = self._parse_wmo(data)
        else:
            self.missing.add(fdid)
        self.wmo[fdid] = res
        return res

    def _parse_wmo(self, data):
        cm = chunk_map(data)
        off, _ = cm["MOHD"]
        n_groups = struct.unpack_from("<I", data, off + 4)[0]
        group_ids = []
        if "GFID" in cm:
            o, s = cm["GFID"]
            group_ids = list(struct.unpack_from("<%dI" % (s // 4), data, o))[:n_groups]
        group_flags = []
        if "MOGI" in cm:
            o, s = cm["MOGI"]
            for i in range(s // 32):
                group_flags.append(struct.unpack_from("<I", data, o + i * 32)[0])
        sets = []
        if "MODS" in cm:
            o, s = cm["MODS"]
            for i in range(s // 32):
                start, count = struct.unpack_from("<II", data, o + i * 32 + 20)
                sets.append((start, count))
        modi = []
        if "MODI" in cm:
            o, s = cm["MODI"]
            modi = list(struct.unpack_from("<%dI" % (s // 4), data, o))
        modd = []
        if "MODD" in cm:
            o, s = cm["MODD"]
            for i in range(s // 40):
                name_flags, px, py, pz, qx, qy, qz, qw, sc = struct.unpack_from("<I3f4ff", data, o + i * 40)
                modd.append((name_flags & 0xFFFFFF, (px, py, pz), (qx, qy, qz, qw), sc))
        # collision of all groups merged into one mesh (model space)
        verts, tris, indoor = [], [], []
        base = 0
        for gi, gid in enumerate(group_ids):
            if not gid:
                continue
            g = self.casc.read_fdid(gid)
            if not g:
                self.missing.add(gid)
                continue
            gv, gt = self._parse_group(g)
            if gv is None or len(gt) == 0:
                continue
            gflags = group_flags[gi] if gi < len(group_flags) else 0
            verts.append(gv)
            tris.append(gt + base)
            indoor.append(np.full(len(gt), 1 if gflags & 0x2000 else 0, np.uint8))
            base += len(gv)
        mesh = None
        if verts:
            mesh = (np.concatenate(verts), np.concatenate(tris), np.concatenate(indoor))
        return {"mesh": mesh, "sets": sets, "modi": modi, "modd": modd}

    @staticmethod
    def _parse_group(g):
        cm = chunk_map(g)
        if "MOGP" not in cm:
            return None, None
        off, size = cm["MOGP"]
        sub = chunk_map(g, off + 0x44, off + size)
        if "MOVT" not in sub:
            return None, None
        o, s = sub["MOVT"]
        v = np.frombuffer(g, "<f4", s // 4, o).reshape(-1, 3).astype(np.float64)
        if "MOVI" in sub:
            o, s = sub["MOVI"]
            idx = np.frombuffer(g, "<u2", s // 2, o).astype(np.int32)
        elif "MOVX" in sub:
            o, s = sub["MOVX"]
            idx = np.frombuffer(g, "<u4", s // 4, o).astype(np.int32)
        else:
            return None, None
        idx = idx[: len(idx) // 3 * 3].reshape(-1, 3)
        if "MOPY" in sub:
            o, s = sub["MOPY"]
            mopy = np.frombuffer(g, np.uint8, s, o).reshape(-1, 2)
            flags, mat = mopy[:, 0].astype(np.int32), mopy[:, 1].astype(np.int32)
        elif "MPY2" in sub:
            o, s = sub["MPY2"]
            mopy = np.frombuffer(g, "<u2", s // 2, o).reshape(-1, 2)
            flags, mat = mopy[:, 0].astype(np.int32), mopy[:, 1].astype(np.int32)
        else:
            flags = np.full(len(idx), 0x08, np.int32)
            mat = np.zeros(len(idx), np.int32)
        n = min(len(idx), len(flags))
        idx, flags, mat = idx[:n], flags[:n], mat[:n]
        render = ((flags & 0x20) != 0) & ((flags & 0x04) == 0)
        collide = ((flags & 0x08) != 0) | render
        keep = collide & (idx.max(axis=1) < len(v))
        return v, idx[keep]


# --------------------------------------------------------------------------------------- terrain
def _chunk_grid():
    """Index arrays into the 145-entry MCVT for outer (9x9) and inner (8x8) vertices."""
    outer = np.array([[i * 17 + j for j in range(9)] for i in range(9)])
    inner = np.array([[i * 17 + 9 + j for j in range(8)] for i in range(8)])
    return outer, inner


OUTER_IDX, INNER_IDX = _chunk_grid()


def _quad_tris():
    """Per quad (i, j): 4 triangles over local vertex ids (outer: i*9+j, inner: 81 + i*8+j), up-facing."""
    tris = []
    for i in range(8):
        for j in range(8):
            o00, o01, o10, o11 = i * 9 + j, i * 9 + j + 1, (i + 1) * 9 + j, (i + 1) * 9 + j + 1
            c = 81 + i * 8 + j
            tris.append([(o00, c, o01), (o01, c, o11), (o11, c, o10), (o10, c, o00)])
    return np.array(tris, np.int32).reshape(64, 4, 3)


QUAD_TRIS = _quad_tris()


def _liquids(root, cm):
    """Per chunk index (iy*16+ix): list of (type, heights 9x9 or None, exists 8x8 bool)."""
    out = {}
    if "MH2O" not in cm:
        return out
    base, size = cm["MH2O"]
    for ci in range(256):
        ofs_inst, n_layers, _ = struct.unpack_from("<III", root, base + ci * 12)
        layers = []
        for li in range(n_layers):
            p = base + ofs_inst + li * 24
            ltype, lvf, hmin, hmax, xo, yo, w, h, ofs_exist, ofs_vert = struct.unpack_from("<HHffBBBBII", root, p)
            if w == 0 or h == 0:
                continue
            exists = np.zeros((8, 8), bool)
            if ofs_exist:
                nbytes = (w * h + 7) // 8
                bits = np.unpackbits(np.frombuffer(root, np.uint8, nbytes, base + ofs_exist), bitorder="little")[: w * h]
                exists[yo:yo + h, xo:xo + w] = bits.reshape(h, w).astype(bool)
            else:
                exists[yo:yo + h, xo:xo + w] = True
            heights = np.full((9, 9), hmin, np.float64)
            if ofs_vert and hmax != hmin and lvf != 2:
                hv = np.frombuffer(root, "<f4", (w + 1) * (h + 1), base + ofs_vert).reshape(h + 1, w + 1)
                heights[yo:yo + h + 1, xo:xo + w + 1] = hv
            layers.append((ltype, heights, exists))
        if layers:
            out[ci] = layers
    return out


def terrain(casc, root_fdid, liquid_types=None):
    """Terrain + liquid triangles of a root ADT. Returns verts (N,3), tris (M,3), area (M,)."""
    root = casc.read_fdid(root_fdid)
    if not root:
        return None
    cm = chunk_map(root)
    liquids = _liquids(root, cm)
    V, T, A = [], [], []
    base = 0
    ci = 0
    for cid, off, size in iter_chunks(root):
        if cid != "MCNK":
            continue
        flags, ix, iy = struct.unpack_from("<III", root, off)
        holes_hi = struct.unpack_from("<Q", root, off + 0x14)[0] if flags & 0x10000 else None
        holes_lo = struct.unpack_from("<H", root, off + 0x3C)[0]
        px, py, pz = struct.unpack_from("<3f", root, off + 0x68)
        sub = chunk_map(root, off + 0x80, off + size)
        if "MCVT" not in sub:
            ci += 1
            continue
        o, _ = sub["MCVT"]
        hts = np.frombuffer(root, "<f4", 145, o).astype(np.float64)
        ii, jj = np.meshgrid(np.arange(9), np.arange(9), indexing="ij")
        outer = np.stack([px - ii * UNIT, py - jj * UNIT, pz + hts[OUTER_IDX]], -1).reshape(-1, 3)
        ii, jj = np.meshgrid(np.arange(8), np.arange(8), indexing="ij")
        inner = np.stack([px - (ii + 0.5) * UNIT, py - (jj + 0.5) * UNIT, pz + hts[INNER_IDX]], -1).reshape(-1, 3)
        verts = np.concatenate([outer, inner])

        # holes
        hole = np.zeros((8, 8), bool)
        if holes_hi is not None:
            for r in range(8):
                byte = (holes_hi >> (r * 8)) & 0xFF
                for c in range(8):
                    hole[r, c] = bool(byte >> c & 1)
        elif holes_lo:
            for r in range(8):
                for c in range(8):
                    hole[r, c] = bool(holes_lo >> ((r // 2) * 4 + c // 2) & 1)

        quad_area = np.full((8, 8), AREA_GROUND, np.uint8)
        outer_z = verts[:81, 2].reshape(9, 9)
        lv, lt, la = [], [], []
        for ltype, lh, lex in liquids.get(iy * 16 + ix, []):
            if liquid_types is not None:
                liquid_types[ltype] = liquid_types.get(ltype, 0) + int(lex.sum())
            cell_ground = (outer_z[:-1, :-1] + outer_z[:-1, 1:] + outer_z[1:, :-1] + outer_z[1:, 1:]) / 4
            cell_surface = (lh[:-1, :-1] + lh[:-1, 1:] + lh[1:, :-1] + lh[1:, 1:]) / 4
            hazard = ltype in HAZARD_TYPES
            deep = lex & ((cell_surface - cell_ground) > SWIM_DEPTH)
            cells = lex if hazard else deep
            if not cells.any():
                continue
            quad_area[cells] = AREA_NULL
            # liquid surface quads (2 triangles each) on the 9x9 liquid vertex grid
            ii, jj = np.meshgrid(np.arange(9), np.arange(9), indexing="ij")
            lverts = np.stack([px - ii * UNIT, py - jj * UNIT, lh], -1).reshape(-1, 3)
            r, c = np.nonzero(cells)
            a, b, cc, d = r * 9 + c, r * 9 + c + 1, (r + 1) * 9 + c, (r + 1) * 9 + c + 1
            quads = np.stack([np.stack([a, cc, b], 1), np.stack([b, cc, d], 1)], 1).reshape(-1, 3)
            lv.append(lverts)
            lt.append(quads)
            la.append(np.full(len(quads), AREA_NULL if hazard else AREA_SWIM, np.uint8))

        keep = ~hole.reshape(-1)
        tris = QUAD_TRIS[keep].reshape(-1, 3) + base
        area = np.repeat(quad_area.reshape(-1)[keep], 4)
        V.append(verts)
        T.append(tris)
        A.append(area)
        base += len(verts)
        for v_, t_, a_ in zip(lv, lt, la):
            V.append(v_)
            T.append(t_ + base)
            A.append(a_)
            base += len(v_)
        ci += 1
    if not V:
        return None
    return np.concatenate(V), np.concatenate(T), np.concatenate(A)


# --------------------------------------------------------------------------------------- objects
def placements(casc, obj0_fdid):
    """(m2 list, wmo list) of placements from an obj0 ADT."""
    obj = casc.read_fdid(obj0_fdid)
    m2s, wmos = [], []
    if not obj:
        return m2s, wmos
    cm = chunk_map(obj)
    if "MDDF" in cm:
        o, s = cm["MDDF"]
        for i in range(s // 36):
            name, uid, x, y, z, rx, ry, rz, sc, fl = struct.unpack_from("<II3f3fHH", obj, o + i * 36)
            m2s.append({"fdid": name, "uid": uid, "pos": (x, y, z), "rot": (rx, ry, rz), "scale": sc / 1024.0, "flags": fl})
    if "MODF" in cm:
        o, s = cm["MODF"]
        for i in range(s // 64):
            vals = struct.unpack_from("<II3f3f6fHHHH", obj, o + i * 64)
            name, uid = vals[0], vals[1]
            pos, rot, ext = vals[2:5], vals[5:8], vals[8:14]
            fl, dset, nset, sc = vals[14:18]
            scale = sc / 1024.0 if fl & 0x4 else 1.0
            wmos.append({"fdid": name, "uid": uid, "pos": pos, "rot": rot, "ext": ext, "flags": fl, "set": dset, "scale": scale})
    return m2s, wmos


def object_meshes(models, m2s, wmos):
    """World-space collision of placed objects, with a per-triangle object key (uid*2, +1 for WMOs)
    so objects referenced by several tiles can be de-duplicated."""
    V, T, A, INDOOR, KEY = [], [], [], [], []
    base = 0
    key = 0

    def add(v, t, indoor=None):
        nonlocal base
        V.append(v)
        T.append(t + base)
        A.append(np.full(len(t), AREA_GROUND, np.uint8))
        INDOOR.append(indoor if indoor is not None else np.zeros(len(t), np.uint8))
        KEY.append(np.full(len(t), key, np.int64))
        base += len(v)

    for p in m2s:
        key = p["uid"] * 2
        col = models.m2_collision(p["fdid"])
        if col is None:
            continue
        v, t = col
        M = placement_matrix(p["rot"], p["scale"])
        add(v @ M.T + placement_pos(p["pos"]), t)

    for p in wmos:
        key = p["uid"] * 2 + 1
        w = models.wmo_root(p["fdid"])
        if w is None:
            continue
        M = placement_matrix(p["rot"], p["scale"])
        P = placement_pos(p["pos"])
        if w["mesh"] is not None:
            v, t, ind = w["mesh"]
            add(v @ M.T + P, t, ind)
        # doodads of the default set and the placement's set
        set_ids = {0, p["set"]}
        for si in set_ids:
            if si >= len(w["sets"]):
                continue
            start, count = w["sets"][si]
            for d in w["modd"][start:start + count]:
                name_idx, dpos, q, dsc = d
                if name_idx >= len(w["modi"]):
                    continue
                col = models.m2_collision(w["modi"][name_idx])
                if col is None:
                    continue
                dv, dt = col
                local = dv * dsc @ quat_matrix(*q).T + np.array(dpos)
                add(local @ M.T + P, dt)

    if not V:
        return None
    return np.concatenate(V), np.concatenate(T), np.concatenate(A), np.concatenate(INDOOR), np.concatenate(KEY)
