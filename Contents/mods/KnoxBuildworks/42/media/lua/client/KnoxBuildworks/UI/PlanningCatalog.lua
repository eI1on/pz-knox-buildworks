---A compact, purpose-built catalogue for Planning Mode.
---
---This deliberately stays separate from the main Buildworks catalogue. The
---planner needs a stable tool window, a small set of persistent controls, and
---a direct "add to plan" action; opening the resizable build window here made
---both interfaces compete for space and state.
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISComboBox"
require "ISUI/ISTextEntryBox"
require "ISUI/ISTickBox"

local Groups = require("KnoxBuildworks/Definitions/Groups")
local TableUtil = require("KnoxBuildworks/Util/Table")
local Theme = require("KnoxBuildworks/UI/Theme")
local BuildCardGrid = require("KnoxBuildworks/UI/BuildCardGrid")
local PinnedRecipes = require("KnoxBuildworks/UI/PinnedRecipes")
local FinishOptions = require("KnoxBuildworks/UI/FinishOptions")
local I18n = require("KnoxBuildworks/I18n")
local CatalogVisibility = require("KnoxBuildworks/UI/CatalogVisibility")
local CatalogIndex = require("KnoxBuildworks/UI/CatalogIndex")
local Profiler = require("KnoxBuildworks/Util/Profiler")

local STAR_OFF = getTexture("media/ui/inventoryPanes/FavouriteNo.png")
local STAR_ON = getTexture("media/ui/inventoryPanes/FavouriteYes.png")
local PIN_TEXTURE = getTexture("media/ui/inventoryPanes/Button_Pin.png")

---@class KBWPlanningCatalog: ISPanel
KBWPlanningCatalog = ISPanel:derive("KBWPlanningCatalog")

local function configureButton(button, primary)
    button:initialise()
    Theme.applyActionButton(button, true, primary == true)
    return button
end

local function clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function optionName(option, fallback)
    if not option then return fallback or "" end
    if option.__kbwDefaultLabel then return option.__kbwDefaultLabel end
    return I18n.optionName(option, fallback or option.id or "")
end

local function append(target, source)
    source = source or {}
    for index = 1, #source do target[#target + 1] = source[index] end
end

local function defaultOption(label)
    return { id = "", __kbwDefaultLabel = label }
end

