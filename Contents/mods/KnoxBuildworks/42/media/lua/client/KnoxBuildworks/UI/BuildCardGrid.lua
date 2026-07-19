---BuildCardGrid provides the Knox Buildworks custom user-interface layer.
require "ISUI/ISPanel"

local Requirements = require("KnoxBuildworks/Validation/Requirements")
local Groups = require("KnoxBuildworks/Definitions/Groups")
local Theme = require("KnoxBuildworks/UI/Theme")
local IconResolver = require("KnoxBuildworks/UI/IconResolver")
local I18n = require("KnoxBuildworks/I18n")
local Profiler = require("KnoxBuildworks/Util/Profiler")

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
    return o
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
    self:setScrollHeight(self:contentHeight())
end

function KBWBuildCardGrid:setItems(items, selectedId)
    self.items, self.selectedIndex = items or {}, 0
    for index = 1, #self.items do
        local definition = self.items[index]
        if definition.id == selectedId then self.selectedIndex = index end
    end
    if self.selectedIndex == 0 and #self.items > 0 then self.selectedIndex = 1 end
    self:setScrollHeight(self:contentHeight())
    if self.vscroll then self:updateScrollbars() end
end

---@param mode string|nil
function KBWBuildCardGrid:setViewMode(mode)
    self.viewMode = mode == "list" and "list" or "grid"
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

