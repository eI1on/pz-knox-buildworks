---BlueprintAccessWindow provides the Knox Buildworks custom user-interface layer.
require "ISUI/ISCollapsableWindow"
require "ISUI/ISButton"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTextEntryBox"
require "ISUI/ISComboBox"

local Blueprints = require("KnoxBuildworks/Planning/Blueprints")
local Theme = require("KnoxBuildworks/UI/Theme")

-- Blueprint access manager: default (everybody) scope, own-faction grant, a
-- "who has access" list with inline View/Build/Contribute editing + removal,
-- a "players you can add" candidate list, and manual username entry for
-- offline players. Only the owner (or an admin) can change anything; others
-- see a read-only view.

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local PAD = 12
local ROW_GAP = 8
local COMBO_H = math.max(26, FONT_HGT_SMALL + 10)
local BUTTON_H = math.max(26, FONT_HGT_SMALL + 10)
local LIST_ROW_H = FONT_HGT_SMALL * 2 + 14

---@class KBW.ACCESS_SCOPESModule
---@type KBW.ACCESS_SCOPESModule
local ACCESS_SCOPES = {
    { id = "private", label = "IGUI_KBW_ScopePrivate", fallback = "Private (only shared)" },
    { id = "view", label = "IGUI_KBW_ScopeView", fallback = "Everyone can view" },
    { id = "build", label = "IGUI_KBW_ScopeBuild", fallback = "Everyone can build" },
    { id = "contribute", label = "IGUI_KBW_ScopeContribute", fallback = "Everyone can contribute" }
}
local GRANT_LEVELS = {
    { id = "none", label = "IGUI_KBW_LevelNone", fallback = "None" },
    { id = "view", label = "IGUI_KBW_LevelView", fallback = "View" },
    { id = "build", label = "IGUI_KBW_LevelBuild", fallback = "Build" },
    { id = "contribute", label = "IGUI_KBW_LevelContribute", fallback = "Contribute" }
}
local SEGMENTS = {
    { id = "view", label = "IGUI_KBW_LevelView", fallback = "View" },
    { id = "build", label = "IGUI_KBW_LevelBuild", fallback = "Build" },
    { id = "contribute", label = "IGUI_KBW_LevelContribute", fallback = "Contribute" }
}

local function safeText(key, fallback)
    if not getText then return fallback or key end
    local text = getText(key)
    if text == key then return fallback or key end
    return text
end

local function measure(text)
    return getTextManager():MeasureStringX(UIFont.Small, tostring(text or ""))
end

local function makeButton(owner, x, y, w, h, title, callback, selected)
    local button = ISButton:new(x, y, w, h, title, owner, callback)
    button:initialise()
    Theme.applyButton(button, selected == true)
    button.borderColor = selected and Theme.accent or Theme.borderSoft
    button.backgroundColorMouseOver = Theme.selectedSoft
    owner:addChild(button)
    return button
end

local function applyCombo(combo)
    combo.background = true
    combo.backgroundColor = { r = Theme.surface.r, g = Theme.surface.g, b = Theme.surface.b, a = 0.96 }
    combo.backgroundColorMouseOver = {
        r = Theme.surfaceRaised.r,
        g = Theme.surfaceRaised.g,
        b = Theme.surfaceRaised.b,
        a = 0.98
    }
    combo.borderColor = { r = Theme.borderSoft.r, g = Theme.borderSoft.g, b = Theme.borderSoft.b, a = 0.95 }
    combo.textColor = Theme.text
end

local function comboData(combo, fallback)
    if not combo then return fallback end
    return combo:getOptionData(combo.selected) or fallback
end

local function selectComboData(combo, value)
    if not combo then return end
    for optionIndex = 1, combo:getOptionCount() do
        if combo:getOptionData(optionIndex) == value then
            combo.selected = optionIndex
            return
        end
    end
    combo.selected = 1
end

local function fillGrantCombo(combo)
    combo:clear()
    for levelIndex = 1, #GRANT_LEVELS do
        combo:addOptionWithData(
            safeText(GRANT_LEVELS[levelIndex].label, GRANT_LEVELS[levelIndex].fallback), GRANT_LEVELS[levelIndex].id
        )
    end
    combo.selected = 1
