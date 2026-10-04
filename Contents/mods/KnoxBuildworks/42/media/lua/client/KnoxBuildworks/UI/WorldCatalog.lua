local KBW = require("KnoxBuildworks/Core")
local Catalog = require("KnoxBuildworks/UI/Catalog")
local CatalogIndex = require("KnoxBuildworks/UI/CatalogIndex")
local CatalogVisibility = require("KnoxBuildworks/UI/CatalogVisibility")
local Groups = require("KnoxBuildworks/Definitions/Groups")
local StageConfig = require("KnoxBuildworks/Definitions/StageConfig")
local Placement = require("KnoxBuildworks/Validation/Placement")
local I18n = require("KnoxBuildworks/I18n")
local TableUtil = require("KnoxBuildworks/Util/Table")
local WallFinishes = require("KnoxBuildworks/Validation/WallFinishes")

local WorldCatalog = {}
local cachedIndex, bySprite, openings

local function addSprite(sprite, target)
    if not sprite then return end
    bySprite[sprite] = bySprite[sprite] or {}
    bySprite[sprite][#bySprite[sprite] + 1] = target
end

local function addRecipe(entry, definition, stage, stageIndex, variantIndex, materialIndex, suffix)
    local config = StageConfig.sprite(definition, stage)
    local placement = StageConfig.placement(definition, stage)
    local target = {
        entry = entry, definition = definition, stage = stage,
        label = (stage.label or I18n.definitionName(definition)) .. suffix,
        state = {scope = "All", search = "", selectedId = entry.id, stageIndex = stageIndex,
            buildableId = definition.id, stageId = Groups.resolveStageId(stage),
            variantIndex = variantIndex, materialIndex = materialIndex}
    }
    local seen = {}
    for face, cells in pairs(stage.cellsByFace or {}) do
        for index = 1, #cells do
            local sprite = cells[index].sprite
            if sprite and not seen[sprite] then seen[sprite] = true; addSprite(sprite, target) end
        end
        local first = cells[1]
        local sprite = first and first.sprite and getSprite(first.sprite)
        local kind = sprite and sprite:getType()
        local window = placement.needWindowFrame or config.needWindowFrame
        local door = kind == IsoObjectType.doorN or kind == IsoObjectType.doorW
        if (window or door) and (face == "N" or face == "W") then
            openings[#openings + 1] = {target = target, cells = cells, north = face == "N", window = window == true, placement = placement}
        end
    end
    local finishes = WallFinishes.entriesFor(definition, stage)
    for index = 1, #finishes do
        local finish = finishes[index]
        if WallFinishes.isWallFinish(finish) then
            local finished = {entry = entry, definition = definition, stage = stage,
                label = target.label .. " / " .. I18n.optionName(finish, finish.id),
                state = TableUtil.merge(target.state, {finishSignature = WallFinishes.plannedFinishSignature(finish)})}
            local west = WallFinishes.previewSprite(finish, false, definition, stage)
            local north = WallFinishes.previewSprite(finish, true, definition, stage)
            -- Tint-only finishes share the original sprite; sprite identity
            -- alone cannot identify their color on a world object.
            if west and not seen[west] then addSprite(west, finished) end
            if north and not seen[north] then addSprite(north, finished) end
        end
    end
end

local function indexRecipes()
    local index = CatalogIndex.get()
    if index == cachedIndex then return end
    cachedIndex, bySprite, openings = index, {}, {}
    for entryIndex = 1, #index.list do
        local entry = index.list[entryIndex]
        -- list contains grouped definitions; orderByName/orderById contain records.
        local catalogDefinition = entry
        local stages = catalogDefinition and catalogDefinition.stages or {}
        for stageIndex = 1, #stages do
            local stage = stages[stageIndex]
            local definition = Groups.resolveDefinition(catalogDefinition, stage)
            local variants, materials = definition.variants or {}, definition.materialOptions or {}
            if not definition.materialRequired or #materials == 0 then
                addRecipe(entry, definition, stage, stageIndex, 1, 1, "")
            end
            for variantIndex = 0, #variants do
                local variant = variants[variantIndex]
                local varied = variant and TableUtil.merge(definition, variant) or definition
                for materialIndex = definition.materialRequired and #materials > 0 and 1 or 0, #materials do
                    local material = materials[materialIndex]
                    if variant or material then
                        local effective = material and TableUtil.merge(varied, material) or varied
                        effective.id = definition.id
                        local targetId = Groups.resolveStageId(stage)
                        local effectiveStages = effective.stages or {}
                        for index = 1, #effectiveStages do
                            if effectiveStages[index].id == targetId then
                                local suffix = variant and (" / " .. I18n.optionName(variant, variant.id)) or ""
                                if material then suffix = suffix .. " / " .. I18n.optionName(material, material.id) end
                                local selectedMaterial = materialIndex + (definition.materialRequired and 0 or 1)
                                addRecipe(entry, effective, effectiveStages[index], stageIndex, variantIndex + 1,
                                    math.max(1, selectedMaterial), suffix)
                            end
                        end
                    end
                end
            end
        end
    end
end

local function fits(square, candidate)
    for cellIndex = 1, #candidate.cells do
        local cell = candidate.cells[cellIndex]
        if cell.sprite then
            local target = getCell():getGridSquare(
                square:getX() + cell.dx, square:getY() + cell.dy, square:getZ() + (cell.dz or 0)
            )
            local sprite = getSprite(cell.sprite)
            local shape = candidate.placement.ignoreWindowShape ~= true
                and Placement.windowShapeOf(sprite and sprite:getProperties()) or nil
            if not Placement.hasWallFrame(target, candidate.north, candidate.window,
                    candidate.placement.windowSupportSprites, shape) then return false end
        end
    end
    return true
end

local function openRecipe(player, target)
    Catalog.open(player, target.state)
end

local function addMenu(context, player, label, targets)
    if #targets == 0 then return end
    table.sort(targets, function(a, b)
        if a.label ~= b.label then return a.label < b.label end
        return a.entry.id < b.entry.id
    end)
    local parent = context:addOption(label, nil, nil)
    local menu = ISContextMenu:getNew(context)
    context:addSubMenu(parent, menu)
    for index = 1, #targets do
        local target = targets[index]
        menu:addOption(target.label, player, openRecipe, target)
    end
end

function WorldCatalog.onContextMenu(playerNum, context, worldObjects, test)
    if not KBW.Runtime.loaded then return end
    local player = getSpecificPlayer(playerNum)
    if not player then return end
    indexRecipes()
    local same, matching, seenSame, seenMatching, squares = {}, {}, {}, {}, {}
    local function append(list, seen, target)
        local key = target.entry.id .. ":" .. tostring(target.state.stageIndex)
            .. ":" .. tostring(target.state.variantIndex) .. ":" .. tostring(target.state.materialIndex)
            .. ":" .. tostring(target.state.finishSignature)
        if not seen[key] and CatalogVisibility.definitionEnabled(target.definition)
            and CatalogVisibility.stagePasses(player, target.definition, target.stage) then
            seen[key] = true
            list[#list + 1] = target
        end
    end
    for objectIndex = 1, #worldObjects do
        local object = worldObjects[objectIndex]
        local square = object and object:getSquare()
        if square and not squares[square] then
            squares[square] = true
            local objects = square:getObjects()
            local shapedOpening = false
            for index = 0, objects:size() - 1 do
                local sprite = objects:get(index):getSprite()
                local props = sprite and sprite:getProperties()
                if props and Placement.windowShapeOf(props)
                    and (props:has(IsoFlagType.cutN) or props:has(IsoFlagType.cutW)) then
                    shapedOpening = true
                end
                local targets = sprite and bySprite[sprite:getName()] or {}
                for targetIndex = 1, #targets do append(same, seenSame, targets[targetIndex]) end
            end
            -- Most right-clicks have no opening. Avoid walking the window
            -- catalogue unless there is an empty frame on this square.
            if shapedOpening or Placement.hasWallFrame(square, true, true) or Placement.hasWallFrame(square, false, true)
                or Placement.hasWallFrame(square, true, false) or Placement.hasWallFrame(square, false, false) then
                for index = 1, #openings do
                    local candidate = openings[index]
                    if fits(square, candidate) then append(matching, seenMatching, candidate.target) end
                end
            end
        end
    end
    if test then
        if #same > 0 or #matching > 0 then return ISWorldObjectContextMenu.setTest() end
        return
    end
    addMenu(context, player, getText("IGUI_KBW_FindWorldPiece"), same)
    addMenu(context, player, getText("IGUI_KBW_FindMatchingOpening"), matching)
end

Events.OnFillWorldObjectContextMenu.Add(WorldCatalog.onContextMenu)
return WorldCatalog
