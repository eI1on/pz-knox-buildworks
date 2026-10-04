require "ISUI/ISRichTextPanel"
require "ISUI/ISButton"

local Theme = require("KnoxBuildworks/UI/Theme")
local VirtualListBox = require("KnoxBuildworks/UI/VirtualListBox")
local I18n = require("KnoxBuildworks/I18n")
local Groups = require("KnoxBuildworks/Definitions/Groups")
local Info = require("KnoxBuildworks/UI/BuildableInfo")
local Icons = require("KnoxBuildworks/UI/IconResolver")
local WallFinishes = require("KnoxBuildworks/Validation/WallFinishes")
local Options = require("KnoxBuildworks/Options")
local Readiness = require("KnoxBuildworks/UI/CatalogReadiness")
local Workspace = {}

local function wrap(text, width)
    local lines, line = {}, ""
    for word in tostring(text):gmatch("%S+") do
        local candidate = line == "" and word or line .. " " .. word
        if line ~= "" and getTextManager():MeasureStringX(UIFont.Small, candidate) > width then
            lines[#lines + 1], line = line, word
        else
            line = candidate
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return lines
end

local function rect(control, x, y, width, height)
    control:setX(x)
    control:setY(y)
    control:setWidth(math.max(1, width))
    control:setHeight(math.max(1, height))
end

local function button(owner, key, callback)
    local control = ISButton:new(0, 0, 80, 28, getText(key), owner, callback)
    control:initialise()
    Theme.applyButton(control)
    owner:addChild(control)
    return control
end

local function updateListScrollbar(list)
    if not list or not list.vscroll then return end
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

local function plain(text)
    return tostring(text or ""):gsub("<", "["):gsub(">", "]"):gsub("\n", " <LINE> ")
end

function Workspace.create(owner)
    owner.workspace = true
    owner.filtersOpen = true
    owner.workspaceTab = "all"
    owner.filtersButton = button(owner, "IGUI_KBW_Filters", function(self)
        self.filtersOpen = not self.filtersOpen
        self:layout()
    end)
    owner.filtersButton:setVisible(false)
    owner.clearFiltersButton = button(owner, "IGUI_KBW_ClearFilters", owner.onClearFilters)
    owner.clearFiltersButton:setTooltip(getText("Tooltip_KBW_ClearFilters"))
    owner.readyButton = button(owner, "IGUI_KBW_ReadyToBuild", function(self)
        self.readyOnly = not self.readyOnly
        Readiness.reset(self)
        self.readyButton:setTitle(getText("IGUI_KBW_ReadyToBuild"))
        Theme.applyActionButton(self.readyButton, true, self.readyOnly)
        self:refreshGrid()
    end)
    owner.readyButton:setTooltip(getText("Tooltip_KBW_ReadyFilter"))
    owner.materialsTab = button(owner, "IGUI_KBW_MaterialsShort", function(self)
        self.workspaceTab = "materials"
        self:layout()
    end)
    owner.skillsTab = button(owner, "IGUI_KBW_SkillsShort", function(self)
        self.workspaceTab = "skills"
        self:layout()
    end)
    owner.materialsTab:setTooltip(getText("IGUI_KBW_MaterialsTools"))
    owner.skillsTab:setTooltip(getText("IGUI_KBW_SkillsKnowledge"))
    local list = VirtualListBox:new(0, 0, 180, 300)
    list:initialise()
    list:instantiate()
    list.font = UIFont.Small
    list.itemheight = getTextManager():getFontHeight(UIFont.Small) + 14
    list.backgroundColor = Theme.color(Theme.surface)
    list.borderColor = Theme.color(Theme.borderSoft)
    list.selectionColor = Theme.color(Theme.selected)
    list.drawBorder = true
    list:setOnMouseDownFunction(owner, function(self, item)
        self:onCategory({internal = item.id})
    end)
    owner.categoryList = list
    owner:addChild(list)
    local summary = ISRichTextPanel:new(0, 0, 240, 120)
    summary:initialise()
    summary:instantiate()
    summary.autosetheight = false
    summary.clip = true
    summary.background = false
    summary.defaultFont = UIFont.Small
    summary:setMargins(4, 2, 18, 4)
    summary:addScrollBars()
    if Theme.applyScrollbar then Theme.applyScrollbar(summary.vscroll) end
    owner.recipeSummary = summary
    owner:addChild(summary)
    owner.sizeButton:setVisible(true)
end

function Workspace.layout(owner, top, liveResize)
    local font = getTextManager():getFontHeight(UIFont.Small)
    local control = math.max(28, font + 10)
    local bottom = owner.height - owner:resizeWidgetHeight() - 8
    local compact = owner.compact == true
    if compact and owner.ingredientDrawer and owner.ingredientDrawer:isVisible() then
        owner.ingredientDrawer:setVisible(false)
    end
    local detailWidth = compact and 0 or math.max(310, math.min(400, math.floor(owner.width * .35)))
    local leftWidth = compact and math.max(138, math.min(168, math.floor(owner.width * .25)))
        or math.max(150, math.min(205, math.floor(owner.width * .19)))
    local normalDetailX = compact and owner.width - 10 or owner.width - detailWidth - 10
    local drawerVisible = not compact and owner.ingredientDrawer and owner.ingredientDrawer:isVisible()
    local drawerWidth = drawerVisible and math.max(310, math.min(360, math.floor(owner.width * .25))) or 0
    if drawerVisible then
        local minimumGridWidth = 190
        local requiredWidth = leftWidth + 30 + minimumGridWidth + detailWidth + 8 + drawerWidth + 10
        local overflow = requiredWidth - owner.width
        if overflow > 0 then
            local detailShrink = math.min(overflow, math.max(0, detailWidth - 250))
            detailWidth = detailWidth - detailShrink
            overflow = overflow - detailShrink
            local drawerShrink = math.min(overflow, math.max(0, drawerWidth - 250))
            drawerWidth = drawerWidth - drawerShrink
            overflow = overflow - drawerShrink
            if overflow > 0 then leftWidth = math.max(138, leftWidth - overflow) end
        end
    end
    local drawerX = owner.width - drawerWidth - 10
    local sideDetailX = drawerX - detailWidth - 8
    local drawerBesideInspector = drawerVisible
    local detailX = drawerBesideInspector and sideDetailX or normalDetailX
    local listX, listWidth = leftWidth + 20, detailX - leftWidth - 30
    owner.inspectorX = compact and owner.width or detailX - 8
    owner.inspectorWidth = compact and 0 or detailWidth + 16
    owner.drawerBesideInspector = drawerBesideInspector
    owner.workspaceLabels = {}
    local labels = owner.workspaceLabels
    local y = top + 8
    local headerDetailWidth = compact and 170 or (drawerVisible and drawerWidth or detailWidth)
    local headerDetailX = compact and owner.width - headerDetailWidth - 10
        or (drawerVisible and drawerX or normalDetailX)
    rect(owner.search, 10, y, headerDetailX - 20, control)
    owner.filtersButton:setVisible(false)
    local plansWidth = headerDetailWidth - 80
    rect(owner.plansButton, headerDetailX, y, plansWidth, control)
    rect(owner.appearanceButton, headerDetailX + plansWidth + 4, y, 34, control)
    rect(owner.sizeButton, headerDetailX + headerDetailWidth - 34, y, 34, control)
    owner.sizeButton:setVisible(true)
    owner.sizeButton:setTitle(compact and ">" or "<")
    y = y + control + 8
    local scopes = {owner.scopeAll, owner.scopeFav, owner.scopeRecent, owner.viewButton}
    local sx, scopeY = 10, y
    for index = 1, #scopes do
        local widget = scopes[index]
        local width = index == 4 and 32 or math.max(36, getTextManager():MeasureStringX(UIFont.Small, widget.title or "") + 16)
        width = math.min(width, math.max(40, detailX - 20))
        if sx > 10 and sx + width > detailX - 10 then
            sx, scopeY = 10, scopeY + control + 4
        end
        rect(widget, sx, scopeY, width, control)
        widget:setVisible(true)
        sx = sx + width + 4
    end
    local quickRight = detailX - 10
    owner.filtersOpen = true
    owner.clearFiltersButton:setVisible(true)
    local clearWidth = math.max(
        94, getTextManager():MeasureStringX(UIFont.Small, owner.clearFiltersButton.title) + 18
    )
    clearWidth = math.min(112, clearWidth)
    local readyWidth = math.min(150, math.max(92, getTextManager():MeasureStringX(UIFont.Small, owner.readyButton.title) + 18))
    local quickY = compact and scopeY + control + 4 or scopeY
    rect(owner.readyButton, quickRight - clearWidth - readyWidth - 4, quickY, readyWidth, control)
    rect(owner.clearFiltersButton, quickRight - clearWidth, quickY, clearWidth, control)
    local filterTop = quickY + control + 6
    local filterWidgets = {owner.searchMode, owner.sortCombo, owner.materialFilter, owner.skillFilter}
    for index = 1, #filterWidgets do filterWidgets[index]:setVisible(true) end
    owner.subcategoryFilter:setVisible(false)
    owner.showAllTickBox:setVisible(true)
    local filterAreaWidth = detailX - 20
    local tickLabel = I18n.text and I18n.text("IGUI_KBW_ShowAllQualities", "All qualities") or "All qualities"
    local tickWidth = math.min(128, math.max(92, getTextManager():MeasureStringX(UIFont.Small, tickLabel) + 30))
    local listTop
    if compact then
        local firstWidth = math.floor((filterAreaWidth - 4) / 2)
        rect(filterWidgets[1], 10, filterTop, firstWidth, control)
        rect(filterWidgets[2], 14 + firstWidth, filterTop, filterAreaWidth - firstWidth - 4, control)
        local secondTop = filterTop + control + 4
        local secondWidth = math.floor((filterAreaWidth - tickWidth - 8) / 2)
        rect(filterWidgets[3], 10, secondTop, secondWidth, control)
        rect(filterWidgets[4], 14 + secondWidth, secondTop, secondWidth, control)
        rect(owner.showAllTickBox, 18 + secondWidth * 2, secondTop, tickWidth, control)
        listTop = secondTop + control + 8
    else
        local comboWidth = math.floor((filterAreaWidth - tickWidth - 16) / #filterWidgets)
        for index = 1, #filterWidgets do
            rect(filterWidgets[index], 10 + (index - 1) * (comboWidth + 4), filterTop, comboWidth, control)
        end
        rect(owner.showAllTickBox, 10 + #filterWidgets * (comboWidth + 4), filterTop, tickWidth, control)
        listTop = filterTop + control + 8
    end
    local labelHeight = font + 5
    local navHeight = bottom - listTop
    local categoryHeight = math.max(70, math.floor((navHeight - labelHeight * 2 - 8) * .55))
    labels[#labels + 1] = {getText("IGUI_KBW_Categories"), 10, listTop}
    rect(owner.categoryList, 10, listTop + labelHeight, leftWidth, categoryHeight)
    if owner.categoryList.setScrollChildren then owner.categoryList:setScrollChildren(false) end
    owner.categoryList.useStencilForChildren = false
    local categoryKey = table.concat(owner.categories or {}, "\t")
    if owner.workspaceCategoryKey ~= categoryKey then
        owner.workspaceCategoryKey = categoryKey
        local rows = {{name = getText("IGUI_KBW_AllCategories"), definition = {id = "All"}}}
        for index = 1, #owner.categories do
            local category = owner.categories[index]
            rows[#rows + 1] = {name = I18n.category(category), definition = {id = category}}
        end
        owner.categoryList:replaceItems(rows)
        for index = 1, #owner.categoryList.items do
            owner.categoryList.items[index].tooltip = owner.categoryList.items[index].text
        end
    end
    owner.categoryList.selected = 1
    for index = 1, #owner.categoryList.items do
        local item = owner.categoryList.items[index]
        if owner.selectedCategories[item.item.id] then owner.categoryList.selected = index end
    end
    updateListScrollbar(owner.categoryList)
    local subcategoryLabelY = listTop + labelHeight + categoryHeight + 6
    labels[#labels + 1] = {getText("IGUI_KBW_Subcategories"), 10, subcategoryLabelY}
    rect(owner.compactGroups, 10, subcategoryLabelY + labelHeight, leftWidth,
        math.max(30, bottom - subcategoryLabelY - labelHeight))
    owner.compactGroups:setVisible(true)
    if owner.compactGroups.setScrollChildren then owner.compactGroups:setScrollChildren(false) end
    owner.compactGroups.useStencilForChildren = false
    updateListScrollbar(owner.compactGroups)
    owner.categoryPrev:setVisible(false)
    owner.categoryNext:setVisible(false)
    for index = 1, #owner.categoryButtons do owner.categoryButtons[index]:setVisible(false) end
    local actionY = bottom - control
    local gridBottom = compact and actionY - 6 or bottom
    rect(owner.grid, listX, listTop, listWidth, gridBottom - listTop)
    if owner.grid.setCompactMode then owner.grid:setCompactMode(compact) end
    if not liveResize then owner.grid:onResize() end

    local definition, stage = owner:effectiveDefinition(), owner:selectedStage()
    local base = Groups.resolveDefinition(owner.selected, owner:rawSelectedStage()) or owner.selected
    local summaryY = top + control + 16
    local previewWidth = 76
    local summaryHeight = math.max(78, math.min(132, math.floor(owner.height * .17)))
    local showInspector = not compact
    owner.workspacePreview = showInspector
        and {x = detailX, y = summaryY, width = previewWidth, height = summaryHeight} or nil
    if showInspector then
        rect(owner.recipeSummary, detailX + previewWidth + 6, summaryY, detailWidth - previewWidth - 6, summaryHeight)
    end
    owner.recipeSummary:setVisible(showInspector)
    local text = definition and ("<SIZE:medium> " .. plain(I18n.definitionName(definition)) .. " <LINE> <SIZE:small> " .. plain(Info.description(definition, stage))) or getText("IGUI_KBW_SelectPiece")
    if stage then
        text = text .. " <LINE> " .. plain(Info.dimensionsText(stage))
        local capacities = Info.capacityLines(stage)
        for index = 1, #capacities do text = text .. " <LINE> " .. plain(capacities[index]) end
        local metadata = owner.recipeMetadata and owner:recipeMetadata() or {}
        for index = 1, #metadata do text = text .. " <LINE> " .. plain(metadata[index].text) end
    end
    if showInspector and (text ~= owner.workspaceSummaryText or owner.workspaceSummaryWidth ~= owner.recipeSummary.width
        or owner.workspaceSummaryHeight ~= owner.recipeSummary.height) then
        owner.workspaceSummaryText, owner.workspaceSummaryWidth = text, owner.recipeSummary.width
        owner.workspaceSummaryHeight = owner.recipeSummary.height
        owner.recipeSummary:setText(text)
        owner.recipeSummary:setMargins(4, 2, 6, 4)
        owner.recipeSummary:paginate()
        if owner.recipeSummary.vscroll then
            local overflowing = owner.recipeSummary:getScrollHeight() > owner.recipeSummary.height
            owner.recipeSummary.vscroll:setVisible(overflowing)
            if overflowing then
                owner.recipeSummary:setMargins(4, 2, 18, 4)
                owner.recipeSummary:paginate()
            end
        end
        owner.recipeSummary:setYScroll(0)
    end
    y = summaryY + summaryHeight + 8
    owner.stage:setVisible(false)
    local stageCount = owner:stageCountForSelection()
    owner.stagePrevButton:setVisible(showInspector and stageCount > 1)
    owner.stageNextButton:setVisible(showInspector and stageCount > 1)
    owner.favoriteButton:setVisible(showInspector)
    owner.recipePinButton:setVisible(showInspector)
    if showInspector then
        rect(owner.favoriteButton, detailX, y, control, control)
        rect(owner.recipePinButton, detailX + control + 4, y, control, control)
    end
    if showInspector and stageCount > 1 then
        local arrowWidth = control
        local carouselX = detailX + control * 2 + 12
        local carouselWidth = detailWidth - control * 2 - 12
        rect(owner.stagePrevButton, carouselX, y, arrowWidth, control)
        rect(owner.stageNextButton, carouselX + carouselWidth - arrowWidth, y, arrowWidth, control)
        Theme.applyActionButton(owner.stagePrevButton, true, false)
        Theme.applyActionButton(owner.stageNextButton, true, false)
        local stageText = owner.stage.getSelectedText and owner.stage:getSelectedText()
            or (stage and (stage.label or stage.displayName or stage.id)) or ""
        stageText = tostring(stageText) .. "  (" .. tostring(owner.stage.selected or 1)
            .. "/" .. tostring(stageCount) .. ")"
        labels[#labels + 1] = {
            stageText, carouselX + arrowWidth + 4, y + 5, carouselWidth - arrowWidth * 2 - 8, true
        }
    end
    if showInspector then y = y + control + 6 end
    local selectors = {
        {owner.variant, "IGUI_KBW_Variant", base and #(base.variants or {}) > 0},
        {owner.material, "IGUI_KBW_MaterialSet", base and #(base.materialOptions or {}) > 0},
        {owner.finish, "IGUI_KBW_Finish", #(owner.finishValues or {}) > 0}
    }
    for index = 1, #selectors do
        local entry = selectors[index]
        entry[1]:setVisible(showInspector and entry[3] == true)
        if showInspector and entry[3] then
            local labelWidth = math.max(86, math.floor(detailWidth * .32))
            local lines = wrap(getText(entry[2]), labelWidth - 8)
            for index = 1, #lines do labels[#labels + 1] = {lines[index], detailX, y + 4 + (index - 1) * (font + 2)} end
            local height = math.max(control, #lines * (font + 2) + 8)
            rect(entry[1], detailX + labelWidth, y, detailWidth - labelWidth, control)
            y = y + height + 6
        end
    end
    owner.materialsTab:setVisible(false)
    owner.skillsTab:setVisible(false)
    local actionWidth = math.floor(((compact and listWidth or detailWidth) - 4) / 2)
    local panelHeight = math.max(20, actionY - y - 8)
    local sectionLabelHeight = font + 5
    local paneSpace = math.max(60, panelHeight - sectionLabelHeight * 2 - 5)
    local accessTarget = math.max(72, math.floor(paneSpace * .45))
    accessTarget = math.min(accessTarget, math.max(20, paneSpace - 40))
    local requirementsNeeded = owner.requirements.contentHeight
        and owner.requirements:contentHeight(detailWidth) or math.floor(paneSpace * .58)
    local requirementsHeight = math.min(
        math.max(40, requirementsNeeded), math.max(40, paneSpace - accessTarget)
    )
    local accessHeight = math.max(20, paneSpace - requirementsHeight)
    if showInspector then labels[#labels + 1] = {getText("IGUI_KBW_MaterialsTools"), detailX, y} end
    local requirementsY = y + sectionLabelHeight
    local skillsLabelY = requirementsY + requirementsHeight + 5
    if showInspector then labels[#labels + 1] = {getText("IGUI_KBW_SkillsKnowledge"), detailX, skillsLabelY} end
    local accessY = skillsLabelY + sectionLabelHeight
    if showInspector then
        rect(owner.requirements, detailX, requirementsY, detailWidth, requirementsHeight)
        rect(owner.accessPanel, detailX, accessY, detailWidth, accessHeight)
    end
    owner.requirements:setVisible(showInspector)
    owner.accessPanel:setVisible(showInspector)
    if showInspector then
        owner.requirements:onResize()
        owner.accessPanel:onResize()
    end
    local actionX = compact and listX or detailX
    rect(owner.buildButton, actionX, actionY, actionWidth, control)
    rect(owner.planButton, actionX + actionWidth + 4, actionY, actionWidth, control)
    owner.buildButton:setVisible(true)
    owner.planButton:setVisible(true)
    if drawerVisible then
        rect(owner.ingredientDrawer, drawerX, summaryY, drawerWidth, bottom - summaryY)
    end
    owner.ingredientDrawer:onResize()
    owner.grid:setVisible(true)
    owner:ensureResizeWidgets()
    if not liveResize then owner:bringChromeToTop() end
end

function Workspace.render(owner)
    local labels = owner.workspaceLabels or {}
    for index = 1, #labels do
        local entry = labels[index]
        if entry[5] then
            owner:drawTextCentre(
                entry[1], entry[2] + entry[4] / 2, entry[3],
                Theme.text.r, Theme.text.g, Theme.text.b, 1, UIFont.Small
            )
        else
            owner:drawText(
                entry[1], entry[2], entry[3],
                Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 1, UIFont.Small
            )
        end
    end
    local preview = owner.workspacePreview
    local definition, stage = owner:effectiveDefinition(), owner:selectedStage()
    if preview and definition and stage then
        local texture, color = Icons.textureForDefinition(definition, stage)
        local finish = owner:selectedFinish()
        if WallFinishes.isWallFinish(finish) then
            local sprite = WallFinishes.previewSprite(finish, false, definition, stage)
            local finished = sprite and Icons.textureForSpriteName(sprite)
            if finished then
                texture = finished
                color = WallFinishes.customColorFor(WallFinishes.wallType(definition, stage), finish) or {r = 1, g = 1, b = 1}
            end
        end
        Theme.drawPreviewBackground(owner, preview.x, preview.y, preview.width, preview.height, Options)
        if texture then owner:drawTextureScaledAspect(texture, preview.x + 4, preview.y + 4, preview.width - 8, preview.height - 8, 1, color.r, color.g, color.b) end
    end
end

return Workspace
