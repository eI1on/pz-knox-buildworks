require "ISUI/ISButton"
require "ISUI/ISContextMenu"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTextEntryBox"
require "ISUI/ISRichTextPanel"
local Theme = require("KnoxBuildworks/UI/Theme")
local Blueprints = require("KnoxBuildworks/Planning/Blueprints")
local Workspace = {}

local names = {
    "blueprintList", "blueprintName", "renameButton", "newButton", "duplicateButton", "deleteButton",
    "activateButton", "pinBlueprintButton", "exportButton", "importButton", "copyJsonButton", "manageAccessButton",
    "totalList", "roomName", "drawRoomButton", "eraseRoomButton", "eraseButton", "gatherAreaButton",
    "buildToolButton", "buildAllButton", "stopToolButton", "stopQueueButton", "moveBlueprintButton",
    "roomList", "updateRoomButton", "deleteRoomButton", "placementList", "buildSelectedButton", "removeSelectedButton", "exitButton",
    "browseButton", "previewButton", "moreButton"
}

local function rect(control, x, y, width, height)
    if not control then return end
    control:setVisible(true)
    control:setX(x); control:setY(y)
    control:setWidth(math.max(1, width)); control:setHeight(math.max(1, height))
end

local function updateListScrollbar(list)
    if not list or not list.vscroll or not list:isVisible() then return end
    Theme.applyScrollbar(list.vscroll)
    local overflowing = list:getScrollHeight() > list.height
    list.vscroll:setVisible(overflowing)
    if overflowing then
        list.vscroll:setX(list.width - list.vscroll:getWidth())
        list.vscroll:setY(0)
        list.vscroll:setHeight(list.height)
        list:updateScrollbars()
    else
        list:setYScroll(0)
    end
end

local function makeButton(owner, key, callback)
    local title = key ~= "" and getText(key) or ""
    local button = ISButton:new(0, 0, 100, 28, title, owner, callback)
    button:initialise()
    Theme.applyButton(button, false)
    owner:addChild(button)
    return button
end

local function buttonMinimumWidth(button)
    return getTextManager():MeasureStringX(UIFont.Small, button.title or "") + 18
end

local function pairRows(left, right, width, gap)
    return buttonMinimumWidth(left) + buttonMinimumWidth(right) + gap <= width and 1 or 2
end

local function placePairTop(left, right, x, y, width, height, gap)
    if pairRows(left, right, width, gap) == 1 then
        local leftWidth = math.max(buttonMinimumWidth(left), math.floor((width - gap) / 2))
        leftWidth = math.min(leftWidth, width - gap - buttonMinimumWidth(right))
        rect(left, x, y, leftWidth, height)
        rect(right, x + leftWidth + gap, y, width - leftWidth - gap, height)
        return y + height + gap
    end
    rect(left, x, y, width, height)
    rect(right, x, y + height + gap, width, height)
    return y + (height + gap) * 2
end

local function placePairBottom(left, right, x, bottom, width, height, gap)
    if pairRows(left, right, width, gap) == 1 then
        local leftWidth = math.max(buttonMinimumWidth(left), math.floor((width - gap) / 2))
        leftWidth = math.min(leftWidth, width - gap - buttonMinimumWidth(right))
        rect(left, x, bottom - height, leftWidth, height)
        rect(right, x + leftWidth + gap, bottom - height, width - leftWidth - gap, height)
        return bottom - height - gap
    end
    rect(right, x, bottom - height, width, height)
    rect(left, x, bottom - height * 2 - gap, width, height)
    return bottom - (height + gap) * 2
end

