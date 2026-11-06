local ADDON, ns = ...

-- Walkable-path graphs, one per continent (instance ID), generated offline from the game's terrain,
-- buildings and doodads (tools/navbuild.cpp builds a navmesh and the graph, tools/pack.py packs it).
-- Every edge is a straight line that was checked to be walkable (small props like trees aside), so a path
-- is just a list of corners. Data is packed into base-64 strings and read in place.
--
--   nodes: n records of 14 chars: x(3) y(3) z(3) flags(1: 1 indoor, 2 swim) firstEdge(4)
--   edges: e records of 4 chars:  neighbour(3) flags(1)
--   cells: c records of 10 chars: cellKey(4) firstNode(3) count(3)   (nodes are sorted by cell)
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
local NODE_INDOOR = 1
-- edge cost multipliers by edge flag (low 3 bits): 0 walk, 1 swim, 2 steep/slow
local MULT = { [0] = 1, [1] = 1.7, [2] = 1.25 }
local HEURISTIC_WEIGHT = 1.15
local FRAME_BUDGET_MS = 4

local graphs = {}

local function v3(s, p)
	local a, b, c = byte(s, p, p + 2)
	return (DEC[a] * 64 + DEC[b]) * 64 + DEC[c]
end

local function v4(s, p)
	local a, b, c, d = byte(s, p, p + 3)
	return ((DEC[a] * 64 + DEC[b]) * 64 + DEC[c]) * 64 + DEC[d]
end

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
	return v3(g.edges, p) + 1, DEC[byte(g.edges, p + 3)]
end

local function edgeFlag(g, a, b)
	local first, last = edgeRange(g, a)
	for j = first, last - 1 do
		local v, fl = edgeAt(g, j)
		if v == b then return fl end
	end
end

local function cellNodes(g, cx, cy)
	local key = cx + cy * 1024
	local s, lo, hi = g.cells, 0, g.c - 1
	while lo <= hi do
		local mid = floor((lo + hi) / 2)
		local p = mid * CELL_W + 1
		local k = v4(s, p)
		if k == key then return v3(s, p + 4) + 1, v3(s, p + 7) end
		if k < key then lo = mid + 1 else hi = mid - 1 end
	end
end

-- Up to `count` nodes nearest to (x, y), as {id, distance} sorted by distance.
-- indoors (from IsIndoors()) breaks ties between stacked floors and caves under open ground.
local function nearest(g, x, y, count, indoors)
	local cs = g.cs
	local cx, cy = floor((x + OFFSET_XY) / cs), floor((y + OFFSET_XY) / cs)
	local found = {}
	for _, r in ipairs({ 1, 2, 4 }) do
		for dy = -r, r do
			for dx = -r, r do
				local first, cnt = cellNodes(g, cx + dx, cy + dy)
				if first then
					for id = first, first + cnt - 1 do
						local ddx, ddy = g.x[id] - x, g.y[id] - y
						local d = sqrt(ddx * ddx + ddy * ddy)
						local score = d
						if indoors ~= nil and ((g.f[id] % 2 == NODE_INDOOR) ~= indoors) then score = score + 15 end
						found[#found + 1] = { id, d, score }
					end
				end
			end
		end
		if #found >= count or r == 4 then break end
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

local function search(g, sx, sy, tx, ty, indoors)
	decodeNodes(g)
	local gx, gy, gz = g.x, g.y, g.z
	local starts = nearest(g, sx, sy, 4, indoors)
	local goals = nearest(g, tx, ty, 3, nil)
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
			if goalCost[u] and gu + goalCost[u] < best then best, bestId = gu + goalCost[u], u end
			local first, last = edgeRange(g, u)
			local ux, uy, uz = gx[u], gy[u], gz[u]
			for j = first, last - 1 do
				local v, fl = edgeAt(g, j)
				if not closed[v] then
					local dx, dy, dz = gx[v] - ux, gy[v] - uy, gz[v] - uz
					local c = gu + sqrt(dx * dx + dy * dy + dz * dz) * (MULT[fl % 8] or 1)
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

-- Drop corners that a direct graph edge (an already-checked straight walk) can skip.
local function smooth(g, ids)
	local out = { ids[1] }
	local i = 1
	while i < #ids do
		local j = min(#ids, i + 10)
		while j > i + 1 do
			local fl = edgeFlag(g, ids[i], ids[j])
			if fl and fl % 8 == 0 then break end
			j = j - 1
		end
		out[#out + 1] = ids[j]
		i = j
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

-- Calls cb(path) later with a path table {x, y, z, n} from (sx, sy) to (tx, ty), or cb(nil).
function Graph.FindPath(instance, sx, sy, tx, ty, indoors, cb)
	local g = graphs[instance]
	if not g or (g.n or 0) == 0 then cb(nil) return end
	local j = { cb = cb }
	j.co = create(function()
		local t0 = debugprofilestop()
		local ids, cost, expanded = search(g, sx, sy, tx, ty, indoors)
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

function Graph.Stats(instance)
	local g = graphs[instance]
	if not g then return end
	return g.n, g.e, g.built
end
