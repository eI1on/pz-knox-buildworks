---FinishQueue provides the Knox Buildworks blueprint planning layer.
local WallFinishes = require("KnoxBuildworks/Validation/WallFinishes")
local KBWFinishAction = require("KnoxBuildworks/TimedActions/KBWFinishAction")
local Log = require("KnoxBuildworks/Log")

-- Applies a wall finish after the wall itself is built, by chaining Knox
-- finish actions (plaster, then paint or wallpaper). Sprites come from the
-- wall-type mapping so custom tilepack walls finish onto their own sprites;
-- consumption matches vanilla/entity scripts (trowel kept/degraded + bucket
-- use, brush + can, roll + paste).
--
-- Phases per watch:
--   built     -> the wall thumpable exists on the square: queue plaster
--   plastered -> the wall became paintable: queue paint or wallpaper
---@class KBW.FinishQueueModule
---@type KBW.FinishQueueModule
local FinishQueue = {}

local pending = {}

local function findBuiltWall(entry)
    local square = getCell():getGridSquare(entry.x, entry.y, entry.z)
    if not square then return nil end
    local candidates = {}
    for i = 0, square:getSpecialObjects():size() - 1 do
        local object = square:getSpecialObjects():get(i)
        if instanceof(object, "IsoThumpable") then
            local data = object:getModData()
            if data and data.KBW and data.KBW.buildableId == entry.buildableId then
                candidates[#candidates + 1] = object
                if object:getNorth() == entry.north then return object end
            end
        end
    end
    -- A snapped/replaced wall can report its final edge only after creation.
    -- Falling back is safe when this square contains exactly one matching Knox
    -- wall; with an N+W corner we retain strict edge matching.
    if #candidates == 1 then return candidates[1] end
    return nil
end

local function cheat(player)
    return player.isBuildCheat and player:isBuildCheat()
end

local function predicateNotBroken(item)
    if not item then return false end
    if item.isBroken and item:isBroken() then return false end
    if item.isDestroyed and item:isDestroyed() then return false end
    return true
end

local function predicateEnoughDrain(item)
    if not item then return false end
    if item.isDestroyed and item:isDestroyed() then return false end
    if item.getCurrentUsesFloat then return item:getCurrentUsesFloat() >= 0.1 end
    if item.getCurrentUses then return item:getCurrentUses() > 0 end
    return true
end

local function finishSprite(entry, wall, mode)
    local wallType = WallFinishes.objectWallType(wall)
    local north = WallFinishes.objectNorth(wall)
    return WallFinishes.spriteForWallType(mode, entry.finish, north, wallType)
        or WallFinishes.spriteFor(mode, entry.finish, north, entry.definition, entry.stage)
end

local function queuePlaster(entry, wall)
    local player = entry.player
    local sprite = finishSprite(entry, wall, "plaster")
    if not sprite then
        Log:warning("No plaster sprite for %s at %d,%d,%d", entry.buildableId, entry.x, entry.y, entry.z)
        return false
    end
    local bucket = nil
    local trowel = nil
    if not cheat(player) then
        trowel = player:getInventory():getFirstTagEvalRecurse(ItemTag.PLASTER_TROWEL, predicateNotBroken)
        bucket = player:getInventory():getFirstTagEvalRecurse(ItemTag.PLASTER_BUCKET, predicateEnoughDrain)
        if not trowel or not bucket then
            Log:warning("Plaster action lost its required tool/material for %s", entry.buildableId)
            return false
        end
        ISWorldObjectContextMenu.transferIfNeeded(player, trowel)
        ISWorldObjectContextMenu.transferIfNeeded(player, bucket)
    end
    ISTimedActionQueue.add(KBWFinishAction:new(player, "plaster", wall, sprite, bucket, trowel, nil, nil, entry.finish))
    return true
end

local function queuePaint(entry, wall)
    local player = entry.player
    local sprite = finishSprite(entry, wall, "paint")
    if not sprite then
        Log:warning("No paint sprite for %s at %d,%d,%d", entry.buildableId, entry.x, entry.y, entry.z)
        return false
    end
    local paintCan = nil
    if not cheat(player) then
        local brush = player:getInventory():getFirstTagEvalRecurse(ItemTag.PAINTBRUSH, predicateNotBroken)
        if not brush then return false end
        ISWorldObjectContextMenu.transferIfNeeded(player, brush)
        paintCan = player:getInventory():getFirstTypeRecurse(entry.finish.paintType)
        if not paintCan then return false end
        ISWorldObjectContextMenu.transferIfNeeded(player, paintCan)
    end
    ISTimedActionQueue.add(KBWFinishAction:new(player, "paint", wall, sprite, paintCan, nil, nil, nil, entry.finish))
    return true
end

local function queueWallpaper(entry, wall)
    local player = entry.player
    local sprite = finishSprite(entry, wall, "wallpaper")
    if not sprite then
        Log:warning("No wallpaper sprite for %s at %d,%d,%d", entry.buildableId, entry.x, entry.y, entry.z)
        return false
    end
    local roll = nil
    if not cheat(player) then
        roll = player:getInventory():getFirstTypeRecurse(entry.finish.wallpaperType)
        local brush = player:getInventory():getFirstTagEvalRecurse(ItemTag.PAINTBRUSH, predicateNotBroken)
        local paste = player:getInventory():getFirstTagEvalRecurse(ItemTag.WALLPAPER_PASTE, predicateEnoughDrain)
        local scissors = player:getInventory():getFirstTagEvalRecurse(ItemTag.SCISSORS, predicateNotBroken)
        if not roll or not brush or not paste or not scissors then return false end
        ISWorldObjectContextMenu.transferIfNeeded(player, roll)
        ISWorldObjectContextMenu.transferIfNeeded(player, brush)
        ISWorldObjectContextMenu.transferIfNeeded(player, paste)
        ISWorldObjectContextMenu.transferIfNeeded(player, scissors)
    end
    ISTimedActionQueue.add(KBWFinishAction:new(player, "wallpaper", wall, sprite, roll, nil, nil, nil, entry.finish))
    return true
end

local function isPlastered(wall)
    if wall.isPaintable and wall:isPaintable() then return true end
    local sprite = wall:getSprite()
    local props = sprite and sprite:getProperties()
    return props ~= nil and props:get("PaintingType") ~= nil
end

local function step(entry)
    local now = getTimestampMs()
    if now > entry.deadline then
        Log:warning("Timed out applying selected finish to %s at %d,%d,%d", entry.buildableId, entry.x, entry.y, entry.z)
        return false
    end
    local wall = findBuiltWall(entry)
    if entry.phase == "built" then
        if not wall then return true end
        if entry.finish.plaster == false then
            if entry.finish.paintType then
                queuePaint(entry, wall)
            elseif entry.finish.wallpaperType then
                queueWallpaper(entry, wall)
            end
            return false
        end
        if not queuePlaster(entry, wall) then return false end
        if not entry.finish.paintType and not entry.finish.wallpaperType then return false end
        entry.phase = "plastered"
        entry.deadline = now + 30000
        return true
    end
    if entry.phase == "plastered" then
        if not wall or not isPlastered(wall) then return true end
        if ISTimedActionQueue.isPlayerDoingAction(entry.player) then return true end
        if entry.finish.paintType then
            queuePaint(entry, wall)
        elseif entry.finish.wallpaperType then
            queueWallpaper(entry, wall)
        end
        return false
    end
    return false
end

local function onTick()
    local remaining = {}
    for index = 1, #pending do
        local entry = pending[index]
        if step(entry) then remaining[#remaining + 1] = entry end
    end
    pending = remaining
    if #pending == 0 then Events.OnTick.Remove(onTick) end
end

---@param player IsoPlayer
---@param buildableId string
---@param x number
---@param y number
---@param z number
---@param north boolean
---@param finish KBW.WallFinish|nil
---@param definition KBW.BuildableDefinition
---@param stage KBW.BuildStage
function FinishQueue.watch(player, buildableId, x, y, z, north, finish, definition, stage)
    if not WallFinishes.isWallFinish(finish) then return end
    if #pending == 0 then Events.OnTick.Add(onTick) end
    pending[#pending + 1] = {
        player = player,
        buildableId = buildableId,
        x = x,
        y = y,
        z = z,
        north = north == true,
        finish = finish,
        definition = definition,
        stage = stage,
        phase = "built",
        -- The construction action may be behind walking, transfers, and other
        -- queued builds. A short timeout could discard the selected finish
        -- before the wall existed or before its plaster step completed.
        deadline = getTimestampMs() + 30000
    }
end

return FinishQueue
