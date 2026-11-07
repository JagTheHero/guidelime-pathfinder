-- Runs Guidelime_Pathfinder against the mock API. Usage: lua51 tests/test_addon.lua <addon dir>
local print = function(...) io.write(table.concat({...}, " "), "\n") end
package.path = arg[0]:gsub("[^/]+$", "") .. "?.lua;" .. package.path
local M = require("mock_wow")
local dir = arg[1]
local fails = 0
local function check(cond, msg)
	if cond then print("ok   " .. msg) else fails = fails + 1; print("FAIL " .. msg) end
end

-- Guidelime's arrow frame with a target 300 yards north and 150 east of the player
GuidelimeArrow = M.NewFrame()
GuidelimeArrow.element = { wx = -150, wy = 300, instance = 1 }
GuidelimeData = {}

local ns = M.LoadAddon(dir, "Guidelime_Pathfinder")
-- the world's ground is the packed height map (tests/test_ground.lua checks it against the build's heights)
M.ground = function(x, y)
	local z, guess = ns.Graph.GroundZ(M.instance, x, y, M.pz, 1)
	return z or guess
end
M.Fire("ADDON_LOADED", "Guidelime_Pathfinder")
M.Fire("PLAYER_LOGIN")
for _ = 1, 5 do M.Step(0.05) end

check(ns.path ~= nil and ns.path.n == 2, "straight-line path to the Guidelime target")
local wx, wy = M.WaypointWorld()
check(wx and math.abs(wx + 150) < 1 and math.abs(wy - 300) < 1, "waypoint placed on the target")
check(M.superTracking, "waypoint is super-tracked")

-- ground dots: the solved camera must reproduce the true camera's projection
local function dotError()
	ns.Dots.record = {}
	M.Step(1 / 60)
	local worst, count = 0, 0
	for _, r in ipairs(ns.Dots.record) do
		local tx, ty = M.TrueProject(r[1], r[2], r[3])
		if tx then
			count = count + 1
			worst = math.max(worst, math.sqrt((tx - r[4]) ^ 2 + (ty - r[5]) ^ 2))
		end
	end
	ns.Dots.record = nil
	return worst, count
end

M.trueYaw, M.truePitch, M.facing = 0.1, 0.45, 0.4
local worst, count = 0, 0
for _ = 1, 10 do worst, count = dotError() end
check(count > 5, "dots drawn (" .. count .. ")")
check(worst < 1.5, string.format("dots match the true projection with the right fov (worst %.2f px)", worst))

-- wrong fov: dots still pinned near the marker but off elsewhere; calibration must fix it
M.trueFov = 100
worst = dotError()
print(string.format("     with fov 100 but assuming 90: worst %.1f px", worst))
M.mouselook = true
for i = 1, 40 do
	M.facing = 0.25 + 0.02 * math.sin(i)
	M.trueYaw = M.facing
	M.truePitch = 0.35 + 0.1 * math.cos(i * 0.7)
	M.Step(1 / 60)
end
M.mouselook = false
check(ns.db.calibF ~= nil, "field of view learned while mouse-steering")
if ns.db.calibF then
	local learned = math.deg(2 * math.atan(0.5 / ns.db.calibF))
	check(math.abs(learned - 100) < 1, string.format("learned fov %.2f (true 100)", learned))
end
M.trueYaw, M.truePitch = -0.2, 0.5
for _ = 1, 5 do worst, count = dotError() end
check(worst < 1.5, string.format("dots match after calibration (worst %.2f px, %d dots)", worst, count))

-- zoomed in to first person
M.zoom = 0
for _ = 1, 5 do worst, count = dotError() end
check(count > 0 and worst < 1.5, string.format("first-person camera (worst %.2f px)", worst))
M.zoom = 12

-- player's own pin takes over
C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(1411, 0.1, 0.1))
for _ = 1, 3 do M.Step(0.1) end
local ux = M.waypoint.position.x
check(math.abs(ux - 0.1) < 1e-9, "player's own pin is left alone")
GuidelimeArrow.element = { wx = 50, wy = 500, instance = 1 }
for _ = 1, 3 do M.Step(0.1) end
wx, wy = M.WaypointWorld()
check(math.abs(wx - 50) < 1 and math.abs(wy - 500) < 1, "next guide step brings the marker back")

