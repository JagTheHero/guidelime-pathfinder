local ADDON, ns = ...

-- EXPERIMENTAL ground dots. Addons cannot project world points to the screen, but the game projects one
-- point for us: the in-world navigation marker. Knowing where that point is in the world, where the
-- player stands and how far the camera is zoomed out, we solve the camera's yaw and pitch so that our
-- own projection lands exactly on the marker, then project the path ahead with the same camera (pulled in where
-- the ground is in the way, as the game does).
-- The field of view follows the cameraFov CVar: the game's vertical field of view is 0.6 x cameraFov
-- (fitted to /gpath probe data: within a pixel at every zoom and pitch measured).

local Dots = {}
ns.Dots = Dots

local sin, cos, tan, sqrt, abs, min, max, rad, pi, floor = math.sin, math.cos, math.tan, math.sqrt, math.abs, math.min, math.max, math.rad, math.pi, math.floor
local DOT = "Interface\\AddOns\\" .. ADDON .. "\\Media\\dot"
local COLOR = { 0.62, 1, 0.25 }
local MAX_DOTS = 48
local VFOV_PER_FOV = 0.6
-- A marker nearer than the camera's distance has two cameras that put it on the same spot: the real one
-- and its mirror on the far side of the player looking back (often under the floor). Of the cameras that fit,
-- the one nearest the way the character faces wins (the game swings the camera behind a moving character);
-- one under the player's floor counts BELOW_COST per yard under it.
local BELOW_COST, FLOOR_SLACK = 4, 0.5
local KEEP_CAMERA = 0.25 -- seconds the last solved camera is used while the marker's spot is not ours yet
-- The game pulls the camera in where the line back from the player to it runs into the ground (a slope behind the
-- player, looking up from low down): it stays CAM_CLEAR yards over the ground, checked every CAM_STEP yards.
local CAM_CLEAR, CAM_STEP = 0.3, 0.5

-- Jumps and falls.
-- The camera goes up when the character jumps. It goes up slowly, and it does not go up the full height.
-- The game draws the marker at the height of the camera pivot. A /gpath trace recording shows this.
-- Thus the marker cannot tell us the camera height during a jump.
-- We calculate the height of the character from the jump speed and the gravity of the game.
-- We then put the camera at JUMP_CAMERA times that height.
-- JUMP_CAMERA is an estimate from two screenshots. It is not a measured value.
local JUMP_SPEED, GRAVITY, FALL_MAX = 7.9555, 19.2911, 60.148 -- yards per second, yards per second squared, yards per second
-- Seconds. If the character leaves the ground this soon after the jump key, it is a jump. If not, it is a fall.
local JUMP_GRACE = 0.3
local JUMP_CAMERA = 0.5
local air, jumpAt
if hooksecurefunc and JumpOrAscendStart then
	hooksecurefunc("JumpOrAscendStart", function()
		if not (IsFalling and IsFalling()) and not (IsSwimming and IsSwimming()) then jumpAt = GetTime() end
	end)
end

