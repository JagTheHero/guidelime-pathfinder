local ADDON, ns = ...
GuidelimePathfinder = ns

local HBD = LibStub("HereBeDragons-2.0")
ns.HBD = HBD

local floor, sqrt, min, max, abs, huge = math.floor, math.sqrt, math.min, math.max, math.abs, math.huge

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
local GROUND_LOST = 1 -- seconds without ground that continues the tracked height before it jumps (a fall)

ns.player = {}
ns.goal = {}
local goalKey
local pathId = 0
local offSince

function ns.Print(...) print("|cff9fff3fGuidelime Pathfinder:|r", ...) end
function ns.Debug(...) if ns.db and ns.db.debug then ns.Print(...) end end

-- Fallback for steps Guidelime has no map position for (the custom WoW: Forever quests): read the active
-- steps from Guidelime's window, find the quests they name among those Questie has map icons for, and head
-- for the nearest icon. Questie draws where a quest goes next: its giver, its objectives or its turn-in.
local KEEP_PICK = 30  -- yards: stay on the chosen icon until another is this much closer
local fallback = { at = -10 }
ns.fallback = fallback
local questNames = {}

local function plainText(s)
	s = s:gsub("|T.-|t", " "):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	return (s:gsub("%[[^%]]*%]", " "):gsub("%(#%d+%)", ""))
end

