---KBWFinishAction provides the Knox Buildworks timed-action layer.
require "TimedActions/ISBaseTimedAction"

-- One timed action for all three wall finish steps. The completion bodies
-- mirror the vanilla actions exactly (ISPlasterAction / ISPaintAction /
-- ISWallpaperAction), but the sprite is resolved by Knox's surface mapping
-- beforehand, so custom tilepack walls and objects use their own bases. Unlike
-- vanilla plastering, every step plays the Paint animation and shows the
-- relevant work tool in hand.
--
-- mode: "plaster" | "paint" | "wallpaper"
-- sprite: the resolved target sprite name for the wall's facing
-- item: the consumed item (plaster bucket / paint can / wallpaper roll)
-- tool: optional kept tool for the action (plastering trowel)
---@class KBWFinishAction: ISBaseTimedAction
KBWFinishAction = ISBaseTimedAction:derive("KBWFinishAction")

local function cheat(character)
    return character.isBuildCheat and character:isBuildCheat()
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

local function skillForTool(character, tool)
    local level = 0
    if Perks and Perks.Woodwork and character and character.getPerkLevel then
        level = character:getPerkLevel(Perks.Woodwork) or 0
    end
    if tool and tool.getMaintenanceMod then level = level + (tool:getMaintenanceMod(character) or 0) end
    return level
end

local function maybeDegradeTrowel(character, tool)
    if not tool or not tool.damageCheck then return end
    tool:damageCheck(skillForTool(character, tool), 6.0, false)
end

-- Only build-with-finish actions opt into the administrative wall policy.
-- Resolve the policy from the completed object's authoritative Knox metadata
-- so a client cannot make unrelated paintable objects free by setting a flag.
local function finishRequirementsWaived(action)
    if not action or action.useWallBuildRules ~= true or not action.thumpable then return false end
    local data = action.thumpable:getModData()
    data = data and data.KBW or nil
    if not data or not data.buildableId or not data.stageId then return false end
    local Registry = require("KnoxBuildworks/Definitions/Registry")
    local BuildableRules = require("KnoxBuildworks/Admin/BuildableRules")
    local definition = Registry:get(tostring(data.buildableId))
    local stage = definition and Registry:getStage(definition, tostring(data.stageId)) or nil
    if not definition then return false end
    -- Material/variant-specific stages may not exist on the base registry
    -- definition. The wall policy is buildable-wide, so a base wall placement
    -- remains sufficient; stage-only wall placements stay conservative.
    if not stage and not BuildableRules.isWallBuildable(definition, nil) then return false end
    return not BuildableRules.wallFinishRequirement(definition, stage, tostring(action.mode or ""))
end

