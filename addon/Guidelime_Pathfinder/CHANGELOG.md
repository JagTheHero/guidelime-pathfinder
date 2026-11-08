# Guidelime Pathfinder

## 0.5.0 (beta)

- Ground dots stay on the ground: the path data now has the ground height every 2 yards on every level you can
  walk on (floors, bridges, decks, ramps, the water's surface where you swim), taken from the game's own collision
  surfaces. The dots follow it yard by yard from where you stand: up and down stairs, along a bridge and not the
  river under it, off a ledge where the way drops.
- Your own way to the next corner: the dots start at you and run to the corner you are heading for, around what is
  in the way (a drop, a wall, the other side of a house), instead of along the route line beside you.
- Down into dungeons: a route to a dungeon door under a city, like the Hall of Thanes under Ironforge's Great
  Forge, ends on the level the door is on and winds down the stairs and ramps to it.
- Where the ground under the way is not known (a slope too steep to walk, the last stretch to a spot off the
  paths), no dots are drawn rather than dots in the air.
- The dots are drawn where the game's camera really looks (the exact field of view, not its mirror image) and
  for the waypoint the game is showing.
- Checked on simulated walks against the game's collision surfaces (over two million dots): on the route, 99% of
  the dots are within a yard of the true ground along the way, half of them within 6 cm. The path data is about
  34 MB for the Eastern Kingdoms and 44 MB for Kalimdor.

## 0.4.0 (beta)

- Routes no longer step off bridges and piers: every shortcut in the path data is checked to be a straight
  walk, and narrow walkways and water cost more, so a route takes the bridge deck or the street instead of a
  ledge you have to hit exactly or a swim.
- Every line in the path data is also walked yard by yard along the ground. Lines that leave it (off the side of a
  bridge, over a ledge or a steep rock) are left out where there is another way, or replaced by the walk around:
  less than half as many such lines as before, and a third as many that cross a drop midway.
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
- Shorter, straighter routes: more long straight lines in the path data, direct lines between nearby corners
  that can see each other (no zigzag over a third corner), and no turning back at the start or just past the
  goal. Against the shortest possible walk, the extra walking is about halved (about 1.5% on average). The
  path data is about a fifth bigger.
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
