---PlanningMode provides the Knox Buildworks custom user-interface layer.
require "ISUI/ISPanel"

local KBW = require("KnoxBuildworks/Core")
local Registry = require("KnoxBuildworks/Definitions/Registry")
local Groups = require("KnoxBuildworks/Definitions/Groups")
local Blueprints = require("KnoxBuildworks/Planning/Blueprints")
local Planner = require("KnoxBuildworks/Planning/Planner")
local GhostRenderer = require("KnoxBuildworks/Planning/GhostRenderer")
local Theme = require("KnoxBuildworks/UI/Theme")
local PinnedRecipes = require("KnoxBuildworks/UI/PinnedRecipes")
local IconResolver = require("KnoxBuildworks/UI/IconResolver")
local I18n = require("KnoxBuildworks/I18n")
local Options = require("KnoxBuildworks/Options")
local Workspace = require("KnoxBuildworks/UI/PlanningWorkspace")
local PlanningCatalog = require("KnoxBuildworks/UI/PlanningCatalog")
local BlueprintPreview = require("KnoxBuildworks/UI/BlueprintPreview")
local Supplies = require("KnoxBuildworks/Planning/Supplies")
require("KnoxBuildworks/UI/BlueprintAccessWindow")
require("KnoxBuildworks/UI/BlueprintImportWindow")

---@class KBWPlanningMode: ISPanel
KBWPlanningMode = ISPanel:derive("KBWPlanningMode")
KBWPlanningMode.instance = nil

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)

---@class KBW.ROOM_COLORSModule
---@type KBW.ROOM_COLORSModule
local ROOM_COLORS = {
    { r = 0.20, g = 0.62, b = 1.00, a = 0.26 }, { r = 0.22, g = 0.86, b = 0.36, a = 0.26 },
    { r = 1.00, g = 0.76, b = 0.10, a = 0.26 }, { r = 0.72, g = 0.38, b = 1.00, a = 0.26 },
    { r = 0.18, g = 0.88, b = 0.90, a = 0.26 }, { r = 1.00, g = 0.42, b = 0.08, a = 0.26 },
    { r = 1.00, g = 0.22, b = 0.32, a = 0.26 }, { r = 1.00, g = 0.48, b = 0.82, a = 0.26 },
    { r = 0.68, g = 0.72, b = 0.78, a = 0.24 }, { r = 1.00, g = 1.00, b = 1.00, a = 0.22 },
    { r = 0.34, g = 0.42, b = 1.00, a = 0.26 }, { r = 0.52, g = 1.00, b = 0.18, a = 0.26 },
    { r = 1.00, g = 0.62, b = 0.28, a = 0.26 }, { r = 0.92, g = 0.32, b = 0.66, a = 0.26 }
}

local OPACITY_VALUES = { 0.08, 0.14, 0.22, 0.34 }

-- Per-player/faction grant levels (labels for the access summary line; the
-- access editor itself lives in UI/BlueprintAccessWindow.lua).
local GRANT_LEVELS = {
    { id = "none", label = "IGUI_KBW_LevelNone" },
    { id = "view", label = "IGUI_KBW_LevelView" },
    { id = "build", label = "IGUI_KBW_LevelBuild" },
    { id = "contribute", label = "IGUI_KBW_LevelContribute" }
}

local function displayName(definition)
    return I18n.definitionName(definition)
end

local function uiData(player)
    local root = player:getModData()
    root.KBW_UI = root.KBW_UI or { favorites = {}, recent = {}, compact = false }
    root.KBW_UI.favorites = root.KBW_UI.favorites or {}
    root.KBW_UI.recent = root.KBW_UI.recent or {}
    return root.KBW_UI
end

local function normalizeTagName(name)
    if not name then return nil end
    local value = tostring(name)
    if not string.find(value, ":", 1, true) then
        local dotIndex = string.find(value, ".", 1, true)
        if dotIndex then
            local namespace = string.sub(value, 1, dotIndex - 1)
            local path = string.sub(value, dotIndex + 1)
            if namespace ~= "" and path ~= "" and not string.find(path, ".", 1, true) then
                value = namespace .. ":" .. path
            end
        end
    end
    return value
end

local function tagDisplayName(name)
    local normalized = normalizeTagName(name) or tostring(name or "?")
    return IconResolver.displayNameForTag(normalized)
end

local function itemDisplayName(fullType)
    if type(fullType) == "string" and string.find(fullType, ".", 1, true) and getItemNameFromFullType then
        return getItemNameFromFullType(fullType)
    end
    return tostring(fullType or "?")
end

local function totalDisplayLabel(key, value, kind)
    local label = value and (value.label or value.name) or nil
    if kind == "skill" then return I18n.skill(value and value.name or key) end
    key = tostring(key or label or "?")
    if string.sub(key, 1, 1) == "#" then return tagDisplayName(string.sub(key, 2)) end
    if label and label ~= key and label ~= "" then return tostring(label) end
    return itemDisplayName(key)
end

local function say(player, text, bad)
    if not HaloTextHelper then return end
    if bad and HaloTextHelper.addBadText then
        HaloTextHelper.addBadText(player, text)
    elseif HaloTextHelper.addText then
        HaloTextHelper.addText(player, text)
    end
end