function KBWFinishAction:isValid()
    if not self.thumpable or not self.thumpable:getSquare() then return false end
    if self.blueprintId then
        local Blueprints = require("KnoxBuildworks/Planning/Blueprints")
        local blueprint = Blueprints.get(self.character, self.blueprintId)
        local placement = blueprint and Blueprints.getPlacement(blueprint, self.placementId) or nil
        if not blueprint or not placement or not Blueprints.canBuild(self.character, blueprint) then return false end
        local square = self.thumpable:getSquare()
        if square:getX() ~= tonumber(placement.x) or square:getY() ~= tonumber(placement.y)
            or square:getZ() ~= tonumber(placement.z) then
            return false
        end
    end
    if self.finish then
        local WallFinishes = require("KnoxBuildworks/Validation/WallFinishes")
        -- A colour that is part of a "plaster + colour" finish has its own
        -- plaster action queued directly in front of it. The engine polls this
        -- while the action is still waiting, so judging the wall as it stands
        -- refuses a colour that is about to become perfectly valid.
        local plasterComing = self.mode ~= "plaster" and self.finish.plaster == true
        local validTarget, reason = WallFinishes.canApplyToObject(
            self.mode, self.finish, self.thumpable, plasterComing
        )
        if not validTarget then
            -- A timed action that answers false here is dropped in silence, so
            -- say why once rather than leaving an unfinished wall unexplained.
            if not self.reportedInvalid then
                self.reportedInvalid = true
                local Log = require("KnoxBuildworks/Log")
                local square = self.thumpable:getSquare()
                Log:warning(
                    "%s action refused on %s at %d,%d,%d: %s", tostring(self.mode),
                    tostring(self.thumpable:getSprite() and self.thumpable:getSprite():getName()),
                    square and square:getX() or -1, square and square:getY() or -1,
                    square and square:getZ() or -1, tostring(reason)
                )
            end
            return false
        end
    end
    if finishRequirementsWaived(self) then return true end
    if cheat(self.character) then return true end
    local inventory = self.character:getInventory()
    if self.mode == "plaster" then
        local hasBucket = self.item ~= nil
            or inventory:getFirstTagEvalRecurse(ItemTag.PLASTER_BUCKET, predicateEnoughDrain) ~= nil
        local hasTrowel = self.tool ~= nil
            or inventory:getFirstTagEvalRecurse(ItemTag.PLASTER_TROWEL, predicateNotBroken) ~= nil
        return hasBucket and hasTrowel
    end
    if not self.item then return false end
    if inventory:getFirstTagEvalRecurse(ItemTag.PAINTBRUSH, predicateNotBroken) == nil then return false end
    if self.mode == "wallpaper" then
        if inventory:getFirstTagEvalRecurse(ItemTag.WALLPAPER_PASTE, predicateEnoughDrain) == nil then return false end
        if inventory:getFirstTagEvalRecurse(ItemTag.SCISSORS, predicateNotBroken) == nil then return false end
    end
    return true
end

function KBWFinishAction:waitToStart()
    self.character:faceThisObject(self.thumpable)
    return self.character:shouldBeTurning()
end

function KBWFinishAction:update()
    self.character:faceThisObject(self.thumpable)
    self.character:setMetabolicTarget(self.mode == "plaster" and Metabolics.MediumWork or Metabolics.LightWork)
end

function KBWFinishAction:start()
    self:setActionAnim(CharacterActionAnims.Paint)
    if self.mode == "plaster" then
        self:setOverrideHandModels(self.tool or "PlasterTrowel", nil)
        self.sound = self.character:playSound("Plastering")
    else
        self:setOverrideHandModels("PaintBrush", nil)
        self.sound = self.character:playSound("Painting")
    end
    self.character:faceThisObject(self.thumpable)
end

function KBWFinishAction:stop()
    if self.sound then self.character:stopOrTriggerSound(self.sound) end
    ISBaseTimedAction.stop(self)
end

function KBWFinishAction:perform()
    if self.sound then self.character:stopOrTriggerSound(self.sound) end
    if self.mode ~= "plaster" and self.thumpable.cleanWallBlood then
        self.thumpable:cleanWallBlood()
    end
    ISBaseTimedAction.perform(self)
end

local function consumeAllowed(character)
    if isServer() then return true end
    return not cheat(character)
end

