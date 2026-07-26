local WallFinishes = require("KnoxBuildworks/Validation/WallFinishes")
local KBWFinishAction = require("KnoxBuildworks/TimedActions/KBWFinishAction")

local WallFinishCursor = {}

local function buildCheatActive(character)
    return (character and character.isBuildCheat and character:isBuildCheat())
        or (ISBuildMenu and ISBuildMenu.cheat == true)
end

local function predicateNotBroken(item)
    if not item then return false end
    if item.isBroken and item:isBroken() then return false end
    if item.isDestroyed and item:isDestroyed() then return false end
    return true
end

local function firstType(inventory, itemType)
    if not inventory or not itemType then return nil end
    local item = inventory:getFirstTypeRecurse(itemType)
    if item then return item end
    local value = tostring(itemType)
    if not string.find(value, ".", 1, true) then
        return inventory:getFirstTypeRecurse("Base." .. value)
    end
    return nil
end

local function isKnoxObject(object)
    local data = object and object.getModData and object:getModData() or nil
    return data and data.KBW and data.KBW.buildableId ~= nil
end

local function defineClass()
    if KBWWallFinishCursor or not ISPaintCursor then return end

    ---@class KBWWallFinishCursor: ISPaintCursor
    KBWWallFinishCursor = ISPaintCursor:derive("KBWWallFinishCursor")

    function KBWWallFinishCursor:hasItems()
        if self.action ~= "paintThump" then return ISPaintCursor.hasItems(self) end
        if buildCheatActive(self.character) then return true end
        local inventory = self.character and self.character:getInventory() or nil
        if not inventory then return false end
        return inventory:getFirstTagEvalRecurse(ItemTag.PAINTBRUSH, predicateNotBroken) ~= nil
            and firstType(inventory, self.args and self.args.paintType) ~= nil
    end

    function KBWWallFinishCursor:knoxPaintSprite(object)
        if self.action ~= "paintThump" or not isKnoxObject(object) then return nil end
        local finish = self.kbwFinish
        if not finish or not finish.paintType then return nil end
        local valid = WallFinishes.canApplyToObject("paint", finish, object, false)
        if not valid then return nil end
        local wallType = WallFinishes.prepareObject(object)
        local objectSprite = object:getSprite()
        local baseSprite = objectSprite and objectSprite:getName() or nil
        return WallFinishes.spriteForWallType(
            "paint", finish, WallFinishes.objectNorth(object), wallType, baseSprite
        )
    end

    function KBWWallFinishCursor:canPaint(object)
        if isKnoxObject(object) then
            if not object:getSquare() or not object:getSprite() then return false end
            if not object:getSquare():isCouldSee(self.player) or not self:hasItems() then return false end
            if self:knoxPaintSprite(object) then return true end
            local wallType = WallFinishes.prepareObject(object)
            if not (Painting and Painting[wallType]) then return false end
        end
        return ISPaintCursor.canPaint(self, object)
    end

    function KBWWallFinishCursor:create(x, y, z, north, sprite)
        local object = self:getObjectList()[self.objectIndex]
        local resolvedSprite = object and self:knoxPaintSprite(object) or nil
        if not resolvedSprite then
            if isKnoxObject(object) then
                local wallType = WallFinishes.prepareObject(object)
                if not (Painting and Painting[wallType]) then return end
            end
            ISPaintCursor.create(self, x, y, z, north, sprite)
            return
        end
        local player = self.character
        local inventory = player:getInventory()
        local paint = nil
        if not buildCheatActive(player) then
            local brush = inventory:getFirstTagEvalRecurse(ItemTag.PAINTBRUSH, predicateNotBroken)
            paint = firstType(inventory, self.kbwFinish.paintType)
            if not brush or not paint then return end
            ISWorldObjectContextMenu.transferIfNeeded(player, brush)
            ISWorldObjectContextMenu.transferIfNeeded(player, paint)
        end
        ISTimedActionQueue.add(
            KBWFinishAction:new(player, "paint", object, resolvedSprite, paint, nil, nil, nil, self.kbwFinish)
        )
    end

    ---@param character IsoPlayer
    ---@param action string
    ---@param args table
    ---@param finish KBW.WallFinish
    ---@return KBWWallFinishCursor
    function KBWWallFinishCursor:new(character, action, args, finish)
        local o = ISPaintCursor.new(self, character, action, args)
        o.kbwFinish = finish
        return o
    end
end

Events.OnGameStart.Add(defineClass)

---@param character IsoPlayer
---@param action string
---@param args table
---@param finish KBW.WallFinish
---@return KBWWallFinishCursor|nil
function WallFinishCursor.new(character, action, args, finish)
    defineClass()
    if not KBWWallFinishCursor then return nil end
    return KBWWallFinishCursor:new(character, action, args, finish)
end

return WallFinishCursor
