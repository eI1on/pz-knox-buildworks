---BuildingCapture turns something already standing in the world - a map house,
---a shop, a player base - into a new blueprint made of catalogue pieces.
---
---Every object on every square of the area is matched back to the recipe that
---draws its sprite (WorldPieceIndex, the same lookup the pipette uses), including
---the overlays the map loader attaches to walls and floors. On top of what is
---visible, the steps a builder has to go through are added back:
---
---  * earlier stages - a wall's SpriteConfig previousStage (wall frame for a
---    wooden or house wall, lvl1 before lvl2 where the script only allows
---    that), resolved by the same name rules plan validation uses;
---  * corner sprites - planned as their W and N walls: Knox's merged corner
---    by its recipe, a map corner by the CornerWestWall / CornerNorthWall
---    tile properties the game itself uses for that tile;
---  * wall finishes - the plaster, paint or wallpaper a wall wears rides the
---    wall placement as a planned finish, so totals, ghosts and the finish
---    queue (plaster first, then paint or wallpaper) handle it. A plastered
---    map wall no finish reproduces exactly is planned as the closest wall of
---    its PaintingType with plaster, and listed as approximated.
---
---When several recipes draw the same sprite, the one a builder would really
---raise wins: Knox's own identity, then agreement with tiles already captured,
---then a wall with a frame chain over a stand-alone piece, a real wall over a
---corner-only piece, the recipe's own face over a finish result, and the
---highest group level (Good wooden walls for painted house walls).
---
---Doors, windows and curtains are read in their closed state, and the random
---clutter TileOverlays attaches to furniture is left out.
---
---The scan runs a few squares per tick, then pieces are added lowest level and
---structure first through Blueprints.addPlacements, so a capture that hits the
---blueprint piece limit still holds the shell of the building. Rooms of a
---captured building become blueprint rooms. A report of every tile that has no
---catalogue piece is written to Zomboid/Lua/KnoxBuildworks/captures/.
local KBW = require("KnoxBuildworks/Core")
local Registry = require("KnoxBuildworks/Definitions/Registry")
local StageConfig = require("KnoxBuildworks/Definitions/StageConfig")
local Blueprints = require("KnoxBuildworks/Planning/Blueprints")
local Placement = require("KnoxBuildworks/Validation/Placement")
local WallFinishes = require("KnoxBuildworks/Validation/WallFinishes")
local EntityCompat = require("KnoxBuildworks/Entity/EntityCompat")
local CatalogVisibility = require("KnoxBuildworks/UI/CatalogVisibility")
local WorldPieceIndex = require("KnoxBuildworks/UI/WorldPieceIndex")
local Log = require("KnoxBuildworks/Log")

---@class KBW.BuildingCaptureModule
local BuildingCapture = {
    MARGIN = 1,
    MAX_LEVELS = 12,
    SQUARES_PER_TICK = 120,
    ADDS_PER_TICK = 64,
    MAX_PREVIOUS_DEPTH = 4,
    REPORT_DIR = "KnoxBuildworks/captures/"
}

local active = nil

local ROOM_COLORS = {
    { r = 0.20, g = 0.62, b = 1.00, a = 0.26 }, { r = 0.22, g = 0.86, b = 0.36, a = 0.26 },
    { r = 1.00, g = 0.76, b = 0.10, a = 0.26 }, { r = 0.72, g = 0.38, b = 1.00, a = 0.26 },
    { r = 0.18, g = 0.88, b = 0.90, a = 0.26 }, { r = 1.00, g = 0.42, b = 0.08, a = 0.26 },
    { r = 1.00, g = 0.48, b = 0.82, a = 0.26 }, { r = 0.52, g = 1.00, b = 0.18, a = 0.26 }
}

-- Ground cover, plants, grime and blood are scenery, not construction; they
-- stay out of the "no catalogue piece" report so it lists real gaps only.
local SCENERY_PREFIXES = {
    "blends_natural", "blends_grassoverlays", "e_newgrass", "vegetation_", "d_plants", "f_bushes",
    "overlay_grime", "overlay_blood", "overlay_messages"
}

