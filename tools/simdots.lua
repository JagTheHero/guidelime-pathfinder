-- Walks routes through the addon's own code (tests/mock_wow.lua) and writes where it puts the player's height and
-- every ground dot, for `navbuild simtruth` to check against the navmesh.
-- usage: lua51 tools/simdots.lua <addon dir> <routes.txt> <out.tsv> [side yards]   (run from the repository root)
--   side: walk that far beside the route line (left on odd routes, right on even ones), where the ground is
--   routes.txt: instance sx sy tx ty sz name (tools/simroutes.py; sz the start's height or nan)
-- Output lines (HereBeDragons coordinates):
--   R route instance name corners: x y z ...      a planned route (again after every replan)
--   P route step x y along pz k ax ay n cx cy ...  the player: distance along the route (at the route line's point
--                                                  ax, ay beside them), height the addon tracks, the corner the marker
--                                                  is on, and the n corners of the dots' own way to the end of the leg
--   D route step along x y z                       a ground dot: yards along the dots' line from the player
--   U route step along x y z                       a dot Dots.lua leaves out: over no known ground
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
local SIDE = tonumber(arg[4] or "0")
local MAX_REPLANS = 4 -- a route that keeps replanning (a target in a pocket the graph cannot reach) stops there
local STALL_STEPS = 60 -- a walk beside the route that gets no further along it for this many steps (going back and
-- forth at a corner) stops there
local routeId, failed, walked, offGraph, stuck, stalled = 0, 0, 0, 0, 0, 0

local function pointAhead(p, i, t, d)
	local x, y = ns.PointOnSeg(p, i, t)
	while i < p.n do
		local nx, ny = p.x[i + 1], p.y[i + 1]
		local L = math.sqrt((nx - x) ^ 2 + (ny - y) ^ 2)
		if L >= d then
			local u = L > 0 and d / L or 0
			return x + (nx - x) * u, y + (ny - y) * u, math.atan2(nx - x, ny - y)
		end
		d = d - L
		x, y = nx, ny
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
	if not (p and p.graph) then
		failed = failed + 1
	elseif p.n > 1 and math.sqrt((p.x[2] - p.x[1]) ^ 2 + (p.y[2] - p.y[1]) ^ 2) > 25 then
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
			local x, y, facing = pointAhead(p, p.seg, p.segT or 0, SPEED * DT)
			if not facing then break end
			-- beside the line, where there is ground on the line's level (else on it)
			local side = SIDE * (routeId % 2 == 1 and -1 or 1)
			local ox, oy = x - side * math.cos(facing), y + side * math.sin(facing)
			local lz = ns.player.z
			if side ~= 0 and lz then
				local _, fell, lost = ns.Graph.Walk(inst, x, y, lz, ox, oy)
				if fell or lost then ox, oy = x, y end
			end
			M.px, M.py, M.facing = ox, oy, facing
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
				local lc = {}
				for _, c in ipairs(ns.LocalLeg(p, inst, M.px, M.py, pz) or {}) do lc[#lc + 1] = string.format("%.2f %.2f", c[1], c[2]) end
				out:write(string.format("P %d %d %.2f %.2f %.2f %.2f %d %.2f %.2f %d%s%s\n", routeId, step, M.px, M.py, along, pz or 0 / 0, p.k,
					ax, ay, #lc, #lc > 0 and " " or "", table.concat(lc, " ")))
				ns.SampleGround(p, inst, M.px, M.py, pz, ns.db.dotSpacing, ns.db.dotRange, function(dx, dy, dz, a, _, unsure)
					if a >= 2 then out:write(string.format("%s %d %d %.2f %.2f %.2f %.2f\n", unsure and "U" or "D", routeId, step, a, dx, dy, dz)) end
				end)
				if p.n - p.seg <= 1 and (p.segT or 0) > 0.95 then break end
			end
		end
	end
end
out:close()
io.stderr:write(string.format("%d routes walked, %d without a graph route, %d starting off the graph, %d stopped after %d replans, %d stalled, %d route records\n",
	walked, failed, offGraph, stuck, MAX_REPLANS, stalled, routeId))
