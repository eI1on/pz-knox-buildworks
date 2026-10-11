---RoomCursor provides the Knox Buildworks blueprint planning layer.
local Blueprints = require("KnoxBuildworks/Planning/Blueprints")
local GhostRenderer = require("KnoxBuildworks/Planning/GhostRenderer")
local PlanCursor = require("KnoxBuildworks/Planning/PlanCursor")
---@class KBW.RoomCursorModule
---@type KBW.RoomCursorModule
local RoomCursor = {}

local function floorInt(value)
    return math.floor(tonumber(value) or 0)
end

-- ISBuildingObject only exists once the server Lua directory loads at game
-- start, after client files, so the class is created on OnGameStart.
local function defineClass()
    KBWRoomCursor = ISBuildingObject:derive("KBWRoomCursor")

    function KBWRoomCursor:new(player, blueprintId, roomTemplate, onRoomAdded)
        local o = {}
        setmetatable(o, self)
        self.__index = self
        o:init()
        o.character = player
        o.player = player:getPlayerNum()
        o.roomTemplate = roomTemplate or {}
        o.onRoomAdded = onRoomAdded
        o.skipBuildAction = true
        o.dragNilAfterPlace = false
        o.canBeAlwaysPlaced = false
        local blueprint = Blueprints.get(player, blueprintId) or Blueprints.activeOrCreate(player)
        o.blueprintId = blueprint.id
        o.planZ = floorInt(blueprint.level ~= nil and blueprint.level or player:getZ())
        local editRoomId = o.roomTemplate.extendRoomId or o.roomTemplate.shrinkRoomId
        if editRoomId then
            local target = Blueprints.getRoom(blueprint, editRoomId)
            if target then o.planZ = floorInt(target.z or o.planZ) end
        end
        return o
    end

    function KBWRoomCursor:walkTo(x, y, z)
        return true
    end

    function KBWRoomCursor:haveMaterial(square)
        return true
    end

    function KBWRoomCursor:rotateMouse(x, y)
    end

    function KBWRoomCursor:rotateKey(key)
    end

    function KBWRoomCursor:getSprite()
        return nil
    end

    function KBWRoomCursor:isValid(square)
        return self.currentX ~= nil
    end

    function KBWRoomCursor:render(x, y, z, square)
        local blueprint = Blueprints.get(self.character, self.blueprintId)
        if blueprint and blueprint.level ~= nil then
            local editRoomId = self.roomTemplate.extendRoomId or self.roomTemplate.shrinkRoomId
            local target = editRoomId and Blueprints.getRoom(blueprint, editRoomId) or nil
            self.planZ = floorInt(target and target.z or blueprint.level)
        end
        self.currentX, self.currentY = PlanCursor.pickTileAt(self.player, self.planZ)
        if self.isLeftDown then
            if self.anchorX == nil then
                self.anchorX, self.anchorY = self.currentX, self.currentY
            end
        else
            if not self.build then
                self.anchorX, self.anchorY = nil, nil
            end
        end
        self.canBeBuild = true
        local color = self.roomTemplate.color or { r = 0.20, g = 0.62, b = 1.00, a = 0.26 }
        -- Cutting shows the room being edited and the area to clear in red.
        if self.roomTemplate.shrinkRoomId then
            color = GhostRenderer.CONFLICT_COLOR
            local target = blueprint and Blueprints.getRoom(blueprint, self.roomTemplate.shrinkRoomId) or nil
            if target then GhostRenderer.renderRoom(target, self.planZ, nil, target.id, self.player) end
        end
        if self.anchorX then
            GhostRenderer.renderRoomRect(
                self.anchorX, self.anchorY, self.currentX, self.currentY, self.planZ, color, self.player
            )
        else
            GhostRenderer.renderRoomRect(
                self.currentX, self.currentY, self.currentX, self.currentY, self.planZ, color, self.player
            )
        end
    end

    function KBWRoomCursor:create(x, y, z, north, sprite)
        local anchorX = self.anchorX or self.currentX
        local anchorY = self.anchorY or self.currentY
        if anchorX == nil or self.currentX == nil then return end
        local minX, maxX = math.min(anchorX, self.currentX), math.max(anchorX, self.currentX)
        local minY, maxY = math.min(anchorY, self.currentY), math.max(anchorY, self.currentY)
        local rectangle = {x = minX, y = minY, w = maxX - minX + 1, h = maxY - minY + 1}
        local room, reason
        if self.roomTemplate.shrinkRoomId then
            local blueprint = Blueprints.get(self.character, self.blueprintId)
            local target = Blueprints.getRoom(blueprint, self.roomTemplate.shrinkRoomId)
            if target and floorInt(target.z or self.planZ) == self.planZ then
                local success, result = Blueprints.shrinkRoom(self.character, self.blueprintId, target.id, rectangle)
                self.anchorX, self.anchorY = nil, nil
                if success then
                    if self.onRoomAdded then self.onRoomAdded(target) end
                    if HaloTextHelper and HaloTextHelper.addText then
                        HaloTextHelper.addText(self.character, getText(result == "removed"
                            and "IGUI_KBW_RoomRemovedByCut" or "IGUI_KBW_RoomCut"))
                    end
                    -- The whole room is gone: nothing left to cut.
                    if result == "removed" then getCell():setDrag(nil, self.player) end
                elseif HaloTextHelper and HaloTextHelper.addBadText then
                    HaloTextHelper.addBadText(self.character, Blueprints.planErrorText(result, blueprint))
                end
                return
            end
            reason = "invalid_room"
        elseif self.roomTemplate.extendRoomId then
            local blueprint = Blueprints.get(self.character, self.blueprintId)
            local target = Blueprints.getRoom(blueprint, self.roomTemplate.extendRoomId)
            if target and floorInt(target.z or self.planZ) == self.planZ then
                local success
                success, reason = Blueprints.extendRoom(self.character, self.blueprintId, target.id, rectangle)
                if success then room = target end
            else
                reason = "invalid_room"
            end
        else
            room, reason = Blueprints.addRoom(self.character, self.blueprintId, {
                name = self.roomTemplate.name,
                type = self.roomTemplate.type,
                color = self.roomTemplate.color,
                x = minX, y = minY, z = self.planZ, w = rectangle.w, h = rectangle.h
            })
        end
        self.anchorX, self.anchorY = nil, nil
        if room and self.onRoomAdded then self.onRoomAdded(room) end
        if room and HaloTextHelper and HaloTextHelper.addText then
            HaloTextHelper.addText(self.character, getText("IGUI_KBW_RoomPlaced"))
        elseif not room and HaloTextHelper and HaloTextHelper.addBadText then
            HaloTextHelper.addBadText(
                self.character, Blueprints.planErrorText(reason, Blueprints.get(self.character, self.blueprintId))
            )
        end
    end
end

Events.OnGameStart.Add(defineClass)

---@param player IsoPlayer
---@param blueprintId string
---@param onRoomAdded function|nil
function RoomCursor.new(player, blueprintId, roomTemplate, onRoomAdded)
    return KBWRoomCursor:new(player, blueprintId, roomTemplate, onRoomAdded)
end

return RoomCursor
