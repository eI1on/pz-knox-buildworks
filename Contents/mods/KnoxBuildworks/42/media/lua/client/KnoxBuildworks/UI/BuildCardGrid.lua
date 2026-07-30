---BuildCardGrid provides the Knox Buildworks custom user-interface layer.
require "ISUI/ISPanel"
require "ISUI/ISToolTip"

local Requirements = require("KnoxBuildworks/Validation/Requirements")
local Groups = require("KnoxBuildworks/Definitions/Groups")
local Theme = require("KnoxBuildworks/UI/Theme")
local IconResolver = require("KnoxBuildworks/UI/IconResolver")
local I18n = require("KnoxBuildworks/I18n")
local Profiler = require("KnoxBuildworks/Util/Profiler")
local BuildableInfo = require("KnoxBuildworks/UI/BuildableInfo")
local Options = require("KnoxBuildworks/Options")
local WallFinishes = require("KnoxBuildworks/Validation/WallFinishes")

---@class KBWBuildCardGrid: ISPanel
KBWBuildCardGrid = ISPanel:derive("KBWBuildCardGrid")

local function displayName(definition)
    return I18n.definitionName(definition)
end

local function shorten(text, width)
    text = string.gsub(tostring(text or ""), "[\r\n]+", " ")
    if getTextManager():MeasureStringX(UIFont.Small, text) <= width then return text end
    while #text > 3 and getTextManager():MeasureStringX(UIFont.Small, text .. "...") > width do
        text = string.sub(text, 1, #text - 1)
    end
    return text .. "..."
end

local function wrapText(text, width)
    text = string.gsub(tostring(text or ""), "[\r\n]+", " ")
    if text == "" then return {} end
    -- TextManager performs the wrapping in Java. The old Lua path measured
    -- every progressively longer character slice in IDs without spaces,
    -- producing quadratic work for every detailed row.
    local wrapped = getTextManager():WrapText(UIFont.Small, text, math.max(1, math.floor(width)))
    local lines = {}
    for line in string.gmatch(wrapped, "[^\r\n]+") do
        lines[#lines + 1] = line
    end
    if #lines == 0 then lines[1] = text end
    return lines
end

-- Card readiness re-evaluates when the inventory revision changes (or a slow
-- TTL catches state the revision cannot see, e.g. perk levels or daylight),
-- at most this many cards per frame so opening or switching large categories
-- cannot hitch a frame. OnContainerUpdate can fire near-continuously (world
-- containers, appliances), so revision-triggered refreshes are additionally
-- rate-limited per card.
local STATUS_BUDGET_PER_FRAME = 8
local STATUS_TTL_MS = 4000
local STATUS_REV_MIN_MS = 400

---@param x number
---@param y number
---@param width number
---@param height number
---@param player IsoPlayer
---@param onSelect function|nil
---@param onActivate function|nil
---@return KBWBuildCardGrid
function KBWBuildCardGrid:new(x, y, width, height, player, target, onSelect, onActivate)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.player, o.target, o.onSelect, o.onActivate = player, target, onSelect, onActivate
    o.items, o.selectedIndex, o.hoverIndex = {}, 0, 0
    o.cardCache = {}
    o.statusBudget = 0
    o.cardWidth, o.cardHeight, o.gap = 118, 132, 10
    o.rowHeight = 88
    o.viewMode = "grid"
    o.favoriteSize = 18
    o.pinSize = 18
    o.starUnsetTexture = getTexture("media/ui/inventoryPanes/FavouriteNo.png")
    o.starSetTexture = getTexture("media/ui/inventoryPanes/FavouriteYes.png")
    o.pinTexture = getTexture("media/ui/inventoryPanes/Button_Pin.png")
    o.background = false
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    o.compactMode = nil
    o.listLayoutCache = nil
    o.listLayoutDeferred = false
    return o
end

function KBWBuildCardGrid:setCompactMode(compact)
    compact = compact == true
    if self.compactMode == compact then return end
    self.compactMode = compact
    if not self.compactMode and self.hideBuildableTooltip then self:hideBuildableTooltip() end
    local fontHeight = getTextManager():getFontHeight(UIFont.Small)
    if self.compactMode then
        self.cardWidth = math.max(74, fontHeight + 50)
        self.cardHeight = math.max(78, fontHeight + 54)
        self.gap = 6
        self.favoriteSize = 14
        self.pinSize = 14
    else
        self.cardWidth = math.max(124, fontHeight * 5 + 18)
        self.cardHeight = math.max(142, fontHeight * 2 + 112)
        self.rowHeight = math.max(92, fontHeight * 3 + 26)
        self.gap = 10
        self.favoriteSize = 18
        self.pinSize = 18
    end
    self.listLayoutCache = nil
    self:setScrollHeight(self:contentHeight())
    if self.vscroll then self:updateScrollbars() end
end

function KBWBuildCardGrid:createChildren()
    ISPanel.createChildren(self)
    self:addScrollBars()
    self:setScrollChildren(false)
    if self.vscroll then
        self.vscroll:setX(self.width - self.vscroll:getWidth())
        self.vscroll:setHeight(self.height)
    end
end

function KBWBuildCardGrid:onResize()
    if ISPanel.onResize then ISPanel.onResize(self) end
    if self.vscroll then
        self.vscroll:setX(self.width - self.vscroll:getWidth())
        self.vscroll:setHeight(self.height)
    end
    -- listLayouts() already rejects a cache whose draw width changed. Keep a
    -- valid cache when only the height or an unrelated inspector control
    -- changes, and defer width reflow while the player drags the resize grip.
    if not (self.listLayoutDeferred and self.viewMode == "list") then
        self:setScrollHeight(self:contentHeight())
    end
end

function KBWBuildCardGrid:setItems(items, selectedId)
    self:hideBuildableTooltip()
    self.hoverIndex = 0
    items = items or {}
    local sameItems = #items == #self.items
    if sameItems then
        for index = 1, #items do
            if items[index] ~= self.items[index] then
                sameItems = false
                break
            end
        end
    end
    self.items, self.selectedIndex = items, 0
    for index = 1, #self.items do
        local definition = self.items[index]
        if definition.id == selectedId then self.selectedIndex = index end
    end
    if self.selectedIndex == 0 and #self.items > 0 then self.selectedIndex = 1 end
    if not sameItems then self.listLayoutCache = nil end
    if not (self.listLayoutDeferred and self.viewMode == "list") then
        self:setScrollHeight(self:contentHeight())
    end
    if self.vscroll then self:updateScrollbars() end
end

function KBWBuildCardGrid:setSelectionPreview(definition, effectiveDefinition, stage, finish)
    if not definition or not stage then
        self.selectionPreview = nil
    else
        self.selectionPreview = {
            id = definition.id,
            definition = effectiveDefinition or definition,
            stage = stage,
            finish = finish
        }
    end
    if self.compactMode and self.hoverIndex == self.selectedIndex then self:updateBuildableTooltip() end
end

function KBWBuildCardGrid:visualFor(definition, entry, selected)
    local preview = selected and self.selectionPreview or nil
    if not preview or preview.id ~= definition.id then return entry.texture, entry.textureColor end
    local texture, textureColor = IconResolver.textureForDefinition(preview.definition, preview.stage)
    if WallFinishes.isWallFinish(preview.finish) then
        local spriteName = WallFinishes.previewSprite(preview.finish, false, preview.definition, preview.stage)
        local finishTexture = spriteName and IconResolver.textureForSpriteName(spriteName) or nil
        if finishTexture then
            texture = finishTexture
            textureColor = { r = 1, g = 1, b = 1, a = 1 }
        end
    end
    return texture or entry.texture, textureColor or entry.textureColor
end

---@param mode string|nil
function KBWBuildCardGrid:setViewMode(mode)
    mode = mode == "list" and "list" or "grid"
    if self.viewMode == mode then return end
    self.viewMode = mode
    self.listLayoutCache = nil
    self:setScrollHeight(self:contentHeight())
    if self.vscroll then self:updateScrollbars() end
end

function KBWBuildCardGrid:setLayoutDeferred(deferred)
    deferred = deferred == true
    if self.listLayoutDeferred == deferred then return end
    self.listLayoutDeferred = deferred
    if deferred or self.viewMode ~= "list" then return end
    self:setScrollHeight(self:contentHeight())
    if self.vscroll then self:updateScrollbars() end
end

function KBWBuildCardGrid:drawWidth()
    return self.width - (self.vscroll and self.vscroll:getWidth() or 0)
end

function KBWBuildCardGrid:columns()
    if self.viewMode == "list" then return 1 end
    return math.max(1, math.floor((self:drawWidth() - self.gap) / (self.cardWidth + self.gap)))
end

function KBWBuildCardGrid:secondaryText(definition, entry)
    if entry.secondary == nil then
        entry.secondary = tostring(definition.category or "?") .. " / "
            .. tostring(definition.subcategory or "General") .. "  -  "
            .. tostring(definition.id or "?")
    end
    return entry.secondary
end

function KBWBuildCardGrid:listLayouts()
    local drawWidth = self:drawWidth()
    local cache = self.listLayoutCache
    if self.listLayoutDeferred and cache then return cache end
    if cache and cache.width == drawWidth and cache.count == #self.items then return cache end
    Profiler.count("grid.listLayoutBuilds")
    local fontHeight = getTextManager():getFontHeight(UIFont.Small)
    local lineHeight = fontHeight + 2
    local rowWidth = math.max(80, drawWidth - self.gap * 2)
    local textWidth = math.max(60, rowWidth - 76 - self.favoriteSize - self.pinSize - 28)
    local layouts = {}
    local y = self.gap
    for index = 1, #self.items do
        local definition = self.items[index]
        local entry = self:cardLayoutData(definition)
        local rowCache = entry.listRowLayout
        if not rowCache or rowCache.width ~= textWidth or rowCache.fontHeight ~= fontHeight then
            Profiler.count("grid.listRowWraps")
            local nameLines = wrapText(entry.name, textWidth)
            local secondaryLines = wrapText(self:secondaryText(definition, entry), textWidth)
            local textHeight = (#nameLines + #secondaryLines) * lineHeight + 8
            rowCache = {
                width = textWidth,
                fontHeight = fontHeight,
                height = math.max(76, 9 + textHeight + fontHeight + 12),
                nameLines = nameLines,
                secondaryLines = secondaryLines
            }
            entry.listRowLayout = rowCache
        end
        layouts[index] = {
            y = y,
            height = rowCache.height,
            nameLines = rowCache.nameLines,
            secondaryLines = rowCache.secondaryLines,
            textWidth = textWidth
        }
        y = y + rowCache.height + self.gap
    end
    cache = { width = drawWidth, count = #self.items, rows = layouts, total = y }
    self.listLayoutCache = cache
    return cache
end

function KBWBuildCardGrid:contentHeight()
    if self.viewMode == "list" then return self:listLayouts().total end
    return math.ceil(#self.items / self:columns()) * (self.cardHeight + self.gap) + self.gap
end

local function listIndexAtY(rows, y)
    local low, high = 1, #rows
    while low <= high do
        local middle = math.floor((low + high) / 2)
        local row = rows[middle]
        if y < row.y then
            high = middle - 1
        elseif y > row.y + row.height then
            low = middle + 1
        else
            return middle
        end
    end
    return 0
end

local function firstListIndexAtOrAfter(rows, y)
    local low, high, result = 1, #rows, #rows + 1
    while low <= high do
        local middle = math.floor((low + high) / 2)
        local row = rows[middle]
        if row.y + row.height >= y then
            result = middle
            high = middle - 1
        else
            low = middle + 1
        end
    end
    return result
end

---@param x number
---@param y number
function KBWBuildCardGrid:indexAt(x, y)
    if x >= self:drawWidth() then return 0 end
    if self.viewMode == "list" then
        return listIndexAtY(self:listLayouts().rows, y)
    end
    local col = math.floor((x - self.gap) / (self.cardWidth + self.gap))
    local row = math.floor((y - self.gap) / (self.cardHeight + self.gap))
    if col < 0 or col >= self:columns() or row < 0 then return 0 end
    local localX = (x - self.gap) % (self.cardWidth + self.gap)
    local localY = (y - self.gap) % (self.cardHeight + self.gap)
    if localX > self.cardWidth or localY > self.cardHeight then return 0 end
    local index = row * self:columns() + col + 1
    return index <= #self.items and index or 0
end

---@param x number
---@param y number
function KBWBuildCardGrid:favoriteIndexAt(x, y)
    local index = self:indexAt(x, y)
    if index == 0 then return 0 end
    if self.viewMode == "list" then
        local rowY = self:listLayouts().rows[index].y
        local starX = self:drawWidth() - self.gap - self.favoriteSize - 12
        local starY = rowY + 9
        if x >= starX and x <= starX + self.favoriteSize and y >= starY and y <= starY + self.favoriteSize then
            return index
        end
        return 0
    end
    local columns = self:columns()
    local col, row = (index - 1) % columns, math.floor((index - 1) / columns)
    local cardX = self.gap + col * (self.cardWidth + self.gap)
    local cardY = self.gap + row * (self.cardHeight + self.gap)
    local starX = cardX + self.cardWidth - self.favoriteSize - (self.compactMode and 5 or 7)
    local starY = cardY + (self.compactMode and 5 or 7)
    if x >= starX and x <= starX + self.favoriteSize and y >= starY and y <= starY + self.favoriteSize then
        return index
    end
    return 0
end

---@param x number
---@param y number
function KBWBuildCardGrid:pinIndexAt(x, y)
    local index = self:indexAt(x, y)
    if index == 0 then return 0 end
    if self.viewMode == "list" then
        local rowY = self:listLayouts().rows[index].y
        local pinX = self:drawWidth() - self.gap - self.favoriteSize - self.pinSize - 20
        local pinY = rowY + 9
        if x >= pinX and x <= pinX + self.pinSize and y >= pinY and y <= pinY + self.pinSize then
            return index
        end
        return 0
    end
    local columns = self:columns()
    local col, row = (index - 1) % columns, math.floor((index - 1) / columns)
    local cardX = self.gap + col * (self.cardWidth + self.gap)
    local cardY = self.gap + row * (self.cardHeight + self.gap)
    local pinX = cardX + (self.compactMode and 5 or 7)
    local pinY = cardY + (self.compactMode and 5 or 7)
    if x >= pinX and x <= pinX + self.pinSize and y >= pinY and y <= pinY + self.pinSize then
        return index
    end
    return 0
end

---@param definition KBW.BuildableDefinition
function KBWBuildCardGrid:isFavorite(definition)
    if self.target and self.target.isFavorite then return self.target:isFavorite(definition) end
    return false
end

---@param definition KBW.BuildableDefinition
function KBWBuildCardGrid:isPinned(definition)
    if self.target and self.target.isPinnedDefinition then return self.target:isPinnedDefinition(definition) end
    return false
end

---@param dx number
---@param dy number
function KBWBuildCardGrid:onMouseMove(dx, dy)
    local hoverIndex = self:indexAt(self:getMouseX(), self:getMouseY())
    if hoverIndex ~= self.hoverIndex then
        self.hoverIndex = hoverIndex
        self:updateBuildableTooltip()
    end
end

---@param dx number
---@param dy number
function KBWBuildCardGrid:onMouseMoveOutside(dx, dy)
    self.hoverIndex = 0
    self:hideBuildableTooltip()
end

function KBWBuildCardGrid:hideBuildableTooltip()
    if not self.buildableTooltip then return end
    self.buildableTooltip:setVisible(false)
    self.buildableTooltip:removeFromUIManager()
    self.buildableTooltip = nil
end

function KBWBuildCardGrid:updateBuildableTooltip()
    self:hideBuildableTooltip()
    if not self.compactMode or self.hoverIndex <= 0 then return end
    local definition = self.items[self.hoverIndex]
    if not definition then return end
    local entry = self:cardData(definition)
    local preview = self.hoverIndex == self.selectedIndex and self.selectionPreview or nil
    local tooltipDefinition = preview and preview.id == definition.id and preview.definition or entry.statusDefinition or definition
    local tooltipStage = preview and preview.id == definition.id and preview.stage or entry.statusStage or entry.stage
    local tooltip = ISToolTip:new()
    tooltip:initialise()
    tooltip:addToUIManager()
    tooltip.owner = self
    tooltip.followMouse = true
    tooltip:setAlwaysOnTop(true)
    tooltip:setName(entry.name)
    tooltip.description = BuildableInfo.compactTooltip(self.player, tooltipDefinition, tooltipStage)
    tooltip:setVisible(true)
    self.buildableTooltip = tooltip
end

---@param x number
---@param y number
function KBWBuildCardGrid:onMouseDown(x, y)
    local pinIndex = self:pinIndexAt(x, y)
    if pinIndex > 0 then
        self.selectedIndex = pinIndex
        if self.onSelect then self.onSelect(self.target, self.items[pinIndex]) end
        if self.target and self.target.onGridPin then self.target:onGridPin(self.items[pinIndex]) end
        return true
    end
    local favoriteIndex = self:favoriteIndexAt(x, y)
    if favoriteIndex > 0 then
        self.selectedIndex = favoriteIndex
        if self.onSelect then self.onSelect(self.target, self.items[favoriteIndex]) end
        if self.target and self.target.onGridFavorite then self.target:onGridFavorite(self.items[favoriteIndex]) end
        return true
    end
    local index = self:indexAt(x, y)
    if index == 0 then return false end
    self.selectedIndex = index
    if self.onSelect then self.onSelect(self.target, self.items[index]) end
    return true
end

---@param x number
---@param y number
function KBWBuildCardGrid:onMouseDoubleClick(x, y)
    local index = self:indexAt(x, y)
    if index > 0 and self.onActivate then
        self.onActivate(self.target, self.items[index])
    end
    return true
end

function KBWBuildCardGrid:onMouseWheel(delta)
    local maximum = math.max(0, self:contentHeight() - self.height)
    local target = self:getYScroll() - delta * (self.compactMode and self.cardHeight or 46)
    self:setYScroll(math.max(-maximum, math.min(0, target)))
    if self.vscroll then self:updateScrollbars() end
    if self.compactMode then
        self.hoverIndex = self:indexAt(self:getMouseX(), self:getMouseY())
        self:updateBuildableTooltip()
    end
    return true
end

-- Lightweight display text is cached for every laid-out row. Stage and icon
-- data is added lazily by cardData() only when that card becomes visible.
---@param definition KBW.BuildableDefinition
function KBWBuildCardGrid:cardLayoutData(definition)
    local id = definition.id or tostring(definition)
    local entry = self.cardCache[id]
    if not entry then
        Profiler.count("grid.cardLayoutDataBuilds")
        entry = { name = displayName(definition) }
        self.cardCache[id] = entry
    end
    return entry
end

---Resolves icon and stage data only when a row/card is actually visible.
---@param definition KBW.BuildableDefinition
function KBWBuildCardGrid:cardData(definition)
    local entry = self:cardLayoutData(definition)
    if not entry.cardDataReady then
        Profiler.count("grid.cardDataBuilds")
        local stage = definition.stages and definition.stages[1]
        local statusDefinition = Groups.resolveDefinition(definition, stage)
        local statusStage = stage
        if statusDefinition and statusDefinition.materialRequired == true then
            local firstOption = (statusDefinition.materialOptions or {})[1]
            local optionStages = firstOption and firstOption.stages or nil
            if optionStages and #optionStages > 0 then
                local targetId = stage and (Groups.resolveStageId(stage) or stage.id) or nil
                statusStage = optionStages[1]
                for stageIndex = 1, #optionStages do
                    if optionStages[stageIndex].id == targetId then
                        statusStage = optionStages[stageIndex]
                        break
                    end
                end
            end
        end
        entry.stage = stage
        entry.statusStage = statusStage
        entry.statusDefinition = statusDefinition
        entry.texture, entry.textureColor = IconResolver.textureForDefinition(definition, stage)
        entry.cardDataReady = true
    end
    return entry
end

---@param definition KBW.BuildableDefinition
function KBWBuildCardGrid:cardStatus(definition)
    local entry = self:cardData(definition)
    local now = getTimestampMs()
    local rev = Requirements.inventoryRevision()
    local age = now - (entry.statusTime or 0)
    local stale = entry.status == nil
        or age > STATUS_TTL_MS
        or (entry.statusRev ~= rev and age > STATUS_REV_MIN_MS)
    if stale and self.statusBudget > 0 then
        self.statusBudget = self.statusBudget - 1
        if not self.statusSnapshot then
            self.statusSnapshot = Requirements.snapshot(self.player, self.player:getSquare())
        end
        entry.status = entry.statusStage
            and Requirements.evaluateReadiness(
                self.player, entry.statusDefinition, entry.statusStage, self.statusSnapshot
            )
            or { ok = false }
        entry.status.pending = nil
        entry.statusRev = rev
        entry.statusTime = now
    elseif entry.status == nil then
        entry.status = { ok = false, pending = true }
        entry.statusTime = 0
    end
    return entry, entry.status
end

---@param width number
function KBWBuildCardGrid:shortNameFor(entry, width)
    if entry.shortName == nil or entry.shortWidth ~= width then
        entry.shortWidth = width
        entry.shortName = shorten(entry.name, width)
    end
    return entry.shortName
end

function KBWBuildCardGrid:invalidateStatuses()
    for _, entry in pairs(self.cardCache) do
        entry.statusTime = 0
    end
end

function KBWBuildCardGrid:prerender()
    ISPanel.prerender(self)
    if self.vscroll then
        self.vscroll:setX(self.width - self.vscroll:getWidth())
        self.vscroll:setHeight(self.height)
    end
    local safeWidth = self:drawWidth()
    self:clampStencilRectToParent(0, 0, safeWidth, self.height)
    local columns, scroll = self:columns(), self:getYScroll()
    self.statusBudget = STATUS_BUDGET_PER_FRAME
    self.statusSnapshot = nil

    if self.viewMode == "list" then
        local layouts = self:listLayouts().rows
        local firstIndex = firstListIndexAtOrAfter(layouts, math.max(0, -scroll))
        for index = firstIndex, #layouts do
            local definition = self.items[index]
            local layout = layouts[index]
            local y = layout.y
            local rowHeight = layout.height
            local viewY = y + scroll
            if viewY > self.height then break end
            if viewY + rowHeight >= 0 then
                local selected, hovered = index == self.selectedIndex, index == self.hoverIndex
                local entry, status = self:cardStatus(definition)
                local texture, textureColor = self:visualFor(definition, entry, selected)
                local fill = selected and Theme.selected or (hovered and Theme.surfaceRaised or Theme.surface)
                local border = selected and Theme.accent or (status.ok and Theme.good or Theme.borderSoft)
                local x = self.gap
                local width = safeWidth - self.gap * 2
                self:drawRect(x + 2, y + 2, width, rowHeight, 0.26, 0, 0, 0)
                self:drawRect(x, y, width, rowHeight, fill.a, fill.r, fill.g, fill.b)
                self:drawRect(x, y, 4, rowHeight, selected and 1 or .72, border.r, border.g, border.b)
                self:drawRectBorder(x, y, width, rowHeight, border.a, border.r, border.g, border.b)
                Theme.drawPreviewBackground(self, x + 9, y + 9, 56, 56, Options)
                self:drawRectBorder(
                    x + 9, y + 9, 56, 56, .6, Theme.borderSoft.r, Theme.borderSoft.g, Theme.borderSoft.b
                )
                if texture then
                    self:drawTextureScaledAspect(
                        texture, x + 11, y + 11, 52, 52, status.ok and 1 or 0.42, textureColor.r, textureColor.g,
                        textureColor.b
                    )
                end
                local pinned = self:isPinned(definition)
                if self.pinTexture then
                    local pinColor = pinned and Theme.accent or Theme.textMuted
                    self:drawTextureScaledAspect(
                        self.pinTexture, x + width - self.favoriteSize - self.pinSize - 20, y + 9, self.pinSize,
                        self.pinSize, pinned and 1 or .58, pinColor.r, pinColor.g, pinColor.b
                    )
                end
                local favorite = self:isFavorite(definition)
                local starTexture = favorite and self.starSetTexture or self.starUnsetTexture
                if starTexture then
                    local alpha = favorite and 1 or (hovered and .88 or .58)
                    local color = favorite and Theme.accent or Theme.textMuted
                    self:drawTextureScaledAspect(
                        starTexture, x + width - self.favoriteSize - 12, y + 9, self.favoriteSize, self.favoriteSize,
                        alpha, color.r, color.g, color.b
                    )
                end
                local fontHeight = getTextManager():getFontHeight(UIFont.Small)
                local lineHeight = fontHeight + 2
                local textY = y + 9
                for lineIndex = 1, #layout.nameLines do
                    self:drawText(
                        layout.nameLines[lineIndex], x + 76, textY,
                        Theme.text.r, Theme.text.g, Theme.text.b, 1, UIFont.Small
                    )
                    textY = textY + lineHeight
                end
                textY = textY + 2
                for lineIndex = 1, #layout.secondaryLines do
                    self:drawText(
                        layout.secondaryLines[lineIndex], x + 76, textY,
                        Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, .9, UIFont.Small
                    )
                    textY = textY + lineHeight
                end
                local marker = status.pending and Theme.textMuted or (status.ok and Theme.good or Theme.warn)
                local statusY = y + rowHeight - fontHeight - 9
                self:drawRect(x + 76, statusY + math.floor(fontHeight / 2) - 2, 6, 6, 1, marker.r, marker.g, marker.b)
                local statusText = status.pending and "..."
                    or (status.ok and getText("IGUI_KBW_Ready") or getText("IGUI_KBW_Missing"))
                self:drawText(
                    statusText, x + 86, statusY, marker.r, marker.g, marker.b, 1, UIFont.Small
                )
            end
        end
    else
        local rowStep = self.cardHeight + self.gap
        local firstRow = math.floor((-scroll - self.gap) / rowStep)
        local lastRow = math.ceil((-scroll + self.height + self.gap) / rowStep)
        if firstRow < 0 then firstRow = 0 end
        local maxRow = math.ceil(#self.items / columns) - 1
        if lastRow > maxRow then lastRow = maxRow end
        for row = firstRow, lastRow do
            for col = 0, columns - 1 do
                local index = row * columns + col + 1
                if index <= #self.items then
                    local definition = self.items[index]
                    local x = self.gap + col * (self.cardWidth + self.gap)
                    local y = self.gap + row * (self.cardHeight + self.gap)
                    local viewY = y + scroll
                    if viewY + self.cardHeight >= 0 and viewY <= self.height then
                        local selected, hovered = index == self.selectedIndex, index == self.hoverIndex
                        local entry, status = self:cardStatus(definition)
                        local texture, textureColor = self:visualFor(definition, entry, selected)
                        local fill = selected and Theme.selected or (hovered and Theme.surfaceRaised or Theme.surface)
                        local border = selected and Theme.accent or (status.ok and Theme.good or Theme.borderSoft)
                        self:drawRect(x + 2, y + 2, self.cardWidth, self.cardHeight, 0.24, 0, 0, 0)
                        self:drawRect(x, y, self.cardWidth, self.cardHeight, fill.a, fill.r, fill.g, fill.b)
                        self:drawRect(x, y, self.cardWidth, 3, selected and 1 or .68, border.r, border.g, border.b)
                        self:drawRectBorder(
                            x, y, self.cardWidth, self.cardHeight, border.a, border.r, border.g, border.b
                        )
                        local previewX = self.compactMode and (x + 6) or (x + math.floor((self.cardWidth - 84) / 2))
                        local previewY = self.compactMode and (y + 6) or (y + 12)
                        local previewWidth = self.compactMode and (self.cardWidth - 12) or 84
                        local previewHeight = self.compactMode and (self.cardHeight - 18) or 70
                        Theme.drawPreviewBackground(
                            self, previewX, previewY, previewWidth, previewHeight, Options
                        )
                        self:drawRectBorder(
                            previewX, previewY, previewWidth, previewHeight, .65, Theme.borderSoft.r,
                            Theme.borderSoft.g, Theme.borderSoft.b
                        )
                        if texture then
                            local inset = self.compactMode and 3 or 8
                            self:drawTextureScaledAspect(
                                texture, previewX + inset, previewY + inset, previewWidth - inset * 2,
                                previewHeight - inset * 2, status.ok and 1 or 0.42, textureColor.r, textureColor.g,
                                textureColor.b
                            )
                        end
                        local pinned = self:isPinned(definition)
                        if self.pinTexture and (not self.compactMode or pinned or hovered) then
                            local pinColor = pinned and Theme.accent or Theme.textMuted
                            local iconOffset = self.compactMode and 5 or 7
                            self:drawTextureScaledAspect(
                                self.pinTexture, x + iconOffset, y + iconOffset, self.pinSize, self.pinSize,
                                pinned and 1 or .58, pinColor.r, pinColor.g, pinColor.b
                            )
                        end
                        local favorite = self:isFavorite(definition)
                        local starTexture = favorite and self.starSetTexture or self.starUnsetTexture
                        if starTexture and (not self.compactMode or favorite or hovered) then
                            local alpha = favorite and 1 or (hovered and .88 or .58)
                            local color = favorite and Theme.accent or Theme.textMuted
                            local iconOffset = self.compactMode and 5 or 7
                            self:drawTextureScaledAspect(
                                starTexture, x + self.cardWidth - self.favoriteSize - iconOffset, y + iconOffset,
                                self.favoriteSize, self.favoriteSize, alpha, color.r, color.g, color.b
                            )
                        end
                        local marker = status.pending and Theme.textMuted or (status.ok and Theme.good or Theme.warn)
                        if self.compactMode then
                            self:drawRect(x, y + self.cardHeight - 5, self.cardWidth, 5, 1, marker.r, marker.g, marker.b)
                        else
                            local name = self:shortNameFor(entry, self.cardWidth - 10)
                            local nameY = previewY + previewHeight + 6
                            self:drawTextCentre(
                                name, x + self.cardWidth / 2, nameY, Theme.text.r, Theme.text.g, Theme.text.b, 1,
                                UIFont.Small
                            )
                            local statusHeight = math.max(24, getTextManager():getFontHeight(UIFont.Small) + 8)
                            self:drawRect(
                                x, y + self.cardHeight - statusHeight, self.cardWidth, statusHeight, .28,
                                Theme.backdrop.r, Theme.backdrop.g, Theme.backdrop.b
                            )
                            self:drawRect(
                                x + 9, y + self.cardHeight - math.floor(statusHeight / 2) - 3, 6, 6, 1, marker.r,
                                marker.g, marker.b
                            )
                            local statusText = status.pending and "..."
                                or (status.ok and getText("IGUI_KBW_Ready") or getText("IGUI_KBW_Missing"))
                            self:drawText(
                                statusText, x + 18, y + self.cardHeight - statusHeight + 3, marker.r, marker.g,
                                marker.b, 1, UIFont.Small
                            )
                        end
                    end
                end
            end
        end
    end
    self:clearStencilRect()
end

return KBWBuildCardGrid
