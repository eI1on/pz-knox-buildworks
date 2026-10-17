---WorldCatalog is the World lookup context menu: right-click a built piece for
---"Find this piece", or an empty frame for "Find a matching opening", and the
---Catalog opens on that recipe. Which recipe draws what comes from
---WorldPieceIndex; this module is only the menu.
local KBW = require("KnoxBuildworks/Core")
local Catalog = require("KnoxBuildworks/UI/Catalog")
local CatalogVisibility = require("KnoxBuildworks/UI/CatalogVisibility")
local Placement = require("KnoxBuildworks/Validation/Placement")
local WorldPieceIndex = require("KnoxBuildworks/UI/WorldPieceIndex")

local WorldCatalog = {}

-- Kept for add-ons that called it here before the index had its own module.
WorldCatalog.placementsForObject = WorldPieceIndex.placementsForObject

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
                local targets = WorldPieceIndex.recipesForSprite(sprite and sprite:getName() or nil)
                for targetIndex = 1, #targets do append(same, seenSame, targets[targetIndex]) end
            end
            -- Most right-clicks have no opening. Avoid walking the window
            -- catalogue unless there is an empty frame on this square.
            if shapedOpening or Placement.hasWallFrame(square, true, true) or Placement.hasWallFrame(square, false, true)
                or Placement.hasWallFrame(square, true, false) or Placement.hasWallFrame(square, false, false) then
                local openings = WorldPieceIndex.openings()
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