-- target gone: marker cleared
GuidelimeArrow.element = nil
for _ = 1, 3 do M.Step(0.1) end
check(M.waypoint == nil, "marker cleared when Guidelime has no target")
SlashCmdList.GUIDELIMEPATHFINDER("status")
local said = table.concat(M.prints, "\n")
check(said:find("no path: Guidelime's current step has no map position", 1, true) ~= nil, "status says why there is no path")

-- Questie fallback: the step has no map position, but Questie has icons for the quest the step names
GuidelimeWindow = M.NewFrame()
GuidelimeWindow.pinnedStepsFrame = M.NewFrame()
GuidelimeWindow.steps = {}
local function stepFrame(i, text, checked)
	local f = M.NewFrame()
	f.visible, f.checked, f.parent = true, checked, GuidelimeWindow
	f.textBox = M.NewFrame()
	f.textBox.text = text
	GuidelimeWindow.steps[i] = f
	return f
end
local questFrames = {}
QuestieLoader = { ImportModule = function(_, name) if name == "QuestieMap" then return { questIdFrames = questFrames } end end }
local icons = 0
local function icon(questId, questName, kind, wx, wy, extra)
	icons = icons + 1
	local name = "QuestieFrame" .. icons
	local f = { data = { Id = questId, Type = kind, QuestData = { name = questName }, Name = "Kobold Vermin" },
		x = (M.zone.left - wx) / M.zone.w * 100, y = (M.zone.top - wy) / M.zone.h * 100, UiMapID = M.zone.id, miniMapIcon = false }
	for k, v in pairs(extra or {}) do f[k] = v end
	_G[name] = f
	questFrames[questId] = questFrames[questId] or {}
	questFrames[questId][name] = name
	return f
end
icon(7001, "Kobold Camp Cleanup", "monster", 100, 200)
icon(7001, "Kobold Camp Cleanup", "monster", -300, 50)
icon(7001, "Kobold Camp Cleanup", "monster", 5, 5).data.ObjectiveData = { Completed = true }
icon(7001, "Kobold Camp Cleanup", "monster", 2, 2, { miniMapIcon = true })
icon(7002, "Far Away Quest", "complete", 10, 10)
stepFrame(3, "|TInterface\\Icons\\a:12|t|cFF59C4F1Old Quest|r", true)
stepFrame(4, "|TInterface\\Icons\\b:12|t[7] |cFF59C4F1Kobold Camp Cleanup|r\n    - |Tx:12|t Kobold Vermin: 0/10")
local nextStep = stepFrame(5, "|cFF666666|TInterface\\Icons\\c:12|tTurn in Far Away Quest")
M.px, M.py = 0, 0
for _ = 1, 12 do M.Step(0.1) end
local function goalAt(x, y) return ns.goal.x and math.abs(ns.goal.x - x) < 1 and math.abs(ns.goal.y - y) < 1 and ns.path ~= nil end
check(goalAt(100, 200), "Questie fallback heads for the nearest objective icon of the active step's quest")
M.prints = {}
SlashCmdList.GUIDELIMEPATHFINDER("status")
said = table.concat(M.prints, "\n")
check(said:find("target from Questie", 1, true) and said:find("objective for Kobold Camp Cleanup", 1, true), "status names the Questie target")
M.px, M.py = -100, 125
for _ = 1, 12 do M.Step(0.1) end
check(goalAt(100, 200), "the pick stays put while another icon is only a little closer")
M.px, M.py = -250, 60
for _ = 1, 12 do M.Step(0.1) end
check(goalAt(-300, 50), "switches when another icon is much closer")
GuidelimeWindow.steps[4].checked = true
nextStep.textBox.text = "|TInterface\\Icons\\c:12|tTurn in |cFF59C4F1Far Away Quest|r"
for _ = 1, 12 do M.Step(0.1) end
check(goalAt(10, 10), "next active step: heads for the turn-in")
GuidelimeArrow.element = { wx = 50, wy = 500, instance = 1 }
for _ = 1, 3 do M.Step(0.1) end
check(goalAt(50, 500), "Guidelime's own position wins when the step has one")
GuidelimeArrow.element = nil
GuidelimeWindow:Hide()
for _ = 1, 12 do M.Step(0.1) end
check(ns.path == nil and ns.WhyNoTarget():find("open Guidelime's window", 1, true), "window closed: no fallback, and status says why")
GuidelimeWindow, QuestieLoader = nil, nil
for _ = 1, 12 do M.Step(0.1) end

