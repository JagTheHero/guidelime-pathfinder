-- Runs real routes on the packed graphs. Usage: lua51 tests/test_graph.lua <addon dir>
local print = function(...) io.write(table.concat({...}, " "), "\n") end
package.path = arg[0]:gsub("[^/]+$", "") .. "?.lua;" .. package.path
local M = require("mock_wow")
local dir = arg[1]
local fails = 0
local function check(cond, msg)
	if cond then print("ok   " .. msg) else fails = fails + 1; print("FAIL " .. msg) end
end

GuidelimeArrow = M.NewFrame()
GuidelimeData = {}
local ns = M.LoadAddon(dir, "Guidelime_Pathfinder")
M.Fire("ADDON_LOADED", "Guidelime_Pathfinder")
-- each continent's data addon loads the first time it is asked for
for _, inst in ipairs({ 0, 1 }) do
	local t0 = os.clock()
	collectgarbage("collect")
	local m0 = collectgarbage("count")
	local has = ns.Graph.Has(inst)
	collectgarbage("collect")
	check(has, string.format("continent %d's data loads when asked for: %.0f ms, %.0f MB of Lua memory", inst,
		(os.clock() - t0) * 1000, (collectgarbage("count") - m0) / 1024))
end

local function route(instance, sx, sy, tx, ty, sz)
	local result, done = nil, false
	local c0 = os.clock()
	ns.Graph.FindPath(instance, sx, sy, tx, ty, false, function(p) result, done = p, true end, sz)
	local frames = 0
	while not done and frames < 20000 do M.Step(1 / 60); frames = frames + 1 end
	local ms = (os.clock() - c0) * 1000
	if not result then return nil, ms, frames end
	local len = 0
	for i = 2, result.n do
		len = len + math.sqrt((result.x[i] - result.x[i - 1]) ^ 2 + (result.y[i] - result.y[i - 1]) ^ 2)
	end
	return result, ms, frames, len
end

-- HereBeDragons world coordinates: x = world Y, y = world X
local CASES = {
	{ "Northshire Abbey -> Goldshire", 0, -133, -8914, 62, -9465, 1.6 },
	{ "Goldshire -> Stormwind Trade District", 0, 62, -9465, 631, -8836, 1.8 },
	{ "Goldshire -> Westfall (Sentinel Hill)", 0, 62, -9465, 1037, -10508, 1.6 },
	{ "Goldshire -> Lakeshire", 0, 62, -9465, -2240, -9250, 1.8 },
	{ "Anvilmar (Coldridge) -> Kharanos", 0, 331, -6240, -511, -5604, 1.8 },
	{ "Razor Hill -> Orgrimmar gate", 1, -4743, 315, -4392, 1350, 1.6 },
	{ "Crossroads -> Ratchet", 1, -2650, -450, -3720, -955, 1.6 },
	{ "Dolanaar -> Darnassus", 1, 948, 9821, 2460, 9950, 1.8 },
}

local dump = os.getenv("PATH_DUMP") and io.open(os.getenv("PATH_DUMP"), "w")
-- HEIGHT_DUMP=file: every 4 yards along each route, the ground height the dots use and the straight-line height
local hdump = os.getenv("HEIGHT_DUMP") and io.open(os.getenv("HEIGHT_DUMP"), "w")
collectgarbage("collect")
for _, c in ipairs(CASES) do
	local name, inst, sx, sy, tx, ty, maxRatio = unpack(c)
	local p, ms, frames, len = route(inst, sx, sy, tx, ty)
	local direct = math.sqrt((tx - sx) ^ 2 + (ty - sy) ^ 2)
	if p and dump then
		dump:write(name, "\t", inst)
		for i = 1, p.n do dump:write(string.format("\t%.1f,%.1f", p.x[i], p.y[i])) end
		dump:write("\n")
	end
	if p and hdump then
		p.seg, p.segT = 1, 0
		ns.player.gx = nil
		local z0 = ns.TrackGround(p.x[1], p.y[1], inst)
		ns.SampleGround(p, inst, p.x[1], p.y[1], z0, 4, math.huge, function(x, y, z, along, lineZ)
			hdump:write(string.format("%s\t%d\t%.2f\t%.2f\t%.2f\t%.2f\n", name, inst, x, y, lineZ, z))
		end)
	end
	if p then
		local ratio = len / direct
		check(ratio <= maxRatio, string.format("%s: %d corners, %.0f yd walk vs %.0f direct (x%.2f), %.0f ms CPU over %d frames",
			name, p.n, len, direct, ratio, ms, frames))
	else
		check(false, string.format("%s: no path (%.0f ms)", name, ms))
	end
