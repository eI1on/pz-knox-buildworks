--- Test Runner world automation: enumerates cases, supplies them, finds a site
--- the real validation accepts (stacking prerequisites), builds and verifies.
if not isDebugEnabled() then return end

local Registry = require("KnoxBuildworks/Definitions/Registry")
local Resolver = require("KnoxBuildworks/Definitions/Resolver")
local Requirements = require("KnoxBuildworks/Validation/Requirements")
local Placement = require("KnoxBuildworks/Validation/Placement")
local StageConfig = require("KnoxBuildworks/Definitions/StageConfig")
local EntityCompat = require("KnoxBuildworks/Entity/EntityCompat")
local Matrix = require("KnoxBuildworks/Geometry/Matrix")
local Integrity = require("KnoxBuildworks/Network/Integrity")
local AttachedSprites = require("KnoxBuildworks/World/AttachedSprites")
local WallFinishes = require("KnoxBuildworks/Validation/WallFinishes")
local I18n = require("KnoxBuildworks/I18n")

---@class KBW.BuildTestRunnerModule
local BuildTestRunner = {
    MODE_INSTANT = "instant",
    MODE_WALK = "walk",
    SEARCH_RADIUS = 7,
    MAX_PREREQUISITE_DEPTH = 3,
    MAX_PROVIDER_ATTEMPTS = 5
}

local SPAWN_MARKER = "KBWDebugBuildTest"
local FACES = { "W", "N", "E", "S" }

-- SORTING ---------------------------------------------------------------

--- Stable iterative merge sort; Kahlua's recursive table.sort overflows on large tied lists.
---@param list table
---@param less function (a, b): boolean
local function mergeSort(list, less)
    local count = #list
    if count < 2 then return list end
    local source, target = list, {}
    local width = 1
    while width < count do
        local left = 1
        while left <= count do
            local middle = math.min(left + width, count + 1)
            local right = math.min(left + width * 2, count + 1)
            local i, j, k = left, middle, left
            while i < middle and j < right do
                if less(source[j], source[i]) then
                    target[k] = source[j]
                    j = j + 1
                else
                    target[k] = source[i]
                    i = i + 1
                end
                k = k + 1
            end
            while i < middle do
                target[k] = source[i]
                i, k = i + 1, k + 1
            end
            while j < right do
                target[k] = source[j]
                j, k = j + 1, k + 1
            end
            left = right
        end
        source, target = target, source
        width = width * 2
    end
    if source ~= list then
        for index = 1, count do
            list[index] = source[index]
        end
    end
    return list
end
BuildTestRunner.mergeSort = mergeSort

-- CASES -----------------------------------------------------------------

local casesCache = nil
local casesHash = nil

local function stageList(base, variant, material)
    if material and material.stages then return material.stages end
    if variant and variant.stages then return variant.stages end
    return base.stages or {}
end

local function findOption(options, id)
    options = options or {}
    for index = 1, #options do
        if options[index].id == id then return options[index] end
    end
    return nil
end

