# Guidelime Pathfinder

## 0.4.0 (beta)

- Routes no longer step off bridges and piers: every shortcut in the path data is checked to be a straight
  walk, and narrow walkways and water cost more, so a route takes the bridge deck or the street instead of a
  ledge you have to hit exactly or a swim.
- Every line in the path data is also walked yard by yard along the ground. Lines that leave it (off the side of a
  bridge, over a ledge or a steep rock) are left out where there is another way, or replaced by the walk around:
  about 60% fewer such lines than before, and about 70% fewer that cross a drop midway.
- Routes end where the NPC stands: the path data has a point on every walkable level at each quest giver,
  quest object and town service (from Questie's data), so a route to someone on a pier or dock ends on it,
  not in the water beside it, and a route from the water leads back to land.
- Turn-ins and quest givers: Guidelime's spot is checked against Questie's data. A few yards off, the route
  goes to the NPC's exact spot; far off (moved on Forever), it goes to the NPC and says so.
- Questie fallback: a step's icons say what it does with each quest, so a turn-in goes to the turn-in (or the
  quest's finisher while objectives are left), not to the quest giver of another quest with the same name
  (Darkshore's beached sea turtles).
- After a `/reload` the ground height under you is where it was, not a guess (under the Great Forge's walkway).
  After a flight you are on the flight master's platform (Orgrimmar's tower), not on the ground under it.
- Long straight runs: the path data has long straight edges where the shortest walk really runs straight
  (across the Barrens, down a valley), and the search counts a little for every leg, so of two routes about
  as long you get the one with fewer, longer legs: line yourself up and run.
- Routes go around hostile mobs near your level like around a traffic jam: every yard inside a mob's aggro
  range costs more (more for orange and red mobs, elites and patrols, less for green ones, nothing for gray),
  so a route skirts a camp when the way around is not much longer and still goes through when it is. Mobs,
  their levels, aggro ranges and patrol paths come from the CMaNGOS classic database.
- NPCs and objects stand at their exact height (from the CMaNGOS classic database), so a route to a quest
  giver on a tower, a pier or an upper floor ends on that level.
- The world map trail shows only the way still ahead of you, in outlined dots that stand out on any map;
  the minimap trail uses them too. After updating, restart the game once (a `/reload` does not load new pictures).
- License: GNU General Public License version 3 or later (the CMaNGOS data is GPL-3.0).

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
