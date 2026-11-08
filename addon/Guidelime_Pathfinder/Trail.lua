local ADDON, ns = ...

-- Dotted trail of the path on the world map (the rest of the way) and the minimap (the stretch ahead).

local Trail = {}
ns.Trail = Trail

local HBDPins = LibStub("HereBeDragons-Pins-2.0")
local PIP = "Interface\\AddOns\\" .. ADDON .. "\\Media\\pip" -- bright disc, dark outline
local COLOR = { 0.62, 1, 0.25 }

local MINI_SPACING, MINI_RANGE = 8, 220
local MAP_MIN_SPACING, MAP_MAX_DOTS = 12, 160

local pools = { mini = {}, map = {} }
local shown = { mini = 0, map = 0 }
local miniRef, mapRef = {}, {}
local lastMini = { id = nil, x = 0, y = 0, t = 0 }
local mapAt = { id = nil, nextDot = 0, t = 0 } -- the world map's first dot, to redraw once it is passed

local function pin(kind, i)
	local f = pools[kind][i]
	if not f then
		f = CreateFrame("Frame")
		local size = kind == "mini" and 6 or 7
		f:SetSize(size, size)
		local t = f:CreateTexture(nil, "OVERLAY")
		t:SetAllPoints()
		t:SetTexture(PIP)
		t:SetVertexColor(COLOR[1], COLOR[2], COLOR[3])
		pools[kind][i] = f
	end
	return f
end

local function clearMini()
	HBDPins:RemoveAllMinimapIcons(miniRef)
	shown.mini = 0
end

local function clearMap()
	HBDPins:RemoveAllWorldMapIcons(mapRef)
	shown.map = 0
end

-- yards of p behind the player
local function walked(p)
	local i = p.seg or 1
	local j = math.min(i + 1, p.n)
	return p.len[i] + (p.len[j] - p.len[i]) * (p.segT or 0)
end

-- The path from the player on, on the world map. Dots sit at fixed spots along the whole path, so the ones
-- ahead stay put as those behind go.
local function drawMap(p)
	clearMap()
	mapAt.id = nil
	if not p or not ns.db.worldmap then return end
	local instance = ns.player.instance
	local spacing = math.max(MAP_MIN_SPACING, p.len[p.n] / MAP_MAX_DOTS)
	local n, nextS = 0, math.ceil(walked(p) / spacing) * spacing
	mapAt.id, mapAt.nextDot, mapAt.t = p.id, nextS, GetTime()
	for i = p.seg or 1, p.n - 1 do
		local a, b = p.len[i], p.len[i + 1]
		while nextS <= b do
			local u = b > a and (nextS - a) / (b - a) or 0
			n = n + 1
			HBDPins:AddWorldMapIconWorld(mapRef, pin("map", n), instance,
				p.x[i] + (p.x[i + 1] - p.x[i]) * u, p.y[i] + (p.y[i + 1] - p.y[i]) * u, HBD_PINS_WORLDMAP_SHOW_CONTINENT)
			nextS = nextS + spacing
		end
	end
	shown.map = n
end

-- Called when the path changes.
function Trail.Refresh()
	clearMini()
	lastMini.id = nil
	drawMap(ns.path)
end

-- Stretch ahead on the minimap; cheap enough to redo a few times a second.
function Trail.Update(p)
	local now = GetTime()
	-- the world map drops the dots behind the player while it is open (and when it opens)
	if p and mapAt.id == p.id and walked(p) > mapAt.nextDot and now - mapAt.t >= 1 and WorldMapFrame and WorldMapFrame:IsShown() then
		drawMap(p)
	end
	if not p or not ns.db.minimap then
		if shown.mini > 0 then clearMini() end
		return
	end
	local px, py = ns.player.x, ns.player.y
	local moved = (px - lastMini.x) ^ 2 + (py - lastMini.y) ^ 2
	if lastMini.id == p.id and moved < 9 and now - lastMini.t < 1 then return end
	lastMini.id, lastMini.x, lastMini.y, lastMini.t = p.id, px, py, now
	clearMini()
	local instance = ns.player.instance
	local n = 0
	ns.SamplePath(p, MINI_SPACING, MINI_RANGE, function(x, y)
		n = n + 1
		HBDPins:AddMinimapIconWorld(miniRef, pin("mini", n), instance, x, y, false)
	end)
	shown.mini = n
end
