# CurseForge upload: Guidelime Pathfinder

## Project form

- Game: World of Warcraft
- Name: Guidelime Pathfinder
- Summary: Walks you to Guidelime's current step along real walkable paths, flights and boats.
- Categories: Map & Minimap (main), Quests & Leveling
- License: GNU General Public License version 3 (GPLv3)
- Description: everything under "Description" below (Markdown)
- Logo: `release/logo-draft.png` (1024x1024)
- Gallery: 2-3 in-game screenshots of the marker, the ground dots and the map trail

## File upload

- File: `dist/Guidelime_Pathfinder-0.4.0.zip` (made by `tools/package.sh`)
- Display name: Guidelime Pathfinder 0.4.0
- Release type: Beta
- Game version: Forever (1.60.1; the TOC says `## Interface: 16001`)
- Changelog: the 0.4.0 section of `addon/Guidelime_Pathfinder/CHANGELOG.md`
- Related projects (both **Required Dependency**):
  - Guidelime: https://www.curseforge.com/wow/addons/guidelime
  - Questie: https://www.curseforge.com/wow/addons/questie

## Description

**Guidelime Pathfinder** walks you to [Guidelime](https://www.curseforge.com/wow/addons/guidelime)'s current step
along real walkable paths, not a straight line through the mountain in the way.

### What it does

- **Real paths.** Routes go around cliffs, through city gates and down the right ramp, worked out from the
  world's own ground in the Eastern Kingdoms and Kalimdor.
- **Waypoint marker.** The game's own in-world waypoint marker moves from corner to corner along the path, with
  the path drawn on the world map and the minimap. Experimental: dots on the ground ahead of you.
- **Floors and tunnels.** Ironforge's halls under the mountain, bridges over rivers, buildings with upper
  floors: the route stays on the level you are on.
- **Long straight runs.** Where the shortest walk runs straight, so does the route: few, long legs you can
  line up with and run.
- **Around mob camps.** Hostile mobs near your level count like a traffic jam: the route skirts their aggro
  range when the way around is not much longer.
- **Flights, boats and more.** Takes the flight paths you have found (and highlights where to fly on the flight
  map), boats, zeppelins, Thunder Bluff's lifts, the Deeprun Tram and the Teldrassil portal, and tells you what
  to do at each stop.
- **Forever's own quests.** When Guidelime's step has no map position, it heads for
  [Questie](https://www.curseforge.com/wow/addons/questie)'s nearest map icon for the quest the step names
  (keep Guidelime's window open).
- **Nearest bank, inn or vendor.** `/gpath go bank` heads for the bank you can reach quickest, counting flights
  and boats, then goes back to your Guidelime step once you get there. Also `ah`, `inn`, `mail`, `repair`,
  `flight`, `trainer`, `food`, `drink`, `ammo`, `reagents`, profession trainers like `mining`, and
  everything else in Questie's town services list.
- **Corpse runs.** While dead it heads for your corpse.

### Needs

- WoW: Forever
- [Guidelime](https://www.curseforge.com/wow/addons/guidelime) and a guide for it
- [Questie](https://www.curseforge.com/wow/addons/questie)

### Commands

| Command | What it does |
| --- | --- |
| `/gpath` | turn it on or off |
| `/gpath go bank` | head for the nearest bank (or `ah`, `inn`, `mail`, `repair`, `trainer`, ...); `/gpath go` alone stops |
| `/gpath marker`, `dots`, `minimap`, `worldmap` | turn one part on or off |
| `/gpath status` | what it is doing and why |
| `/gpath replan` | work the route out again |
| `/gpath probe` | measure the camera, for better ground dots |
| `/gpath spacing`, `range`, `size`, `height`, `fov` | ground dot tuning |

### Good to know

- This is a beta. Paths exist for the Eastern Kingdoms and Kalimdor; anywhere else the marker points straight
  at the step.
- Boat and zeppelin times are estimates, and a ship that has just left means a wait.
- It never changes Guidelime or Questie; it only reads where they point.
- Found a spot where the route goes wrong? Note the zone, where you stood and where it tried to send you, and
  post it in the comments.