function Workspace.create(owner, roomColors, opacityValues)
    local buttons = {
        {"renameButton", "IGUI_KBW_Rename", "onRenameBlueprint"},
        {"newButton", "IGUI_KBW_NewShort", "onNewBlueprint"},
        {"duplicateButton", "IGUI_KBW_Duplicate", "onDuplicateBlueprint"},
        {"deleteButton", "IGUI_KBW_Delete", "onDeleteBlueprint"},
        {"activateButton", "IGUI_KBW_ActivateBlueprint", "onActivateBlueprint"},
        {"pinBlueprintButton", "IGUI_KBW_PinBlueprint", "onPinBlueprint"},
        {"exportButton", "IGUI_KBW_ExportJSON", "onExportBlueprint"},
        {"importButton", "IGUI_KBW_Import", "onImportBlueprint"},
        {"copyJsonButton", "IGUI_KBW_CopyBlueprintJSON", "onCopyBlueprintJSON"},
        {"drawRoomButton", "IGUI_KBW_DrawRoom", "onDrawRoom"},
        {"eraseRoomButton", "IGUI_KBW_EraseRoomTool", "onEraseRoomTool"},
        {"eraseButton", "IGUI_KBW_EraseTool", "onEraseTool"},
        {"gatherAreaButton", "IGUI_KBW_GatherArea", "onGatherArea"},
        {"buildToolButton", "IGUI_KBW_BuildTool", "onBuildTool"},
        {"buildAllButton", "IGUI_KBW_BuildAll", "onBuildAll"},
        {"stopToolButton", "IGUI_KBW_StopTool", "onStopTool"},
        {"stopQueueButton", "IGUI_KBW_StopQueue", "onStopQueue"},
        {"moveBlueprintButton", "IGUI_KBW_MoveBlueprintTool", "onMoveBlueprint"},
        {"updateRoomButton", "IGUI_KBW_UpdateRoom", "onUpdateRoom"},
        {"deleteRoomButton", "IGUI_KBW_DeleteRoom", "onDeleteRoom"},
        {"buildSelectedButton", "IGUI_KBW_BuildPlacement", "onBuildSelected"},
        {"removeSelectedButton", "IGUI_KBW_RemoveSelectedPiece", "onRemoveSelectedPlacement"},
        {"exitButton", "IGUI_KBW_ClosePlanning", "onExit"},
        {"levelDownButton", "IGUI_KBW_FloorDown", "onLevelDown"},
        {"levelUpButton", "IGUI_KBW_FloorUp", "onLevelUp"},
        {"usePlayerLevelButton", "IGUI_KBW_UsePlayerLevel", "onUsePlayerLevel"},
        {"manageAccessButton", "IGUI_KBW_ManageAccess", "onManageAccess"},
        {"previewButton", "IGUI_KBW_PreviewBlueprint", "onPreviewBlueprint"}
    }
    for index = 1, #buttons do
        local entry = buttons[index]
        if not owner[entry[1]] then owner[entry[1]] = makeButton(owner, entry[2], owner[entry[3]]) end
    end
    local lists = {
        {"blueprintList", "drawBlueprintRow", "onBlueprintSelected"},
        {"placementList", "drawPlacementRow", "onPlacementSelected"},
        {"roomList", "drawRoomRow", "onRoomSelected"}, {"totalList", "drawTotalRow"}
    }
    for index = 1, #lists do
        local entry = lists[index]
        if not owner[entry[1]] then
            local list = ISScrollingListBox:new(0, 0, owner.width - 24, 100)
            list:initialise(); list:instantiate()
            list.backgroundColor = Theme.color(Theme.surface)
            list.borderColor = Theme.color(Theme.borderSoft)
            if list.setScrollChildren then list:setScrollChildren(false) end
            list.useStencilForChildren = false
            list.doDrawItem = function(control, y, item, alt) return owner[entry[2]](owner, control, y, item, alt) end
            if entry[3] then list:setOnMouseDownFunction(owner, owner[entry[3]]) end
            owner[entry[1]] = list
            owner:addChild(list)
        end
    end
    local textEntries = {"blueprintName", "roomName"}
    for entryIndex = 1, #textEntries do
        local name = textEntries[entryIndex]
        if not owner[name] then
            local entry = ISTextEntryBox:new("", 0, 0, 220, 28)
            entry:initialise(); entry:instantiate()
            owner[name] = entry
            owner:addChild(entry)
        end
    end
    owner.colorButtons = owner.colorButtons or {}
    if #owner.colorButtons == 0 then
        for index = 1, #(roomColors or {}) do
            local color = roomColors[index]
            local button = makeButton(owner, "", function(self) self:onPickColor(index) end)
            button:setTitle("")
            button.backgroundColor = { r = color.r, g = color.g, b = color.b, a = 1 }
            button.backgroundColorMouseOver = {
                r = math.min(1, color.r + 0.12), g = math.min(1, color.g + 0.12),
                b = math.min(1, color.b + 0.12), a = 1
            }
            Theme.lockButtonColors(button)
            owner.colorButtons[#owner.colorButtons + 1] = button
        end
    end
    owner.opacityButtons = owner.opacityButtons or {}
    if #owner.opacityButtons == 0 then
        for index = 1, #(opacityValues or {}) do
            local button = makeButton(owner, "", function(self) self:onOpacity(index) end)
            button:setTitle(tostring(math.floor(opacityValues[index] * 100)) .. "%")
            owner.opacityButtons[#owner.opacityButtons + 1] = button
        end
    end
    local summary = ISRichTextPanel:new(0, 0, owner.width - 24, 60)
    summary:initialise(); summary:instantiate()
    summary.autosetheight, summary.clip, summary.background = false, true, false
    summary.defaultFont = UIFont.Small
    summary:setMargins(0, 2, 18, 2)
    summary:addScrollBars()
    if Theme.applyScrollbar then Theme.applyScrollbar(summary.vscroll) end
    owner.workspaceSummary = summary
    owner:addChild(summary)
    owner.workspaceTab = "plans"
    owner.workspaceTabs = {}
    local tabs = {{"plans", "IGUI_KBW_Plans"}, {"pieces", "IGUI_KBW_PiecesTab"},
        {"rooms", "IGUI_KBW_Rooms"}, {"supplies", "IGUI_KBW_SuppliesTab"}}
    for index = 1, #tabs do
        local entry = tabs[index]
        local button = makeButton(owner, entry[2], function(self)
            self.workspaceTab = entry[1]
            Workspace.layout(self)
            self:refreshRooms(); self:refreshPlacements(); self:refreshTotals()
        end)
        button.tabId = entry[1]
        owner.workspaceTabs[#owner.workspaceTabs + 1] = button
    end
    owner.browseButton = makeButton(owner, "IGUI_KBW_AddPieces", function(self) self:onBrowsePieces() end)
    owner.moreButton = makeButton(owner, "IGUI_KBW_BlueprintActions", function(self)
        local menu = ISContextMenu.get(self.player:getPlayerNum(), getMouseX(), getMouseY())
        local actions = {
            {"IGUI_KBW_Duplicate", self.onDuplicateBlueprint}, {"IGUI_KBW_PinBlueprint", self.onPinBlueprint},
            {"IGUI_KBW_ManageAccess", self.onManageAccess}, {"IGUI_KBW_ExportJSON", self.onExportBlueprint},
            {"IGUI_KBW_Import", self.onImportBlueprint}, {"IGUI_KBW_CopyBlueprintJSON", self.onCopyBlueprintJSON},
            {"IGUI_KBW_Delete", self.onDeleteBlueprint}
        }
        local blueprint = self:selectedBlueprint()
        for index = 1, #actions do
            local action = actions[index]
            local option = menu:addOption(getText(action[1]), self, action[2])
            if action[2] ~= self.onImportBlueprint then option.notAvailable = blueprint == nil end
            if action[2] == self.onDeleteBlueprint then
                option.notAvailable = not blueprint or not Blueprints.isOwner(self.player, blueprint)
            end
        end
    end)
    owner.exitButton:setTitle(getText("IGUI_KBW_ClosePlanning"))
    Workspace.layout(owner)
end

function Workspace.layout(owner)
    if not owner.workspaceTabs then return end
    local font = getTextManager():getFontHeight(UIFont.Small)
    local height, gap, pad = math.max(28, font + 12), 6, 12
    local width = owner.width - pad * 2
    local bottom = owner.height - pad
    for index = 1, #names do
        local control = owner[names[index]]
        if control then control:setVisible(false) end
    end
    for index = 1, #owner.colorButtons do owner.colorButtons[index]:setVisible(false) end
    for index = 1, #owner.opacityButtons do owner.opacityButtons[index]:setVisible(false) end
    owner.workspaceLabels = {}
    owner.colorHintX = nil
    local labels = owner.workspaceLabels
    local blueprint = owner:selectedBlueprint()
    local title = tostring(blueprint and blueprint.name or getText("IGUI_KBW_NoBlueprintSelected")):gsub("<", "["):gsub(">", "]")
    local summary = owner.workspaceSummary
    rect(summary, pad, 8, width, 60)
    local text = getText("IGUI_KBW_PlanningMode") .. " <LINE> " .. title
    if owner.workspaceSummaryText ~= text then
        owner.workspaceSummaryText = text
        summary:setText(text); summary:paginate(); summary:setYScroll(0)
    end
    if summary.vscroll then
        summary.vscroll:setVisible(summary:getScrollHeight() > summary.height)
    end
    local y = 72
    local tabWidth = math.floor((width - gap * 3) / 4)
    local twoRows = false
    for index = 1, #owner.workspaceTabs do
        if getTextManager():MeasureStringX(UIFont.Small, owner.workspaceTabs[index].title) + 16 > tabWidth then twoRows = true end
    end
    local columns = twoRows and 2 or 4
    tabWidth = math.floor((width - gap * (columns - 1)) / columns)
    for index = 1, #owner.workspaceTabs do
        local button = owner.workspaceTabs[index]
        rect(button, pad + ((index - 1) % columns) * (tabWidth + gap), y + math.floor((index - 1) / columns) * (height + gap), tabWidth, height)
        Theme.applyActionButton(button, true, button.tabId == owner.workspaceTab)
    end
    y = y + (twoRows and 2 or 1) * (height + gap)
    rect(owner.levelDownButton, pad, y, 38, height)
    rect(owner.levelUpButton, pad + 44, y, 38, height)
    owner.levelLabelX, owner.workspaceLevelY = pad + 90, y + 6
    local levelWidth = math.max(112, getTextManager():MeasureStringX(UIFont.Small, owner.usePlayerLevelButton.title) + 16)
    rect(owner.usePlayerLevelButton, pad + width - levelWidth, y, levelWidth, height)
    y = y + height + gap

    bottom = placePairBottom(owner.stopToolButton, owner.exitButton, pad, bottom, width, height, gap)
    local tab = owner.workspaceTab
    if tab == "plans" then
        local showFileActions = owner.height >= 800
        local actionRows = 4 + pairRows(owner.newButton, owner.duplicateButton, width, gap)
            + pairRows(owner.pinBlueprintButton, owner.manageAccessButton, width, gap)
            + pairRows(owner.activateButton, owner.browseButton, width, gap)
            + (showFileActions and (pairRows(owner.exportButton, owner.importButton, width, gap)
                + pairRows(owner.copyJsonButton, owner.deleteButton, width, gap)) or 1)
        local listHeight = math.max(60, bottom - y - (height + gap) * actionRows - font - 8)
        rect(owner.blueprintList, pad, y, width, listHeight)
        y = y + listHeight + gap
        local renameWidth = math.max(78, getTextManager():MeasureStringX(UIFont.Small, owner.renameButton.title) + 16)
        rect(owner.blueprintName, pad, y, width - renameWidth - gap, height)
        rect(owner.renameButton, pad + width - renameWidth, y, renameWidth, height)
        y = y + height + gap
        y = placePairTop(owner.newButton, owner.duplicateButton, pad, y, width, height, gap)
        y = placePairTop(owner.pinBlueprintButton, owner.manageAccessButton, pad, y, width, height, gap)
        y = placePairTop(owner.activateButton, owner.browseButton, pad, y, width, height, gap)
        rect(owner.previewButton, pad, y, width, height)
        y = y + height + gap
        if showFileActions then
            y = placePairTop(owner.exportButton, owner.importButton, pad, y, width, height, gap)
            y = placePairTop(owner.copyJsonButton, owner.deleteButton, pad, y, width, height, gap)
        else
            rect(owner.moreButton, pad, y, width, height)
            y = y + height + gap
        end
        labels[#labels + 1] = {getText("IGUI_KBW_GhostOpacity"), pad, y}
        y = y + font + 6
        local opacityWidth = math.floor((width - gap * (#owner.opacityButtons - 1)) / #owner.opacityButtons)
        for index = 1, #owner.opacityButtons do rect(owner.opacityButtons[index], pad + (index - 1) * (opacityWidth + gap), y, opacityWidth, height) end
    elseif tab == "pieces" then
        rect(owner.browseButton, pad, y, width, height)
        y = y + height + gap
        y = placePairTop(owner.buildToolButton, owner.eraseButton, pad, y, width, height, gap)
        y = placePairTop(owner.moveBlueprintButton, owner.removeSelectedButton, pad, y, width, height, gap)
        bottom = placePairBottom(owner.buildSelectedButton, owner.buildAllButton, pad, bottom, width, height, gap)
        rect(owner.placementList, pad, y, width, bottom - y)
    elseif tab == "rooms" then
        rect(owner.roomName, pad, y, width, height)
        y = y + height + gap
        local columns = math.max(1, math.floor((width + gap) / 30))
        for index = 1, #owner.colorButtons do
            rect(owner.colorButtons[index], pad + ((index - 1) % columns) * 30, y + math.floor((index - 1) / columns) * 30, 24, 24)
        end
        y = y + math.ceil(#owner.colorButtons / columns) * 30 + gap
        y = placePairTop(owner.drawRoomButton, owner.eraseRoomButton, pad, y, width, height, gap)
        bottom = placePairBottom(owner.updateRoomButton, owner.deleteRoomButton, pad, bottom, width, height, gap)
        rect(owner.roomList, pad, y, width, bottom - y)
    else
        rect(owner.gatherAreaButton, pad, y, width, height)
        y = y + height + gap
        bottom = placePairBottom(owner.buildAllButton, owner.stopQueueButton, pad, bottom, width, height, gap)
        rect(owner.totalList, pad, y, width, bottom - y)
    end
    updateListScrollbar(owner.blueprintList)
    updateListScrollbar(owner.placementList)
    updateListScrollbar(owner.roomList)
    updateListScrollbar(owner.totalList)
    owner:updateAccessControls()
end

function Workspace.render(owner)
    local color = Theme.text
    local blueprint = owner:selectedBlueprint()
    owner:drawText(getText("IGUI_KBW_BlueprintLevel", tostring(blueprint and blueprint.level or math.floor(owner.player:getZ()))),
        owner.levelLabelX, owner.workspaceLevelY, color.r, color.g, color.b, 1, UIFont.Small)
    for index = 1, #(owner.workspaceLabels or {}) do
        local entry = owner.workspaceLabels[index]
        owner:drawText(entry[1], entry[2], entry[3], Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 1, UIFont.Small)
    end
end

return Workspace