--- Every (buildable, variant, material, stage) case; resolved lazily when run.
---@return table[]
function BuildTestRunner.cases()
    if casesCache and casesHash == Registry.hash then return casesCache end
    local result = {}
    local definitions = Registry:list()
    for definitionIndex = 1, #definitions do
        local base = definitions[definitionIndex]
        local variantIds = { "" }
        local variants = base.variants or {}
        for index = 1, #variants do
            variantIds[#variantIds + 1] = tostring(variants[index].id)
        end
        local materialIds = {}
        if base.materialRequired ~= true then materialIds[1] = "" end
        local materials = base.materialOptions or {}
        for index = 1, #materials do
            materialIds[#materialIds + 1] = tostring(materials[index].id)
        end
        local group = base.group or {}
        for variantIndex = 1, #variantIds do
            local variantId = variantIds[variantIndex]
            local variant = variantId ~= "" and findOption(variants, variantId) or nil
            for materialIndex = 1, #materialIds do
                local materialId = materialIds[materialIndex]
                local material = materialId ~= "" and findOption(materials, materialId) or nil
                local stages = stageList(base, variant, material)
                for stageIndex = 1, #stages do
                    local stage = stages[stageIndex]
                    local category = tostring(base.category or "Other")
                    local subcategory = tostring(base.subcategory or "General")
                    result[#result + 1] = {
                        key = table.concat({ base.id, tostring(stage.id), variantId, materialId }, "|"),
                        buildableId = base.id,
                        stageId = tostring(stage.id),
                        stageIndex = stageIndex,
                        stageCount = #stages,
                        variantId = variantId,
                        materialId = materialId,
                        category = category,
                        subcategory = subcategory,
                        base = base,
                        sortKey = table.concat({
                            category,
                            subcategory,
                            tostring(group.id or ""),
                            string.format("%05d", tonumber(group.level) or 0),
                            base.id,
                            variantId,
                            materialId,
                            string.format("%05d", stageIndex)
                        }, "|")
                    }
                end
            end
        end
    end
    mergeSort(result, function (a, b) return a.sortKey < b.sortKey end)
    casesCache, casesHash = result, Registry.hash
    return result
end

---@return string
function BuildTestRunner.caseName(testCase)
    local parts = { I18n.definitionName(testCase.base) }
    if testCase.stageCount > 1 then parts[#parts + 1] = testCase.stageId end
    if testCase.variantId ~= "" then parts[#parts + 1] = testCase.variantId end
    if testCase.materialId ~= "" then parts[#parts + 1] = testCase.materialId end
    return table.concat(parts, " / ")
end

local function sortedValues(set)
    local result = { "All" }
    local values = {}
    for value in pairs(set) do
        values[#values + 1] = value
    end
    mergeSort(values, function (a, b) return a < b end)
    for index = 1, #values do
        result[#result + 1] = values[index]
    end
    return result
end

--- Scope lists, from cases or raw definitions.
function BuildTestRunner.categories(entries)
    local seen = {}
    for index = 1, #entries do
        seen[tostring(entries[index].category or "Other")] = true
    end
    return sortedValues(seen)
end

function BuildTestRunner.subcategories(entries, category)
    local seen = {}
    for index = 1, #entries do
        local entry = entries[index]
        if category == "All" or tostring(entry.category or "Other") == category then
            seen[tostring(entry.subcategory or "General")] = true
        end
    end
    return sortedValues(seen)
end

function BuildTestRunner.resolve(testCase)
    return Resolver.resolveStage(testCase.buildableId, testCase.variantId, testCase.materialId, testCase.stageId)
end

-- CHARACTER STATE ---------------------------------------------------------

--- Character state the runner changes, restored after the run.
function BuildTestRunner.captureCharacter(player)
    -- Skill raises auto-learn recipes, so remember the whole list.
    local known = {}
    local recipes = player:getKnownRecipes()
    for index = 0, recipes:size() - 1 do
        known[tostring(recipes:get(index))] = true
    end
    return {
        x = player:getX(),
        y = player:getY(),
        z = player:getZ(),
        perks = {},
        known = known,
        instant = player:isTimedActionInstantCheat()
    }
end

function BuildTestRunner.restoreCharacter(player, snapshot)
    if not player or not snapshot then return end
    for perkName, level in pairs(snapshot.perks) do
        local perk = Perks[perkName]
        if perk then player:setPerkLevelDebug(perk, level) end
    end
    local known = player:getKnownRecipes()
    local added = {}
    for index = 0, known:size() - 1 do
        local name = tostring(known:get(index))
        if not snapshot.known[name] then added[#added + 1] = name end
    end
    -- Remove by name: a Kahlua number could bind to List.remove(Object).
    for index = 1, #added do
        known:remove(added[index])
    end
    player:setTimedActionInstantCheat(snapshot.instant == true)
    ISTimedActionQueue.clear(player)
    player:teleportTo(snapshot.x, snapshot.y, math.floor(snapshot.z))
    -- Debug perk changes fire no LevelPerk event.
    Requirements.invalidate()
end

local function raisePerk(player, snapshot, perkName, level)
    local perk = Perks[perkName]
    level = tonumber(level) or 0
    if not perk or player:getPerkLevel(perk) >= level then return end
    if snapshot and snapshot.perks[perkName] == nil then snapshot.perks[perkName] = player:getPerkLevel(perk) end
    player:setPerkLevelDebug(perk, level)
end

local function learn(player, recipe)
    recipe = tostring(recipe or "")
    if recipe == "" or player:isRecipeActuallyKnown(recipe) then return end
    player:learnRecipe(recipe)
end

--- Grants every skill and recipe the stage asks for.
function BuildTestRunner.grantKnowledge(player, stage, snapshot)
    local requirements = stage.requirements or {}
    for perkName, level in pairs(requirements.skills or {}) do
        raisePerk(player, snapshot, perkName, level)
    end
    local knowledge = requirements.knowledge or {}
    local alternatives = knowledge.skillAlternatives or {}
    if alternatives[1] then
        for perkName, level in pairs(alternatives[1].skills or {}) do
            raisePerk(player, snapshot, perkName, level)
        end
    end
    local direct = requirements.recipes or {}
    for index = 1, #direct do
        learn(player, direct[index])
    end
    local recipes = knowledge.recipes or {}
    for index = 1, #recipes do
        learn(player, recipes[index])
    end
    Requirements.invalidate()
end

-- TEST INVENTORY ----------------------------------------------------------

local function isSpawnedTestItem(item)
    local data = item and item.getModData and item:getModData() or nil
    return data ~= nil and data[SPAWN_MARKER] ~= nil
end

function BuildTestRunner.spawnedItems(player)
    return player:getInventory():getAllEvalRecurse(isSpawnedTestItem, ArrayList.new())
end

--- Units (items, or uses for drainables) of runner-spawned items still held.
function BuildTestRunner.spawnedUnits(player)
    local items = BuildTestRunner.spawnedItems(player)
    local total = 0
    for index = 0, items:size() - 1 do
        local item = items:get(index)
        if instanceof(item, "DrainableComboItem") then
            total = total + math.max(0, item:getCurrentUses())
        else
            total = total + 1
        end
    end
    return total
end

function BuildTestRunner.cleanupSpawnedItems(player)
    local items = BuildTestRunner.spawnedItems(player)
    for index = items:size() - 1, 0, -1 do
        local item = items:get(index)
        player:removeFromHands(item)
        local container = item:getContainer()
        if container then container:Remove(item) end
    end
    triggerEvent("OnContainerUpdate")
end

local function firstFullType(input)
    if input.selectedFullType then return input.selectedFullType end
    local items = input.items or {}
    if items[1] then return items[1] end
    local possible = input.possibleItems or Requirements.possibleItems(input)
    return possible[1]
end

local function hasFlag(input, wanted)
    local flags = input.flags or {}
    for index = 1, #flags do
        if flags[index] == wanted then return true end
    end
    return false
end

--- Fill level a spawned drainable needs to satisfy the input's item-state flags.
local function fillFor(input)
    if hasFlag(input, "IsEmpty") or hasFlag(input, "HasNoUses") then return 0 end
    if hasFlag(input, "NotFull") then return 0.5 end
    return 1.0
end

local function spawnRow(player, row, choices)
    local needed = tonumber(row.uses or row.needed or row.amount) or 1
    if needed <= 0 then return true end
    if tostring(row.resourceType or "Item") ~= "Item" then
        return false, "unsupported resource type " .. tostring(row.resourceType)
    end
    local fullType = firstFullType(row)
    if not fullType then return false, "no installed item satisfies input " .. tostring(row.id) end
    if not string.find(fullType, ".", 1, true) then fullType = "Base." .. fullType end
    local usesUnits = row.uses ~= nil or row.mode == "drain"
    local supplied, guard = 0, 0
    while supplied < needed and guard < needed + 16 do
        guard = guard + 1
        local item = player:getInventory():AddItem(fullType)
        if not item then return false, "could not spawn " .. tostring(fullType) end
        item:getModData()[SPAWN_MARKER] = tostring(row.id or "input")
        local fill = fillFor(row)
        if instanceof(item, "DrainableComboItem") then item:setUsedDelta(fill) end
        if usesUnits and fill > 0 and instanceof(item, "DrainableComboItem") then
            supplied = supplied + math.max(1, item:getCurrentUses())
        else
            supplied = supplied + 1
        end
    end
    if supplied < needed then return false, "could not supply " .. tostring(fullType) end
    if choices and row.id then choices[tostring(row.id)] = fullType end
    return true
end

--- Grants knowledge and spawns exactly what every input needs.
---@param extraRows table[] | nil finish/covering rows (WallFinishes.statusRows shape)
---@return boolean ok
---@return string | nil reason
---@return table<string, string> choices input id -> chosen full type
function BuildTestRunner.supply(player, definition, stage, snapshot, extraRows, spawn)
    BuildTestRunner.grantKnowledge(player, stage, snapshot)
    local choices = {}
    if spawn == false then return true, nil, nil end
    local inputs = Requirements.getInputs(definition, stage)
    for index = 1, #inputs do
        local ok, why = spawnRow(player, inputs[index], choices)
        if not ok then return false, why, choices end
    end
    extraRows = extraRows or {}
    for index = 1, #extraRows do
        local ok, why = spawnRow(player, extraRows[index], nil)
        if not ok then return false, why, choices end
    end
    triggerEvent("OnContainerUpdate")
    return true, nil, choices
end

--- Requirement rows the character is missing (for runs that do not spawn).
function BuildTestRunner.missingRequirements(player, definition, stage, square, choices)
    local status = Requirements.evaluate(player, definition, stage, square, choices)
    if status.ok then return nil end
    local missing = {}
    local rows = status.rows or {}
    for index = 1, #rows do
        local row = rows[index]
        if row.ok == false then missing[#missing + 1] = tostring(row.label or row.id) end
    end
    if status.reason then missing[#missing + 1] = tostring(status.reason) end
    return table.concat(missing, ", ")
end

-- CURSOR, AREAS AND SITES -------------------------------------------------

function BuildTestRunner.ensureBuildingObject()
    if not KBWBuildingObject then require("KnoxBuildworks/BuildingObjects/KBWBuildingObject") end
    return KBWBuildingObject ~= nil
end

---@return table | nil cursor
function BuildTestRunner.newCursor(player, buildableId, stageId, variantId, materialId, choices)
    if not BuildTestRunner.ensureBuildingObject() then return nil end
    local cursor = KBWBuildingObject:new(player, buildableId, stageId, variantId, materialId, 1, choices)
    if not cursor or cursor.blockBuild or not cursor.definition or not cursor.stage then return nil end
    return cursor
end

--- Directions a stage can face (walls: west/north edge only).
function BuildTestRunner.directionsFor(cursor)
    if cursor.isWallLike then return { 1, 2 } end
    local faces = {}
    for index = 1, #FACES do
        local cells = Matrix.getFaceCells(cursor.stage, FACES[index]) or {}
        for cellIndex = 1, #cells do
            if cells[cellIndex].sprite then
                faces[#faces + 1] = index
                break
            end
        end
    end
    if #faces == 0 then faces[1] = 1 end
    return faces
end

function BuildTestRunner.setDirection(cursor, direction)
    cursor.nSprite = direction
    cursor.direction = direction
    cursor:getSprite()
end

--- Largest footprint over every face: the slot a case reserves in the layout.
function BuildTestRunner.extentOf(stage)
    local width, height = 1, 1
    for index = 1, #FACES do
        local cells = Matrix.getFaceCells(stage, FACES[index]) or {}
        if #cells > 0 then
            local bounds = Matrix.getBounds(cells)
            width = math.max(width, bounds.width or 1)
            height = math.max(height, bounds.height or 1)
        end
    end
    return width, height
end

local function squareKey(square)
    return square:getX() .. "," .. square:getY() .. "," .. square:getZ()
end
BuildTestRunner.squareKey = squareKey

--- Test areas: a spiral around a point, or a layout slot rectangle.
function BuildTestRunner.spiralArea(x, y, z, radius)
    return { kind = "spiral", x = x, y = y, z = z, radius = radius or BuildTestRunner.SEARCH_RADIUS }
end

function BuildTestRunner.rectArea(x1, y1, x2, y2, z)
    return { kind = "rect", x1 = x1, y1 = y1, x2 = x2, y2 = y2, z = z }
end

--- Candidate (square, direction) placements, best first; footprints stay inside a slot.
function BuildTestRunner.candidates(cursor, area, limit)
    local result = {}
    local directions = BuildTestRunner.directionsFor(cursor)
    local function add(x, y, z, direction)
        local square = getCell():getGridSquare(x, y, z)
        if square then
            result[#result + 1] = { square = square, direction = direction }
        end
    end
    if area.kind == "rect" then
        for index = 1, #directions do
            local direction = directions[index]
            BuildTestRunner.setDirection(cursor, direction)
            local bounds = Matrix.getBounds(cursor:getFootprint() or {})
            add(area.x1 - (bounds.minX or 0), area.y1 - (bounds.minY or 0), area.z, direction)
        end
    else
        for ring = 0, area.radius do
            for dx = -ring, ring do
                for dy = -ring, ring do
                    if math.max(math.abs(dx), math.abs(dy)) == ring then
                        for index = 1, #directions do
                            add(area.x + dx, area.y + dy, area.z, directions[index])
                        end
                    end
                end
            end
            if limit and #result >= limit then break end
        end
    end
    return result
end

--- Whether Placement.validate accepts the piece here.
function BuildTestRunner.accepts(cursor, square, direction)
    BuildTestRunner.setDirection(cursor, direction)
    local ok, reason = Placement.validate(cursor, square)
    if not ok and reason == "missing footprint square" then
        -- create() needs the upper footprint squares to exist.
        cursor:ensureSquaresExist(square:getX(), square:getY(), square:getZ())
        ok, reason = Placement.validate(cursor, square)
    end
    return ok == true, reason
end

--- Full cursor validation (structure + requirements) right before building.
function BuildTestRunner.readyAt(cursor, square, direction)
    BuildTestRunner.setDirection(cursor, direction)
    if cursor:isValid(square) then return true, nil end
    return false, cursor.validationReason or "cursor rejected the square"
end

--- First candidate the real validation accepts.
---@return IsoGridSquare | nil square
---@return number | nil direction
---@return string | nil reason        the most common rejection when nothing fits
function BuildTestRunner.findSite(cursor, area, exclude)
    local reasons, best, bestCount = {}, nil, 0
    local candidates = BuildTestRunner.candidates(cursor, area)
    for index = 1, #candidates do
        local candidate = candidates[index]
        if not (exclude and exclude[squareKey(candidate.square)]) then
            local ok, reason = BuildTestRunner.accepts(cursor, candidate.square, candidate.direction)
            if ok then return candidate.square, candidate.direction, nil end
            reason = tostring(reason)
            reasons[reason] = (reasons[reason] or 0) + 1
            if reasons[reason] > bestCount then
                best, bestCount = reason, reasons[reason]
            end
        end
    end
    return nil, nil, best or "no candidate squares are loaded"
end

-- LAYOUT ------------------------------------------------------------------

--- Row-by-row slot allocator: one slot per footprint, `gap` tiles apart.
function BuildTestRunner.newLayout(origin, gap, rowWidth)
    return {
        origin = origin,
        gap = math.max(1, gap or 2),
        rowWidth = math.max(8, rowWidth or 40),
        x = origin.x,
        y = origin.y,
        rowHeight = 0
    }
end

function BuildTestRunner.allocate(layout, width, height)
    width, height = math.max(1, width), math.max(1, height)
    if layout.x > layout.origin.x and layout.x + width - 1 > layout.origin.x + layout.rowWidth - 1 then
        layout.x = layout.origin.x
        layout.y = layout.y + layout.rowHeight + layout.gap
        layout.rowHeight = 0
    end
    local slot = BuildTestRunner.rectArea(
        layout.x, layout.y, layout.x + width - 1, layout.y + height - 1, layout.origin.z
    )
    layout.x = layout.x + width + layout.gap
    layout.rowHeight = math.max(layout.rowHeight, height)
    return slot
end

-- PREREQUISITES -----------------------------------------------------------

local function compactName(value)
    value = string.lower(tostring(value or ""))
    value = string.gsub(value, "[%s_%-%(%)%.:]+", "")
    value = string.gsub(value, "wooden", "wood")
    return value
end

local function nameMatches(candidate, names)
    candidate = compactName(candidate)
    if candidate == "" then return false end
    for index = 1, #names do
        local wanted = compactName(names[index])
        if candidate == wanted or string.sub(candidate, -#wanted) == wanted then return true end
    end
    return false
end

local function simpleCase(definition, stage)
    return { buildableId = definition.id, stageId = stage.id, variantId = "", materialId = "" }
end

--- Maps a placement rejection to the prerequisite that would satisfy it.
function BuildTestRunner.prerequisiteFor(cursor, reason)
    reason = tostring(reason or "")
    local previous = Placement.previousStageOf(cursor.stage)
    if previous and (reason == "previous stage missing" or reason == "previous stage direction mismatch") then
        local names = type(previous) == "table" and previous or { previous }
        return "previous", names
    end
    if reason == "door frame required" then return "door frame", nil end
    if reason == "window frame required" or reason == "window frame of a different shape" then
        return "window frame", nil
    end
    if reason == "wall required" or reason == "wall support missing" then return "wall", nil end
    if reason == "script OnIsValid rejected" then
        local callback = tostring(StageConfig.sprite(cursor.definition, cursor.stage).onIsValid or "")
        if string.find(string.lower(callback), "barricade", 1, true) then return "barricadable", nil end
    end
    return nil, nil
end

local function faceSpriteProps(stage, north)
    if not getSprite then return nil, nil end
    local faces = north and { "N", "S" } or { "W", "E" }
    for faceIndex = 1, #faces do
        local cells = Matrix.getFaceCells(stage, faces[faceIndex]) or {}
        for cellIndex = 1, #cells do
            local name = cells[cellIndex].sprite
            local sprite = name and getSprite(name) or nil
            if sprite then return sprite:getProperties(), name, sprite end
        end
    end
    return nil, nil, nil
end

--- What the case needs from a prerequisite (window shape, corner, support sprites).
function BuildTestRunner.needsOf(cursor, kind)
    local placement = StageConfig.placement(cursor.definition, cursor.stage)
    local needs = {
        kind = kind,
        isCorner = AttachedSprites.isCornerStage(placement, cursor.stage),
        patterns = placement.windowSupportSprites,
        shapes = {}
    }
    needs.ignoreShape = placement.ignoreWindowShape == true
    if kind == "window frame" then
        -- false: shapeless window; missing key: no face in that orientation.
        for _, orientation in pairs({ "N", "W" }) do
            local props, spriteName = faceSpriteProps(cursor.stage, orientation == "N")
            if spriteName then needs.shapes[orientation] = props and Placement.windowShapeOf(props) or false end
        end
    end
    return needs
end

local function fakeObject(props)
    return { getModData = function () return {} end, getProperties = function () return props end }
end

-- Wall sprites with a window opening.
local function providesWindowOpening(props, north)
    if not props or not IsoFlagType then return false end
    if north then
        return props:has(IsoFlagType.WindowN) or props:has(IsoFlagType.cutN)
            or (IsoPropertyType and props:has(IsoPropertyType.WINDOW_FRAME_N))
    end
    return props:has(IsoFlagType.WindowW) or props:has(IsoFlagType.cutW)
        or (IsoPropertyType and props:has(IsoPropertyType.WINDOW_FRAME_W))
end

-- How well a provider stage satisfies `needs`; nil = it cannot.
local function providerScore(definition, stage, needs, names)
    local placement = StageConfig.placement(definition, stage)
    local object = stage.object or {}
    local entity = EntityCompat.metadata(stage).entity
    local standalone = Placement.previousStageOf(stage) == nil
    local sprite = StageConfig.sprite(definition, stage)
    local id = compactName(definition.id)
    local score = 0
    if stage.entityCompat == nil then score = score + 20 end
    if standalone then score = score + 10 end
    if sprite.onIsValid then score = score - 15 end
    if placement.requiresOutside == true then return nil end
    local kind = needs.kind
    if kind == "previous" then
        if not (nameMatches(entity, names) or nameMatches(stage.id, names)) then return nil end
        return score
    end
    if kind == "wall" or kind == "covering wall" then
        if placement.kind ~= "wall" or placement.needWindowFrame == true or placement.providesWindowFrame == true
            or object.isDoorFrame == true or object.canPassThrough == true then
            return nil
        end
        local name = compactName(entity or definition.id)
        for _, bad in pairs({
            "frame",
            "fence",
            "railing",
            "gate",
            "barricade",
            "door",
            "window",
            "arch",
            "pole",
            "half",
            "low",
            "trim",
            "corner",
            "roof",
            "end",
            "pillar",
            "column",
            "beam",
            "post",
            "stair",
            "curb",
            "ledge",
            "shelf",
            "counter",
            "sign",
            "slope",
            "gable",
            "triangle"
        }) do
            local allowed = bad == "corner" and needs.isCorner
            if not allowed and string.find(name, bad, 1, true) then return nil end
        end
        for _, face in pairs({ "W", "N" }) do
            local cells = Matrix.getFaceCells(stage, face) or {}
            local sprites = 0
            for cellIndex = 1, #cells do
                if cells[cellIndex].sprite then sprites = sprites + 1 end
            end
            if sprites ~= 1 then return nil end
        end
        if string.find(id, "wall", 1, true) then score = score + 5 end
        if kind == "covering wall" then
            if not WallFinishes.isPlasterable(definition, stage) then return nil end
            return score
        end
        local fits = false
        for _, north in pairs({ true, false }) do
            local props = faceSpriteProps(stage, north)
            if props == nil and not getSprite then fits = true end
            if props and AttachedSprites.isRelevantWall(fakeObject(props), north, needs.isCorner) then fits = true end
        end
        return fits and score or nil
    end
    if kind == "door frame" then
        local props, _, faceSprite = faceSpriteProps(stage, false)
        local frameType = faceSprite and faceSprite:getType() or nil
        if object.isDoorFrame == true or string.find(compactName(entity), "doorframe", 1, true)
            or (IsoObjectType and frameType ~= nil
                and (frameType == IsoObjectType.doorFrW or frameType == IsoObjectType.doorFrN)) then
            return score
        end
        return nil
    end
    if kind == "barricadable" then
        local frameLike = placement.providesWindowFrame == true
            or string.find(compactName(entity), "windowframe", 1, true) ~= nil
        if frameLike then return score + 10 end
        if object.canBarricade == true then return score end
        return nil
    end
    if kind == "window frame" then
        local frameLike = placement.providesWindowFrame == true
            or string.find(compactName(entity), "windowframe", 1, true) ~= nil
        for _, orientation in pairs({ "N", "W" }) do
            local north = orientation == "N"
            local props, spriteName = faceSpriteProps(stage, north)
            if needs.patterns and Placement.matchesWindowSupportSprite(spriteName, needs.patterns) then
                return score + 30
            end
            local wanted = needs.shapes[orientation]
            if wanted ~= nil then
                if props == nil then
                    -- Offline (no sprite data) every declared frame is a candidate.
                    if frameLike and not getSprite then return score end
                elseif frameLike or providesWindowOpening(props, north) then
                    if needs.ignoreShape or Placement.windowShapesMatch(wanted or nil, Placement.windowShapeOf(props)) then
                        return score + (frameLike and 10 or 5)
                    end
                end
            end
        end
        return nil
    end
    return nil
end

local providerCache = {}
local remembered = {}

local function needsKey(needs, names)
    return table.concat({
        needs.kind,
        tostring(needs.isCorner),
        tostring(needs.shapes.N),
        tostring(needs.shapes.W),
        table.concat(needs.patterns or {}, ","),
        table.concat(names or {}, ",")
    }, "|")
end

--- Stages that can serve as a prerequisite, best first.
---@param kind string "previous" | "wall" | "door frame" | "window frame" | "barricadable" | "covering wall"
function BuildTestRunner.providers(kind, names, needs)
    needs = needs or { kind = kind, shapes = {} }
    needs.kind = kind
    local key = needsKey(needs, names)
    if providerCache[key] then return providerCache[key] end
    local scored = {}
    local definitions = Registry:list()
    for definitionIndex = 1, #definitions do
        local definition = definitions[definitionIndex]
        if definition.materialRequired ~= true then
            local stages = definition.stages or {}
            for stageIndex = 1, #stages do
                local score = providerScore(definition, stages[stageIndex], needs, names)
                if score then
                    scored[#scored + 1] = {
                        case = simpleCase(definition, stages[stageIndex]),
                        score = score,
                        id = definition.id
                    }
                end
            end
        end
    end
    mergeSort(scored, function (a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.id < b.id
    end)
    local result = {}
    local first = remembered[key]
    if first then result[1] = first end
    for index = 1, #scored do
        local case = scored[index].case
        if not first or case.buildableId ~= first.buildableId or case.stageId ~= first.stageId then
            result[#result + 1] = case
        end
    end
    providerCache[key] = result
    return result
end

function BuildTestRunner.rememberProvider(kind, names, needs, provider)
    needs = needs or { kind = kind, shapes = {} }
    needs.kind = kind
    local key = needsKey(needs, names)
    if not remembered[key] then
        remembered[key] = provider
        providerCache[key] = nil
    end
end

--- A plain, self-standing buildable of the given placement kind.
---@return table | nil case-like { buildableId, stageId, variantId, materialId }
function BuildTestRunner.representative(kind)
    local cacheKey = "representative|" .. kind
    if providerCache[cacheKey] ~= nil then return providerCache[cacheKey] or nil end
    local best, bestScore = nil, nil
    local definitions = Registry:list()
    for definitionIndex = 1, #definitions do
        local definition = definitions[definitionIndex]
        local stage = (definition.stages or {})[1]
        if stage and definition.materialRequired ~= true and #(definition.stages or {}) == 1 then
            local placement = StageConfig.placement(definition, stage)
            local object = stage.object or {}
            local sprite = StageConfig.sprite(definition, stage)
            local fits = placement.kind == kind and Placement.previousStageOf(stage) == nil
                and placement.needToBeAgainstWall ~= true and placement.againstWall ~= true
                and placement.needWindowFrame ~= true and placement.requiresOutside ~= true
                and object.isDoorFrame ~= true and object.canPassThrough ~= true
                -- JSON floors carry Knox's own default floor callbacks.
                and (kind == "floor" or (sprite.onIsValid == nil and sprite.onCreate == nil))
            if fits and kind == "wall" then
                fits = providerScore(definition, stage, { kind = "wall", shapes = {} }, nil) ~= nil
            end
            if fits then
                local cells = Matrix.getFaceCells(stage, "W") or {}
                local spriteCells = 0
                for cellIndex = 1, #cells do
                    if cells[cellIndex].sprite then spriteCells = spriteCells + 1 end
                end
                if spriteCells == 1 then
                    local score = #Requirements.getInputs(definition, stage)
                    if stage.entityCompat then score = score + 50 end
                    if string.find(tostring(definition.__source or ""), "^KnoxBuildworks:") then score = score - 5 end
                    if not bestScore or score < bestScore then
                        best, bestScore = definition, score
                    end
                end
            end
        end
    end
    local result = best and simpleCase(best, best.stages[1]) or nil
    providerCache[cacheKey] = result or false
    return result
end

function BuildTestRunner.representativeDefinition(kind)
    local sample = BuildTestRunner.representative(kind)
    return sample and Registry:get(sample.buildableId) or nil
end

-- WORLD -------------------------------------------------------------------

local function eachSquareAround(square, radius, depth, visit)
    local x, y, z = square:getX(), square:getY(), square:getZ()
    for dz = 0, depth do
        for dx = -radius, radius do
            for dy = -radius, radius do
                local target = getCell():getGridSquare(x + dx, y + dy, z + dz)
                if target then visit(target) end
            end
        end
    end
end

local function trackable(object)
    return object and not instanceof(object, "IsoWorldInventoryObject") and not instanceof(object, "IsoDeadBody")
end

--- World objects around a square, including natives an OnCreate swapped in.
---@return table set keyed by object (or object|sprite for attached decorations)
function BuildTestRunner.worldObjectsAround(square, radius, depth)
    local found = {}
    eachSquareAround(square, radius or 4, depth or 3, function (target)
        local objects = target:getObjects()
        for index = 0, objects:size() - 1 do
            local object = objects:get(index)
            if trackable(object) then
                local data = object:getModData()
                local kbw = data and data.KBW or nil
                found[object] = {
                    object = object,
                    square = target,
                    buildableId = kbw and kbw.buildableId or nil,
                    stageId = kbw and kbw.stageId or nil,
                    native = kbw == nil
                }
                local attached = data and data.KBWAttachedSprites or nil
                if attached then
                    for attachedIndex = 1, #attached do
                        local entry = attached[attachedIndex]
                        found[tostring(object) .. "|" .. tostring(entry.sprite)] = {
                            object = object,
                            square = target,
                            attachedSprite = entry.sprite,
                            buildableId = entry.buildableId
                        }
                    end
                end
            end
        end
    end)
    return found
end
BuildTestRunner.knoxObjectsAround = BuildTestRunner.worldObjectsAround

--- Entries present now but not in `before`.
function BuildTestRunner.newObjects(before, square)
    local result = {}
    local now = BuildTestRunner.worldObjectsAround(square)
    for key, entry in pairs(now) do
        if not before[key] then result[#result + 1] = entry end
    end
    return result
end

--- Removes objects the runner built (attached decorations are detached).
function BuildTestRunner.removeEntries(entries)
    for index = #entries, 1, -1 do
        local entry = entries[index]
        if entry.attachedSprite then
            AttachedSprites.remove(entry.object, entry.attachedSprite)
        elseif entry.object:getSquare() and entry.object:getObjectIndex() >= 0 then
            -- Parts removed along with a sibling are skipped.
            entry.object:getSquare():transmitRemoveItemFromSquare(entry.object)
        end
    end
    for index = 1, #entries do
        local square = entries[index].square
        if square then square:RecalcAllWithNeighbours(true) end
    end
end

--- Moves the player beside the footprint, within build distance.
function BuildTestRunner.standBeside(player, cursor, square)
    local bounds = Matrix.getBounds(cursor:getFootprint() or {})
    local x = square:getX() + (bounds.minX or 0) - 1
    local y = square:getY() + (bounds.maxY or 0) + 2
    player:teleportTo(x + 0.5, y + 0.5, square:getZ())
end

--- Same sequence as vanilla ISBuildAction:perform in single-player.
---@return boolean ok
function BuildTestRunner.createNow(player, cursor, square)
    local x, y, z = square:getX(), square:getY(), square:getZ()
    cursor.character = player
    cursor.square = square
    local created = cursor:create(x, y, z, cursor.north == true, cursor:getSprite())
    square:RecalcAllWithNeighbours(true)
    buildUtil.setHaveConstruction(square, true)
    return created ~= false
end

--- Expected object squares: every footprint tile that places a sprite.
function BuildTestRunner.expectedTiles(cursor, square)
    local tiles = {}
    local footprint = cursor:getFootprint() or {}
    for index = 1, #footprint do
        local tile = footprint[index]
        if tile.sprite then
            tiles[#tiles + 1] = {
                x = square:getX() + (tile.dx or 0),
                y = square:getY() + (tile.dy or 0),
                z = square:getZ() + (tile.dz or 0),
                sprite = tile.sprite
            }
        end
    end
    return tiles
end

--- Problems with what a build placed (empty list = verified), plus notes.
---@param fixtures table | nil prerequisite entries (joined corners copy their identity)
function BuildTestRunner.verifyBuilt(cursor, square, entries, buildableId, fixtures)
    local problems, notes = {}, {}
    if #entries == 0 then
        problems[1] = "nothing appeared in the world"
        return problems, notes
    end
    local allowed = { [buildableId] = true }
    fixtures = fixtures or {}
    for index = 1, #fixtures do
        if fixtures[index].buildableId then allowed[fixtures[index].buildableId] = true end
    end
    local bySquare, natives = {}, 0
    for index = 1, #entries do
        local entry = entries[index]
        if entry.native then natives = natives + 1 end
        if entry.buildableId and not allowed[entry.buildableId] then
            problems[#problems + 1] = "unexpected buildable " .. tostring(entry.buildableId)
        end
        if entry.square then
            bySquare[entry.square:getX() .. "," .. entry.square:getY() .. "," .. entry.square:getZ()] = true
        end
    end
    if natives > 0 then notes[#notes + 1] = tostring(natives) .. " native object(s) from OnCreate" end
    -- An OnCreate may merge a multi-tile piece into one native object.
    local overlay = StageConfig.placement(cursor.definition, cursor.stage).kind == "overlay"
    if not overlay and natives == 0 then
        local tiles = BuildTestRunner.expectedTiles(cursor, square)
        for index = 1, #tiles do
            local tile = tiles[index]
            if not bySquare[tile.x .. "," .. tile.y .. "," .. tile.z] then
                problems[#problems + 1] = "footprint tile " .. tile.x
                    .. "," .. tile.y
                    .. "," .. tile.z
                    .. " (" .. tostring(tile.sprite)
                    .. ") has no object"
            end
        end
    end
    return problems, notes
end

-- SITE PREPARATION --------------------------------------------------------
-- Builds wait SETTLE_TICKS after a teleport: BuildLogic reads inventory access
-- from the player's square, which only updates on the next tick.

BuildTestRunner.SETTLE_TICKS = 2

--- Builds a provider at exactly (square, direction), stacking its own
--- prerequisites first, then calls done(entries, reason).
function BuildTestRunner.buildFixtureAt(t, player, provider, square, direction, depth, fixtures, ctx, done)
    local probe = BuildTestRunner.newCursor(player, provider.buildableId, provider.stageId, "", "", nil)
    if not probe then return done(nil, "fixture " .. provider.buildableId .. " has no cursor") end
    local function build()
        BuildTestRunner.cleanupSpawnedItems(player)
        local definition, stage = BuildTestRunner.resolve(provider)
        local ok, why, choices = BuildTestRunner.supply(player, definition, stage, ctx.characterSnapshot, nil, true)
        if not ok then return done(nil, why) end
        local cursor = BuildTestRunner.newCursor(player, provider.buildableId, provider.stageId, "", "", choices)
        BuildTestRunner.standBeside(player, cursor, square)
        t:waitTicks(BuildTestRunner.SETTLE_TICKS)
        t:next(function ()
            local valid, notReady = BuildTestRunner.readyAt(cursor, square, direction)
            if not valid then
                BuildTestRunner.cleanupSpawnedItems(player)
                return done(nil, "fixture " .. provider.buildableId .. ": " .. tostring(notReady))
            end
            local before = BuildTestRunner.worldObjectsAround(square)
            local created = BuildTestRunner.createNow(player, cursor, square)
            local entries = BuildTestRunner.newObjects(before, square)
            BuildTestRunner.cleanupSpawnedItems(player)
            t.yieldAfterStep = true
            if not created or #entries == 0 then
                BuildTestRunner.removeEntries(entries)
                return done(nil, "fixture " .. provider.buildableId .. " did not build")
            end
            for index = 1, #entries do
                fixtures[#fixtures + 1] = entries[index]
            end
            done(entries, nil)
        end)
    end
    local ok, reason = BuildTestRunner.accepts(probe, square, direction)
    if ok then return build() end
    BuildTestRunner.stackPrerequisite(
        t,
        player,
        probe,
        square,
        direction,
        reason,
        depth,
        fixtures,
        ctx,
        function (stacked, why)
            if not stacked then return done(nil, "fixture " .. provider.buildableId .. ": " .. tostring(why)) end
            build()
        end
    )
end

local function forgetEntries(fixtures, entries)
    for entryIndex = 1, #entries do
        for fixtureIndex = #fixtures, 1, -1 do
            if fixtures[fixtureIndex] == entries[entryIndex] then table.remove(fixtures, fixtureIndex) end
        end
    end
end

--- Squares (relative to the anchor) whose decoration tiles each need a wall.
local function wallTargets(cursor, square, direction)
    BuildTestRunner.setDirection(cursor, direction)
    local targets = {}
    local footprint = cursor:getFootprint() or {}
    for index = 1, #footprint do
        local tile = footprint[index]
        if tile.sprite and AttachedSprites.isWallDecorationSprite(tile.sprite) then
            local target = getCell()
                :getGridSquare(square:getX() + (tile.dx or 0), square:getY() + (tile.dy or 0), square:getZ()
                    + (tile.dz or 0))
            if target then targets[#targets + 1] = target end
        end
    end
    if #targets == 0 then targets[1] = square end
    return targets
end

--- Builds what `reason` asks for at (square, direction) so the cursor fits
--- there, then calls done(true) or done(false, why).
function BuildTestRunner.stackPrerequisite(t, player, cursor, square, direction, reason, depth, fixtures, ctx, done)
    depth = depth or 0
    if depth >= BuildTestRunner.MAX_PREREQUISITE_DEPTH then return done(false, reason) end
    local kind, names = BuildTestRunner.prerequisiteFor(cursor, reason)
    if not kind then return done(false, reason) end
    local needs = BuildTestRunner.needsOf(cursor, kind)
    local providers = BuildTestRunner.providers(kind, names, needs)
    local edges = nil
    if kind == "wall" and needs.isCorner and #providers == 0 then
        -- No corner piece: plain walls on the W and N edges join into one.
        providers = BuildTestRunner.providers(kind, names, { kind = "wall", shapes = {}, isCorner = false })
        edges = { 1, 2 }
    end
    if #providers == 0 then return done(false, reason .. " (no " .. kind .. " provider is registered)") end
    BuildTestRunner.setDirection(cursor, direction)
    local fixtureDirection = cursor.isWallLike and direction or (cursor.north == true and 2 or 1)
    if kind == "previous" then fixtureDirection = direction end
    local targetSquares = kind == "wall" and wallTargets(cursor, square, direction) or { square }
    local targets = {}
    for index = 1, #targetSquares do
        local directions = edges or { fixtureDirection }
        for edgeIndex = 1, #directions do
            targets[#targets + 1] = { square = targetSquares[index], direction = directions[edgeIndex] }
        end
    end
    local attempt, lastReason = 0, reason
    local function tryNext()
        attempt = attempt + 1
        local provider = providers[attempt]
        if not provider or attempt > BuildTestRunner.MAX_PROVIDER_ATTEMPTS then
            return done(
                false,
                tostring(lastReason) .. " (after trying "
                    .. (attempt - 1) .. " "
                    .. kind .. " prerequisite(s))"
            )
        end
        local built = {}
        local targetIndex = 0
        local function nextTarget()
            targetIndex = targetIndex + 1
            local target = targets[targetIndex]
            if not target then
                local ok, why = BuildTestRunner.accepts(cursor, square, direction)
                if ok then
                    BuildTestRunner.rememberProvider(kind, names, needs, provider)
                    return done(true, nil)
                end
                lastReason = why
                BuildTestRunner.removeEntries(built)
                forgetEntries(fixtures, built)
                return tryNext()
            end
            BuildTestRunner.buildFixtureAt(
                t,
                player,
                provider,
                target.square,
                target.direction,
                depth + 1,
                fixtures,
                ctx,
                function (entries, why)
                    if not entries then
                        lastReason = why or lastReason
                        BuildTestRunner.removeEntries(built)
                        forgetEntries(fixtures, built)
                        return tryNext()
                    end
                    for index = 1, #entries do
                        built[#built + 1] = entries[index]
                    end
                    nextTarget()
                end
            )
        end
        nextTarget()
    end
    tryNext()
end

--- Finds a site for the cursor inside `area`, stacking prerequisites when the
--- real validation asks for one, then calls done(square, direction, reason).
function BuildTestRunner.prepareSite(t, player, cursor, area, depth, fixtures, ctx, exclude, done)
    local square, direction, reason = BuildTestRunner.findSite(cursor, area, exclude)
    if square then return done(square, direction, nil) end
    local kind = BuildTestRunner.prerequisiteFor(cursor, reason)
    if not kind then return done(nil, nil, reason) end
    local candidates = BuildTestRunner.candidates(cursor, area, 3)
    local index, lastReason = 0, reason
    local function tryNext()
        index = index + 1
        local candidate = candidates[index]
        if not candidate or index > 4 then return done(nil, nil, lastReason) end
        if exclude and exclude[squareKey(candidate.square)] then return tryNext() end
        local ok, why = BuildTestRunner.accepts(cursor, candidate.square, candidate.direction)
        if ok then return done(candidate.square, candidate.direction, nil) end
        if not BuildTestRunner.prerequisiteFor(cursor, why) then
            lastReason = why
            return tryNext()
        end
        BuildTestRunner.stackPrerequisite(
            t,
            player,
            cursor,
            candidate.square,
            candidate.direction,
            why,
            depth or 0,
            fixtures,
            ctx,
            function (stacked, stackReason)
                if stacked then return done(candidate.square, candidate.direction, nil) end
                lastReason = stackReason or lastReason
                tryNext()
            end
        )
    end
    tryNext()
end

-- MANUAL MODE -------------------------------------------------------------

--- Supplies a case and hands the real cursor to the player.
---@return boolean ok
---@return string | nil reason
function BuildTestRunner.prepareManual(player, testCase)
    if not player or not testCase then return false, getText("IGUI_KBW_DebugTestNoSelection") end
    if isClient() then return false, getText("IGUI_KBW_DebugTestSingleplayerOnly") end
    if player:isBuildCheat() then return false, getText("IGUI_KBW_DebugTestDisableBuildCheat") end
    if not Integrity.isAllowed(player) then return false, getText("IGUI_KBW_IntegrityMismatchShort") end
    local definition, stage, reason = BuildTestRunner.resolve(testCase)
    if not definition or not stage then return false, tostring(reason) end
    if StageConfig.placement(definition, stage).kind == "wallCovering" then
        return false, getText("IGUI_KBW_DebugTestWallCoveringManual")
    end
    BuildTestRunner.cleanupSpawnedItems(player)
    local ok, why, choices = BuildTestRunner.supply(player, definition, stage, nil, nil, true)
    if not ok then return false, why end
    local cursor = BuildTestRunner.newCursor(
        player, testCase.buildableId, testCase.stageId, testCase.variantId, testCase.materialId, choices
    )
    if not cursor then return false, getText("IGUI_KBW_DebugTestCursorFailed") end
    getCell():setDrag(cursor, player:getPlayerNum())
    return true, nil
end

return BuildTestRunner
