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
local t0 = os.clock()
local ns = M.LoadAddon(dir, "Guidelime_Pathfinder")
print(string.format("     data loaded in %.0f ms, Lua memory %.0f MB", (os.clock() - t0) * 1000, collectgarbage("count") / 1024))
M.Fire("ADDON_LOADED", "Guidelime_Pathfinder")

local function route(instance, sx, sy, tx, ty)
	local result, done = nil, false
	local c0 = os.clock()
	ns.Graph.FindPath(instance, sx, sy, tx, ty, false, function(p) result, done = p, true end)
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
	if p then
		local ratio = len / direct
		check(ratio <= maxRatio, string.format("%s: %d corners, %.0f yd walk vs %.0f direct (x%.2f), %.0f ms CPU over %d frames",
			name, p.n, len, direct, ratio, ms, frames))
	else
		check(false, string.format("%s: no path (%.0f ms)", name, ms))
	end
end
if dump then dump:close() end
print(string.format("     Lua memory after searches %.0f MB", collectgarbage("count") / 1024))

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
