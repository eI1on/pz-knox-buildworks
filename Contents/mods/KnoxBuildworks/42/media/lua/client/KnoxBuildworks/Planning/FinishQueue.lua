---FinishQueue provides the Knox Buildworks blueprint planning layer.
local WallFinishes = require("KnoxBuildworks/Validation/WallFinishes")
local KBWFinishAction = require("KnoxBuildworks/TimedActions/KBWFinishAction")
local BuildableRules = require("KnoxBuildworks/Admin/BuildableRules")
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

local function matchesEntry(object, entry)
    if not object or not object.getModData then return false end
    local data = object:getModData()
    return data ~= nil and data.KBW ~= nil and data.KBW.buildableId == entry.buildableId
end

-- The walls of this buildable already standing on the tile when the finish was
-- queued. The watcher starts from tryBuild, before the build action completes,
-- so without this the search could settle on a wall that was already there -
-- the other half of a V corner, or an earlier wall on the same tile - and the
-- finish went to that one instead of the wall being built.
local function wallsAlreadyOnTile(buildableId, x, y, z)
    local existing = {}
    local square = getCell() and getCell():getGridSquare(x, y, z) or nil
    if not square then return existing end
    local probe = { buildableId = buildableId }
    local special = square:getSpecialObjects()
    for objectIndex = 0, special:size() - 1 do
        local object = special:get(objectIndex)
        if matchesEntry(object, probe) then existing[object] = true end
    end
    local objects = square:getObjects()
    for objectIndex = 0, objects:size() - 1 do
        local object = objects:get(objectIndex)
        if matchesEntry(object, probe) then existing[object] = true end
    end
    return existing
end

