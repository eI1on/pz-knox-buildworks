---FinishActions provides the Knox Buildworks construction validation layer.
local WallFinishes = require("KnoxBuildworks/Validation/WallFinishes")
local EntityCompat = require("KnoxBuildworks/Entity/EntityCompat")

---@class KBW.FinishActionsModule
---@type KBW.FinishActionsModule
local FinishActions = {}

local paintTypes = {
    PaintBlue = true,
    PaintGreen = true,
    PaintLightBrown = true,
    PaintLightBlue = true,
    PaintBrown = true,
    PaintOrange = true,
    PaintCyan = true,
    PaintPink = true,
    PaintGrey = true,
    PaintTurquoise = true,
    PaintPurple = true,
    PaintYellow = true,
    PaintWhite = true,
    PaintRed = true,
    PaintBlack = true
}

local wallpaperTypes = {
    Wallpaper_BeigeStripe = true,
    Wallpaper_BlackFloral = true,
    Wallpaper_BlueStripe = true,
    Wallpaper_GreenDiamond = true,
    Wallpaper_GreenFloral = true,
    Wallpaper_PinkChevron = true,
    Wallpaper_PinkFloral = true
}

local signTypes = { [32] = true, [33] = true, [34] = true, [35] = true, [36] = true }

local function wallConfig(definition, stage)
    local compat = EntityCompat.metadata(stage)
    return compat.wallCoveringConfig or {}
end

local function hasItemType(player, itemType, requireItems)
    if not requireItems then return true end
    if not itemType then return false end
    if player and player.isBuildCheat and player:isBuildCheat() then return true end
    local inventory = player and player:getInventory()
    if not inventory then return false end
    if inventory:getFirstTypeRecurse(itemType) ~= nil then return true end
    local value = tostring(itemType)
    if not string.find(value, ".", 1, true) then
        return inventory:getFirstTypeRecurse("Base." .. value) ~= nil
    end
    return false
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

local function hasTag(player, tag, requireItems, predicate)
    if not requireItems then return true end
    if player and player.isBuildCheat and player:isBuildCheat() then return true end
    local inventory = player and player:getInventory()
    if not inventory or not tag then return false end
    if predicate then return inventory:getFirstTagEvalRecurse(tag, predicate) ~= nil end
    return inventory:getFirstTagRecurse(tag) ~= nil
end

---@param player IsoPlayer
---@param definition KBW.BuildableDefinition
---@param stage KBW.BuildStage
---@param finish KBW.WallFinish|nil
function FinishActions.validate(player, definition, stage, finish, requireItems)
    if not definition or not stage then return false, "missing definition or stage" end
    local placement = definition.placement or {}
    if placement.kind ~= "wallCovering" then
        -- Wall finishes: build the wall already plastered (and optionally
        -- painted/papered). Validated against the wall type's sprite mapping
        -- so custom tilepack walls only accept the finishes they define.
        if WallFinishes.isWallFinish(finish) then
            if finish.plaster ~= false then
                if not WallFinishes.isPlasterable(definition, stage) then
                    return false, "stage cannot be plastered"
                end
                if not WallFinishes.spriteFor("plaster", finish, false, definition, stage) then
                    return false, "wall has no plaster mapping"
                end
            end
            if finish.paintType and not WallFinishes.spriteFor("paint", finish, false, definition, stage) then
                return false, "paint not available for this wall"
            end
            if finish.wallpaperType and not WallFinishes.spriteFor("wallpaper", finish, false, definition, stage) then
                return false, "wallpaper not available for this wall"
            end
            if requireItems then return WallFinishes.validateItems(player, finish) end
            return true
        end
        return true
    end
    local wall = wallConfig(definition, stage)
    local action = wall.type or placement.wallCoveringType
    if not action then return false, "missing wall covering action" end
    if action == "plaster" then
        if not hasTag(player, ItemTag.PLASTER_TROWEL, requireItems, predicateNotBroken) then
            return false, "missing plastering trowel"
        end
        if not hasTag(player, ItemTag.PLASTER_BUCKET, requireItems, predicateEnoughDrain) then
            return false, "missing plaster bucket"
        end
        return true
    end
    if type(finish) ~= "table" then return false, "missing finish selection" end
    if finish.actionType and finish.actionType ~= action then return false, "finish action mismatch" end
    if action == "paintThump" then
        if not finish.paintType or tostring(finish.paintType) == "" then return false, "invalid paint color" end
        if not hasTag(player, ItemTag.PAINTBRUSH, requireItems, predicateNotBroken) then
            return false, "missing paintbrush"
        end
        if not hasItemType(player, finish.paintType, requireItems) then return false, "missing selected paint" end
        return true
    end
    if action == "paintSign" then
        if not paintTypes[finish.paintType] then return false, "invalid sign paint color" end
        if not signTypes[tonumber(finish.sign)] then return false, "invalid sign variant" end
        if not hasTag(player, ItemTag.PAINTBRUSH, requireItems, predicateNotBroken) then
            return false, "missing paintbrush"
        end
        if not hasItemType(player, finish.paintType, requireItems) then return false, "missing selected paint" end
        return true
    end
    if action == "wallpaper" then
        if not finish.wallpaperType or tostring(finish.wallpaperType) == "" then return false, "invalid wallpaper" end
        if not hasTag(player, ItemTag.PAINTBRUSH, requireItems, predicateNotBroken) then
            return false, "missing paintbrush"
        end
        if not hasItemType(player, finish.wallpaperType, requireItems) then
            return false, "missing selected wallpaper"
        end
        if not hasTag(player, ItemTag.WALLPAPER_PASTE, requireItems, predicateEnoughDrain) then
            return false, "missing wallpaper paste"
        end
        if not hasTag(player, ItemTag.SCISSORS, requireItems, predicateNotBroken) then
            return false, "missing scissors"
        end
        return true
    end
    return false, "unknown wall covering action"
end

return FinishActions
