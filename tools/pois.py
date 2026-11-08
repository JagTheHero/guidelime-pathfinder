"""Where quest givers, quest objects and town services stand, from the installed QuestieDB, for navbuild graph.

usage: pois.py <out_dir>    writes <out_dir>/Azeroth.pois and Kalimdor.pois: "worldX worldY [worldZ]" per line

Routes end at the graph node nearest the target, so navbuild puts nodes where a player can stand to talk to these
(within 5 yards: in front of a banker's counter): within reach of their height when known (a pier's deck, an
inn's upper floor), on every walkable level over the spot otherwise.
QuestieDB keeps its rows as base-64 CBOR in TOC metadata: ## X-Npc-<id>-<field> (S: the scalar fields, 7:
spawns, 10/11: quests it starts/ends) and ## X-Object-<id>-<field> (2/3: quests it starts/ends, 4: spawns).
Spawns are zone percent per area id; QuestieDB maps area ids to UiMap ids, and the client's UiMapAssignment to
world coordinates. Questie's spots have no height: the same NPC's or object's spawn in the CMaNGOS classic
database (tools/cmangos.py) within MATCH yards gives the exact spot and height; WoW: Forever's own NPCs have none.
"""
import base64
import os
import re
import struct
import sys

from casc import Casc, WOW_DIR
from cmangos import table
from db2 import WDC5

QUESTIE = os.path.join(WOW_DIR, "_forever_/Interface/AddOns/QuestieDB")
TOC = QUESTIE + "/QuestieDB_Forever.toc"
AREA2UI = QUESTIE + "/support/Forever/Zones/areaIdToUiMapId.lua"
UIMAPASSIGNMENT = 1957219
CONTINENTS = {0: "Azeroth", 1: "Kalimdor"}
MAX_SPAWNS = 30  # an NPC with more spawns than this is a wandering mob that happens to give a quest
MATCH = 10  # yards between Questie's spot and a CMaNGOS spawn of the same NPC or object that count as one


def cbor(b, i=0):
    ib = b[i]
    major, info = ib >> 5, ib & 31
    i += 1
    if info < 24:
        val = info
    elif info == 24:
        val, i = b[i], i + 1
    elif info == 25:
        val, i = struct.unpack_from(">H", b, i)[0], i + 2
    elif info == 26:
        if major == 7:
            return struct.unpack_from(">f", b, i)[0], i + 4
        val, i = struct.unpack_from(">I", b, i)[0], i + 4
    elif info == 27:
        if major == 7:
            return struct.unpack_from(">d", b, i)[0], i + 8
        val, i = struct.unpack_from(">Q", b, i)[0], i + 8
    else:
        raise ValueError(info)
    if major == 0:
        return val, i
    if major == 1:
        return -1 - val, i
    if major in (2, 3):
        return b[i:i + val].decode("utf-8", "replace"), i + val
    if major == 4:
        out = []
        for _ in range(val):
            v, i = cbor(b, i)
            out.append(v)
        return out, i
    if major == 5:
        out = {}
        for _ in range(val):
            k, i = cbor(b, i)
            v, i = cbor(b, i)
            out[k] = v
        return out, i
    if major == 7:
        if info == 25:  # half float
            s, e, m = val >> 15, (val >> 10) & 31, val & 1023
            f = (m / 1024) * 2 ** -14 if e == 0 else (1 + m / 1024) * 2 ** (e - 15)
            return (-f if s else f), i
        return {20: False, 21: True, 22: None}.get(val, val), i
    raise ValueError(major)


def dec(s):
    v = cbor(base64.b64decode(s))[0]
    if isinstance(v, list):  # a Lua table keyed 1..n
        v = {i + 1: x for i, x in enumerate(v) if x is not None}
    return v