end

local function fillScopeCombo(combo)
    combo:clear()
    for scopeIndex = 1, #ACCESS_SCOPES do
        combo:addOptionWithData(
            safeText(ACCESS_SCOPES[scopeIndex].label, ACCESS_SCOPES[scopeIndex].fallback), ACCESS_SCOPES[scopeIndex].id
        )
    end
    combo.selected = 1
end

local function levelLabel(level)
    level = tostring(level or "none")
    for levelIndex = 1, #GRANT_LEVELS do
        if GRANT_LEVELS[levelIndex].id == level then
            return safeText(GRANT_LEVELS[levelIndex].label, GRANT_LEVELS[levelIndex].fallback)
        end
    end
    return tostring(level)
end

local function scopeAsLevel(scope)
    if scope == "private" then return "none" end
    return scope or "none"
end

local function currentFactionName(player)
    if not player or not Faction or not Faction.getPlayerFaction then return nil end
    local faction = Faction.getPlayerFaction(player)
    if faction and faction.getName then return tostring(faction:getName()) end
    return nil
end

-- Online player object for a username, or nil (offline / SP).
local function onlinePlayerByName(username)
    if not getOnlinePlayers then return nil end
    local players = getOnlinePlayers()
    if not players then return nil end
    for playerIndex = 0, players:size() - 1 do
        local player = players:get(playerIndex)
        if player and player.getUsername and tostring(player:getUsername()) == tostring(username) then
            return player
        end
    end
    return nil
end

local function isAdminName(username)
    local player = onlinePlayerByName(username)
    return player ~= nil and Blueprints.isAdmin(player)
end

