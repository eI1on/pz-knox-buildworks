require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISContextMenu"
local Theme = require("KnoxBuildworks/UI/Theme")
local Resolver = require("KnoxBuildworks/Definitions/Resolver")
local Visibility = require("KnoxBuildworks/UI/CatalogVisibility")
local Blueprints = require("KnoxBuildworks/Planning/Blueprints")
local Planner = require("KnoxBuildworks/Planning/Planner")
local Icons = require("KnoxBuildworks/UI/IconResolver")
local I18n = require("KnoxBuildworks/I18n")
local TableUtil = require("KnoxBuildworks/Util/Table")

KBWPlanQuickbar = ISPanel:derive("KBWPlanQuickbar")
local SLOT_COUNT = 9

-- Let the planning panels consume shortcuts before the game's equipment bar.
-- Core also covers chat and text boxes owned by other windows.
function KBWPlanQuickbar:keySlot(key)
    if not Keyboard or getCore():isDoingTextEntry() then return nil end
    if self.owner.roofWindow and self.owner.roofWindow:isVisible() then return nil end
    for index = 1, SLOT_COUNT do
        if key == Keyboard["KEY_" .. index] then return index end
    end
end

local function slots(player)
    local data = player:getModData()
    data.KBW_UI = data.KBW_UI or {}
    data.KBW_UI.quickbar = data.KBW_UI.quickbar or {}
    return data.KBW_UI.quickbar
end

function KBWPlanQuickbar:new(owner)
    local size = 44
    local gapLeft = owner.x + owner.width + 8
    local available = math.max(size + 12, owner.catalogX - gapLeft - 8)
    local columns = math.max(1, math.min(SLOT_COUNT, math.floor((available - 12) / size)))
    local width = columns * size + 12
    local height = math.ceil(SLOT_COUNT / columns) * size + 8
    local o = ISPanel.new(self, gapLeft + (available - width) / 2,
        owner.screenTop + owner.screenH - height - 8, width, height)
    o.owner, o.player, o.size, o.columns = owner, owner.player, size, columns
    o.backgroundColor, o.borderColor = Theme.color(Theme.backdrop), Theme.color(Theme.border)
    return o
end

function KBWPlanQuickbar:createChildren()
    self.buttons = {}
    for index = 1, SLOT_COUNT do
        local button = ISButton:new(6 + ((index - 1) % self.columns) * self.size, 4 + math.floor((index - 1) / self.columns) * self.size, self.size - 4, self.size - 4, "", self,
            function(bar) bar:activate(index) end)
        button:initialise(); button:instantiate()
        button.render = function(control)
            ISButton.render(control)
            if control.image then control:drawText(tostring(index), 2, 1, 1, 1, 1, 1, UIFont.Small) end
        end
        Theme.applyButton(button, false)
        button.onRightMouseUp = function()
            local menu = ISContextMenu.get(self.player:getPlayerNum(), getMouseX(), getMouseY())
            menu:addOption(getText("IGUI_KBW_QuickbarAssign"), self, function(bar) bar:assign(index) end)
            menu:addOption(getText("IGUI_KBW_QuickbarClear"), self, function(bar)
                slots(bar.player)[tostring(index)] = nil; bar:refresh()
            end)
            return true
        end
        self:addChild(button)
        self.buttons[index] = button
    end
    self:refresh()
end

function KBWPlanQuickbar:refresh()
    for index = 1, SLOT_COUNT do
        local entry = slots(self.player)[tostring(index)]
        local definition, stage
        if entry then definition, stage = Resolver.resolveStage(entry.buildableId, entry.variantId, entry.materialId, entry.stageId) end
        local button = self.buttons[index]
        local texture = definition and stage and Icons.textureForDefinition(definition, stage, entry.direction)
        button:setImage(texture)
        if texture then
            local scale = 28 / math.max(texture:getWidth(), texture:getHeight(), 1)
            button:forceImageSize(texture:getWidth() * scale, texture:getHeight() * scale)
        end
        button:setTitle(texture and "" or tostring(index))
        button:setTooltip(tostring(index) .. " - " .. (definition and I18n.definitionName(definition) or getText("IGUI_KBW_QuickbarEmpty"))
            .. "\n" .. getText("IGUI_KBW_QuickbarHelp"))
    end
end

function KBWPlanQuickbar:assign(index)
    local entry = self.owner:planSelection()
    if not entry then return end
    slots(self.player)[tostring(index)] = TableUtil.copy(entry)
    self:refresh()
end

function KBWPlanQuickbar:activate(index)
    local entry = slots(self.player)[tostring(index)]
    if not entry then self:assign(index); return end
    local blueprint = self.owner:selectedOrActiveBlueprint()
    if not blueprint or not Blueprints.canContribute(self.player, blueprint) then return end
    local definition, stage = Resolver.resolveStage(entry.buildableId, entry.variantId, entry.materialId, entry.stageId)
    if not definition or not stage or not Visibility.definitionEnabled(definition)
        or not Visibility.stagePasses(self.player, definition, stage, false) then
        HaloTextHelper.addBadText(self.player, getText("IGUI_KBW_QuickbarUnavailable")); return
    end
    Blueprints.setActive(self.player, blueprint.id)
    Planner.begin(self.player, entry.buildableId, entry.stageId, entry.variantId, entry.materialId,
        entry.direction or 1, TableUtil.copy(entry.finish))
end

function KBWPlanQuickbar:close()
    self:setVisible(false)
    self:removeFromUIManager()
end

return KBWPlanQuickbar