function KBWBuildCardGrid:contentHeight()
    if self.viewMode == "list" then return #self.items * (self.rowHeight + self.gap) + self.gap end
    return math.ceil(#self.items / self:columns()) * (self.cardHeight + self.gap) + self.gap
end

---@param x number
---@param y number
function KBWBuildCardGrid:indexAt(x, y)
    if x >= self:drawWidth() then return 0 end
    if self.viewMode == "list" then
        local row = math.floor((y - self.gap) / (self.rowHeight + self.gap))
        if row < 0 then return 0 end
        local localY = (y - self.gap) % (self.rowHeight + self.gap)
        if localY > self.rowHeight then return 0 end
        local index = row + 1
        return index <= #self.items and index or 0
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
        local row = index - 1
        local rowY = self.gap + row * (self.rowHeight + self.gap)
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
    local starX = cardX + self.cardWidth - self.favoriteSize - 7
    local starY = cardY + 7
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
        local row = index - 1
        local rowY = self.gap + row * (self.rowHeight + self.gap)
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
    local pinX = cardX + 7
    local pinY = cardY + 7
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
    self.hoverIndex = self:indexAt(self:getMouseX(), self:getMouseY())
end

---@param dx number
---@param dy number
function KBWBuildCardGrid:onMouseMoveOutside(dx, dy)
    self.hoverIndex = 0
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
    self:setYScroll(self:getYScroll() - delta * 46)
    if self.vscroll then self:updateScrollbars() end
    return true
end

-- Static per-definition data (resolved definition, icon, display name) is
-- computed once and kept; only the readiness status has a TTL.
---@param definition KBW.BuildableDefinition
function KBWBuildCardGrid:cardData(definition)
    local id = definition.id or tostring(definition)
    local entry = self.cardCache[id]
    if not entry then
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
        entry = {
            stage = stage,
            statusStage = statusStage,
            statusDefinition = statusDefinition,
            name = displayName(definition)
        }
        entry.texture, entry.textureColor = IconResolver.textureForDefinition(definition, stage)
        self.cardCache[id] = entry
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
        local snapshot = Requirements.snapshot(self.player, self.player:getSquare())
        entry.status = entry.statusStage
            and Requirements.evaluateReadiness(self.player, entry.statusDefinition, entry.statusStage, snapshot)
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

    if self.viewMode == "list" then
        local rowStep = self.rowHeight + self.gap
        local firstIndex = math.floor((-scroll - self.gap) / rowStep) + 1
        local lastIndex = math.ceil((-scroll + self.height + self.gap) / rowStep) + 1
        if firstIndex < 1 then firstIndex = 1 end
        if lastIndex > #self.items then lastIndex = #self.items end
        for index = firstIndex, lastIndex do
            local definition = self.items[index]
            local y = self.gap + (index - 1) * (self.rowHeight + self.gap)
            local viewY = y + scroll
            if viewY + self.rowHeight >= 0 and viewY <= self.height then
                local selected, hovered = index == self.selectedIndex, index == self.hoverIndex
                local entry, status = self:cardStatus(definition)
                local texture, textureColor = entry.texture, entry.textureColor
                local fill = selected and Theme.selected or (hovered and Theme.surfaceRaised or Theme.surface)
                local border = selected and Theme.accent or (status.ok and Theme.good or Theme.borderSoft)
                local x = self.gap
                local width = safeWidth - self.gap * 2
                self:drawRect(x + 2, y + 2, width, self.rowHeight, 0.26, 0, 0, 0)
                self:drawRect(x, y, width, self.rowHeight, fill.a, fill.r, fill.g, fill.b)
                self:drawRect(x, y, 4, self.rowHeight, selected and 1 or .72, border.r, border.g, border.b)
                self:drawRectBorder(x, y, width, self.rowHeight, border.a, border.r, border.g, border.b)
                self:drawRect(x + 9, y + 9, 56, 56, .58, Theme.backdrop.r, Theme.backdrop.g, Theme.backdrop.b)
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
                self:drawText(entry.name, x + 76, y + 11, Theme.text.r, Theme.text.g, Theme.text.b, 1, UIFont.Small)
                if entry.secondary == nil then
                    entry.secondary = tostring(definition.category or "?") .. " / "
                        .. tostring(definition.subcategory or "General") .. "  -  "
                        .. tostring(definition.id or "?")
                end
                self:drawText(
                    entry.secondary, x + 76, y + 34, Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, .9,
                    UIFont.Small
                )
                local marker = status.pending and Theme.textMuted or (status.ok and Theme.good or Theme.warn)
                self:drawRect(x + 76, y + self.rowHeight - 20, 6, 6, 1, marker.r, marker.g, marker.b)
                local statusText = status.pending and "..."
                    or (status.ok and getText("IGUI_KBW_Ready") or getText("IGUI_KBW_Missing"))
                self:drawText(
                    statusText, x + 82, y + self.rowHeight - 26, marker.r, marker.g, marker.b, 1, UIFont.Small
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
                        local texture, textureColor = entry.texture, entry.textureColor
                        local fill = selected and Theme.selected or (hovered and Theme.surfaceRaised or Theme.surface)
                        local border = selected and Theme.accent or (status.ok and Theme.good or Theme.borderSoft)
                        self:drawRect(x + 2, y + 2, self.cardWidth, self.cardHeight, 0.24, 0, 0, 0)
                        self:drawRect(x, y, self.cardWidth, self.cardHeight, fill.a, fill.r, fill.g, fill.b)
                        self:drawRect(x, y, self.cardWidth, 3, selected and 1 or .68, border.r, border.g, border.b)
                        self:drawRectBorder(
                            x, y, self.cardWidth, self.cardHeight, border.a, border.r, border.g, border.b
                        )
                        self:drawRect(x + 17, y + 12, 84, 70, .46, Theme.backdrop.r, Theme.backdrop.g, Theme.backdrop.b)
                        self:drawRectBorder(
                            x + 17, y + 12, 84, 70, .55, Theme.borderSoft.r, Theme.borderSoft.g, Theme.borderSoft.b
                        )
                        if texture then
                            self:drawTextureScaledAspect(
                                texture, x + 25, y + 14, 68, 68, status.ok and 1 or 0.42, textureColor.r, textureColor.g,
                                textureColor.b
                            )
                        end
                        local pinned = self:isPinned(definition)
                        if self.pinTexture then
                            local pinColor = pinned and Theme.accent or Theme.textMuted
                            self:drawTextureScaledAspect(
                                self.pinTexture, x + 7, y + 7, self.pinSize, self.pinSize, pinned and 1 or .58,
                                pinColor.r, pinColor.g, pinColor.b
                            )
                        end
                        local favorite = self:isFavorite(definition)
                        local starTexture = favorite and self.starSetTexture or self.starUnsetTexture
                        if starTexture then
                            local alpha = favorite and 1 or (hovered and .88 or .58)
                            local color = favorite and Theme.accent or Theme.textMuted
                            self:drawTextureScaledAspect(
                                starTexture, x + self.cardWidth - self.favoriteSize - 7, y + 7, self.favoriteSize,
                                self.favoriteSize, alpha, color.r, color.g, color.b
                            )
                        end
                        local name = self:shortNameFor(entry, self.cardWidth - 10)
                        self:drawTextCentre(
                            name, x + self.cardWidth / 2, y + 88, Theme.text.r, Theme.text.g, Theme.text.b, 1,
                            UIFont.Small
                        )
                        local marker = status.pending and Theme.textMuted or (status.ok and Theme.good or Theme.warn)
                        self:drawRect(
                            x, y + self.cardHeight - 24, self.cardWidth, 24, .28, Theme.backdrop.r, Theme.backdrop.g,
                            Theme.backdrop.b
                        )
                        self:drawRect(x + 9, y + self.cardHeight - 15, 6, 6, 1, marker.r, marker.g, marker.b)
                        local statusText = status.pending and "..."
                            or (status.ok and getText("IGUI_KBW_Ready") or getText("IGUI_KBW_Missing"))
                        self:drawText(
                            statusText, x + 18, y + self.cardHeight - 21, marker.r, marker.g, marker.b, 1, UIFont.Small
                        )
                    end
                end
            end
        end
    end
    self:clearStencilRect()
end

return KBWBuildCardGrid
