# Guidelime Pathfinder

## Unreleased

- The ground dots do not move on the ground when you walk. Before, each dot was a fixed distance from your
  character, and the full line moved with each step. Now each dot is a fixed distance from the end of the route.
  The minimap trail has the same correction.
- The dots do not move away from the ground when the marker is near. Before, the addon used a camera pivot height
  of 1.9 yards for all characters. The correct height changes with the character (1.68 yards on one test character).
  Now the addon measures the height while you play, each time the marker moves to the next corner. It uses the
  median of the last 15 results when it has 3 or more. A height that you set with `/gpath height` has priority.
- The dots do not shake on clients that give the player position in steps of 0.1 yards. The addon now fits a line
  through the positions of the last quarter second. On a test recording, the position error decreased from 0.030
  to 0.007 yards.
- The dots stay on the ground when you jump. The camera goes up when the character jumps, and the marker goes up
  with the camera, thus the marker cannot show the camera height. The addon calculates the jump height and puts the
  camera at half of it. This half is an estimate. `/gpath jump 0.6` changes it: use a larger number if the dots
  go up when you jump, and a smaller number if they go down. `/gpath jump off` stops this correction.
- New command `/gpath trace`. It records the camera data of each frame for 15 seconds. Use it to find the cause
  of dots that are not on the ground.
- Shortcuts. When you leave the route, the dots do not go back to the nearest point of the route. They go in a
  straight line to a point of the route that is ahead. The distance ahead is 3 times your distance from the
  route, up to 45 yards. Thus this point moves smoothly, and the line of dots does not jump from one state to
  another. This occurs only when you can walk the line and it does not go near more mobs. The marker moves to
  the corner after that point. The route does not change.
- The route search now finds the cheapest route each time. Before, it was a faster search, and its result changed
  with small changes of the start position.
- When you are far from the route, the addon makes a new plan. The new plan now goes back onto the old route,
  unless a different route is 15 percent or more cheaper. Before, a new plan frequently gave a different route.
  In a test of 128 new plans from 30 yards beside 8 routes, 28 plans left the old route before and 8 do now.
- The dots of a new route come in during 0.4 seconds.
- The dots now go 90 yards ahead by default (60 before), and `/gpath range` accepts up to 380 yards at the default
  spacing. If you used the addon before, your saved range stays: type `/gpath range 90`.
- The addon looks for your position farther along the route (80 yards, not only 4 legs). Thus the marker does not
  stay on a corner behind you when you cut across a bend that has many short legs.

## 0.7.3 (beta)

- Fixed a Lua error ("bad argument #1 ... GetAllTaxiNodes") when you open a flight master's map: the game gave no
  map for it, so 0.7.2 learned no flight paths and the "fly to" highlight did not come. It now reads the map of the
  continent you are on, and also the older flight map. Open a flight master's map once so your flight paths count.

## 0.7.2 (beta)

- Flight paths: routes only take the flight paths you have found. WoW: Forever's world map says every flight master
  is found (the other faction's too), so routes could send you to one you never visited. The add-on now learns yours
  from the flight map whenever you open it at a flight master, per character: open any flight master's map once
  after updating, and until then routes walk.
- The wrong floor in Ironforge: after a hearth, a teleport or a login, the add-on guesses which floor you are on,
  and in Ironforge's Military Ward it picked the mountainside 180 yards over the halls, so the route and the dots
  were up there. The guess now weighs each floor at your spot by the path points on it and where NPCs stand: on
  stacked floors around the world it picks the wrong one about a third less often (and the Military Ward's floor).
  A height saved by an older version is no longer restored after a /reload.

## 0.7.1 (beta)

- Fixed a Lua error ("bad argument #3 ... GetMapInfoAtPosition") after `/gpath go <dungeon>`: the route was set,
  but the line saying where the entrance is never came. The same error could hit a boat or zeppelin stop with no
  name in the path data. The entrance now names its zone as the map does (the Ruins of Lordaeron: Tirisfal Glades).

## 0.7.0 (beta)

- Dungeons: `/gpath go <dungeon>` heads for a dungeon's or battleground's entrance, with the whole trip there
  (flights, boats, the tram): `/gpath go deadmines`, `/gpath go ruins of lordaeron`, and WoW: Forever's own
  dungeons too. The entrances come from Questie; where a dungeon has several, it picks the quickest to reach.
- Map pins: a pin you place on the world map (Ctrl-click) is now a goal like Guidelime's step. The route goes there
  and the marker walks you to it corner by corner (it takes the pin over: the game has only one). Removing the
  marker drops the pin and goes back to Guidelime's step, and so does `/gpath go`.
- Reaching the end of a route no longer says "your own map pin takes over".

## 0.6.1 (beta)

- `/gpath go bank` in Stormwind takes you to Stormwind's bank, not Ironforge's. Routes to quest givers and town
  services now end where you can stand to talk to them (within 5 yards), not only on the ground right under them:
  Stormwind's bankers stand behind their counter, and the only path data under them was a sealed space below the
  bank's floor, so the bank looked out of reach. The same goes for anyone behind a counter, a desk or a rail.
- The dots lead you onto the route instead of cutting across to its next corner. The route's corners stay where
  they are (they were picked for their directions); the dots join the route a little ahead of your spot on it (as
  far ahead as you are off it, at most 12 yards), going around anything in the way. On the simulated walks, walking
  6 yards beside the route, about 40% fewer dots are off the ground, and on the route about as many as in 0.6.0.
- A trip to a goal down in a city counts the climb down to it, so from the Undercity's zeppelin tower it takes the
  lift down to the flight master.

## 0.6.0 (beta)

- Restart the game once after updating: the path data now comes as two more add-ons in the zip,
  Guidelime_Pathfinder_Azeroth and Guidelime_Pathfinder_Kalimdor, and only the continent you are on is loaded
  (about 50 MB of memory in the Eastern Kingdoms, 67 MB in Kalimdor, where 0.5.0 took 75 MB for both).
- Dots stop at the edge: the path data says where the ground ends between its points, measured on the game's
  collision surfaces to about a quarter of a yard, so dots no longer float up to 2 yards out past a ledge, a pit or
  the side of a walkway.
- Steep ground: the ground beside the walkable ground that is too steep to walk (an embankment, a hillside) is in the
  path data too, so your height is followed when you slide down a bank, and dots that cross a bit of it stay on it.
- Ramps: where a ramp or stairway rises off the ground, the ground under its low end (where nobody fits) is no
  longer taken for a floor, so your height follows you up the ramp (Darnassus, Ironforge).
- Caves under lakes are no longer taken for the lake's surface.
- The camera: on a slope or looking up from low down, the game pulls its camera in front of the ground behind you;
  the dots now do the same, instead of landing several yards off on hillsides.
- Lifts: the Great Lift, Freewind Post's lifts and Undercity's three lifts are in the routes, and a Thunder Bluff lift
  that was linked to the wrong landing is fixed. Walking up or down a cliff counts for the climb, so a route takes
  the lift where that is quicker.
- Checked against a simulated player who walks the game's collision surfaces like a real one (not through walls,
  not up slopes too steep, not off big drops): on the route, 99.5% of the dots are within a yard of the true ground
  (half of them within 6 cm), and walking 6 yards beside the route about half as many dots are off as in 0.5.0 in
  the Eastern Kingdoms.

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
