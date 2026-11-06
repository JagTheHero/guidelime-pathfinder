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
		M.px, M.py, M.pz = q.x[j], q.y[j], q.z[j]
		for _ = 1, 3 do M.Step(0.1) end
		local yaw = math.atan2(q.x[q.k] - M.px, q.y[q.k] - M.py)
		M.trueYaw, M.facing, M.truePitch = yaw, yaw, 0.4
		worst, count = 0, 0
		for _ = 1, 5 do worst, count = dotError() end
		check(count > 3 and worst < 1.5, string.format("dots on a slope match (worst %.2f px, %d dots, next corner %.1f yd higher)", worst, count, q.z[q.k] - M.pz))

		-- camera probe: walk back a bit so a path is active, then measure
		M.px, M.py, M.pz = p.x[p.n - 2], p.y[p.n - 2], p.z[p.n - 2]
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

-- slash commands do not error
for _, cmd in ipairs({ "status", "dots", "dots", "fov 95", "fov 0", "help" }) do SlashCmdList.GUIDELIMEPATHFINDER(cmd) end
check(true, "slash commands run")

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