function KBWFinishAction:complete()
    if not self.thumpable then return false end
    do
        local Log = require("KnoxBuildworks/Log")
        local square = self.thumpable:getSquare()
        Log:info(
            "Applying %s to %s at %d,%d,%d", tostring(self.mode),
            tostring(self.thumpable:getSprite() and self.thumpable:getSprite():getName()),
            square and square:getX() or -1, square and square:getY() or -1,
            square and square:getZ() or -1
        )
    end
    local WallFinishes = require("KnoxBuildworks/Validation/WallFinishes")
    local requirementsWaived = finishRequirementsWaived(self)
    -- Resolve against the object that actually exists at completion time. This
    -- preserves door/window/corner wall types and the final N/W face even when
    -- the placement cursor snapped or replaced a previous construction stage.
    local wallType = WallFinishes.objectWallType(self.thumpable)
    local north = WallFinishes.objectNorth(self.thumpable)
    local currentSprite = self.thumpable:getSprite()
    local baseSprite = currentSprite and currentSprite:getName() or nil
    local resolvedSprite = WallFinishes.spriteForWallType(
        self.mode, self.finish, north, wallType, baseSprite
    ) or self.sprite
    if not resolvedSprite then return false end
    if self.mode == "plaster" then
        self.thumpable:setSpriteFromName(resolvedSprite)
        -- setPaintable and setCanBePlastered belong to IsoThumpable. A passable
        -- wall piece - a pillar, a door or window frame - is placed as a plain
        -- world prop and has neither, so calling them threw and left the rest
        -- of this undone. The prop carries its plastered state in its sprite,
        -- which is what the queue and the validation read anyway.
        -- Only where vanilla could actually handle the result. A plastered
        -- corner is still WallNW-only, so marking it paintable would put it
        -- back in front of the menu that cannot classify it.
        if self.thumpable.setPaintable and WallFinishes.vanillaPaintable(resolvedSprite) then
            self.thumpable:setPaintable(true)
        end
        if self.thumpable.setCanBePlastered then self.thumpable:setCanBePlastered(false) end
        self.thumpable:transmitUpdatedSpriteToClients()
        self.thumpable:sendObjectChange(IsoObjectChange.PAINTABLE)
        local square = self.thumpable:getSquare()
        if square then square:RecalcAllWithNeighbours(true) end
        if not requirementsWaived and consumeAllowed(self.character) and self.item then
            self.item:UseAndSync()
            maybeDegradeTrowel(self.character, self.tool)
        end
        return true
    end
    self.thumpable:setSpriteFromName(resolvedSprite)
    self.thumpable:transmitUpdatedSpriteToClients()
    if self.mode == "paint" then
        local color = WallFinishes.customColorFor(wallType, self.finish)
        if color then
            self.thumpable:setCustomColor(ColorInfo.new(color.r, color.g, color.b, color.a))
            self.thumpable:transmitCustomColorToClients()
        end
    end
    if not requirementsWaived and consumeAllowed(self.character) then
        -- A blended paint spends the share of the ratio each colour carries, so
        -- it draws from its own list rather than taking one use off the first can.
        if self.paintDraws then
            for drawIndex = 1, #self.paintDraws do
                local draw = self.paintDraws[drawIndex]
                for _useIndex = 1, (draw.uses or 1) do
                    if draw.item and (not draw.item.getCurrentUses or draw.item:getCurrentUses() > 0) then
                        draw.item:UseAndSync()
                    end
                end
            end
        elseif self.item then
            self.item:UseAndSync()
        end
        if self.mode == "wallpaper" then
            local paste = self.character:getInventory():getFirstTagRecurse(ItemTag.WALLPAPER_PASTE)
            if paste then paste:UseAndSync() end
        end
    end
    local square = self.thumpable:getSquare()
    if square then square:RecalcAllWithNeighbours(true) end
    return true
end

function KBWFinishAction:getDuration()
    if self.character:isTimedActionInstant() or cheat(self.character) then return 1 end
    return 100
end

---@param character IsoPlayer
---@param mode string|nil
---@param blueprintId string
---@param placementId string
---@param finish KBW.WallFinish|nil
---@param useWallBuildRules boolean|nil
---@return KBWFinishAction
---@param paintDraws {item: InventoryItem, uses: number}[]|nil cans a blended paint spends
function KBWFinishAction:new(
    character, mode, thumpable, sprite, item, tool, blueprintId, placementId, finish, useWallBuildRules,
    paintDraws
)
    local o = ISBaseTimedAction.new(self, character)
    o.character = character
    o.mode = mode
    o.thumpable = thumpable
    o.sprite = sprite
    o.item = item
    o.paintDraws = paintDraws
    o.tool = tool
    o.blueprintId = blueprintId
    o.placementId = placementId
    o.finish = finish
    o.useWallBuildRules = useWallBuildRules == true
    o.maxTime = o:getDuration()
    o.caloriesModifier = mode == "plaster" and 8 or 4
    return o
end

return KBWFinishAction
