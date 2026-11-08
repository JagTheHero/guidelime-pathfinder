local ADDON, ns = ...

-- Walkable-path graphs, one per continent (instance ID), generated offline from the game's terrain,
-- buildings and doodads (tools/navbuild.cpp builds a navmesh and the graph, tools/pack.py packs it). Each
-- continent's data is a load-on-demand addon of its own (DATA_ADDON), loaded the first time that continent is
-- asked for: only the one you are on takes memory.
-- Every edge is a straight line that was checked to be walkable (small props like trees aside), so a path
-- is just a list of corners. Data is packed into base-64 strings and read in place.
--
--   nodes: n records of 14 chars: x(3) y(3) z(3) flags(1: 1 indoor, 2 swim, 4 where an NPC or object stands) firstEdge(4)
--   edges: e records of 4 chars:  neighbour(3: its low 18 bits) flags(1: 1 swims, 2 crosses a narrow walkway;
--          above those 2 bits, the neighbour's bits above 18)
--   cells: c records of 10 chars: cellKey(4) firstNode(4) count(2)   (nodes are sorted by cell)
-- Coordinates are HereBeDragons world coordinates (x west-positive, y north-positive), stored as
-- (v + 17100) * 4; z as (z + 4000) * 4.

local Graph = {}
ns.Graph = Graph

local byte, floor, sqrt, abs, min, max, huge = string.byte, math.floor, math.sqrt, math.abs, math.min, math.max, math.huge
local yield, create, resume, status = coroutine.yield, coroutine.create, coroutine.resume, coroutine.status

local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DEC = {}
for i = 1, 64 do DEC[byte(ALPHA, i)] = i - 1 end

local OFFSET_XY, OFFSET_Z, Q = 17100, 4000, 4
local NODE_W, EDGE_W, CELL_W = 14, 4, 10
local NODE_INDOOR, NODE_SWIM, NODE_POI = 1, 2, 4
-- edge cost multipliers by edge flag (low 3 bits), as navbuild's: 0 walk, 1 swim, 2 narrow walkway, 3 both
local MULT = { [0] = 1, [1] = 2.5, [2] = 2.5, [3] = 2.5 }
-- yards from the target within which a quest giver's, quest object's or service's nodes are its goals: navbuild
-- puts them where a player can stand to talk to it, up to 5 yards off (behind a counter: in front of it)
local POI_REACH = 6
local SWIM_GOAL = 15 -- yards a goal in the water counts as farther than one on land
local HEURISTIC_WEIGHT = 1.15
-- yards every leg costs on top of its length (navbuild's LEG_COST): of two routes about as long, the one with
-- fewer, longer straight legs, which is less to steer
local LEG_COST = 10
local BACK_COST = 4 -- per yard a route walks back over its first or last leg (behind the start, past the goal)
local LAYER_GAP = 8 -- yards of height between a node and the player before the node counts as another layer
local FRAME_BUDGET_MS = 4

local DATA_ADDON = { [0] = "Guidelime_Pathfinder_Azeroth", [1] = "Guidelime_Pathfinder_Kalimdor" }
local tried = {}
local graphs = setmetatable({}, { __index = function(t, instance)
	if tried[instance] or not DATA_ADDON[instance] then return end
	tried[instance] = true
	local load = C_AddOns and C_AddOns.LoadAddOn or LoadAddOn
	if load then pcall(load, DATA_ADDON[instance]) end
	return rawget(t, instance)
end })
local layersAt -- every walkable layer's height at a spot, from the walk grid (below)

local function v3(s, p)
	local a, b, c = byte(s, p, p + 2)
	return (DEC[a] * 64 + DEC[b]) * 64 + DEC[c]
end

local function v2(s, p)
	local a, b = byte(s, p, p + 1)
	return DEC[a] * 64 + DEC[b]
end

local function v4(s, p)
	local a, b, c, d = byte(s, p, p + 3)
	return ((DEC[a] * 64 + DEC[b]) * 64 + DEC[c]) * 64 + DEC[d]
end

-- called by the data addons (through the global GuidelimePathfinder, Core.lua)
function Graph.Register(instance, g)
	graphs[instance] = g
end

function Graph.Has(instance)
	local g = graphs[instance]
	return g ~= nil and (g.n or 0) > 0
end

-- Node ids are 1-based in Lua; the packed data is 0-based.
local function decodeNodes(g)
	if g.x then return end
	local s, n = g.nodes, g.n
	local gx, gy, gz, gf = {}, {}, {}, {}
	for i = 1, n do
		local p = (i - 1) * NODE_W + 1
		gx[i] = v3(s, p) / Q - OFFSET_XY
		gy[i] = v3(s, p + 3) / Q - OFFSET_XY
		gz[i] = v3(s, p + 6) / Q - OFFSET_Z
		gf[i] = DEC[byte(s, p + 9)]
		if i % 4000 == 0 and coroutine.running() then yield() end
	end
	g.x, g.y, g.z, g.f = gx, gy, gz, gf
end

local function edgeRange(g, id)
	local p = (id - 1) * NODE_W + 11
	local first = v4(g.nodes, p)
	local last = id < g.n and v4(g.nodes, p + NODE_W) or g.e
	return first, last -- 0-based, [first, last)
end

local function edgeAt(g, j)
	local p = j * EDGE_W + 1
	local c = DEC[byte(g.edges, p + 3)] -- 2 flag bits, then the neighbour's bits above its 18 in 3 chars
	local fl = c % 4
	return v3(g.edges, p) + 1 + (c - fl) * 65536, fl
end

local function edgeFlag(g, a, b)
	local first, last = edgeRange(g, a)
	for j = first, last - 1 do
		local v, fl = edgeAt(g, j)
		if v == b then return fl, j end
	end
end

local function cellNodes(g, cx, cy)
	local key = cx + cy * 1024
	local s, lo, hi = g.cells, 0, g.c - 1
	while lo <= hi do
		local mid = floor((lo + hi) / 2)
		local p = mid * CELL_W + 1
		local k = v4(s, p)
		if k == key then return v4(s, p + 4) + 1, v2(s, p + 8) end
		if k < key then lo = mid + 1 else hi = mid - 1 end
	end
end

-- Up to `count` nodes nearest to (x, y), as {id, distance} sorted by distance.
-- indoors (from IsIndoors()) breaks ties between stacked floors and caves under open ground.
-- The `count` nodes nearest to (x, y), as { id, distance, score }. With z (the player's ground height) nodes on
-- another layer score far worse: Ironforge's halls lie under walkable mountainside. Without z, the game's
-- indoor flag is a weak hint only (it says outdoors in Ironforge, whose halls are indoor in the map data).
local function nearest(g, x, y, count, indoors, z)
	local cs = g.cs
	local cx, cy = floor((x + OFFSET_XY) / cs), floor((y + OFFSET_XY) / cs)
	local found = {}
	for _, r in ipairs({ 1, 2, 4 }) do
		local fit = 0
		for dy = -r, r do
			for dx = -r, r do
				local first, cnt = cellNodes(g, cx + dx, cy + dy)
				if first then
					for id = first, first + cnt - 1 do
						local ddx, ddy = g.x[id] - x, g.y[id] - y
						local d = sqrt(ddx * ddx + ddy * ddy)
						local score = d
						if z then
							local dz = abs(g.z[id] - z)
							if dz > LAYER_GAP then score = score + 3 * dz else fit = fit + 1 end
						else
							if indoors ~= nil and ((g.f[id] % 2 == NODE_INDOOR) ~= indoors) then score = score + 3 end
							fit = fit + 1
						end
						found[#found + 1] = { id, d, score }
					end
				end
			end
		end
		if fit >= count or r == 4 then break end
		wipe(found)
	end
	table.sort(found, function(a, b) return a[3] < b[3] end)
	for i = count + 1, #found do found[i] = nil end
	return found
end

-- Binary heap of node ids keyed by f-score (parallel arrays).
local function heapPush(hk, hv, n, key, val)
	n = n + 1
	local i = n
	while i > 1 do
		local parent = floor(i / 2)
		if hk[parent] <= key then break end
		hk[i], hv[i] = hk[parent], hv[parent]
		i = parent
	end
	hk[i], hv[i] = key, val
	return n
end

local function heapPop(hk, hv, n)
	local topK, topV = hk[1], hv[1]
	local lastK, lastV = hk[n], hv[n]
	hk[n], hv[n] = nil, nil
	n = n - 1
	local i = 1
	while true do
		local c = i * 2
		if c > n then break end
		if c < n and hk[c + 1] < hk[c] then c = c + 1 end
		if lastK <= hk[c] then break end
		hk[i], hv[i] = hk[c], hv[c]
		i = c
	end
	if n > 0 then hk[i], hv[i] = lastK, lastV end
	return topK, topV, n
end

local function flag(f, bit) return floor(f / bit) % 2 == 1 end

-- Where a route may end near (tx, ty). A quest giver, quest object or town service has a node on every walkable
-- layer where it stands (a pier's deck, the ground under it, an inn's upper floor): all of them are goals, on tz's
-- layer if any is, and the search ends at the one it reaches cheapest. Anywhere else the nearest nodes, land
-- before water: the nearest node to a spot on a pier can be in the sea beside it. Without tz, nodes on a level the
-- ground at the spot itself has come first: a dungeon's door down a pit, not the hall floor at the pit's edge.
local OFF_SPOT = 30 -- yards a goal node on no level of the spot counts as farther
local function goalNodes(g, tx, ty, tz)
	local found = nearest(g, tx, ty, 24, nil, tz)
	local poi, onLayer = {}, {}
	for _, c in ipairs(found) do
		if c[2] <= POI_REACH and flag(g.f[c[1]], NODE_POI) then
			poi[#poi + 1] = c
			if c[3] == c[2] then onLayer[#onLayer + 1] = c end
		end
	end
	if #onLayer > 0 then return onLayer end
	if #poi > 0 then return poi end -- on the level of the NPC's height where known (tools/pois.py), so over a guessed tz
	local here = not tz and layersAt(g, tx, ty)
	for _, c in ipairs(found) do
		if flag(g.f[c[1]], NODE_SWIM) then c[3] = c[3] + SWIM_GOAL end
		if here and #here > 0 then
			local onOne = false
			for _, z in ipairs(here) do onOne = onOne or abs(g.z[c[1]] - z) <= LAYER_GAP end
			if not onOne then c[3] = c[3] + OFF_SPOT end
		end
	end
	table.sort(found, function(a, b) return a[3] < b[3] end)
	for i = 4, #found do found[i] = nil end
	return found
end

-- Hostile mobs as traffic (tools/mobs.py; packed by cell like the nodes):
--   mobs:   m records of 14 chars: x(3) y(3) z(3) minLevel(1) maxLevel(1) detection(1) wander(1) flags(1)
--   mcells: records of 10 chars: cellKey(4) firstMob(3) count(3)
-- flags: 1 hostile to the Alliance, 2 to the Horde, 4 elite, 8 a point on a patrol path. A mob that is not gray
-- to the player aggroes within its detection range less the levels the player is above it (more, up to 25 levels,
-- when it is above the player), at least 5 yards (CMaNGOS's Unit::GetAttackDistance), widened by its wander. Like
-- a traffic jam, each yard of route inside such a zone costs 1 + JAM x weight yards, at most JAM_MAX yards in
-- all, so routes go around camps near the player's level when the way around is not much longer (at most
-- JAM_MAX times the jammed stretch), and still through them when it is. The weight is by the mob's colour to the
-- player (CON: green, yellow, orange, red), times ELITE for an elite and PATROL for a point on a patrol path.
local JAM, JAM_MAX, ELITE, PATROL = 1.5, 4, 2.5, 0.5
local CON = { green = 0.3, yellow = 1, orange = 2, red = 4 }
local MOB_W, MOB_LAYER, ZONE_MAX = 14, 12, 64 -- record width; yards of height to another level; widest zone
local threat = { level = 0, side = 0 }

local function grayLevel(L)
	if L <= 5 then return 0 elseif L <= 39 then return L - 5 - floor(L / 10) elseif L <= 59 then return L - 1 - floor(L / 5) end
	return L - 9
end

local function conWeight(L, lvl)
	local d = lvl - L
	return d >= 5 and CON.red or d >= 3 and CON.orange or d >= -2 and CON.yellow or CON.green
end

-- Who routes are for: level (UnitLevel) and side (1 Alliance, 2 Horde; 0 ignores mobs).
function Graph.SetThreat(level, side)
	if threat.level ~= level or threat.side ~= side then
		threat.level, threat.side = level, side
		for _, g in pairs(graphs) do g.zones, g.mobZones, g.jam = nil, nil, nil end
	end
end

-- The aggro zones of the mobs packed in one 64-yard cell for the current threat: { x, y, z, radius, weight }.
local function mobZones(g, key)
	local zs = {}
	local s, lo, hi = g.mcells, 0, floor(#g.mcells / CELL_W) - 1
	while lo <= hi do
		local mid = floor((lo + hi) / 2)
		local p = mid * CELL_W + 1
		local k = v4(s, p)
		if k == key then
			local first, cnt = v3(s, p + 4), v3(s, p + 7)
			local L, gray, side, m = threat.level, grayLevel(threat.level), threat.side, g.mobs
			for i = first, first + cnt - 1 do
				local q = i * MOB_W + 1
				local fl = DEC[byte(m, q + 13)]
				local lvl = DEC[byte(m, q + 10)]
				if flag(fl, side) and lvl > gray then
					local r = max(5, DEC[byte(m, q + 11)] - max(-25, L - lvl)) + DEC[byte(m, q + 12)]
					zs[#zs + 1] = { v3(m, q) / Q - OFFSET_XY, v3(m, q + 3) / Q - OFFSET_XY, v3(m, q + 6) / Q - OFFSET_Z, min(r, ZONE_MAX),
						conWeight(L, lvl) * (flag(fl, 4) and ELITE or 1) * (flag(fl, 8) and PATROL or 1) }
				end
			end
			return zs
		end
		if k < key then lo = mid + 1 else hi = mid - 1 end
	end
	return zs
end

-- The aggro zones that reach into one 64-yard cell (zones are at most ZONE_MAX = one cell wide).
local function cellZones(g, cx, cy)
	local key = cx + cy * 1024
	local zs = g.zones[key]
	if zs then return zs end
	zs = {}
	local cs = g.cs
	local x0, y0 = cx * cs - OFFSET_XY, cy * cs - OFFSET_XY
	for dy = -1, 1 do
		for dx = -1, 1 do
			local k = key + dx + dy * 1024
			local own = g.mobZones[k]
			if not own then
				own = mobZones(g, k)
				g.mobZones[k] = own
			end
			for _, z in ipairs(own) do
				local nx, ny = min(max(z[1], x0), x0 + cs), min(max(z[2], y0), y0 + cs)
				if (nx - z[1]) ^ 2 + (ny - z[2]) ^ 2 < z[4] * z[4] then zs[#zs + 1] = z end
			end
		end
	end
	g.zones[key] = zs
	return zs
end

-- Extra cost of walking the segment a -> b (HBD x, y, z) through aggro zones: JAM x the weighted yards inside them.
local stamp = 0
local function segmentJam(g, ax, ay, az, bx, by, bz)
	local dx, dy = bx - ax, by - ay
	local l2 = dx * dx + dy * dy
	if l2 < 1e-4 then return 0 end
	local len = sqrt(l2)
	local cs = g.cs
	local x0, x1 = floor((min(ax, bx) + OFFSET_XY) / cs), floor((max(ax, bx) + OFFSET_XY) / cs)
	local y0, y1 = floor((min(ay, by) + OFFSET_XY) / cs), floor((max(ay, by) + OFFSET_XY) / cs)
	stamp = stamp + 1
	local inside = 0
	for cy = y0, y1 do
		for cx = x0, x1 do
			for _, z in ipairs(cellZones(g, cx, cy)) do
				if z[6] ~= stamp then
					z[6] = stamp
					local mx, my, r = z[1], z[2], z[4]
					local t = ((mx - ax) * dx + (my - ay) * dy) / l2
					local px, py = ax + t * dx - mx, ay + t * dy - my
					local h2 = r * r - (px * px + py * py)
					if h2 > 0 then
						local half = sqrt(h2) / len
						local t0, t1 = max(0, t - half), min(1, t + half)
						local tc = min(1, max(0, t))
						if t1 > t0 and abs(az + tc * (bz - az) - z[3]) < MOB_LAYER then inside = inside + (t1 - t0) * len * z[5] end
					end
				end
			end
		end
	end
	return min(JAM * inside, (JAM_MAX - 1) * len)
end

local function edgeJam(g, j, a, b)
	if threat.side == 0 or not g.mobs then return 0 end
	g.zones, g.mobZones, g.jam = g.zones or {}, g.mobZones or {}, g.jam or {}
	local c = g.jam[j]
	if not c then
		c = segmentJam(g, g.x[a], g.y[a], g.z[a], g.x[b], g.y[b], g.z[b])
		g.jam[j] = c
	end
	return c
end

-- Weighted yards of aggro zones along a path { x, y, z, n } for the current threat (for /gpath status and tests).
function Graph.PathJam(instance, p)
	local g = graphs[instance]
	if not g or not g.mobs or threat.side == 0 then return 0 end
	g.zones, g.mobZones = g.zones or {}, g.mobZones or {}
	local sum = 0
	for i = 2, p.n do sum = sum + segmentJam(g, p.x[i - 1], p.y[i - 1], p.z[i - 1], p.x[i], p.y[i], p.z[i]) / JAM end
	return sum
end

-- Yards of a -> b that b -> c walks back over, times BACK_COST: a U-turn at the first or the last corner.
local function back(ax, ay, bx, by, cx, cy)
	local ux, uy, vx, vy = bx - ax, by - ay, cx - bx, cy - by
	local lv = sqrt(vx * vx + vy * vy)
	if lv < 0.5 then return 0 end
	local d = -(ux * vx + uy * vy) / lv
	return d > 0 and min(d, lv) * BACK_COST or 0
end

local function search(g, sx, sy, tx, ty, indoors, sz, tz)
	decodeNodes(g)
	local gx, gy, gz = g.x, g.y, g.z
	local starts = nearest(g, sx, sy, 4, indoors, sz)
	local goals = goalNodes(g, tx, ty, tz)
	if #starts == 0 or #goals == 0 then return end

	local goalCost = {}
	for _, gl in ipairs(goals) do goalCost[gl[1]] = gl[2] end

	local gs, came, closed = {}, {}, {}
	local hk, hv, hn = {}, {}, 0
	local function h(id)
		local dx, dy = gx[id] - tx, gy[id] - ty
		return sqrt(dx * dx + dy * dy) * HEURISTIC_WEIGHT
	end
	for _, st in ipairs(starts) do
		gs[st[1]] = st[2]
		hn = heapPush(hk, hv, hn, st[2] + h(st[1]), st[1])
	end

	local best, bestId = huge, nil
	local expanded = 0
	while hn > 0 do
		local f, u
		f, u, hn = heapPop(hk, hv, hn)
		if f >= best then break end
		if not closed[u] then
			closed[u] = true
			local gu = gs[u]
			local ux, uy, uz = gx[u], gy[u], gz[u]
			local from = came[u]
			local fx, fy = from and gx[from] or sx, from and gy[from] or sy
			if goalCost[u] then
				local c = gu + goalCost[u] + back(fx, fy, ux, uy, tx, ty)
				if c < best then best, bestId = c, u end
			end
			local first, last = edgeRange(g, u)
			for j = first, last - 1 do
				local v, fl = edgeAt(g, j)
				if not closed[v] then
					local dx, dy, dz = gx[v] - ux, gy[v] - uy, gz[v] - uz
					local c = gu + sqrt(dx * dx + dy * dy + dz * dz) * (MULT[fl % 8] or 1) + LEG_COST + edgeJam(g, j, u, v)
					if not from then c = c + back(sx, sy, ux, uy, gx[v], gy[v]) end
					local old = gs[v]
					if not old or c < old then
						gs[v], came[v] = c, u
						hn = heapPush(hk, hv, hn, c + h(v), v)
					end
				end
			end
			expanded = expanded + 1
			if expanded % 300 == 0 then yield() end
		end
	end
	if not bestId then return end

	local ids = {}
	local id = bestId
	while id do
		table.insert(ids, 1, id)
		id = came[id]
	end
	return ids, best, expanded
end

-- Of the found path's corners, the cheapest chain by the search's own costs over direct graph edges (each an
-- already-checked straight walk) between corners up to SKIP apart: fewer, longer legs where the graph has them.
local SKIP = 10
local function smooth(g, ids)
	local n = #ids
	local best, from = { [1] = 0 }, {}
	for j = 2, n do
		local v = ids[j]
		for i = max(1, j - SKIP), j - 1 do
			local fl, e = edgeFlag(g, ids[i], v)
			if fl then
				local u = ids[i]
				local dx, dy, dz = g.x[v] - g.x[u], g.y[v] - g.y[u], g.z[v] - g.z[u]
				local c = best[i] + sqrt(dx * dx + dy * dy + dz * dz) * (MULT[fl % 8] or 1) + LEG_COST + edgeJam(g, e, u, v)
				if not best[j] or c < best[j] then best[j], from[j] = c, i end
			end
		end
	end
	local out, j = {}, n
	while j do
		table.insert(out, 1, ids[j])
		j = from[j]
	end
	return out
end

local function buildPath(g, ids, sx, sy, tx, ty)
	local p = { x = { sx }, y = { sy }, z = { g.z[ids[1]] }, n = 1 }
	for _, id in ipairs(ids) do
		p.n = p.n + 1
		p.x[p.n], p.y[p.n], p.z[p.n] = g.x[id], g.y[id], g.z[id]
	end
	p.n = p.n + 1
	p.x[p.n], p.y[p.n], p.z[p.n] = tx, ty, g.z[ids[#ids]]
	return p
end

-- One search at a time; a new request replaces the running one.
local job
local driver = CreateFrame("Frame")
driver:Hide()
driver:SetScript("OnUpdate", function(self)
	if not job then self:Hide() return end
	local t0 = debugprofilestop()
	repeat
		local ok, err = resume(job.co)
		if not ok then
			local j = job
			job = nil
			self:Hide()
			geterrorhandler()(err)
			j.cb(nil)
			return
		end
		if status(job.co) == "dead" then
			local j = job
			job = nil
			self:Hide()
			j.cb(j.result)
			return
		end
	until debugprofilestop() - t0 > FRAME_BUDGET_MS
end)

-- Calls cb(path) later with a path table {x, y, z, n} from (sx, sy) to (tx, ty), or cb(nil). sz, the player's
-- ground height if known, starts the path on the player's layer; tz, the target's, ends it on the target's.
function Graph.FindPath(instance, sx, sy, tx, ty, indoors, cb, sz, tz)
	local g = graphs[instance]
	if not g or (g.n or 0) == 0 then cb(nil) return end
	local j = { cb = cb }
	j.co = create(function()
		local t0 = debugprofilestop()
		local ids, cost, expanded = search(g, sx, sy, tx, ty, indoors, sz, tz)
		if ids then
			j.result = buildPath(g, smooth(g, ids), sx, sy, tx, ty)
			ns.Debug(format("path: %d corners, %.0f yd, %d nodes searched, %.0f ms", j.result.n, cost, expanded, debugprofilestop() - t0))
		else
			ns.Debug("no connected path found")
		end
	end)
	if job then job.cb(nil) end
	job = j
	driver:Show()
end

-- Height of the path point nearest to (x, y), or nil if none within 30 yards (used by /gpath probe).
function Graph.NearestZ(instance, x, y, indoors)
	local g = graphs[instance]
	if not g or (g.n or 0) == 0 then return end
	decodeNodes(g)
	local found = nearest(g, x, y, 1, indoors)
	if found[1] and found[1][2] < 30 then return g.z[found[1][1]] end
end

-- The walk grid (navbuild walkgrid, tools/walkpack.py): ground points every 2 yards, every walkable layer (bridges,
-- caves, floors, the surface of deep water), at the height of the surface the feet are on, by 64-yard cell. A smooth
-- 8-yard block keeps only its corner point: its other points are the blend of its four corners. Heights are in
-- quarter yards above -4000.
--   wcells: wc records of 9 chars: cellKey(4) offset(5) into walk, sorted by key
--   walk, per cell:
--     the 64 block corners (points 0, 4, ..., 28 of rows 0, 4, ..., 28) in serpentine order, as a chain
--     which blocks are kept in full: 11 chars of 6 bits, block j * 8 + i the (j * 8 + i)-th bit from the top
--     each full block in order: its 15 other points, serpentine over its 4 x 4 after the corner, as a chain
--       going on from the corner's height
--     extra layers: count(3), then per extra layer the point's index as a step from the last one's (1 char below
--       63, else 63 and the index(2)), and its height above the point's first + 2048 (2; 4095 then an absolute
--       height(3) when over 511 yards away)
--     edges: count(3), then per layer that ends before one of its 4 neighbours: the point's index as a step from
--       the last one's (1 char: the step - 1 below 62, else 62 and the index(2)), the edge bits (2: 3 bits each for
--       +x, -x, +y, -y from the low bits, how far it reaches in 2/7 yards, 7 all the way), and at a point with more
--       than one layer, the layer's rank from the lowest (1). A point with an edge is in a full block.
--   scells, steep: the steep grid, the same way without edges: ground within 12 yards of the walk grid's that is
--   too steep to walk (an embankment, a hillside) but under a player who slides on it
--   A chain codes each point as a step from the one before: 0-48 two points' steps a, b in -3..3 as
--   (a + 3) * 7 + b + 3; 49-55 one step of c - 52; 56-59 one step of -5, -4, 4 or 5; 60 no ground; 61 four points
--   without ground; 62 a step of the next char - 32; 63 an absolute height in the next 3 chars.
local WP, WB, WN, WS, WQ = 32, 4, 8, 2, 4
local MIDS = { [56] = -5, [57] = -4, [58] = 4, [59] = 5 }
local CORNERS, BLOCK_PTS = {}, {}
for bj = 0, WN - 1 do
	for k = 0, WN - 1 do CORNERS[#CORNERS + 1] = bj * WB * WP + (bj % 2 == 0 and k or WN - 1 - k) * WB end
end
for b = 0, WN * WN - 1 do
	local bj, bi, list = floor(b / WN), b % WN, {}
	for oj = 0, WB - 1 do
		for k = 0, WB - 1 do
			local oi = oj % 2 == 0 and k or WB - 1 - k
			if oj > 0 or oi > 0 then list[#list + 1] = (bj * WB + oj) * WP + bi * WB + oi end
		end
	end
	BLOCK_PTS[b] = list
end
local CACHE_CELLS = 256
-- a grid point fits a reference height within CLIMB + SLOPE x its distance + REACH x how far back the reference
-- was measured (52-degree slopes, the steepest walkable; STEEP_SLOPE on the steep grid, 70 degrees)
local CLIMB, SLOPE, REACH, STEEP_SLOPE = 1.3, 1.3, 0.4, 2.75
local NO_EDGE = 4095
-- the two grids' fields in the data and their caches
local WALK = { c = "wc", cells = "wcells", data = "walk", cache = "wcache", n = "wcached", edges = true }
local STEEP = { c = "sc", cells = "scells", data = "steep", cache = "scache", n = "scached", slope = true }
local WALK_STEP = 1 -- yards between the points Graph.Walk tries

local function v5(s, p)
	return v4(s, p) * 64 + DEC[byte(s, p + 4)]
end

-- decodes a chain of points into z (quarter-yard heights by point index) going on from height prev
local function chain(s, p, pts, z, prev)
	local k, n = 1, #pts
	while k <= n do
		local c = DEC[byte(s, p)]
		p = p + 1
		if c < 49 then
			prev = prev + floor(c / 7) - 3
			z[pts[k]] = prev
			prev = prev + c % 7 - 3
			z[pts[k + 1]] = prev
			k = k + 2
		elseif c < 60 then
			prev = prev + (c < 56 and c - 52 or MIDS[c])
			z[pts[k]] = prev
			k = k + 1
		elseif c == 60 then
			k = k + 1
		elseif c == 61 then
			k = k + 4
		elseif c == 62 then
			prev = prev + DEC[byte(s, p)] - 32
			z[pts[k]] = prev
			p, k = p + 1, k + 1
		else
			prev = v3(s, p)
			z[pts[k]] = prev
			p, k = p + 3, k + 1
		end
	end
	return p
end

local function walkCell(g, key, grid)
	local cache = g[grid.cache]
	if not cache then cache = {}; g[grid.cache], g[grid.n] = cache, 0 end
	local cell = cache[key]
	if cell ~= nil then return cell end
	local s, lo, hi, off = g[grid.cells], 1, g[grid.c] or 0, nil
	while lo <= hi do
		local mid = floor((lo + hi) / 2)
		local k = v4(s, (mid - 1) * 9 + 1)
		if k == key then off = v5(s, (mid - 1) * 9 + 5) break end
		if k < key then lo = mid + 1 else hi = mid - 1 end
	end
	cell = false
	if off then
		s = g[grid.data]
		local z, full, more = {}, {}, {}
		local p = chain(s, off + 1, CORNERS, z, nil)
		for c = 0, 10 do
			local v = DEC[byte(s, p + c)]
			for b = 0, 5 do
				if floor(v / 2 ^ (5 - b)) % 2 == 1 then full[c * 6 + b] = true end
			end
		end
		p = p + 11
		for b = 0, WN * WN - 1 do
			if full[b] then p = chain(s, p, BLOCK_PTS[b], z, z[floor(b / WN) * WB * WP + b % WN * WB]) end
		end
		local idx, extras = -1, v3(s, p)
		p = p + 3
		for _ = 1, extras do
			local gap = DEC[byte(s, p)]
			if gap < 63 then
				idx, p = idx + gap, p + 1
			else
				idx, p = v2(s, p + 1), p + 3
			end
			local list = more[idx] or {}
			more[idx] = list
			local dq = v2(s, p)
			if dq == 4095 then
				list[#list + 1] = v3(s, p + 2)
				p = p + 5
			else
				list[#list + 1] = z[idx] + dq - 2048
				p = p + 2
			end
		end
		cell = { z = z, full = full, more = more }
		if grid.edges then
			local n, edge = v3(s, p), nil
			p, idx = p + 3, -1
			for _ = 1, n do
				local gap = DEC[byte(s, p)]
				if gap < 62 then
					idx, p = idx + gap + 1, p + 1
				else
					idx, p = v2(s, p + 1), p + 3
				end
				local bits, rank = v2(s, p), 0
				p = p + 2
				if more[idx] then rank, p = DEC[byte(s, p)], p + 1 end
				edge = edge or {}
				edge[idx * 8 + rank] = bits
			end
			cell.edge = edge
		end
	end
	if g[grid.n] >= CACHE_CELLS then wipe(cache); g[grid.n] = 0 end
	cache[key], g[grid.n] = cell, g[grid.n] + 1
	return cell
end

-- The layers at walk grid point (sx, sy) (global 2-yard indices) in quarter yards: the first, and a list of the
-- others or nil. A point in a smooth block is the blend of its corners.
local function walkPoint(g, sx, sy, grid)
	grid = grid or WALK
	local cx, cy = floor(sx / WP), floor(sy / WP)
	local cell = walkCell(g, cx + cy * 1024, grid)
	if not cell then return end
	local i, j = sx - cx * WP, sy - cy * WP
	local oi, oj = i % WB, j % WB
	local z = cell.z
	if (oi == 0 and oj == 0) or cell.full[floor(j / WB) * WN + floor(i / WB)] then return z[j * WP + i], cell.more[j * WP + i] end
	local c00 = z[(j - oj) * WP + i - oi]
	if not c00 then return end
	local c10 = walkPoint(g, sx - oi + WB, sy - oj, grid) or c00
	local c01 = walkPoint(g, sx - oi, sy - oj + WB, grid) or c00
	local c11 = walkPoint(g, sx - oi + WB, sy - oj + WB, grid) or c00
	local fx, fy = oi / WB, oj / WB
	return c00 * (1 - fx) * (1 - fy) + c10 * fx * (1 - fy) + c01 * (1 - fx) * fy + c11 * fx * fy
end

-- of a point's layers, the one nearest ref (yards; the first without ref), or with below the highest at most ref
local function layer(first, more, ref, below)
	local h = first / WQ - OFFSET_Z
	if below and h > ref then h = nil end
	if more and ref then
		for _, q in ipairs(more) do
			local z = q / WQ - OFFSET_Z
			if below then
				if z <= ref and (not h or z > h) then h = z end
			elseif abs(z - ref) < abs(h - ref) then
				h = z
			end
		end
	end
	return h
end

layersAt = function(g, x, y)
	if not g.wc then return {} end
	local first, more = walkPoint(g, floor((x + OFFSET_XY) / WS + 0.5), floor((y + OFFSET_XY) / WS + 0.5))
	local out = {}
	if first then out[1] = first / WQ - OFFSET_Z end
	for _, q in ipairs(more or {}) do out[#out + 1] = q / WQ - OFFSET_Z end
	table.sort(out)
	return out
end

-- Every layer's height at the walk grid point nearest (x, y), lowest first.
function Graph.Layers(instance, x, y)
	local g = graphs[instance]
	return g and layersAt(g, x, y) or {}
end

function Graph.HasGround(instance)
	local g = graphs[instance]
	return g ~= nil and (g.wc or 0) > 0
end

-- Whether the walk grid's layer at height h at point (sx, sy) reaches (rx, ry) grid steps from it (each within
-- -1..1): as far as its edges say towards each side.
local function withinEdges(g, sx, sy, h, rx, ry)
	local cx, cy = floor(sx / WP), floor(sy / WP)
	local cell = walkCell(g, cx + cy * 1024, WALK)
	local edge = cell and cell.edge
	if not edge then return true end
	local idx = (sy - cy * WP) * WP + sx - cx * WP
	local more, rank = cell.more[idx], 0
	if more then
		local q = floor((h + OFFSET_Z) * WQ + 0.5)
		if cell.z[idx] < q then rank = 1 end
		for _, m in ipairs(more) do if m < q then rank = rank + 1 end end
	end
	local bits = edge[idx * 8 + rank]
	if not bits then return true end
	local cx3 = rx >= 0 and bits % 8 or floor(bits / 8) % 8
	local cy3 = ry >= 0 and floor(bits / 64) % 8 or floor(bits / 512) % 8
	return (cx3 == 7 or abs(rx) <= (cx3 + 0.5) / 7) and (cy3 == 7 or abs(ry) <= (cy3 + 0.5) / 7)
end

-- One grid's ground at (x, y) (see Graph.GroundZ); with edge (the walk grid), only within the edges of a point
-- that fits.
local function gridZ(g, grid, x, y, ref, reach, below, edge)
	if not g[grid.c] then return end
	local gx, gy = (x + OFFSET_XY) / WS, (y + OFFSET_XY) / WS
	local ix, iy = floor(gx), floor(gy)
	local fx, fy = gx - ix, gy - iy
	local slope = grid.slope and STEEP_SLOPE or SLOPE
	local sum, wsum, any, anyW, inside = 0, 0, 0, 0, not edge
	for c = 0, 3 do
		local dx, dy = c % 2, floor(c / 2)
		local w = (dx == 1 and fx or 1 - fx) * (dy == 1 and fy or 1 - fy)
		if w > 0 then
			local first, more = walkPoint(g, ix + dx, iy + dy, grid)
			local h = first and layer(first, more, ref, below)
			if h then
				any, anyW = any + w * h, anyW + w
				local d = WS * sqrt((dx - fx) ^ 2 + (dy - fy) ^ 2)
				if below or not ref or abs(h - ref) <= CLIMB + slope * d + REACH * (reach or 0) then
					sum, wsum = sum + w * h, wsum + w
					inside = inside or withinEdges(g, ix + dx, iy + dy, h, fx - dx, fy - dy)
				end
			end
		end
	end
	if wsum > 1e-3 and inside then return sum / wsum end
	if anyW > 1e-3 then return nil, any / anyW end
end

-- Ground height at (x, y), on the layer that continues from height `ref` measured `reach` yards away: the blend of
-- the four grid points around, each on its layer nearest ref, of those that fit ref (not the water under a bridge);
-- where the walk grid has none, the steep grid's (a player sliding down a bank). Returns nil, guess when none fits
-- ref (guess: the blend of the layers nearest ref), and nil without ground here. With below, the highest layer at
-- most ref at each point instead (where a fall lands).
function Graph.GroundZ(instance, x, y, ref, reach, below)
	local g = graphs[instance]
	if not g or not g.wc then return end
	local z, guess = gridZ(g, WALK, x, y, ref, reach, below)
	if below then
		local sz = gridZ(g, STEEP, x, y, ref, reach, true)
		return sz and (not z or sz > z) and sz or z
	end
	if z then return z end
	local sz, sguess = gridZ(g, STEEP, x, y, ref, reach)
	if sz then return sz end
	return nil, guess or sguess
end

-- The layer continuing from height z at the nearest of the walk grid points a step further out than the four around
-- (x, y): a deck, ramp or walkway the four around miss, at about the same height (not the ledge beside it). nil if
-- none of the 16 has one.
local BRIDGE_SLOPE = 0.4
local function layerNearby(g, x, y, z)
	local gx, gy = (x + OFFSET_XY) / WS, (y + OFFSET_XY) / WS
	local ix, iy = floor(gx), floor(gy)
	local best, bestD
	for sy = iy - 1, iy + 2 do
		for sx = ix - 1, ix + 2 do
			local d = WS * sqrt((sx - gx) ^ 2 + (sy - gy) ^ 2)
			if not bestD or d < bestD then
				local first, more = walkPoint(g, sx, sy)
				local h = first and layer(first, more, z)
				if h and abs(h - z) <= CLIMB + BRIDGE_SLOPE * d then best, bestD = h, d end
			end
		end
	end
	return best
end

-- Walks from (x0, y0) at height z0 to (x1, y1) a yard at a time like a player: up and down the ground the feet are
-- on (stairs, a bridge, not the river under it), falling where it drops away (no ground on its layer within a grid
-- step and a half), keeping the height over a hole. fn(x, y, z, yards, overHole, onSteep) at each step, if given,
-- can stop the walk by returning false. Returns the last height, whether the walk fell somewhere, and whether it crossed a hole or ran
-- into ground too high to climb (a wall, a cliff), and whether it went over ground too steep to walk (the steep
-- grid: a player slides down it). With edge (the dots and the ways they show), the walk grid's ground ends where its
-- edges say, not up to a grid step past them.
function Graph.Walk(instance, x0, y0, z0, x1, y1, fn, edge)
	local g = graphs[instance]
	if not g or not g.wc then return z0, false, true, false end
	local dx, dy = x1 - x0, y1 - y0
	local len = sqrt(dx * dx + dy * dy)
	local n = max(1, floor(len / WALK_STEP + 0.999))
	local z, fell, lost, steep = z0, false, false, false
	for k = 1, n do
		local t = k / n
		local x, y = x0 + dx * t, y0 + dy * t
		local nz = gridZ(g, WALK, x, y, z, 0, nil, edge) or (not edge and layerNearby(g, x, y, z))
		local onSteep = false
		if not nz then
			nz = gridZ(g, STEEP, x, y, z, 0)
			if nz then steep, onSteep = true, true end
		end
		local hole = false
		if not nz then
			-- the highest ground under the feet on either grid; at an edge, under the layer that ends there
			local ref = edge and z - CLIMB or z + CLIMB
			local wz, sz = gridZ(g, WALK, x, y, ref, 0, true), gridZ(g, STEEP, x, y, ref, 0, true)
			nz = wz and sz and max(wz, sz) or wz or sz
			if nz then fell = true else nz, lost, hole = z, true, true end
		end
		z = nz
		if fn and fn(x, y, z, len * t, hole, onSteep) == false then break end
	end
	return z, fell, lost, steep
end

-- A walkable way on the walk grid from (x0, y0) at height z0 to (x1, y1) at height z1 when the straight line is not
-- (it falls off something or runs into a wall): grid points joined to their 8 neighbours where the ground steps at
-- most CLIMB + SLOPE x the step (stairs, slopes up to 52 degrees), searched within LOCAL_MARGIN yards around the
-- two ends, then straightened to a corner wherever the straight walk on would fall or run out of ground.
-- Returns the corners after the start, the last one (x1, y1), or nil when there is no such way nearby.
local LOCAL_MARGIN, LOCAL_MAX = 16, 3000 -- yards around the ends; most points searched
local DIRS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
function Graph.LocalPath(instance, x0, y0, z0, x1, y1, z1)
	local g = graphs[instance]
	if not g or not g.wc then return end
	local sx0, sy0 = floor((x0 + OFFSET_XY) / WS + 0.5), floor((y0 + OFFSET_XY) / WS + 0.5)
	local sx1, sy1 = floor((x1 + OFFSET_XY) / WS + 0.5), floor((y1 + OFFSET_XY) / WS + 0.5)
	local m = LOCAL_MARGIN / WS
	local lox, hix, loy, hiy = min(sx0, sx1) - m, max(sx0, sx1) + m, min(sy0, sy1) - m, max(sy0, sy1) + m
	-- a node is a grid point on one layer: its key keeps layers 4 yards apart apart
	local function key(sx, sy, h) return (sx * 20000 + sy) * 2048 + floor(h / 4) % 2048 end
	local function hdist(sx, sy) return WS * sqrt((sx - sx1) ^ 2 + (sy - sy1) ^ 2) end
	local first, more = walkPoint(g, sx0, sy0)
	local h0 = first and layer(first, more, z0) or z0
	if abs(h0 - z0) > CLIMB + SLOPE * WS then h0 = z0 end
	local k0 = key(sx0, sy0, h0)
	local gs, came, hs, px, py = { [k0] = 0 }, {}, { [k0] = h0 }, { [k0] = sx0 }, { [k0] = sy0 }
	local hk, hv, hn = {}, {}, 0
	hn = heapPush(hk, hv, hn, hdist(sx0, sy0), k0)
	local closed, found, searched = {}, nil, 0
	while hn > 0 and searched < LOCAL_MAX do
		local _, u
		_, u, hn = heapPop(hk, hv, hn)
		if not closed[u] then
			closed[u] = true
			searched = searched + 1
			local ux, uy, uh = px[u], py[u], hs[u]
			if ux == sx1 and uy == sy1 and abs(uh - z1) <= CLIMB + SLOPE * WS then found = u break end
			for _, d in ipairs(DIRS) do
				local nx, ny = ux + d[1], uy + d[2]
				if nx >= lox and nx <= hix and ny >= loy and ny <= hiy then
					local step = (d[1] ~= 0 and d[2] ~= 0) and WS * 1.4142 or WS
					local f, mo = walkPoint(g, nx, ny)
					local h = f and layer(f, mo, uh)
					if h and abs(h - uh) <= CLIMB + SLOPE * step then
						local v = key(nx, ny, h)
						local c = gs[u] + step
						if not closed[v] and (not gs[v] or c < gs[v]) then
							gs[v], came[v], hs[v], px[v], py[v] = c, u, h, nx, ny
							hn = heapPush(hk, hv, hn, c + hdist(nx, ny), v)
						end
					end
				end
			end
		end
	end
	if not found then return end
	local pts = {}
	local v = found
	while v do
		table.insert(pts, 1, { px[v] * WS - OFFSET_XY, py[v] * WS - OFFSET_XY, hs[v] })
		v = came[v]
	end
	pts[#pts] = { x1, y1, z1 }
	-- straighten: from each corner on to the farthest point the straight walk reaches without falling or getting lost
	local corners, ax, ay, az, i = {}, x0, y0, z0, 1
	while i <= #pts do
		local j = #pts
		while j > i do
			local z, fell, lost, steep = Graph.Walk(instance, ax, ay, az, pts[j][1], pts[j][2], nil, true)
			if not fell and not lost and not steep and abs(z - pts[j][3]) <= CLIMB then break end
			j = j - 1
		end
		corners[#corners + 1] = { pts[j][1], pts[j][2] }
		ax, ay, az = pts[j][1], pts[j][2], pts[j][3]
		i = j + 1
	end
	return corners
end

-- Most likely ground height at (x, y) when nothing else is known (login, teleport): the layer most path nodes
-- within 40 yards are on, nearer nodes counting more. Ironforge's halls win over the mountainside above them.
-- The nodes where NPCs stand do not vote: each has one on every layer over its spot, the mountainside too.
-- At a flight master (where a flight lands) it is the flight master's: Orgrimmar's stands on top of a tower.
local AT_TAXI = 8
function Graph.LikelyZ(instance, x, y)
	local g = graphs[instance]
	if not g or (g.n or 0) == 0 then return end
	for _, pos in pairs(g.links and g.links.taxi or {}) do
		if (pos[1] - x) ^ 2 + (pos[2] - y) ^ 2 < AT_TAXI * AT_TAXI then return pos[3] end
	end
	decodeNodes(g)
	local found = {}
	for _, a in ipairs(nearest(g, x, y, 36)) do
		if #found < 12 and not flag(g.f[a[1]], NODE_POI) then found[#found + 1] = a end
	end
	local best, bestScore
	for _, a in ipairs(found) do
		if a[2] < 40 then
			local score = 0
			for _, b in ipairs(found) do
				if b[2] < 40 and abs(g.z[b[1]] - g.z[a[1]]) < LAYER_GAP then score = score + 1 / (b[2] + 10) end
			end
			if not bestScore or score > bestScore then best, bestScore = g.z[a[1]], score end
		end
	end
	return best
end

-- Trips: walking plus flight paths, boats, zeppelins, lifts, the tram and portals (tools/links.py, g.links):
--   taxi:    [node id] = { x, y, z, piece }  flight masters, by the ids C_TaxiMap reports
--   flights: flat triples from, to, seconds (direct flights)
--   rides:   { kind, to name, x, y, z, to instance, x, y, z, ride s, wait s, faction, piece, to piece }
-- A piece (g.comps: 2 chars per node, 0 the biggest) is a walkable part of a continent cut off from the rest:
-- Thunder Bluff's mesas, Teldrassil's treetop. Trips are planned on a small graph of places: the start, the
-- goal, the known flight masters, every dock, landing and portal. Walking counts only within one piece, at
-- the straight-line distance times WALK_DETOUR; flights chain through known flight masters like the game's.
local WALK_DETOUR = 1.3
local CLIMB_DETOUR = 3 -- yards of walking per yard of height on foot (a way up or down a cliff winds; a lift does not)
local TAKE_FLIGHT, LAND = 20, 5 -- seconds: talking to the flight master and taking off; landing
local TAKE_RIDE = 15            -- seconds: getting on and off a boat, a zeppelin, a lift, the tram

-- The walkable piece under (x, y) on the layer at height z (any layer without z), nil off the graph.
function Graph.Piece(instance, x, y, z)
	local g = graphs[instance]
	if not g or not g.comps or (g.n or 0) == 0 then return end
	decodeNodes(g)
	local f = nearest(g, x, y, 1, nil, z)[1]
	if f and f[2] < 60 and (not z or abs(g.z[f[1]] - z) <= LAYER_GAP) then return v2(g.comps, (f[1] - 1) * 2 + 1) end
end

-- The pieces a route to (x, y) can end in: those of the nodes the search could end at (an NPC's spot without a
-- known height can have a layer in another piece, such as a mesa's top and the hollow under it), as { piece,
-- height of its nearest goal node }.
local function goalPieces(instance, x, y, z)
	local g = graphs[instance]
	if not g or not g.comps or (g.n or 0) == 0 then return {} end
	decodeNodes(g)
	local out, seen = {}, {}
	for _, c in ipairs(goalNodes(g, x, y, z)) do
		local piece = v2(g.comps, (c[1] - 1) * 2 + 1)
		if c[2] < 60 and (not z or abs(g.z[c[1]] - z) <= LAYER_GAP or flag(g.f[c[1]], NODE_POI)) and not seen[piece] then
			seen[piece] = true
			out[#out + 1] = { piece, g.z[c[1]] }
		end
	end
	return out
end

-- the far end's piece of a ride to another continent: that continent's ride back starts there
local function farPiece(r)
	local g = graphs[r[6]]
	for _, back in ipairs(g and g.links and g.links.rides or {}) do
		if abs(back[3] - r[7]) < 1 and abs(back[4] - r[8]) < 1 and abs(back[5] - r[9]) < 1 then return back[13] end
	end
	return Graph.Piece(r[6], r[7], r[8], r[9])
end

-- s, t: { instance, x, y, z } (t.z may be nil), or t a list of them: the trip goes to whichever is quickest to
-- reach. opts: speed (yards per second on foot), faction ("A" or "H"), known ([node id] = name, the flight
-- masters the player can fly from and to). Returns { cost = seconds, legs = { { kind, from = place, to = place,
-- ... } }, goal = index in the list }; nil off the graph, nil, true when the goal is on the graph but out of
-- reach.
-- A leg's kind is "walk", "flight" (to.node, to.name; hops) or the ride's kind (name, ride, wait).
function Graph.PlanTrip(s, t, opts)
	local places, out = {}, {}
	local function add(inst, x, y, z, piece, pl)
		pl = pl or {}
		pl.instance, pl.x, pl.y, pl.z, pl.piece = inst, x, y, z, piece
		places[#places + 1], out[pl] = pl, {}
		return pl
	end
	local function link(a, b, cost, kind, ride)
		local e = out[a]
		e[#e + 1] = { b, cost, kind, ride }
	end
	local S = add(s.instance, s.x, s.y, s.z, Graph.Piece(s.instance, s.x, s.y, s.z), { kind = "start" })
	if not S.piece then return end
	local goals = {}
	for i, g in ipairs(t[1] and t or { t }) do
		for _, pc in ipairs(goalPieces(g.instance, g.x, g.y, g.z)) do
			goals[add(g.instance, g.x, g.y, g.z or pc[2], pc[1], { kind = "goal", goal = i })] = true
		end
	end
	if not next(goals) then return end
	local known, air = opts.known or {}, {}
	for inst, g in pairs(graphs) do
		for id, pos in pairs(g.links and g.links.taxi or {}) do
			if known[id] and pos[4] then
				local fm = add(inst, pos[1], pos[2], pos[3], pos[4], { kind = "taxi", node = id, name = known[id] })
				air[id] = add(inst, pos[1], pos[2], pos[3], nil, { kind = "air", node = id, name = known[id] })
				link(fm, air[id], TAKE_FLIGHT, "board")
				link(air[id], fm, LAND, "land")
			end
		end
	end
	for inst, g in pairs(graphs) do
		local L = g.links
		if L then
			local f = L.flights
			for k = 1, #f, 3 do
				if air[f[k]] and air[f[k + 1]] then link(air[f[k]], air[f[k + 1]], f[k + 2], "fly") end
			end
			for _, r in ipairs(L.rides) do
				if (r[12] == "" or r[12] == opts.faction) and r[13] then
					local to = r[14]
					if to == false then to = farPiece(r) end
					if to then
						local a = add(inst, r[3], r[4], r[5], r[13], { kind = "dock" })
						local b = add(r[6], r[7], r[8], r[9], to, { kind = "dock" })
						link(a, b, r[10] + r[11] + TAKE_RIDE, r[1], r)
					end
				end
			end
		end
	end

	-- Dijkstra over the places; walking edges are worked out as needed
	local speed = opts.speed or 7
	local cost, prev, how, done = { [S] = 0 }, {}, {}, {}
	local T
	while true do
		local u, cu
		for _, pl in ipairs(places) do
			local c = cost[pl]
			if c and not done[pl] and (not cu or c < cu) then u, cu = pl, c end
		end
		if not u then break end
		if goals[u] then T = u break end
		done[u] = true
		local function relax(v, c, kind, ride)
			if not cost[v] or cu + c < cost[v] then cost[v], prev[v], how[v] = cu + c, u, { kind, ride } end
		end
		if u.piece then
			for _, v in ipairs(places) do
				if v.piece == u.piece and v.instance == u.instance and v ~= u and v ~= S and not done[v] then
					local dx, dy = v.x - u.x, v.y - u.y
					local climb = v.z and u.z and abs(v.z - u.z) or 0
					relax(v, (sqrt(dx * dx + dy * dy) + CLIMB_DETOUR * climb) * WALK_DETOUR / speed, "walk")
				end
			end
		end
		for _, e in ipairs(out[u]) do relax(e[1], e[2], e[3], e[4]) end
	end
	if not T then return nil, true end

	-- steps back from the goal, then legs: walks joined, a flight from boarding to landing
	local steps = {}
	local v = T
	while prev[v] do
		table.insert(steps, 1, { from = prev[v], to = v, kind = how[v][1], ride = how[v][2] })
		v = prev[v]
	end
	local legs = {}
	for _, st in ipairs(steps) do
		local last = legs[#legs]
		if st.kind == "walk" and last and last.kind == "walk" then
			last.to = st.to
		elseif st.kind == "walk" then
			legs[#legs + 1] = { kind = "walk", from = st.from, to = st.to }
		elseif st.kind == "board" then
			legs[#legs + 1] = { kind = "flight", from = st.from, hops = 0 }
		elseif st.kind == "fly" then
			last.hops = last.hops + 1
		elseif st.kind == "land" then
			last.to = st.to
		else
			local r = st.ride
			legs[#legs + 1] = { kind = st.kind, from = st.from, to = st.to, name = r[2], ride = r[10], wait = r[11] }
		end
	end
	return { cost = cost[T], legs = legs, goal = T.goal }
end

function Graph.Stats(instance)
	local g = graphs[instance]
	if not g then return end
	return g.n, g.e, g.built
end