def main():
    out_dir = sys.argv[1]
    rows, parts = {}, {}
    pat = re.compile(r"^## X-(Npc|Object)-(\d+)-(\w+)(?:-(\d+))?: (.*)$")
    with open(TOC, encoding="utf-8") as f:
        for line in f:
            m = pat.match(line.rstrip("\r\n"))
            if m and m[4]:
                parts[(m[1], int(m[2]), m[3], int(m[4]))] = m[5]
            elif m:
                rows[(m[1], int(m[2]), m[3])] = m[5]
    for key, v in rows.items():  # long rows are "~n~", continued in fields <field>-1 .. <field>-n
        n = re.fullmatch(r"~(\d+)~", v)
        if n:
            rows[key] = "".join(parts[key + (i,)] for i in range(1, int(n[1]) + 1))
    with open(AREA2UI) as f:
        area2ui = {int(a): int(u) for a, u in re.findall(r"\[(\d+)\]\s*=\s*(\d+)", f.read())}

    casc = Casc()
    t = WDC5(casc.read_fdid(UIMAPASSIGNMENT))
    rect = {}
    for rid, r in t.records:
        umin, umax, region = t.field(r, 0, rid, "f"), t.field(r, 1, rid, "f"), t.field(r, 2, rid, "f")
        ui, order, mapid = t.field(r, 4, rid), t.field(r, 5, rid), t.field(r, 6, rid)
        if order == 0 and umin == (0.0, 0.0) and umax == (1.0, 1.0) and ui not in rect:
            rect[ui] = (mapid, region)

    # NPCs that start or end a quest or offer a service (any flag but plain gossip); quest objects
    wanted = []
    for (kind, id_, field) in list(rows):
        if kind == "Npc" and field == "S":
            row = dec(rows[(kind, id_, field)])
            if row.get(1, "").startswith("[DND]"):
                continue
            if (kind, id_, "10") in rows or (kind, id_, "11") in rows or row.get(15, 0) & ~1:
                wanted.append((kind, id_, "7"))
        elif kind == "Object" and field in ("2", "3"):
            wanted.append((kind, id_, "4"))
    exact = {}  # (kind, id, map) -> [(x, y, z)], world coordinates
    for kind, name in (("Npc", "creature"), ("Object", "gameobject")):
        for r in table(name):
            if r[2] in CONTINENTS:
                exact.setdefault((kind, r[1], r[2]), []).append((r[4], r[5], r[6]))
    pts = {m: {} for m in CONTINENTS}
    matched = total = 0
    for key in sorted(set(wanted)):
        s = rows.get(key)
        if not s:
            continue
        spawns = dec(s)
        if sum(len(v) for v in spawns.values() if isinstance(v, list)) > MAX_SPAWNS:
            continue
        for area, ps in spawns.items():
            ui = area2ui.get(area)
            if ui not in rect or not isinstance(ps, list):
                continue
            mapid, (x0, y0, _z0, x1, y1, _z1) = rect[ui]
            if mapid not in pts:
                continue
            for p in ps:
                if not isinstance(p, list) or len(p) < 2 or p[0] < 0:
                    continue
                wy = y1 - p[0] / 100 * (y1 - y0)
                wx = x1 - p[1] / 100 * (x1 - x0)
                near = min(exact.get((key[0], key[1], mapid), []), key=lambda e: (e[0] - wx) ** 2 + (e[1] - wy) ** 2,
                           default=None)
                total += 1
                if near and (near[0] - wx) ** 2 + (near[1] - wy) ** 2 <= MATCH ** 2:
                    matched += 1
                    pts[mapid][(round(near[0], 1), round(near[1], 1))] = round(near[2], 1)
                else:
                    pts[mapid].setdefault((round(wx, 1), round(wy, 1)), None)
    print("spots with a CMaNGOS height: %d of %d" % (matched, total))
    for mapid, name in CONTINENTS.items():
        path = os.path.join(out_dir, name + ".pois")
        with open(path, "w") as f:
            for (wx, wy), wz in sorted(pts[mapid].items()):
                f.write("%.1f %.1f\n" % (wx, wy) if wz is None else "%.1f %.1f %.1f\n" % (wx, wy, wz))
        print("%s: %d points" % (path, len(pts[mapid])))


if __name__ == "__main__":
    main()
