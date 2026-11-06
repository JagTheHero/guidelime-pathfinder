local ADDON, ns = ...
GuidelimePathfinder = ns

local HBD = LibStub("HereBeDragons-2.0")
ns.HBD = HBD

local floor, sqrt, min, max, huge = math.floor, math.sqrt, math.min, math.max, math.huge

local DEFAULTS = {
	enabled = true,
	marker = true,   -- move the game's in-world waypoint marker along the path
	dots = true,     -- experimental ground dots (camera solved from the marker's screen position)
	minimap = true,
	worldmap = true,
	dotSpacing = 4,  -- yards between ground dots
	dotRange = 60,   -- yards of path ahead drawn as ground dots
	dotSize = 0.8,   -- dot diameter in yards
	focusHeight = 1.9, -- camera pivot height above the feet, yards
	fov = 0,         -- horizontal field of view in degrees; 0 = from the cameraFov CVar + calibration
	debug = false,
}

local OFF_PATH = 25   -- yards away from the path before replanning
local ADVANCE = 7     -- yards from a corner before the marker moves to the next one

ns.player = {}
ns.goal = {}
local goalKey
local pathId = 0
local offSince

function ns.Print(...) print("|cff9fff3fGuidelime Pathfinder:|r", ...) end
function ns.Debug(...) if ns.db and ns.db.debug then ns.Print(...) end end

-- The current Guidelime arrow target, in HereBeDragons world coordinates, or the corpse while a ghost.
function ns.GetTarget()
	if UnitIsGhost("player") then
		local zone = HBD:GetPlayerZone()
		local corpse = zone and C_DeathInfo.GetCorpseMapPosition(zone)
		if corpse then
			local x, y, instance = HBD:GetWorldCoordinatesFromZone(corpse.x, corpse.y, zone)
			if x then return x, y, instance end
		end
		return
	end
	local arrow = _G.GuidelimeArrow
	local el = arrow and arrow.element
	if not el or el.completed or not el.wx or not el.wy then return end
	local tomtom = GuidelimeData and GuidelimeData.useTomTomArrow and TomTom
	if not arrow:IsShown() and not tomtom then return end
	return el.wx, el.wy, el.instance
end

local function segDist(px, py, ax, ay, bx, by)
	local dx, dy = bx - ax, by - ay
	local l2 = dx * dx + dy * dy
	local t = 0
	if l2 > 0 then t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / l2)) end
	local qx, qy = ax + dx * t - px, ay + dy * t - py
	return sqrt(qx * qx + qy * qy), t
end

local function dist(ax, ay, bx, by)
	local dx, dy = bx - ax, by - ay
	return sqrt(dx * dx + dy * dy)
end

local function measure(p)
	p.len = p.len or {}
	p.len[1] = 0
	for i = 2, p.n do p.len[i] = p.len[i - 1] + dist(p.x[i - 1], p.y[i - 1], p.x[i], p.y[i]) end
end

function ns.PointOnSeg(p, i, t)
	local j = min(i + 1, p.n)
	local z0 = p.z and p.z[i] or 0
	local z1 = p.z and p.z[j] or 0
	return p.x[i] + (p.x[j] - p.x[i]) * t, p.y[i] + (p.y[j] - p.y[i]) * t, z0 + (z1 - z0) * t
end

-- Calls fn(x, y, z, distanceAlong) every `spacing` yards along the path ahead of the player.
function ns.SamplePath(p, spacing, maxDist, fn)
	if not p or not p.seg then return end
	local i = p.seg
	local x0, y0, z0 = ns.PointOnSeg(p, i, p.segT or 0)
	local travelled, nextS = 0, spacing
	while i < p.n and travelled < maxDist do
		local x1, y1, z1 = p.x[i + 1], p.y[i + 1], p.z and p.z[i + 1] or 0
		local L = dist(x0, y0, x1, y1)
		while nextS <= travelled + L and nextS <= maxDist do
			local u = (nextS - travelled) / L
			if fn(x0 + (x1 - x0) * u, y0 + (y1 - y0) * u, z0 + (z1 - z0) * u, nextS) == false then return end
			nextS = nextS + spacing
		end
		travelled = travelled + L
		x0, y0, z0 = x1, y1, z1
		i = i + 1
	end
end

function ns.SetPath(p, fromGraph)
	pathId = pathId + 1
	p.id, p.k, p.graph = pathId, 2, fromGraph
	measure(p)
	ns.path = p
	ns.Follow(p, ns.player.x, ns.player.y)
	ns.Trail.Refresh()
end

-- Tracks progress: which segment the player is on and which corner comes next.
function ns.Follow(p, px, py)
	if not px then return end
	local bestI, bestD, bestT = max(1, p.k - 1), huge, 0
	for i = max(1, p.k - 2), min(p.n - 1, p.k + 4) do
		local d, t = segDist(px, py, p.x[i], p.y[i], p.x[i + 1], p.y[i + 1])
		if d <= bestD + 0.25 then bestI, bestD, bestT = i, d, t end
	end
	local k = bestI + 1
	if k < p.n and dist(px, py, p.x[k], p.y[k]) < ADVANCE then k = k + 1 end
	p.k, p.seg, p.segT, p.off = k, bestI, bestT, bestD
	p.remaining = dist(px, py, p.x[k], p.y[k]) + p.len[p.n] - p.len[k]
end

function ns.Plan(px, py, keepCurrent)
	local g = ns.goal
	if not keepCurrent or not ns.path then
		ns.SetPath({ x = { px, g.x }, y = { py, g.y }, n = 2 }, false)
	end
	if not ns.Graph.Has(g.instance) then return end
	local key = goalKey
	ns.planning = true
	ns.Graph.FindPath(g.instance, px, py, g.x, g.y, IsIndoors(), function(p)
		ns.planning = false
		if key ~= goalKey then return end
		if p then ns.SetPath(p, true) end
	end)
