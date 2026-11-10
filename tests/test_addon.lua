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
-- and the game's camera runs into it
M.cameraGround = function(x, y, reach) return (ns.Graph.GroundZ(M.instance, x, y, M.pz, reach)) end
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

-- the field of view follows the cameraFov CVar
M.cvarFov, M.truePitch = 75, 0.25
for _ = 1, 3 do worst, count = dotError() end
check(count > 5 and worst < 1.5, string.format("dots match with cameraFov 75 (worst %.2f px)", worst))
M.cvarFov = 90

-- A marker nearer than the camera: two cameras put it on the same spot, the real one and its mirror looking
-- back from the far side of the player. The real one wins, also right after the camera looked the other way.
local function ahead(dist, ang) -- a straight-line path (no path data on instance 5)
	local a = M.facing + math.rad(ang)
	GuidelimeArrow.element = { wx = M.px + dist * math.sin(a), wy = M.py + dist * math.cos(a), instance = 5 }
	for _ = 1, 3 do M.Step(0.1) end
end
M.instance, M.pz = 5, 0
M.facing, M.trueYaw, M.truePitch, M.zoom = 3.79, 3.79, 0.28, 15
ahead(11.6, 3)
for _ = 1, 3 do worst, count = dotError() end
check(count > 0 and worst < 1.5, string.format("marker 11.6 yd ahead, camera 15 yd behind: the real camera (worst %.2f px)", worst))
M.trueYaw, M.truePitch = M.facing + math.pi - 0.2, 0.35 -- the camera swung round to the front
for _ = 1, 3 do dotError() end
M.trueYaw, M.truePitch = M.facing + 0.1, 0.28 -- and back behind
for _ = 1, 2 do worst, count = dotError() end
check(count > 0 and worst < 1.5, string.format("after looking at the character from the front: the real camera again (worst %.2f px)", worst))
local cases, bad, sweepWorst = 0, 0, 0
for _, zoom in ipairs({ 5, 12, 25 }) do
	for _, pitch in ipairs({ -0.1, 0.15, 0.35, 0.7, 1.1 }) do
		for _, off in ipairs({ -50, -20, 0, 20, 50 }) do
			for _, mk in ipairs({ { 7, 0 }, { 12, 30 }, { 20, -35 }, { 40, 10 } }) do
				if 1.9 + zoom * math.sin(pitch) > -0.5 then -- the game keeps the camera over the floor
					M.zoom, M.truePitch, M.trueYaw = zoom, pitch, M.facing + math.rad(off)
					ahead(mk[1], off + mk[2])
					worst, count = dotError()
					worst, count = dotError()
					if count > 0 then
						cases = cases + 1
						sweepWorst = math.max(sweepWorst, worst)
						if worst > 2 then bad = bad + 1 end
					end
				end
			end
		end
	end
end
check(cases > 150 and bad == 0, string.format("cameras turned up to 50 degrees from the facing, at any pitch and zoom: %d of %d off (worst %.1f px)", bad, cases, sweepWorst))
-- the camera swung round the character fast (mouse look), 20 degrees a frame
M.zoom, M.truePitch, M.trueYaw = 12, 0.35, M.facing
ahead(30, 0)
local swingBad, swingN, swingWorst = 0, 0, 0
for k = 1, 36 do
	M.trueYaw = M.facing + math.rad(20 * k)
	worst, count = dotError()
	if count > 0 then
		swingN, swingWorst = swingN + 1, math.max(swingWorst, worst)
		if worst > 2 then swingBad = swingBad + 1 end
	end
end
check(swingN >= 8 and swingBad == 0, string.format("camera swung round the character 20 degrees a frame: %d of %d frames off (worst %.1f px)", swingBad, swingN, swingWorst))
M.instance, M.trueYaw, M.truePitch, M.facing, M.zoom = 1, -0.2, 0.3, 0.4, 12
GuidelimeArrow.element = { wx = -150, wy = 300, instance = 1 }
for _ = 1, 3 do M.Step(0.1) end

