"""Flight paths, boats, zeppelins, lifts, the tram and the Teldrassil portal, as links between walkable places.

usage: links.py <out.json>

Reads the game's TaxiPath and TaxiPathNode tables (flight routes and ship routes, with their full paths) and
TransportAnimation (lift timings), and puts every dock, landing and portal on walkable ground from the
navbuild graphs (data/graph/<map>.graph). Coordinates are written in HereBeDragons world space
(x = world Y, y = world X), per continent (instance 0 Azeroth, 1 Kalimdor):

  taxi:    {node id: [x, y, z]}       flight masters (TaxiNodes ids, as C_TaxiMap reports them)
  flights: [[from, to, seconds]]     direct flights
  rides:   [[kind, to name, x, y, z, to instance, x, y, z, ride seconds, wait seconds, faction]]
           kind boat | zeppelin | lift | tram | portal; faction "A", "H" or "" for anyone
"""
import json
import math
import os
import sys
from collections import defaultdict

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from casc import Casc
from db2 import WDC5
from graphio import components, read_graph

TAXIPATH, TAXIPATHNODE, TRANSPORTANIMATION = 1067802, 1000437, 1140686
MAPS = {0: "Azeroth", 1: "Kalimdor"}
GRAPH_DIR = os.path.join(os.path.dirname(__file__), "..", "data", "graph")
FLIGHT_SPEED = 32.0  # yards per second on a flight path
SHIP_SPEED, SHIP_ACCEL = 30.0, 1.0  # boats and zeppelins: yards per second, and per second squared
MIN_COMPONENT = 25  # pack.py drops smaller pieces of the graph

# Ship routes that run, by TaxiPath id: kind, faction, and the stops' names in path order. The client also
# holds routes that may not run on Forever (a stop at Southshore, routes to a map 2991): those are left out.
# Stormwind's harbour is in this client's map (its docks and lighthouse are placed), so its boat counts.
SHIPS = {
    241: ("boat", "", ["Ratchet", "Booty Bay"]),
    285: ("zeppelin", "H", ["Grom'gol", "Orgrimmar"]),
    292: ("boat", "A", ["Menethil Harbor", "Theramore"]),
    293: ("boat", "A", ["Rut'theran Village", "Auberdine"]),
    295: ("boat", "A", ["Menethil Harbor", "Auberdine"]),
    301: ("zeppelin", "H", ["Grom'gol", "Undercity"]),
    302: ("zeppelin", "H", ["Orgrimmar", "Undercity"]),
    303: ("boat", "A", ["Feathermoon Stronghold", "the Feralas coast"]),
    11391: ("boat", "", ["Tanaris", ""]),  # to the new zone east of the Burning Steppes; named in game
    11616: ("boat", "A", ["Auberdine", "Stormwind Harbor"]),
}

# Lifts: (continent, lower landing, upper landing, TransportAnimation id) in world (X, Y, Z). Thunder Bluff's,
# found as the only places where its mesa (cut off from the ground in the graph) has walkable ground a lift's
# travel (71 yards, from TransportAnimation 47296/47297) below it; the others at their cars in the CMaNGOS
# database (gameobject type 11), the landings at the ends of the car's travel (TransportAnimation): the Great
# Lift and Freewind Post (129.5 yards), Undercity's three (96.5 yards, the top landing on the ruins' floor).
LIFTS = [
    (1, (-1092, 140, 74), (-1100, 132, 147), 47296),
    (1, (-1084, -100, 82), (-1076, -108, 151), 47296),
    (1, (-4670.8, -1849.6, -44.1), (-4665.4, -1827.7, 85.4), 11898),  # the Great Lift
    (1, (-5382.5, -2489.4, -40.5), (-5399.2, -2504.6, 89.0), 11898),  # Freewind Post
    (0, (1596.2, 291.8, -40.8), (1596.2, 291.8, 62.3), 20652),        # Undercity
    (0, (1595.3, 188.6, -40.8), (1595.3, 188.6, 62.3), 20652),
    (0, (1544.2, 240.8, -40.8), (1544.2, 240.8, 62.3), 20652),
]
# Deeprun Tram entrances (AreaTrigger 2173 Stormwind, 2175 Ironforge) and the Teldrassil portals
# (AreaTrigger 542 Rut'theran Village up, 527 Darnassus down); you come out next to the other end's trigger.
TRAM = ((-8346.5, 514.0, 96.6, "Stormwind"), (-4840.3, -1330.5, 508.2, "Ironforge"))
TRAM_RIDE, TRAM_WAIT = 90, 25  # walk the station tunnels and ride; cars leave each end about every 48 s
PORTALS = ((8799.4, 969.8, 30.2, "Rut'theran Village"), (9947.5, 2630.0, 1318.6, "Darnassus"))


