-- Minimal WoW API mock for running Guidelime_Pathfinder outside the game.
-- A "true" camera projects the navigation marker so the ground-dot solver can be checked.

local M = { frames = {}, now = 0, prints = {}, events = {} }
MOCK = M

local function noop() end

-- frames ----------------------------------------------------------------------------------------
local FrameMT = {}
FrameMT.__index = FrameMT
function FrameMT:SetScript(name, fn) self.scripts[name] = fn end
function FrameMT:GetScript(name) return self.scripts[name] end
function FrameMT:HookScript(name, fn) local old = self.scripts[name]; self.scripts[name] = function(...) if old then old(...) end fn(...) end end
function FrameMT:RegisterEvent(e) M.events[e] = M.events[e] or {}; table.insert(M.events[e], self) end
function FrameMT:Show() self.shown = true end
function FrameMT:Hide() self.shown = false end
function FrameMT:IsShown() return self.shown end
function FrameMT:SetShown(v) self.shown = v and true or false end
function FrameMT:SetSize(w, h) self.w, self.h = w, h end
function FrameMT:GetWidth() return self.w or 0 end
function FrameMT:GetHeight() return self.h or 0 end
function FrameMT:SetPoint(_, _, _, x, y) self.px, self.py = x, y end
function FrameMT:ClearAllPoints() self.px, self.py = nil, nil end
function FrameMT:SetAllPoints() end
function FrameMT:GetCenter() return self.cx, self.cy end
function FrameMT:GetEffectiveScale() return self.scale or 1 end
function FrameMT:SetFrameStrata() end
function FrameMT:SetFrameLevel() end
function FrameMT:SetAlpha(a) self.alpha = a end
function FrameMT:SetTexture(t) self.texture = t end
function FrameMT:SetVertexColor() end
function FrameMT:SetText(t) self.text = t end
function FrameMT:GetText() return self.text end
function FrameMT:GetChecked() return self.checked end
function FrameMT:GetParent() return self.parent end
function FrameMT:CreateTexture() local t = M.NewFrame(); t.shown = true; self.children = self.children or {}; table.insert(self.children, t); return t end
function FrameMT:CreateFontString() return M.NewFrame() end

function M.NewFrame()
	local f = setmetatable({ scripts = {}, shown = true }, FrameMT)
	table.insert(M.frames, f)
	return f
end
function CreateFrame() return M.NewFrame() end

UIParent = M.NewFrame()
WorldFrame = M.NewFrame()
M.W, M.H = 1920, 1080
WorldFrame.cx, WorldFrame.cy, WorldFrame.w, WorldFrame.h = M.W / 2, M.H / 2, M.W, M.H

