local KBW = require("KnoxBuildworks/Core")

KBW.JsonCallbacks = KBW.JsonCallbacks or {}
KBW.JsonCallbacks.Floor = KBW.JsonCallbacks.Floor or {}
KBW.JsonCallbacks.DoorFrame = KBW.JsonCallbacks.DoorFrame or {}
KBW.JsonCallbacks.Surface = KBW.JsonCallbacks.Surface or {}

local Floor = KBW.JsonCallbacks.Floor
local DoorFrame = KBW.JsonCallbacks.DoorFrame
local Surface = KBW.JsonCallbacks.Surface

function Floor.OnIsValid(params)
    if not params or not params.square or not params.tileInfo then return false end
    if params.square:HasStairsBelow() then return false end
    local spriteName = params.tileInfo:getSpriteName()
    for objectIndex = 0, params.square:getObjects():size() - 1 do
        local object = params.square:getObjects():get(objectIndex)
        local textureName = object:getTextureName()
        local objectSpriteName = object:getSpriteName()
        if (textureName and luautils.stringStarts(textureName, "vegetation_farming"))
            or (objectSpriteName and luautils.stringStarts(objectSpriteName, "vegetation_farming")) then
            return false
        end
        if (textureName and textureName == spriteName) or (objectSpriteName and objectSpriteName == spriteName) then
            return false
        end
    end
    if not params.square:connectedWithFloor() then return false end
    params.testCollisions = false
    return true
end

function Floor.OnCreate(params)
    local floor = params and params.thumpable
    local square = floor and floor:getSquare()
    if not square then return nil end
    local objects = square:getObjects()
    local rug = nil
    for objectIndex = objects:size() - 1, 0, -1 do
        local object = objects:get(objectIndex)
        if object and object ~= floor then
            local properties = object:getProperties()
            local shouldRemove = properties and (properties:has(IsoFlagType.canBeRemoved)
                or properties:has(IsoFlagType.solidfloor) or properties:has(IsoFlagType.noStart)
                or (properties:has(IsoFlagType.vegitation) and object:getType() ~= IsoObjectType.tree)
                or properties:has(IsoFlagType.taintedWater))
            local textureName = object:getTextureName()
            shouldRemove = shouldRemove or (textureName and string.contains(textureName, "blends_grassoverlays"))
            if textureName and string.contains(textureName, "floors_rugs") then
                rug = object
                shouldRemove = false
            end
            if shouldRemove then
                square:transmitRemoveItemFromSquare(object)
                square:RemoveTileObject(object)
            end
        end
    end
    if rug then
        local rugIndex = objects:indexOf(rug)
        local floorIndex = objects:indexOf(floor)
        if rugIndex >= 0 and floorIndex >= 0 and rugIndex < floorIndex then
            objects:set(rugIndex, floor)
            objects:set(floorIndex, rug)
        end
    end
    square:EnsureSurroundNotNull()
    square:RecalcProperties()
    if DesignationZoneAnimal then
        DesignationZoneAnimal.addNewRoof(square:getX(), square:getY(), square:getZ())
    end
    square:getCell():checkHaveRoof(square:getX(), square:getY())
    for z = square:getZ() - 1, 0, -1 do
        local below = getCell():getGridSquare(square:getX(), square:getY(), z)
        if not below then
            below = IsoGridSquare.getNew(getCell(), nil, square:getX(), square:getY(), z)
            getCell():ConnectNewSquare(below, false)
        end
        below:EnsureSurroundNotNull()
        below:RecalcAllWithNeighbours(true)
    end
    square:clearWater()
    square:disableErosion()
    sendServerCommand("erosion", "disableForSquare", {
        x = square:getX(), y = square:getY(), z = square:getZ()
    })
    invalidateLighting()
    square:setSquareChanged()
    floor:invalidateRenderChunkLevel(FBORenderChunk.DIRTY_OBJECT_ADD)
    return nil
end

function DoorFrame.OnIsValid(params)
    if not params or not params.square then return false end
    local adjacent = params.north and params.square:getN() or params.square:getW()
    if adjacent and adjacent:getModData()["ConnectedToStairs" .. tostring(params.north)] then return false end
    return true
end

function Surface.EnablePlaster(params)
    local object = params and params.thumpable
    if not object or not instanceof(object, "IsoThumpable") then return nil end
    object:setCanBePlastered(true)
    return nil
end

return KBW.JsonCallbacks