def taxi_tables(casc):
    tp = WDC5(casc.read_fdid(TAXIPATH))
    paths = {}
    for rid, r in tp.records:
        f = [tp.field(r, i, rid) for i in range(4)]
        paths[f[0]] = tuple(f[1:])  # from, to, cost
    tn = WDC5(casc.read_fdid(TAXIPATHNODE))
    nodes = defaultdict(list)
    for rid, r in tn.records:
        loc = tn.field(r, 0, rid, "f")
        f = [tn.field(r, i, rid) for i in range(1, 9)]
        # PathID, NodeIndex, ContinentID, Flags (2 = stop), Delay
        nodes[f[1]].append((f[2], loc, f[3], f[4], f[5]))
    for v in nodes.values():
        v.sort()
    return paths, nodes


def path_length(pts, a, b):
    """Length of the path from point a to point b, skipping jumps (between continents, or from a node flagged 1)."""
    total = 0.0
    for i in range(a, b):
        if pts[i][2] == pts[i + 1][2] and not pts[i][3] & 1:
            total += math.dist(pts[i][1], pts[i + 1][1])
    return total


class Walkable:
    """Graph nodes of the pieces pack.py keeps, per continent, for snapping places onto walkable ground."""

    def __init__(self):
        self.pts = {}
        for inst, name in MAPS.items():
            n, e = read_graph(os.path.join(GRAPH_DIR, name + ".graph"))
            comp = components(len(n), e)
            _, inv, cnt = np.unique(comp, return_inverse=True, return_counts=True)
            keep = cnt[inv] >= MIN_COMPONENT
            self.pts[inst] = np.stack([n["x"][keep], n["y"][keep], n["z"][keep]], 1).astype(np.float64)

    def snap(self, inst, x, y, z, radius=60, above=5):
        """The walkable point nearest (x, y, z) in 3D within radius yards across, not more than `above` higher."""
        p = self.pts[inst]
        d2 = np.hypot(p[:, 0] - x, p[:, 1] - y)
        ok = (d2 < radius) & (p[:, 2] <= z + above)
        if not ok.any():
            raise SystemExit("no walkable ground near (%.0f, %.0f, %.0f) on %s" % (x, y, z, MAPS[inst]))
        d3 = np.where(ok, np.sqrt(d2 ** 2 + (p[:, 2] - z) ** 2), np.inf)
        j = int(d3.argmin())
        return float(p[j, 0]), float(p[j, 1]), float(p[j, 2]), float(d3[j])


def hbd(x, y, z):
    return [round(y, 1), round(x, 1), round(z, 1)]