-- Greedy word wrap using measured text widths; list rows grow instead of
-- overflowing (no ellipses, per project UI rules).
local function wrapLines(text, maxWidth)
    text = tostring(text or "")
    local tm = getTextManager()
    if maxWidth < 20 or tm:MeasureStringX(UIFont.Small, text) <= maxWidth then return { text } end
    local lines, current = {}, ""
    for word in string.gmatch(text, "%S+") do
        local candidate = current == "" and word or (current .. " " .. word)
        if current ~= "" and tm:MeasureStringX(UIFont.Small, candidate) > maxWidth then
            lines[#lines + 1] = current
            current = word
        else
            current = candidate
        end
    end
    if current ~= "" then lines[#lines + 1] = current end
    if #lines == 0 then lines[1] = "" end
    return lines
end

-- addItem accumulates the default itemheight into the scroll range, so a
-- per-item height change must adjust the list's scroll height too.
local function setItemHeight(list, item, height)
    if not item then return end
    list:setScrollHeight(list:getScrollHeight() - (item.height or 0) + height)
    item.height = height
end

local function drawWrapped(list, lines, x, y, color, font)
    for lineIndex = 1, #lines do
        list:drawText(lines[lineIndex], x, y, color.r, color.g, color.b, 1, font or UIFont.Small)
        y = y + FONT_HGT_SMALL
    end
    return y
end

local function matchesInventoryBar(element, panel)
    if not element or not panel then return false end
    return element == panel or (panel.javaObject ~= nil and element == panel.javaObject)
end

local function isInventoryBar(element)
    for playerIndex = 0, 3 do
        if getPlayerInventory and matchesInventoryBar(element, getPlayerInventory(playerIndex)) then return true end
        if getPlayerLoot and matchesInventoryBar(element, getPlayerLoot(playerIndex)) then return true end
    end
    return false
end

local function captureInventoryBars()
    local states = {}
    local function capture(panel)
        if not panel then return end
        states[#states + 1] = {
            panel = panel,
            visible = panel:isVisible(),
            collapsed = panel.isCollapsed == true,
            pinned = panel.pin == true
        }
    end
    for playerIndex = 0, 3 do
        if getPlayerInventory then capture(getPlayerInventory(playerIndex)) end
        if getPlayerLoot then capture(getPlayerLoot(playerIndex)) end
    end
    return states
end

-- Expanded, unpinned inventory windows normally auto-collapse as soon as the
-- mouse moves to the planner. Hold only those windows open for the lifetime of
-- Planning Mode, then restore their original collapsed/pinned/visible state.
local function holdInventoryBars(states)
    states = states or {}
    for stateIndex = 1, #states do
        local state = states[stateIndex]
        local panel = state.panel
        if panel and state.visible then
            panel:setVisible(true)
            if not state.collapsed then
                if panel.setPinned then
                    panel:setPinned()
                else
                    panel.pin = true
                end
                panel.isCollapsed = false
                panel.collapseCounter = 0
                if panel.clearMaxDrawHeight then panel:clearMaxDrawHeight() end
            end
            panel:bringToTop()
        end
    end
end

local function restoreInventoryBars(states)
    states = states or {}
    for stateIndex = 1, #states do
        local state = states[stateIndex]
        local panel = state.panel
        if panel then
            panel:setVisible(state.visible == true)
            panel.isCollapsed = state.collapsed == true
            panel.collapseCounter = 0
            if state.pinned then
                if panel.setPinned then panel:setPinned() else panel.pin = true end
            else
                if panel.collapse then panel:collapse() else panel.pin = false end
                panel.pin = false
                if panel.collapseButton then panel.collapseButton:setVisible(false) end
                if panel.pinButton then
                    panel.pinButton:setVisible(true)
                    panel.pinButton:bringToTop()
                end
            end
            panel.isCollapsed = state.collapsed == true
            if state.collapsed then
                if panel.setMaxDrawHeight and panel.titleBarHeight then
                    panel:setMaxDrawHeight(panel:titleBarHeight())
                end
            elseif panel.clearMaxDrawHeight then
                panel:clearMaxDrawHeight()
            end
            if state.visible then panel:bringToTop() end
        end
    end
end

local function hideBaseUI(keepInventoryBars)
    local hidden = {}
    local ui = UIManager.getUI()
    for uiIndex = 0, ui:size() - 1 do
        local element = ui:get(uiIndex)
        if element and element:isVisible() and (keepInventoryBars ~= true or not isInventoryBar(element)) then
            hidden[#hidden + 1] = element:toString()
            element:setVisible(false)
        end
    end
    return hidden
end

local function restoreBaseUI(hidden)
    local ui = UIManager.getUI()
    hidden = hidden or {}
    for hiddenIndex = 1, #hidden do
        local key = hidden[hiddenIndex]
        for uiIndex = 0, ui:size() - 1 do
            local element = ui:get(uiIndex)
            if element and element:toString() == key then
                element:setVisible(true)
                break
            end
        end
    end
end

local function mapToSortedList(map, kind)
    local list = {}
    for key, value in pairs(map or {}) do
        local row = {
            kind = kind,
            key = value.iconKey or key,
            label = totalDisplayLabel(value.iconKey or key, value, kind),
            rawLabel = tostring((value and value.label) or (value and value.name) or key),
            source = value
        }
        if value and value.amount then row.amount = value.amount end
        if value and value.needed then row.amount = value.needed end
        row.stock, row.available = value.stock, value.available
        list[#list + 1] = row
    end
    table.sort(list, function (a, b) return tostring(a.label) < tostring(b.label) end)
    return list
end

local function levelLabel(level)
    level = tostring(level or "none")
    for levelIndex = 1, #GRANT_LEVELS do
        if GRANT_LEVELS[levelIndex].id == level then
            return getText(GRANT_LEVELS[levelIndex].label)
        end
    end
    if level == "private" then return getText("IGUI_KBW_LevelNone") end
    return tostring(level)
end

local function scopeShortLabel(scope)
    if scope == "view" then return getText("IGUI_KBW_AllCanViewShort") end
    if scope == "build" then return getText("IGUI_KBW_AllCanBuildShort") end
    if scope == "contribute" then return getText("IGUI_KBW_AllCanContributeShort") end
    return getText("IGUI_KBW_PrivateShort")
end

local function currentFaction(player)
    if not player or not Faction or not Faction.getPlayerFaction then return nil end
    return Faction.getPlayerFaction(player)
end

local function factionName(faction)
    if faction and faction.getName then return tostring(faction:getName()) end
    return nil
end

local function currentFactionName(player)
    return factionName(currentFaction(player))
end

local function blueprintAccessSummary(player, blueprint)
    if not blueprint then return getText("IGUI_KBW_NoBlueprintSelected") end
    local access = blueprint.access or {}
    local playerCount = 0
    for _ in pairs(access.players or {}) do
        playerCount = playerCount + 1
    end
    local factionCount = 0
    for _ in pairs(access.factions or {}) do
        factionCount = factionCount + 1
    end
    local faction = currentFactionName(player)
    local factionAccess = faction and access.factions and access.factions[faction] or nil
    if factionAccess then
        return string.format(
            "%s - faction %s - %d players", scopeShortLabel(access.scope), levelLabel(factionAccess), playerCount
        )
    end
    return string.format("%s - %d players - %d factions", scopeShortLabel(access.scope), playerCount, factionCount)
end

function KBWPlanningMode:new(player, hiddenUI, inventoryBars)
    Theme.applyAccessibility(Options)
    local playerNum = player:getPlayerNum()
    local screenLeft = getPlayerScreenLeft(playerNum)
    local screenTop = getPlayerScreenTop(playerNum)
    local screenW = getPlayerScreenWidth(playerNum)
    local screenH = getPlayerScreenHeight(playerNum)
    local usableWidth = math.max(560, screenW - 36)
    local catalogW = math.min(410, math.max(320, math.floor(screenW * .28)))
    local preferredWidth = math.max(390, math.min(460, getTextManager():getFontHeight(UIFont.Small) * 20 + 80))
    local width = math.min(preferredWidth, math.max(300, usableWidth - catalogW - 12))
    if width + catalogW + 12 > usableWidth then catalogW = math.max(280, usableWidth - width - 12) end
    local height = math.min(screenH - 48, math.max(620, screenH - 72))
    local x = screenLeft + 12
    local y = screenTop + 36
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.player = player
    o.hiddenUI = hiddenUI or {}
    o.inventoryBars = inventoryBars or {}
    o.screenLeft = screenLeft
    o.screenTop = screenTop
    o.screenW = screenW
    o.screenH = screenH
    o.catalogWidth = catalogW
    o.catalogX = screenLeft + screenW - catalogW - 12
    o.background = true
    o.backgroundColor = Theme.color(Theme.backdrop)
    o.borderColor = Theme.color(Theme.border)
    o.roomColorIndex = 1
    o.selectedBuildable = nil
    o.opacityIndex = 2
    return o
end

function KBWPlanningMode:createChildren()
    ISPanel.createChildren(self)
    self:setWantKeyEvents(true)
    Workspace.create(self, ROOM_COLORS, OPACITY_VALUES)
    self:refreshBlueprints()
    self:onPickColor(1)
    self:onOpacity(self.opacityIndex)
    Workspace.layout(self)
    self.catalogPanel = PlanningCatalog:new(
        self, self.player, self.catalogX, self.y, self.catalogWidth, self.height
    )
    self.catalogPanel:initialise()
    self.catalogPanel:addToUIManager()
    self.catalogPanel:bringToTop()
end

function KBWPlanningMode:onBrowsePieces()
    local blueprint = self:selectedOrActiveBlueprint()
    if not blueprint or not Blueprints.canContribute(self.player, blueprint) then return end
    Planner.cancelCursor(self.player)
    Blueprints.setActive(self.player, blueprint.id)
    self.workspaceTab = "pieces"
    Workspace.layout(self)
    self:focusCatalog()
end

function KBWPlanningMode:focusCatalog()
    if not self.catalogPanel then return nil end
    self.catalogPanel:setVisible(true)
    self.catalogPanel:bringToTop()
    return self.catalogPanel
end

---@param key string|number
function KBWPlanningMode:isKeyConsumed(key)
    if Keyboard and key == Keyboard.KEY_ESCAPE then return true end
    return false
end

---@param key string|number
function KBWPlanningMode:onKeyRelease(key)
    if Keyboard and key == Keyboard.KEY_ESCAPE then self:close() end
end

function KBWPlanningMode:selectedBlueprint()
    local item = self.blueprintList.items[self.blueprintList.selected]
    return item and item.item or nil
end

function KBWPlanningMode:selectedPlacement()
    local item = self.placementList.items[self.placementList.selected]
    return item and item.item or nil
end

function KBWPlanningMode:selectedRoom()
    local item = self.roomList and self.roomList.items[self.roomList.selected]
    return item and item.item or nil
end

function KBWPlanningMode:selectedOrActiveBlueprint()
    local blueprint = self:selectedBlueprint() or Blueprints.active(self.player)
    if not blueprint then
        blueprint = Blueprints.create(self.player, nil, math.floor(self.player:getZ()))
        self:refreshBlueprints()
    end
    return blueprint
end

function KBWPlanningMode:canPlanSelection()
    local blueprint = self:selectedBlueprint() or Blueprints.active(self.player)
    return blueprint == nil or Blueprints.canContribute(self.player, blueprint)
end

---@param definition KBW.BuildableDefinition|nil
function KBWPlanningMode:onCatalogSelected(definition)
    local changed = self.selectedBuildable ~= definition
    self.selectedBuildable = definition
    if changed and self.catalogPanel then self.catalogPanel:selectDefinition(definition) end
end

---@param definition KBW.BuildableDefinition
function KBWPlanningMode:onCatalogActivated(definition)
    self:onCatalogSelected(definition)
    self:onPlanSelected()
end

---@param definition KBW.BuildableDefinition
function KBWPlanningMode:isFavorite(definition)
    return definition ~= nil and uiData(self.player).favorites[definition.id] == true
end

---@param definition KBW.BuildableDefinition
function KBWPlanningMode:isPinnedDefinition(definition)
    return PinnedRecipes.hasPinnedDefinition(self.player, definition)
end

---@param definition KBW.BuildableDefinition
function KBWPlanningMode:onGridFavorite(definition)
    if not definition then return end
    local favorites = uiData(self.player).favorites
    favorites[definition.id] = not favorites[definition.id]
    if self.catalogPanel then
        self.catalogPanel:refreshCatalog()
        self.catalogPanel:layout()
    end
end

---@param definition KBW.BuildableDefinition
function KBWPlanningMode:onGridPin(definition)
    if not definition then return end
    PinnedRecipes.toggleDefault(self.player, definition)
    if self.catalogPanel then
        self.catalogPanel:refreshCatalog()
        self.catalogPanel:layout()
    end
end

---@param y number
---@param item table
function KBWPlanningMode:drawBlueprintRow(list, y, item, alt)
    local blueprint = item.item
    local selected = list.selected == item.index
    local fill = selected and Theme.selected or (alt and Theme.surfaceRaised or Theme.surface)
    list:drawRect(0, y, list.width, item.height - 2, fill.a, fill.r, fill.g, fill.b)
    list:drawRectBorder(
        0, y, list.width, item.height - 2, Theme.borderSoft.a, Theme.borderSoft.r, Theme.borderSoft.g,
        Theme.borderSoft.b
    )
    local nameLines = item.nameLines or { tostring(blueprint.name or blueprint.id) }
    local textY = drawWrapped(list, nameLines, 10, y + 5, Theme.text)
    local rooms = blueprint.rooms or {}
    local placements = blueprint.placements or {}
    list:drawText(
        getText("IGUI_KBW_BlueprintSummary", tostring(blueprint.level or 0),
            tostring(#rooms), tostring(#placements)
        ), 10, textY + 2, Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 1, UIFont.Small
    )
    return y + item.height
end

---@param y number
---@param item table
function KBWPlanningMode:drawPlacementRow(list, y, item, alt)
    local placement = item.item
    local selected = list.selected == item.index
    local fill = selected and Theme.selected or (alt and Theme.surfaceRaised or Theme.surface)
    list:drawRect(0, y, list.width, item.height - 2, fill.a, fill.r, fill.g, fill.b)
    local nameLines = item.nameLines or { displayName(Registry:get(placement.buildableId)) }
    local textY = drawWrapped(list, nameLines, 10, y + 4, Theme.text)
    local details = string.format(
        "%s  %d,%d z%d", tostring(placement.stageId or ""), placement.x or 0, placement.y or 0, placement.z or 0
    )
    list:drawText(details, 10, textY + 2, Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 1, UIFont.Small)
    return y + item.height
end

---@param y number
---@param item table
function KBWPlanningMode:drawRoomRow(list, y, item, alt)
    local room = item.item
    local selected = list.selected == item.index
    local fill = selected and Theme.selected or (alt and Theme.surfaceRaised or Theme.surface)
    local color = room.color or ROOM_COLORS[1]
    list:drawRect(0, y, list.width, item.height - 2, fill.a, fill.r, fill.g, fill.b)
    list:drawRect(8, y + 8, 14, 14, 1, color.r or 0.25, color.g or 0.65, color.b or 0.95)
    list:drawRectBorder(8, y + 8, 14, 14, Theme.border.a, Theme.border.r, Theme.border.g, Theme.border.b)
    local nameLines = item.nameLines or { tostring(room.name or room.type or "Room") }
    local textY = drawWrapped(list, nameLines, 30, y + 3, Theme.text)
    local details = string.format(
        "%dx%d  %d,%d z%d", room.w or room.width or 1, room.h or room.height or 1, room.x or 0, room.y or 0, room.z or 0
    )
    list:drawText(details, 30, textY + 2, Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 1, UIFont.Small)
    return y + item.height
end

---@param y number
---@param item table
function KBWPlanningMode:drawTotalRow(list, y, item, alt)
    local row = item.item
    if row.kind == "header" then
        list:drawRect(
            0, y, list.width, item.height - 1, Theme.surfaceRaised.a, Theme.surfaceRaised.r, Theme.surfaceRaised.g,
            Theme.surfaceRaised.b
        )
        drawWrapped(list, item.nameLines or { row.label }, 8, y + 3, Theme.accent)
    else
        local fill = alt and Theme.surfaceRaised or Theme.surface
        list:drawRect(0, y, list.width, item.height - 1, fill.a, fill.r, fill.g, fill.b)
        local suffix = row.amount and ("  x" .. tostring(row.amount)) or ""
        local icon = nil
        local iconColor = { r = 1, g = 1, b = 1, a = 1 }
        local key = tostring(row.key or "")
        if string.sub(key, 1, 1) == "#" then
            icon, iconColor = IconResolver.textureForTag(string.sub(key, 2))
        elseif row.kind == "material" or row.kind == "tool" then
            icon, iconColor = IconResolver.textureForItem(key)
        end
        iconColor = iconColor or { r = 1, g = 1, b = 1, a = 1 }
        local textX = 12
        if icon then
            list:drawTextureScaledAspect(
                icon, 8, y + 3, 20, 20, iconColor.a or 1, iconColor.r or 1, iconColor.g or 1, iconColor.b or 1
            )
            textX = 34
        end
        local textColor = row.stock ~= nil and row.available < row.amount and Theme.warn or Theme.text
        drawWrapped(list, item.nameLines or { tostring(row.label) .. suffix }, textX, y + 5, textColor)
    end
    return y + item.height
end

function KBWPlanningMode:refreshBlueprints(preferredId)
    local active = Blueprints.active(self.player)
    self.blueprintList:clear()
    local values = Blueprints.list(self.player)
    local selectedIndex = 1
    for blueprintIndex = 1, #values do
        local blueprint = values[blueprintIndex]
        local item = self.blueprintList:addItem(blueprint.name or blueprint.id, blueprint)
        if item then
            -- Long names wrap into taller rows instead of overflowing.
            item.nameLines = wrapLines(blueprint.name or blueprint.id, self.blueprintList.width - 20)
            setItemHeight(self.blueprintList, item, #item.nameLines * FONT_HGT_SMALL + FONT_HGT_SMALL + 16)
        end
        if preferredId and preferredId == blueprint.id then
            selectedIndex = blueprintIndex
        elseif not preferredId and active and active.id == blueprint.id then
            selectedIndex = blueprintIndex
        end
    end
    if #values > 0 then self.blueprintList.selected = selectedIndex end
    local selected = self:selectedBlueprint()
    if self.blueprintName then
        self.blueprintName:setText(selected and tostring(selected.name or selected.id) or "")
    end
    self:refreshRooms()
    self:refreshPlacements()
    self:refreshTotals()
    self:updateBlueprintPinButton()
    self:updateActivateButton()
    self:updateAccessControls()
    if self.accessWindow and selected then
        self.accessWindow.blueprintId = selected.id
        self.accessWindow:syncFromBlueprint()
    end
    Workspace.layout(self)
end

-- Enables/disables editing controls to match the player's permission on the
-- selected blueprint, and reflects the current access scope.
function KBWPlanningMode:updateAccessControls()
    local blueprint = self:selectedBlueprint()
    local isOwner = blueprint ~= nil and Blueprints.isOwner(self.player, blueprint)
    local canContribute = blueprint ~= nil and Blueprints.canContribute(self.player, blueprint)
    Theme.setButtonEnabled(self.manageAccessButton, blueprint ~= nil)
    Theme.setButtonEnabled(self.previewButton, blueprint ~= nil)
    local ownerButtons = { self.renameButton }
    for buttonIndex = 1, #ownerButtons do
        Theme.setButtonEnabled(ownerButtons[buttonIndex], isOwner == true)
    end
    -- Contribute-gated editing tools.
    local editButtons = {
        self.levelDownButton, self.levelUpButton, self.usePlayerLevelButton, self.drawRoomButton, self.eraseRoomButton,
        self.eraseButton, self.gatherAreaButton, self.moveBlueprintButton, self.removeSelectedButton,
        self.updateRoomButton, self.deleteRoomButton
    }
    for buttonIndex = 1, #editButtons do
        Theme.setButtonEnabled(editButtons[buttonIndex], canContribute == true)
    end
    Theme.setButtonEnabled(self.browseButton, canContribute == true)
    Theme.setButtonEnabled(self.removeSelectedButton, canContribute == true and self:selectedPlacement() ~= nil)
    -- Build-gated tools (build access can raise ghosts, not edit the plan).
    local canBuild = blueprint ~= nil and Blueprints.canBuild(self.player, blueprint)
    local buildButtons = { self.buildToolButton, self.buildAllButton, self.buildSelectedButton }
    for buttonIndex = 1, #buildButtons do
        Theme.setButtonEnabled(buildButtons[buttonIndex], canBuild == true)
    end
    local supplies = self.supplyState
    local checked = blueprint and Supplies.current(supplies, blueprint) and supplies.phase == "done"
    local selected = self:selectedPlacement()
    Theme.setButtonEnabled(self.buildAllButton, canBuild and checked and supplies.count > 0 and supplies.allReady)
    Theme.setButtonEnabled(self.buildToolButton, canBuild and checked and supplies.anyReady)
    Theme.setButtonEnabled(self.buildSelectedButton, canBuild and checked and selected and supplies.singleReady[selected.id] == true)
    local reason = not canBuild and getText("IGUI_KBW_PlanNoBuildPermission")
        or (not checked and getText("IGUI_KBW_CheckingSupplies"))
        or (supplies and supplies.incomplete and getText("IGUI_KBW_UnloadedSupplies"))
        or getText("IGUI_KBW_SupplyShortageHelp")
    if self.buildAllButton.enable == false then self.buildAllButton:setTooltip(reason)
    else self.buildAllButton:setTooltip(getText("Tooltip_KBW_BuildAll")) end
    if self.buildToolButton.enable == false then self.buildToolButton:setTooltip(reason)
    else self.buildToolButton:setTooltip(getText("Tooltip_KBW_BuildTool")) end
    if self.buildSelectedButton.enable == false then self.buildSelectedButton:setTooltip(reason)
    else self.buildSelectedButton:setTooltip(getText("Tooltip_KBW_BuildPlacement")) end
    if self.catalogPanel then self.catalogPanel:layout() end
end

function KBWPlanningMode:onManageAccess()
    local blueprint = self:selectedBlueprint()
    if not blueprint then return end
    if self.accessWindow then
        self.accessWindow.blueprintId = blueprint.id
        self.accessWindow:syncFromBlueprint()
        self.accessWindow:setVisible(true)
        self.accessWindow:bringToTop()
        return
    end
    self.accessWindow = KBWBlueprintAccessWindow:new(self, self.player, blueprint)
    self.accessWindow:initialise()
    self.accessWindow:addToUIManager()
    self.accessWindow:bringToTop()
end

function KBWPlanningMode:refreshRooms()
    if not self.roomList then return end
    self.roomList:clear()
    local blueprint = self:selectedBlueprint()
    if not blueprint then return end
    local rooms = blueprint.rooms or {}
    for roomIndex = 1, #rooms do
        local room = rooms[roomIndex]
        local item = self.roomList:addItem(tostring(room.name or room.id), room)
        if item then
            item.nameLines = wrapLines(room.name or room.type or "Room", self.roomList.width - 40)
            setItemHeight(self.roomList, item, #item.nameLines * FONT_HGT_SMALL + FONT_HGT_SMALL + 14)
        end
    end
    if #rooms > 0 then self.roomList.selected = 1 end
end

function KBWPlanningMode:refreshPlacements()
    self.placementList:clear()
    local blueprint = self:selectedBlueprint()
    if not blueprint then return end
    local placements = blueprint.placements or {}
    for placementIndex = 1, #placements do
        local placement = placements[placementIndex]
        local item = self.placementList:addItem(tostring(placement.id), placement)
        if item then
            item.nameLines = wrapLines(displayName(Registry:get(placement.buildableId)), self.placementList.width - 20)
            setItemHeight(self.placementList, item, #item.nameLines * FONT_HGT_SMALL + FONT_HGT_SMALL + 14)
        end
    end
end

function KBWPlanningMode:refreshTotals()
    self.totalList:clear()
    local blueprint = self:selectedBlueprint()
    if not blueprint then return end
    if not Supplies.current(self.supplyState, blueprint) then self.supplyState = Supplies.new(self.player, blueprint) end
    local checked = self.supplyState.phase == "done"
    local totals = checked and self.supplyState or Blueprints.totals(self.player, blueprint)
    local listWidth = self.totalList.width
    local function addHeader(label)
        local item = self.totalList:addItem(label, { kind = "header", label = label })
        if item then
            item.nameLines = wrapLines(label, listWidth - 16)
            setItemHeight(self.totalList, item, #item.nameLines * FONT_HGT_SMALL + 8)
        end
    end
    local function addRows(rows)
        for rowIndex = 1, #rows do
            local row = rows[rowIndex]
            local item = self.totalList:addItem(row.label, row)
            if item then
                local suffix = row.amount and ("  x" .. tostring(row.amount)) or ""
                if row.stock ~= nil then
                    local key = row.source.uses and "IGUI_KBW_HaveNeedUses" or "IGUI_KBW_HaveNeed"
                    suffix = "  " .. getText(key, tostring(row.stock), tostring(row.amount))
                    if row.available < row.amount then
                        suffix = suffix .. "  " .. getText("IGUI_KBW_ShortBy", tostring(row.amount - row.available))
                    end
                end
                -- Icon rows indent by 34, plain rows by 12.
                item.nameLines = wrapLines(tostring(row.label) .. suffix, listWidth - 46)
                setItemHeight(self.totalList, item, math.max(26, #item.nameLines * FONT_HGT_SMALL + 10))
            end
        end
    end
    local rooms = blueprint.rooms or {}
    addHeader(
        getText("IGUI_KBW_BlueprintTotalsShort", tostring(totals.count or totals.placements or 0),
            tostring(#rooms)
        )
    )
    if not checked then addHeader(getText("IGUI_KBW_CheckingSupplies"))
    elseif totals.incomplete then addHeader(getText("IGUI_KBW_UnloadedSupplies")) end
    if checked then addHeader(getText("IGUI_KBW_SupplySources")) end
    addHeader(getText("IGUI_KBW_MaterialsTools"))
    addRows(mapToSortedList(totals.materials, "material"))
    addRows(mapToSortedList(totals.tools, "tool"))
    addHeader(getText("IGUI_KBW_SkillsKnowledge"))
    addRows(mapToSortedList(totals.skills, "skill"))
    addRows(mapToSortedList(totals.recipes, "knowledge"))
end

function KBWPlanningMode:onBlueprintSelected()
    Workspace.layout(self)
    local blueprint = self:selectedBlueprint()
    if self.blueprintName then
        self.blueprintName:setText(blueprint and tostring(blueprint.name or blueprint.id) or "")
    end
    self:refreshRooms()
    self:refreshPlacements()
    self:refreshTotals()
    self:updateBlueprintPinButton()
    self:updateActivateButton()
    self:updateAccessControls()
end

function KBWPlanningMode:onPlacementSelected()
    self:updateAccessControls()
    local placement = self:selectedPlacement()
    Planner.setHighlight(placement and placement.id or nil)
end

function KBWPlanningMode:onRoomSelected()
    local room = self:selectedRoom()
    if room and self.roomName then self.roomName:setText(tostring(room.name or room.type or "")) end
    -- Seed the color picker from the selected room so Update Room does not
    -- silently overwrite the room's color with a stale swatch selection.
    if room and room.color then
        for colorIndex = 1, #ROOM_COLORS do
            local color = ROOM_COLORS[colorIndex]
            if math.abs(color.r - (room.color.r or -1)) < 0.01 and math.abs(color.g - (room.color.g or -1)) < 0.01
                and math.abs(color.b - (room.color.b or -1)) < 0.01 then
                self:onPickColor(colorIndex)
                break
            end
        end
    end
    Planner.setHighlightRoom(room and room.id or nil)
end

function KBWPlanningMode:updateBlueprintPinButton()
    if not self.pinBlueprintButton then return end
    local blueprint = self:selectedBlueprint()
    local pinned = blueprint and PinnedRecipes.isBlueprintPinned
        and PinnedRecipes.isBlueprintPinned(self.player, blueprint)
    Theme.applyButton(self.pinBlueprintButton, pinned == true)
    self.pinBlueprintButton:setTitle(
        pinned and getText("IGUI_KBW_UnpinBlueprint") or getText("IGUI_KBW_PinBlueprint")
    )
end

function KBWPlanningMode:onPinBlueprint()
    local blueprint = self:selectedBlueprint()
    if not blueprint or not PinnedRecipes.toggleBlueprint then return end
    PinnedRecipes.toggleBlueprint(self.player, blueprint)
    self:updateBlueprintPinButton()
end

function KBWPlanningMode:onNewBlueprint()
    Blueprints.create(self.player, nil, math.floor(self.player:getZ()))
    self:refreshBlueprints()
end

function KBWPlanningMode:onDuplicateBlueprint()
    local blueprint = self:selectedBlueprint()
    if not blueprint then return end
    local copy = Blueprints.duplicate(self.player, blueprint.id)
    if copy then Blueprints.setActive(self.player, copy.id) end
    self:refreshBlueprints()
end

function KBWPlanningMode:onRenameBlueprint()
    local blueprint = self:selectedBlueprint()
    if not blueprint or not self.blueprintName then return end
    local name = self.blueprintName:getInternalText()
    if name and name ~= "" then
        Blueprints.rename(self.player, blueprint.id, name)
        self:refreshBlueprints()
    end
end

function KBWPlanningMode:onDeleteBlueprint()
    local blueprint = self:selectedBlueprint()
    if not blueprint then return end
    Blueprints.delete(self.player, blueprint.id)
    Planner.setHighlight(nil)
    Planner.setHighlightRoom(nil)
    self:refreshBlueprints()
end

-- Toggles the selected blueprint's ghost overlay: activating draws it in the
-- world, deactivating clears the active blueprint so nothing is drawn.
function KBWPlanningMode:onActivateBlueprint()
    local blueprint = self:selectedBlueprint()
    if not blueprint then return end
    if Blueprints.isActive(self.player, blueprint.id) then
        Blueprints.setActive(self.player, nil)
    else
        Blueprints.setActive(self.player, blueprint.id)
        GhostRenderer.clearCache()
    end
    self:updateActivateButton()
end

function KBWPlanningMode:updateActivateButton()
    if not self.activateButton then return end
    local blueprint = self:selectedBlueprint()
    local active = blueprint ~= nil and Blueprints.isActive(self.player, blueprint.id)
    Theme.applyButton(self.activateButton, active == true)
    self.activateButton:setTitle(
        active and getText("IGUI_KBW_DeactivateBlueprint")
            or getText("IGUI_KBW_ActivateBlueprint")
    )
end

function KBWPlanningMode:onExportBlueprint()
    local blueprint = self:selectedBlueprint()
    if not blueprint then return end
    local path = Blueprints.exportToFile(blueprint)
    say(
        self.player,
        path
            and getText("IGUI_KBW_Exported", tostring(blueprint.name or blueprint.id), path
            )
            or getText("IGUI_KBW_ExportFailed"), path == nil
    )
end

function KBWPlanningMode:onImportBlueprint()
    local owner = self
    KBWBlueprintImportWindow.open(self.player, function (blueprint)
        owner:refreshBlueprints()
        -- Imported plans land at the player; hand straight to the Move
        -- blueprint cursor so the origin can be placed properly.
        Planner.beginMoveBlueprint(owner.player, blueprint.id)
    end)
end

function KBWPlanningMode:onCopyBlueprintJSON()
    local blueprint = self:selectedBlueprint()
    if not blueprint or not Clipboard then return end
    Clipboard.setClipboard(Blueprints.exportJSON(blueprint))
    say(self.player, getText("IGUI_KBW_BlueprintCopiedJSON"), false)
end

function KBWPlanningMode:onLevelDown()
    local blueprint = self:selectedBlueprint()
    if not blueprint then return end
    local level = (tonumber(blueprint.level) or 0) - 1
    Blueprints.setLevel(self.player, blueprint.id, level)
    self:refreshBlueprints()
end

function KBWPlanningMode:onLevelUp()
    local blueprint = self:selectedBlueprint()
    if not blueprint then return end
    local level = (tonumber(blueprint.level) or 0) + 1
    Blueprints.setLevel(self.player, blueprint.id, level)
    self:refreshBlueprints()
end

function KBWPlanningMode:onUsePlayerLevel()
    local blueprint = self:selectedBlueprint()
    if not blueprint then return end
    Blueprints.setLevel(self.player, blueprint.id, math.floor(self.player:getZ()))
    self:refreshBlueprints()
end

function KBWPlanningMode:onPickColor(colorIndex)
    self.roomColorIndex = colorIndex
    for buttonIndex = 1, #self.colorButtons do
        local button = self.colorButtons[buttonIndex]
        button.borderColor = Theme.color(buttonIndex == colorIndex and Theme.accent or Theme.borderSoft)
        Theme.lockButtonColors(button)
    end
end

-- Applies both the name field and the currently selected palette color to the
-- selected room (the hint swatch beside the name field previews the color).
function KBWPlanningMode:onUpdateRoom()
    local blueprint = self:selectedBlueprint()
    local room = self:selectedRoom()
    if not blueprint or not room then return end
    local name = self.roomName and self.roomName:getInternalText() or nil
    if not name or name == "" then name = room.name or getText("IGUI_KBW_RoomTypeGeneric") end
    local color = ROOM_COLORS[self.roomColorIndex or 1] or ROOM_COLORS[1]
    Blueprints.updateRoom(self.player, blueprint.id, room.id, {
        name = name,
        color = { r = color.r, g = color.g, b = color.b, a = color.a }
    })
    self:refreshRooms()
    self:refreshTotals()
end

function KBWPlanningMode:onDeleteRoom()
    local blueprint = self:selectedBlueprint()
    local room = self:selectedRoom()
    if not blueprint or not room then return end
    Blueprints.removeRoom(self.player, blueprint.id, room.id)
    Planner.setHighlightRoom(nil)
    self:refreshRooms()
    self:refreshTotals()
end

function KBWPlanningMode:onOpacity(opacityIndex)
    self.opacityIndex = opacityIndex
    local value = OPACITY_VALUES[opacityIndex] or 0.5
    GhostRenderer.setOpacity(value)
    for buttonIndex = 1, #self.opacityButtons do
        Theme.applyButton(self.opacityButtons[buttonIndex], buttonIndex == opacityIndex)
    end
end

function KBWPlanningMode:roomTemplate()
    local color = ROOM_COLORS[self.roomColorIndex or 1] or ROOM_COLORS[1]
    local name = self.roomName:getInternalText()
    if name == nil or name == "" then name = getText("IGUI_KBW_RoomTypeGeneric") end
    return { name = name, type = "room", color = { r = color.r, g = color.g, b = color.b, a = color.a } }
end

function KBWPlanningMode:onDrawRoom()
    local blueprint = self:selectedOrActiveBlueprint()
    if not blueprint then return end
    Blueprints.setActive(self.player, blueprint.id)
    local owner = self
    Planner.beginRoom(self.player, blueprint.id, self:roomTemplate(), function ()
        owner:refreshBlueprints()
    end)
end

---@param mode string|nil
function KBWPlanningMode:beginEraseMode(mode)
    local blueprint = self:selectedOrActiveBlueprint()
    if not blueprint then return end
    Blueprints.setActive(self.player, blueprint.id)
    local owner = self
    Planner.beginErase(self.player, blueprint.id, function ()
        owner:refreshBlueprints()
    end, mode
    )
end

function KBWPlanningMode:onEraseTool()
    self:beginEraseMode("placements")
end

function KBWPlanningMode:onEraseRoomTool()
    self:beginEraseMode("rooms")
end

function KBWPlanningMode:onGatherArea()
    local blueprint = self:selectedOrActiveBlueprint()
    if not blueprint then return end
    Blueprints.setActive(self.player, blueprint.id)
    local owner = self
    Planner.beginGatherArea(self.player, blueprint.id, function ()
        Planner.cancelCursor(owner.player)
    end)
end

function KBWPlanningMode:onBuildAll()
    local blueprint = self:selectedOrActiveBlueprint()
    if not blueprint then return end
    Blueprints.setActive(self.player, blueprint.id)
    local BuildQueue = require("KnoxBuildworks/Planning/BuildQueue")
    local owner = self
    BuildQueue.start(self.player, blueprint.id, function ()
        owner:refreshBlueprints()
    end)
end

function KBWPlanningMode:onStopQueue()
    local BuildQueue = require("KnoxBuildworks/Planning/BuildQueue")
    BuildQueue.stop()
end

function KBWPlanningMode:onBuildTool()
    local blueprint = self:selectedOrActiveBlueprint()
    if not blueprint then return end
    Blueprints.setActive(self.player, blueprint.id)
    local owner = self
    Planner.beginBuildTool(self.player, blueprint.id, function ()
        owner:refreshBlueprints()
    end)
end

function KBWPlanningMode:onMoveBlueprint()
    local blueprint = self:selectedOrActiveBlueprint()
    if not blueprint then return end
    Blueprints.setActive(self.player, blueprint.id)
    local owner = self
    Planner.beginMoveBlueprint(self.player, blueprint.id, function ()
        owner:refreshBlueprints()
        owner:updateActivateButton()
    end)
end

function KBWPlanningMode:onStopTool()
    Planner.cancelCursor(self.player)
    Planner.setHighlightRoom(nil)
end

function KBWPlanningMode:onPreviewBlueprint()
    local blueprint = self:selectedBlueprint()
    if not blueprint then return end
    self.previewWindow = BlueprintPreview.open(self, self.player, blueprint)
end

function KBWPlanningMode:onPlanSelected()
    local blueprint = self:selectedOrActiveBlueprint()
    local definition = self.selectedBuildable
    if not blueprint or not definition then
        say(self.player, getText("IGUI_KBW_SelectBuildableFirst"), true)
        return
    end
    if not Blueprints.canContribute(self.player, blueprint) then
        say(self.player, getText("IGUI_KBW_PlanNoPermission"), true)
        return
    end
    local catalog = self.catalogPanel
    local stage = catalog and catalog:selectedStage() or (definition.stages and definition.stages[1])
    if not stage then return end
    local variantId = catalog and catalog:selectedVariant() or ""
    local materialId = catalog and catalog:selectedMaterial() or ""
    local finish = catalog and catalog:selectedFinish() or nil
    Blueprints.setActive(self.player, blueprint.id)
    Planner.begin(
        self.player, Groups.resolveBuildableId(definition, stage), Groups.resolveStageId(stage),
        variantId, materialId, 1, finish
    )
end

function KBWPlanningMode:onBuildSelected()
    local blueprint = self:selectedBlueprint()
    local placement = self:selectedPlacement()
    if blueprint and placement then
        local owner = self
        local BuildQueue = require("KnoxBuildworks/Planning/BuildQueue")
        BuildQueue.startSelected(self.player, blueprint.id, placement, function ()
            owner:refreshBlueprints()
        end)
    end
end

function KBWPlanningMode:onExit()
    self:close()
end

function KBWPlanningMode:prerender()
    ISPanel.prerender(self)
    Workspace.render(self)
end

function KBWPlanningMode:update()
    ISPanel.update(self)
    if self.closing then return end
    local blueprint = self:selectedBlueprint()
    if blueprint and not Supplies.current(self.supplyState, blueprint) then self:refreshTotals() end
    local state = self.supplyState
    if blueprint and state and state.phase ~= "done" then
        Supplies.step(state)
        if state.phase == "done" then
            self:refreshTotals()
            self:updateAccessControls()
        end
    end
end

function KBWPlanningMode:close()
    self.closing = true
    if self.catalogPanel then
        self.catalogPanel:close()
        self.catalogPanel = nil
    end
    Planner.cancelCursor(self.player)
    Planner.setHighlight(nil)
    Planner.setHighlightRoom(nil)
    if self.accessWindow then
        self.accessWindow:close()
        self.accessWindow = nil
    end
    if self.previewWindow then
        self.previewWindow:close()
        self.previewWindow = nil
    end
    self:setVisible(false)
    self:removeFromUIManager()
    restoreBaseUI(self.hiddenUI)
    restoreInventoryBars(self.inventoryBars)
    if KBWPlanningMode.instance == self then KBWPlanningMode.instance = nil end
end

---@param player IsoPlayer
function KBWPlanningMode.open(player)
    player = player or getPlayer()
    if not KBW.Runtime.loaded then
        if player and HaloTextHelper and HaloTextHelper.addText then
            HaloTextHelper.addText(player, getText("IGUI_KBW_DefinitionsLoading"))
        end
        return nil
    end
    if KBW.sandboxValue("KnoxBuildworks.EnablePlanningMode", true) ~= true then
        if HaloTextHelper and HaloTextHelper.addBadText then
            HaloTextHelper.addBadText(
                player, getText("IGUI_KBW_PlanningDisabled")
            )
        end
        return nil
    end
    if KBWPlanningMode.instance then KBWPlanningMode.instance:close() end
    local keepOption = Options and Options.getOption and Options:getOption("KeepInventoryVisibleInPlanning") or nil
    local keepInventoryBars = keepOption and keepOption.getValue and keepOption:getValue() == true
    local inventoryBars = keepInventoryBars and captureInventoryBars() or {}
    local hidden = hideBaseUI(keepInventoryBars)
    local ui = KBWPlanningMode:new(player, hidden, inventoryBars)
    ui:initialise()
    ui:addToUIManager()
    ui:bringToTop()
    if ui.catalogPanel then ui.catalogPanel:bringToTop() end
    if keepInventoryBars then holdInventoryBars(inventoryBars) end
    KBWPlanningMode.instance = ui
    return ui
end

function KBWPlanningMode:onRemoveSelectedPlacement()
    local blueprint = self:selectedBlueprint()
    local placement = self:selectedPlacement()
    if not blueprint or not placement or not Blueprints.canContribute(self.player, blueprint) then return end
    if Blueprints.removePlacement(self.player, blueprint.id, placement.id) then
        Planner.setHighlight(nil)
        self:refreshBlueprints(blueprint.id)
    end
end

return KBWPlanningMode