-- What a non-ACL candidate would get today, mirroring Blueprints.accessLevel
-- (admins get contribute; then the user's faction grant; then the scope).
local function candidateEffectiveAccess(blueprint, username)
    if isAdminName(username) then
        return "contribute", safeText("IGUI_KBW_AccessAdmin", "Admin")
    end
    local access = blueprint and blueprint.access or {}
    local userFaction = Blueprints.factionNameForUser(username)
    if userFaction and access.factions and access.factions[userFaction] and access.factions[userFaction] ~= "none" then
        return access.factions[userFaction],
            string.format("%s: %s", safeText("IGUI_KBW_Faction", "Faction"), userFaction)
    end
    return scopeAsLevel(access.scope), safeText("IGUI_KBW_DefaultAccess", "Default access")
end

---@class KBWBlueprintAccessWindow: ISCollapsableWindow
KBWBlueprintAccessWindow = ISCollapsableWindow:derive("KBWBlueprintAccessWindow")

---@param player IsoPlayer
---@param blueprint KBW.Blueprint
---@return KBWBlueprintAccessWindow
function KBWBlueprintAccessWindow:new(owner, player, blueprint)
    -- Segment widths drive the ACL list width, which drives the window width.
    local segW = 0
    for segmentIndex = 1, #SEGMENTS do
        segW = math.max(segW, measure(safeText(SEGMENTS[segmentIndex].label, SEGMENTS[segmentIndex].fallback)))
    end
    segW = segW + 14
    local removeW = FONT_HGT_SMALL + 10
    local segTotal = segW * 3 + 4 * 2 + 6 + removeW
    local leftW = math.max(330, segTotal + 150)
    local rightW = math.max(230, measure(safeText("IGUI_KBW_FactionOwner", "Faction owner")) + 150)
    local width = PAD * 3 + leftW + rightW
    local listH = LIST_ROW_H * 6 + 4
    local o = ISCollapsableWindow:new(0, 0, width, 100)
    setmetatable(o, self)
    self.__index = self
    o.owner = owner
    o.player = player
    o.blueprintId = blueprint and blueprint.id or nil
    o.segW, o.removeW, o.segTotal = segW, removeW, segTotal
    o.leftW, o.rightW, o.listH = leftW, rightW, listH
    o.resizable = false
    o.title = safeText("IGUI_KBW_BlueprintAccessTitle", "Blueprint access")
    o.backgroundColor = Theme.backdrop
    o.borderColor = Theme.border
    o.moveWithMouse = true
    return o
end

function KBWBlueprintAccessWindow:blueprint()
    return Blueprints.get(self.player, self.blueprintId)
end

function KBWBlueprintAccessWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local top = self:titleBarHeight() + PAD

    -- Top rows: default (everybody) scope and own-faction grant, with the
    -- combo x derived from the wider of the two measured labels.
    local scopeLabel = safeText("IGUI_KBW_DefaultAccess", "Default access")
    local factionLabel = safeText("IGUI_KBW_MyFactionAccess", "My faction: %s")
    local labelW = math.max(measure(scopeLabel), measure(string.format(factionLabel, "WWWWWWWWWWWW")))
    local comboX = PAD + math.min(labelW, math.floor(self.width * 0.45)) + ROW_GAP
    local comboW = math.min(260, self.width - comboX - PAD)
    self.labelX, self.comboX = PAD, comboX
    self.scopeRowY = top
    self.factionRowY = top + COMBO_H + ROW_GAP

    self.scopeCombo = ISComboBox:new(comboX, self.scopeRowY, comboW, COMBO_H, self, self.onScopeChanged)
    self.scopeCombo:initialise()
    applyCombo(self.scopeCombo)
    fillScopeCombo(self.scopeCombo)
    self:addChild(self.scopeCombo)

    self.factionCombo = ISComboBox:new(comboX, self.factionRowY, comboW, COMBO_H, self, self.onFactionChanged)
    self.factionCombo:initialise()
    applyCombo(self.factionCombo)
    fillGrantCombo(self.factionCombo)
    self:addChild(self.factionCombo)

    -- Two columns: who has access (left, inline-editable) and who can be
    -- added (right).
    local headerY = self.factionRowY + COMBO_H + PAD
    local listY = headerY + FONT_HGT_SMALL + 6
    self.leftHeaderY, self.listY = headerY, listY
    local leftX = PAD
    local rightX = PAD * 2 + self.leftW
    self.leftX, self.rightX = leftX, rightX

    self.aclList = ISScrollingListBox:new(leftX, listY, self.leftW, self.listH)
    self.aclList:initialise()
    self.aclList:instantiate()
    self.aclList.itemheight = LIST_ROW_H
    self.aclList.drawBorder = true
    self.aclList.backgroundColor = Theme.surface
    self.aclList.borderColor = Theme.borderSoft
    self.aclList.doDrawItem = function (list, rowY, item, alt) return self:drawAclRow(list, rowY, item, alt) end
    self.aclList:setOnMouseDownFunction(
        self,
        function (target)
            target:onAclClicked()
        end
    )
    self:addChild(self.aclList)

    self.candidateList = ISScrollingListBox:new(rightX, listY, self.rightW, self.listH)
    self.candidateList:initialise()
    self.candidateList:instantiate()
    self.candidateList.itemheight = LIST_ROW_H
    self.candidateList.drawBorder = true
    self.candidateList.backgroundColor = Theme.surface
    self.candidateList.borderColor = Theme.borderSoft
    self.candidateList.doDrawItem = function (list, rowY, item, alt)
        return self:drawCandidateRow(list, rowY, item, alt)
    end
    if self.candidateList.setOnMouseDoubleClick then
        self.candidateList:setOnMouseDoubleClick(
            self,
            function (target)
                target:onAddSelected()
            end
        )
    end
    self:addChild(self.candidateList)

    -- Candidate controls stay directly under the candidate list. Manual
    -- username grants are a separate section under the ACL list so the two
    -- workflows do not share an ambiguously positioned level selector.
    local controlsY = listY + self.listH + ROW_GAP
    local grantHeaderY = controlsY
    local grantY = grantHeaderY + FONT_HGT_SMALL + 6
    self.grantHeaderY = grantHeaderY
    local levelW = 0
    for levelIndex = 1, #GRANT_LEVELS do
        levelW = math.max(levelW, measure(safeText(GRANT_LEVELS[levelIndex].label, GRANT_LEVELS[levelIndex].fallback)))
    end
    levelW = levelW + 40
    local addLabel = safeText("IGUI_KBW_AddSelected", "Add selected")
    local applyLabel = safeText("IGUI_KBW_ApplyPlayerAccess", "Apply")
    local addW = measure(addLabel) + 24
    local applyW = measure(applyLabel) + 24

    local candidateComboW = math.min(levelW, math.floor(self.rightW * 0.45))
    self.playerLevelCombo = ISComboBox:new(rightX, controlsY, candidateComboW, COMBO_H, self, nil)
    self.playerLevelCombo:initialise()
    applyCombo(self.playerLevelCombo)
    fillGrantCombo(self.playerLevelCombo)
    self:addChild(self.playerLevelCombo)

    self.addSelectedButton = makeButton(
        self, rightX + candidateComboW + ROW_GAP, controlsY, self.rightW - candidateComboW - ROW_GAP, COMBO_H, addLabel,
        self.onAddSelected
    )

    local manualComboW = math.min(levelW, 120)
    local entryW = self.leftW - manualComboW - applyW - ROW_GAP * 2
    self.playerEntry = ISTextEntryBox:new("", leftX, grantY, entryW, COMBO_H)
    self.playerEntry:initialise()
    self.playerEntry:instantiate()
    if self.playerEntry.setPlaceholderText then
        self.playerEntry:setPlaceholderText(safeText("IGUI_KBW_PlayerName", "Player username"))
    end
    self:addChild(self.playerEntry)

    self.manualLevelCombo = ISComboBox:new(leftX + entryW + ROW_GAP, grantY, manualComboW, COMBO_H, self, nil)
    self.manualLevelCombo:initialise()
    applyCombo(self.manualLevelCombo)
    fillGrantCombo(self.manualLevelCombo)
    self:addChild(self.manualLevelCombo)

    self.applyPlayerButton = makeButton(
        self, leftX + self.leftW - applyW, grantY, applyW, COMBO_H, applyLabel, self.onApplyPlayer
    )

    -- Footer: summary text (drawn in render) + close button.
    local footerY = grantY + COMBO_H + PAD
    self.footerY = footerY
    local closeLabel = safeText("IGUI_KBW_Close", "Close")
    local closeW = measure(closeLabel) + 32
    self.closeButton = makeButton(self, self.width - closeW - PAD, footerY, closeW, BUTTON_H, closeLabel, self.close)
    self:setHeight(footerY + BUTTON_H + PAD)
    self:setX(math.floor((getCore():getScreenWidth() - self.width) / 2))
    self:setY(math.floor((getCore():getScreenHeight() - self.height) / 2))

    self:syncFromBlueprint()
end

-- Right-aligned segment/remove boxes inside an ACL row; shared by drawing and
-- click hit-testing so they can never drift apart.
function KBWBlueprintAccessWindow:aclSegmentRects(list)
    local rects = {}
    local right = list.width - PAD
    -- The vertical scrollbar overlaps the row's right edge when visible.
    if list.vscroll and list.vscroll:isVisible() then right = right - 13 end
    rects.remove = { x1 = right - self.removeW, x2 = right }
    local x = right - self.removeW - 6
    for segmentIndex = #SEGMENTS, 1, -1 do
        rects[SEGMENTS[segmentIndex].id] = { x1 = x - self.segW, x2 = x }
        x = x - self.segW - 4
    end
    return rects
end

function KBWBlueprintAccessWindow:canManage()
    local blueprint = self:blueprint()
    return blueprint ~= nil and Blueprints.canManageAccess(self.player, blueprint)
end

---@param y number
---@param item table
function KBWBlueprintAccessWindow:drawAclRow(list, y, item, alt)
    local row = item.item
    local selected = list.selected == item.index
    local fill = selected and Theme.selected or (alt and Theme.surfaceRaised or Theme.surface)
    list:drawRect(0, y, list.width, item.height - 2, fill.a, fill.r, fill.g, fill.b)
    list:drawRectBorder(
        0, y, list.width, item.height - 2, Theme.borderSoft.a, Theme.borderSoft.r, Theme.borderSoft.g,
        Theme.borderSoft.b
    )
    list:drawText(tostring(row.label), 8, y + 4, Theme.text.r, Theme.text.g, Theme.text.b, 1, UIFont.Small)
    list:drawText(
        tostring(row.detail or ""), 8, y + 6 + FONT_HGT_SMALL, Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b,
        1, UIFont.Small
    )
    if row.kind == "owner" then
        local label = safeText("IGUI_KBW_AccessOwner", "Owner")
        list:drawText(
            label, list.width - PAD - measure(label), y + math.floor((item.height - FONT_HGT_SMALL) / 2), Theme.accent.r,
            Theme.accent.g, Theme.accent.b, 1, UIFont.Small
        )
        return y + item.height
    end
    local rects = self:aclSegmentRects(list)
    local manage = self:canManage()
    local segY = y + math.floor((item.height - 2 - (FONT_HGT_SMALL + 8)) / 2)
    local segH = FONT_HGT_SMALL + 8
    for segmentIndex = 1, #SEGMENTS do
        local segment = SEGMENTS[segmentIndex]
        local rect = rects[segment.id]
        local active = row.level == segment.id
        local editable = manage and (row.kind ~= "faction" or row.ownFaction == true)
        local border = active and Theme.accent or Theme.borderSoft
        if active then
            list:drawRect(rect.x1, segY, self.segW, segH, 0.35, Theme.accent.r, Theme.accent.g, Theme.accent.b)
        end
        list:drawRectBorder(rect.x1, segY, self.segW, segH, border.a, border.r, border.g, border.b)
        local textColor = active and Theme.text or (editable and Theme.textMuted or Theme.borderSoft)
        local label = safeText(segment.label, segment.fallback)
        list:drawText(
            label, rect.x1 + math.floor((self.segW - measure(label)) / 2), segY + 4, textColor.r, textColor.g,
            textColor.b, 1, UIFont.Small
        )
    end
    if manage then
        local rect = rects.remove
        list:drawRectBorder(
            rect.x1, segY, self.removeW, segH, Theme.borderSoft.a, Theme.borderSoft.r, Theme.borderSoft.g,
            Theme.borderSoft.b
        )
        local closeTexture = self.closeButtonTexture or getTexture("media/ui/inventoryPanes/Button_Close.png")
        local iconSize = math.min(segH - 6, self.removeW - 6)
        if closeTexture then
            list:drawTextureScaled(
                closeTexture, rect.x1 + math.floor((self.removeW - iconSize) / 2),
                segY + math.floor((segH - iconSize) / 2), iconSize, iconSize, 0.9, 1, 1, 1
            )
        end
    end
    return y + item.height
end

---@param y number
---@param item table
function KBWBlueprintAccessWindow:drawCandidateRow(list, y, item, alt)
    local row = item.item
    local selected = list.selected == item.index
    local fill = selected and Theme.selected or (alt and Theme.surfaceRaised or Theme.surface)
    list:drawRect(0, y, list.width, item.height - 2, fill.a, fill.r, fill.g, fill.b)
    list:drawRectBorder(
        0, y, list.width, item.height - 2, Theme.borderSoft.a, Theme.borderSoft.r, Theme.borderSoft.g,
        Theme.borderSoft.b
    )
    list:drawText(tostring(row.user), 8, y + 4, Theme.text.r, Theme.text.g, Theme.text.b, 1, UIFont.Small)
    list:drawText(
        tostring(row.detail or ""), 8, y + 6 + FONT_HGT_SMALL, Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b,
        1, UIFont.Small
    )
    local label = levelLabel(row.effective)
    list:drawText(
        label, list.width - PAD - measure(label), y + 4, Theme.accent.r, Theme.accent.g, Theme.accent.b, 1, UIFont.Small
    )
    return y + item.height
end

function KBWBlueprintAccessWindow:onAclClicked()
    if not self:canManage() then return end
    local item = self.aclList.items[self.aclList.selected]
    local row = item and item.item or nil
    if not row or row.kind == "owner" then return end
    local mx = self.aclList:getMouseX()
    local rects = self:aclSegmentRects(self.aclList)
    local blueprint = self:blueprint()
    if not blueprint then return end
    local changed = false
    if mx >= rects.remove.x1 and mx <= rects.remove.x2 then
        if row.kind == "faction" then
            changed = Blueprints.setFactionAccess(self.player, blueprint.id, row.faction, "none")
        else
            changed = Blueprints.setPlayerAccess(self.player, blueprint.id, row.user, "none")
        end
    else
        for segmentIndex = 1, #SEGMENTS do
            local segment = SEGMENTS[segmentIndex]
            local rect = rects[segment.id]
            if mx >= rect.x1 and mx <= rect.x2 and row.level ~= segment.id then
                if row.kind == "faction" then
                    if row.ownFaction == true then
                        changed = Blueprints.setFactionAccess(self.player, blueprint.id, row.faction, segment.id)
                    end
                else
                    changed = Blueprints.setPlayerAccess(self.player, blueprint.id, row.user, segment.id)
                end
                break
            end
        end
    end
    if changed then
        self:syncFromBlueprint()
        if self.owner and self.owner.refreshBlueprints then self.owner:refreshBlueprints() end
    end
end

function KBWBlueprintAccessWindow:onAddSelected()
    if not self:canManage() then return end
    local item = self.candidateList.items[self.candidateList.selected]
    local row = item and item.item or nil
    if not row then return end
    local blueprint = self:blueprint()
    if not blueprint then return end
    local level = comboData(self.playerLevelCombo, "view")
    if level == "none" then level = "view" end
    if Blueprints.setPlayerAccess(self.player, blueprint.id, row.user, level) then
        self:syncFromBlueprint()
        if self.owner and self.owner.refreshBlueprints then self.owner:refreshBlueprints() end
    end
end

function KBWBlueprintAccessWindow:onApplyPlayer()
    if not self:canManage() then return end
    local blueprint = self:blueprint()
    if not blueprint or not self.playerEntry then return end
    local username = self.playerEntry:getInternalText()
    if not username or username == "" then return end
    local level = comboData(self.manualLevelCombo, "none")
    if Blueprints.setPlayerAccess(self.player, blueprint.id, username, level) then
        if HaloTextHelper and HaloTextHelper.addText then
            HaloTextHelper.addText(self.player, safeText("IGUI_KBW_AccessUpdated", "Blueprint access updated"))
        end
        self.playerEntry:setText("")
        self:syncFromBlueprint()
        if self.owner and self.owner.refreshBlueprints then self.owner:refreshBlueprints() end
    end
end

function KBWBlueprintAccessWindow:onScopeChanged()
    if not self:canManage() then return end
    local blueprint = self:blueprint()
    if not blueprint then return end
    local scope = comboData(self.scopeCombo, "private")
    if Blueprints.setAccessScope(self.player, blueprint.id, scope) then
        self:syncFromBlueprint()
        if self.owner and self.owner.refreshBlueprints then self.owner:refreshBlueprints() end
    end
end

function KBWBlueprintAccessWindow:onFactionChanged()
    if not self:canManage() then return end
    local blueprint = self:blueprint()
    local faction = currentFactionName(self.player)
    if not blueprint or not faction then return end
    local level = comboData(self.factionCombo, "none")
    if Blueprints.setFactionAccess(self.player, blueprint.id, faction, level) then
        self:syncFromBlueprint()
        if self.owner and self.owner.refreshBlueprints then self.owner:refreshBlueprints() end
    end
end

function KBWBlueprintAccessWindow:syncFromBlueprint()
    local blueprint = self:blueprint()
    local isOwner = blueprint ~= nil and Blueprints.canManageAccess(self.player, blueprint)
    if self.scopeCombo then
        selectComboData(self.scopeCombo, blueprint and blueprint.access and blueprint.access.scope or "private")
        self.scopeCombo:setEnabled(isOwner == true)
    end
    local faction = currentFactionName(self.player)
    local factionLevel = blueprint and blueprint.access
        and blueprint.access.factions and faction
        and blueprint.access.factions[faction] or "none"
    if self.factionCombo then
        selectComboData(self.factionCombo, factionLevel or "none")
        self.factionCombo:setEnabled(isOwner == true and faction ~= nil)
    end
    if self.playerLevelCombo then self.playerLevelCombo:setEnabled(isOwner == true) end
    if self.manualLevelCombo then self.manualLevelCombo:setEnabled(isOwner == true) end
    if self.playerEntry then self.playerEntry:setEditable(isOwner == true) end
    Theme.setButtonEnabled(self.applyPlayerButton, isOwner == true)
    Theme.setButtonEnabled(self.addSelectedButton, isOwner == true)
    self:refreshAcl()
    self:refreshCandidates()
end

-- Left list: owner + every explicit grant (faction rows first, then player
-- rows), each showing its direct level for inline editing.
function KBWBlueprintAccessWindow:refreshAcl()
    if not self.aclList then return end
    local remembered = nil
    local selectedItem = self.aclList.items[self.aclList.selected]
    if selectedItem and selectedItem.item then
        remembered = tostring(selectedItem.item.kind) .. ":"
            .. tostring(selectedItem.item.user or selectedItem.item.faction)
    end
    self.aclList:clear()
    local blueprint = self:blueprint()
    if not blueprint then return end
    local access = blueprint.access or {}
    local rows = {}
    if blueprint.owner then
        rows[#rows + 1] = {
            kind = "owner",
            user = blueprint.owner,
            label = tostring(blueprint.owner),
            detail = safeText("IGUI_KBW_AccessOwner", "Owner"),
            level = "contribute"
        }
    end
    local ownFaction = currentFactionName(self.player)
    local factionRows = {}
    for name, level in pairs(access.factions or {}) do
        if level ~= "none" then
            factionRows[#factionRows + 1] = {
                kind = "faction",
                faction = name,
                label = string.format("%s: %s", safeText("IGUI_KBW_Faction", "Faction"), tostring(name)),
                detail = safeText("IGUI_KBW_FactionGrant", "Everyone in this faction"),
                level = level,
                ownFaction = ownFaction ~= nil and tostring(ownFaction) == tostring(name)
            }
        end
    end
    table.sort(factionRows, function (a, b) return tostring(a.faction) < tostring(b.faction) end)
    local playerRows = {}
    for username, level in pairs(access.players or {}) do
        if level ~= "none" then
            local userFaction = Blueprints.factionNameForUser(username)
            playerRows[#playerRows + 1] = {
                kind = "player",
                user = username,
                label = tostring(username),
                detail = userFaction and string.format("%s: %s", safeText("IGUI_KBW_Faction", "Faction"), userFaction)
                    or (onlinePlayerByName(username) and safeText("IGUI_KBW_OnlinePlayer", "Online")
                        or safeText("IGUI_KBW_OfflinePlayer", "Offline")),
                level = level
            }
        end
    end
    table.sort(playerRows, function (a, b) return tostring(a.user) < tostring(b.user) end)
    for rowIndex = 1, #factionRows do
        rows[#rows + 1] = factionRows[rowIndex]
    end
    for rowIndex = 1, #playerRows do
        rows[#rows + 1] = playerRows[rowIndex]
    end
    for rowIndex = 1, #rows do
        local item = self.aclList:addItem(rows[rowIndex].label, rows[rowIndex])
        if item then item.height = LIST_ROW_H end
        local key = tostring(rows[rowIndex].kind) .. ":" .. tostring(rows[rowIndex].user or rows[rowIndex].faction)
        if remembered ~= nil and key == remembered then self.aclList.selected = rowIndex end
    end
end

-- Right list: online players + own-faction members not already on the ACL
-- (and not the owner), with the access they would currently fall back to.
function KBWBlueprintAccessWindow:refreshCandidates()
    if not self.candidateList then return end
    self.candidateList:clear()
    local blueprint = self:blueprint()
    if not blueprint then return end
    local access = blueprint.access or {}
    local granted = {}
    for username, level in pairs(access.players or {}) do
        if level ~= "none" then granted[tostring(username)] = true end
    end
    if blueprint.owner then granted[tostring(blueprint.owner)] = true end
    local candidates, seen = {}, {}
    local function addCandidate(username, role)
        username = tostring(username or "")
        if username == "" or seen[username] or granted[username] then return end
        seen[username] = true
        local effective, source = candidateEffectiveAccess(blueprint, username)
        candidates[#candidates + 1] = { user = username, detail = role .. " - " .. source, effective = effective }
    end
    if getOnlinePlayers then
        local players = getOnlinePlayers()
        if players then
            for playerIndex = 0, players:size() - 1 do
                local player = players:get(playerIndex)
                if player and player.getUsername then
                    addCandidate(player:getUsername(), safeText("IGUI_KBW_OnlinePlayer", "Online"))
                end
            end
        end
    elseif getPlayer and getPlayer() and getPlayer().getUsername then
        addCandidate(getPlayer():getUsername(), safeText("IGUI_KBW_ThisPlayer", "This player"))
    end
    if Faction and Faction.getPlayerFaction then
        local faction = Faction.getPlayerFaction(self.player)
        if faction then
            if faction.getOwner then
                addCandidate(faction:getOwner(), safeText("IGUI_KBW_FactionOwner", "Faction owner"))
            end
            local members = faction.getPlayers and faction:getPlayers() or nil
            if members then
                for memberIndex = 0, members:size() - 1 do
                    addCandidate(members:get(memberIndex), safeText("IGUI_KBW_FactionMember", "Faction member"))
                end
            end
        end
    end
    table.sort(candidates, function (a, b) return tostring(a.user) < tostring(b.user) end)
    for candidateIndex = 1, #candidates do
        local item = self.candidateList:addItem(candidates[candidateIndex].user, candidates[candidateIndex])
        if item then item.height = LIST_ROW_H end
    end
end

function KBWBlueprintAccessWindow:render()
    ISCollapsableWindow.render(self)
    local labelY = self.scopeRowY + math.floor((COMBO_H - FONT_HGT_SMALL) / 2)
    self:drawText(
        safeText("IGUI_KBW_DefaultAccess", "Default access"), self.labelX, labelY, Theme.text.r, Theme.text.g,
        Theme.text.b, 1, UIFont.Small
    )
    local faction = currentFactionName(self.player)
    local factionText = faction and string.format(safeText("IGUI_KBW_MyFactionAccess", "My faction: %s"), faction)
        or safeText("IGUI_KBW_NoFactionAccess", "You are not in a faction")
    self:drawText(
        factionText, self.labelX, self.factionRowY + math.floor((COMBO_H - FONT_HGT_SMALL) / 2), Theme.text.r,
        Theme.text.g, Theme.text.b, 1, UIFont.Small
    )
    self:drawText(
        safeText("IGUI_KBW_PlayersWithAccess", "Players with access"), self.leftX, self.leftHeaderY, Theme.accent.r,
        Theme.accent.g, Theme.accent.b, 1, UIFont.Small
    )
    self:drawText(
        safeText("IGUI_KBW_AddPlayers", "Players you can add"), self.rightX, self.leftHeaderY, Theme.accent.r,
        Theme.accent.g, Theme.accent.b, 1, UIFont.Small
    )
    self:drawText(
        safeText("IGUI_KBW_GrantAccess", "Grant access"), PAD, self.grantHeaderY, Theme.accent.r, Theme.accent.g,
        Theme.accent.b, 1, UIFont.Small
    )
    if not self:canManage() then
        local note = safeText("IGUI_KBW_AccessReadOnly", "Only the owner or an admin can change access")
        self:drawText(
            note, PAD, self.footerY + math.floor((BUTTON_H - FONT_HGT_SMALL) / 2), Theme.textMuted.r, Theme.textMuted.g,
            Theme.textMuted.b, 1, UIFont.Small
        )
    end
end

function KBWBlueprintAccessWindow:close()
    ISCollapsableWindow.close(self)
    if self.owner and self.owner.accessWindow == self then self.owner.accessWindow = nil end
end

return KBWBlueprintAccessWindow
