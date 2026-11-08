-- Walks routes through the addon's own code (tests/mock_wow.lua) with a player that walks on the game's collision
-- surfaces like a real one (`navbuild geoserve`: no walking through walls or up slopes too steep, no jumping off big
-- drops), and writes where the addon puts the player's height and every ground dot, for `navbuild simtruth` to check
-- against the collision surfaces.
-- usage: lua51 tools/simdots.lua <addon dir> <routes.txt> <out.tsv> <geo dir> [side yards]   (from the repository root)
--   geo dir: data/geo/<map> of the routes' map (one map per routes file)
--   side: walk that far beside the route line (left on odd routes, right on even ones) where a player can, else on it
--   routes.txt: instance sx sy tx ty sz name (tools/simroutes.py; sz the start's height or nan)
-- Output lines (HereBeDragons coordinates):
--   R route instance name corners: x y z ...      a planned route (again after every replan)
--   P route step x y along pz k ax ay tz j n cx cy ...  the player: distance along the route (at the route line's
--                                                  point ax, ay beside them), height the addon tracks, the corner the
--                                                  marker is on, the true height, and the n corners of the dots' own
--                                                  way onto the route, the last where it joins the route on its leg
--                                                  from corner j
--   D route step along x y z                       a ground dot: yards along the dots' line from the player
--   U route step along x y z                       a dot Dots.lua leaves out: over no known ground
--   B route step x y z why                         where a real player cannot walk on along the route line (why: a
--                                                  hole, drop, slope too steep, wall): the player is put on it there,
--                                                  and the addon told their height (it is no walk to follow)
package.path = "tests/?.lua;" .. package.path
local M = require("mock_wow")
GuidelimeArrow = M.NewFrame()
GuidelimeData = {}
local ns = M.LoadAddon(arg[1], "Guidelime_Pathfinder")
M.Fire("ADDON_LOADED", "Guidelime_Pathfinder")
M.Fire("PLAYER_LOGIN")
ns.db.dots = true

local out = assert(io.open(arg[3], "w"))
local SPEED, DT, MAX_STEPS = 7, 0.1, 2500
local SIDE = tonumber(arg[5] or "0")
local MAX_REPLANS = 4 -- a route that keeps replanning (a target in a pocket the graph cannot reach) stops there
local STALL_STEPS = 60 -- a walk that gets no further along the route for this many steps stops there
local LINE_DROP, SIDE_DROP = 6, 3 -- yards: the biggest drop a player following the route line / walking beside it takes
local OTHER_LEVEL = 5 -- yards off the route line's height beside it: on another level (a walkway over a ramp)
local routeId, failed, walked, offGraph, stuck, stalled, blocked = 0, 0, 0, 0, 0, 0, 0
local WHY = { [1] = "hole", [2] = "drop", [3] = "steep", [4] = "wall-low", [5] = "wall-high" } -- navbuild's WALK_*

-- the collision surfaces, from navbuild geoserve through a named pipe
local fifo = arg[3] .. ".fifo"
os.remove(fifo)
assert(os.execute("mkfifo '" .. fifo .. "'") == 0)
local geoIn = assert(io.popen("build/navbuild geoserve '" .. arg[4] .. "' - - > '" .. fifo .. "'", "w"))
local geoOut = assert(io.open(fifo, "r"))
local function geo(fmt, ...)
	geoIn:write(string.format(fmt, ...), "\n")
	geoIn:flush()
	local t = {}
	for v in geoOut:read("*l"):gmatch("%S+") do t[#t + 1] = tonumber(v) end
	return unpack(t)
end

-- the route line's point d yards ahead of (i, t): x, y, facing, the line's height there
local function pointAhead(p, i, t, d)
	local x, y, z = ns.PointOnSeg(p, i, t)
	while i < p.n do
		local nx, ny, nz = p.x[i + 1], p.y[i + 1], p.z[i + 1]
		local L = math.sqrt((nx - x) ^ 2 + (ny - y) ^ 2)
		if L >= d then
			local u = L > 0 and d / L or 0
			return x + (nx - x) * u, y + (ny - y) * u, math.atan2(nx - x, ny - y), z + (nz - z) * u
		end
		d = d - L
		x, y, z = nx, ny, nz
		i = i + 1
	end
	return x, y
end

local function startRoute(p, name)
	routeId = routeId + 1
	local parts = { "R", routeId, M.instance, (name:gsub("%s", "_")) }
	for i = 1, p.n do parts[#parts + 1] = string.format("%.2f %.2f %.2f", p.x[i], p.y[i], p.z and p.z[i] or 0) end
	out:write(table.concat(parts, " "), "\n")
end

for line in io.lines(arg[2]) do
	local inst, sx, sy, tx, ty, sz, name = line:match("^(%d+) (%S+) (%S+) (%S+) (%S+) (%S+) (.*)$")
	inst, sx, sy, tx, ty, sz = tonumber(inst), tonumber(sx), tonumber(sy), tonumber(tx), tonumber(ty), tonumber(sz)
	GuidelimeArrow.element = nil
	for _ = 1, 2 do M.Step(DT) end
	M.instance, M.px, M.py = inst, sx, sy
	M.zone = { id = 1411, left = sx + 4000, top = sy + 4000, w = 8000, h = 8000 }
	local pl = ns.player
	if sz == sz then pl.gx, pl.gy, pl.ginstance, pl.z = sx, sy, inst, sz else pl.gx, pl.z = nil, nil end
	GuidelimeArrow.element = { wx = tx, wy = ty, instance = inst }
	for _ = 1, 4000 do
		M.Step(0.05)
		if ns.path and ns.path.graph and not ns.planning then break end
	end
	local p = ns.path
	local th = p and p.graph and geo("n %.3f %.3f %.3f 6", sx, sy, sz == sz and sz or p.z[1])
	if not (p and p.graph) then
		failed = failed + 1
	elseif p.n > 1 and math.sqrt((p.x[2] - p.x[1]) ^ 2 + (p.y[2] - p.y[1]) ^ 2) > 25 or th ~= th then
		offGraph = offGraph + 1 -- a start on a scrap of ground the packer left out: a straight line to the graph
	else
		walked = walked + 1
		startRoute(p, name)
		local step, replans, best, bestStep = 0, 0, -1, 0
		while step < MAX_STEPS do
			p = ns.path
			if not p or not p.graph then break end
			if p.id ~= p.simId then
				if p.simId ~= false and step > 0 then
					replans = replans + 1
					if replans > MAX_REPLANS then stuck = stuck + 1 break end
					startRoute(p, name .. "_replan")
				end
				p.simId = p.id
			end
			local x, y, facing, lineZ = pointAhead(p, p.seg, p.segT or 0, SPEED * DT)
			if not facing then break end
			-- beside the line where a player can walk there, else back to it; where the line itself cannot be walked,
			-- on it anyway (B)
			local side = SIDE * (routeId % 2 == 1 and -1 or 1)
			if math.abs(th - lineZ) > OTHER_LEVEL then side = 0 end -- beside the route but on another level: back to it
			local ox, oy = x - side * math.cos(facing), y + side * math.sin(facing)
			local want = math.sqrt((ox - M.px) ^ 2 + (oy - M.py) ^ 2)
			local nx, ny, nh, share, why = geo("w %.3f %.3f %.3f %.3f %.3f %.1f", M.px, M.py, th, ox, oy, side ~= 0 and SIDE_DROP or LINE_DROP)
			if share * want < 0.5 * math.min(want, SPEED * DT) and side ~= 0 then
				want = math.sqrt((x - M.px) ^ 2 + (y - M.py) ^ 2)
				nx, ny, nh, share, why = geo("w %.3f %.3f %.3f %.3f %.3f %.1f", M.px, M.py, th, x, y, LINE_DROP)
			end
			if share * want < 0.5 * math.min(want, SPEED * DT) then
				blocked = blocked + 1
				out:write(string.format("B %d %d %.2f %.2f %.2f %s\n", routeId, step + 1, M.px, M.py, th, WHY[why] or why))
				nx, ny, nh = x, y, geo("n %.3f %.3f %.3f 6", x, y, lineZ)
				if nh ~= nh then nh = lineZ end
				-- no player gets there like that: the addon is told where they are, as if it had followed them
				ns.player.gx, ns.player.gy, ns.player.z = nx, ny, nh
			end
			M.px, M.py, M.facing, th = nx, ny, facing, nh
			M.Step(DT)
			step = step + 1
			p = ns.path
			if p and p.graph and p.seg then
				local along = p.len[p.seg] + (p.len[p.seg + 1] - p.len[p.seg]) * (p.segT or 0)
				if along > best + 1 or p.id ~= p.simBest then best, bestStep, p.simBest = along, step, p.id end
				if step - bestStep > STALL_STEPS then stalled = stalled + 1 break end
				local ax, ay = ns.PointOnSeg(p, p.seg, p.segT or 0)
				local ground = ns.player.z
				local pz = ground and (ns.Graph.GroundZ(inst, M.px, M.py, ground, 1) or ground)
				local lc, way, _, js = {}, ns.LocalLeg(p, inst, M.px, M.py, pz)
				for _, c in ipairs(way) do lc[#lc + 1] = string.format("%.2f %.2f", c[1], c[2]) end
				out:write(string.format("P %d %d %.2f %.2f %.2f %.2f %d %.2f %.2f %.2f %d %d %s\n", routeId, step, M.px, M.py, along, pz or 0 / 0, p.k,
					ax, ay, th, js, #lc, table.concat(lc, " ")))
				ns.SampleGround(p, inst, M.px, M.py, pz, ns.db.dotSpacing, ns.db.dotRange, function(dx, dy, dz, a, _, unsure)
					if a >= 2 then out:write(string.format("%s %d %d %.2f %.2f %.2f %.2f\n", unsure and "U" or "D", routeId, step, a, dx, dy, dz)) end
				end)
				if p.n - p.seg <= 1 and (p.segT or 0) > 0.95 then break end
			end
		end
	end
end
out:close()
geoIn:close()
geoOut:close()
os.remove(fifo)
io.stderr:write(string.format("%d routes walked, %d without a graph route, %d starting off the graph, %d stopped after %d replans, %d stalled, "
	.. "%d steps where the route line could not be walked, %d route records\n", walked, failed, offGraph, stuck, MAX_REPLANS, stalled, blocked, routeId))
