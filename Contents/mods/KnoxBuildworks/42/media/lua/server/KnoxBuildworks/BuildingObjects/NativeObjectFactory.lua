---@diagnostic disable: undefined-global
local NativeObjectTypes = require("KnoxBuildworks/World/NativeObjectTypes")
local Mannequins = require("KnoxBuildworks/World/Mannequins")

local NativeObjectFactory = {}

local handlers = {}

local function register(objectType, handler)
    handlers[objectType] = handler
end

-- Matches ISMoveableSpriteProps:placeMoveableInternal: a table-top object sits
-- at the height of the surface under it.
local function applyTableTopOffset(object, sprite, square)
    local properties = sprite and sprite:getProperties() or nil
    if not properties or not properties:has("IsTableTop") then return end
    local moveable = ISMoveableSpriteProps.new(sprite)
    local surface = moveable:getTotalTableHeight(square)
    if moveable.surface and moveable.surfaceIsOffset then
        surface = surface - moveable.surface
    end
    object:setRenderYOffset(surface)
end

local function initializeSpriteContainers(object, sprite, markMoved)
    if markMoved ~= false and object.setMovedThumpable then object:setMovedThumpable(true) end
    if object.createContainersFromSpriteProperties then
        object:createContainersFromSpriteProperties()
        if object.getContainerCount and object.getContainerByIndex then
            for index = 0, object:getContainerCount() - 1 do
                local container = object:getContainerByIndex(index)
                if container then container:setExplored(true) end
            end
        end
    end
    local properties = sprite and sprite:getProperties() or nil
    if properties and properties:has(IsoFlagType.waterPiped) then
        object:getModData().canBeWaterPiped = true
    end
end

local function registerSpriteObject(objectType, constructor)
    register(objectType, {
        create = function (config, square, spriteName)
            local sprite = spriteName and getSprite(spriteName) or nil
            if not sprite then
                return nil, "could not resolve " .. objectType .. " sprite " .. tostring(spriteName)
            end
            local object = constructor(getCell(), square, sprite)
            if not object then
                return nil, "could not initialize native " .. objectType .. " from " .. tostring(spriteName)
            end
            initializeSpriteContainers(object, sprite)
            return object, {
                alreadyAdded = false,
                alreadyTransmitted = false
            }
        end,
        finalize = function (object, square)
            square:RecalcAllWithNeighbours(true)
        end
    })
end

register("generator", {
    create = function (config, square, spriteName)
        local item = config and instanceItem(config.item) or nil
        local object = item and IsoGenerator.new(item, getCell(), square) or nil
        if not object then
            return nil, "could not initialize IsoGenerator from " .. tostring(config and config.item)
        end
        if spriteName then object:setSprite(getSprite(spriteName)) end
        return object, {
            alreadyAdded = true,
            alreadyTransmitted = isServer()
        }
    end,
    finalize = function (object, square)
        square:RecalcAllWithNeighbours(true)
        IsoGenerator.updateGenerator(square)
    end
})

register("fireplace", {
    create = function (config, square, spriteName)
        local sprite = spriteName and getSprite(spriteName) or nil
        if not sprite then
            return nil, "could not resolve fireplace sprite " .. tostring(spriteName)
        end
        local object = IsoFireplace.new(getCell(), square, sprite)
        initializeSpriteContainers(object, sprite, false)
        return object, {
            alreadyAdded = false,
            alreadyTransmitted = false
        }
    end,
    finalize = function (object, square)
        square:RecalcAllWithNeighbours(true)
    end
})

register("lightSwitch", {
    create = function (config, square, spriteName)
        local sprite = spriteName and getSprite(spriteName) or nil
        if not sprite then
            return nil, "could not resolve light-switch sprite " .. tostring(spriteName)
        end
        local object = IsoLightSwitch.new(getCell(), square, sprite, square:getRoomID())
        if not object then
            return nil, "could not initialize IsoLightSwitch from " .. tostring(spriteName)
        end

        object:addLightSourceFromSprite()

        applyTableTopOffset(object, sprite, square)

        return object, {
            alreadyAdded = false,
            alreadyTransmitted = false
        }
    end,
    finalize = function (object, square)
        -- A lamp (lightR tile) owns its light and needs nothing more. A wall
        -- switch inside a map room controls that room: the constructor may
        -- have changed the room's lightsActive on the server only, so push the
        -- room state to clients the same way a toggle does (sendMetaGrid).
        -- Wall switches outside map rooms are handled by World/LightSwitches.
        if square:getRoom() ~= nil and not object:getCanBeModified() then
            object:switchLight(object:isActivated())
        end
        square:RecalcAllWithNeighbours(true)
        IsoGenerator.updateGenerator(square)
    end
})

-- Glass panes (windowN/windowW tiles) are IsoWindow objects on the map
-- (CellLoader) and when built by vanilla (BuildRecipeCode.windowGlass). As an
-- IsoThumpable they become an open window frame anyone can climb through; a
-- WindowLocked pane (sliding-door side panels, shop glass) must stay shut and
-- can only be smashed, which IsoWindow's permaLocked handles.
register("window", {
    create = function (config, square, spriteName)
        local sprite = spriteName and getSprite(spriteName) or nil
        local properties = sprite and sprite:getProperties() or nil
        if not properties or not (properties:has(IsoFlagType.windowN) or properties:has(IsoFlagType.windowW)) then
            return nil, "could not resolve window sprite " .. tostring(spriteName)
        end
        local object = IsoWindow.new(getCell(), square, sprite, properties:has(IsoFlagType.windowN))
        if not object then return nil, "could not initialize IsoWindow from " .. tostring(spriteName) end
        object:setIsLocked(false)
        return object, {
            alreadyAdded = false,
            alreadyTransmitted = false
        }
    end,
    finalize = function (object, square)
        square:RecalcAllWithNeighbours(true)
    end
})