local function findBuiltWall(entry, preferUnfinished)
    -- Once a wall has been picked it stays picked. The paint that follows a
    -- plaster must land on the same wall, and by then the tile can hold two
    -- finished walls that no longer tell each other apart.
    if entry.wall and entry.wall.getSquare and entry.wall:getSquare() then return entry.wall end
    local square = getCell():getGridSquare(entry.x, entry.y, entry.z)
    if not square then return nil end
    local candidates = {}
    local edgeMatch = nil
    for i = 0, square:getSpecialObjects():size() - 1 do
        local object = square:getSpecialObjects():get(i)
        if instanceof(object, "IsoThumpable") and matchesEntry(object, entry)
            and not (entry.existing and entry.existing[object]) then
            candidates[#candidates + 1] = object
            if edgeMatch == nil and object:getNorth() == entry.north then edgeMatch = object end
        end
    end
    -- Passable pieces build as props, so they are plain objects on the square
    -- rather than IsoThumpables among its special objects. Without this the
    -- watcher never saw them and every such finish waited out its timeout.
    if #candidates == 0 then
        local objects = square:getObjects()
        for i = 0, objects:size() - 1 do
            local object = objects:get(i)
            if not instanceof(object, "IsoThumpable") and matchesEntry(object, entry)
                and not (entry.existing and entry.existing[object]) then
                candidates[#candidates + 1] = object
            end
        end
    end
    -- Two walls of one buildable meeting in a V share this tile, and the one
    -- this finish was queued for is the one still bare - the neighbour has had
    -- its own finish applied already. Without this the finish could go to the
    -- neighbour, repainting it and leaving the new wall plain, or match neither
    -- and wait until it timed out.
    if preferUnfinished then
        if edgeMatch ~= nil and WallFinishes.objectFinishSignature(edgeMatch) == nil then
            return edgeMatch
        end
        local bare, bareCount = nil, 0
        for candidateIndex = 1, #candidates do
            if WallFinishes.objectFinishSignature(candidates[candidateIndex]) == nil then
                bare = candidates[candidateIndex]
                bareCount = bareCount + 1
            end
        end
        if bareCount == 1 then return bare end
    end
    if edgeMatch ~= nil then
        Log:info(
            "Finish for %s at %d,%d,%d took the edge match out of %d wall(s) on the tile",
            tostring(entry.buildableId), entry.x, entry.y, entry.z, #candidates
        )
        return edgeMatch
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
    local sprite = wall and wall:getSprite() or nil
    local baseSprite = sprite and sprite:getName() or nil
    return WallFinishes.spriteForWallType(mode, entry.finish, north, wallType, baseSprite)
        or WallFinishes.spriteFor(mode, entry.finish, north, entry.definition, entry.stage, baseSprite)
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
    local required = BuildableRules.wallFinishRequirement(entry.definition, entry.stage, "plaster")
    if required and not cheat(player) then
        trowel = player:getInventory():getFirstTagEvalRecurse(ItemTag.PLASTER_TROWEL, predicateNotBroken)
        bucket = player:getInventory():getFirstTagEvalRecurse(ItemTag.PLASTER_BUCKET, predicateEnoughDrain)
        if not trowel or not bucket then
            Log:warning("Plaster action lost its required tool/material for %s", entry.buildableId)
            return false
        end
        ISWorldObjectContextMenu.transferIfNeeded(player, trowel)
        ISWorldObjectContextMenu.transferIfNeeded(player, bucket)
    end
    Log:info("Queued plaster action for %s at %d,%d,%d", entry.buildableId, entry.x, entry.y, entry.z)
    ISTimedActionQueue.add(KBWFinishAction:new(
        player, "plaster", wall, sprite, bucket, trowel, nil, nil, entry.finish, true
    ))
    return true
end

local function queuePaint(entry, wall)
    local player = entry.player
    local sprite = finishSprite(entry, wall, "paint")
    if not sprite then
        Log:warning("No paint sprite for %s at %d,%d,%d", entry.buildableId, entry.x, entry.y, entry.z)
        return false
    end
    local paintCan, paintCans = nil, nil
    local required = BuildableRules.wallFinishRequirement(entry.definition, entry.stage, "paint")
    if required and not cheat(player) then
        local brush = player:getInventory():getFirstTagEvalRecurse(ItemTag.PAINTBRUSH, predicateNotBroken)
        if not brush then
            Log:warning("No usable paintbrush left for %s at %d,%d,%d", entry.buildableId, entry.x, entry.y, entry.z)
            return false
        end
        ISWorldObjectContextMenu.transferIfNeeded(player, brush)
        paintCans = WallFinishes.paintItemsIn(player:getInventory(), entry.finish.paintType)
        if not paintCans then
            Log:warning(
                "No %s left for %s at %d,%d,%d", tostring(entry.finish.paintType),
                entry.buildableId, entry.x, entry.y, entry.z
            )
            return false
        end
        for canIndex = 1, #paintCans do
            ISWorldObjectContextMenu.transferIfNeeded(player, paintCans[canIndex].item)
        end
        paintCan = paintCans[1].item
    end
    Log:info("Queued paint action for %s at %d,%d,%d", entry.buildableId, entry.x, entry.y, entry.z)
    ISTimedActionQueue.add(KBWFinishAction:new(
        player, "paint", wall, sprite, paintCan, nil, nil, nil, entry.finish, true, paintCans
    ))
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
    local required = BuildableRules.wallFinishRequirement(entry.definition, entry.stage, "wallpaper")
    if required and not cheat(player) then
        roll = player:getInventory():getFirstTypeRecurse(entry.finish.wallpaperType)
        local brush = player:getInventory():getFirstTagEvalRecurse(ItemTag.PAINTBRUSH, predicateNotBroken)
        local paste = player:getInventory():getFirstTagEvalRecurse(ItemTag.WALLPAPER_PASTE, predicateEnoughDrain)
        local scissors = player:getInventory():getFirstTagEvalRecurse(ItemTag.SCISSORS, predicateNotBroken)
        if not roll or not brush or not paste or not scissors then
            Log:warning(
                "Missing wallpaper tools or roll for %s at %d,%d,%d", entry.buildableId,
                entry.x, entry.y, entry.z
            )
            return false
        end
        ISWorldObjectContextMenu.transferIfNeeded(player, roll)
        ISWorldObjectContextMenu.transferIfNeeded(player, brush)
        ISWorldObjectContextMenu.transferIfNeeded(player, paste)
        ISWorldObjectContextMenu.transferIfNeeded(player, scissors)
    end
    Log:info("Queued wallpaper action for %s at %d,%d,%d", entry.buildableId, entry.x, entry.y, entry.z)
    ISTimedActionQueue.add(KBWFinishAction:new(
        player, "wallpaper", wall, sprite, roll, nil, nil, nil, entry.finish, true
    ))
    return true
end

local function step(entry)
    local now = getTimestampMs()
    if now > entry.deadline then
        local square = getCell():getGridSquare(entry.x, entry.y, entry.z)
        local total, matching = 0, 0
        if square then
            total = square:getSpecialObjects():size()
            for i = 0, total - 1 do
                if matchesEntry(square:getSpecialObjects():get(i), entry) then matching = matching + 1 end
            end
        end
        Log:warning(
            "Timed out applying selected finish to %s at %d,%d,%d in phase %s"
            .. " (%d object(s) on the tile, %d of this buildable)",
            entry.buildableId, entry.x, entry.y, entry.z, tostring(entry.phase), total, matching
        )
        return false
    end
    local wall = findBuiltWall(entry, entry.phase == "built")
    if entry.phase == "built" then
        if not wall then return true end
        entry.wall = wall
        if entry.finish.plaster == false then
            if entry.finish.paintType then
                queuePaint(entry, wall)
            elseif entry.finish.wallpaperType then
                queueWallpaper(entry, wall)
            end
            return false
        end
        if not queuePlaster(entry, wall) then return false end
        -- The colour goes into the same queue, right behind the plaster.
        -- ISTimedActionQueue runs them in order, KBWFinishAction resolves its
        -- sprite at completion against whatever the wall is wearing by then,
        -- and the paint action's own isValid refuses to paint a wall that was
        -- not plastered - so the order is enforced by the actions themselves.
        -- Waiting for the player to go idle instead meant that a player who
        -- kept building never became idle, and the colour was dropped when the
        -- entry timed out thirty seconds later.
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
    Log:info(
        "Finish queued for %s at %d,%d,%d north=%s plaster=%s paint=%s wallpaper=%s",
        tostring(buildableId), x, y, z, tostring(north == true),
        tostring(finish.plaster), tostring(finish.paintType), tostring(finish.wallpaperType)
    )
    if #pending == 0 then Events.OnTick.Add(onTick) end
    pending[#pending + 1] = {
        player = player,
        buildableId = buildableId,
        -- taken now, before the wall exists: see wallsAlreadyOnTile
        existing = wallsAlreadyOnTile(buildableId, x, y, z),
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