-- looking up from low down: the ground behind the player pulls the game's camera in nearer than the zoom, and the
-- solved one with it (the Crossroads)
do
	local zone = M.zone
	M.instance, M.px, M.py, M.zoom = 1, -2650, -450, 20
	M.zone = { id = 1411, left = M.px + 2000, top = M.py + 2000, w = 4000, h = 4000 }
	M.pz = select(1, ns.Graph.GroundZ(1, M.px, M.py, ns.Graph.LikelyZ(1, M.px, M.py), 6)) or 0
	ns.player.gx, ns.player.gy, ns.player.ginstance, ns.player.z = M.px, M.py, 1, M.pz
	M.facing, M.trueYaw, M.truePitch = 0.4, 0.4, -0.1
	local tx, ty = M.px + 60 * math.sin(M.facing), M.py + 60 * math.cos(M.facing)
	GuidelimeArrow.element = { wx = tx, wy = ty, instance = 1 }
	for _ = 1, 2000 do
		M.Step(0.05)
		local p = ns.path
		if p and not ns.planning and math.abs(p.x[p.n] - tx) < 1 and math.abs(p.y[p.n] - ty) < 1 then break end
	end
	for _ = 1, 3 do worst, count = dotError() end
	check(M.camDist < M.zoom - 2 and count > 0 and worst < 2, string.format(
		"camera pulled in by the ground to %.1f of %d yd: %d dots match (worst %.2f px)", M.camDist, M.zoom, count, worst))
	M.zone = zone
end
M.instance, M.px, M.py, M.trueYaw, M.truePitch, M.facing, M.zoom = 1, 0, 0, -0.2, 0.3, 0.4, 12
GuidelimeArrow.element = { wx = -150, wy = 300, instance = 1 }
for _ = 1, 3 do M.Step(0.1) end

-- zoomed in to first person
M.zoom = 0
for _ = 1, 5 do worst, count = dotError() end
check(count > 0 and worst < 1.5, string.format("first-person camera (worst %.2f px)", worst))
M.zoom = 12

