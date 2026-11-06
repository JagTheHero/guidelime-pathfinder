local ADDON, ns = ...

-- Dotted trail of the path on the world map (whole path) and the minimap (the stretch ahead).

local Trail = {}
ns.Trail = Trail

local HBDPins = LibStub("HereBeDragons-Pins-2.0")
local DOT = "Interface\\AddOns\\" .. ADDON .. "\\Media\\dot"
local COLOR = { 0.62, 1, 0.25 }

local MINI_SPACING, MINI_RANGE = 8, 220
local MAP_MIN_SPACING, MAP_MAX_DOTS = 12, 160

local pools = { mini = {}, map = {} }
local shown = { mini = 0, map = 0 }
local miniRef, mapRef = {}, {}
local lastMini = { id = nil, x = 0, y = 0, t = 0 }

local function pin(kind, i)
	local f = pools[kind][i]
	if not f then
		f = CreateFrame("Frame")
		local size = kind == "mini" and 5 or 6
		f:SetSize(size, size)
		local t = f:CreateTexture(nil, "OVERLAY")
		t:SetAllPoints()
		t:SetTexture(DOT)
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

-- Whole path on the world map; called when the path changes.
function Trail.Refresh()
	clearMap()
	clearMini()
	lastMini.id = nil
	local p = ns.path
	if not p or not ns.db.worldmap then return end
	local instance = ns.player.instance
	local total = p.len and p.len[p.n] or 0
	local spacing = math.max(MAP_MIN_SPACING, total / MAP_MAX_DOTS)
	local n, nextS = 0, 0
	for i = 1, p.n - 1 do
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

-- Stretch ahead on the minimap; cheap enough to redo a few times a second.
function Trail.Update(p)
	if not p or not ns.db.minimap then
		if shown.mini > 0 then clearMini() end
		return
	end
	local now = GetTime()
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
