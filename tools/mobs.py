"""Hostile creatures on the two continents, for routes that go around mobs near the player's level.

usage: mobs.py <out_dir>    writes <out_dir>/Azeroth.mobs and Kalimdor.mobs, one line per mob or patrol point:
                            worldX worldY worldZ minLevel maxLevel detection wander flags

From the CMaNGOS classic database (tools/cmangos.py): spawns, levels, detection range (the aggro radius at the
player's level; CMaNGOS's Unit::GetAttackDistance takes 1 yard off per level the player is above the mob, down to
5) and wander radius. Hostility comes from the client's FactionTemplate: a mob counts as hostile to a side when
it is to any of that side's races, by the client's rule (enemy list, then friend list, then enemy group mask).
flags: 1 hostile to the Alliance, 2 to the Horde, 4 elite, 8 a point on a patrol path (the patrol's spawn and
its waypoints, at least PATROL_STEP yards apart).
"""
import math
import os
import sys

from casc import Casc
from cmangos import table
from db2 import WDC5

FACTION_TEMPLATE = 1361579
RACES = {1: (1, 3, 4, 115), 2: (2, 5, 6, 116)}  # player faction templates: Alliance, Horde
CONTINENTS = {0: "Azeroth", 1: "Kalimdor"}
PATROL_STEP = 15
NO_AGGRO, INVISIBLE, CIVILIAN = 0x2, 0x80, 0x10000  # ExtraFlags
NON_ATTACKABLE, NOT_SELECTABLE = 0x2, 0x2000000      # UnitFlags


def faction_templates():
    t = WDC5(Casc().read_fdid(FACTION_TEMPLATE))
    out = {}
    for rid, r in t.records:
        faction, _flags, group, _friend_group, enemy_group, enemies, friends = (t.field(r, i, rid) for i in range(7))
        out[rid] = dict(faction=faction, group=group, enemy_group=enemy_group, enemies=enemies, friends=friends)
    return out


def hostile(ft, mob, player):
    m, p = ft.get(mob), ft[player]
    if not m or mob == player:
        return False
    if p["faction"]:
        if p["faction"] in m["enemies"]:
            return True
        if p["faction"] in m["friends"]:
            return False
    return (m["enemy_group"] & p["group"]) != 0


def row(x, y, z, stats, wander, flags):
    return "%.1f %.1f %.1f %s %d %d" % (x, y, z, stats, min(wander, 63), flags)


def main():
    out_dir = sys.argv[1]
    ft = faction_templates()
    tpl = {}
    for r in table("creature_template"):
        entry, name, minl, maxl, faction, unit_flags, extra = r[0], r[1], r[3], r[4], r[9], r[17], r[19]
        detection, rank, civilian = r[27], r[33], r[84]
        if extra & (NO_AGGRO | INVISIBLE | CIVILIAN) or civilian or unit_flags & (NON_ATTACKABLE | NOT_SELECTABLE) or not detection:
            continue
        side = sum(bit for bit, races in ((1, RACES[1]), (2, RACES[2])) if any(hostile(ft, faction, p) for p in races))
        if side:
            tpl[entry] = (minl, maxl, detection, side | (4 if rank in (1, 2, 3) else 0))
    alt = {}
    for guid, entry in table("creature_spawn_entry"):
        alt.setdefault(guid, entry)
    paths = {}
    for r in table("creature_movement"):
        paths.setdefault(("guid", r[0]), []).append((r[1], r[2], r[3], r[4]))
    for r in table("creature_movement_template"):
        if r[1] == 0:
            paths.setdefault(("entry", r[0]), []).append((r[2], r[3], r[4], r[5]))
    rows = {m: [] for m in CONTINENTS}
    patrols = 0
    for r in table("creature"):
        guid, entry, mapid, x, y, z, wander, movement = r[0], r[1] or alt.get(r[0]), r[2], r[4], r[5], r[6], r[10], r[11]
        t = tpl.get(entry)
        if mapid not in CONTINENTS or not t:
            continue
        minl, maxl, detection, flags = t
        stats = "%d %d %d" % (minl, maxl, min(detection, 63))
        path = movement == 2 and (paths.get(("guid", guid)) or paths.get(("entry", entry)))
        if path:
            patrols += 1
            last = (x, y)
            rows[mapid].append(row(x, y, z, stats, 0, flags | 8))
            for _, px, py, pz in sorted(path):
                if math.dist(last, (px, py)) >= PATROL_STEP:
                    rows[mapid].append(row(px, py, pz, stats, 0, flags | 8))
                    last = (px, py)
        else:
            rows[mapid].append(row(x, y, z, stats, round(wander) if movement == 1 else 0, flags))
    print("hostile creature templates: %d, patrols: %d" % (len(tpl), patrols))
    for mapid, name in CONTINENTS.items():
        path = os.path.join(out_dir, name + ".mobs")
        with open(path, "w") as f:
            f.write("\n".join(rows[mapid]) + "\n")
        print("%s: %d mobs and patrol points" % (path, len(rows[mapid])))


if __name__ == "__main__":
    main()