-- Litter and wreckage: real objects nobody builds. Reported on their own so
-- the gap list stays a to-do list of construction pieces.
local LITTER_PREFIXES = {
    "trash_01_", "trash_walls_", "d_generic", "d_trash", "fencing_damaged_", "walls_house_wood_01_MIRRORED_"
}

-- Map wall types with no Knox recipe of their own, planned as the nearest one.
local APPROXIMATE_WALL_TYPES = { dblwindowframeleft = "windowsframe", dblwindowframeright = "windowsframe" }

local function floorInt(value)
    return math.floor(tonumber(value) or 0)
end

local function hasPrefix(spriteName, prefixes)
    for index = 1, #prefixes do
        local prefix = prefixes[index]
        if string.sub(spriteName, 1, #prefix) == prefix then return true end
    end
    return false
end

local function isScenery(spriteName)
    return hasPrefix(spriteName, SCENERY_PREFIXES)
end

local function spriteProps(name)
    local sprite = name and getSprite and getSprite(name) or nil
    return sprite and sprite:getProperties() or nil
end

local function propValue(props, key)
    if not props or not props:has(key) then return nil end
    local value = props:get(key)
    return value ~= nil and tostring(value) or ""
end

local function northEdge(direction)
    direction = tonumber(direction) or 1
    return direction == 2 or direction == 4
end

local function edgeKey(entry)
    return tostring(entry.x) .. "|" .. tostring(entry.y) .. "|" .. tostring(entry.z) .. "|"
        .. (northEdge(entry.direction) and "N" or "W")
end

local function entryKey(entry)
    local definition = Registry:get(entry.buildableId)
    local kind = definition and (definition.placement or {}).kind or nil
    local direction = tostring(entry.direction or 1)
    if kind == "wall" or kind == "wallCovering" then direction = northEdge(entry.direction) and "N" or "W" end
    return table.concat({ entry.buildableId or "", entry.stageId or "", entry.variantId or "",
        entry.materialId or "", tostring(entry.x), tostring(entry.y), tostring(entry.z), direction }, "|")
end

-- AREAS ---------------------------------------------------------------------

---The whole building a square belongs to: its BuildingDef bounds (x2/y2 are
---exclusive, so the margin reaches the east/south exterior walls and roof
---eaves), every level it has rooms on, plus one above for the roof.
---@param square IsoGridSquare|nil
function BuildingCapture.buildingArea(square)
    local def = square and square.getBuildingDef and square:getBuildingDef() or nil
    if not def then return nil end
    local margin = BuildingCapture.MARGIN
    return {
        mode = "building",
        x1 = def:getX() - margin, y1 = def:getY() - margin,
        x2 = def:getX2() + margin, y2 = def:getY2() + margin,
        zMin = def:getMinLevel(), zMax = def:getMaxLevel() + 1,
        building = def
    }
end

---A dragged rectangle, from z upward until a level has nothing on it.
function BuildingCapture.rectArea(x1, y1, x2, y2, z)
    return {
        mode = "area",
        x1 = math.min(x1, x2), y1 = math.min(y1, y2), x2 = math.max(x1, x2), y2 = math.max(y1, y2),
        zMin = floorInt(z), zMax = floorInt(z) + BuildingCapture.MAX_LEVELS - 1,
        stopOnEmptyLevel = true
    }
end

-- PREVIOUS STAGES -----------------------------------------------------------

local function nameList(previousStage)
    local names = {}
    if type(previousStage) == "table" then
        for index = 1, #previousStage do names[#names + 1] = tostring(previousStage[index]) end
    elseif previousStage ~= nil then
        for name in string.gmatch(tostring(previousStage), "[^;]+") do names[#names + 1] = name end
    end
    return names
end

-- A metal wall goes on a metal frame, a wooden one on a wooden frame; scripts
-- list both, wood first, so the piece's own material picks between them.
local function materialOrdered(names, definition, stage)
    local own = string.lower(tostring(definition.id) .. " " .. tostring(EntityCompat.metadata(stage).entity or ""))
    local token = (string.find(own, "metal", 1, true) and "metal")
        or ((string.find(own, "wood", 1, true) or string.find(own, "log", 1, true)) and "wood") or nil
    if not token then return names end
    local preferred, rest = {}, {}
    for index = 1, #names do
        local list = string.find(string.lower(names[index]), token, 1, true) and preferred or rest
        list[#list + 1] = names[index]
    end
    for index = 1, #rest do preferred[#preferred + 1] = rest[index] end
    return preferred
end

local function resolvePreviousName(job, name)
    local cached = job.previousCache[name]
    if cached ~= nil then return cached or nil end
    job.registryList = job.registryList or Registry:list()
    local found = false
    for definitionIndex = 1, #job.registryList do
        local definition = job.registryList[definitionIndex]
        if CatalogVisibility.definitionEnabled(definition) then
            local stages = definition.stages or {}
            for stageIndex = 1, #stages do
                if Blueprints.stageMatchesPrevious(name, definition, stages[stageIndex]) then
                    found = { definition = definition, stage = stages[stageIndex] }
                    break
                end
            end
        end
        if found then break end
    end
    job.previousCache[name] = found
    return found or nil
end

-- REPORT HELPERS ------------------------------------------------------------

local function countInto(map, key)
    map[key] = (map[key] or 0) + 1
end

local function sortedCounts(map)
    local list = {}
    for key, count in pairs(map) do list[#list + 1] = { key = key, count = count } end
    table.sort(list, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.key < b.key
    end)
    return list
end

-- SCAN ----------------------------------------------------------------------

local function addEntry(job, entry, source)
    local key = entryKey(entry)
    if job.keys[key] then return job.keys[key], false end
    entry.captureSource = source
    entry.captureIndex = #job.entries + 1
    job.entries[#job.entries + 1] = entry
    job.keys[key] = entry
    local edge = edgeKey(entry)
    job.byEdge[edge] = job.byEdge[edge] or {}
    job.byEdge[edge][#job.byEdge[edge] + 1] = entry
    return entry, true
end

local function placementFrom(candidate, direction)
    return {
        buildableId = candidate.buildableId, stageId = candidate.stageId,
        variantId = candidate.variantId, materialId = candidate.materialId,
        finish = candidate.finish, inputChoices = candidate.inputChoices,
        x = candidate.x, y = candidate.y, z = candidate.z,
        direction = direction or candidate.direction
    }
end

-- See the header: identity, agreement with captured tiles, frame chain,
-- real wall over corner piece, own face over finish result, group level.
local function candidateScore(job, candidate)
    local value = 0
    if candidate.exact then value = value + 1000000 end
    if job.keys[entryKey(candidate)] then value = value + 100000 end
    if candidate.chain then value = value + 10000 end
    if not candidate.cornerPiece then value = value + 1000 end
    if not candidate.fromFinish then value = value + 100 end
    return value + math.max(0, math.min(tonumber(candidate.level) or 0, 99))
end

local function pickCandidate(job, candidates)
    local best, bestScore = nil, nil
    for index = 1, #candidates do
        local score = candidateScore(job, candidates[index])
        if not best or score > bestScore then best, bestScore = candidates[index], score end
    end
    return best
end

local function spriteIndexName(name, delta)
    local base, index = string.match(tostring(name), "^(.*)_(%d+)$")
    local value = index and tonumber(index) - delta or -1
    if value < 0 then return nil end
    return base .. "_" .. tostring(value)
end

local DOOR_OFFSETS = { { 2, nil }, { 4, "DoubleDoor" }, { 8, "GarageDoor" } }
local WINDOW_OFFSET_KEYS = { "OpenTileOffset", "SmashedTileOffset", "GlassRemovedOffset" }

-- An open door, open curtain or open/smashed/glassless window shows a state
-- sprite a fixed offset past its closed sprite (IsoDoor: 2, double 4, garage
-- 8; IsoCurtain: 4; IsoWindow: the offset its closed tile declares). Recipes
-- list the closed sprite, so this walks back to it.
local function closedSpriteNames(object, name)
    local names = {}
    if not object or not name then return names end
    if instanceof(object, "IsoDoor") or (instanceof(object, "IsoThumpable") and object.isDoor and object:isDoor()) then
        for index = 1, #DOOR_OFFSETS do
            local offset, flag = DOOR_OFFSETS[index][1], DOOR_OFFSETS[index][2]
            local closed = spriteIndexName(name, offset)
            local props = closed and spriteProps(closed) or nil
            if props and (flag == nil or props:has(flag)) and not props:has("open") then
                names[#names + 1] = closed
            end
        end
    elseif instanceof(object, "IsoCurtain") then
        names[#names + 1] = spriteIndexName(name, 4)
    elseif instanceof(object, "IsoWindow") then
        for offset = 1, 12 do
            local closed = spriteIndexName(name, offset)
            local props = closed and spriteProps(closed) or nil
            for keyIndex = 1, #WINDOW_OFFSET_KEYS do
                if tonumber(propValue(props, WINDOW_OFFSET_KEYS[keyIndex])) == offset then
                    names[#names + 1] = closed
                    break
                end
            end
        end
    end
    return names
end

-- A map wall whose exact surface no finish reproduces (a plaster colour or
-- pattern outside the paint tables): the best wall recipe of its
-- PaintingType, plastered when the tile is a plaster surface.
local function approximateWall(job, square, props)
    local wallType = propValue(props, "PaintingType")
    if not wallType or wallType == "" then return nil end
    local north = props:has("WallN") or props:has("WindowN") or props:has("DoorWallN")
    local candidates = WorldPieceIndex.candidatesForWallType(job.player, wallType, square, north)
    if #candidates == 0 and APPROXIMATE_WALL_TYPES[wallType] then
        candidates = WorldPieceIndex.candidatesForWallType(job.player, APPROXIMATE_WALL_TYPES[wallType], square, north)
    end
    local best = pickCandidate(job, candidates)
    if not best then return nil end
    if best.plasterFinish and (propValue(props, "MaterialType") == "Plaster" or props:has("IsPaintable")) then
        best.finish = best.plasterFinish
    end
    return best
end

-- outdoorGround: a ground-level floor (or something attached to one) outside
-- every room. A building's outer ring is yard and sidewalk, so a building
-- capture leaves it out; an area capture keeps what it can match. Neither
-- reports unmatched ground - it is mostly grass and pavement.
local function captureSprite(job, square, spriteName, object, outdoorGround, depth)
    if not spriteName or WorldPieceIndex.isAutoSprite(spriteName) then return end
    if outdoorGround and job.area.mode == "building" then return end
    local props = spriteProps(spriteName)
    if props and props:has("TileOverlay") then
        job.overlaysSkipped = job.overlaysSkipped + 1
        return
    end
    local candidates = WorldPieceIndex.placementsForSprite(job.player, spriteName, square, object, true)
    -- A corner tile is two walls. Knox's merged corner knows its recipe; any
    -- other corner names its two halves in its tile properties.
    local knoxCorner = false
    for index = 1, #candidates do
        if candidates[index].corner then knoxCorner = true end
    end
    local westPart, northPart = propValue(props, "CornerWestWall"), propValue(props, "CornerNorthWall")
    if not knoxCorner and (depth or 0) < 2 and westPart and northPart and westPart ~= "" and northPart ~= "" then
        job.cornersSplit = job.cornersSplit + 1
        captureSprite(job, square, westPart, nil, outdoorGround, (depth or 0) + 1)
        captureSprite(job, square, northPart, nil, outdoorGround, (depth or 0) + 1)
        return
    end
    if #candidates == 0 and object then
        local closed = closedSpriteNames(object, spriteName)
        for index = 1, #closed do
            candidates = WorldPieceIndex.placementsForSprite(job.player, closed[index], square, object, true)
            if #candidates > 0 then break end
        end
    end
    local candidate = pickCandidate(job, candidates)
    if not candidate and props then
        candidate = approximateWall(job, square, props)
        if candidate then countInto(job.approximated, spriteName) end
    end
    if not candidate then
        if outdoorGround or isScenery(spriteName) then return end
        countInto(hasPrefix(spriteName, LITTER_PREFIXES) and job.litter or job.unmatched, spriteName)
        return
    end
    job.matchedTiles = job.matchedTiles + 1
    if candidate.corner then
        addEntry(job, placementFrom(candidate, 1), "world")
        addEntry(job, placementFrom(candidate, 2), "world")
    else
        addEntry(job, placementFrom(candidate), "world")
    end
end

local function scanSquare(job, square)
    local objects = square:getObjects()
    local count = objects:size()
    if count == 0 then return end
    job.levelHasObjects = true
    local outdoorGround = square:getRoom() == nil and square:getZ() <= 0
    local roomDef = square.getRoomDef and square:getRoomDef() or nil
    if roomDef then job.roomDefs[tostring(roomDef:getID())] = roomDef end
    for index = 0, count - 1 do
        local object = objects:get(index)
        if object and not instanceof(object, "IsoTree") then
            local sprite = object:getSprite()
            local name = sprite and sprite:getName() or nil
            local floor = sprite and sprite:getProperties() and sprite:getProperties():has(IsoFlagType.solidfloor)
            captureSprite(job, square, name, object, outdoorGround and floor == true)
            local attached = object:getAttachedAnimSprite()
            if attached then
                for attachedIndex = 0, attached:size() - 1 do
                    local instance = attached:get(attachedIndex)
                    local parent = instance and instance:getParentSprite() or nil
                    captureSprite(job, square, parent and parent:getName() or nil, nil, outdoorGround and floor == true)
                end
            end
        end
    end
end

-- Steps one square; returns false once the whole area is done.
local function advanceScan(job)
    local area = job.area
    local cursor = job.cursor
    if cursor.z > area.zMax then return false end
    local square = getCell():getGridSquare(cursor.x, cursor.y, cursor.z)
    if square then
        scanSquare(job, square)
    elseif cursor.z == 0 then
        job.missingGround = job.missingGround + 1
    end
    cursor.x = cursor.x + 1
    if cursor.x > area.x2 then
        cursor.x = area.x1
        cursor.y = cursor.y + 1
        if cursor.y > area.y2 then
            cursor.y = area.y1
            if area.stopOnEmptyLevel and not job.levelHasObjects then return false end
            job.levelHasObjects = false
            job.levelsScanned = job.levelsScanned + 1
            cursor.z = cursor.z + 1
        end
    end
    return cursor.z <= area.zMax
end

-- PREREQUISITES -------------------------------------------------------------

local function addPrerequisites(job, entry, depth)
    if depth > BuildingCapture.MAX_PREVIOUS_DEPTH then return end
    local definition, stage = Blueprints.resolvePlacement(entry)
    if not definition or not stage then return end
    local previousStage = Placement.previousStageOf(stage)
    if not previousStage then return end
    local sameEdge = job.byEdge[edgeKey(entry)] or {}
    for index = 1, #sameEdge do
        if sameEdge[index] ~= entry and Blueprints.placementMatchesPrevious(previousStage, sameEdge[index]) then
            return
        end
    end
    local names = materialOrdered(nameList(previousStage), definition, stage)
    for index = 1, #names do
        local resolved = resolvePreviousName(job, names[index])
        if resolved then
            local kind = (StageConfig.placement(resolved.definition, resolved.stage) or {}).kind
            local direction = entry.direction
            if kind == "wall" then direction = northEdge(direction) and 2 or 1 end
            local previous, added = addEntry(job, {
                buildableId = resolved.definition.id, stageId = resolved.stage.id,
                x = entry.x, y = entry.y, z = entry.z, direction = direction
            }, "previous")
            if added then
                job.prerequisites = job.prerequisites + 1
                addPrerequisites(job, previous, depth + 1)
            end
            return
        end
    end
    countInto(job.missingPrevious, table.concat(names, " / "))
end

-- ORDER ---------------------------------------------------------------------

-- Lower levels first; within a level the order a builder works in: floors,
-- frames, walls, frame fillers (doors, windows), furniture, overlays.
local function captureTier(entry)
    local definition, stage = Blueprints.resolvePlacement(entry)
    local kind = definition and (definition.placement or {}).kind or "object"
    local tier = 5
    if kind == "floor" then
        tier = 1
    elseif kind == "wall" then
        tier = Placement.previousStageOf(stage) and 3 or 2
    elseif kind == "stairs" then
        tier = 4
    elseif kind == "overlay" or kind == "wallCovering" then
        tier = 7
    end
    if Blueprints.requiresFrame(entry) then tier = 6 end
    return (tonumber(entry.z) or 0) * 100 + tier
end

local function orderEntries(entries)
    local tiers = {}
    for index = 1, #entries do tiers[entries[index]] = captureTier(entries[index]) end
    table.sort(entries, function(a, b)
        if tiers[a] ~= tiers[b] then return tiers[a] < tiers[b] end
        return a.captureIndex < b.captureIndex
    end)
end

-- ROOMS ---------------------------------------------------------------------

local function roomLabel(name)
    name = tostring(name or "")
    if name == "" then return getText("IGUI_KBW_RoomTypeGeneric") end
    name = string.gsub(name, "_", " ")
    return string.upper(string.sub(name, 1, 1)) .. string.sub(name, 2)
end

local function roomInside(area, roomDef)
    return roomDef:getX() >= area.x1 and roomDef:getY() >= area.y1
        and roomDef:getX2() - 1 <= area.x2 and roomDef:getY2() - 1 <= area.y2
end

local function addRooms(job)
    local list = {}
    if job.area.building then
        local rooms = job.area.building:getRooms()
        for index = 0, rooms:size() - 1 do list[#list + 1] = rooms:get(index) end
    else
        for _key, roomDef in pairs(job.roomDefs) do
            if roomInside(job.area, roomDef) then list[#list + 1] = roomDef end
        end
    end
    table.sort(list, function(a, b)
        if a:getZ() ~= b:getZ() then return a:getZ() < b:getZ() end
        if a:getY() ~= b:getY() then return a:getY() < b:getY() end
        return a:getX() < b:getX()
    end)
    for index = 1, #list do
        local roomDef = list[index]
        local rects = roomDef:getRects()
        if rects and rects:size() > 0 then
            local first = rects:get(0)
            local room = {
                name = roomLabel(roomDef:getName()), type = "room",
                color = ROOM_COLORS[(index - 1) % #ROOM_COLORS + 1],
                x = first:getX(), y = first:getY(), z = roomDef:getZ(), rects = {}
            }
            for rectIndex = 0, math.min(rects:size(), 32) - 1 do
                local rect = rects:get(rectIndex)
                room.rects[#room.rects + 1] = {
                    dx = rect:getX() - room.x, dy = rect:getY() - room.y, w = rect:getW(), h = rect:getH()
                }
            end
            if Blueprints.addRoom(job.player, job.blueprint.id, room) then job.rooms = job.rooms + 1 end
        end
    end
end

-- REPORT --------------------------------------------------------------------

local function writeReport(job)
    local lines = {
        "Knox Buildworks capture report",
        "Blueprint: " .. tostring(job.blueprint.name) .. " (" .. tostring(job.blueprint.id) .. ")",
        string.format("Area: %d,%d to %d,%d, levels %d to %d (%s)", job.area.x1, job.area.y1, job.area.x2,
            job.area.y2, job.area.zMin, job.cursor.z - 1, job.area.mode),
        "Pieces planned: " .. tostring(job.added),
        "Earlier stages added (frames...): " .. tostring(job.prerequisites),
        "Walls with planned finishes: " .. tostring(job.finishes),
        "Rooms: " .. tostring(job.rooms),
        "Corner tiles split into two walls: " .. tostring(job.cornersSplit),
        "Furniture clutter left out (game TileOverlays): " .. tostring(job.overlaysSkipped)
    }
    if job.truncated > 0 then
        lines[#lines + 1] = "Left out at the blueprint limit: " .. tostring(job.truncated)
    end
    if job.missingGround > 0 then
        lines[#lines + 1] = "Ground tiles not loaded: " .. tostring(job.missingGround)
    end
    local sections = {
        { "Not added to the plan (reason: count)", job.rejected },
        { "Earlier stage with no catalogue piece", job.missingPrevious },
        { "Approximated: planned as the closest wall of the same type, plastered (sprite: tiles)", job.approximated },
        { "World sprites with no catalogue piece (sprite: tiles)", job.unmatched },
        { "Litter and wreckage, not planned (sprite: tiles)", job.litter }
    }
    for sectionIndex = 1, #sections do
        local entries = sortedCounts(sections[sectionIndex][2])
        if #entries > 0 then
            lines[#lines + 1] = ""
            lines[#lines + 1] = sections[sectionIndex][1]
            for index = 1, #entries do
                lines[#lines + 1] = "  " .. entries[index].key .. ": " .. tostring(entries[index].count)
            end
        end
    end
    local path = BuildingCapture.REPORT_DIR .. tostring(job.blueprint.id) .. ".txt"
    local writer = getFileWriter(path, true, false)
    if not writer then return nil end
    writer:write(table.concat(lines, "\n") .. "\n")
    writer:close()
    return path
end

-- RUNNER --------------------------------------------------------------------

local function finish(job)
    Events.OnTick.Remove(BuildingCapture.onTick)
    active = nil
    addRooms(job)
    job.reportPath = writeReport(job)
    local unmatchedKinds, unmatchedTiles = 0, 0
    for _name, count in pairs(job.unmatched) do
        unmatchedKinds = unmatchedKinds + 1
        unmatchedTiles = unmatchedTiles + count
    end
    job.unmatchedKinds, job.unmatchedTiles = unmatchedKinds, unmatchedTiles
    Log:info("capture %s: %d pieces, %d earlier stages, %d unmatched tiles", tostring(job.blueprint.id),
        job.added, job.prerequisites, unmatchedTiles)
    if job.onDone then job.onDone(job) end
end

local function prepareEntries(job)
    for index = 1, #job.entries do addPrerequisites(job, job.entries[index], 1) end
    orderEntries(job.entries)
    for index = 1, #job.entries do
        local entry = job.entries[index]
        entry.captureSource, entry.captureIndex = nil, nil
        if WallFinishes.isWallFinish(entry.finish) then job.finishes = job.finishes + 1 end
    end
end

local function startAdding(job)
    local room = Blueprints.importLimit() - #(job.blueprint.placements or {})
    if #job.entries > room then
        job.truncated = #job.entries - math.max(0, room)
        for index = #job.entries, math.max(0, room) + 1, -1 do job.entries[index] = nil end
    end
    job.phase = "add"
    job.addIndex = 1
end

local function advanceAdd(job)
    local chunk = {}
    local last = math.min(#job.entries, job.addIndex + BuildingCapture.ADDS_PER_TICK - 1)
    for index = job.addIndex, last do chunk[#chunk + 1] = job.entries[index] end
    job.addIndex = last + 1
    if #chunk > 0 then
        local added = Blueprints.addPlacements(job.player, job.blueprint.id, chunk, function(_placement, reason)
            countInto(job.rejected, tostring(reason or "unknown"))
        end)
        job.added = job.added + #added
    end
    return job.addIndex <= #job.entries
end

function BuildingCapture.onTick()
    local job = active
    if not job then
        Events.OnTick.Remove(BuildingCapture.onTick)
        return
    end
    if job.phase == "scan" then
        for _step = 1, BuildingCapture.SQUARES_PER_TICK do
            if not advanceScan(job) then
                if #job.entries == 0 then
                    Events.OnTick.Remove(BuildingCapture.onTick)
                    active = nil
                    if job.onDone then job.onDone(job) end
                    return
                end
                prepareEntries(job)
                job.blueprint = Blueprints.create(job.player, job.name, job.area.zMin,
                    math.min(#job.entries, Blueprints.importLimit()))
                startAdding(job)
                return
            end
        end
    elseif job.phase == "add" then
        if not advanceAdd(job) then finish(job) end
    end
end

function BuildingCapture.isRunning()
    return active ~= nil
end

---Starts a capture. onDone(job) receives counts (added, prerequisites,
---finishes, rooms, rejected, unmatched...) and job.blueprint (nil when nothing
---in the area matched a catalogue piece).
---@param player IsoPlayer
---@param area table from buildingArea or rectArea
---@param onDone function|nil
function BuildingCapture.start(player, area, onDone)
    if active or not player or not area or not KBW.Runtime.loaded then return false end
    local nameKey = area.mode == "building" and "IGUI_KBW_CaptureBuildingName" or "IGUI_KBW_CaptureAreaName"
    active = {
        player = player, area = area, onDone = onDone,
        name = getText(nameKey, tostring(area.x1 + BuildingCapture.MARGIN), tostring(area.y1 + BuildingCapture.MARGIN)),
        phase = "scan", cursor = { x = area.x1, y = area.y1, z = area.zMin },
        entries = {}, keys = {}, byEdge = {}, previousCache = {}, roomDefs = {},
        unmatched = {}, rejected = {}, missingPrevious = {}, approximated = {}, litter = {},
        matchedTiles = 0, prerequisites = 0, finishes = 0, rooms = 0, added = 0, truncated = 0,
        missingGround = 0, levelsScanned = 0, levelHasObjects = false, cornersSplit = 0, overlaysSkipped = 0
    }
    Events.OnTick.Add(BuildingCapture.onTick)
    return true
end

---Rich-text summary of a finished capture for the result dialog.
function BuildingCapture.summaryText(job)
    if not job.blueprint then return getText("IGUI_KBW_CaptureNothing") end
    local lines = {
        " <SIZE:medium> " .. getText("IGUI_KBW_CaptureSummaryTitle", tostring(job.blueprint.name)) .. " <SIZE:small> <LINE> ",
        getText("IGUI_KBW_CaptureSummaryPieces", tostring(job.added)),
        getText("IGUI_KBW_CaptureSummaryPrerequisites", tostring(job.prerequisites)),
        getText("IGUI_KBW_CaptureSummaryFinishes", tostring(job.finishes)),
        getText("IGUI_KBW_CaptureSummaryRooms", tostring(job.rooms))
    }
    local rejected = 0
    for _reason, count in pairs(job.rejected) do rejected = rejected + count end
    if rejected > 0 then lines[#lines + 1] = getText("IGUI_KBW_CaptureSummaryRejected", tostring(rejected)) end
    local approximated = 0
    for _sprite, count in pairs(job.approximated) do approximated = approximated + count end
    if approximated > 0 then
        lines[#lines + 1] = getText("IGUI_KBW_CaptureSummaryApproximated", tostring(approximated))
    end
    if (job.unmatchedTiles or 0) > 0 then
        lines[#lines + 1] = getText("IGUI_KBW_CaptureSummaryUnmatched", tostring(job.unmatchedTiles),
            tostring(job.unmatchedKinds))
    end
    if job.truncated > 0 then
        lines[#lines + 1] = getText("IGUI_KBW_CaptureSummaryTruncated", tostring(Blueprints.importLimit()),
            tostring(job.truncated))
    end
    if job.missingGround > 0 then
        lines[#lines + 1] = getText("IGUI_KBW_CaptureSummaryUnloaded", tostring(job.missingGround))
    end
    if job.reportPath then lines[#lines + 1] = getText("IGUI_KBW_CaptureSummaryReport", job.reportPath) end
    return table.concat(lines, " <LINE> ")
end

return BuildingCapture