-- Match ISMoveableSpriteProps:placeMoveableInternal for WindowObject tiles.
-- South/east faces sit on the far side of the window and must be inserted
-- directly after that window or frame for the game's curtain lookup/rendering.
register("curtain", {
    create = function (config, square, spriteName)
        local sprite = spriteName and getSprite(spriteName) or nil
        local properties = sprite and sprite:getProperties() or nil
        if not properties or not properties:has("MoveType")
            or properties:get("MoveType") ~= "WindowObject" then
            return nil, "could not resolve curtain sprite " .. tostring(spriteName)
        end
        local facing = properties:has("Facing") and properties:get("Facing") or nil
        if facing ~= "N" and facing ~= "S" and facing ~= "W" and facing ~= "E" then
            return nil, "curtain sprite has no valid facing " .. tostring(spriteName)
        end
        local north = facing == "N" or facing == "S"
        local closed = properties:has("IsClosedState")
        local openName = spriteName
        if closed then
            local prefix, number = string.match(spriteName, "^(.*_)(%d+)$")
            if not prefix then return nil, "could not resolve open curtain sprite " .. tostring(spriteName) end
            openName = prefix .. tostring(tonumber(number) + 4)
        end
        local object = IsoCurtain.new(getCell(), square, openName, north)
        if closed then object:ToggleDoorSilent() end
        local state = {alreadyAdded = false, alreadyTransmitted = false}
        if facing == "S" or facing == "E" then
            local moveable = ISMoveableSpriteProps.new(sprite)
            local frame = moveable:getWallForFacing(square, facing, "WindowFrame")
            local window = square:getWindow(north and GridSquareEdgeFacingDirection.NORTH_SOUTH
                or GridSquareEdgeFacingDirection.EAST_WEST)
            local objects = square:getObjects()
            for index = 0, objects:size() - 1 do
                local candidate = objects:get(index)
                if (window and candidate == window) or (frame and candidate == frame) then
                    state.insertAfter = candidate
                end
            end
        end
        return object, state
    end,
    finalize = function (object, square)
        square:RecalcAllWithNeighbours(true)
    end
})

-- A mannequin owns its container, its 3D model and its facing; none of that
-- survives being built as a plain tile object.
register("mannequin", {
    create = function (config, square, spriteName, context)
        local sprite = spriteName and getSprite(spriteName) or nil
        if not sprite then
            return nil, "could not resolve mannequin sprite " .. tostring(spriteName)
        end
        local object = IsoMannequin.new(getCell(), square, sprite)
        if not object then
            return nil, "could not initialize IsoMannequin from " .. tostring(spriteName)
        end
        object:setSquare(square)
        Mannequins.applyScript(object, spriteName, config and config.script)
        object:setForwardIsoDirection(Mannequins.directionIndex(spriteName, context and context.direction))
        applyTableTopOffset(object, sprite, square)
        return object, {
            alreadyAdded = false,
            alreadyTransmitted = false
        }
    end,
    finalize = function (object, square)
        -- Runs after addToWorld, so the outfit the engine rolled there is gone
        -- too and a built mannequin is the player's to dress.
        Mannequins.strip(object)
        square:RecalcAllWithNeighbours(true)
    end
})

registerSpriteObject("barbecue", function (cell, square, sprite)
    return IsoBarbecue.new(cell, square, sprite)
end)

registerSpriteObject("clothingDryer", function (cell, square, sprite)
    return IsoClothingDryer.new(cell, square, sprite)
end)

registerSpriteObject("clothingWasher", function (cell, square, sprite)
    return IsoClothingWasher.new(cell, square, sprite)
end)

registerSpriteObject("combinationWasherDryer", function (cell, square, sprite)
    return IsoCombinationWasherDryer.new(cell, square, sprite)
end)

-- Radios and televisions: IsoWaveSignal(cell, square, sprite) builds the
-- device data from the tile's own signal properties, as map-placed sets get.
registerSpriteObject("radio", function (cell, square, sprite)
    return IsoRadio.new(cell, square, sprite)
end)

registerSpriteObject("television", function (cell, square, sprite)
    return IsoTelevision.new(cell, square, sprite)
end)

registerSpriteObject("stove", function (cell, square, sprite)
    return IsoStove.new(cell, square, sprite)
end)

function NativeObjectFactory.resolve(config, spriteName)
    return NativeObjectTypes.resolve(config, spriteName)
end

function NativeObjectFactory.create(objectType, config, square, spriteName, context)
    local handler = handlers[objectType]
    if not handler then return nil, nil, "unsupported native object type " .. tostring(objectType) end
    local object, stateOrReason = handler.create(config or {}, square, spriteName, context)
    if not object then return nil, nil, stateOrReason end
    local state = stateOrReason or {}
    state.type = objectType
    return object, state, nil
end

function NativeObjectFactory.insert(object, state, square, insertIndex)
    if state and state.alreadyAdded then return end
    if state and state.type == "curtain" and state.insertAfter then
        -- Replacements may have removed a preceding object since create().
        local objects = square:getObjects()
        for index = 0, objects:size() - 1 do
            if objects:get(index) == state.insertAfter then insertIndex = index + 1; break end
        end
    end
    if insertIndex and insertIndex >= 0 then
        square:AddSpecialObject(object, insertIndex)
    else
        square:AddSpecialObject(object)
    end
end

function NativeObjectFactory.finalize(object, state, square)
    local handler = state and handlers[state.type] or nil
    if handler and handler.finalize then handler.finalize(object, square) end
end

return NativeObjectFactory
