---@diagnostic disable: undefined-global
---CaptureCursor picks what BuildingCapture turns into a blueprint.
---
---Hovering a tile inside a building outlines the whole building; a click
---captures it on every level. Dragging instead captures the dragged
---rectangle from the cursor level upward - for player bases, fences, yards or
---anything that is not a map building.
local GhostRenderer = require("KnoxBuildworks/Planning/GhostRenderer")
local PlanCursor = require("KnoxBuildworks/Planning/PlanCursor")
local BuildingCapture = require("KnoxBuildworks/Planning/BuildingCapture")

local CaptureCursor = {}
CaptureCursor.COLOR = { r = 1.00, g = 0.76, b = 0.10, a = 0.30 }
CaptureCursor.BORDER = { r = 1.00, g = 0.76, b = 0.10, a = 0.85 }

local function floorInt(value)
    return math.floor(tonumber(value) or 0)
end

local function defineClass()
    KBWCaptureCursor = ISBuildingObject:derive("KBWCaptureCursor")

    function KBWCaptureCursor:new(player, onCapture)
        local o = {}
        setmetatable(o, self)
        self.__index = self
        o:init()
        o.character = player
        o.player = player:getPlayerNum()
        o.onCapture = onCapture
        o.skipBuildAction = true
        o.dragNilAfterPlace = true
        o.planZ = floorInt(player:getZ())
        return o
    end

    function KBWCaptureCursor:walkTo(x, y, z) return true end
    function KBWCaptureCursor:haveMaterial(square) return true end
    function KBWCaptureCursor:rotateMouse(x, y) end
    function KBWCaptureCursor:rotateKey(key) end
    function KBWCaptureCursor:getSprite() return nil end

    function KBWCaptureCursor:isValid(square)
        return self.currentX ~= nil and not BuildingCapture.isRunning()
    end

    function KBWCaptureCursor:dragging()
        return self.anchorX ~= nil and (self.anchorX ~= self.currentX or self.anchorY ~= self.currentY)
    end

    function KBWCaptureCursor:removeTooltip()
        if self.tooltip then
            self.tooltip:setVisible(false)
            self.tooltip:removeFromUIManager()
            self.tooltip = nil
        end
    end

    function KBWCaptureCursor:deactivate()
        self:removeTooltip()
    end

    function KBWCaptureCursor:updateTooltip(text)
        if not KBWBuildPlanTooltip then return end
        if not self.tooltip then
            self.tooltip = KBWBuildPlanTooltip:new()
            self.tooltip:initialise()
            self.tooltip:addToUIManager()
        end
        local Theme = require("KnoxBuildworks/UI/Theme")
        self.tooltip:setLines({ { text = text, color = Theme.text } })
        local mouseX, mouseY = getMouseX() + 24, getMouseY() + 12
        local screenW = getPlayerScreenLeft(self.player) + getPlayerScreenWidth(self.player)
        local screenH = getPlayerScreenTop(self.player) + getPlayerScreenHeight(self.player)
        if mouseX + self.tooltip.width > screenW then mouseX = screenW - self.tooltip.width - 4 end
        if mouseY + self.tooltip.height > screenH then mouseY = mouseY - self.tooltip.height - 28 end
        self.tooltip:setX(mouseX)
        self.tooltip:setY(mouseY)
        self.tooltip:setVisible(true)
        self.tooltip:bringToTop()
    end

    -- The building under the cursor, cached per tile (the BuildingDef lookup
    -- is cheap but the outline is drawn every frame).
    function KBWCaptureCursor:hoveredArea()
        local key = tostring(self.currentX) .. "|" .. tostring(self.currentY) .. "|" .. self.planZ
        if self.hoverKey ~= key then
            self.hoverKey = key
            local square = self.currentX and getCell():getGridSquare(self.currentX, self.currentY, self.planZ) or nil
            self.hover = BuildingCapture.buildingArea(square)
        end
        return self.hover
    end

    function KBWCaptureCursor:render(x, y, z, square)
        self.planZ = floorInt(self.character:getZ())
        self.currentX, self.currentY = PlanCursor.pickTileAt(self.player, self.planZ)
        if self.isLeftDown then
            if self.anchorX == nil then self.anchorX, self.anchorY = self.currentX, self.currentY end
        elseif not self.build then
            self.anchorX, self.anchorY = nil, nil
        end
        self.canBeBuild = self:isValid(square)
        if self.currentX == nil then return self:removeTooltip() end
        if BuildingCapture.isRunning() then
            return self:updateTooltip(getText("IGUI_KBW_CaptureBusy"))
        end
        if self:dragging() then
            GhostRenderer.renderRect(self.anchorX, self.anchorY, self.currentX, self.currentY, self.planZ,
                CaptureCursor.COLOR, self.player)
            return self:updateTooltip(getText("IGUI_KBW_CaptureHoverDrag",
                tostring(math.abs(self.currentX - self.anchorX) + 1),
                tostring(math.abs(self.currentY - self.anchorY) + 1), tostring(self.planZ)))
        end
        local area = self:hoveredArea()
        if area then
            GhostRenderer.renderRectBorder(area.x1, area.y1, area.x2, area.y2, self.planZ, CaptureCursor.BORDER,
                self.player)
            return self:updateTooltip(getText("IGUI_KBW_CaptureHoverBuilding",
                tostring(area.x2 - area.x1 + 1), tostring(area.y2 - area.y1 + 1),
                tostring(area.zMin), tostring(area.zMax)))
        end
        GhostRenderer.renderTileHighlight(self.currentX, self.currentY, self.planZ, CaptureCursor.COLOR, 0.45,
            self.player)
        self:updateTooltip(getText("IGUI_KBW_CaptureHoverArea"))
    end

    function KBWCaptureCursor:create(x, y, z, north, sprite)
        if self.currentX == nil or BuildingCapture.isRunning() then return end
        local area
        if self:dragging() then
            area = BuildingCapture.rectArea(self.anchorX, self.anchorY, self.currentX, self.currentY, self.planZ)
        else
            area = self:hoveredArea()
                or BuildingCapture.rectArea(self.currentX, self.currentY, self.currentX, self.currentY, self.planZ)
        end
        self.anchorX, self.anchorY = nil, nil
        self:removeTooltip()
        if self.onCapture then self.onCapture(area) end
    end
end

Events.OnGameStart.Add(defineClass)

---@param player IsoPlayer
---@param onCapture function(area)
function CaptureCursor.new(player, onCapture)
    return KBWCaptureCursor:new(player, onCapture)
end

return CaptureCursor
