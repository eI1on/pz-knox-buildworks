local AttachedSprites = {}

-- A wall a decoration can hang on; shared by placement validation and the build.
function AttachedSprites.isRelevantWall(object, north, isCorner)
    if not object or instanceof(object, "IsoWindow") then return false end
    local modData = object:getModData()
    if modData and modData.WindowWall then return true end
    local props = object:getProperties()
    if not props or props:has(IsoFlagType.solidfloor) then return false end
    if isCorner then return props:has(IsoFlagType.WallNW) or props:has(IsoFlagType.WallSE) end
    if north then
        return props:has(IsoFlagType.WallN) or props:has(IsoFlagType.WindowN)
            or props:has(IsoFlagType.DoorWallN) or props:has(IsoFlagType.WallNW)
            or props:has(IsoFlagType.WallSE)
            or (props:has(IsoFlagType.HoppableN) and props:has(IsoFlagType.WallNTrans))
    end
    return props:has(IsoFlagType.WallW) or props:has(IsoFlagType.WindowW)
        or props:has(IsoFlagType.DoorWallW) or props:has(IsoFlagType.WallNW)
        or props:has(IsoFlagType.WallSE)
        or (props:has(IsoFlagType.HoppableW) and props:has(IsoFlagType.WallWTrans))
end

function AttachedSprites.findWallHost(square, north, isCorner)
    if not square then return nil end
    local objects = square:getObjects()
    for objectIndex = objects:size() - 1, 0, -1 do
        local object = objects:get(objectIndex)
        if AttachedSprites.isRelevantWall(object, north == true, isCorner == true) then return object end
    end
    return nil
end

---True for decal-like sprites built as attached sprites on a host wall.
function AttachedSprites.isWallDecorationSprite(spriteName)
    if not spriteName then return false end
    local sprite = getSprite(spriteName)
    local properties = sprite and sprite:getProperties() or nil
    if not properties then return false end
    local attached = properties:has(IsoFlagType.attachedN) or properties:has(IsoFlagType.attachedW)
        or properties:has(IsoFlagType.attachedE) or properties:has(IsoFlagType.attachedS)
    if not attached then return false end
    return not (properties:has(IsoFlagType.solid) or properties:has(IsoFlagType.solidtrans)
        or properties:has(IsoFlagType.collideN) or properties:has(IsoFlagType.collideW)
        or properties:has(IsoFlagType.WallN) or properties:has(IsoFlagType.WallNTrans)
        or properties:has(IsoFlagType.WallW) or properties:has(IsoFlagType.WallWTrans)
        or properties:has(IsoFlagType.WallNW) or properties:has(IsoFlagType.WindowN)
        or properties:has(IsoFlagType.WindowW) or properties:has(IsoFlagType.windowN)
        or properties:has(IsoFlagType.windowW) or properties:has(IsoFlagType.doorN)
        or properties:has(IsoFlagType.doorW) or properties:has(IsoFlagType.DoorWallN)
        or properties:has(IsoFlagType.DoorWallW))
end

---Whether a decoration stage is a corner piece (stage object or placement flag).
function AttachedSprites.isCornerStage(placement, stage)
    return (placement and placement.isCorner == true) or ((stage and stage.object) or {}).isCorner == true
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
