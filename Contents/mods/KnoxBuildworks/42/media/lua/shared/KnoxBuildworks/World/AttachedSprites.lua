local AttachedSprites = {}

local function isRelevantWall(object, north, isCorner)
    if not object or instanceof(object, "IsoWindow") then return false end
    local props = object:getProperties()
    if not props or props:has(IsoFlagType.solidfloor) then return false end
    if isCorner then return props:has(IsoFlagType.WallNW) or props:has(IsoFlagType.WallSE) end
    if north then
        return props:has(IsoFlagType.WallN) or props:has(IsoFlagType.WindowN)
            or props:has(IsoFlagType.DoorWallN) or props:has(IsoFlagType.WallNW)
            or props:has(IsoFlagType.WallSE)
    end
    return props:has(IsoFlagType.WallW) or props:has(IsoFlagType.WindowW)
        or props:has(IsoFlagType.DoorWallW) or props:has(IsoFlagType.WallNW)
        or props:has(IsoFlagType.WallSE)
end

function AttachedSprites.findWallHost(square, north, isCorner)
    if not square then return nil end
    local objects = square:getObjects()
    for objectIndex = objects:size() - 1, 0, -1 do
        local object = objects:get(objectIndex)
        if isRelevantWall(object, north == true, isCorner == true) then return object end
    end
    return nil
end

function AttachedSprites.attach(object, spriteName, buildData)
    local sprite = spriteName and getSprite(spriteName) or nil
    if not object or not sprite then return nil end
    local attached = object:getAttachedAnimSprite()
    if not attached then
        attached = ArrayList:new()
        object:setAttachedAnimSprite(attached)
    end
    local instance = sprite:newInstance()
    attached:add(instance)
    local data = object:getModData()
    data.KBWAttachedSprites = data.KBWAttachedSprites or {}
    data.KBWAttachedSprites[#data.KBWAttachedSprites + 1] = {
        sprite = spriteName,
        buildableId = buildData and buildData.buildableId or nil
    }
    if isClient() then
        object:transmitUpdatedSpriteToServer()
    elseif object.transmitUpdatedSpriteToClients then
        object:transmitUpdatedSpriteToClients()
    end
    if object.transmitModData then object:transmitModData() end
    return instance
end

function AttachedSprites.remove(object, spriteName)
    if not object or not spriteName then return false end
    local attached = object:getAttachedAnimSprite()
    if not attached then return false end
    for index = attached:size() - 1, 0, -1 do
        local instance = attached:get(index)
        local parent = instance and instance:getParentSprite() or nil
        if parent and parent:getName() == spriteName then
            object:RemoveAttachedAnim(index)
            local data = object:getModData()
            local tracked = data.KBWAttachedSprites or {}
            for trackedIndex = #tracked, 1, -1 do
                if tracked[trackedIndex].sprite == spriteName then
                    table.remove(tracked, trackedIndex)
                    break
                end
            end
            if object.transmitUpdatedSpriteToClients then object:transmitUpdatedSpriteToClients() end
            if object.transmitModData then object:transmitModData() end
            return true
        end
    end
    return false
end

return AttachedSprites
