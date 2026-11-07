# Guidelime Pathfinder

A WoW: Forever add-on that walks you to [Guidelime](https://www.curseforge.com/wow/addons/guidelime)'s current
step along real walkable paths instead of a straight line: the game's waypoint marker moves from corner to corner,
the route is drawn on the world map and minimap and (experimental) as dots on the ground. It takes the flight
paths you have found, boats, zeppelins, lifts, the Deeprun Tram and the Teldrassil portal, falls back to
[Questie](https://www.curseforge.com/wow/addons/questie)'s map icons for Forever's own quests, and
`/gpath go bank` heads for the nearest bank, inn, vendor or trainer. See
[addon/Guidelime_Pathfinder/CHANGELOG.md](addon/Guidelime_Pathfinder/CHANGELOG.md) for everything it does.

Needs Guidelime and Questie. Paths exist for the Eastern Kingdoms and Kalimdor.

## Install

Copy `addon/Guidelime_Pathfinder` into `World of Warcraft/_forever_/Interface/AddOns/`, or run
`tools/install.sh` (set the path in it to your install first), then `/reload` in game. `/gpath help` lists the
commands.

## Layout

- `addon/Guidelime_Pathfinder/`: the add-on. `Data/Azeroth.lua` and `Data/Kalimdor.lua` are generated (below).
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
through a Recast/Detour navmesh, which becomes a sparse walkable graph plus an 8-yard ground-height map, packed
into the Lua data files. You need Linux, a WoW: Forever install, `cmake`, `ninja`, `g++`, and Python 3 with
`numpy` and `Pillow` (`scipy` for `tools/probe_fit.py`). The full extract is about 5 GB.

1. Dependencies, in `ext/`:

   ```sh
   git clone https://github.com/ladislav-zezula/CascLib.git ext/CascLib                 # tested at 6b889ec
   git clone https://github.com/recastnavigation/recastnavigation.git ext/recastnavigation  # tested at 9f4ce64
   git clone --branch v5.1 https://github.com/lua/lua.git ext/lua51
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
   for m in Azeroth Kalimdor; do
     build/navbuild graph data/nav/$m data/graph/$m.graph 12
     build/navbuild heights data/nav/$m data/graph/$m.hgt 12
   done
   python3 tools/links.py data/graph/links.json     # flight paths, boats, zeppelins, lifts, tram, portal
   python3 tools/pack.py data/graph/Azeroth.graph 0 Azeroth addon/Guidelime_Pathfinder/Data/Azeroth.lua \
     --heights data/graph/Azeroth.hgt --links data/graph/links.json
   python3 tools/pack.py data/graph/Kalimdor.graph 1 Kalimdor addon/Guidelime_Pathfinder/Data/Kalimdor.lua \
     --heights data/graph/Kalimdor.hgt --links data/graph/links.json
   ```

   `tools/build_tiles.sh` runs `navbuild` in a memory-capped systemd scope (16 GB); drop the `systemd-run`
   prefix if you have no user systemd.

## License

MIT, see [LICENSE](LICENSE). The path and height data is computed from World of Warcraft's map geometry; World
of Warcraft is a trademark of Blizzard Entertainment, Inc. Not made or endorsed by Blizzard, or by the authors of
Guidelime or Questie.