local function sortedSubcategories(filterSet)
    local values = {}
    local labels = {}
    for value, enabled in pairs(filterSet or {}) do
        if enabled == true then
            values[#values + 1] = value
            labels[value] = I18n.subcategory(value)
        end
    end
    table.sort(values, function(a, b)
        if labels[a] ~= labels[b] then return labels[a] < labels[b] end
        return tostring(a) < tostring(b)
    end)
    return values
end

---@param owner KBWPlanningMode
---@param player IsoPlayer
---@return KBWPlanningCatalog
function KBWPlanningCatalog:new(owner, player, x, y, width, height)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.owner = owner
    o.player = player
    o.background = true
    o.backgroundColor = Theme.color(Theme.backdrop)
    o.borderColor = Theme.color(Theme.border)
    o.categories = { "All" }
    o.categoryIndex = 1
    o.subcategories = { "All" }
    o.subcategoryIndex = 1
    o.visibleStages = {}
    o.stageIndex = 1
    o.variantOptions = {}
    o.variantIndex = 1
    o.materialOptions = {}
    o.materialIndex = 1
    o.finishOptions = {}
    o.finishIndex = 1
    o.selectorRows = {}
    o.lastVisibilityGeneration = CatalogIndex.visibilityGeneration
    return o
end

function KBWPlanningCatalog:createChildren()
    ISPanel.createChildren(self)
    self:setWantKeyEvents(true)
    local owner = self
    self.search = ISTextEntryBox:new("", 10, 32, self.width - 20, 28)
    self.search:initialise()
    self.search:instantiate()
    self.search.target = self
    if self.search.setClearButton then self.search:setClearButton(true) end
    if self.search.setPlaceholderText then self.search:setPlaceholderText(getText("IGUI_KBW_SearchPlaceholder")) end
    if self.search.javaObject and self.search.javaObject.setCentreVertically then
        self.search.javaObject:setCentreVertically(true)
    end
    self.search.onTextChange = function (box)
        if box and box.target then box.target.searchDirtyAt = getTimestampMs() end
    end
    self:addChild(self.search)

    self.categoryCombo = ISComboBox:new(10, 66, self.width - 20, 28, self, self.onCategoryChanged)
    self.categoryCombo:initialise()
    self.categoryCombo:instantiate()
    self:addChild(self.categoryCombo)

    self.subcategoryCombo = ISComboBox:new(10, 98, self.width - 20, 28, self, self.onSubcategoryChanged)
    self.subcategoryCombo:initialise()
    self.subcategoryCombo:instantiate()
    self:addChild(self.subcategoryCombo)

    local showAllLabel = I18n.text("IGUI_KBW_ShowAllQualities", "All qualities")
    local showAllWidth = 28 + getTextManager():MeasureStringX(UIFont.Small, showAllLabel)
    self.showAllTickBox = ISTickBox:new(10, 132, showAllWidth, 24, "", self, self.onShowAllChanged)
    self.showAllTickBox:initialise()
    self.showAllTickBox:addOption(showAllLabel)
    self.showAllTickBox.selected[1] = CatalogVisibility.shouldShowAll(self.player)
    self:addChild(self.showAllTickBox)

    self.catalogGrid = BuildCardGrid:new(
        10, 160, self.width - 20, 180, self.player, self.owner,
        self.owner.onCatalogSelected, self.owner.onCatalogActivated
    )
    self.catalogGrid:initialise()
    self.catalogGrid:setViewMode("grid")
    self.catalogGrid:setCompactMode(true, true)
    self:addChild(self.catalogGrid)

    self.selectorButtons = {}
    local kinds = { "stage", "variant", "material", "finish" }
    for kindIndex = 1, #kinds do
        local kind = kinds[kindIndex]
        local previous = configureButton(ISButton:new(0, 0, 28, 28, "<", self, self.onSelectorCycle), false)
        previous.selectorKind, previous.internal = kind, -1
        self:addChild(previous)
        local following = configureButton(ISButton:new(0, 0, 28, 28, ">", self, self.onSelectorCycle), false)
        following.selectorKind, following.internal = kind, 1
        self:addChild(following)
        self.selectorButtons[kind] = { previous, following }
    end

    self.favoriteButton = configureButton(ISButton:new(0, 0, 26, 26, "", self, self.onFavorite), false)
    if STAR_OFF then self.favoriteButton:setImage(STAR_OFF); self.favoriteButton:forceImageSize(16, 16) end
    if self.favoriteButton.setTooltip then self.favoriteButton:setTooltip(getText("IGUI_KBW_Favorites")) end
    self:addChild(self.favoriteButton)
    self.pinButton = configureButton(ISButton:new(0, 0, 26, 26, "", self, self.onPin), false)
    if PIN_TEXTURE then self.pinButton:setImage(PIN_TEXTURE); self.pinButton:forceImageSize(16, 16) end
    if self.pinButton.setTooltip then self.pinButton:setTooltip(getText("IGUI_KBW_PinRecipe")) end
    self:addChild(self.pinButton)

    self.placePlanButton = configureButton(ISButton:new(
        10, self.height - 42, self.width - 20, 32,
        getText("IGUI_KBW_AddToPlan"), self, self.onPlanSelected
    ), true)
    self:addChild(self.placePlanButton)

    self:refreshCategories()
    self:refreshSubcategories()
    self:refreshCatalog()
    self:layout()
end

function KBWPlanningCatalog:refreshCategories()
    local selected = self.categories[self.categoryIndex] or "All"
    self.categories = { "All" }
    local categories = CatalogIndex.get().categories or {}
    for index = 1, #categories do self.categories[#self.categories + 1] = categories[index] end
    self.categoryIndex = 1
    for index = 1, #self.categories do
        if self.categories[index] == selected then self.categoryIndex = index end
    end
    self.categoryCombo:clear()
    for index = 1, #self.categories do
        local category = self.categories[index]
        self.categoryCombo:addOption(category == "All" and getText("IGUI_KBW_AllCategories") or I18n.category(category))
    end
    self.categoryCombo.selected = self.categoryIndex
end

function KBWPlanningCatalog:refreshSubcategories()
    local selected = self.subcategories[self.subcategoryIndex] or "All"
    local index = CatalogIndex.get()
    local category = self.categories[self.categoryIndex] or "All"
    local filters = category == "All" and index.allFilters or index.filtersByCategory[category]
    self.subcategories = { "All" }
    local values = sortedSubcategories(filters and filters.subcategories)
    for valueIndex = 1, #values do self.subcategories[#self.subcategories + 1] = values[valueIndex] end
    self.subcategoryIndex = 1
    for valueIndex = 1, #self.subcategories do
        if self.subcategories[valueIndex] == selected then self.subcategoryIndex = valueIndex end
    end
    self.subcategoryCombo:clear()
    for index = 1, #self.subcategories do
        local subcategory = self.subcategories[index]
        self.subcategoryCombo:addOption(
            subcategory == "All" and getText("IGUI_KBW_AllSubcategories") or I18n.subcategory(subcategory)
        )
    end
    self.subcategoryCombo.selected = self.subcategoryIndex
end

function KBWPlanningCatalog:onCategoryChanged()
    self.categoryIndex = self.categoryCombo.selected or 1
    self:refreshSubcategories()
    self:refreshCatalog()
end

function KBWPlanningCatalog:onSubcategoryChanged()
    self.subcategoryIndex = self.subcategoryCombo.selected or 1
    self:refreshCatalog()
end

function KBWPlanningCatalog:onShowAllChanged(clickedOption, enabled)
    CatalogVisibility.setShowAll(self.player, enabled == true)
    self:refreshCatalog()
    if self.owner and self.owner.selectedBuildable then
        self:selectDefinition(self.owner.selectedBuildable)
    end
end

function KBWPlanningCatalog:refreshCatalog()
    local startedAt = Profiler.now()
    local query = string.lower(self.search and self.search:getInternalText() or "")
    local category = self.categories[self.categoryIndex] or "All"
    local subcategory = self.subcategories[self.subcategoryIndex] or "All"
    local pinnedIds, pinnedCount = PinnedRecipes.pinnedBuildableIds(self.player)
    local source = CatalogIndex.get().orderByName or {}
    local showAll = CatalogVisibility.shouldShowAll(self.player)
    local pinnedFavorites, pinned, favorites, rest = {}, {}, {}, {}
    local selectedId = self.owner.selectedBuildable and self.owner.selectedBuildable.id or nil
    for sourceIndex = 1, #source do
        local record = source[sourceIndex]
        local include = (category == "All" or record.category == category)
            and (subcategory == "All" or record.subcategory == subcategory)
            and CatalogVisibility.definitionEnabled(record.definition)
        if include and not record.alwaysVisible then
            include = CatalogIndex.recordVisible(self.player, record, showAll)
        end
        if include and query ~= "" then
            include = string.find(record.searchTextExtended, query, 1, true) ~= nil
        end
        if include then
            local definition = record.definition
            local favorite = self.owner:isFavorite(definition) == true
            local recipePinned = pinnedCount > 0 and Groups.anyMemberIn(definition, pinnedIds)
            if recipePinned and favorite then
                pinnedFavorites[#pinnedFavorites + 1] = definition
            elseif recipePinned then
                pinned[#pinned + 1] = definition
            elseif favorite then
                favorites[#favorites + 1] = definition
            else
                rest[#rest + 1] = definition
            end
        end
    end
    local filtered = {}
    append(filtered, pinnedFavorites)
    append(filtered, pinned)
    append(filtered, favorites)
    append(filtered, rest)
    self.catalogGrid:setItems(filtered, selectedId)
    local selected = filtered[self.catalogGrid.selectedIndex]
    if selected then
        if self.owner.selectedBuildable ~= selected then self.owner:onCatalogSelected(selected) end
    elseif self.owner.selectedBuildable ~= nil then
        self.owner:onCatalogSelected(nil)
    end
    Profiler.add("planning.refreshCatalog", startedAt)
    Profiler.count("planning.refreshCatalogRuns")
end

function KBWPlanningCatalog:rawSelectedStage()
    return self.visibleStages[self.stageIndex or 1]
end

function KBWPlanningCatalog:selectedVariant()
    local option = self.variantOptions[self.variantIndex or 1]
    return option and option.id or ""
end

function KBWPlanningCatalog:selectedMaterial()
    local option = self.materialOptions[self.materialIndex or 1]
    return option and option.id or ""
end

function KBWPlanningCatalog:effectiveDefinition(definition, stage)
    local base = Groups.resolveDefinition(definition, stage)
    if not base then return nil end
    local ids = { self:selectedVariant(), self:selectedMaterial() }
    local sources = { base.variants or {}, base.materialOptions or {} }
    local effective = base
    for sourceIndex = 1, #sources do
        local wanted = ids[sourceIndex]
        if wanted ~= "" then
            local options = sources[sourceIndex]
            for optionIndex = 1, #options do
                if options[optionIndex].id == wanted then
                    effective = TableUtil.merge(effective, options[optionIndex])
                    break
                end
            end
        end
    end
    return effective
end

function KBWPlanningCatalog:selectedStage()
    local raw = self:rawSelectedStage()
    if not raw then return nil end
    local definition = self.owner and self.owner.selectedBuildable
    local effective = self:effectiveDefinition(definition, raw)
    if not effective or (self:selectedVariant() == "" and self:selectedMaterial() == "") then return raw end
    local wanted = Groups.resolveStageId(raw)
    local stages = effective.stages or {}
    for stageIndex = 1, #stages do
        if stages[stageIndex].id == wanted then return stages[stageIndex] end
    end
    return stages[1] or raw
end

function KBWPlanningCatalog:selectedFinish()
    local entry = self.finishOptions[self.finishIndex or 1]
    if entry and entry.none then return nil end
    return entry
end

local function restoreIndex(options, wantedId, fallback)
    if wantedId ~= nil then
        for index = 1, #options do
            if options[index].id == wantedId then return index end
        end
    end
    return clamp(fallback or 1, 1, math.max(1, #options))
end

function KBWPlanningCatalog:refreshOptionChoices(keepOptions)
    local definition = self.owner and self.owner.selectedBuildable
    local rawStage = self:rawSelectedStage()
    local base = Groups.resolveDefinition(definition, rawStage)
    local previousVariant = keepOptions and self:selectedVariant() or ""
    local previousMaterial = keepOptions and self:selectedMaterial() or ""
    self.variantOptions = { defaultOption(getText("IGUI_KBW_DefaultVariant")) }
    append(self.variantOptions, base and base.variants or {})
    self.materialOptions = {}
    if not (base and base.materialRequired == true) then
        self.materialOptions[1] = defaultOption(getText("IGUI_KBW_DefaultMaterial"))
    end
    append(self.materialOptions, base and base.materialOptions or {})
    if #self.materialOptions == 0 then
        self.materialOptions[1] = defaultOption(getText("IGUI_KBW_DefaultMaterial"))
    end
    self.variantIndex = restoreIndex(self.variantOptions, previousVariant, 1)
    self.materialIndex = restoreIndex(self.materialOptions, previousMaterial, 1)
    self:refreshFinishChoices()
end

function KBWPlanningCatalog:refreshFinishChoices()
    local previous = self.finishOptions[self.finishIndex or 1]
    local previousId = previous and (previous.id or previous.paintType or previous.wallpaperType) or nil
    local definition = self.owner and self.owner.selectedBuildable
    local stage = self:selectedStage()
    local effective = self:effectiveDefinition(definition, self:rawSelectedStage())
    self.finishOptions = effective and stage and FinishOptions.entriesFor(effective, stage) or {}
    self.finishIndex = 1
    if previousId then
        for index = 1, #self.finishOptions do
            local entry = self.finishOptions[index]
            if (entry.id or entry.paintType or entry.wallpaperType) == previousId then self.finishIndex = index end
        end
    end
    self:syncPreview()
    self:layout()
end

function KBWPlanningCatalog:selectDefinition(definition)
    self.visibleStages = definition and CatalogVisibility.filteredStages(
        self.player, definition, CatalogVisibility.shouldShowAll(self.player)
    ) or {}
    self.stageIndex = 1
    self.variantIndex, self.materialIndex, self.finishIndex = 1, 1, 1
    self:refreshOptionChoices(false)
end

function KBWPlanningCatalog:selectorOptions(kind)
    if kind == "stage" then return self.visibleStages, self.stageIndex end
    if kind == "variant" then return self.variantOptions, self.variantIndex end
    if kind == "material" then return self.materialOptions, self.materialIndex end
    return self.finishOptions, self.finishIndex
end

function KBWPlanningCatalog:selectorLabel(kind)
    local options, index = self:selectorOptions(kind)
    local option = options[index or 1]
    if not option then return "" end
    return optionName(option, tostring(index or 1)) .. "  (" .. tostring(index or 1) .. "/" .. tostring(#options) .. ")"
end

function KBWPlanningCatalog:onSelectorCycle(button)
    local kind = button.selectorKind
    local options, index = self:selectorOptions(kind)
    local count = #options
    if count <= 1 then return end
    index = ((index - 1 + (button.internal or 0)) % count) + 1
    if kind == "stage" then
        self.stageIndex = index
        self:refreshOptionChoices(false)
        return
    elseif kind == "variant" then
        self.variantIndex = index
    elseif kind == "material" then
        self.materialIndex = index
    else
        self.finishIndex = index
        self:syncPreview()
        self:layout()
        return
    end
    self:refreshFinishChoices()
end

function KBWPlanningCatalog:onFavorite()
    local definition = self.owner and self.owner.selectedBuildable
    if definition then self.owner:onGridFavorite(definition) end
end

function KBWPlanningCatalog:onPin()
    local definition = self.owner and self.owner.selectedBuildable
    if definition then self.owner:onGridPin(definition) end
end

function KBWPlanningCatalog:syncPreview()
    if not self.catalogGrid then return end
    local definition = self.owner and self.owner.selectedBuildable
    self.catalogGrid:setSelectionPreview(
        definition, self:effectiveDefinition(definition, self:rawSelectedStage()),
        self:selectedStage(), self:selectedFinish()
    )
end

function KBWPlanningCatalog:layout()
    if not self.search then return end
    local width = self.width - 20
    local control = math.max(28, getTextManager():getFontHeight(UIFont.Small) + 12)
    self.search:setWidth(width)
    self.categoryCombo:setWidth(width)
    self.subcategoryCombo:setWidth(width)
    self.showAllTickBox:setWidth(math.min(width, self.showAllTickBox.width))
    self.placePlanButton:setX(10)
    self.placePlanButton:setY(self.height - control - 10)
    self.placePlanButton:setWidth(width)
    self.placePlanButton:setHeight(control)

    local rowKinds = { "stage", "variant", "material", "finish" }
    self.selectorRows = {}
    self.selectorText = {}
    for kindIndex = 1, #rowKinds do
        local kind = rowKinds[kindIndex]
        local options = self:selectorOptions(kind)
        local visible = #options > 0 and (kind == "stage" or #options > 1)
        local buttons = self.selectorButtons[kind]
        buttons[1]:setVisible(visible)
        buttons[2]:setVisible(visible)
        if visible then
            self.selectorRows[#self.selectorRows + 1] = kind
            self.selectorText[kind] = self:selectorLabel(kind)
        end
    end
    local rowHeight = control
    local selectorHeight = 44 + #self.selectorRows * (rowHeight + 4)
    self.selectorPanelY = self.placePlanButton.y - selectorHeight - 7
    self.selectorPanelH = selectorHeight
    self.favoriteButton:setX(self.width - 76)
    self.favoriteButton:setY(self.selectorPanelY + 6)
    self.pinButton:setX(self.width - 46)
    self.pinButton:setY(self.selectorPanelY + 6)
    local definition = self.owner and self.owner.selectedBuildable
    self.favoriteButton:setVisible(definition ~= nil)
    self.pinButton:setVisible(definition ~= nil)
    if definition then
        if STAR_OFF and self.favoriteButton.setImage then
            self.favoriteButton:setImage(self.owner:isFavorite(definition) and (STAR_ON or STAR_OFF) or STAR_OFF)
        end
        Theme.applyButton(self.favoriteButton, self.owner:isFavorite(definition))
        Theme.applyButton(self.pinButton, self.owner:isPinnedDefinition(definition))
    end
    local fullName = definition and I18n.definitionName(definition) or getText("IGUI_KBW_NoBuildableSelected")
    local titleWidth = self.width - (definition and 104 or 36)
    local renderedName = fullName
    while #renderedName > 3 and getTextManager():MeasureStringX(UIFont.Small, renderedName) > titleWidth do
        renderedName = string.sub(renderedName, 1, #renderedName - 1)
    end
    if renderedName ~= fullName then renderedName = renderedName .. "..." end
    self.renderedSelectedName = renderedName
    local rowY = self.selectorPanelY + 36
    for rowIndex = 1, #self.selectorRows do
        local kind = self.selectorRows[rowIndex]
        local buttons = self.selectorButtons[kind]
        buttons[1]:setX(18); buttons[1]:setY(rowY); buttons[1]:setWidth(28); buttons[1]:setHeight(rowHeight)
        buttons[2]:setX(self.width - 46); buttons[2]:setY(rowY); buttons[2]:setWidth(28); buttons[2]:setHeight(rowHeight)
        local options = self:selectorOptions(kind)
        local canCycle = #options > 1
        Theme.applyActionButton(buttons[1], canCycle, false)
        Theme.applyActionButton(buttons[2], canCycle, false)
        rowY = rowY + rowHeight + 4
    end
    self.catalogGrid:setX(10)
    self.catalogGrid:setY(160)
    self.catalogGrid:setWidth(width)
    self.catalogGrid:setHeight(math.max(84, self.selectorPanelY - 168))
    self.catalogGrid:onResize()
    local enabled = self.owner and self.owner.selectedBuildable ~= nil and self:selectedStage() ~= nil
        and (not self.owner.canPlanSelection or self.owner:canPlanSelection())
    Theme.applyActionButton(self.placePlanButton, enabled, true)
end

function KBWPlanningCatalog:onResize()
    if ISPanel.onResize then ISPanel.onResize(self) end
    self:layout()
end

function KBWPlanningCatalog:onPlanSelected()
    if self.owner then self.owner:onPlanSelected() end
end

function KBWPlanningCatalog:isKeyConsumed(key)
    return Keyboard and key == Keyboard.KEY_ESCAPE
end

function KBWPlanningCatalog:onKeyRelease(key)
    if self:isKeyConsumed(key) and self.owner then self.owner:close() end
end

function KBWPlanningCatalog:update()
    if ISPanel.update then ISPanel.update(self) end
    CatalogIndex.pumpVisibility(4)
    if self.lastVisibilityGeneration ~= CatalogIndex.visibilityGeneration then
        self.lastVisibilityGeneration = CatalogIndex.visibilityGeneration
        self.visibilityRefreshPending = true
    end
    if self.searchDirtyAt and getTimestampMs() - self.searchDirtyAt >= 220 then
        self.searchDirtyAt = nil
        self:refreshCatalog()
        return
    end
    if self.visibilityRefreshPending then
        self.visibilityRefreshPending = nil
        self:refreshCatalog()
    end
end

function KBWPlanningCatalog:prerender()
    ISPanel.prerender(self)
    self:drawText(
        getText("IGUI_KBW_PlanningCatalog"), 10, 9,
        Theme.text.r, Theme.text.g, Theme.text.b, 1, UIFont.Small
    )
    self:drawRect(
        10, self.selectorPanelY, self.width - 20, self.selectorPanelH,
        Theme.surface.a, Theme.surface.r, Theme.surface.g, Theme.surface.b
    )
    self:drawRectBorder(
        10, self.selectorPanelY, self.width - 20, self.selectorPanelH,
        Theme.borderSoft.a, Theme.borderSoft.r, Theme.borderSoft.g, Theme.borderSoft.b
    )
    self:drawRect(10, self.selectorPanelY, self.width - 20, 2, Theme.ready.a, Theme.ready.r, Theme.ready.g, Theme.ready.b)
    local name = self.renderedSelectedName or getText("IGUI_KBW_NoBuildableSelected")
    self:drawText(name, 18, self.selectorPanelY + 11, Theme.text.r, Theme.text.g, Theme.text.b, 1, UIFont.Small)
    local rowLabels = {
        stage = getText("IGUI_KBW_Stage"), variant = getText("IGUI_KBW_Variant"),
        material = getText("IGUI_KBW_MaterialSet"), finish = getText("IGUI_KBW_Finish")
    }
    local rowY = self.selectorPanelY + 36
    local control = math.max(28, getTextManager():getFontHeight(UIFont.Small) + 12)
    for rowIndex = 1, #self.selectorRows do
        local kind = self.selectorRows[rowIndex]
        local label = rowLabels[kind] .. ":  " .. (self.selectorText[kind] or "")
        self:drawTextCentre(label, self.width / 2, rowY + math.floor((control - getTextManager():getFontHeight(UIFont.Small)) / 2),
            Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 1, UIFont.Small)
        rowY = rowY + control + 4
    end
end

function KBWPlanningCatalog:close()
    if self.catalogGrid then self.catalogGrid:hideBuildableTooltip() end
    self:setVisible(false)
    self:removeFromUIManager()
end

return KBWPlanningCatalog
