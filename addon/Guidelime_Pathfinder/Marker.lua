local ADDON, ns = ...

-- Drives the game's own in-world navigation marker (a super-tracked user waypoint): it sits on the next
-- corner of the path and moves on as each corner is reached. The player's own map pins take priority.

local Marker = {}
ns.Marker = Marker

local abs = math.abs
local own        -- {m = uiMapID, x, y} of the waypoint this addon placed
local override   -- the player placed or removed a pin themselves; stand back until the next guide step
local TOLERANCE = 2e-3

local function mapPointFor(x, y)
	local m = C_Map.GetBestMapForUnit("player")
	for _ = 1, 6 do
		if not m or m == 0 then return end
		local mx, my = ns.HBD:GetZoneCoordinatesFromWorld(x, y, m, true)
		if mx and mx >= 0 and mx <= 1 and my >= 0 and my <= 1 and C_Map.CanSetUserWaypointOnMap(m) then
			return m, mx, my
		end
		local info = C_Map.GetMapInfo(m)
		m = info and info.parentMapID
	end
end

local function isOwn(wp)
	return own and wp and wp.uiMapID == own.m and abs(wp.position.x - own.x) < TOLERANCE and abs(wp.position.y - own.y) < TOLERANCE
end

function Marker.IsActive()
	return own ~= nil and C_SuperTrack.IsSuperTrackingUserWaypoint() and isOwn(C_Map.GetUserWaypoint())
end

-- Puts the super-tracked waypoint on a world point (HereBeDragons coordinates). False if no map takes it.
function Marker.Place(x, y, z)
	local m, mx, my = mapPointFor(x, y)
	if not m then return false end
	own = { m = m, x = mx, y = my }
	Marker.before, Marker.at = Marker.at, { x, y } -- world spots, for the ground dots
	C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(m, mx, my, z))
	C_SuperTrack.SetSuperTrackedUserWaypoint(true)
	return true
end

function Marker.Update(p)
	if Marker.probing then return end
	if not p or not ns.db.marker or override then return Marker.Release() end
	local k = p.k
	if Marker.pathId == p.id and Marker.k == k then return end
	if Marker.Place(p.x[k], p.y[k], p.z and p.z[k] or nil) then Marker.pathId, Marker.k = p.id, k end
end

function Marker.Release()
	if own and isOwn(C_Map.GetUserWaypoint()) then
		own = nil
		C_Map.ClearUserWaypoint()
	end
	own = nil
	Marker.pathId, Marker.k = nil, nil
end

function Marker.ResetOverride()
	override = false
end

function Marker.OnWaypointUpdated()
	if not own then return end
	if not isOwn(C_Map.GetUserWaypoint()) then
		own = nil
		override = true
		Marker.pathId, Marker.k = nil, nil
		ns.Print("your own map pin takes over; the path marker comes back at the next guide step.")
	end
end

-- Blizzard clears a reached user waypoint and shows "destination reached"; skip that for the
-- corners along the way, and show the remaining path length under the marker.
local hooked
function Marker.HookBlizzard()
	if hooked or not SuperTrackedFrame then return end
	hooked = true
	local reached = SuperTrackedFrame.OnDestinationReached
	SuperTrackedFrame.OnDestinationReached = function(self, isWaypoint)
		local p = ns.path
		if Marker.probing or (own and p and p.k < p.n) then return end
		return reached(self, isWaypoint)
	end
	hooksecurefunc(SuperTrackedFrame, "UpdateDistanceText", function(self)
		local p = ns.path
		if self.isClamped or not p or not p.remaining or not Marker.IsActive() then return end
		local d = Round(C_Navigation.GetDistance())
		if p.k < p.n then
			self.DistanceText:SetText(format("%d yds  |cff9fff3f%d to go|r", d, Round(p.remaining)))
		end
		self.distance = nil -- let Blizzard's own update run again next frame
	end)
end