end
if dump then dump:close() end
if hdump then hdump:close() end

-- long straight runs: across the Barrens most of the way is in legs of 100 yards or more, the longest 300+
do
	local p, _, _, len = route(1, -2650, -450, -3720, -955)
	local longest, long = 0, 0
	for i = 2, p and p.n or 0 do
		local l = math.sqrt((p.x[i] - p.x[i - 1]) ^ 2 + (p.y[i] - p.y[i - 1]) ^ 2)
		longest = math.max(longest, l)
		if l >= 100 then long = long + l end
	end
	check(p and longest >= 300 and long >= len * 0.6, string.format(
		"Crossroads -> Ratchet runs straight: longest leg %.0f yd, %.0f%% of the way in legs of 100+ yd", longest, p and 100 * long / len or 0))
end

-- a dungeon's door down a pit: the Hall of Thanes (Questie: Ironforge 27.63, 47.83) has no height to go on; at
-- that spot the ground is 100 yards under the hall floor, so the route winds down to it from the Great Forge
do
	local p = route(0, -1166.4, -4808.5, -932.0, -4821.6, 502.5) -- standing at the forge
	local lowest = math.huge
	for i = 1, p and p.n or 0 do lowest = math.min(lowest, p.z[i]) end
	check(p and math.abs(p.z[p.n] - 399.5) < 5 and lowest > 395, string.format(
		"Great Forge -> Hall of Thanes: ends at the door down the pit (%.1f, %d corners)", p and p.z[p.n] or -1, p and p.n or 0))
end

-- hostile mobs as traffic: west of Kharanos the troggs and wolves are level 5-9. A level 8 Alliance player goes
-- around them for a slightly longer walk; at level 60 they are gray and the route is the plain one.
do
	local G = ns.Graph
	G.SetThreat(60, 1)
	local plain, _, _, plainLen = route(0, -324.3, -5619.9, -1213.5, -5587.5)
	local plainZones = plain and G.PathJam(0, plain) or -1
	G.SetThreat(8, 1)
	local inZones = plain and G.PathJam(0, plain) or -1
	local around, ms, _, aroundLen = route(0, -324.3, -5619.9, -1213.5, -5587.5)
	local after = around and G.PathJam(0, around) or -1
	check(plainZones == 0 and inZones > 100 and after < inZones * 0.25 and aroundLen and aroundLen < plainLen * 1.15,
		string.format("level 8 goes around Dun Morogh's mobs: %.0f -> %.0f yards in aggro zones, %.0f -> %.0f yd long (%.0f ms); none at level 60",
			inZones, after, plainLen or -1, aroundLen or -1, ms))
	G.SetThreat(8, 2)
	check(G.PathJam(0, plain) > 100, "the Horde gets the same troggs (hostile to both sides)")
	G.SetThreat(0, 0)
end
-- lifts: from Freewind Post's mesa to the floor of Thousand Needles, the floor up to the Barrens by the Great Lift,
-- Undercity up to the ruins of Lordaeron
for _, c in ipairs({
	{ "Freewind Post -> Thousand Needles floor", { instance = 1, x = -2498, y = -5404.6, z = 89.3 }, { instance = 1, x = -2470, y = -5300, z = -50 } },
	{ "Thousand Needles floor -> top of the Great Lift", { instance = 1, x = -1900, y = -4700, z = -50 }, { instance = 1, x = -1800, y = -4600, z = 85 } },
	{ "Undercity -> the ruins above", { instance = 0, x = 240, y = 1580, z = -41 }, { instance = 0, x = 250, y = 1640, z = 62 } },
}) do
	local trip = ns.Graph.PlanTrip(c[2], c[3], {})
	local lift
	for _, leg in ipairs(trip and trip.legs or {}) do lift = lift or leg.kind == "lift" end
	check(lift, string.format("%s takes the lift (%s)", c[1], trip and string.format("%.0f s", trip.cost) or "no trip"))
end
print(string.format("     Lua memory after searches %.0f MB", collectgarbage("count") / 1024))

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
