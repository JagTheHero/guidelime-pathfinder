# Guidelime Pathfinder

## 0.3.0 (beta)

First public release.

- Walks you to Guidelime's current step along real walkable paths in the Eastern Kingdoms and Kalimdor, around
  mountains and through city gates instead of in a straight line.
- Moves the game's own waypoint marker from corner to corner along the path, draws the path on the world map
  and minimap, and (experimental) as dots on the ground.
- Follows floors and tunnels: Ironforge's halls, bridges over rivers, buildings with upper floors.
- Trips: takes the flight paths you have found (and highlights where to fly on the flight map), boats, zeppelins,
  Thunder Bluff's lifts, the Deeprun Tram and the Teldrassil portal, and says what to do at each stop.
- Forever's own quests that Guidelime has no map position for: heads for Questie's nearest map icon for the
  quest the step names (keep Guidelime's window open).
- `/gpath go bank` (or ah, inn, mail, repair, flight, trainer, food, mining, ...): heads for the nearest one
  you can use, counting flights and boats, then back to your Guidelime step once you get there.
- While dead, heads for your corpse.
