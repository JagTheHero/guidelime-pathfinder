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
C_CVar = { GetCVar = function(k) if k == "cameraFov" then return tostring(M.cvarFov or 90) end end }

-- player + camera truth -------------------------------------------------------------------------
M.px, M.py, M.pz, M.instance = 0, 0, 0, 1
M.facing, M.zoom = 0, 12
M.trueYaw, M.truePitch, M.trueFov, M.trueHeight = 0, 0.35, 90, 1.9

-- true projection of a world point (HBD coords x west+, y north+) using the mock camera
function M.TrueProject(x, y, z)
	local E, N, U = -x, y, z
	local yaw, pitch = M.trueYaw, M.truePitch
	local fx, fy, fz = -math.sin(yaw) * math.cos(pitch), math.cos(yaw) * math.cos(pitch), -math.sin(pitch)
	local rx, ry = math.cos(yaw), math.sin(yaw)
	local ux, uy, uz = ry * fz, -rx * fz, rx * fy - ry * fx
	local Fx, Fy, Fz = -M.px, M.py, M.pz + M.trueHeight
	local Cx, Cy, Cz = Fx - M.zoom * fx, Fy - M.zoom * fy, Fz - M.zoom * fz
	local vx, vy, vz = E - Cx, N - Cy, U - Cz
	local cf = vx * fx + vy * fy + vz * fz
	if cf < 0.3 then return end
	local f = (M.W / 2) / math.tan(math.rad(M.trueFov) / 2)
	return M.W / 2 + f * (vx * rx + vy * ry) / cf, M.H / 2 + f * (vx * ux + vy * uy + vz * uz) / cf
end

-- maps: one zone (uiMapID 1411) spanning 4000 yards square around the origin --------------------
M.zone = { id = 1411, left = 2000, top = 2000, w = 4000, h = 4000 }
local HBD = {}
function HBD:GetPlayerWorldPosition() return M.px, M.py, M.instance end
function HBD:GetPlayerZone() return M.zone.id end
function HBD:GetZoneCoordinatesFromWorld(x, y, zone, allow)
	if zone ~= M.zone.id then return end
	return (M.zone.left - x) / M.zone.w, (M.zone.top - y) / M.zone.h
end
function HBD:GetWorldCoordinatesFromZone(x, y, zone)
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
	GetMapInfo = function() return { parentMapID = 0 } end,
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
	GetDistance = function() local x, y = M.WaypointWorld(); return x and math.sqrt((x - M.px) ^ 2 + (y - M.py) ^ 2) or 0 end,
}
function M.UpdateNav()
	local x, y = M.WaypointWorld()
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

function M.LoadAddon(dir, name)
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