end

function ns.Stop()
	if goalKey or ns.path then
		goalKey, ns.path, ns.planning = nil, nil, false
		ns.Marker.Release()
		ns.Trail.Refresh()
	end
end

local function tick()
	local db = ns.db
	if not db.enabled then return ns.Stop() end
	local px, py, instance = HBD:GetPlayerWorldPosition()
	local tx, ty, tinstance = ns.GetTarget()
	if not px or not tx or tinstance ~= instance then return ns.Stop() end
	ns.player.x, ns.player.y, ns.player.instance = px, py, instance

	local key = instance .. ":" .. floor(tx) .. ":" .. floor(ty)
	if key ~= goalKey then
		goalKey = key
		ns.goal.x, ns.goal.y, ns.goal.instance = tx, ty, instance
		ns.Marker.ResetOverride()
		ns.Plan(px, py)
	end

	local p = ns.path
	if p then
		if not p.graph then
			p.x[1], p.y[1] = px, py
			measure(p)
		end
		ns.Follow(p, px, py)
		if p.graph and p.off > OFF_PATH then
			offSince = offSince or GetTime()
			if GetTime() - offSince > 1.5 and not ns.planning then
				offSince = nil
				ns.Plan(px, py, true)
			end
		else
			offSince = nil
		end
	end
	ns.Marker.Update(p)
	ns.Trail.Update(p)
end

local ticker = CreateFrame("Frame")
local elapsedSince = 0
ticker:SetScript("OnUpdate", function(_, elapsed)
	elapsedSince = elapsedSince + elapsed
	if elapsedSince < 0.1 then return end
	elapsedSince = 0
	tick()
end)
ticker:Hide()

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("USER_WAYPOINT_UPDATED")
events:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON then
			GuidelimePathfinderDB = GuidelimePathfinderDB or {}
			ns.db = GuidelimePathfinderDB
			for k, v in pairs(DEFAULTS) do
				if ns.db[k] == nil then ns.db[k] = v end
			end
		end
		ns.Marker.HookBlizzard()
	elseif event == "PLAYER_LOGIN" then
		ns.Marker.HookBlizzard()
		ticker:Show()
	elseif event == "USER_WAYPOINT_UPDATED" then
		ns.Marker.OnWaypointUpdated()
	end
end)

local TOGGLES = { marker = "in-world marker", dots = "ground dots", minimap = "minimap trail", worldmap = "world map trail", debug = "debug messages" }

local function onOff(v) return v and "|cff40ff40on|r" or "|cffff4040off|r" end

local function status()
	local db = ns.db
	ns.Print("enabled " .. onOff(db.enabled) .. ", marker " .. onOff(db.marker) .. ", dots " .. onOff(db.dots)
		.. ", minimap " .. onOff(db.minimap) .. ", world map " .. onOff(db.worldmap))
	for _, instance in ipairs({ 0, 1 }) do
		local n, e, built = ns.Graph.Stats(instance)
		ns.Print(format("  %s: %s", instance == 0 and "Eastern Kingdoms" or "Kalimdor",
			n and n > 0 and format("%d path nodes, %d links (built %s)", n, e, built or "?") or "no path data yet (straight line)"))
	end
	local p = ns.path
	if p then
		ns.Print(format("  path: %d corners, %s, next corner %d, %.0f yd to go", p.n, p.graph and "walkable route" or "straight line", p.k, p.remaining or 0))
	else
		ns.Print("  no active Guidelime target")
	end
	ns.Print(format("  dots: spacing %d yd, range %d yd, size %.1f yd, camera height %.1f yd, fov %s",
		db.dotSpacing, db.dotRange, db.dotSize, db.focusHeight, db.fov > 0 and db.fov or ns.Dots.FovText()))
end

SLASH_GUIDELIMEPATHFINDER1 = "/gpath"
SlashCmdList.GUIDELIMEPATHFINDER = function(msg)
	local cmd, arg = strsplit(" ", strtrim(msg or ""):lower(), 2)
	local db = ns.db
	if cmd == "" then
		db.enabled = not db.enabled
		ns.Print(db.enabled and "on" or "off")
		if not db.enabled then ns.Stop() end
	elseif TOGGLES[cmd] then
		db[cmd] = not db[cmd]
		ns.Print(TOGGLES[cmd] .. " " .. onOff(db[cmd]))
		ns.Trail.Refresh()
		if cmd == "marker" and not db.marker then ns.Marker.Release() end
	elseif cmd == "replan" then
		if ns.goal.x and ns.player.x then ns.Plan(ns.player.x, ns.player.y) end
	elseif (cmd == "spacing" or cmd == "range" or cmd == "size" or cmd == "height" or cmd == "fov") and tonumber(arg) then
		local field = ({ spacing = "dotSpacing", range = "dotRange", size = "dotSize", height = "focusHeight", fov = "fov" })[cmd]
		db[field] = tonumber(arg)
		if cmd == "fov" then ns.Dots.ResetCalibration() end
		ns.Print(cmd .. " = " .. db[field])
	elseif cmd == "status" then
		status()
	else
		ns.Print("/gpath  - turn on/off")
		ns.Print("/gpath marker | dots | minimap | worldmap | debug  - toggle a part")
		ns.Print("/gpath status | replan")
		ns.Print("/gpath spacing <yd> | range <yd> | size <yd> | height <yd> | fov <deg, 0 = auto>  - ground dot tuning")
	end
end
