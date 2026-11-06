local ADDON, ns = ...

-- EXPERIMENTAL ground dots. Addons cannot project world points to the screen, but the game projects one
-- point for us: the in-world navigation marker. Knowing where that point is in the world, where the
-- player stands and how far the camera is zoomed out, we solve the camera's yaw and pitch so that our
-- own projection lands exactly on the marker, then project the path ahead with the same camera.
-- The field of view is learned while mouse-steering, when camera yaw equals the character's facing.

local Dots = {}
ns.Dots = Dots

local sin, cos, tan, sqrt, abs, min, max, rad, deg, atan = math.sin, math.cos, math.tan, math.sqrt, math.abs, math.min, math.max, math.rad, math.deg, math.atan
local DOT = "Interface\\AddOns\\" .. ADDON .. "\\Media\\dot"
local COLOR = { 0.62, 1, 0.25 }
local MAX_DOTS = 48
local CALIB_SAMPLES = 15

local layer = CreateFrame("Frame", nil, UIParent)
layer:SetAllPoints()
layer:SetFrameStrata("BACKGROUND")
local pool = {}

local cam = { yaw = nil, pitch = 0.3 }
local calib = { samples = {} }

-- camera basis and position (world axes: E = east, N = north, U = up), focal length and screen centre
local fx, fy, fz, rx, ry, ux, uy, uz, Cx, Cy, Cz, focal, scx, scy

local function setCamera(yaw, pitch, Fx, Fy, Fz, d)
	local cyw, syw, cp, sp = cos(yaw), sin(yaw), cos(pitch), sin(pitch)
	fx, fy, fz = -syw * cp, cyw * cp, -sp
	rx, ry = cyw, syw
	ux, uy, uz = ry * fz, -rx * fz, rx * fy - ry * fx
	Cx, Cy, Cz = Fx - d * fx, Fy - d * fy, Fz - d * fz
end

local function project(E, N, U)
	local vx, vy, vz = E - Cx, N - Cy, U - Cz
	local cf = vx * fx + vy * fy + vz * fz
	if cf < 0.3 then return end
	local cr = vx * rx + vy * ry
	local cu = vx * ux + vy * uy + vz * uz
	return scx + focal * cr / cf, scy + focal * cu / cf, cf, vz / sqrt(vx * vx + vy * vy + vz * vz)
end

-- Gauss-Newton on two unknowns. `set(a, b)` configures the camera; returns a, b when the marker matches.
local function solve2(a, b, set, ox, oy, mE, mN, mU)
	local function res(p, q)
		set(p, q)
		local sx, sy = project(mE, mN, mU)
		if sx then return sx - ox, sy - oy end
	end
	for _ = 1, 8 do
		local r1, r2 = res(a, b)
		if not r1 then return end
		if r1 * r1 + r2 * r2 < 0.25 then return a, b end
		local e = 1e-3
		local a1, a2 = res(a + e, b)
		local b1, b2 = res(a, b + e)
		if not a1 or not b1 then return end
		local j11, j21, j12, j22 = (a1 - r1) / e, (a2 - r2) / e, (b1 - r1) / e, (b2 - r2) / e
		local det = j11 * j22 - j12 * j21
		if abs(det) < 1e-9 then return end
		local da = -(j22 * r1 - j12 * r2) / det
		local db = -(-j21 * r1 + j11 * r2) / det
		local s = max(abs(da), abs(db))
		if s > 0.4 then da, db = da * 0.4 / s, db * 0.4 / s end
		a, b = a + da, b + db
	end
	local r1, r2 = res(a, b)
	if r1 and r1 * r1 + r2 * r2 < 9 then return a, b end
end

local function cvarFov()
	local v = C_CVar and C_CVar.GetCVar and C_CVar.GetCVar("cameraFov") or (GetCVar and GetCVar("cameraFov"))
	return tonumber(v) or 90
end

local function focalFor(W)
	local fov = ns.db.fov
	if fov and fov > 0 then return (W / 2) / tan(rad(fov) / 2) end
	if ns.db.calibF then return ns.db.calibF * W end
	return (W / 2) / tan(rad(cvarFov()) / 2)
end

function Dots.FovText()
	if ns.db.calibF then return format("auto (learned %.0f°)", deg(2 * atan(0.5 / ns.db.calibF))) end
	return format("auto (cameraFov %d°, steer with the right mouse button to calibrate)", cvarFov())
end

function Dots.ResetCalibration()
	ns.db.calibF = nil
	calib.samples = {}