-- /gpath trace records one row for each frame. The rows go to GuidelimePathfinderDB.traces.
-- Use a trace to compare the solved camera with the game. The columns of a row are:
--    1 time              2 player x           3 player y              4 facing          5 zoom
--    6 marker screen x   7 marker screen y    8 marker distance       9 in the air      10 mouse look
--   11 ground height    12 tracked height    13 height above ground  14 camera yaw     15 camera pitch
--   16 camera distance  17 camera lift       18 marker x             19 marker y       20 pivot height
-- Columns 9 and 10 are 1 or 0. A value that the game does not give is 0.
local TRACE_SECONDS, TRACES_KEPT = 15, 2
local function traceFrame(tr, ...)
	local row = { ... }
	for i = 1, select("#", ...) do row[i] = row[i] or 0 end
	tr[#tr + 1] = row
	if row[1] - tr.t0 < TRACE_SECONDS then return end
	Dots.trace = nil
	local traces = ns.db.traces or {}
	ns.db.traces = traces
	traces[#traces + 1] = tr
	while #traces > TRACES_KEPT do table.remove(traces, 1) end
	ns.Print(format("Trace complete (%d frames). Type /reload to save it.", #tr))
end

-- Returns the height of the character above the ground, in yards. Returns 0 when the character is on the ground.
-- pz is the height of the ground below the character.
local function airHeight(pz, now)
	if not (IsFalling and IsFalling()) then
		air = nil
		return 0
	end
	if not air then
		-- The character left the ground in this frame. Record the time, the ground height and the upward speed.
		local jumped = jumpAt and now - jumpAt < JUMP_GRACE
		air = { t = jumped and jumpAt or now, z = pz, v = jumped and JUMP_SPEED or 0 }
		jumpAt = nil
	end
	local t, v = now - air.t, air.v
	local tm = (v + FALL_MAX) / GRAVITY -- the time when the fall gets to its maximum speed
	local dz = t <= tm and v * t - GRAVITY * t * t / 2 or v * tm - GRAVITY * tm * tm / 2 - FALL_MAX * (t - tm)
	return max(0, air.z + dz - pz)
end

local layer = CreateFrame("Frame", nil, UIParent)
layer:SetAllPoints()
layer:SetFrameStrata("BACKGROUND")
local pool = {}

local cam = { yaw = nil, pitch = 0.3, t = nil }

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
-- tol is the largest error that is a match, in pixels squared. The default is 0.25.
local function solve2(a, b, set, ox, oy, mE, mN, mU, tol)
	local function res(p, q)
		set(p, q)
		local sx, sy = project(mE, mN, mU)
		if sx then return sx - ox, sy - oy end
	end
	for _ = 1, 8 do
		local r1, r2 = res(a, b)
		if not r1 then return end
		if r1 * r1 + r2 * r2 < (tol or 0.25) then return a, b end
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

-- Position steps.
-- Some clients give the player position in steps of 0.1 yards. The marker position on the screen is exact.
-- Each step then turns the solved camera a small quantity, and the dots shake.
-- The dots shake more when the marker is near.
-- A player moves in an almost straight line during a quarter of a second.
-- Thus we fit a line through the positions of the last POS_WINDOW seconds.
-- We use the point on that line for the time now.
-- The result is never more than half a step from the position that the game gives.
-- If a position is not on a step, the client gives exact positions. Then we do not change them.
local POS_WINDOW, POS_STEP = 0.25, 0.1 -- seconds, yards
local pos, posExact = {}, false
local function smoothPosition(x, y, instance, now)
	if posExact then return x, y end
	local fx, fy = x / POS_STEP, y / POS_STEP
	if abs(fx - floor(fx + 0.5)) > 1e-3 or abs(fy - floor(fy + 0.5)) > 1e-3 then
		posExact = true -- This client gives exact positions. Do not smooth them in this session.
		return x, y
	end
	-- Start again after a teleport, a change of map, or a pause.
	local n = #pos
	if n > 0 and (pos.instance ~= instance or abs(x - pos[n][2]) > 2 or abs(y - pos[n][3]) > 2 or now - pos[n][1] > POS_WINDOW) then
		for i = n, 1, -1 do pos[i] = nil end
	end
	pos.instance = instance
	-- Remove the old samples. Use one of their tables again for the new sample.
	local s
	while pos[1] and pos[1][1] < now - POS_WINDOW do s = table.remove(pos, 1) end
	s = s or {}
	s[1], s[2], s[3] = now, x, y
	pos[#pos + 1] = s
	n = #pos
	if n < 4 then return x, y end
	-- Fit the line with least squares: x and y as functions of time.
	local tm, xm, ym = 0, 0, 0
	for i = 1, n do tm, xm, ym = tm + pos[i][1], xm + pos[i][2], ym + pos[i][3] end
	tm, xm, ym = tm / n, xm / n, ym / n
	local stt, stx, sty = 0, 0, 0
	for i = 1, n do
		local dt = pos[i][1] - tm
		stt, stx, sty = stt + dt * dt, stx + dt * (pos[i][2] - xm), sty + dt * (pos[i][3] - ym)
	end
	if stt < 1e-6 then return x, y end
	local half = POS_STEP / 2
	return min(max(xm + stx / stt * (now - tm), x - half), x + half), min(max(ym + sty / stt * (now - tm), y - half), y + half)
end
Dots.SmoothPosition = smoothPosition -- for the tests

-- Camera pivot height.
-- The camera turns about a point above the feet of the character. The height of this point changes with the character.
-- We measured 1.9 yards on one character and 1.68 yards on a different one.
-- If the height is incorrect, the solved pitch changes as the marker comes near.
-- When the marker moves to the next corner, the pitch jumps back. The dots move with the pitch.
-- We measure the height each time the marker moves to a new corner.
-- The frame before and the frame after show two markers through the same camera.
-- Only the correct height gives the same pitch for the two markers. fitFocus finds that height.
-- We keep the last FIT_KEEP results. We use their median when there are FIT_MIN or more.
-- If the user sets a height with /gpath height, we use that height.
local DEFAULT_FOCUS, FIT_KEEP, FIT_MIN = 1.9, 15, 3
local FIT_LOW, FIT_HIGH = 1, 3.2 -- yards. A result out of this range is an error.
local FIT_GAP = 0.5 -- seconds. The two frames must be this near in time.
-- Yards. The two markers must be at different distances, and one must be near. If not, the result is not accurate.
local FIT_SPREAD, FIT_NEAR = 10, 45
local fitHeight

-- Returns the pivot height that gives the frames a and b the same pitch. Returns nil if it finds none.
-- h is the first estimate. The search uses the secant method.
local function fitFocus(a, b, h)
	-- Returns the pitch of frame a minus the pitch of frame b for the pivot height hh.
	local function gap(hh)
		local _, p1 = solve2(a.yaw, a.pitch, function(y, p) setCamera(y, p, a.x, a.y, a.z + hh, a.d) end, a.ox, a.oy, a.m[1], a.m[2], a.m[3], 1e-4)
		local _, p2 = solve2(b.yaw, b.pitch, function(y, p) setCamera(y, p, b.x, b.y, b.z + hh, b.d) end, b.ox, b.oy, b.m[1], b.m[2], b.m[3], 1e-4)
		return p1 and p2 and p1 - p2
	end
	local h0, h1 = h, h - 0.2
	local g0, g1 = gap(h0), gap(h1)
	for _ = 1, 8 do
		if not g0 or not g1 or g0 == g1 then return end
		local h2 = h1 - g1 * (h1 - h0) / (g1 - g0)
		if h2 ~= h2 or h2 < 0.5 or h2 > 4 then return end
		h0, g0, h1, g1 = h1, g1, h2, gap(h2)
		if g1 and abs(g1) < 1e-5 then return h1 end
	end
end
Dots.FitFocus = fitFocus -- for the tests

-- Adds one measured pivot height to the saved results.
local function addFit(h)
	local fits = ns.db.focusFits or {}
	ns.db.focusFits = fits
	fits[#fits + 1] = h
	while #fits > FIT_KEEP do table.remove(fits, 1) end
	fitHeight = nil
end

-- Returns the pivot height to use, in yards.
local function focusHeight()
	local db = ns.db
	local fits = db.focusFits
	if db.focusHeight ~= DEFAULT_FOCUS or not fits or #fits < FIT_MIN then return db.focusHeight end
	if not fitHeight then
		local sorted = { unpack(fits) }
		table.sort(sorted)
		fitHeight = sorted[floor((#sorted + 1) / 2)]
	end
	return fitHeight
end
Dots.FocusHeight = focusHeight

local function cvarFov()
	local v = C_CVar and C_CVar.GetCVar and C_CVar.GetCVar("cameraFov") or (GetCVar and GetCVar("cameraFov"))
	return tonumber(v) or 90
end

-- W, H: the world view's size in UI units. /gpath fov (degrees across) overrides the CVar.
local function focalFor(W, H)
	local fov = ns.db.fov
	if fov and fov > 0 then return (W / 2) / tan(rad(fov) / 2) end
	return (H / 2) / tan(rad(cvarFov() * VFOV_PER_FOV) / 2)
end

-- /gpath trace: starts a recording of TRACE_SECONDS seconds (see traceFrame).
function Dots.Trace()
	Dots.trace = { t0 = GetTime(), zoom = GetCameraZoom(), focal = focal, focusHeight = focusHeight(), center = { scx, scy } }
	ns.Print(format("Trace started. It records %d seconds. Walk and jump. Keep the marker and the dots on the screen. Do not move the camera with the mouse.", TRACE_SECONDS))
end

function Dots.FovText()
	return format("auto (from cameraFov %d)", cvarFov())
end

local function wrap(a)
	return (a + pi) % (2 * pi) - pi
end

-- How far back from the pivot F the camera at (yaw, pitch) really is: the zoom, or less where the line back to it
-- runs into the ground on the player's level (at height pz).
local function cameraDistance(instance, F, yaw, pitch, zoom, pz)
	if zoom <= CAM_STEP or not ns.Graph.HasGround(instance) then return zoom end
	local bx, by, bz = sin(yaw) * cos(pitch), -cos(yaw) * cos(pitch), sin(pitch)
	for d = CAM_STEP, zoom, CAM_STEP do
		local g = ns.Graph.GroundZ(instance, -(F[1] + bx * d), F[2] + by * d, pz, d)
		if g and F[3] + bz * d < g + CAM_CLEAR then return max(CAM_STEP, d - CAM_STEP) end
	end
	return zoom
end
Dots.CameraDistance = cameraDistance

-- The camera (yaw, pitch) that puts marker m on screen at (ox, oy), pivoting at F at distance d: every fit
-- from guesses around the facing and the last camera, scored by how far it turns from the facing and how far
-- under the player's floor it puts the camera. Returns yaw, pitch or nil.
local function solveCamera(facing, F, d, ox, oy, m, floor)
	local set = function(yaw, pitch) setCamera(yaw, pitch, F[1], F[2], F[3], d) end
	local bestYaw, bestPitch, bestScore
	local function try(y0, p0)
		local yaw, pitch = solve2(y0, p0, set, ox, oy, m[1], m[2], m[3], 0.01)
		if not yaw or abs(pitch) >= 1.55 then return end
		local below = max(0, floor - FLOOR_SLACK - (F[3] + d * sin(pitch)))
		local score = abs(wrap(yaw - facing)) + BELOW_COST * below
		if not bestScore or score < bestScore then bestYaw, bestPitch, bestScore = wrap(yaw), pitch, score end
	end
	if cam.yaw then try(cam.yaw, cam.pitch) end
	for _, dy in ipairs({ 0, 0.8, -0.8, pi }) do
		for _, p0 in ipairs({ cam.pitch, 0.9, -0.3 }) do try(facing + dy, p0) end
	end
	return bestYaw, bestPitch
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
	px, py = smoothPosition(px, py, instance, GetTime())

	local ui = UIParent:GetEffectiveScale()
	local wf = WorldFrame:GetEffectiveScale()
	local wcx, wcy = WorldFrame:GetCenter()
	local W, H = WorldFrame:GetWidth() * wf / ui, WorldFrame:GetHeight() * wf / ui
	scx, scy = wcx * wf / ui, wcy * wf / ui
	local nx, ny = nav:GetCenter()
	if not nx then return 0 end
	local ns_ = nav:GetEffectiveScale() / ui
	local ox, oy = nx * ns_, ny * ns_
	focal = focalFor(W, H)

	-- Heights: the ground under the player and under each dot from the height map, else (no height data)
	-- the path's own corner heights in a straight line between corners.
	local ground = ns.Graph.HasGround(instance) and ns.player.z
	local pz
	if ground then
		pz = ns.Graph.GroundZ(instance, px, py, ground, 1) or ground
	else
		pz = select(3, ns.PointOnSeg(p, p.seg, p.segT or 0))
	end
	-- Where the game shows the marker: just after it moves on, the game may still show (and measure) it at the
	-- last corner for a frame, so of the spot it was put on and the one before, the one at the game's distance.
	-- The game draws a user waypoint at the player's own height, whatever height it was given (measured
	-- with /gpath probe), so the marker sits pz + 0 while the camera pivots at pz + focus height.
	local gd = C_Navigation.GetDistance and C_Navigation.GetDistance()
	local now = GetTime()
	local falling = IsFalling and IsFalling() or false
	local up = airHeight(pz, now)
	-- The height of the camera pivot and the marker above their height on the ground, in yards.
	local lift = db.jumpFix ~= false and JUMP_CAMERA * up or 0
	local m, md
	for _, at in ipairs({ ns.Marker.at, ns.Marker.before }) do
		local d2 = sqrt((at[1] - px) ^ 2 + (at[2] - py) ^ 2)
		if not gd or abs(gd - d2) <= max(1.5, 0.05 * d2) then
			m, md = { -at[1], at[2], pz + lift }, d2
			break
		end
	end
	if m and md < 6 then return 0 end -- marker too close to solve against
	local mounted = IsMounted()
	local h = focusHeight() + (mounted and 0.9 or 0)
	local F = { -px, py, pz + lift + h }
	local d = GetCameraZoom() or 0
	local facing = GetPlayerFacing() or 0

	-- no spot at the game's distance (it has not caught up yet): the last camera for a moment
	local yaw, pitch
	if m then
		yaw, pitch = solveCamera(facing, F, d, ox, oy, m, pz)
		-- pulled in by the ground: solve again from there with the nearer camera, until it settles
		for _ = 1, 3 do
			local cd = yaw and cameraDistance(instance, F, yaw, pitch, GetCameraZoom() or 0, pz)
			if not cd or abs(cd - d) < 0.25 then break end
			d = cd
			local y2, p2 = solve2(yaw, pitch, function(a, b) setCamera(a, b, F[1], F[2], F[3], d) end, ox, oy, m[1], m[2], m[3], 0.01)
			if not y2 then break end
			yaw, pitch = wrap(y2), p2
		end
	end
	if yaw then
		cam.yaw, cam.pitch, cam.t, cam.d = yaw, pitch, now, d
		-- Keep the data of this frame in b. The frame before is a.
		-- If the marker moved to a new corner between a and b, measure the pivot height (see fitFocus).
		local a, b = cam.last, cam.spare or {}
		b.t, b.x, b.y, b.z, b.d, b.ox, b.oy, b.m, b.md, b.yaw, b.pitch = now, F[1], F[2], pz + lift, d, ox, oy, m, md, yaw, pitch
		-- A frame is plain when the character is on the ground and on foot, the ground does not pull the camera in,
		-- and the mouse does not turn the camera. We measure only with plain frames.
		b.plain = not falling and not mounted and d == (GetCameraZoom() or 0) and not (IsMouselooking and IsMouselooking())
		if a and a.plain and b.plain and now - a.t < FIT_GAP and (a.m[1] ~= m[1] or a.m[2] ~= m[2])
			and abs(a.md - md) >= FIT_SPREAD and min(a.md, md) <= FIT_NEAR then
			local fit = fitFocus(a, b, h)
			if fit and fit > FIT_LOW and fit < FIT_HIGH then addFit(fit) end
		end
		cam.last, cam.spare = b, a
	elseif cam.yaw and cam.t and now - cam.t <= KEEP_CAMERA then
		yaw, pitch, d = cam.yaw, cam.pitch, cam.d or d
	else
		cam.yaw, cam.last = nil, nil
		return 0
	end
	setCamera(yaw, pitch, F[1], F[2], F[3], d)
	local tr = Dots.trace
	if tr then
		traceFrame(tr, now, px, py, facing, GetCameraZoom(), ox, oy, gd, falling and 1 or 0, IsMouselooking and IsMouselooking() and 1 or 0,
			pz, ns.player.z, up, yaw, pitch, d, lift, m and -m[1], m and m[2], h)
	end
	-- one frame of the solve and the drawn dots, for /gpath probe
	local cap = Dots.capture
	if cap then
		Dots.capture = nil
		cap.solved = { nav = { ox, oy }, marker = m, focus = F, zoom = d, facing = facing, yaw = yaw, pitch = pitch, focal = focal, W = W, H = H, center = { scx, scy }, navDistance = gd }
		cap.dots = {}
	end
	local rec = Dots.record or (cap and cap.dots)

	local n = 0
	local range, size = db.dotRange, db.dotSize
	ns.SampleGround(p, instance, px, py, ground and pz, db.dotSpacing, range, function(x, y, z, along, lineZ, unsure)
		if n >= MAX_DOTS then return false end
		if along < 2 or unsure then return end -- no dot in the air where the ground is not known
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
		settings = { focusHeight = ns.db.focusHeight, fov = ns.db.fov },
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