-- Text of the steps Guidelime shows as active: pinned optional steps last, otherwise in guide order.
local function activeSteps()
	local win = _G.GuidelimeWindow
	if not win or not win.steps or not win:IsShown() then return end
	local inactive = GuidelimeData and GuidelimeData.fontColorInactive or "|cFF666666"
	local list = {}
	for i, f in pairs(win.steps) do
		if f.visible and f.textBox and f:IsShown() and not f:GetChecked() then
			local text = f.textBox:GetText() or ""
			-- inactive steps start with the inactive colour (after an optional line number)
			if not text:sub(1, #inactive + 6):find(inactive, 1, true) then
				list[#list + 1] = { i = i, text = plainText(text), pinned = f:GetParent() == win.pinnedStepsFrame }
			end
		end
	end
	table.sort(list, function(a, b)
		if a.pinned ~= b.pinned then return b.pinned end
		return a.i < b.i
	end)
	return list
end

local function questName(questMap, questId)
	if questNames[questId] then return questNames[questId] end
	for _, name in pairs(questMap.questIdFrames[questId]) do
		local f = _G[name]
		local q = f and f.data and f.data.Id == questId and f.data.QuestData
		if q and q.name then
			questNames[questId] = q.name
			return q.name
		end
	end
end

local function findFallback(px, py, instance)
	local questMap = QuestieLoader and QuestieLoader:ImportModule("QuestieMap")
	if not questMap or not questMap.questIdFrames then return nil, "Questie is not loaded" end
	local steps = activeSteps()
	if not steps then return nil, "open Guidelime's window so the step can be looked up in Questie" end
	for _, step in ipairs(steps) do
		local best, bestD, kept, keptD
		for questId, frames in pairs(questMap.questIdFrames) do
			local name = questName(questMap, questId)
			if name and #name >= 3 and step.text:find(name, 1, true) then
				for _, frameName in pairs(frames) do
					local f = _G[frameName]
					local d = f and f.data
					if d and d.Id == questId and not f.miniMapIcon and f.x and f.UiMapID
						and not (d.ObjectiveData and d.ObjectiveData.Completed) then
						local x, y, inst = HBD:GetWorldCoordinatesFromZone(f.x / 100, f.y / 100, f.UiMapID)
						if x and inst == instance then
							local dd = (x - px) ^ 2 + (y - py) ^ 2
							local c = { x = x, y = y, instance = inst, quest = name, kind = d.Type, name = d.Name }
							if not bestD or dd < bestD then best, bestD = c, dd end
							if fallback.x and abs(x - fallback.x) < 1 and abs(y - fallback.y) < 1 then kept, keptD = c, dd end
						end
					end
				end
			end
		end
		if best then
			if kept and sqrt(keptD) <= sqrt(bestD) + KEEP_PICK then return kept end
			return best
		end
	end
	return nil, "Questie shows no map icons on this continent for the quests in Guidelime's active steps"
end

-- Recomputed at most once a second; the pick is sticky so the route does not flip between objective spawns.
function ns.QuestieTarget(px, py, instance)
	local now = GetTime()
	if now - fallback.at >= 1 then
		fallback.at = now
		local pick, why = findFallback(px, py, instance)
		fallback.why = why
		fallback.x, fallback.y, fallback.instance = pick and pick.x, pick and pick.y, pick and pick.instance
		fallback.quest, fallback.kind, fallback.name = pick and pick.quest, pick and pick.kind, pick and pick.name
	end
	return fallback.x, fallback.y, fallback.instance
end

-- The current Guidelime arrow target, in HereBeDragons world coordinates, or the corpse while a ghost.
-- ns.targetSource says which: "guidelime", "questie" or "corpse".
function ns.GetTarget()
	ns.targetSource = nil
	if UnitIsGhost("player") then
		local zone = HBD:GetPlayerZone()
		local corpse = zone and C_DeathInfo.GetCorpseMapPosition(zone)
		if corpse then
			local x, y, instance = HBD:GetWorldCoordinatesFromZone(corpse.x, corpse.y, zone)
			if x then ns.targetSource = "corpse"; return x, y, instance end
		end
		return
	end
	local arrow = _G.GuidelimeArrow
	local el = arrow and arrow.element
	if not el or el.completed or not el.wx or not el.wy then
		local px, py, instance = HBD:GetPlayerWorldPosition()
		if not px then return end
		local x, y, inst = ns.QuestieTarget(px, py, instance)
		if x then ns.targetSource = "questie" end
		return x, y, inst
	end
	local tomtom = GuidelimeData and GuidelimeData.useTomTomArrow and TomTom
	if not arrow:IsShown() and not tomtom then return end
	ns.targetSource = "guidelime"
	return el.wx, el.wy, el.instance
end

-- Plain-words reason for /gpath status when there is no path.
function ns.WhyNoTarget()
	if not ns.db.enabled then return "turned off (/gpath turns it on)" end
	local px, _, instance = HBD:GetPlayerWorldPosition()
	if not px then return "the game gives no position here (instance or unmapped area)" end
	local arrow = _G.GuidelimeArrow
	local el = arrow and arrow.element
	if not arrow then return "Guidelime's arrow frame is not loaded" end
	if not el or el.completed or not el.wx or not el.wy then
		local why = not el and "Guidelime's current step has no map position"
			or el.completed and "Guidelime's current step is already done"
			or "Guidelime's current step has no world position"
		return why .. ", and no Questie fallback: " .. (fallback.why or "waiting for the next update")
	end
	local tomtom = GuidelimeData and GuidelimeData.useTomTomArrow and TomTom
	if not arrow:IsShown() and not tomtom then return "Guidelime's arrow is hidden (show it in Guidelime's options)" end
	if el.instance ~= instance then return format("the step is on another continent (%s, you are on %s)", tostring(el.instance), tostring(instance)) end
	return "waiting for the next update"
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

local OFFSET_EASE = 0.7 -- where no ground fits, the offset from the route's line shrinks by this each point

-- SamplePath with the ground height under each point from the height map, starting from height z0 at (x0, y0).
-- On a walkable route each height is predicted as the route's straight line between corners plus the offset
-- the ground had from that line at the point before. Following the offset rather than the height keeps the
-- route's layer where layers part slowly (a ramp down into a tunnel under the hillside, a bridge ramp); where
-- no ground fits (a narrow bridge between samples) it eases back to the line, which is on the route's layer
-- at every corner. A straight-line path (no corner heights) just continues the last height.
-- Without height data (or z0) the heights are the path's own. fn also gets the straight-line height.
function ns.SampleGround(p, instance, x0, y0, z0, spacing, maxDist, fn)
	if not z0 or not ns.Graph.HasGround(instance) then
		return ns.SamplePath(p, spacing, maxDist, function(x, y, z, along) return fn(x, y, z, along, z) end)
	end
	local anchored = p.graph and p.z
	local _, _, lineZ0 = ns.PointOnSeg(p, p.seg, p.segT or 0)
	local offset, rx, ry = z0 - lineZ0, x0, y0
	ns.SamplePath(p, spacing, maxDist, function(x, y, lineZ, along)
		local z, guess = ns.Graph.GroundZ(instance, x, y, lineZ + offset, dist(rx, ry, x, y))
		if not z then
			if anchored then offset = offset * OFFSET_EASE end
			z = not anchored and guess or lineZ + offset
		end
		offset, rx, ry = z - lineZ, x, y
		return fn(x, y, z, along, lineZ)
	end)
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

-- The game gives addons no player height, so follow the ground under the player on the height map from tick
-- to tick: the layer that continues from the last height (a bridge, not the river below it), predicted along
-- the route's straight line when on a walkable route (see SampleGround), jumping to the nearest layer only
-- after a moment without one (a fall, a teleport).
function ns.TrackGround(px, py, instance)
	local pl = ns.player
	local moved = pl.gx and pl.ginstance == instance and sqrt((px - pl.gx) ^ 2 + (py - pl.gy) ^ 2)
	local ref = moved and moved < 40 and pl.z or nil
	local p = ns.path
	local onRoute = p and p.graph and p.seg and (p.off or huge) < 10
	local lineZ = onRoute and select(3, ns.PointOnSeg(p, p.seg, p.segT or 0))
	local pred, reach = ref, moved
	if not ref then
		-- first height (login, teleport): the route's or the nearest route point's, which pick the floor of
		-- a building or the layer of a bridge, then the ground under the player within a few yards of it
		pred, reach = lineZ or ns.Graph.NearestZ(instance, px, py, IsIndoors()), 6
	elseif lineZ and pl.linePath == p.id then
		pred = lineZ + ref - pl.lineZ
	end
	local z, guess = ns.Graph.GroundZ(instance, px, py, pred, reach or 0)
	if z then
		pl.lost = nil
	elseif guess then
		pl.lost = pl.lost or GetTime()
		if GetTime() - pl.lost > GROUND_LOST then z, pl.lost = guess, nil end
	end
	pl.z = z or ref or pred
	pl.lineZ, pl.linePath = lineZ, lineZ and p.id
	pl.gx, pl.gy, pl.ginstance = px, py, instance
	return pl.z
end

local function tick()
	local db = ns.db
	if not db.enabled then return ns.Stop() end
	local px, py, instance = HBD:GetPlayerWorldPosition()
	if px then ns.TrackGround(px, py, instance) end
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
local shownErrors = {}
ticker:SetScript("OnUpdate", function(_, elapsed)
	elapsedSince = elapsedSince + elapsed
	if elapsedSince < 0.1 then return end
	elapsedSince = 0
	local ok, err = pcall(tick)
	if not ok and not shownErrors[err] then
		shownErrors[err] = true
		ns.Print("|cffff4040error:|r " .. tostring(err))
	end
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
	if ns.targetSource == "questie" then
		ns.Print(format("  target from Questie (Guidelime's step has no map position): %s for %s",
			({ available = "quest giver", complete = "turn-in" })[fallback.kind] or "objective", fallback.quest or "?")
			.. (fallback.name and (" (" .. fallback.name .. ")") or ""))
	end
	if p then
		ns.Print(format("  path: %d corners, %s, next corner %d, %.0f yd to go", p.n, p.graph and "walkable route" or "straight line", p.k, p.remaining or 0))
	else
		ns.Print("  no path: " .. ns.WhyNoTarget())
	end
	ns.Print("  marker " .. (ns.Marker.IsActive() and "placed" or "not placed") .. (ns.Marker.probing and " (probing)" or ""))
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
	elseif cmd == "probe" then
		ns.Dots.Probe()
	else
		ns.Print("/gpath  - turn on/off")
		ns.Print("/gpath marker | dots | minimap | worldmap | debug  - toggle a part")
		ns.Print("/gpath status | replan | probe (measure the camera for the ground dots)")
		ns.Print("/gpath spacing <yd> | range <yd> | size <yd> | height <yd> | fov <deg, 0 = auto>  - ground dot tuning")
	end
end