-- a map pin the player places is the goal: the route goes there and the marker (taking the pin over) leads the way
C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(1411, 0.1, 0.1))
local pinX, pinY = M.zone.left - 0.1 * M.zone.w, M.zone.top - 0.1 * M.zone.h
for _ = 1, 3 do M.Step(0.1) end
check(ns.service and ns.service.pin and math.abs(ns.goal.x - pinX) < 1 and math.abs(ns.goal.y - pinY) < 1 and ns.Marker.IsActive()
	and M.prints[#M.prints]:find("heading for your map pin", 1, true), "a map pin the player places becomes the goal, the marker leads there")
GuidelimeArrow.element = { wx = 50, wy = 500, instance = 1 }
for _ = 1, 3 do M.Step(0.1) end
check(ns.service and ns.service.pin and math.abs(ns.goal.x - pinX) < 1, "a new guide step does not take over from the pin")
C_Map.ClearUserWaypoint() -- the player removes the marker: the pin is dropped
for _ = 1, 3 do M.Step(0.1) end
wx, wy = M.WaypointWorld()
check(not ns.service and wx and math.abs(wx - 50) < 1 and math.abs(wy - 500) < 1, "removing the marker drops the pin: back to Guidelime's step")
C_Map.ClearUserWaypoint() -- and on Guidelime's step: it stays away until the next one
for _ = 1, 3 do M.Step(0.1) end
check(M.waypoint == nil, "removing the marker on a guide step: it stays away")
GuidelimeArrow.element = { wx = 60, wy = 520, instance = 1 }
for _ = 1, 3 do M.Step(0.1) end
wx, wy = M.WaypointWorld()
check(wx and math.abs(wx - 60) < 1 and math.abs(wy - 520) < 1, "next guide step brings the marker back")
-- Blizzard clears the waypoint at the route's end ("destination reached"): arriving, not the player removing it
SuperTrackedFrame = { OnDestinationReached = function() C_Map.ClearUserWaypoint() end, UpdateDistanceText = function() end }
M.Fire("ADDON_LOADED", "Blizzard_ObjectiveTracker")
local tx, ty = M.px + 20, M.py + 20
C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(M.zone.id, (M.zone.left - tx) / M.zone.w, (M.zone.top - ty) / M.zone.h))
for _ = 1, 3 do M.Step(0.1) end
M.px, M.py = tx - 8, ty - 8 -- 11 yd short of it: the marker on the route's last corner
for _ = 1, 3 do M.Step(0.1) end
local saidBefore = #M.prints
SuperTrackedFrame:OnDestinationReached(true)
for _ = 1, 3 do M.Step(0.1) end
check(ns.service and ns.service.pin and M.waypoint == nil and #M.prints == saidBefore, "destination reached near the pin: the marker stands back quietly, the pin stays the goal")
M.px, M.py = tx - 3, ty - 2
for _ = 1, 3 do M.Step(0.1) end
wx, wy = M.WaypointWorld()
check(not ns.service and (M.prints[#M.prints - 1] or ""):find("here: your map pin", 1, true) or (M.prints[#M.prints] or ""):find("here: your map pin", 1, true),
	"at the pin it says so (" .. (M.prints[#M.prints] or "") .. ")")
check(wx and math.abs(wx - 60) < 1 and math.abs(wy - 520) < 1, "then back to Guidelime's step")

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

-- what the step does with a quest picks the icon. Darkshore has five quests named "Beached Sea Turtle": a turn-in
-- goes to the turn-in, not to another one's quest giver on the beach nearby, and an accept the other way round.
GuidelimeWindow:Show()
GuidelimeWindow.steps = {}
for k in pairs(questFrames) do questFrames[k] = nil end
local function pct(wx, wy) return { (M.zone.left - wx) / M.zone.w * 100, (M.zone.top - wy) / M.zone.h * 100 } end
local quests, npcs, questLog = {}, {}, {}
local modules = {
	QuestieMap = { questIdFrames = questFrames },
	QuestiePlayer = { currentQuestlog = questLog },
	QuestieDB = {
		QueryQuestSingle = function(id, field) return quests[id] and quests[id][field] end,
		QueryNPCSingle = function(id, field) return npcs[id] and npcs[id][field] end,
		QueryObjectSingle = function() end,
	},
	ZoneDB = { GetUiMapIdByAreaId = function() return M.zone.id end, IsDungeonZone = function() return false end },
}
QuestieLoader = { ImportModule = function(_, name) return modules[name] end }
icon(7101, "Beached Sea Turtle", "available", 100, 200)
icon(7102, "Beached Sea Turtle", "complete", 50, 500)
local GOSSIP = "|TInterface\\GossipFrame\\%s:12|t"
local step = stepFrame(6, GOSSIP:format("ActiveQuestIcon") .. "Turn in |cFF59C4F1Beached Sea Turtle|r")
M.px, M.py = 0, 0
for _ = 1, 12 do M.Step(0.1) end
check(goalAt(50, 500), "turn-in: Questie's turn-in icon, not the quest giver of a quest with the same name nearer by")
step.textBox.text = GOSSIP:format("AvailableQuestIcon") .. "Accept |cFF59C4F1Beached Sea Turtle|r"
for _ = 1, 12 do M.Step(0.1) end
check(goalAt(100, 200), "accept: Questie's quest giver icon")
step.textBox.text = GOSSIP:format("UI-CheckBox-Check") .. "Accept |cFF59C4F1Beached Sea Turtle|r"
for _ = 1, 12 do M.Step(0.1) end
check(ns.path == nil, "a quest the step shows as done is not a target")
-- objectives left: Questie draws no turn-in icon yet; the quest's finisher in its database, if it is in the log
for k in pairs(questFrames[7102]) do _G[k] = nil end
questFrames[7102] = nil
quests[7102] = { name = "Beached Sea Turtle", finishedBy = { { 9101 } } }
npcs[9101] = { name = "Gwennyth Bly'Leggonde", spawns = { [148] = { pct(-300, 50) } } }
step.textBox.text = GOSSIP:format("IncompleteQuestIcon") .. "Turn in |cFF59C4F1Beached Sea Turtle|r"
for _ = 1, 12 do M.Step(0.1) end
check(ns.path == nil, "objectives left, quest not in the log: no target")
questLog[7102] = true
for _ = 1, 12 do M.Step(0.1) end
check(goalAt(-300, 50), "objectives left, quest in the log: heads for the quest's finisher")
M.prints = {}
SlashCmdList.GUIDELIMEPATHFINDER("status")
check(table.concat(M.prints, "\n"):find("turn-in for Beached Sea Turtle (Gwennyth Bly'Leggonde)", 1, true), "status names the finisher")
GuidelimeWindow.steps = {}

-- Guidelime's own spot for a turn-in or a quest giver, checked against Questie's: a few yards off, the NPC's own
-- spot (the route ends where it stands); far off (moved on WoW: Forever), the NPC, said once
quests[7103] = { finishedBy = { { 9102 } } }
npcs[9102] = { name = "Thundris Windweaver", spawns = { [148] = { pct(100, 200) } } }
GuidelimeArrow.element = { wx = 112, wy = 214, instance = M.instance, attached = { questId = 7103, t = "TURNIN", title = "Tools of the Highborne" } }
for _ = 1, 12 do M.Step(0.1) end
check(goalAt(100, 200) and ns.targetSource == "guidelime", "a Guidelime turn-in spot a few yards off: the NPC's own spot")
quests[7104] = { startedBy = { { 9103 } } }
npcs[9103] = { name = "Gubber Blump", spawns = { [148] = { pct(-300, 50) } } }
M.prints = {}
GuidelimeArrow.element = { wx = 50, wy = 500, instance = M.instance, attached = { questId = 7104, t = "ACCEPT", title = "Fruit of the Sea" } }
for _ = 1, 12 do M.Step(0.1) end
local note = "Guidelime's spot for Fruit of the Sea is 570 yd from Gubber Blump in Questie's data; heading there instead"
local count = 0
for _, line in ipairs(M.prints) do if line:find(note, 1, true) then count = count + 1 end end
check(goalAt(-300, 50) and count == 1, "a Guidelime quest giver spot far off: Questie's NPC, said once (" .. table.concat(M.prints, " / ") .. ")")
M.prints = {}
SlashCmdList.GUIDELIMEPATHFINDER("status")
check(table.concat(M.prints, "\n"):find(note, 1, true), "status says so too")
GuidelimeArrow.element = { wx = 50, wy = 500, instance = M.instance, attached = { questId = 7104, t = "ACCEPT", completed = true } }
for _ = 1, 3 do M.Step(0.1) end
check(goalAt(50, 500), "no check once Guidelime counts the quest element done")
GuidelimeArrow.element = nil
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

		local function mapDots() local n = 0 for _ in pairs(M.pins.map) do n = n + 1 end return n end
		local dotsBefore = mapDots()
		WorldMapFrame = M.NewFrame()
		WorldMapFrame:Show()
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
		for _ = 1, 11 do M.Step(0.1) end
		local last = p.len[p.n] - p.len[p.n - 1]
		check(mapDots() < dotsBefore and mapDots() <= math.ceil(last / 12) + 1, string.format(
			"world map trail: %d dots for the whole way, %d once at the last corner (%.0f yd to go)", dotsBefore, mapDots(), last))
		WorldMapFrame = nil

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

	-- running a freshly planned route, the camera swinging round behind at each corner, and the game showing the
	-- marker at the last corner for a frame after it moves on: every frame's dots on the true projection
	GuidelimeArrow.element = nil
	for _ = 1, 3 do M.Step(0.1) end
	M.px, M.py = -133, -8914
	GuidelimeArrow.element = { wx = 62, wy = -9465, instance = 0 }
	for _ = 1, 200 do
		M.Step(0.05)
		if ns.path and ns.path.graph then break end
	end
	local r = ns.path
	M.navLag, M.zoom, M.truePitch, M.trueYaw = true, 15, 0.35, nil
	local s, frames, shown, walkWorst, walkOff, i0 = 0, 0, 0, 0, 0, 1
	local function turn(a) return (a + math.pi) % (2 * math.pi) - math.pi end
	while r and s < math.min(r.len[r.n] - 5, 300) do
		s = s + 7 / 60
		while r.len[i0 + 1] < s do i0 = i0 + 1 end
		local u = (s - r.len[i0]) / (r.len[i0 + 1] - r.len[i0])
		M.px, M.py = r.x[i0] + (r.x[i0 + 1] - r.x[i0]) * u, r.y[i0] + (r.y[i0 + 1] - r.y[i0]) * u
		M.facing = math.atan2(r.x[i0 + 1] - r.x[i0], r.y[i0 + 1] - r.y[i0])
		M.trueYaw = M.trueYaw or M.facing
		M.trueYaw = M.trueYaw + math.max(-0.06, math.min(0.06, turn(M.facing - M.trueYaw) * 0.1))
		-- the camera alone (heights are tools/simdots.lua's to check): the player stands where the dots think
		M.ground = function(x, y) local z = ns.player.z return z and (ns.Graph.GroundZ(M.instance, x, y, z, 1) or z) end
		local w, c = dotError()
		frames = frames + 1
		if c > 0 and s > 3 then
			shown = shown + 1
			if w > 2 then walkOff = walkOff + 1 end
			walkWorst = math.max(walkWorst, w)
			if w > 2 and os.getenv("WALK_DEBUG") then print(string.format("  s %.1f err %.1f dots %d k %d pz %.2f est %.2f camera %.0f deg off the facing", s, w, c, ns.path.k, M.pz, ns.player.z or -1, math.deg(turn(M.trueYaw - M.facing)))) end
		end
	end
	-- (a frame where the tracked height jumps is off by that jump: tools/simdots.lua checks heights)
	check(r and shown > frames * 0.8 and walkOff <= shown * 0.01, string.format("running the route: dots on the true projection in %d of %d frames, %d frames over 2 px (worst %.1f px)", shown, frames, walkOff, walkWorst))
	M.navLag, M.zoom = false, 12
	M.ground = function(x, y)
		local z, guess = ns.Graph.GroundZ(M.instance, x, y, M.pz, 1)
		return z or guess
	end
end

-- Ironforge: the halls lie under walkable mountainside, and a walkway crosses over the Great Forge. With no
-- height to go on, the likely one is in the halls; after a /reload on the forge floor the player's height is the
-- floor, the route leaves through the halls, and the dots stay on the floor.
if ns.Graph.HasGround(0) then
	M.instance = 0
	M.zone = { id = 1455, left = 0, top = -4000, w = 3000, h = 3000 }
	M.px, M.py, M.pz = -1166.4, -4808.5, 502.5
	local likely = ns.Graph.LikelyZ(0, M.px, M.py)
	check(likely and likely < 600, string.format("Ironforge: the likely height is in the halls, not on the mountainside (%.1f)", likely or -1))
	-- the Military Ward by the Hot Coals: the mountainside over it has more path nodes close by (picked until 0.7.1)
	likely = ns.Graph.LikelyZ(0, -1216.9, -4961.1)
	check(likely and math.abs(likely - 501.8) < 3, string.format("Ironforge's Military Ward: the likely height is its floor (%.1f, the floor 501.8)", likely or -1))
	ns.player.gx, ns.player.gy, ns.player.ginstance, ns.player.z = M.px, M.py, 0, M.pz -- on the floor at the /reload
	M.Fire("PLAYER_LOGOUT")
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
	-- a height saved by another version is not restored after the /reload (0.7.1 put players in the Military Ward on
	-- the mountainside over it, and kept them there)
	M.px, M.py, M.pz = -1216.9, -4961.1, 501.8
	ns.db.ground = { 0, M.px, M.py, 684.2, "0.7.1" }
	ns.player.gx, ns.player.z = nil, nil
	for _ = 1, 3 do M.Step(0.1) end
	check(ns.player.z and math.abs(ns.player.z - 501.8) < 3, string.format("a height saved by an older version is not restored (%.1f, the floor 501.8)", ns.player.z or -1))
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
	-- WoW: Forever's world map says every flight master is found (isUndiscovered = false), the other faction's too
	M.taxiNodes = { [1414] = {
		{ nodeID = 25, name = "Crossroads, The Barrens", faction = 1, isUndiscovered = false },
		{ nodeID = 23, name = "Orgrimmar, Durotar", faction = 1, isUndiscovered = false },
		{ nodeID = 22, name = "Thunder Bluff, Mulgore", faction = 1, isUndiscovered = false },
	} }
	M.Fire("TAXI_NODE_STATUS_CHANGED")
	settle()
	check(ns.trip and not ns.trip.next, "the world map's flight masters do not count as found")
	-- the flight map does know: the player opens it at the Crossroads
	M.taxiAll = {
		{ nodeID = 25, name = "Crossroads, The Barrens", state = 0 },
		{ nodeID = 23, name = "Orgrimmar, Durotar", state = 1 },
		{ nodeID = 22, name = "Thunder Bluff, Mulgore", state = 2 },
	}
	M.taxiOpen = true
	M.Fire("TAXIMAP_OPENED", 1)
	M.taxiOpen = false
	M.Fire("TAXIMAP_CLOSED")
	local saved = ns.db.flights and ns.db.flights[UnitGUID("player")]
	check(saved and saved[25] and saved[23] and not saved[22], "the flight map's found flight masters are kept for this character")
	settle()
	l = ns.trip and ns.trip.next
	check(l and l.kind == "flight" and l.to.node == 23 and near(routeEnd(), l.from, 3), "both found: walk to the flight master, fly to Orgrimmar")
	M.guid = "Player-1-00000002"
	ns.KnownTaxi() -- (cached for a few seconds)
	check(not (ns.db.flights[M.guid]), "another character starts with none")
	-- the older taxi frame: no flight map nodes, slots by name and type
	local getAll = C_TaxiMap.GetAllTaxiNodes
	C_TaxiMap.GetAllTaxiNodes = nil
	M.taxiSlots, M.taxiTypes = { "Crossroads, The Barrens", "Orgrimmar, Durotar", "Thunder Bluff, Mulgore" }, { "CURRENT", "REACHABLE", "NONE" }
	M.taxiOpen = true
	M.Fire("TAXIMAP_OPENED", 1)
	M.taxiOpen = false
	M.Fire("TAXIMAP_CLOSED")
	saved = ns.db.flights[M.guid]
	check(saved and saved[25] and saved[23] and not saved[22], "the older taxi frame's found flight masters are kept too")
	C_TaxiMap.GetAllTaxiNodes, M.taxiSlots, M.taxiTypes, M.guid = getAll, nil, nil, nil
	M.Fire("TAXI_NODE_STATUS_CHANGED") -- with no flight map open: nothing read, nothing lost
	saved = ns.db.flights[UnitGUID("player")]
	check(saved and saved[25] and saved[23], "nothing is read while no flight map is open")
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
		local nx = ns.trip and ns.trip.next
		check(ns.trip and nx and nx.kind == "lift" and ns.path and ns.path.graph and ns.dest.instance == 0,
			"off the zeppelin: on to the goal, the flight master down in the city, by a lift" .. (nx and string.format(" (next: %s %s)", nx.kind, nx.name or "") or ""))
	end
	M.faction, M.taxiNodes, M.taxiSlots = nil, nil, nil

	-- town services: /gpath go bank heads for the quickest banker Questie knows (of the player's faction)
	-- instead of Guidelime's step, until there
	M.zones = {
		[1432] = { left = -1993.750, top = -4487.500, w = 2758.333, h = 1839.583, instance = 0, name = "Loch Modan" },
		[1453] = { left = 1722.920, top = -7995.830, w = 1737.504, h = 1158.340, instance = 0, name = "Stormwind City" },
		[1455] = { left = -713.591, top = -4569.241, w = 790.625, h = 527.604, instance = 0, name = "Ironforge" },
		[1458] = { left = 873.193, top = 1877.945, w = 959.375, h = 640.104, instance = 0, name = "Undercity" },
		[1436] = { left = 3016.667, top = -9400.000, w = 3500.000, h = 2333.333, instance = 0, name = "Westfall" },
		[1415] = { left = 16000.000, top = 7466.600, w = 35199.900, h = 23466.600, instance = 0, name = "Eastern Kingdoms" },
		[1420] = { left = 3033.333, top = 3837.500, w = 4518.750, h = 3012.500, instance = 0, name = "Tirisfal Glades", parent = 1415 },
	}
	local dungeons = { -- Questie's ZoneDB: name, other area ids, parent zone, entrances (area id, zone percent)
		[16611] = { "Ruins of Lordaeron", nil, 1497, { { 1497, 72.48, 11.33 } } }, -- WoW: Forever's own
		[1581] = { "The Deadmines", nil, 40, { { 40, 42.6, 71.8 } } },
		[3429] = { "Ruins of Ahn'Qiraj", nil, 1377, { { 1377, 36.5, 93.9 } } },
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
		ZoneDB = { GetUiMapIdByAreaId = function(_, a) return ({ [1519] = 1453, [1537] = 1455, [38] = 1432, [1497] = 1458, [40] = 1436 })[a] end,
			IsDungeonZone = function() return false end, GetDungeons = function() return dungeons end },
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
	check(ns.targetSource == "service" and p and p.graph and near(routeEnd(), sv, 15) and math.abs(p.z[p.n] - 504) < 10,
		string.format("the route walks to the banker, in Ironforge's halls (ends at height %.0f, the bank's floor 504)", p and p.z and p.z[p.n] or -1))
	go("go auction house")
	check(ns.service and ns.service.name == "Auctioneer Buckler", "go auction house: Ironforge's auctioneer (" .. said() .. ")")
	go("go ah")
	check(ns.service and ns.service.name == "Auctioneer Buckler", "go ah: the same")
	go("go ba")
	check(said():find("ba could be: bags, banker", 1, true), "a word that starts several names asks which (" .. said() .. ")")
	go("go banana")
	check(said():find("no banana in Questie's town services or dungeons; there are: auctioneer, bags, banker, innkeeper, or any dungeon", 1, true), "an unknown word lists them (" .. said() .. ")")
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
	-- Stormwind's bankers stand behind their counter, on ground too small for path nodes and over a sealed space
	-- under the floor: the route ends in front of the counter, in the bank's hall
	goTo(0, 600, -8860) -- the Trade District
	settle()
	go("go bank")
	sv = ns.service
	check(sv and sv.name == "Olivia Burnside" and said():find("in Stormwind City", 1, true), "Stormwind: its own bank, not Ironforge's (" .. said() .. ")")
	for _ = 1, 400 do
		M.Step(0.05)
		if ns.path and ns.path.graph and not ns.planning and near(routeEnd(), sv, 1) then break end
	end
	p = ns.path
	local stand = p and p.n > 1 and { x = p.x[p.n - 1], y = p.y[p.n - 1] }
	check(ns.targetSource == "service" and p and p.graph and near(stand, sv, 6) and math.abs(p.z[p.n] - 99.5) < 3,
		string.format("the route ends within talking range of the banker, on the bank's floor (height %.1f, the floor 99.5)", p and p.z and p.z[p.n] or -1))

	-- dungeons and battlegrounds: /gpath go <name> heads for the entrance
	go("go ruins")
	check(said():find("ruins could be: ruins of ahn'qiraj, ruins of lordaeron", 1, true), "go ruins: which ruins (" .. said() .. ")")
	go("go ruins of lordaeron")
	sv = ns.service
	check(sv and sv.label == "the Ruins of Lordaeron entrance" and math.abs(sv.x - 177.8) < 1 and math.abs(sv.y - 1805.4) < 1
		and said():find("Ruins of Lordaeron: the entrance in Tirisfal Glades, about %d+ min away"), "go ruins of lordaeron: its entrance, up over the Undercity in Tirisfal (" .. said() .. ")")
	settle()
	local nxt = ns.trip and ns.trip.next
	check(nxt and nxt.kind == "tram", "from Stormwind: the tram to Ironforge first (" .. (nxt and nxt.kind or "no trip") .. ")")
	go("go deadmines")
	sv = ns.service
	check(sv and sv.label == "The Deadmines entrance" and said():find("The Deadmines: the entrance in Westfall", 1, true), "go deadmines: The Deadmines (" .. said() .. ")")
	goTo(0, sv.x + 60, sv.y + 40) -- Moonbrook
	settle()
	p = ns.path
	local last = p and p.n > 1 and { x = p.x[p.n - 1], y = p.y[p.n - 1] }
	check(ns.targetSource == "service" and p and p.graph and near(last, sv, 15), "the route ends at the Deadmines' door")
	goTo(0, sv.x + 3, sv.y + 2, M.pz)
	for _ = 1, 3 do M.Step(0.1) end
	check(not ns.service and lastHint() == "here: The Deadmines entrance", "at the door it says so (" .. lastHint() .. ")")
	go("go ruins of lordaeron")
	go("go")
	check(not ns.service and said():find("stopped heading for the Ruins of Lordaeron entrance", 1, true), "go alone stops it (" .. said() .. ")")
	M.faction, M.zones, QuestieLoader, Questie = nil, nil, nil, nil
end

-- slash commands do not error
for _, cmd in ipairs({ "status", "dots", "dots", "fov 95", "fov 0", "help" }) do SlashCmdList.GUIDELIMEPATHFINDER(cmd) end
check(true, "slash commands run")

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