-- globals ---------------------------------------------------------------------------------------
function GetTime() return M.now end
function debugprofilestop() return os.clock() * 1000 end
function print(...) local t = {} for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end M.prints[#M.prints + 1] = table.concat(t, " "); if M.echo then io.write("[print] ", table.concat(t, " "), "\n") end end
format = string.format
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function strsplit(sep, s, n)
	local out, start = {}, 1
	while true do
		if n and #out == n - 1 then out[#out + 1] = s:sub(start) break end
		local i = s:find(sep, start, true)
		if not i then out[#out + 1] = s:sub(start) break end
		out[#out + 1] = s:sub(start, i - 1)
		start = i + 1
	end
	return unpack(out)
end
function Round(v) return math.floor(v + 0.5) end
function geterrorhandler() return function(e) error(e, 2) end end
function hooksecurefunc(t, name, fn) local old = t[name]; t[name] = function(...) local r = { old(...) } fn(...) return unpack(r) end end
function IsIndoors() return false end
function IsMounted() return false end
function IsMouselooking() return M.mouselook end
function UnitIsGhost() return false end
function GetPlayerFacing() return M.facing end
function GetCameraZoom() return M.zoom end
SlashCmdList = {}
date = os.date
function GetBuildInfo() return "1.60.1", "70790", "Nov 1 2026", 16001 end
function GetPhysicalScreenSize() return M.W, M.H end
function GetScreenWidth() return M.W end
function GetScreenHeight() return M.H end
function UnitPosition() return M.py, M.px, 0, M.instance end
function UnitRace() return "Human", "Human", 1 end
function UnitSex() return 2 end
function Screenshot() M.screenshots = (M.screenshots or 0) + 1; M.pendingShot = true end
C_CVar = { GetCVar = function(k) if k == "cameraFov" then return tostring(M.cvarFov) end end }
function UnitFactionGroup() return M.faction or "Alliance" end
function UnitLevel() return M.level or 60 end
function UnitOnTaxi() return M.onTaxi end
function GetUnitSpeed() return 0, M.runSpeed or 7, 0, 4.7 end
-- flight masters: M.taxiNodes[uiMapID] = { { nodeID, name, faction, isUndiscovered }, ... } (WoW: Forever says
-- isUndiscovered = false for all); while a flight map is open (M.taxiOpen), M.taxiAll = { { nodeID, name, state }, ... }
-- (Enum.FlightPathState); the taxi map's slots are M.taxiSlots = { name, ... }
Enum = Enum or {}
Enum.FlightPathState = { Current = 0, Reachable = 1, Unreachable = 2 }
C_TaxiMap = {
	GetTaxiNodesForMap = function(mapID) return M.taxiNodes and M.taxiNodes[mapID] or {} end,
	-- like the game's, an error without a map id
	GetAllTaxiNodes = function(mapID)
		if type(mapID) ~= "number" then error("Usage: local taxiNodes = C_TaxiMap.GetAllTaxiNodes(uiMapID)", 2) end
		return M.taxiOpen and M.taxiAll or {}
	end,
}
function GetTaxiMapID() return M.taxiMapID end -- WoW: Forever gave none at TAXIMAP_OPENED
function TaxiNodeGetType(i) return M.taxiTypes and M.taxiTypes[i] or "NONE" end -- the older taxi frame's
function UnitGUID(unit) return unit == "player" and (M.guid or "Player-1-00000001") or nil end
function NumTaxiNodes() return #(M.taxiSlots or {}) end
function TaxiNodeName(i) return M.taxiSlots[i] end
C_Timer = { After = function(_, fn) fn() end }
UIErrorsFrame = { AddMessage = function(_, text) M.hints = M.hints or {}; table.insert(M.hints, text) end }

-- player + camera truth -------------------------------------------------------------------------
M.px, M.py, M.pz, M.instance = 0, 0, 0, 1
M.facing, M.zoom = 0, 12
M.trueYaw, M.truePitch, M.trueHeight = 0, 0.35, 1.9
M.cvarFov = 90 -- the game's vertical field of view is 0.6 x cameraFov

-- true projection of a world point (HBD coords x west+, y north+) using the mock camera
function M.TrueProject(x, y, z)
	local E, N, U = -x, y, z
	local yaw, pitch = M.trueYaw, M.truePitch
	local fx, fy, fz = -math.sin(yaw) * math.cos(pitch), math.cos(yaw) * math.cos(pitch), -math.sin(pitch)
	local rx, ry = math.cos(yaw), math.sin(yaw)
	local ux, uy, uz = ry * fz, -rx * fz, rx * fy - ry * fx
	local Fx, Fy, Fz = -M.px, M.py, M.pz + M.trueHeight
	local d = M.trueDist or M.zoom -- nearer than the zoom when something is in the way
	if not M.trueDist and M.cameraGround then -- like the game: pulled in 0.3 yd over the ground on the line back
		for k = 0.5, M.zoom, 0.5 do
			local g = M.cameraGround(M.px + k * fx, M.py - k * fy, k)
			if g and Fz - k * fz < g + 0.3 then d = math.max(0.5, k - 0.5) break end
		end
	end
	M.camDist = d
	local Cx, Cy, Cz = Fx - d * fx, Fy - d * fy, Fz - d * fz
	local vx, vy, vz = E - Cx, N - Cy, U - Cz
	local cf = vx * fx + vy * fy + vz * fz
	if cf < 0.3 then return end
	local f = (M.H / 2) / math.tan(math.rad(M.cvarFov * 0.6) / 2)
	return M.W / 2 + f * (vx * rx + vy * ry) / cf, M.H / 2 + f * (vx * ux + vy * uy + vz * uz) / cf
end

-- maps: one zone (uiMapID 1411) spanning 4000 yards square around the origin --------------------
-- (M.zones[uiMapID] = { left, top, w, h, instance, name, parent } adds real zones for zone-to-world lookups; with
-- parent, C_Map.GetMapInfoAtPosition(parent, ...) finds them)
M.zone = { id = 1411, left = 2000, top = 2000, w = 4000, h = 4000 }
local HBD = {}
function HBD:GetPlayerWorldPosition() return M.px, M.py, M.instance end
function HBD:GetPlayerZone() return M.zone.id end
function HBD:GetZoneCoordinatesFromWorld(x, y, zone, allow)
	local z = zone == M.zone.id and M.zone or M.zones and M.zones[zone]
	if not z then return end
	return (z.left - x) / z.w, (z.top - y) / z.h
end
function HBD:GetWorldCoordinatesFromZone(x, y, zone)
	local z = M.zones and M.zones[zone]
	if z then return z.left - x * z.w, z.top - y * z.h, z.instance end
	return M.zone.left - x * M.zone.w, M.zone.top - y * M.zone.h, M.instance
end
local Pins = { mini = {}, map = {} }
M.pins = Pins
function Pins:AddMinimapIconWorld(ref, icon, inst, x, y) Pins.mini[icon] = { x, y } end
function Pins:RemoveAllMinimapIcons() wipe(Pins.mini) end
function Pins:AddWorldMapIconWorld(ref, icon, inst, x, y) Pins.map[icon] = { x, y } end
function Pins:RemoveAllWorldMapIcons() wipe(Pins.map) end
HBD_PINS_WORLDMAP_SHOW_CONTINENT = 2
function LibStub(name) if name == "HereBeDragons-2.0" then return HBD end return Pins end

-- waypoint + navigation -------------------------------------------------------------------------
M.waypoint, M.superTracking = nil, false
M.navFrame = M.NewFrame()
C_Map = {
	GetBestMapForUnit = function() return M.zone.id end,
	CanSetUserWaypointOnMap = function() return true end,
	GetMapInfo = function(id) local z = M.zones and M.zones[id] return { parentMapID = 0, name = z and z.name } end,
	-- the zone at a spot on a map: like the game's, an error without numbers for x and y
	GetMapInfoAtPosition = function(m, x, y)
		if type(m) ~= "number" or type(x) ~= "number" or type(y) ~= "number" then
			error("Usage: local info = C_Map.GetMapInfoAtPosition(uiMapID, x, y [, ignoreZoneMapPositionData])", 2)
		end
		local on = M.zones and M.zones[m]
		if not on then return end
		local wx, wy = on.left - x * on.w, on.top - y * on.h
		for id, z in pairs(M.zones) do
			if z.parent == m and wx <= z.left and wx >= z.left - z.w and wy <= z.top and wy >= z.top - z.h then return { mapID = id, name = z.name } end
		end
	end,
	SetUserWaypoint = function(pt) M.waypoint = pt; M.waypointSets = (M.waypointSets or 0) + 1; M.Fire("USER_WAYPOINT_UPDATED") end,
	GetUserWaypoint = function() return M.waypoint end,
	ClearUserWaypoint = function() M.waypoint = nil; M.Fire("USER_WAYPOINT_UPDATED") end,
}
UiMapPoint = { CreateFromCoordinates = function(m, x, y, z) return { uiMapID = m, position = { x = x, y = y }, z = z } end }
C_SuperTrack = {
	SetSuperTrackedUserWaypoint = function(v) M.superTracking = v end,
	IsSuperTrackingUserWaypoint = function() return M.superTracking end,
}
-- world position of the waypoint (HBD coords), z from the UiMapPoint (0 if unset)
function M.WaypointWorld()
	local wp = M.waypoint
	if not wp then return end
	return M.zone.left - wp.position.x * M.zone.w, M.zone.top - wp.position.y * M.zone.h, wp.z or 0
end
C_Navigation = {
	GetFrame = function() return M.navFrame end,
	HasValidScreenPosition = function() return M.navValid end,
	WasClampedToScreen = function() return M.navClamped end,
	GetDistance = function() local x, y = M.navX, M.navY; return x and math.sqrt((x - M.px) ^ 2 + (y - M.py) ^ 2) or 0 end,
}
-- M.navLag: like the game may, the frame after the waypoint moves still shows (and measures) the last one
function M.UpdateNav()
	local x, y = M.WaypointWorld()
	if M.navLag then
		local nx, ny = M.nextNavX, M.nextNavY
		M.nextNavX, M.nextNavY = x, y
		if nx then x, y = nx, ny end
	end
	M.navX, M.navY = x, y
	M.navValid, M.navClamped = false, false
	if not x or not M.superTracking then return end
	local sx, sy = M.TrueProject(x, y, M.pz) -- like the game: drawn at the player's height, not the waypoint's
	if not sx then M.navValid = true; M.navClamped = true; return end
	M.navValid = true
	M.navClamped = sx < 0 or sx > M.W or sy < 0 or sy > M.H
	M.navFrame.cx, M.navFrame.cy = sx, sy
end

-- event + frame driving -------------------------------------------------------------------------
function M.Fire(event, ...)
	for _, f in ipairs(M.events[event] or {}) do
		local fn = f.scripts.OnEvent
		if fn then fn(f, event, ...) end
	end
end
function M.Step(dt)
	M.now = M.now + dt
	if M.pendingShot then M.pendingShot = false; M.Fire("SCREENSHOT_SUCCEEDED") end
	if M.ground then M.pz = M.ground(M.px, M.py) or M.pz end -- the player stands on the ground
	M.UpdateNav()
	for _, f in ipairs(M.frames) do
		local fn = f.scripts.OnUpdate
		if fn and f.shown then fn(f, dt) end
	end
end

-- C_AddOns.LoadAddOn loads an addon from the folder next to the last one loaded with M.LoadAddon
local addonRoot, loaded = ".", {}
C_AddOns = C_AddOns or {}
C_AddOns.GetAddOnMetadata = function(_, field) if field == "Version" then return M.version or "test" end end
C_AddOns.LoadAddOn = function(name)
	if loaded[name] then return true end
	local ok = io.open(addonRoot .. "/" .. name .. "/" .. name .. ".toc")
	if not ok then return false, "MISSING" end
	ok:close()
	M.LoadAddon(addonRoot .. "/" .. name, name)
	return true
end

function M.LoadAddon(dir, name)
	addonRoot, loaded[name] = dir:match("^(.*)/[^/]+$") or ".", true
	local ns = {}
	local toc = assert(io.open(dir .. "/" .. name .. ".toc"))
	for line in toc:lines() do
		line = line:gsub("\r", "")
		if line ~= "" and not line:find("^##") then
			local path = dir .. "/" .. line:gsub("\\", "/")
			local chunk = assert(loadfile(path))
			chunk(name, ns)
		end
	end
	toc:close()
	return ns
end

return M
