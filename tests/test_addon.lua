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

-- slash commands do not error
for _, cmd in ipairs({ "status", "dots", "dots", "fov 95", "fov 0", "help" }) do SlashCmdList.GUIDELIMEPATHFINDER(cmd) end
check(true, "slash commands run")

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