-- real graph data: Northshire Abbey to Goldshire, then walk the route corner by corner
if ns.Graph.Has(0) then
	M.instance = 0
	M.zone = { id = 1429, left = 1000, top = -8000, w = 3000, h = 3000 }
	M.px, M.py = -133, -8914
	GuidelimeArrow.element = { wx = 62, wy = -9465, instance = 0 }
	for _ = 1, 200 do
		M.Step(0.05)
		if ns.path and ns.path.graph then break end
	end
	for _ = 1, 3 do M.Step(0.1) end
	local p = ns.path
	check(p and p.graph and p.n > 3, "graph route planned (" .. (p and p.n or 0) .. " corners)")
	if p and p.graph then
		wx, wy = M.WaypointWorld()
		check(math.abs(wx - p.x[p.k]) < 1 and math.abs(wy - p.y[p.k]) < 1, "marker on the next corner, not the target")
		local onCorner = true
		for i = 2, p.n - 1 do
			M.px, M.py = p.x[i], p.y[i]
			for _ = 1, 3 do M.Step(0.1) end
			wx, wy = M.WaypointWorld()
			if ns.path ~= p or math.abs(wx - p.x[i + 1]) > 1 or math.abs(wy - p.y[i + 1]) > 1 then onCorner = false end
		end
		check(onCorner, "marker steps to each next corner as the player walks")
		wx, wy = M.WaypointWorld()
		check(math.abs(wx - 62) < 1 and math.abs(wy + 9465) < 1, "last corner is the Guidelime target")

		-- dots on a slope: the corners ahead are higher or lower than the player, the marker is not
		local q = ns.path
		local j = math.max(2, q.k - 2)
		M.px, M.py = q.x[j], q.y[j]
		for _ = 1, 3 do M.Step(0.1) end
		local yaw = math.atan2(q.x[q.k] - M.px, q.y[q.k] - M.py)
		M.trueYaw, M.facing, M.truePitch = yaw, yaw, 0.4
		worst, count = 0, 0
		for _ = 1, 5 do worst, count = dotError() end
		check(count > 3 and worst < 1.5, string.format("dots on a slope match (worst %.2f px, %d dots, next corner %.1f yd higher)", worst, count, q.z[q.k] - M.pz))

		-- the dots sit on the ground under them, not on the straight line between corners
		ns.Dots.record = {}
		M.Step(1 / 60)
		local onGround, offLine, nd = 0, 0, #ns.Dots.record
		for _, r in ipairs(ns.Dots.record) do
			local z = r[3] - 0.05
			local fit, plain = ns.Graph.GroundZ(M.instance, r[1], r[2], z, 0)
			plain = fit or plain
			if plain and math.abs(plain - z) < 0.3 then onGround = onGround + 1 end
			offLine = math.max(offLine, math.abs(z - r[6]))
		end
		ns.Dots.record = nil
		check(nd > 3 and onGround == nd, string.format("dots are on the ground (%d of %d; up to %.1f yd off the straight line between corners)", onGround, nd, offLine))

		-- camera probe: walk back a bit so a path is active, then measure
		M.px, M.py = p.x[p.n - 2], p.y[p.n - 2]
		M.trueYaw, M.truePitch, M.facing = 2.4, 0.4, 2.4
		for _ = 1, 3 do M.Step(0.1) end
		local before = M.waypoint
		SlashCmdList.GUIDELIMEPATHFINDER("probe")
		for _ = 1, 400 do M.Step(1 / 60) end
		local pr = ns.db.probes and ns.db.probes[#ns.db.probes]
		check(pr and pr.result == "done" and #pr.points == 25 and M.screenshots == 1, "probe ran: 25 points and a screenshot")
		local worst, seen = 0, 0
		for _, pt in ipairs(pr and pr.points or {}) do
			local s = pt.s[#pt.s]
			local tx, ty = M.TrueProject(pt.w[1], pt.w[2], M.pz)
			if s and tx and s[3] == 1 and s[4] == 0 then
				seen = seen + 1
				worst = math.max(worst, math.sqrt((s[1] - tx) ^ 2 + (s[2] - ty) ^ 2))
			end
		end
		check(seen >= 10 and worst < 0.5, string.format("probe samples match where the game drew the marker (%d on screen)", seen))
		check(pr and pr.capture and #pr.capture.dots > 0, "probe captured the dots frame")
		wx, wy = M.WaypointWorld()
		local q = ns.path
		check(q and math.abs(wx - q.x[q.k]) < 1 and math.abs(wy - q.y[q.k]) < 1 and not ns.Marker.probing, "marker back on the path after the probe")

		-- probe with no guide target: height comes from the nearest path point
		GuidelimeArrow.element = nil
		for _ = 1, 3 do M.Step(0.1) end
		SlashCmdList.GUIDELIMEPATHFINDER("probe")
		for _ = 1, 400 do M.Step(1 / 60) end
		pr = ns.db.probes[#ns.db.probes]
		check(pr.result == "done" and pr.player.graphZ and math.abs(pr.points[1].w[3] - M.pz) < 5 and M.waypoint == nil,
			string.format("probe works without a guide target (height %.1f vs %.1f) and clears the marker after", pr.player.graphZ or -1, M.pz))
	end
end

-- Ironforge: the halls lie under walkable mountainside. After a /reload on the Great Forge floor the player's
-- height is the floor, the route leaves through the halls, and the dots stay on the floor.
if ns.Graph.HasGround(0) then
	M.instance = 0
	M.zone = { id = 1455, left = 0, top = -4000, w = 3000, h = 3000 }
	M.px, M.py, M.pz = -1166.4, -4808.5, 502.5
	ns.player.gx, ns.player.z = nil, nil
	GuidelimeArrow.element = { wx = -1400, wy = -5300, instance = 0 } -- southwest, where the mountainside is shorter
	for _ = 1, 200 do
		M.Step(0.05)
		if ns.path and ns.path.graph then break end
	end
	for _ = 1, 3 do M.Step(0.1) end
	local q = ns.path
	check(ns.player.z and math.abs(ns.player.z - 502.5) < 3, string.format("Ironforge: the player's height is the forge floor (%.1f)", ns.player.z or -1))
	check(q and q.graph and math.abs(q.z[1] - 502.5) < 8, string.format("Ironforge: the route starts in the halls (first corner at %.1f)", q and q.z[1] or -1))
	if q and q.graph then
		local yaw = math.atan2(q.x[q.k] - M.px, q.y[q.k] - M.py)
		M.trueYaw, M.facing, M.truePitch = yaw, yaw, 0.4
		for _ = 1, 3 do M.Step(1 / 60) end
		ns.Dots.record = {}
		M.Step(1 / 60)
		local nd, worst = #ns.Dots.record, 0
		for _, r in ipairs(ns.Dots.record) do worst = math.max(worst, math.abs(r[3] - M.pz)) end
		ns.Dots.record = nil
		check(nd > 3 and worst < 15, string.format("Ironforge: the dots stay in the halls (%d dots, at most %.1f yd from the floor)", nd, worst))
	end
end

-- trips: walk to where a lift, portal, boat, zeppelin or flight starts, say what to do there, wait out the ride,
-- then plan the rest from where it ends
if ns.Graph.Has(0) and ns.Graph.Has(1) then
	local function goTo(inst, x, y, z)
		M.instance, M.px, M.py, M.pz = inst, x, y, z or M.pz
		M.zone = { id = 1411, left = x + 2000, top = y + 2000, w = 4000, h = 4000 }
		-- walked there on this layer (z given) or arrived out of nowhere (a teleport: height from scratch)
		local pl = ns.player
		if z then pl.z, pl.gx, pl.gy, pl.ginstance = z, x, y, inst else pl.gx, pl.z = nil, nil end
	end
	local function settle()
		for _ = 1, 200 do
			M.Step(0.05)
			if ns.path and ns.path.graph and not ns.planning then break end
		end
		for _ = 1, 3 do M.Step(0.1) end
	end
	local function near(p, q, r) return p and q and math.sqrt((p.x - q.x) ^ 2 + (p.y - q.y) ^ 2) < r end
	local function lastHint() return M.hints and M.hints[#M.hints] or "" end
	local function routeEnd() local p = ns.path return p and { x = p.x[p.n], y = p.y[p.n] } end

	-- Thunder Bluff: the city's mesas are reached only by lift
	M.faction = "Horde"
	goTo(1, -400, -1300)
	GuidelimeArrow.element = { wx = 29.9, wy = -1197.0, instance = 1 } -- the flight master on the mesa
	settle()
	local l = ns.trip and ns.trip.next
	check(l and l.kind == "lift" and l.name == "up", "Thunder Bluff: up the lift (" .. (l and ns.TripText(ns.trip) or "no trip") .. ")")
	check(l and near(routeEnd(), l.from, 3) and ns.path.graph, "Thunder Bluff: the route walks to the lift")
	if l then
		goTo(1, l.from.x, l.from.y, l.from.z)
		for _ = 1, 3 do M.Step(0.1) end
		check(lastHint() == "take the lift up", "Thunder Bluff: at the lift it says to take it up (" .. lastHint() .. ")")
		goTo(1, l.to.x, l.to.y, l.to.z) -- the ride up: the height jumps to the top landing
		settle()
		local p = ns.path
		check(not ns.trip.next and p and p.graph and math.abs(p.z[1] - l.to.z) < 15,
			string.format("Thunder Bluff: at the top the route goes on across the mesa (starts at %.0f)", p and p.z[1] or -1))
	end

	-- Teldrassil to Darkshore: the portal down to Rut'theran Village, then the boat
	M.faction = "Alliance"
	goTo(1, 960, 9850)
	GuidelimeArrow.element = { wx = 558.4, wy = 6341.5, instance = 1 } -- Auberdine's flight master
	settle()
	l = ns.trip and ns.trip.next
	check(l and l.kind == "portal" and ns.path and ns.path.graph, "Teldrassil: the route walks to the portal (" .. (l and ns.TripText(ns.trip) or "no trip") .. ")")
	if l then
		goTo(1, l.to.x, l.to.y) -- through the portal
		settle()
		l = ns.trip.next
		check(l and l.kind == "boat" and l.name == "Auberdine" and near(routeEnd(), l.from, 3), "Rut'theran Village: on to the boat to Auberdine")
	end
	if l and l.kind == "boat" then
		goTo(1, l.from.x, l.from.y, l.from.z)
		for _ = 1, 3 do M.Step(0.1) end
		check(lastHint() == "take the boat to Auberdine", "at the dock it says to take the boat")
		goTo(1, l.from.x - 150, l.from.y - 300) -- out at sea
		for _ = 1, 20 do M.Step(0.1) end
		check(ns.riding and not ns.path and not M.waypoint, "on the boat: no route or marker, the trip waits")
		goTo(1, l.to.x, l.to.y)
		settle()
		check(ns.trip and not ns.trip.next and ns.path and ns.path.graph and not ns.riding, "off the boat: the route walks on to the goal")
	end

	-- a flight: from Crossroads to Orgrimmar once both flight masters are found
	M.faction = "Horde"
	goTo(1, -2570, -470)
	GuidelimeArrow.element = { wx = -4330, wy = 1660, instance = 1 }
	settle()
	check(ns.trip and not ns.trip.next, "no flight masters found: the way is walked")
	M.taxiNodes = { [1414] = {
		{ nodeID = 25, name = "Crossroads, The Barrens", faction = 1, isUndiscovered = false },
		{ nodeID = 23, name = "Orgrimmar, Durotar", faction = 1, isUndiscovered = false },
		{ nodeID = 22, name = "Thunder Bluff, Mulgore", faction = 1, isUndiscovered = true },
	} }
	M.Fire("TAXI_NODE_STATUS_CHANGED")
	settle()
	l = ns.trip and ns.trip.next
	check(l and l.kind == "flight" and l.to.node == 23 and near(routeEnd(), l.from, 3), "both found: walk to the flight master, fly to Orgrimmar")
	if l then
		goTo(1, l.from.x, l.from.y, l.from.z)
		for _ = 1, 3 do M.Step(0.1) end
		check(lastHint() == "fly to Orgrimmar, Durotar: talk to the flight master", "at the flight master it says where to fly (" .. lastHint() .. ")")
	end
	M.taxiSlots = { "Crossroads, The Barrens", "Orgrimmar, Durotar" }
	TaxiButton2 = { LockHighlight = function(b) b.lit = true end, UnlockHighlight = function(b) b.lit = false end }
	M.Fire("TAXIMAP_OPENED", 1)
	check(TaxiButton2.lit, "the taxi map highlights Orgrimmar")
	M.Fire("TAXIMAP_CLOSED")
	check(not TaxiButton2.lit, "and lets go when it closes")
	M.onTaxi = true
	for _ = 1, 3 do M.Step(0.1) end
	check(ns.flying and not ns.path, "flying: no route")
	M.onTaxi = false
	goTo(1, -4315.6, 1678.5)
	settle()
	check(ns.trip and not ns.trip.next and ns.path and ns.path.graph, "landed: the route walks on to the goal")

	-- another continent: the zeppelin from Orgrimmar to the Undercity
	goTo(1, -4600, 1450)
	GuidelimeArrow.element = { wx = 269, wy = 1568, instance = 0 } -- the Undercity's flight master
	settle()
	l = ns.trip and ns.trip.next
	check(l and l.kind == "zeppelin" and l.name == "Undercity" and near(routeEnd(), l.from, 3), "goal on another continent: walk to the zeppelin to the Undercity")
	if l then
		goTo(1, l.from.x, l.from.y, l.from.z)
		for _ = 1, 3 do M.Step(0.1) end
		goTo(0, l.to.x + 400, l.to.y - 300) -- over the Eastern Kingdoms
		for _ = 1, 20 do M.Step(0.1) end
		check(ns.riding and not ns.path, "riding: the new continent does not start a new plan")
		goTo(0, l.to.x, l.to.y)
		settle()
		check(ns.trip and not ns.trip.next and ns.path and ns.path.graph and ns.dest.instance == 0, "off the zeppelin: on to the goal")
	end
	M.faction, M.taxiNodes, M.taxiSlots = nil, nil, nil

	-- town services: /gpath go bank heads for the quickest banker Questie knows (of the player's faction)
	-- instead of Guidelime's step, until there
	M.zones = {
		[1432] = { left = -1993.750, top = -4487.500, w = 2758.333, h = 1839.583, instance = 0, name = "Loch Modan" },
		[1453] = { left = 1722.920, top = -7995.830, w = 1737.504, h = 1158.340, instance = 0, name = "Stormwind City" },
		[1455] = { left = -713.591, top = -4569.241, w = 790.625, h = 527.604, instance = 0, name = "Ironforge" },
	}
	local npcs = { -- Questie's name, friendlyToFaction and spawns ([areaId] = { { x, y } } in zone percent)
		[2455] = { "Olivia Burnside", "A", { [1519] = { { 64.3, 80.8 } } } },
		[2460] = { "Barnum Stonemantle", "A", { [1537] = { { 35.0, 58.4 } } } },
		[9001] = { "Horde Teller", "H", { [38] = { { 36.0, 48.0 } } } }, -- made up: a Horde banker in Thelsamar
		[8671] = { "Auctioneer Buckler", "A", { [1537] = { { 23.8, 71.8 } } } },
		[6734] = { "Innkeeper Hearthstove", "A", { [38] = { { 35.5, 48.4 } } } },
	}
	local function npc(id, field)
		local n = npcs[id]
		return n and ({ name = n[1], friendlyToFaction = n[2], spawns = n[3] })[field]
	end
	local modules = {
		QuestieDB = { QueryNPCSingle = npc, QueryObjectSingle = npc },
		ZoneDB = { GetUiMapIdByAreaId = function(_, a) return ({ [1519] = 1453, [1537] = 1455, [38] = 1432 })[a] end, IsDungeonZone = function() return false end },
		Townsfolk = { townsfolk = { Banker = { 2455, 2460, 9001 }, Auctioneer = { 8671 }, Innkeeper = { 6734 } }, professionTrainers = {} },
	}
	QuestieLoader = { ImportModule = function(_, name) return modules[name] end }
	Questie = { db = { char = { townsfolk = {}, vendorList = { Bags = { 6734 } } } } }
	local function said() return M.prints[#M.prints] or "" end
	local go = SlashCmdList.GUIDELIMEPATHFINDER

	M.faction = "Alliance"
	goTo(0, -2985, -5390) -- Thelsamar, Loch Modan
	GuidelimeArrow.element = { wx = -2950, wy = -5420, instance = 0 }
	settle()
	go("go bank")
	local sv = ns.service
	check(sv and sv.name == "Barnum Stonemantle" and said():find("nearest banker: Barnum Stonemantle in Ironforge, about %d+ min away"),
		"Thelsamar: the nearest bank for the Alliance is Ironforge's (" .. said() .. ")")
	for _ = 1, 2000 do -- a long search: about 2000 yards to the bank
		M.Step(0.05)
		if ns.path and ns.path.graph and not ns.planning and near(routeEnd(), sv, 15) then break end
	end
	local p = ns.path
	check(ns.targetSource == "service" and p and p.graph and near(routeEnd(), sv, 15) and math.abs(p.z[p.n] - sv.z) < 10,
		string.format("the route walks to the banker, in Ironforge's halls (ends at height %.0f, the bank's floor %.0f)", p and p.z and p.z[p.n] or -1, sv and sv.z or -1))
	go("go auction house")
	check(ns.service and ns.service.name == "Auctioneer Buckler", "go auction house: Ironforge's auctioneer (" .. said() .. ")")
	go("go ah")
	check(ns.service and ns.service.name == "Auctioneer Buckler", "go ah: the same")
	go("go ba")
	check(said():find("ba could be: bags, banker", 1, true), "a word that starts several names asks which (" .. said() .. ")")
	go("go banana")
	check(said():find("no banana in Questie's town services; there are: auctioneer, bags, banker, innkeeper", 1, true), "an unknown word lists them (" .. said() .. ")")
	go("go")
	check(not ns.service and said():find("back to Guidelime's step", 1, true), "go alone stops")
	M.faction = "Horde"
	go("go bank")
	check(ns.service and ns.service.name == "Horde Teller", "the Horde gets the Horde banker")
	M.faction = "Alliance"
	go("go inn")
	sv = ns.service
	check(sv and sv.name == "Innkeeper Hearthstove" and said():find("under a minute away", 1, true), "go inn: Thelsamar's inn (" .. said() .. ")")
	settle()
	goTo(0, sv.x + 4, sv.y + 3, M.pz)
	for _ = 1, 3 do M.Step(0.1) end
	check(not ns.service and lastHint() == "here: Innkeeper Hearthstove (innkeeper)" and ns.targetSource == "guidelime",
		"at the inn it says so and goes back to Guidelime's step (" .. lastHint() .. ")")
	M.faction, M.zones, QuestieLoader, Questie = nil, nil, nil, nil
end

-- slash commands do not error
for _, cmd in ipairs({ "status", "dots", "dots", "fov 95", "fov 0", "help" }) do SlashCmdList.GUIDELIMEPATHFINDER(cmd) end
check(true, "slash commands run")

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
