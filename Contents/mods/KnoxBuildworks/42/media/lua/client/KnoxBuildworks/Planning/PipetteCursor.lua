---@diagnostic disable: undefined-global
---PipetteCursor: pick a planned ghost or a built piece in the world and keep
---planning with exactly that piece - same recipe, stage, variant, material,
---direction and finish - without looking it up in the catalogue.
---
---Hover a tile: the piece that would be picked is outlined and named. Planned
---ghosts come first, then built pieces from the top of the square down
---(furniture, then walls, then floors). Press the rotate key (R) to step
---through everything on the tile, click to pick it.
local Blueprints = require("KnoxBuildworks/Planning/Blueprints")
local GhostRenderer = require("KnoxBuildworks/Planning/GhostRenderer")
local PlanCursor = require("KnoxBuildworks/Planning/PlanCursor")
local WorldPieceIndex = require("KnoxBuildworks/UI/WorldPieceIndex")

local PipetteCursor = {}
PipetteCursor.COLOR = { r = 0.40, g = 0.95, b = 0.60, a = 0.45 }

local function floorInt(value)
    return math.floor(tonumber(value) or 0)
end

local function definitionName(buildableId)
    local Registry = require("KnoxBuildworks/Definitions/Registry")
    local I18n = require("KnoxBuildworks/I18n")
    local definition = Registry:get(buildableId)
    return definition and I18n.definitionName(definition) or tostring(buildableId)
end

local function copyChoice(placement)
    return {
        buildableId = placement.buildableId, stageId = placement.stageId, variantId = placement.variantId,
        materialId = placement.materialId, direction = placement.direction, finish = placement.finish,
        x = placement.x, y = placement.y, z = placement.z
    }
end

---Everything that can be picked on one tile, in pick order.
function PipetteCursor.choicesAt(player, blueprint, x, y, z)
    local choices = {}
    local ghosts = blueprint and Blueprints.placementsAt(blueprint, x, y, z) or {}
    for index = #ghosts, 1, -1 do
        local ghost = ghosts[index]
        local definition, stage = Blueprints.resolvePlacement(ghost)
        local Visibility = require("KnoxBuildworks/UI/CatalogVisibility")
        if definition and stage and Visibility.definitionEnabled(definition)
            and Visibility.stagePasses(player, definition, stage, false) then
            choices[#choices + 1] = { source = "ghost", placement = copyChoice(ghost),
                label = definitionName(ghost.buildableId) }
        end
    end
    local square = getCell():getGridSquare(x, y, z)
    local objects = square and square:getObjects() or nil
    if objects then
        local seen = {}
        for index = objects:size() - 1, 0, -1 do
            local candidates = WorldPieceIndex.placementsForObject(player, objects:get(index))
            local candidate = candidates[1]
            if candidate then
                local key = candidate.buildableId .. "|" .. tostring(candidate.direction)
                if not seen[key] then
                    seen[key] = true
                    choices[#choices + 1] = { source = "world", placement = copyChoice(candidate),
                        label = candidate.label or definitionName(candidate.buildableId) }
                end
            end
        end
    end
    return choices
end

local function defineClass()
    KBWPipetteCursor = ISBuildingObject:derive("KBWPipetteCursor")

    function KBWPipetteCursor:new(player, blueprintId, onPicked)
        local o = {}
        setmetatable(o, self)
        self.__index = self
        o:init()
        o.character = player
        o.player = player:getPlayerNum()
        o.onPicked = onPicked
        o.skipBuildAction = true
        o.dragNilAfterPlace = false
        o.choiceIndex = 1
        local blueprint = Blueprints.get(player, blueprintId) or Blueprints.activeOrCreate(player)
        o.blueprintId = blueprint.id
        o.planZ = floorInt(blueprint.level ~= nil and blueprint.level or player:getZ())
        return o
    end

    function KBWPipetteCursor:walkTo(x, y, z) return true end
    function KBWPipetteCursor:haveMaterial(square) return true end
    function KBWPipetteCursor:rotateMouse(x, y) end
    function KBWPipetteCursor:getSprite() return nil end

    function KBWPipetteCursor:rotateKey(key)
        if getCore():isKey(KeybindId.ROTATE_BUILDING, key) and self.choices and #self.choices > 1 then
            self.choiceIndex = self.choiceIndex % #self.choices + 1
        end
    end

    function KBWPipetteCursor:current()
        return self.choices and self.choices[self.choiceIndex] or nil
    end

    function KBWPipetteCursor:isValid(square)
        return self:current() ~= nil
    end

    function KBWPipetteCursor:removeTooltip()
        if self.tooltip then
            self.tooltip:setVisible(false)
            self.tooltip:removeFromUIManager()
            self.tooltip = nil
        end
    end

    function KBWPipetteCursor:deactivate()
        self:removeTooltip()
    end

    -- Names what a click would pick, and how many pieces share the tile.
    function KBWPipetteCursor:updateTooltip()
        local choice = self:current()
        if not choice or not KBWBuildPlanTooltip then
            if self.tooltip then self.tooltip:setVisible(false) end
            return
        end
        if not self.tooltip then
            self.tooltip = KBWBuildPlanTooltip:new()
            self.tooltip:initialise()
            self.tooltip:addToUIManager()
        end
        local Theme = require("KnoxBuildworks/UI/Theme")
        local lines = { { text = getText(choice.source == "ghost" and "IGUI_KBW_PipettePlanned"
            or "IGUI_KBW_PipetteWorld", choice.label), color = Theme.text } }
        if #self.choices > 1 then
            ---@diagnostic disable-next-line: undefined-global
            local key = Keyboard and Keyboard.getKeyName and Keyboard.getKeyName(getCore():getKey(KeybindId.ROTATE_BUILDING)) or "R"
            lines[#lines + 1] = { text = getText("IGUI_KBW_PipetteNext", self.choiceIndex, #self.choices, key),
                color = Theme.textMuted }
        end
        self.tooltip:setLines(lines)
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

    function KBWPipetteCursor:render(x, y, z, square)
        local blueprint = Blueprints.get(self.character, self.blueprintId)
        if blueprint and blueprint.level ~= nil then self.planZ = floorInt(blueprint.level) end
        local tileX, tileY = PlanCursor.pickTileAt(self.player, self.planZ)
        local key = tostring(tileX) .. "|" .. tostring(tileY) .. "|" .. self.planZ .. "|" .. tostring(blueprint and blueprint.updated)
        if self.tileKey ~= key then
            self.tileKey = key
            self.choices = tileX and PipetteCursor.choicesAt(self.character, blueprint, tileX, tileY, self.planZ) or {}
            self.choiceIndex = 1
        end
        self.canBeBuild = self:current() ~= nil
        if tileX then
            GhostRenderer.renderTileHighlight(tileX, tileY, self.planZ,
                self:current() and PipetteCursor.COLOR or GhostRenderer.PLAN_COLOR_DIM, 0.45, self.player)
        end
        local choice = self:current()
        if choice then GhostRenderer.renderPlacementLayerAll(choice.placement, PipetteCursor.COLOR) end
        self:updateTooltip()
    end

    function KBWPipetteCursor:create(x, y, z, north, sprite)
        local choice = self:current()
        if not choice then return end
        self:removeTooltip()
        if self.onPicked then self.onPicked(choice) end
    end
end

Events.OnGameStart.Add(defineClass)

---@param player IsoPlayer
---@param blueprintId string
---@param onPicked function(choice)
function PipetteCursor.new(player, blueprintId, onPicked)
    return KBWPipetteCursor:new(player, blueprintId, onPicked)
end

return PipetteCursor
