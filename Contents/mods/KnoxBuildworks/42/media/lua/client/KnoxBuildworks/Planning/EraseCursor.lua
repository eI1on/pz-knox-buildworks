---EraseCursor provides the Knox Buildworks blueprint planning layer.
local Blueprints = require("KnoxBuildworks/Planning/Blueprints")
local GhostRenderer = require("KnoxBuildworks/Planning/GhostRenderer")
local PlanCursor = require("KnoxBuildworks/Planning/PlanCursor")
local I18n = require("KnoxBuildworks/I18n")

---@class KBW.EraseCursorModule
---@type KBW.EraseCursorModule
local EraseCursor = {}

local function floorInt(value)
    return math.floor(tonumber(value) or 0)
end

-- Ghosts stacked on one tile (a floor, the wall on its edge, the table on
-- it) are listed bottom to top. The cursor starts on the top one, and the
-- Rotate key (R) steps down through the rest, wrapping round.
---@param count number pieces on the tile
---@param offset number how many times the key was pressed
---@return number index into the stack
function EraseCursor.pickIndex(count, offset)
    if count <= 0 then return 0 end
    return count - (offset % count)
end

local function targetName(target, mode)
    if mode == "rooms" then return target.name or getText("IGUI_KBW_RoomTypeGeneric") end
    local definition = Blueprints.resolvePlacement(target)
    return definition and I18n.definitionName(definition) or tostring(target.buildableId)
end

-- ISBuildingObject only exists once the server Lua directory loads at game
-- start, after client files, so the class is created on OnGameStart.
local function defineClass()
    KBWEraseCursor = ISBuildingObject:derive("KBWEraseCursor")

    function KBWEraseCursor:new(player, blueprintId, onErased, mode)
        local o = {}
        setmetatable(o, self)
        self.__index = self
        o:init()
        o.character = player
        o.player = player:getPlayerNum()
        o.onErased = onErased
        o.mode = mode == "rooms" and "rooms" or "placements"
        o.skipBuildAction = true
        o.dragNilAfterPlace = false
        local blueprint = Blueprints.get(player, blueprintId) or Blueprints.activeOrCreate(player)
        o.blueprintId = blueprint.id
        o.planZ = floorInt(blueprint.level ~= nil and blueprint.level or player:getZ())
        return o
    end

    function KBWEraseCursor:walkTo(x, y, z)
        return true
    end

    function KBWEraseCursor:haveMaterial(square)
        return true
    end

    function KBWEraseCursor:rotateMouse(x, y)
    end

    function KBWEraseCursor:rotateKey(key)
        if not getCore():isKey(KeybindId.ROTATE_BUILDING, key) then return end
        local stack = self.stack or {}
        if #stack < 2 then return end
        self.cycle = (self.cycle or 0) + 1
        local index = EraseCursor.pickIndex(#stack, self.cycle)
        self.target = stack[index]
        if HaloTextHelper and HaloTextHelper.addText then
            HaloTextHelper.addText(self.character, getText(
                "IGUI_KBW_EraseCycle", targetName(self.target, self.mode), #stack - index + 1, #stack
            ))
        end
    end

    function KBWEraseCursor:getSprite()
        return nil
    end

    ---Everything erasable on the tile, bottom to top.
    function KBWEraseCursor:stackAt(x, y)
        local blueprint = Blueprints.get(self.character, self.blueprintId)
        if not blueprint then return {} end
        if self.mode == "rooms" then return Blueprints.roomsAt(blueprint, x, y, self.planZ) end
        return Blueprints.placementsAt(blueprint, x, y, self.planZ)
    end

    function KBWEraseCursor:targetAt(x, y)
        local stack = self:stackAt(x, y)
        return stack[#stack]
    end

    function KBWEraseCursor:isValid(square)
        return self.target ~= nil
    end

    function KBWEraseCursor:render(x, y, z, square)
        local blueprint = Blueprints.get(self.character, self.blueprintId)
        if blueprint and blueprint.level ~= nil then self.planZ = floorInt(blueprint.level) end
        self.currentX, self.currentY = PlanCursor.pickTileAt(self.player, self.planZ)
        local key = self.currentX .. "|" .. self.currentY .. "|" .. self.planZ
        if self.targetKey ~= key then
            -- A new tile starts again from the top piece.
            self.targetKey = key
            self.stack = self:stackAt(self.currentX, self.currentY)
            self.cycle = 0
            self.target = self.stack[#self.stack]
        end
        self.canBeBuild = self.target ~= nil
        local color = self.target and GhostRenderer.CONFLICT_COLOR or GhostRenderer.PLAN_COLOR_DIM
        GhostRenderer.renderTileHighlight(self.currentX, self.currentY, self.planZ, color, 0.55, self.player)
        if self.target then
            if self.mode == "rooms" then
                GhostRenderer.renderRoom(self.target, self.planZ, nil, self.target.id, self.player)
            else
                GhostRenderer.renderPlacementLayerAll(self.target, GhostRenderer.CONFLICT_COLOR)
            end
        end
    end

    function KBWEraseCursor:create(x, y, z, north, sprite)
        if self.currentX == nil or not self.target then return end
        -- Erase the piece the cursor shows, which R may have moved off the top.
        local removed = nil
        if self.mode == "rooms" then
            if Blueprints.removeRoom(self.character, self.blueprintId, self.target.id) then removed = self.target end
        elseif Blueprints.removePlacement(self.character, self.blueprintId, self.target.id) then
            removed = self.target
        end
        self.targetKey = nil
        if removed then
            GhostRenderer.clearCache()
            if HaloTextHelper and HaloTextHelper.addText then
                HaloTextHelper.addText(self.character, getText("IGUI_KBW_PlanErased"))
            end
            if self.onErased then self.onErased(removed) end
        end
    end
end

Events.OnGameStart.Add(defineClass)

---@param player IsoPlayer
---@param blueprintId string
---@param onErased function|nil
---@param mode string|nil
function EraseCursor.new(player, blueprintId, onErased, mode)
    return KBWEraseCursor:new(player, blueprintId, onErased, mode)
end

return EraseCursor