end

-- While mouse-steering the camera yaw equals the facing; solve pitch and focal length instead.
local function calibrate(facing, F, d, ox, oy, m, W)
	if ns.db.fov and ns.db.fov > 0 then return end
	if abs(ox - scx) < 0.15 * W then return end
	local logf0 = math.log(focal)
	local pitch, logf = solve2(cam.pitch, logf0, function(p, lf)
		focal = math.exp(lf)
		setCamera(facing, p, F[1], F[2], F[3], d)
	end, ox, oy, m[1], m[2], m[3])
	focal = math.exp(logf0)
	if not pitch then return end
	local ratio = math.exp(logf) / W
	if ratio < 0.2 or ratio > 2.5 then return end
	local s = calib.samples
	if ns.db.calibF then
		if abs(ratio - ns.db.calibF) < 0.25 * ns.db.calibF then ns.db.calibF = ns.db.calibF * 0.97 + ratio * 0.03 end
	else
		s[#s + 1] = ratio
		if #s >= CALIB_SAMPLES then
			table.sort(s)
			ns.db.calibF = s[math.floor(#s / 2) + 1]
			ns.Debug(format("learned field of view: %.0f°", deg(2 * atan(0.5 / ns.db.calibF))))
		end
	end
end

local function dot(i)
	local t = pool[i]
	if not t then
		t = layer:CreateTexture(nil, "BACKGROUND")
		t:SetTexture(DOT)
		t:SetVertexColor(COLOR[1], COLOR[2], COLOR[3])
		pool[i] = t
	end
	return t
end

local function draw()
	local db, p = ns.db, ns.path
	if not db.dots or not db.marker or not p or not p.seg or ns.Marker.probing or not ns.Marker.IsActive() then return 0 end
	local nav = C_Navigation.GetFrame()
	if not nav or not C_Navigation.HasValidScreenPosition() or C_Navigation.WasClampedToScreen() then return 0 end
	local px, py, instance = ns.HBD:GetPlayerWorldPosition()
	if not px then return 0 end

	local ui = UIParent:GetEffectiveScale()
	local wf = WorldFrame:GetEffectiveScale()
	local wcx, wcy = WorldFrame:GetCenter()
	local W = WorldFrame:GetWidth() * wf / ui
	scx, scy = wcx * wf / ui, wcy * wf / ui
	local nx, ny = nav:GetCenter()
	if not nx then return 0 end
	local ns_ = nav:GetEffectiveScale() / ui
	local ox, oy = nx * ns_, ny * ns_
	focal = focalFor(W)

	local k = p.k
	-- Heights: the ground under the player and under each dot from the height map, else (no height data)
	-- the path's own corner heights in a straight line between corners.
	local ground = ns.Graph.HasGround(instance) and ns.player.z
	local pz
	if ground then
		pz = ns.Graph.GroundZ(instance, px, py, ground, 1) or ground
	else
		pz = select(3, ns.PointOnSeg(p, p.seg, p.segT or 0))
	end
	-- The game draws a user waypoint at the player's own height, whatever height it was given (measured
	-- with /gpath probe), so the marker sits pz + 0 while the camera pivots at pz + focus height.
	local m = { -p.x[k], p.y[k], pz }
	if (m[1] + px) ^ 2 + (m[2] - py) ^ 2 < 36 then return 0 end -- marker too close to solve against
	local h = db.focusHeight + (IsMounted() and 0.9 or 0)
	local F = { -px, py, pz + h }
	local d = GetCameraZoom() or 0
	local facing = GetPlayerFacing() or 0

	if IsMouselooking() then calibrate(facing, F, d, ox, oy, m, W) end

	local set = function(yaw, pitch) setCamera(yaw, pitch, F[1], F[2], F[3], d) end
	local yaw, pitch
	for _, guess in ipairs({ cam.yaw or facing, facing, facing + math.pi }) do
		yaw, pitch = solve2(guess, cam.pitch, set, ox, oy, m[1], m[2], m[3])
		if yaw and abs(pitch) < 1.55 then break end
		yaw = nil
	end
	if not yaw then
		cam.yaw = nil
		return 0
	end
	cam.yaw, cam.pitch = yaw, pitch
	set(yaw, pitch)
	-- one frame of the solve and the drawn dots, for /gpath probe
	local cap = Dots.capture
	if cap then
		Dots.capture = nil
		cap.solved = { nav = { ox, oy }, marker = m, focus = F, zoom = d, facing = facing, yaw = yaw, pitch = pitch, focal = focal, W = W, center = { scx, scy } }
		cap.dots = {}
	end
	local rec = Dots.record or (cap and cap.dots)

	local n = 0
	local range, size = db.dotRange, db.dotSize
	ns.SampleGround(p, instance, px, py, ground and pz, db.dotSpacing, range, function(x, y, z, along, lineZ)
		if n >= MAX_DOTS then return false end
		if along < 2 then return end
		local sx, sy, cf, dirz = project(-x, y, z + 0.05)
		if not sx then return end
		n = n + 1
		if rec then rec[n] = { x, y, z + 0.05, sx, sy, lineZ } end
		local t = dot(n)
		local s = min(40, max(3, size * focal / cf))
		t:SetSize(s, s * min(1, max(0.15, -dirz)))
		t:ClearAllPoints()
		t:SetPoint("CENTER", UIParent, "BOTTOMLEFT", sx, sy)
		local fadeIn = min(1, (along - 2) / 6)
		local fadeOut = min(1, (range - along) / (range * 0.35))
		t:SetAlpha(0.85 * fadeIn * fadeOut)
		t:Show()
	end)
	return n
end

local broken
layer:SetScript("OnUpdate", function()
	if broken then return end
	local ok, res = pcall(draw)
	if not ok then
		broken = true
		ns.Print("ground dots hit an error and are off until /reload: " .. tostring(res))
	end
	for i = (ok and res or 0) + 1, #pool do pool[i]:Hide() end
end)

-- /gpath probe: measures the game's camera for offline fitting. Takes a screenshot with the dots, then moves
-- the marker through points around the player and records where the game draws it on screen each time.
-- Saved in GuidelimePathfinderDB.probes (written to disk on /reload or logout).
local PROBE_ANGLES = { 0, 25, -25, 50, -50 }
local PROBE_DISTANCES = { 6, 12, 24, 48 }
local PROBE_RAISED = { { 12, 0, 5 }, { 24, 0, 10 }, { 12, 25, 5 }, { 24, -25, 10 }, { 12, 0, -3 } }
local PROBE_FRAMES = 8 -- frames per point; the last half are recorded
local PROBE_CVARS = { "cameraFov", "cameraDistanceMaxZoomFactor", "cameraPivot", "test_cameraOverShoulder",
	"test_cameraDynamicPitch", "test_cameraHeadMovementStrength", "cameraIndirectVisibility", "cameraWaterCollision",
	"renderScale", "uiScale", "useUiScale", "gxWindowedResolution", "gxFullscreenResolution", "gxMaximize", "screenshotFormat" }

local probe
local prober = CreateFrame("Frame")
prober:Hide()

local function cvar(name)
	local ok, v = pcall(function() return C_CVar and C_CVar.GetCVar(name) or GetCVar(name) end)
	return ok and v or nil
end

local function navSample()
	local nav = C_Navigation.GetFrame()
	local ui = UIParent:GetEffectiveScale()
	local nx, ny, s = nil, nil, 1
	if nav then
		nx, ny = nav:GetCenter()
		s = nav:GetEffectiveScale() / ui
	end
	return {
		nx and nx * s, ny and ny * s,
		C_Navigation.HasValidScreenPosition() and 1 or 0, C_Navigation.WasClampedToScreen() and 1 or 0,
		C_Navigation.GetDistance(), GetPlayerFacing(), GetCameraZoom(), IsMouselooking() and 1 or 0,
	}
end

local function finishProbe(msg)
	local pr = probe
	probe = nil
	prober:Hide()
	ns.Marker.probing = false
	ns.Marker.pathId, ns.Marker.k = nil, nil -- put the marker back on the path at the next tick
	if not ns.path then ns.Marker.Release() end
	if not pr then return end
	pr.rec.result = msg
	local list = ns.db.probes or {}
	ns.db.probes = list
	list[#list + 1] = pr.rec
	while #list > 6 do table.remove(list, 1) end
	ns.Print(format("probe %d saved (%s, %d points). Type /reload so it is written to disk.", #list, msg, #pr.rec.points))
end

prober:SetScript("OnUpdate", function()
	local pr = probe
	if not pr then prober:Hide() return end
	pr.frame = pr.frame + 1
	if pr.stage == "capture" then
		-- the dots layer filled Dots.capture during this frame (or could not draw); take the picture next
		if pr.frame >= 2 then
			pr.rec.capture = pr.capture.solved and pr.capture or nil
			pr.rec.navBefore = navSample()
			pr.rec.screenshot = date("%m%d%y_%H%M%S")
			Screenshot()
			pr.stage, pr.frame = "shot", 0
		end
	elseif pr.stage == "shot" then
		if pr.shotDone or pr.frame > 90 then
			ns.Marker.probing = true
			pr.stage, pr.frame, pr.i = "points", 0, 0
		end
	elseif pr.stage == "points" then
		local pt = pr.rec.points[pr.i]
		if pt and pr.frame > PROBE_FRAMES / 2 then pt.s[#pt.s + 1] = navSample() end
		if pr.i == 0 or pr.frame >= PROBE_FRAMES then
			pr.i, pr.frame = pr.i + 1, 0
			local nxt = pr.list[pr.i]
			if not nxt then return finishProbe("done") end
			if not ns.Marker.Place(nxt[1], nxt[2], nxt[3]) then return finishProbe("no map for a probe point") end
			pr.rec.points[pr.i] = { w = nxt, s = {} }
		end
	end
end)
prober:RegisterEvent("SCREENSHOT_SUCCEEDED")
prober:RegisterEvent("SCREENSHOT_FAILED")
prober:SetScript("OnEvent", function(_, event)
	if probe then probe.shotDone = event end
end)

function Dots.Probe()
	if probe then return end
	local px, py, instance = ns.HBD:GetPlayerWorldPosition()
	if not px then ns.Print("probe: no player position here") return end
	local p = ns.path
	local pz
	if p and p.seg then _, _, pz = ns.PointOnSeg(p, p.seg, p.segT or 0) end
	local u1, u2, u3, u4 = UnitPosition("player")
	local gz = ns.Graph.NearestZ(instance, px, py, IsIndoors())
	local z0 = ns.player.z or pz or gz or u3 or 0
	local facing = GetPlayerFacing() or 0
	local ui = UIParent:GetEffectiveScale()
	local wcx, wcy = WorldFrame:GetCenter()
	local physW, physH = GetPhysicalScreenSize()
	local rec = {
		version = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version"),
		build = { GetBuildInfo() },
		player = { x = px, y = py, instance = instance, pathZ = pz, graphZ = gz, groundZ = ns.player.z, unitPosition = { u1, u2, u3, u4 }, facing = facing,
			zoom = GetCameraZoom(), mounted = IsMounted(), indoors = IsIndoors(), race = select(2, UnitRace("player")),
			sex = UnitSex("player"), map = C_Map.GetBestMapForUnit("player") },
		screen = { ui = ui, uiW = UIParent:GetWidth(), uiH = UIParent:GetHeight(), worldW = WorldFrame:GetWidth(),
			worldH = WorldFrame:GetHeight(), worldScale = WorldFrame:GetEffectiveScale(), worldCenter = { wcx, wcy },
			physical = { physW, physH }, screenW = GetScreenWidth(), screenH = GetScreenHeight() },
		cvars = {},
		settings = { focusHeight = ns.db.focusHeight, fov = ns.db.fov, calibF = ns.db.calibF },
		points = {},
	}
	for _, name in ipairs(PROBE_CVARS) do rec.cvars[name] = cvar(name) end
	if p then
		rec.path = { n = p.n, k = p.k, seg = p.seg, segT = p.segT, graph = p.graph, corners = {} }
		for i = max(1, p.k - 3), min(p.n, p.k + 6) do rec.path.corners[#rec.path.corners + 1] = { i, p.x[i], p.y[i], p.z and p.z[i] } end
	end
	local wp = C_Map.GetUserWaypoint()
	if wp then rec.waypoint = { wp.uiMapID, wp.position.x, wp.position.y, wp.z } end

	local list = {}
	local function add(dist, ang, dz)
		local a = facing + rad(ang)
		list[#list + 1] = { px + dist * sin(a), py + dist * cos(a), z0 + dz }
	end
	for _, dist in ipairs(PROBE_DISTANCES) do
		for _, ang in ipairs(PROBE_ANGLES) do add(dist, ang, 0) end
	end
	for _, r in ipairs(PROBE_RAISED) do add(r[1], r[2], r[3]) end

	probe = { rec = rec, list = list, stage = "capture", frame = 0, capture = {} }
	Dots.capture = probe.capture
	ns.Print("probing the camera: hold still and keep the mouse off the camera for 4 seconds...")
	prober:Show()
end