def main():
    out = sys.argv[1]
    casc = Casc()
    paths, nodes = taxi_tables(casc)
    walk = Walkable()
    data = {inst: {"taxi": {}, "flights": [], "rides": []} for inst in MAPS}

    # flights: routes between two flight masters on one continent, without the stops and jumps of ship routes
    # (some real flights cost nothing, Rut'theran Village to Auberdine)
    ends = defaultdict(list)
    for pid, (a, b, cost) in sorted(paths.items()):
        pts = nodes.get(pid)
        if pid in SHIPS or not pts or a == 0 or b == 0 or a == b:
            continue
        cont = pts[0][2]
        if cont not in MAPS or any(p[2] != cont or p[3] & 3 for p in pts) or math.dist(pts[0][1], pts[-1][1]) < 100:
            continue
        secs = round(path_length(pts, 0, len(pts) - 1) / FLIGHT_SPEED)
        data[cont]["flights"].append([a, b, secs])
        ends[(cont, a)].append(pts[0][1])
        ends[(cont, b)].append(pts[-1][1])
    for (cont, node), locs in sorted(ends.items()):
        x, y, z = np.mean(locs, 0)
        data[cont]["taxi"][node] = hbd(x, y, z)

    # boats and zeppelins: stops in path order, each leg's ride time, waiting half a round trip on average
    for pid, (kind, faction, names) in SHIPS.items():
        pts = nodes[pid]
        stops = []
        for i, p in enumerate(pts):
            if p[3] & 2 and not (stops and pts[stops[-1]][2] == p[2] and math.dist(pts[stops[-1]][1], p[1]) < 30):
                stops.append(i)
        if len(stops) > 2 and pts[stops[0]][2] == pts[stops[-1]][2] and math.dist(pts[stops[0]][1], pts[stops[-1]][1]) < 30:
            stops.pop()  # the loop starts at a stop and comes back to it
        assert len(stops) == len(names), (pid, stops)
        legs = []
        for k, s in enumerate(stops):
            t = stops[(k + 1) % len(stops)]
            length = path_length(pts, s, t) if t > s else path_length(pts, s, len(pts) - 1) + path_length(pts, 0, t)
            legs.append(length / SHIP_SPEED + SHIP_SPEED / SHIP_ACCEL)
        period = sum(legs) + sum(pts[s][4] for s in stops)
        docks = []
        for s in stops:
            cont, (x, y, z) = pts[s][2], pts[s][1]
            sx, sy, sz, d = walk.snap(cont, x, y, z)
            docks.append((cont, sx, sy, sz))
            print("%s %d stop %s: dock %.0f yd from the ship" % (kind, pid, names[len(docks) - 1] or "?", d))
        for k in range(len(stops)):
            a, b = docks[k], docks[(k + 1) % len(stops)]
            data[a[0]]["rides"].append([kind, names[(k + 1) % len(stops)], *hbd(*a[1:]), b[0], *hbd(*b[1:]),
                                        round(legs[k]), round(period / 2), faction])

    # lifts: up and down, a ride is about half the cycle and the car is on average half a cycle away
    anim = WDC5(casc.read_fdid(TRANSPORTANIMATION))
    cycles = defaultdict(int)
    for rid, r in anim.records:
        tid = anim.parent.get(r)
        cycles[tid] = max(cycles[tid], anim.field(r, 2, rid))
    for cont, low, high, tid in LIFTS:
        cycle = cycles[tid] / 1000.0
        lo = walk.snap(cont, *low, radius=40, above=3)[:3]  # the graph's nodes near a lift may be some way off
        hi = walk.snap(cont, *high, radius=40, above=3)[:3]
        data[cont]["rides"].append(["lift", "up", *hbd(*lo), cont, *hbd(*hi), round(cycle / 2), round(cycle / 2), ""])
        data[cont]["rides"].append(["lift", "down", *hbd(*hi), cont, *hbd(*lo), round(cycle / 2), round(cycle / 2), ""])

    # the tram (its own map in between) and the Teldrassil portal: you come out next to the other end
    for (ends_, kind, ride, wait, faction) in ((TRAM, "tram", TRAM_RIDE, TRAM_WAIT, "A"), (PORTALS, "portal", 2, 0, "A")):
        cont = 0 if kind == "tram" else 1
        for a, b in ((ends_[0], ends_[1]), (ends_[1], ends_[0])):
            data[cont]["rides"].append([kind, b[3], *hbd(*a[:3]), cont, *hbd(*b[:3]), ride, wait, faction])

    for inst, d in data.items():
        print("%s: %d flight masters, %d flights, %d rides" % (MAPS[inst], len(d["taxi"]), len(d["flights"]), len(d["rides"])))
    with open(out, "w") as f:
        json.dump({str(k): v for k, v in data.items()}, f, indent=1)


if __name__ == "__main__":
    main()
