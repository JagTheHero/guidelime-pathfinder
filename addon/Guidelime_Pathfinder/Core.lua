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
local OFF_LAYER = 30  -- yards above or below the path's line before replanning (the route is on another layer)
local ADVANCE = 7     -- yards from a corner before the marker moves to the next one
local GROUND_LOST = 1 -- seconds without ground that continues the tracked height before it jumps (a fall)
-- trips (flight paths, boats, zeppelins, lifts, the tram, portals): yards from where a ride starts that count as
-- being there, and from where it ends that count as arrived (a ship stops off its dock); seconds past a ride's
-- wait and ride before it counts as missed
local AT_START = { boat = 30, zeppelin = 30, lift = 8, tram = 15, portal = 15 }
local ARRIVED = { boat = 50, zeppelin = 40, lift = 60, tram = 40, portal = 40 } -- a lift's end is told by height
local RIDE_SPARE = 90

ns.player = {}
ns.goal = {}
local goalKey
local pathId = 0
local offSince

function ns.Print(...) print("|cff9fff3fGuidelime Pathfinder:|r", ...) end
function ns.Debug(...) if ns.db and ns.db.debug then ns.Print(...) end end

-- Fallback for steps Guidelime has no map position for (the custom WoW: Forever quests): read the active
-- steps from Guidelime's window, find the quests they name among those Questie has map icons for, and head
-- for the nearest icon that fits what the step does with the quest: the quest giver for an accept, the turn-in
-- (or, objectives left, the quest's finisher) for a turn-in, objectives otherwise. Several quests can share a
-- name (Darkshore's beached sea creatures): a turn-in is never sent to another one's quest giver.
local KEEP_PICK = 30  -- yards: stay on the chosen icon until another is this much closer
local fallback = { at = -10 }
ns.fallback = fallback
local questNames = {}
-- what the icon Guidelime puts in front of each quest a step names says (its addon.icons); any other icon is
-- an objective's
local ICON_KINDS = { AvailableQuestIcon = "accept", questunavailable = "accept", ActiveQuestIcon = "turnin",
	IncompleteQuestIcon = "turnin", ["UI-CheckBox-Check"] = "done", ["UI-GroupLoot-Pass-Up"] = "done" }

local function plainText(s)
	s = s:gsub("|T.-|t", " "):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	return (s:gsub("%[[^%]]*%]", " "):gsub("%(#%d+%)", ""))
end

-- A step's text in parts, one per icon: { kind = what the icon says (nil before the first), text }.
local function stepParts(text)
	local parts, pos, kind = {}, 1, nil
	while true do
		local s, e, icon = text:find("|T([^:|]+)[^|]*|t", pos)
		local chunk = text:sub(pos, (s or 0) - 1)
		if chunk:find("%w") then parts[#parts + 1] = { kind = kind, text = plainText(chunk) } end
		if not s then return parts end
		kind = ICON_KINDS[icon:match("([^\\/]+)$")] or "complete"
		pos = e + 1
	end
end

-- The steps Guidelime shows as active, in parts: pinned optional steps last, otherwise in guide order.
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
				list[#list + 1] = { i = i, parts = stepParts(text), pinned = f:GetParent() == win.pinnedStepsFrame }
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
	for _, name in pairs(questMap and questMap.questIdFrames[questId] or {}) do
		local f = _G[name]
		local q = f and f.data and f.data.Id == questId and f.data.QuestData
		if q and q.name then
			questNames[questId] = q.name
			return q.name
		end
	end
	local DB = QuestieLoader:ImportModule("QuestieDB")
	local name = DB and DB.QueryQuestSingle and DB.QueryQuestSingle(questId, "name")
	questNames[questId] = name
	return name
end

-- does a Questie map icon of this type fit what the step does with its quest?
local function iconFits(kind, icon)
	if kind == "accept" then return icon == "available" end
	if kind == "turnin" then return icon == "complete" end
	if kind == "complete" then return icon ~= "available" end
	return true
end

-- Where an NPC or object stands, from Questie's database (query: QueryNPCSingle or QueryObjectSingle), added
-- to out as { instance, x, y, uiMap } in world coordinates.
local function spawnSpots(query, id, out)
	local Z = QuestieLoader:ImportModule("ZoneDB")
	for area, list in pairs(query(id, "spawns") or {}) do
		local uiMap = not Z.IsDungeonZone(area) and Z:GetUiMapIdByAreaId(area)
		for _, c in ipairs(uiMap and list or {}) do
			local x, y, inst
			if c[1] >= 0 then x, y, inst = HBD:GetWorldCoordinatesFromZone(c[1] / 100, c[2] / 100, uiMap) end
			if x then out[#out + 1] = { instance = inst, x = x, y = y, uiMap = uiMap } end
		end
	end
	return out
end

-- Where a quest starts (field "startedBy") or ends ("finishedBy"): its NPCs' and objects' spots, with names.
local function questSpots(questId, field)
	local DB = QuestieLoader:ImportModule("QuestieDB")
	local by = DB and DB.QueryQuestSingle and DB.QueryQuestSingle(questId, field)
	local out = {}
	for k, query in ipairs({ DB and DB.QueryNPCSingle or false, DB and DB.QueryObjectSingle or false }) do
		for _, id in ipairs(query and by and by[k] or {}) do
			local n = #out
			spawnSpots(query, id, out)
			for i = n + 1, #out do out[i].name = query(id, "name") end
		end
	end
	return out
end

local function findFallback(px, py, instance)
	local questMap = QuestieLoader and QuestieLoader:ImportModule("QuestieMap")
	if not questMap or not questMap.questIdFrames then return nil, "Questie is not loaded" end
	local steps = activeSteps()
	if not steps then return nil, "open Guidelime's window so the step can be looked up in Questie" end
	local questiePlayer = QuestieLoader:ImportModule("QuestiePlayer")
	local log = questiePlayer and questiePlayer.currentQuestlog or {}
	local ids = {}
	for questId in pairs(questMap.questIdFrames) do ids[questId] = true end
	for questId in pairs(log) do ids[questId] = true end
	for _, step in ipairs(steps) do
		local best, bestD, kept, keptD
		local function consider(x, y, inst, c)
			if not x or inst ~= instance then return end
			local dd = (x - px) ^ 2 + (y - py) ^ 2
			c.x, c.y, c.instance = x, y, inst
			if not bestD or dd < bestD then best, bestD = c, dd end
			if fallback.x and abs(x - fallback.x) < 1 and abs(y - fallback.y) < 1 then kept, keptD = c, dd end
		end
		for _, part in ipairs(step.parts) do
			if part.kind ~= "done" then
				for questId in pairs(ids) do
					local name = questName(questMap, questId)
					if name and #name >= 3 and part.text:find(name, 1, true) then
						local icons = 0
						for _, frameName in pairs(questMap.questIdFrames[questId] or {}) do
							local f = _G[frameName]
							local d = f and f.data
							if d and d.Id == questId and not f.miniMapIcon and f.x and f.UiMapID and iconFits(part.kind, d.Type)
								and not (d.ObjectiveData and d.ObjectiveData.Completed) then
								icons = icons + 1
								local x, y, inst = HBD:GetWorldCoordinatesFromZone(f.x / 100, f.y / 100, f.UiMapID)
								consider(x, y, inst, { quest = name, kind = d.Type, name = d.Name })
							end
						end
						-- a turn-in Questie draws no icon for yet (objectives left): the quest's finisher
						if part.kind == "turnin" and icons == 0 and log[questId] then
							for _, sp in ipairs(questSpots(questId, "finishedBy")) do
								consider(sp.x, sp.y, sp.instance, { quest = name, kind = "complete", name = sp.name })
							end
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

-- Guidelime's spot for a quest giver or a turn-in, checked against Questie's database (its WoW: Forever data):
-- within CHECK_REACH of one of the quest's NPCs or objects, that one's own spot is the target, so the route ends
-- where it stands (on its floor, its pier); farther from all of them, Guidelime's spot is wrong for Forever and
-- the nearest of them is the target, said once.
local CHECK_REACH = 40
local checked = setmetatable({}, { __mode = "k" })
local function checkedSpot(el, px, py)
	local q = el.attached
	local field = q and q.questId and not q.completed and (q.t == "TURNIN" and "finishedBy" or q.t == "ACCEPT" and "startedBy")
	if not field or not QuestieLoader then return end
	local c = checked[el]
	if c == nil then
		c = false
		local spots, near, nearD = {}, nil, nil
		for _, sp in ipairs(questSpots(q.questId, field)) do
			if sp.instance == el.instance then
				spots[#spots + 1] = sp
				local d = sqrt((sp.x - el.wx) ^ 2 + (sp.y - el.wy) ^ 2)
				if not nearD or d < nearD then near, nearD = sp, d end
			end
		end
		if near and nearD <= CHECK_REACH then
			c = { spot = near }
		elseif near then
			c = { spots = spots, note = format("Guidelime's spot for %s is %d yd from %s in Questie's data; heading there instead",
				q.title or questName(nil, q.questId) or "this quest",
				floor(nearD + 0.5), near.name or "its NPC") }
			ns.Print(c.note)
		end
		checked[el] = c
	end
	if not c then return end
	ns.checkNote = c.note
	if c.spot then return c.spot end
	local best, bestD
	for _, sp in ipairs(c.spots) do
		local d = (sp.x - px) ^ 2 + (sp.y - py) ^ 2
		if not bestD or d < bestD then best, bestD = sp, d end
	end
	return best
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

-- The current Guidelime arrow target, in HereBeDragons world coordinates, or the corpse while a ghost, or the
-- town service from /gpath go (with its height). ns.targetSource says which: "guidelime", "questie", "corpse"
-- or "service".
function ns.GetTarget()
	ns.targetSource, ns.checkNote = nil, nil
	if UnitIsGhost("player") then
		local zone = HBD:GetPlayerZone()
		local corpse = zone and C_DeathInfo.GetCorpseMapPosition(zone)
		if corpse then
			local x, y, instance = HBD:GetWorldCoordinatesFromZone(corpse.x, corpse.y, zone)
			if x then ns.targetSource = "corpse"; return x, y, instance end
		end
		return
	end
	local sv = ns.service
	if sv then
		ns.targetSource = "service"
		return sv.x, sv.y, sv.instance, sv.z
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
	local px, py = HBD:GetPlayerWorldPosition()
	local spot = px and checkedSpot(el, px, py)
	if spot then return spot.x, spot.y, spot.instance end
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
	if el.instance ~= instance then
		return format("the step is on another continent (%s, you are on %s) and no boat or zeppelin you can take goes there", tostring(el.instance), tostring(instance))
	end
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

-- Plans the trip to the goal (unless keepCurrent: an off-route replan) and the walk to where its next ride or
-- flight starts, or to the goal.
function ns.Plan(px, py, keepCurrent)
	if not keepCurrent then ns.PlanTrip(px, py) end
	local d = ns.dest
	if not d or d.instance ~= ns.player.instance then return ns.Pause() end
	if not keepCurrent or not ns.path then
		ns.SetPath({ x = { px, d.x }, y = { py, d.y }, n = 2 }, false)
	end
	if not ns.Graph.Has(d.instance) or d.straight then return end
	local key = goalKey
	ns.planning = true
	ns.Graph.FindPath(d.instance, px, py, d.x, d.y, IsIndoors(), function(p)
		ns.planning = false
		if key ~= goalKey then return end
		if p then
			-- no route from the player's layer nearby: do not keep replanning for being on another layer
			p.otherLayer = ns.player.z and abs(p.z[1] - ns.player.z) > OFF_LAYER
			ns.SetPath(p, true)
		end
	end, ns.player.z, d.z)
end

function ns.Stop()
	if goalKey or ns.path then
		goalKey, ns.path, ns.planning = nil, nil, false
		ns.trip, ns.dest, ns.riding = nil, nil, nil
		ns.Marker.Release()
		ns.Trail.Refresh()
	end
end

-- Nothing to walk for now (flying, on a boat, no way there): no marker or trail, but the plan stays.
function ns.Pause()
	if ns.path then
		ns.path = nil
		ns.Marker.Release()
		ns.Trail.Refresh()
	end
end

-- Trips -------------------------------------------------------------------------------------------------------
-- Graph.PlanTrip picks walking, flight paths and rides; the route walks to where the next flight or ride
-- starts (ns.trip.next), and the plan is made again from wherever the player is once it is over. The game
-- says which flight masters the player has found; the taxi map highlights where to fly.
local CONTINENT_MAP = { [0] = 1415, [1] = 1414 }
local FACTION = { Alliance = "A", Horde = "H" }
local TAXI_FACTION = { Horde = 1, Alliance = 2 } -- Enum.FlightPathFaction; 0 is neutral
local KNOWN_FOR = 10 -- seconds the list of found flight masters is reused
local known, knownAt, knownCount = {}, -huge, 0

local function taxiNodes(mapID, mine, into)
	local nodes = C_TaxiMap.GetTaxiNodesForMap(mapID) or {}
	for _, n in ipairs(nodes) do
		if not n.isUndiscovered and (n.faction == 0 or n.faction == mine) and n.nodeID then into[n.nodeID] = n.name end
	end
	return #nodes
end

-- [node id] = name of every flight master the player has found and may use
function ns.KnownTaxi()
	if GetTime() - knownAt < KNOWN_FOR then return known, knownCount end
	knownAt = GetTime()
	local found = {}
	if C_TaxiMap and C_TaxiMap.GetTaxiNodesForMap then
		local mine = TAXI_FACTION[UnitFactionGroup("player")]
		for _, mapID in pairs(CONTINENT_MAP) do
			-- no nodes on the continent map: ask its zones
			if taxiNodes(mapID, mine, found) == 0 and C_Map.GetMapChildrenInfo then
				for _, child in ipairs(C_Map.GetMapChildrenInfo(mapID, 3) or {}) do taxiNodes(child.mapID, mine, found) end
			end
		end
	end
	local n, changed = 0, false
	for id, name in pairs(found) do
		n = n + 1
		if known[id] ~= name then changed = true end
	end
	if changed or n ~= knownCount then
		known, knownCount = found, n
		if not ns.riding then goalKey = nil end -- plan again with them
	end
	return known, knownCount
end

function ns.Speed()
	local _, run = GetUnitSpeed("player")
	return max(7, run or 7)
end

-- the zone at a world position, for a ship whose far stop has no name in the data
local function placeName(pl)
	local mapID = CONTINENT_MAP[pl.instance]
	local x, y = mapID and HBD:GetZoneCoordinatesFromWorld(pl.x, pl.y, mapID, true)
	local info = x and C_Map.GetMapInfoAtPosition and C_Map.GetMapInfoAtPosition(mapID, x, y)
	return info and info.name
end

function ns.LegText(l)
	if l.kind == "flight" then return "fly to " .. (l.to.name or "the next flight master") end
	if l.kind == "lift" then return "take the lift " .. l.name end
	local to = l.name ~= "" and l.name or placeName(l.to) or "the far shore"
	if l.kind == "tram" then return "ride the Deeprun Tram to " .. to end
	return "take the " .. l.kind .. " to " .. to
end

function ns.TripText(trip)
	local parts = {}
	for _, l in ipairs(trip.legs) do
		if l.kind ~= "walk" then parts[#parts + 1] = ns.LegText(l) end
	end
	return table.concat(parts, ", then ")
end

local function hint(text)
	ns.Print(text)
	if UIErrorsFrame then UIErrorsFrame:AddMessage(text, 0.62, 1, 0.25) end
end

local function tripOpts()
	return { speed = ns.Speed(), faction = FACTION[UnitFactionGroup("player")], known = (ns.KnownTaxi()) }
end

local said
function ns.PlanTrip(px, py)
	local pl, g = ns.player, ns.goal
	local trip, unreachable = ns.Graph.PlanTrip({ instance = pl.instance, x = px, y = py, z = pl.z }, { instance = g.instance, x = g.x, y = g.y, z = g.z }, tripOpts())
	ns.trip, ns.riding = trip, nil
	local nextLeg
	for _, l in ipairs(trip and trip.legs or {}) do
		if l.kind ~= "walk" then nextLeg = l break end
	end
	if nextLeg then
		trip.next = nextLeg
		local f = nextLeg.from
		ns.dest = { instance = f.instance, x = f.x, y = f.y, z = f.z }
		local text = ns.TripText(trip)
		if text ~= said then
			said = text
			ns.Print(format("route: %s (about %d min)", text, floor(trip.cost / 60 + 0.5)))
		end
	else
		said = nil
		-- no walkable way there (no lift, boat or portal either): a straight line, without a hopeless search
		ns.dest = g.instance == pl.instance and { instance = g.instance, x = g.x, y = g.y, z = g.z, straight = unreachable } or nil
	end
end

-- While the next leg is a ride: says what to do at its start, notices the ride under way and its end (then
-- the plan is made again). Returns true while riding (nothing to walk).
function ns.FollowRide(px, py, instance)
	local trip = ns.trip
	local l = trip and trip.next
	if not l then return false end
	local f, t, pz = l.from, l.to, ns.player.z
	if l.kind == "flight" then -- the flight itself is UnitOnTaxi's
		if not trip.boarded and instance == f.instance and dist(px, py, f.x, f.y) < 12 then
			trip.boarded = GetTime()
			hint(ns.LegText(l) .. ": talk to the flight master")
		end
		return false
	end
	local near = AT_START[l.kind] or 15
	local dFrom = instance == f.instance and dist(px, py, f.x, f.y) or huge
	local atStart = dFrom < near and (l.kind ~= "lift" or not pz or abs(pz - f.z) < 10)
	if atStart then
		if not trip.boarded then hint(ns.LegText(l)) end
		trip.boarded = GetTime()
	end
	local arrived = instance == t.instance and dist(px, py, t.x, t.y) < (ARRIVED[l.kind] or 40)
		and (l.kind ~= "lift" or (pz and abs(pz - t.z) < 10))
	if arrived then
		ns.riding, goalKey = nil, nil -- plan the rest from here
		return false
	end
	if trip.boarded and dFrom > near + 10 then
		if GetTime() - trip.boarded > l.wait * 2 + l.ride + RIDE_SPARE then
			ns.riding, goalKey = nil, nil -- missed it, or got off: plan again
			return false
		end
		ns.riding = l
		return true
	end
	ns.riding = nil
	return false
end

-- the taxi map: highlight the flight master to fly to
local lit
local function lightTaxi()
	local l = ns.trip and ns.trip.next
	if not l or l.kind ~= "flight" or not NumTaxiNodes then return end
	for i = 1, NumTaxiNodes() do
		if TaxiNodeName(i) == l.to.name then
			lit = _G["TaxiButton" .. i]
			if lit and lit.LockHighlight then lit:LockHighlight() end
			ns.Print("fly to " .. l.to.name)
			return
		end
	end
end

-- Town services (/gpath go bank): Questie knows where every banker, auctioneer, innkeeper, mailbox, trainer
-- and vendor stands. Head for the one quickest to reach (walking, flights and rides) instead of Guidelime's
-- step, until there.
local SERVICE_ARRIVED = 10 -- yards from it that count as there
local SERVICE_WORDS = { -- short words for Questie's names; any start of a name works too ("bank", "inn")
	ah = "Auctioneer", auctionhouse = "Auctioneer", fm = "Flight Master", trainer = "Class Trainer",
	bg = "Battlemaster", graveyard = "Spirit Healer",
}

local function squash(s) return (s:lower():gsub("[%s_'%-]", "")) end

-- name -> NPC (or object) ids, as Questie's townsfolk menu has them
local function serviceLists()
	local T = QuestieLoader:ImportModule("Townsfolk")
	local char = Questie and Questie.db and Questie.db.char
	local lists = {}
	for _, src in ipairs({ T and T.townsfolk, char and char.townsfolk, char and char.vendorList }) do
		for name, ids in pairs(src or {}) do
			if type(ids) == "table" and #ids > 0 and not lists[name] then lists[name] = ids end
		end
	end
	local P = QuestieLoader:ImportModule("QuestieProfessions")
	for key, prof in pairs(P and P.professionKeys or {}) do
		local ids = T and T.professionTrainers and T.professionTrainers[prof]
		if ids and #ids > 0 then lists[key:sub(1, 1) .. key:sub(2):lower():gsub("_", " ") .. " Trainer"] = ids end
	end
	return lists
end

-- every place one of them stands that the player's faction may use, in world coordinates
local function serviceSpots(name, ids)
	local DB = QuestieLoader:ImportModule("QuestieDB")
	local C = QuestieLoader:ImportModule("QuestieCorrections")
	local blacklist = C and C.questNPCBlacklist or {}
	local object = name == "Mailbox" or name == "Meeting Stones"
	local query = object and DB.QueryObjectSingle or DB.QueryNPCSingle
	local mine = FACTION[UnitFactionGroup("player")]
	local spots = {}
	for _, id in ipairs(ids) do
		local friendly = not object and query(id, "friendlyToFaction")
		if not blacklist[id] and (not friendly or friendly == "AH" or friendly == mine) then
			local n = #spots
			spawnSpots(query, id, spots)
			for i = n + 1, #spots do
				local sp = spots[i]
				sp.z, sp.name = ns.Graph.LikelyZ(sp.instance, sp.x, sp.y), query(id, "name")
			end
		end
	end
	return spots
end

-- word: what the player typed after /gpath go; nil or "" stops
function ns.GoService(word)
	if not word or word == "" then
		if ns.service then ns.Print("stopped heading for the " .. ns.service.what .. "; back to Guidelime's step") end
		ns.service = nil
		return
	end
	if not QuestieLoader then return ns.Print("the town services come from Questie, which is not loaded") end
	local lists = serviceLists()
	if not next(lists) then return ns.Print("Questie has not finished loading its town services; try again in a moment") end
	local w = squash(SERVICE_WORDS[squash(word)] or word)
	local name, matches = nil, {}
	for n in pairs(lists) do
		if squash(n) == w then name = n end
		if squash(n):sub(1, #w) == w then matches[#matches + 1] = n:lower() end
	end
	if not name and #matches == 1 then
		for n in pairs(lists) do if n:lower() == matches[1] then name = n end end
	end
	if not name then
		local unknown = #matches == 0
		if unknown then for n in pairs(lists) do matches[#matches + 1] = n:lower() end end
		table.sort(matches)
		return ns.Print(format("%s: %s", unknown and ("no " .. word .. " in Questie's town services; there are") or (word .. " could be"), table.concat(matches, ", ")))
	end
	local px, py, instance = HBD:GetPlayerWorldPosition()
	if not px then return ns.Print("the game gives no position here") end
	local spots = serviceSpots(name, lists[name])
	local trip = ns.Graph.PlanTrip({ instance = instance, x = px, y = py, z = ns.player.z }, spots, tripOpts())
	local pick = trip and spots[trip.goal]
	if not pick then -- off the walkable graph: the nearest on this continent in a straight line
		local best
		for _, s in ipairs(spots) do
			local d = s.instance == instance and dist(px, py, s.x, s.y)
			if d and (not best or d < best) then pick, best = s, d end
		end
	end
	if not pick then return ns.Print(format("no %s you can get to from here", name:lower())) end
	pick.what = name:lower()
	ns.service = pick
	local zone = C_Map.GetMapInfo(pick.uiMap)
	ns.Print(format("nearest %s: %s%s%s", pick.what, pick.name or "?", zone and zone.name and (" in " .. zone.name) or "",
		not trip and "" or trip.cost < 60 and ", under a minute away" or format(", about %d min away", floor(trip.cost / 60 + 0.5))))
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
	local saved = not pl.gx and ns.db.ground
	if saved and saved[1] == instance and sqrt((px - saved[2]) ^ 2 + (py - saved[3]) ^ 2) < 3 then
		pred, reach = saved[4], 0 -- after a /reload or a login: where the player stood at the logout
	elseif not ref then
		-- first height (a teleport, or no saved one): the layer most path nodes around are on, which picks the
		-- floor of a building or the halls under a mountain, then the ground under the player within a few
		-- yards of it. Not the route's: a route can start on another layer (it is planned from this height).
		pred, reach = ns.Graph.LikelyZ(instance, px, py), 6
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

local planInstance
local function tick()
	local db = ns.db
	if not db.enabled then return ns.Stop() end
	if UnitOnTaxi("player") then
		ns.flying = true
		return ns.Pause()
	end
	if ns.flying then ns.flying, goalKey = nil, nil end -- landed: plan the rest from here
	local px, py, instance = HBD:GetPlayerWorldPosition()
	if px then ns.TrackGround(px, py, instance) end
	local sv = ns.service
	if sv and px and instance == sv.instance and dist(px, py, sv.x, sv.y) < SERVICE_ARRIVED then
		ns.service = nil
		hint(format("here: %s (%s)", sv.name or "?", sv.what))
	end
	local tx, ty, tinstance, tz = ns.GetTarget()
	if not px or not tx then return ns.Stop() end
	ns.player.x, ns.player.y, ns.player.instance = px, py, instance
	ns.KnownTaxi()
	local riding = ns.FollowRide(px, py, instance)
	if instance ~= planInstance and not riding then goalKey = nil end

	local key = tinstance .. ":" .. floor(tx) .. ":" .. floor(ty)
	if key ~= goalKey then
		goalKey, planInstance = key, instance
		ns.goal.x, ns.goal.y, ns.goal.instance, ns.goal.z = tx, ty, tinstance, tz
		ns.Marker.ResetOverride()
		ns.Plan(px, py)
	end
	if riding then return ns.Pause() end
	if not ns.dest or ns.dest.instance ~= instance then return ns.Pause() end

	local p = ns.path
	if p then
		if not p.graph then
			p.x[1], p.y[1] = px, py
			measure(p)
		end
		ns.Follow(p, px, py)
		local pz = ns.player.z
		local offLayer = p.graph and pz and not p.otherLayer and abs(pz - select(3, ns.PointOnSeg(p, p.seg, p.segT or 0))) > OFF_LAYER
		if p.graph and (p.off > OFF_PATH or offLayer) then
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
events:RegisterEvent("PLAYER_LOGOUT")
events:RegisterEvent("USER_WAYPOINT_UPDATED")
events:RegisterEvent("TAXIMAP_OPENED")
events:RegisterEvent("TAXIMAP_CLOSED")
events:RegisterEvent("TAXI_NODE_STATUS_CHANGED")
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
	elseif event == "PLAYER_LOGOUT" then -- also on /reload: the height to start from after it
		local pl = ns.player
		ns.db.ground = pl.gx and pl.z and { pl.ginstance, pl.gx, pl.gy, pl.z } or nil
	elseif event == "USER_WAYPOINT_UPDATED" then
		ns.Marker.OnWaypointUpdated()
	else -- the taxi map: a flight master just found counts at once
		knownAt = -huge
		if event == "TAXIMAP_OPENED" then
			C_Timer.After(0, lightTaxi) -- after the taxi frame has made its buttons
		elseif event == "TAXIMAP_CLOSED" and lit then
			lit:UnlockHighlight()
			lit = nil
		end
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
	if ns.targetSource == "service" then
		ns.Print(format("  heading for the nearest %s: %s (/gpath go stops)", ns.service.what, ns.service.name or "?"))
	end
	if ns.targetSource == "questie" then
		ns.Print(format("  target from Questie (Guidelime's step has no map position): %s for %s",
			({ available = "quest giver", complete = "turn-in" })[fallback.kind] or "objective", fallback.quest or "?")
			.. (fallback.name and (" (" .. fallback.name .. ")") or ""))
	end
	if ns.checkNote then ns.Print("  " .. ns.checkNote) end
	if ns.player.z then
		local line = p and p.graph and p.seg and select(3, ns.PointOnSeg(p, p.seg, p.segT or 0))
		ns.Print(format("  ground height under you %.1f yd%s", ns.player.z, line and format(", route here %.1f yd", line) or ""))
	end
	local _, found = ns.KnownTaxi()
	ns.Print(format("  flight paths: %d found%s", found, found == 0 and " (the game lists none yet)" or ""))
	local trip = ns.trip
	if trip and trip.next then
		ns.Print(format("  trip: %s (about %d min)%s", ns.TripText(trip), floor(trip.cost / 60 + 0.5),
			ns.flying and ", flying now" or ns.riding and ", under way" or ""))
	end
	if p then
		ns.Print(format("  path: %d corners, %s, next corner %d, %.0f yd to go", p.n, p.graph and "walkable route" or "straight line", p.k, p.remaining or 0))
	elseif ns.flying or ns.riding then
		ns.Print("  no path while " .. (ns.flying and "flying" or "riding") .. ": the route goes on from where it ends")
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
	elseif cmd == "go" then
		ns.GoService(arg)
	else
		ns.Print("/gpath  - turn on/off")
		ns.Print("/gpath marker | dots | minimap | worldmap | debug  - toggle a part")
		ns.Print("/gpath go bank | ah | inn | mail | repair | flight | trainer | food | mining ...  - head for the nearest one; /gpath go stops")
		ns.Print("/gpath status | replan | probe (measure the camera for the ground dots)")
		ns.Print("/gpath spacing <yd> | range <yd> | size <yd> | height <yd> | fov <deg, 0 = auto>  - ground dot tuning")
	end
end
