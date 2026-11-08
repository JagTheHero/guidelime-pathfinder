# Guidelime Pathfinder

A WoW: Forever add-on that walks you to [Guidelime](https://www.curseforge.com/wow/addons/guidelime)'s current
step along real walkable paths instead of a straight line: the game's waypoint marker moves from corner to corner,
the route is drawn on the world map and minimap and (experimental) as dots on the ground. Routes run in long
straight legs where the ground allows and go around mob camps near your level. It takes the flight
paths you have found, boats, zeppelins, lifts, the Deeprun Tram and the Teldrassil portal, falls back to
[Questie](https://www.curseforge.com/wow/addons/questie)'s map icons for Forever's own quests, and
`/gpath go bank` heads for the nearest bank, inn, vendor or trainer. See
[addon/Guidelime_Pathfinder/CHANGELOG.md](addon/Guidelime_Pathfinder/CHANGELOG.md) for everything it does.

Needs Guidelime and Questie. Paths exist for the Eastern Kingdoms and Kalimdor.

## Install

Copy the three folders in `addon/` (`Guidelime_Pathfinder` and its two path data add-ons,
`Guidelime_Pathfinder_Azeroth` and `Guidelime_Pathfinder_Kalimdor`) into `World of Warcraft/_forever_/Interface/AddOns/`,
or run `tools/install.sh` (set the path in it to your install first), then restart the game (a `/reload` is enough
for later updates that add no files). `/gpath help` lists the
commands.

## Layout

- `addon/Guidelime_Pathfinder/`: the add-on. `addon/Guidelime_Pathfinder_Azeroth/Azeroth.lua` and
  `addon/Guidelime_Pathfinder_Kalimdor/Kalimdor.lua` are its path data (generated, below), each a load-on-demand
  add-on the main one loads when you are on that continent.
- `tools/`: the data pipeline (Python and C++) and route/navmesh debug renders (`check_*.py`).
- `tests/`: the add-on run against a mock WoW API, on the real path data.
- `release/`: the CurseForge page text; `tools/package.sh` makes the upload zip in `dist/`.

## Tests

Build Lua 5.1 (below), then:

```sh
ext/lua51/lua51 tests/test_addon.lua addon/Guidelime_Pathfinder
ext/lua51/lua51 tests/test_graph.lua addon/Guidelime_Pathfinder
ext/lua51/lua51 tests/test_ground.lua addon/Guidelime_Pathfinder
```

## Rebuilding the path data

The paths come from the game's own collision geometry: every map tile's terrain, buildings and doodads go
through a Recast/Detour navmesh, which becomes a sparse walkable graph plus a 2-yard walk grid (every walkable
layer's ground height, snapped to the collision surfaces, and where it ends) and a steep grid (the ground beside it
too steep to walk), packed into the Lua data files. You need Linux, a WoW: Forever install, `cmake`, `ninja`, `g++`, and Python 3 with
`numpy` and `Pillow` (`scipy` for `tools/probe_fit.py`). The full extract is about 5 GB.

1. Dependencies, in `ext/`:

   ```sh
   git clone https://github.com/ladislav-zezula/CascLib.git ext/CascLib                 # tested at 6b889ec
   git clone https://github.com/recastnavigation/recastnavigation.git ext/recastnavigation  # tested at 9f4ce64
   git clone --branch v5.1 https://github.com/lua/lua.git ext/lua51
   mkdir -p ext/cmangos && curl -L -o ext/cmangos/ClassicDB_1_12_1_z2815.sql.gz \
     https://raw.githubusercontent.com/cmangos/classic-db/master/Full_DB/ClassicDB_1_12_1_z2815.sql.gz
   ```

2. Build them and `navbuild`:

   ```sh
   mkdir -p build && cd build
   cmake -S ../ext/CascLib -B casclib -G Ninja -DCMAKE_BUILD_TYPE=Release -DCASC_BUILD_SHARED_LIB=ON \
     -DCASC_BUILD_STATIC_LIB=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 && ninja -C casclib
   cmake -S ../ext/recastnavigation -B recast -G Ninja -DCMAKE_BUILD_TYPE=Release -DRECASTNAVIGATION_DEMO=OFF \
     -DRECASTNAVIGATION_TESTS=OFF -DRECASTNAVIGATION_EXAMPLES=OFF -DRECASTNAVIGATION_DT_POLYREF64=ON \
     -DCMAKE_POSITION_INDEPENDENT_CODE=ON && ninja -C recast
   R=../ext/recastnavigation
   g++ -O2 -std=c++17 -DDT_POLYREF64 -include functional -include array -I$R/Recast/Include -I$R/Detour/Include \
     ../tools/navbuild.cpp recast/Detour/libDetour.a recast/Recast/libRecast.a -lpthread -o navbuild
   cd ../ext/lua51 && gcc -O2 -DLUA_USE_POSIX -o lua51 $(ls *.c | grep -v -E '^(luac|print)\.c$') -lm
   ```

3. Set `WOW_DIR` in `tools/casc.py` to your World of Warcraft folder, then run the pipeline from the repo root
   (Azeroth is instance 0, Kalimdor 1):

   ```sh
   python3 tools/extract.py 8                       # collision geometry -> data/geo (8 workers)
   tools/build_tiles.sh 12                          # navmesh tiles -> data/nav
   mkdir -p data/graph
   python3 tools/pois.py data/graph                 # where quest givers, quest objects and services stand
   python3 tools/mobs.py data/graph                 # hostile mobs: levels, aggro ranges, patrols
   for m in Azeroth Kalimdor; do
     build/navbuild graph data/nav/$m data/graph/$m.graph 12 data/graph/$m.pois
     build/navbuild walkgrid data/nav/$m data/graph/$m.hgt3 12 data/geo/$m
   done
   python3 tools/links.py data/graph/links.json     # flight paths, boats, zeppelins, lifts, tram, portal
   python3 tools/pack.py data/graph/Azeroth.graph 0 Azeroth addon/Guidelime_Pathfinder_Azeroth/Azeroth.lua \
     --walk data/graph/Azeroth.hgt3 --links data/graph/links.json --mobs data/graph/Azeroth.mobs
   python3 tools/pack.py data/graph/Kalimdor.graph 1 Kalimdor addon/Guidelime_Pathfinder_Kalimdor/Kalimdor.lua \
     --walk data/graph/Kalimdor.hgt3 --links data/graph/links.json --mobs data/graph/Kalimdor.mobs
   ```

   `tools/build_tiles.sh` runs `navbuild` in a memory-capped systemd scope (16 GB); drop the `systemd-run`
   prefix if you have no user systemd. `tools/pois.py` reads the installed QuestieDB add-on and the CMaNGOS
   database: routes end on a graph node on the level where an NPC stands (a pier's deck, not the sea beside it).

## Checking the ground dots

The world's ground and how a player walks on it are both known, so the dots can be checked on simulated walks:
`tools/simroutes.py` picks routes (random ones, half of them indoors or on stacked floors, plus fixed ones such as
Ironforge's Great Forge down to the Hall of Thanes), `tools/simdots.lua` walks them through the add-on's own code
with a player that walks on the collision surfaces like a real one (`navbuild geoserve`: not through walls, not up
slopes too steep, not off big drops; on the route line, or a few yards beside it) and writes the player's true and
tracked heights and every dot, `navbuild simtruth` walks the dots' lines on the collision surfaces, and
`tools/simreport.py` says how far off the add-on is:

```sh
python3 tools/simroutes.py build/routes.txt 100
awk '$1 == 0' build/routes.txt > build/routes_0.txt                                                   # one map at a time
ext/lua51/lua51 tools/simdots.lua addon/Guidelime_Pathfinder build/routes_0.txt build/sim.tsv data/geo/Azeroth  # add 6: 6 yd beside
build/navbuild simtruth data/geo/Azeroth build/sim.tsv 12 build/truth.tsv
python3 tools/simreport.py build/sim.tsv build/truth.tsv 20 data/graph/Azeroth.hgt3
```

`tools/render_walk.py` draws the walk grid around a route from above.

## License

Copyright (c) 2026 JagTheHero. GNU General Public License version 3 or later, see [LICENSE](LICENSE). The path
and height data is computed from World of Warcraft's map geometry. NPC heights and the hostile mobs (levels,
aggro ranges, patrols) come from the [CMaNGOS classic database](https://github.com/cmangos/classic-db) (GPL-3.0),
whose game content is shared for non-commercial use. World of Warcraft is a trademark of Blizzard
Entertainment, Inc. Not made or endorsed by Blizzard, or by the authors of Guidelime, Questie or CMaNGOS.
