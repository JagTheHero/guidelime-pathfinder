-- Checks the packed walk grid against navbuild's (tests/ground_points.tsv, from tools/ground_points.py).
-- Usage: lua51 tests/test_ground.lua <addon dir>
local print = function(...) io.write(table.concat({...}, " "), "\n") end
package.path = arg[0]:gsub("[^/]+$", "") .. "?.lua;" .. package.path
local M = require("mock_wow")
local ns = M.LoadAddon(arg[1], "Guidelime_Pathfinder")
local fails = 0
local function check(cond, msg)
	if cond then print("ok   " .. msg) else fails = fails + 1; print("FAIL " .. msg) end
end

local points, missing, layers, wrong, worst = 0, 0, 0, 0, 0
for line in io.lines(arg[0]:gsub("[^/]+$", "") .. "ground_points.tsv") do
	if not line:find("^#") then
		local f = {}
		for v in line:gmatch("[^\t]+") do f[#f + 1] = tonumber(v) end
		local instance, x, y = f[1], f[2], f[3]
		-- only ground near kept path nodes is packed (pack.py drops tiny islands and open sea)
		if not ns.Graph.NearestZ(instance, x, y) then
			-- not packed
		elseif not ns.Graph.GroundZ(instance, x, y) then
			points, missing = points + 1, missing + 1
		else
			points = points + 1
			for i = 4, #f do
				layers = layers + 1
				local z = ns.Graph.GroundZ(instance, x, y, f[i], 0)
				local err = z and math.abs(z - f[i]) or math.huge
				-- quarter yards, and a smooth block's points within a quarter yard of the blend of its corners
				if err > 0.4 then wrong = wrong + 1 else worst = math.max(worst, err) end
			end
		end
	end
end
check(points > 1000 and missing <= points * 0.05, string.format("height map covers the ground next to path nodes (%d of %d points missing)", missing, points))
check(wrong == 0, string.format("every layer decodes to within 0.4 yd (%d of %d layers off, worst of the rest %.2f yd)", wrong, layers, worst))

-- between grid points: the layer continuing from a nearby height, not the one under or over it
local bridge = 0
for line in io.lines(arg[0]:gsub("[^/]+$", "") .. "ground_points.tsv") do
	local f = {}
	for v in line:gmatch("[^\t]+") do f[#f + 1] = tonumber(v) end
	if #f >= 5 and f[5] - f[4] > 4 then
		local lo = ns.Graph.GroundZ(f[1], f[2] + 1, f[3] + 1, f[4], 1.5)
		local hi = ns.Graph.GroundZ(f[1], f[2] + 1, f[3] + 1, f[5], 1.5)
		if lo and hi and math.abs(lo - f[4]) < 2.5 and math.abs(hi - f[5]) < 2.5 then bridge = bridge + 1 end
		if bridge >= 1 then break end
	end
end
check(bridge >= 1, "stacked layers: a yard off a grid point, both the lower and the upper layer are followed")

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
