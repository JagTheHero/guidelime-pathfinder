"""Fit the game camera to /gpath probe data.

usage: probe_fit.py <probe.json> <geo_dir>
The game draws a user waypoint at its own ground height (our z is ignored), so marker heights come from the
extracted terrain. Fits pitch/yaw per probe plus focal length, pivot height, camera distance and marker lift.
"""
import json, math, os, struct, sys
import numpy as np
from scipy.optimize import least_squares

TILE = 1600 / 3
TERRAIN = os.environ.get("MARKER_Z", "player") == "terrain"  # marker at terrain height, else at the player's height


def load_terrain(geo_dir, col, row):
    d = open(os.path.join(geo_dir, "%d_%d.geo" % (col, row)), "rb").read()
    nv, nt = struct.unpack_from("<II", d, 4)
    p = 12
    V = np.frombuffer(d, "<f4", nv * 3, p).reshape(-1, 3); p += nv * 12
    T = np.frombuffer(d, "<i4", nt * 3, p).reshape(-1, 3); p += nt * 12
    A = np.frombuffer(d, "u1", nt, p); p += nt
    K = np.frombuffer(d, "<i8", nt, p)
    return V, T, K


_cache = {}


def ground(geo_dir, X, Y, terrain_only=True):
    """Heights of all surfaces at world (X north, Y west): terrain first, then object surfaces."""
    col, row = int(math.floor(32 - Y / TILE)), int(math.floor(32 - X / TILE))
    if (col, row) not in _cache:
        _cache[(col, row)] = load_terrain(geo_dir, col, row)
    V, T, K = _cache[(col, row)]
    a, b, c = V[T[:, 0]], V[T[:, 1]], V[T[:, 2]]
    v0, v1 = b[:, :2] - a[:, :2], c[:, :2] - a[:, :2]
    v2 = np.array([X, Y]) - a[:, :2]
    den = v0[:, 0] * v1[:, 1] - v1[:, 0] * v0[:, 1]
    ok = np.abs(den) > 1e-9
    u = np.where(ok, (v2[:, 0] * v1[:, 1] - v1[:, 0] * v2[:, 1]) / np.where(ok, den, 1), -1)
    w = np.where(ok, (v0[:, 0] * v2[:, 1] - v2[:, 0] * v0[:, 1]) / np.where(ok, den, 1), -1)
    inside = ok & (u >= -1e-6) & (w >= -1e-6) & (u + w <= 1 + 1e-6)
    z = a[:, 2] + u * (b[:, 2] - a[:, 2]) + w * (c[:, 2] - a[:, 2])
    ter = z[inside & (K == -1)]
    obj = z[inside & (K != -1)]
    return (float(ter.max()) if len(ter) else None), sorted(set(np.round(obj, 2).tolist()))


def project(params, E, N, U, F, d, W, H):
    yaw, pitch, f = params
    cy, sy, cp, sp = math.cos(yaw), math.sin(yaw), math.cos(pitch), math.sin(pitch)
    fwd = np.array([-sy * cp, cy * cp, -sp])
    right = np.array([cy, sy, 0.0])
    up = np.cross(right, fwd)
    C = F - d * fwd
    v = np.stack([E, N, U], -1) - C
    cf = v @ fwd
    return W / 2 + f * (v @ right) / cf, H / 2 + f * (v @ up) / cf


def main():
    db = json.load(open(sys.argv[1]))
    geo_dir = sys.argv[2]
    probes = []
    for pr in db["probes"]:
        pl, sc = pr["player"], pr["screen"]
        W, H = sc["uiW"], sc["uiH"]
        zp, objp = ground(geo_dir, pl["y"], pl["x"])
        rows = []
        for pt in pr["points"]:
            s = pt["s"][-1]
            if s[2] != 1 or s[3] != 0:
                continue
            hx, hy = pt["w"][0], pt["w"][1]
            zt, objs = ground(geo_dir, hy, hx)
            rows.append((-hx, hy, zt, s[0], s[1], s[4], objs))
        probes.append(dict(pl=pl, W=W, H=H, zp=zp, objp=objp, rows=rows))
        print("probe at", round(pl["x"], 1), round(pl["y"], 1), "terrain z", round(zp, 2), "objects", objp[:4], "facing", round(pl["facing"], 4), "zoom", pl["zoom"])
        for r in rows[:5]:
            print("   pt terrain z %.2f objects %s  screen %.1f %.1f  game dist %.2f" % (r[2], r[6][:3], r[3], r[4], r[5]))

    # parameters: per probe (yaw, pitch); global f, h (pivot above feet), d scale, lift (marker above ground)
    def unpack(x):
        g = x[2 * len(probes):]
        return [(x[2 * i], x[2 * i + 1]) for i in range(len(probes))], g

    def residuals(x, free):
        per, g = unpack(x)
        f, h, dscale, lift = g
        res = []
        for (yaw, pitch), pr in zip(per, probes):
            R = np.array(pr["rows"], dtype=object)
            E = R[:, 0].astype(float); N = R[:, 1].astype(float)
            Z = (R[:, 2].astype(float) if TERRAIN else np.full(len(R), pr["zp"])) + lift
            F = np.array([-pr["pl"]["x"], pr["pl"]["y"], pr["zp"] + h])
            sx, sy = project((yaw, pitch, f), E, N, Z, F, pr["pl"]["zoom"] * dscale, pr["W"], pr["H"])
            res += list(sx - R[:, 3].astype(float)) + list(sy - R[:, 4].astype(float))
        return np.array(res)

    x0 = []
    for pr in probes:
        x0 += [pr["pl"]["facing"], 0.3]
    W = probes[0]["W"]
    x0 += [(W / 2) / math.tan(math.radians(45)), 1.9, 1.0, 0.0]
    for name, fix in (("pitch+yaw only (f from cameraFov 90 horizontal, pivot 1.9, distance=zoom, no lift)", {"f", "h", "d", "lift"}),
                      ("free f", {"h", "d", "lift"}),
                      ("free f, pivot", {"d", "lift"}),
                      ("free f, pivot, distance", {"lift"}),
                      ("all free", set())):
        idx = {"f": -4, "h": -3, "d": -2, "lift": -1}
        mask = np.ones(len(x0), bool)
        for k in fix:
            mask[len(x0) + idx[k]] = False
        base = np.array(x0, float)

        def fun(v):
            full = base.copy(); full[mask] = v
            return residuals(full, None)
        r = least_squares(fun, base[mask])
        full = base.copy(); full[mask] = r.x
        res = fun(r.x)
        per, g = unpack(full)
        f, h, ds, lift = g
        hfov = math.degrees(2 * math.atan((W / 2) / f))
        vfov = math.degrees(2 * math.atan((probes[0]["H"] / 2) / f))
        print("%-90s rms %6.2f px max %6.2f | hfov %.1f vfov %.1f pivot %.2f dist x%.3f lift %.2f | %s" % (name, np.sqrt(np.mean(res ** 2)), np.abs(res).max(),
              hfov, vfov, h, ds, lift, " ".join("yaw %.4f (facing %.4f) pitch %.3f" % (y, pr["pl"]["facing"], p) for (y, p), pr in zip(per, probes))))


if __name__ == "__main__":
    main()
