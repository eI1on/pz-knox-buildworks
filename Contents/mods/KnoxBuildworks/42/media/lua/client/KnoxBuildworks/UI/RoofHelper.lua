require "ISUI/ISCollapsableWindow"
require "ISUI/ISButton"
require "ISUI/ISPanel"
local RoofPlanner = require("KnoxBuildworks/Planning/RoofPlanner")
local RoomShape = require("KnoxBuildworks/Planning/RoomShape")
local Registry = require("KnoxBuildworks/Definitions/Registry")
local Resolver = require("KnoxBuildworks/Definitions/Resolver")
local Blueprints = require("KnoxBuildworks/Planning/Blueprints")
local GhostRenderer = require("KnoxBuildworks/Planning/GhostRenderer")
local Theme = require("KnoxBuildworks/UI/Theme")
local Visibility = require("KnoxBuildworks/UI/CatalogVisibility")
local I18n = require("KnoxBuildworks/I18n")
local WallFinishes = require("KnoxBuildworks/Validation/WallFinishes")
local Matrix = require("KnoxBuildworks/Geometry/Matrix")
local RoofModelView = require("KnoxBuildworks/UI/RoofModelView")

KBWRoofHelper = ISCollapsableWindow:derive("KBWRoofHelper")

local PAD = 12
local MODEL_W = 132
-- Milliseconds of layout work per frame for the shown family, and for
-- quietly preparing the families next to it in the carousel.
local FRAME_BUDGET_MS = 4
local PREFETCH_BUDGET_MS = 2
local SLICE = 40
local CACHE_LIMIT = 24
-- True-colour ghosts: the player judges the real tiles, not a tinted blob.
local PREVIEW_COLOR = { r = 1, g = 1, b = 1, a = 0.82 }
local HOVER_COLOR = { r = 0.85, g = 0.95, b = 1, a = 0.62 }

local function fontHeight()
    return getTextManager():getFontHeight(UIFont.Small)
end

local function textWidth(text)
    return getTextManager():MeasureStringX(UIFont.Small, text)
end

-- Greedy word wrap; long words are never cut or ellipsised.
local function wrap(text, width)
    local lines, line = {}, ""
    for word in string.gmatch(text or "", "%S+") do
        local candidate = line == "" and word or line .. " " .. word
        if line ~= "" and textWidth(candidate) > width then
            lines[#lines + 1] = line
            line = word
        else
            line = candidate
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return lines
end

local function textureFor(spriteName)
    if type(spriteName) ~= "string" or not getTexture then return nil end
    return getTexture(spriteName)
end

local function entrySprite(entry)
    if not entry or not entry.stage then return nil end
    return RoofPlanner.faceSprite(entry.stage, entry.face or "W")
end

-- ---------------------------------------------------------------------------
-- Carousel: "< label (n/m) >", the same pattern as the catalogue's stage
-- selector, used for the option steppers. With a preview size it becomes a
-- picker card instead: a framed, large tile preview with the name wrapped
-- under it and tall arrow strips on both sides. The wheel and a click on the
-- body also step through it.
-- ---------------------------------------------------------------------------

KBWRoofCarousel = ISPanel:derive("KBWRoofCarousel")

---@param preview number|nil size of the square tile preview; nil for a one-line stepper
---@param nameLines number|nil lines reserved for the name under the preview
function KBWRoofCarousel:new(x, y, w, h, target, onChange, preview, nameLines)
    local o = ISPanel.new(self, x, y, w, h)
    o.target, o.onChange = target, onChange
    o.preview = type(preview) == "number" and preview or nil
    o.nameLines = nameLines or 2
    o.items, o.selected = {}, 1
    o.backgroundColor = Theme.color(Theme.surface)
    o.borderColor = Theme.color(Theme.borderSoft)
    return o
end

-- Width of the arrow buttons: square on a stepper, a narrow full-height strip
-- on a card.
function KBWRoofCarousel:arrowWidth()
    if self.preview then return math.max(22, math.floor(fontHeight() * 1.2)) end
    return self.height
end

function KBWRoofCarousel:createChildren()
    local aw = self:arrowWidth()
    self.prev = ISButton:new(0, 0, aw, self.height, "<", self, KBWRoofCarousel.onArrow)
    self.prev.internal = -1
    self.next = ISButton:new(self.width - aw, 0, aw, self.height, ">", self, KBWRoofCarousel.onArrow)
    self.next.internal = 1
    for _, button in pairs({ self.prev, self.next }) do
        button:initialise(); button:instantiate()
        Theme.applyActionButton(button, true, false)
        self:addChild(button)
    end
end

-- Height a card needs for a preview of this size and the reserved name lines.
function KBWRoofCarousel.cardHeight(preview, nameLines)
    return 6 + preview + 6 + (nameLines or 2) * (fontHeight() + 2) + 4
end

function KBWRoofCarousel:setItems(items, selected)
    self.items = items or {}
    self.selected = math.max(1, math.min(#self.items, selected or self.selected or 1))
    local enabled = #self.items > 1
    Theme.setButtonEnabled(self.prev, enabled)
    Theme.setButtonEnabled(self.next, enabled)
end

function KBWRoofCarousel:current()
    return self.items[self.selected]
end

function KBWRoofCarousel:step(delta)
    if #self.items < 2 then return end
    local selected = self.selected + delta
    if selected < 1 then selected = #self.items end
    if selected > #self.items then selected = 1 end
    self.selected = selected
    if self.onChange then self.onChange(self.target, self) end
end

function KBWRoofCarousel:onArrow(button)
    self:step(button.internal or 1)
end

function KBWRoofCarousel:onMouseWheel(delta)
    self:step(delta > 0 and 1 or -1)
    return true
end

function KBWRoofCarousel:onMouseDown(x, y)
    local aw = self:arrowWidth()
    if x > aw and x < self.width - aw then self:step(1) end
    return true
end

local function colorParts(c)
    return c[1] or c.r or 1, c[2] or c.g or 1, c[3] or c.b or 1
end

-- Draws a tile cropped to its visible pixels and scaled to fit the box, so a
-- 64x128 sheet tile fills the preview instead of floating small in its frame.
-- Paint finishes are previewed on the painted sprite tinted with the colour,
-- the way the game shows painted walls.
function KBWRoofCarousel:drawTile(item, x, y, size)
    local texture, inset = item.texture, 5
    local w, h = texture and texture:getWidth() or 0, texture and texture:getHeight() or 0
    if w > 0 and h > 0 then
        local scale = math.min((size - inset * 2) / w, (size - inset * 2) / h)
        local dw, dh = math.floor(w * scale), math.floor(h * scale)
        local r, g, b = 1, 1, 1
        if item.color then r, g, b = colorParts(item.color) end
        self:drawTextureScaled(texture, x + math.floor((size - dw) / 2), y + math.floor((size - dh) / 2), dw, dh, 1, r, g, b)
        if item.color then
            local chip = math.max(10, math.floor(size / 6))
            self:drawRect(x + 4, y + size - chip - 4, chip, chip, 1, r, g, b)
            self:drawRectBorder(x + 4, y + size - chip - 4, chip, chip, 1, Theme.border.r, Theme.border.g, Theme.border.b)
        end
    elseif item.color then
        local r, g, b = colorParts(item.color)
        local inner = size - 20
        self:drawRect(x + 10, y + 10, inner, inner, 1, r, g, b)
        self:drawRectBorder(x + 10, y + 10, inner, inner, 1, Theme.border.r, Theme.border.g, Theme.border.b)
    end
end

-- A label too long for its space is shown whole above the control on hover.
function KBWRoofCarousel:drawHoverLabel(text, left)
    if not (self.truncated and self:isMouseOver()) then return end
    local w = textWidth(text) + 12
    local h = fontHeight() + 6
    local x = math.max(0, math.min(left, self.width - w))
    self:drawRect(x, -h - 2, w, h, 0.95, Theme.backdrop.r, Theme.backdrop.g, Theme.backdrop.b)
    self:drawRectBorder(x, -h - 2, w, h, 1, Theme.border.r, Theme.border.g, Theme.border.b)
    self:drawText(text, x + 6, -h + 1, Theme.text.r, Theme.text.g, Theme.text.b, 1, UIFont.Small)
end

function KBWRoofCarousel:renderCard()
    local item = self:current()
    local aw = self:arrowWidth()
    local left, right = aw + 6, self.width - aw - 6
    local size = math.max(16, math.min(self.preview, right - left))
    local boxX, boxY = math.floor((self.width - size) / 2), 6
    local hover = self:isMouseOver() and #self.items > 1
    local frame = hover and Theme.surfaceRaised or Theme.backdrop
    self:drawRect(boxX, boxY, size, size, 0.85, frame.r, frame.g, frame.b)
    self:drawRectBorder(boxX, boxY, size, size, 1, Theme.borderSoft.r, Theme.borderSoft.g, Theme.borderSoft.b)
    self:setStencilRect(boxX + 1, boxY + 1, size - 2, size - 2)
    if item then self:drawTile(item, boxX, boxY, size) end
    if #self.items > 1 then
        local counter = self.selected .. "/" .. #self.items
        local cw, ch = textWidth(counter) + 8, fontHeight() + 2
        local cx, cy = boxX + size - cw - 2, boxY + size - ch - 2
        self:drawRect(cx, cy, cw, ch, 0.8, Theme.backdrop.r, Theme.backdrop.g, Theme.backdrop.b)
        self:drawText(counter, cx + 4, cy + 1, Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 1, UIFont.Small)
    end
    self:clearStencilRect()
    -- Name: centred and wrapped under the preview, never ellipsised; a name
    -- longer than the reserved lines is shown whole on hover.
    local text = item and item.label or getText("IGUI_KBW_RoofNoChoices")
    local color = item and Theme.text or Theme.textMuted
    local lines = wrap(text, right - left)
    local lineH = fontHeight() + 2
    local top = boxY + size + 6
    self.truncated = #lines > self.nameLines
    self:setStencilRect(left, top, right - left, self.height - top)
    for index = 1, math.min(#lines, self.nameLines) do
        local line = lines[index]
        self:drawText(line, math.floor((self.width - textWidth(line)) / 2), top + (index - 1) * lineH,
            color.r, color.g, color.b, 1, UIFont.Small)
    end
    self:clearStencilRect()
    self:drawHoverLabel(text, left)
end

function KBWRoofCarousel:render()
    if self.preview then return self:renderCard() end
    local item = self:current()
    local left, right = self.height + 4, self.width - self.height - 4
    self:setStencilRect(left, 0, right - left, self.height)
    local x = left + 2
    local text = item and item.label or getText("IGUI_KBW_RoofNoChoices")
    local counter = #self.items > 1 and ("  " .. self.selected .. "/" .. #self.items) or ""
    local textY = (self.height - fontHeight()) / 2
    local width = right - x - textWidth(counter)
    -- Never ellipsise: a long label is clipped by the stencil and shown in full
    -- on hover.
    self:drawText(text, x, textY, Theme.text.r, Theme.text.g, Theme.text.b, 1, UIFont.Small)
    if counter ~= "" then
        self:drawTextRight(counter, right, textY, Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 1,
            UIFont.Small)
    end
    self.truncated = textWidth(text) > width
    self:clearStencilRect()
    self:drawHoverLabel(text, left)
end

-- ---------------------------------------------------------------------------
-- Layout list. Everything is clipped to the viewport twice: a stencil, and
-- by hand (rows, text and model polygons outside the list are never drawn),
-- so nothing can spill over the controls around it.
-- ---------------------------------------------------------------------------

KBWRoofLayoutList = ISPanel:derive("KBWRoofLayoutList")

function KBWRoofLayoutList:new(x, y, w, h, helper)
    local o = ISPanel.new(self, x, y, w, h)
    o.helper = helper
    o.rows = {}
    o.scroll = 0
    o.backgroundColor = Theme.color(Theme.surface)
    o.borderColor = Theme.color(Theme.borderSoft)
    return o
end

function KBWRoofLayoutList:layoutRow(row, textW)
    local lineH = fontHeight() + 2
    row.lines = { { text = row.name, color = Theme.accent } }
    local function add(text, color)
        local lines = wrap(text, textW)
        for j = 1, #lines do row.lines[#row.lines + 1] = { text = lines[j], color = color } end
    end
    add(row.description, Theme.text)
    add(row.stats, Theme.textMuted)
    for t = 1, #(row.tags or {}) do add(row.tags[t].text, row.tags[t].color) end
    row.height = math.max(84, #row.lines * lineH + 14)
    row.wrappedFor = textW
end

function KBWRoofLayoutList:setRows(rows)
    self.rows = rows or {}
    local textW = self.width - MODEL_W - PAD * 3 - 10
    local y = 0
    for i = 1, #self.rows do
        local row = self.rows[i]
        if row.wrappedFor ~= textW then self:layoutRow(row, textW) end
        row.y = y
        y = y + row.height
    end
    self.contentHeight = y
    self:clampScroll()
end

function KBWRoofLayoutList:clampScroll()
    local maxScroll = math.max(0, (self.contentHeight or 0) - self.height)
    self.scroll = math.max(0, math.min(maxScroll, self.scroll))
end

function KBWRoofLayoutList:scrollTo(index)
    local row = self.rows[index]
    if not row then return end
    if row.y < self.scroll then self.scroll = row.y
    elseif row.y + row.height > self.scroll + self.height then self.scroll = row.y + row.height - self.height end
    self:clampScroll()
end

function KBWRoofLayoutList:rowAt(y)
    if y < 0 or y >= self.height then return nil end
    local contentY = y + self.scroll
    for i = 1, #self.rows do
        local row = self.rows[i]
        if contentY >= row.y and contentY < row.y + row.height then return i end
    end
    return nil
end

function KBWRoofLayoutList:onMouseWheel(delta)
    self.scroll = self.scroll + delta * 48
    self:clampScroll()
    return true
end

function KBWRoofLayoutList:onMouseMove(dx, dy)
    local index = self:rowAt(self:getMouseY())
    if index ~= self.hover then
        self.hover = index
        self.helper:onHoverLayout(index)
    end
end

function KBWRoofLayoutList:onMouseMoveOutside(dx, dy)
    if self.hover then
        self.hover = nil
        self.helper:onHoverLayout(nil)
    end
end

function KBWRoofLayoutList:onMouseDown(x, y)
    local index = self:rowAt(y)
    if index then self.helper:selectLayout(index) end
    return true
end

-- Rectangle clipped to the vertical viewport [1, height - 1].
function KBWRoofLayoutList:clippedRect(x, y, w, h, a, r, g, b)
    local top, bottom = math.max(y, 1), math.min(y + h, self.height - 1)
    if bottom > top then self:drawRect(x, top, w, bottom - top, a, r, g, b) end
end

function KBWRoofLayoutList:render()
    local width = self.width
    local viewW = width - 10
    self:setStencilRect(1, 1, width - 2, self.height - 2)
    local lineH = fontHeight() + 2
    for i = 1, #self.rows do
        local row = self.rows[i]
        local top = row.y - self.scroll
        if top + row.height > 0 and top < self.height then
            if i == self.helper.selectedIndex then
                local c = Theme.selected
                self:clippedRect(2, top + 1, viewW - 2, row.height - 2, c.a, c.r, c.g, c.b)
                local a = Theme.accent
                self:clippedRect(2, top + 1, viewW - 2, 1, 1, a.r, a.g, a.b)
                self:clippedRect(2, top + row.height - 2, viewW - 2, 1, 1, a.r, a.g, a.b)
                self:clippedRect(2, top + 1, 1, row.height - 2, 1, a.r, a.g, a.b)
                self:clippedRect(viewW - 1, top + 1, 1, row.height - 2, 1, a.r, a.g, a.b)
            elseif i == self.hover then
                local c = Theme.surfaceRaised
                self:clippedRect(2, top + 1, viewW - 2, row.height - 2, c.a, c.r, c.g, c.b)
            end
            self:clippedRect(PAD, top + 6, MODEL_W, row.height - 12, 0.85, 0.03, 0.03, 0.03)
            if row.model then
                RoofModelView.draw(self, row.model, PAD + 4, top + 10, MODEL_W - 8, row.height - 20,
                    row.blocked and 0.55 or 1, row.blocked and { r = 1, g = 0.55, b = 0.5 } or nil,
                    1, self.height - 1)
            end
            local tx = PAD * 2 + MODEL_W
            local ty = top + 7
            for j = 1, #row.lines do
                if ty >= 1 and ty + lineH <= self.height - 1 then
                    local line = row.lines[j]
                    self:drawText(line.text, tx, ty, line.color.r, line.color.g, line.color.b, 1, UIFont.Small)
                end
                ty = ty + lineH
            end
            local b = Theme.borderSoft
            self:clippedRect(4, top + row.height - 1, viewW - 8, 1, 0.6, b.r, b.g, b.b)
        end
    end
    if #self.rows == 0 and self.helper.emptyText then
        local lines = wrap(self.helper.emptyText, width - PAD * 2)
        for j = 1, #lines do
            local y = PAD + (j - 1) * lineH
            if y + lineH <= self.height then
                self:drawText(lines[j], PAD, y, Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 1, UIFont.Small)
            end
        end
    end
    self:clearStencilRect()
    -- Scrollbar track and thumb inside the viewport.
    local content = self.contentHeight or 0
    if content > self.height then
        local trackX = width - 7
        local s = Theme.surfaceRaised
        self:drawRect(trackX, 2, 5, self.height - 4, 0.6, s.r, s.g, s.b)
        local thumb = math.max(24, (self.height - 4) * self.height / content)
        local y = 2 + (self.height - 4 - thumb) * self.scroll / (content - self.height)
        self:drawRect(trackX, y, 5, thumb, 0.9, Theme.accent.r, Theme.accent.g, Theme.accent.b)
    end
end

-- ---------------------------------------------------------------------------
-- Helper window
-- ---------------------------------------------------------------------------

function KBWRoofHelper:new(owner, blueprint, room)
    local width = math.max(620, fontHeight() * 31)
    local o = ISCollapsableWindow.new(self, owner.screenLeft + (owner.screenW - width) / 2,
        owner.screenTop + 60, width, 600)
    o.owner, o.player, o.blueprintId, o.room = owner, owner.player, blueprint.id, copyTable(room)
    o.title, o.resizable = getText("IGUI_KBW_RoofHelper"), false
    o.backgroundColor, o.borderColor = Theme.color(Theme.backdrop), Theme.color(Theme.border)
    o.layouts = {}
    o.cache, o.cacheOrder = {}, {}
    o.styleCache, o.allowedCache, o.shapeCache = {}, {}, {}
    return o
end

---True when the helper can build every layout of this family itself.
function KBWRoofHelper.isAutomatic(profile)
    if not profile then return false end
    if profile.stepsPerLevel then return true end
    -- A family with only flat roof tiles is automatic too (flat layouts).
    return profile.flat ~= nil and #(profile.details or {}) == 0
end

-- Option steppers: value lists for the small carousels.
local OVERHANG = { 0, 1, 2 }
local RISE = { false, 1, 2, 3, 4 }
local ELEVATION = { 0, 1, 2, 3, 4, 5, 6, 7, 8 }
local CEILING = { "auto", "yes", "no" }
local EAVES = { true, false }
local ACCENTS = { true, false }

local function steps(values, label)
    local items = {}
    for i = 1, #values do items[i] = { value = values[i], label = label(values[i]) } end
    return items
end

function KBWRoofHelper:createChildren()
    ISCollapsableWindow.createChildren(self)
    local blueprint = Blueprints.get(self.player, self.blueprintId)
    self.region = self:getRegion(blueprint)
    local definitions = {}
    local all = Registry:list()
    for index = 1, #all do
        local definition = all[index]
        -- Do not invoke catalogue callbacks for thousands of unrelated pieces.
        for stageIndex = 1, #(definition.stages or {}) do
            if definition.stages[stageIndex].roof then
                if Visibility.definitionEnabled(definition) then definitions[#definitions + 1] = definition end
                break
            end
        end
    end
    local function allowed(definition, stage)
        return Visibility.stagePasses(self.player, definition, stage, false)
    end
    -- Only families the helper can lay out by itself. Detail-only sets
    -- (tents) stay in the catalogue; shallow sets are offered but only for
    -- layouts two rows high (the planner rejects taller ones).
    self.profiles = {}
    local all = RoofPlanner.profiles(definitions, allowed)
    for index = 1, #all do
        if KBWRoofHelper.isAutomatic(all[index]) then self.profiles[#self.profiles + 1] = all[index] end
    end
    table.sort(self.profiles, function(a, b) return a.id < b.id end)
    self.gableProfiles = RoofPlanner.gables(definitions, allowed)
    self.accentSet = RoofPlanner.accents(definitions, allowed)[1]

    local fontH = fontHeight()
    local row = math.max(28, fontH + 12)
    local inner = self.width - PAD * 2
    local half = (inner - PAD) / 2
    local y = self:titleBarHeight() + 10
    self.labels = {}
    local function label(text, x, ly)
        self.labels[#self.labels + 1] = { text = text, x = x, y = ly }
    end
    local lineH = fontH + 2
    -- Label column on the left (wrapped, never cut), carousel on the right,
    -- like the catalogue's variant/material/finish selectors. Returns the
    -- height the row used.
    local function labelWidth(keys, w, share)
        local widest = 0
        for i = 1, #keys do widest = math.max(widest, textWidth(getText(keys[i]))) end
        return math.max(86, math.min(math.floor(w * share), widest + 14))
    end
    local function carousel(key, x, cy, w, text, onChange, labelW)
        local lines = wrap(text, labelW - 8)
        local height = math.max(row, #lines * lineH + 4)
        local textTop = cy + math.floor((height - #lines * lineH) / 2)
        for j = 1, #lines do
            self.labels[#self.labels + 1] = { text = lines[j], x = x, y = textTop + (j - 1) * lineH, key = key }
        end
        local c = KBWRoofCarousel:new(x + labelW, cy + math.floor((height - row) / 2), w - labelW, row, self, onChange)
        c:initialise(); c:instantiate()
        self:addChild(c)
        self[key] = c
        return height
    end
    -- Picker cards side by side: roof family, gable walls, gable finish. Each
    -- has its heading above it and a large preview of the real tile.
    local cards = {
        { "family", "IGUI_KBW_RoofStyle", KBWRoofHelper.onFamilyChanged },
        { "gable", "IGUI_KBW_RoofGableMaterial", KBWRoofHelper.onGableChanged },
        { "finish", "IGUI_KBW_RoofGableFinish", KBWRoofHelper.onOptionsChanged },
    }
    local cardW = math.floor((inner - PAD * 2) / 3)
    -- Option steppers.
    local options = {
        { "overhang", "IGUI_KBW_RoofOverhang", steps(OVERHANG, function(v) return tostring(v) end) },
        { "rise", "IGUI_KBW_RoofRise", steps(RISE, function(v)
            return v and tostring(v) or getText("IGUI_KBW_RoofFullRise") end) },
        { "elevation", "IGUI_KBW_RoofElevation", steps(ELEVATION, function(v) return tostring(v) end) },
        { "ceiling", "IGUI_KBW_RoofCeiling", steps(CEILING, function(v)
            return getText(v == "auto" and "IGUI_KBW_RoofCeilingAuto" or v == "yes" and "IGUI_KBW_Yes" or "IGUI_KBW_No") end) },
        { "eaves", "IGUI_KBW_RoofEaves", steps(EAVES, function(v) return getText(v and "IGUI_KBW_Yes" or "IGUI_KBW_No") end) },
        { "accents", "IGUI_KBW_RoofAccents", steps(ACCENTS, function(v) return getText(v and "IGUI_KBW_Yes" or "IGUI_KBW_No") end) },
    }
    -- Steppers line up under the cards in three columns when a label, the
    -- widest value and both arrows fit in a card's width; two otherwise.
    local optionKeys, widestValue = {}, 0
    for index = 1, #options do
        optionKeys[index] = options[index][2]
        for v = 1, #options[index][3] do widestValue = math.max(widestValue, textWidth(options[index][3][v].label)) end
    end
    local columns = 2
    local thirdLabel = labelWidth(optionKeys, cardW, 0.55)
    if thirdLabel + widestValue + textWidth("  0/0") + row * 2 + 16 <= cardW then columns = 3 end
    local columnW = columns == 3 and cardW or half
    local optionLabel = columns == 3 and thirdLabel or labelWidth(optionKeys, half, 0.55)
    local arrowW = math.max(22, math.floor(fontH * 1.2))
    local headings, headingLines = {}, 1
    for index = 1, #cards do
        headings[index] = wrap(getText(cards[index][2]), cardW - 4)
        headingLines = math.max(headingLines, #headings[index])
    end
    -- The preview is as large as the card allows, shrunk (never below 64 px)
    -- only when a large UI font would push the window past the screen.
    local optionRows, rowGroup = 0, 0
    for index = 1, #options do
        local lines = #wrap(getText(options[index][2]), optionLabel - 8)
        rowGroup = math.max(rowGroup, math.max(row, lines * lineH + 4))
        if (index - 1) % columns == columns - 1 or index == #options then
            optionRows = optionRows + rowGroup + 6; rowGroup = 0
        end
    end
    local screenH = self.owner.screenH or (getCore and getCore():getScreenHeight()) or 900
    local rest = y + headingLines * lineH + 4 + KBWRoofCarousel.cardHeight(0, 2) + 10 + optionRows + 4
        + (fontH + 6) + (lineH * 2 + 6) + 112 + 8 + row + PAD + 16
    local preview = math.min(cardW - 2 * (arrowW + 6), math.max(104, fontH * 2 + 48))
    preview = math.max(64, math.min(preview, screenH - rest))
    local cardH = KBWRoofCarousel.cardHeight(preview, 2)
    for index = 1, #cards do
        local spec = cards[index]
        local x = PAD + (index - 1) * (cardW + PAD)
        local lines = headings[index]
        local top = y + (headingLines - #lines) * lineH
        for j = 1, #lines do
            local tx = x + math.floor((cardW - textWidth(lines[j])) / 2)
            self.labels[#self.labels + 1] = { text = lines[j], x = tx, y = top + (j - 1) * lineH, key = spec[1] }
        end
        local c = KBWRoofCarousel:new(x, y + headingLines * lineH + 4, cardW, cardH, self, spec[3], preview, 2)
        c:initialise(); c:instantiate()
        self:addChild(c)
        self[spec[1]] = c
    end
    y = y + headingLines * lineH + 4 + cardH + 10
    local rowHeight = 0
    for index = 1, #options do
        local spec = options[index]
        local column = (index - 1) % columns
        local x = PAD + column * (columnW + PAD)
        rowHeight = math.max(rowHeight, carousel(spec[1], x, y, columnW, getText(spec[2]),
            KBWRoofHelper.onOptionsChanged, optionLabel))
        self[spec[1]]:setItems(spec[3], 1)
        if column == columns - 1 or index == #options then y = y + rowHeight + 6; rowHeight = 0 end
    end
    y = y + 4
    self.elevation:setItems(self.elevation.items, 2)
    -- Layouts header: the title, a "?" with the how-to in its tooltip, and a
    -- two-line summary (footprint, then the chosen layout or why none fits)
    -- in place of the old scrolling status box under the list.
    label(getText("IGUI_KBW_RoofLayouts"), PAD, y)
    local helpSize = fontH + 6
    self.help = ISButton:new(self.width - PAD - helpSize, y - 3, helpSize, helpSize, "?", self, nil)
    self.help:initialise(); self.help:instantiate()
    Theme.applyActionButton(self.help, true, false)
    self.help:setTooltip(getText("IGUI_KBW_RoofHelp"))
    self:addChild(self.help)
    y = y + fontH + 6
    self.summaryY, self.summaryLineH = y, lineH
    y = y + lineH * 2 + 6
    local fixed = y + 8 + row + PAD
    local listH = math.max(96, math.min(math.floor(screenH * 0.42), screenH - fixed - 16))
    self.list = KBWRoofLayoutList:new(PAD, y, inner, listH, self)
    self.list:initialise(); self.list:instantiate()
    self:addChild(self.list)
    y = y + listH + 8
    local halfButton = (inner - PAD) / 2
    local function button(x, text, handler, primary)
        local b = ISButton:new(x, y, halfButton, row, getText(text), self, handler)
        b:initialise(); b:instantiate(); self:addChild(b)
        Theme.applyActionButton(b, true, primary)
        return b
    end
    self.apply = button(PAD, "IGUI_KBW_RoofApply", KBWRoofHelper.onApply, true)
    self.closeButton2 = button(PAD * 2 + halfButton, "IGUI_KBW_Close", KBWRoofHelper.close, false)
    self:setHeight(y + row + PAD)
    self:setY(self.owner.screenTop + math.max(0, ((self.owner.screenH or self.height) - self.height) / 2))

    self:fillFamilies()
    self.renderGhosts = function()
        local currentPlayer = getPlayer()
        if not currentPlayer or currentPlayer:getPlayerNum() ~= self.player:getPlayerNum() or not self:getIsVisible() then
            return
        end
        local playerIndex = currentPlayer:getPlayerNum()
        local layout = self.layouts[self.hoverIndex or self.selectedIndex or 0]
        if layout and layout.preview then
            local color = layout.reason and GhostRenderer.CONFLICT_COLOR
                or (self.hoverIndex and self.hoverIndex ~= self.selectedIndex and HOVER_COLOR or PREVIEW_COLOR)
            GhostRenderer.renderBlueprint(layout.preview, nil, nil, nil, playerIndex, color)
        end
        if self.roofOutline then
            GhostRenderer.renderOutline(self.roofOutline, self.roofOutlineZ,
                { r = 0.36, g = 0.82, b = 1.00, a = 0.34 }, playerIndex)
            GhostRenderer.flushWorldAreaHighlights(playerIndex)
        end
    end
    Events.OnPostRender.Add(self.renderGhosts)
    self.rebuildAt = 0
    Theme.setButtonEnabled(self.apply, false)
end

-- ---------------------------------------------------------------------------
-- Choices
-- ---------------------------------------------------------------------------

local function pitchText(profile)
    if profile.pitch == "shallow" then return getText("IGUI_KBW_RoofShallow") end
    if profile.pitch == "custom" then return getText("IGUI_KBW_RoofCustom") end
    return tostring(profile.pitch) .. "°"
end

function KBWRoofHelper:fillFamilies()
    local items = {}
    for index = 1, #self.profiles do
        local profile = self.profiles[index]
        local text = I18n.subcategory(profile.label) .. " | " .. pitchText(profile)
        local icon = (profile.pieces or {})["slope:S:2"] or (profile.pieces or {})["slope:S:1"]
            or (profile.details or {})[1] or profile.flat
        items[index] = { profile = profile, label = text, texture = textureFor(entrySprite(icon)) }
    end
    self.family:setItems(items, 1)
    for index = 1, #self.profiles do
        if self.profiles[index].complete and self.profiles[index].pitch == 45 then self.family.selected = index; break end
    end
    self:fillGables()
end

function KBWRoofHelper:selectedProfile()
    local item = self.family and self.family:current()
    return item and item.profile or nil
end

-- Gable family whose walls are most common on the roofed storey.
function KBWRoofHelper:matchingGable(blueprint, gables)
    if #gables == 0 or not blueprint then return nil end
    local storey = self.room.z or 0
    local votes, best = {}, nil
    local placements = blueprint.placements or {}
    for index = 1, #placements do
        local p = placements[index]
        if (p.z or 0) == storey and type(p.buildableId) == "string" then
            local name = string.match(p.buildableId, "([^%.]+)$") or p.buildableId
            for g = 1, #gables do
                local family = gables[g].family
                if type(family) == "string" and string.sub(name, 1, #family + 1) == family .. "_" then
                    votes[g] = (votes[g] or 0) + 1
                    if not best or votes[g] > votes[best] then best = g end
                end
            end
        end
    end
    return best
end

function KBWRoofHelper:fillGables()
    local profile = self:selectedProfile()
    local pitch = profile and profile.pitch
    if self.gablePitch == pitch and self.gable.items and #self.gable.items > 0 then return end
    self.gablePitch = pitch
    local previous = self.gable:current()
    local items = { { label = getText("IGUI_KBW_RoofNoGables") } }
    local gables = {}
    for index = 1, #self.gableProfiles do
        local gable = self.gableProfiles[index]
        if profile and gable.pitch == pitch then
            gables[#gables + 1] = gable
            local icon = gable.parts["W:peak:3"] or gable.parts["W:peak:6"] or gable.parts["W:lowS:3"] or gable.fills.W
            items[#items + 1] = { gable = gable, label = I18n.subcategory(gable.label), texture = textureFor(entrySprite(icon)) }
        end
    end
    local selected = #items > 1 and 2 or 1
    local best = self:matchingGable(Blueprints.get(self.player, self.blueprintId), gables)
    if best then selected = best + 1 end
    -- Keep the same siding when switching between pitches of one family.
    for index = 2, #items do
        if previous and previous.gable and items[index].gable.family == previous.gable.family then selected = index end
    end
    self.gable:setItems(items, selected)
    self:fillGableStyles()
end

-- Every look the end walls can be built in: the plain wall, each variant
-- that all slope pieces have (old brick, ...), and each paint, plaster or
-- wallpaper that every piece of that variant can take.
function KBWRoofHelper:gableStyles(gable)
    if not gable then return {} end
    local cached = self.styleCache[gable.id]
    if cached then return cached end
    local pieces = {}
    for _, e in pairs(gable.parts or {}) do pieces[#pieces + 1] = e end
    local fills = {}
    for _, e in pairs(gable.fills or {}) do fills[#fills + 1] = e end
    local variants, variantOrder = nil, {}
    for i = 1, #pieces do
        local definition = Registry:get(pieces[i].buildableId)
        local has = {}
        for v = 1, #((definition and definition.variants) or {}) do
            local variant = definition.variants[v]
            has[variant.id] = variant
            if not variants and i == 1 then variantOrder[#variantOrder + 1] = variant end
        end
        if not variants then variants = has
        else
            for id in pairs(variants) do if not has[id] then variants[id] = nil end end
        end
    end
    variants = variants or {}
    local styles = {}
    local function finishKey(f)
        return tostring(f.plaster == true) .. "|" .. tostring(f.paintType) .. "|" .. tostring(f.wallpaperType)
    end
    local function addVariant(variantId, variantLabel)
        styles[#styles + 1] = { id = tostring(variantId), variantId = variantId, label = variantLabel }
        -- Finishes all pieces of this look accept.
        local common, order = nil, {}
        local all = {}
        for i = 1, #pieces do all[#all + 1] = pieces[i] end
        for i = 1, #fills do all[#all + 1] = fills[i] end
        for i = 1, #all do
            local e = all[i]
            local definition, stage = Resolver.resolveStage(e.buildableId, variantId, nil, e.stageId)
            if not definition and variantId then
                definition, stage = Resolver.resolveStage(e.buildableId, nil, nil, e.stageId)
            end
            local entries = definition and WallFinishes.entriesFor(definition, stage) or {}
            local here = {}
            for k = 1, #entries do
                local f = entries[k]
                if WallFinishes.isWallFinish(f) then
                    local key = finishKey(f)
                    here[key] = f
                    if not common then order[#order + 1] = key end
                end
            end
            if not common then common = here
            else
                for key in pairs(common) do if not here[key] then common[key] = nil end end
            end
        end
        for k = 1, #order do
            local f = common and common[order[k]]
            if f then
                styles[#styles + 1] = { id = tostring(variantId) .. "|" .. order[k], variantId = variantId, finish = f,
                    label = (variantId and (variantLabel .. " | ") or "") .. tostring(f.label), color = f.color }
            end
        end
    end
    addVariant(nil, getText("IGUI_KBW_RoofGablePlain"))
    for i = 1, #variantOrder do
        local variant = variantOrder[i]
        if variants[variant.id] then
            local text = variant.labelKey and getText(variant.labelKey) or variant.label or variant.id
            addVariant(variant.id, text)
        end
    end
    self.styleCache[gable.id] = styles
    return styles
end

function KBWRoofHelper:fillGableStyles()
    local item = self.gable:current()
    local gable = item and item.gable
    local previous = self.finish:current()
    local styles = self:gableStyles(gable)
    local items = {}
    for i = 1, #styles do
        local style = styles[i]
        local sample = gable and (gable.fills.W or gable.parts["W:peak:3"] or gable.parts["W:peak:6"])
        local texture
        if sample then
            local definition, stage = Resolver.resolveStage(sample.buildableId, style.variantId, nil, sample.stageId)
            local base = stage and RoofPlanner.faceSprite(stage, sample.face)
            local finished = style.finish and definition
                and WallFinishes.previewSprite(style.finish, false, definition, stage, base) or base
            texture = textureFor(finished)
        end
        items[i] = { style = style, label = style.label, color = style.color, texture = texture }
    end
    local selected = 1
    for i = 1, #items do
        if previous and previous.style and items[i].style.id == previous.style.id then selected = i end
    end
    self.finish:setItems(items, selected)
end

function KBWRoofHelper:selectedGable()
    local item = self.gable and self.gable:current()
    return item and item.gable or nil
end

function KBWRoofHelper:selectedStyle()
    if not self:selectedGable() then return nil end
    local item = self.finish and self.finish:current()
    return item and item.style or nil
end

local function value(carousel)
    local item = carousel and carousel:current()
    if item then return item.value end
    return nil
end

-- Input choices (which paint can, which wallpaper roll) for a finished piece.
function KBWRoofHelper:finishChoices(entry, style)
    local key = entry.buildableId .. "|" .. tostring(style.id)
    local cached = self.choiceCache and self.choiceCache[key]
    if cached ~= nil then return cached or nil end
    self.choiceCache = self.choiceCache or {}
    local _, stage = Resolver.resolveStage(entry.buildableId, style.variantId, nil, entry.stageId)
    local choices = {}
    local any = false
    local finish = style.finish
    local inputs = ((stage or {}).requirements or {}).inputs or {}
    for index = 1, #inputs do
        local input = inputs[index]
        local tags = input.tags or {}
        for t = 1, #tags do
            local tag = string.lower(tostring(tags[t]))
            local itemType = (finish.paintType and tag == "base:paint" and finish.paintType)
                or (finish.wallpaperType and tag == "base:wallpaper" and finish.wallpaperType) or nil
            if itemType then
                local parts = WallFinishes.paintComponents(itemType)
                local first = tostring(#parts > 0 and parts[1].item or itemType)
                choices[input.id or ("input-" .. index)] = string.find(first, ".", 1, true) and first or ("Base." .. first)
                any = true
            end
        end
    end
    self.choiceCache[key] = any and choices or false
    return any and choices or nil
end

function KBWRoofHelper:selectedRoofOptions()
    local ceiling = value(self.ceiling)
    local style = self:selectedStyle()
    local ceilingValue = nil
    if ceiling == "yes" then ceilingValue = true elseif ceiling == "no" then ceilingValue = false end
    local options = {
        overhang = value(self.overhang) or 0,
        riseLevels = value(self.rise) or nil,
        z = (self.room.z or 0) + (value(self.elevation) or 1),
        ceiling = ceilingValue,
        eaves = value(self.eaves) ~= false,
        gable = self:selectedGable(),
        accents = value(self.accents) ~= false and self.accentSet or nil,
    }
    if style and (style.variantId or style.finish) then
        local helper = self
        options.decorateGable = function(item, entry)
            if style.variantId then
                local definition = Registry:get(entry.buildableId)
                for v = 1, #((definition and definition.variants) or {}) do
                    if definition.variants[v].id == style.variantId then item.variantId = style.variantId; break end
                end
            end
            if style.finish then
                local f = style.finish
                item.finish = { label = f.label, actionType = f.actionType, plaster = f.plaster,
                    paintType = f.paintType, wallpaperType = f.wallpaperType, color = f.color }
                item.inputChoices = helper:finishChoices(entry, style)
            end
        end
    end
    return options
end

function KBWRoofHelper:optionsKey(profile, options)
    local style = self:selectedStyle()
    return table.concat({ profile and profile.id or "-", options.gable and options.gable.id or "-",
        style and style.id or "-", tostring(options.overhang), tostring(options.riseLevels), tostring(options.z),
        tostring(options.ceiling), tostring(options.eaves), tostring(options.accents and options.accents.id),
        tostring(self.regionUpdated) }, "|")
end

-- ---------------------------------------------------------------------------
-- Plan checks, one piece at a time
-- ---------------------------------------------------------------------------

function KBWRoofHelper:pieceChecker()
    local helper = self
    local blueprint = Blueprints.get(self.player, self.blueprintId)
    local state = { count = 0 }
    if not blueprint or not Blueprints.canContribute(self.player, blueprint) then
        return { each = function() return "no_permission" end }
    end
    if self.collisionBlueprint ~= blueprint or self.collisionUpdated ~= blueprint.updated
        or self.collisionPlacements ~= blueprint.placements then
        self.collisionIndex = Blueprints.intersectionIndex(blueprint)
        self.collisionBlueprint, self.collisionUpdated = blueprint, blueprint.updated
        self.collisionPlacements = blueprint.placements
    end
    local index = self.collisionIndex
    local room = Blueprints.maxPlacements() - #(blueprint.placements or {})
    return {
        start = function() state.count = 0 end,
        each = function(candidate)
            state.count = state.count + 1
            if state.count > room then return "placement_limit" end
            local key = candidate.buildableId .. ":" .. tostring(candidate.stageId) .. ":"
                .. tostring(candidate.variantId) .. ":" .. tostring(candidate.direction)
            local shape = helper.shapeCache[key]
            if shape == nil then
                local definition, stage = Blueprints.resolvePlacement(candidate)
                local ok = definition and Visibility.definitionEnabled(definition)
                    and Visibility.stagePasses(helper.player, definition, stage, false) or false
                local cells = ok and Matrix.getFaceCells(stage, tonumber(candidate.direction) or 1) or nil
                local single = not cells or #cells <= 1
                    and ((cells[1] or {}).dx or 0) == 0 and ((cells[1] or {}).dy or 0) == 0 and ((cells[1] or {}).dz or 0) == 0
                shape = { ok = ok, single = single }
                helper.shapeCache[key] = shape
            end
            if not shape.ok then return "locked" end
            if not Blueprints.withinRange(blueprint, candidate.x, candidate.y) then return "out_of_range" end
            -- Most roof squares are empty in the plan: only an occupied
            -- square (or a multi-square piece) needs the full overlap test.
            if not shape.single or index[candidate.x .. "," .. candidate.y .. "," .. candidate.z] then
                if #Blueprints.findIntersections(blueprint, candidate, index) > 0 then return "plan_overlap" end
            end
            return nil
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Layout search, cached per choice and spread across frames
-- ---------------------------------------------------------------------------

function KBWRoofHelper:onFamilyChanged()
    self:fillGables()
    self:onOptionsChanged()
end

function KBWRoofHelper:onGableChanged()
    self:fillGableStyles()
    self:onOptionsChanged()
end

function KBWRoofHelper:onOptionsChanged()
    -- Coalesce rapid clicks; never rebuild inside the input event. A cached
    -- result shows at once.
    self.rebuildAt = getTimestampMs() + 60
    Theme.setButtonEnabled(self.apply, false)
end

function KBWRoofHelper:getRegion(blueprint)
    if self.regionBlueprint ~= blueprint or self.regionUpdated ~= (blueprint and blueprint.updated) then
        self.region = RoofPlanner.findRegion(blueprint and blueprint.rooms or {}, self.room.id)
        self.regionBlueprint, self.regionUpdated = blueprint, blueprint and blueprint.updated
    end
    return self.region
end

function KBWRoofHelper:footprint(blueprint)
    local footprint = self:getRegion(blueprint)
    if not footprint and (not blueprint or not blueprint.rooms or #blueprint.rooms == 0) then footprint = self.room end
    return footprint
end

function KBWRoofHelper:remember(key, entry)
    if not self.cache[key] then
        self.cacheOrder[#self.cacheOrder + 1] = key
        if #self.cacheOrder > CACHE_LIMIT then
            local old = table.remove(self.cacheOrder, 1)
            if old ~= self.activeKey then self.cache[old] = nil end
        end
    end
    self.cache[key] = entry
end

-- Start (or resume) the search for one choice of family and options.
function KBWRoofHelper:searchFor(profile, options, footprint)
    local key = self:optionsKey(profile, options)
    local entry = self.cache[key]
    if entry then return entry, key end
    entry = { layouts = {} }
    if not footprint then
        entry.reason = "covered_by_room"
    elseif not profile then
        entry.reason = "no_profile"
    elseif not profile.stepsPerLevel and not profile.flat then
        entry.reason = "manual_only"
    else
        entry.ctx, entry.reason = RoofPlanner.prepare(profile, footprint, options, self:pieceChecker())
        entry.profile = profile
    end
    self:remember(key, entry)
    return entry, key
end

function KBWRoofHelper:rebuild()
    if not self.list then return end
    self.rebuildAt = nil
    local blueprint = Blueprints.get(self.player, self.blueprintId)
    self.checkedUpdated = blueprint and blueprint.updated
    local footprint = self:footprint(blueprint)
    local options = self:selectedRoofOptions()
    local roofFootprint = footprint and RoofPlanner.previewFootprint(footprint, options.overhang) or nil
    self.roofOutline = roofFootprint and (roofFootprint.cells
        and RoomShape.perimeterCells(roofFootprint.cells, roofFootprint.list)
        or RoomShape.perimeter(roofFootprint)) or nil
    self.roofOutlineZ = options.z
    local keep = self.layouts[self.selectedIndex or 0]
    self.selectedKind = keep and keep.kind or self.selectedKind
    self.active, self.activeKey = self:searchFor(self:selectedProfile(), options, footprint)
    self.hoverIndex = nil
    self.prefetch = nil
    self:syncLayouts()
end

-- Copy the active search's results into the list.
function KBWRoofHelper:syncLayouts()
    local entry = self.active
    if not entry then return end
    local layouts, reason = {}, entry.reason
    if entry.ctx then
        layouts, reason = RoofPlanner.results(entry.ctx)
        entry.layouts = layouts
        if entry.done then entry.reason = reason end
    else
        layouts = entry.layouts
    end
    local keep = self.layouts[self.selectedIndex or 0]
    local keepKey = keep and keep.rowKey or self.selectedRowKey
    self.layouts = layouts
    self.selectedIndex = nil
    for index = 1, #layouts do
        local layout = layouts[index]
        if not layout.rowKey then
            layout.rowKey = layout.kind .. "|" .. tostring(layout.face) .. "|" .. tostring(layout.alongX) .. "|"
                .. (layout.styles and table.concat(layout.styles, ",") or "") .. "|" .. tostring(layout.cap ~= nil)
        end
        if not layout.preview then layout.preview = { placements = layout.placements, updated = getTimestampMs() } end
        if keepKey and layout.rowKey == keepKey then self.selectedIndex = index end
    end
    -- Same roof type in another family keeps its place in the list.
    if not self.selectedIndex and self.selectedKind then
        for index = 1, #layouts do
            if layouts[index].kind == self.selectedKind and not layouts[index].reason then self.selectedIndex = index; break end
        end
    end
    if not self.selectedIndex and entry.done then
        for index = 1, #layouts do
            if not layouts[index].reason then self.selectedIndex = index; break end
        end
    end
    if self.selectedIndex then self.selectedRowKey = layouts[self.selectedIndex].rowKey end
    if #layouts == 0 then
        self.emptyText = (entry.done or not entry.ctx) and getText("IGUI_KBW_RoofError_" .. tostring(reason or "unsupported_shape"))
            or getText("IGUI_KBW_RoofComputing")
    end
    self.reason = #layouts == 0 and (entry.done or not entry.ctx) and reason or nil
    self:refreshRows()
    self:updateStatus()
    local selected = layouts[self.selectedIndex or 0]
    Theme.setButtonEnabled(self.apply, (entry.done or not entry.ctx) and selected ~= nil and selected.reason == nil)
end

-- Spend this frame's budget on the shown family, then on its neighbours.
function KBWRoofHelper:stepLayouts()
    local entry = self.active
    if entry and entry.ctx and not entry.done then
        local start = getTimestampMs()
        local count = #entry.ctx.layouts
        repeat
            entry.done = RoofPlanner.step(entry.ctx, SLICE)
        until entry.done or getTimestampMs() - start >= FRAME_BUDGET_MS
        if entry.done or #entry.ctx.layouts ~= count then self:syncLayouts() end
        return
    end
    -- Idle: prepare the families either side so the carousel answers at once.
    if not self.family then return end
    if not self.prefetch then
        self.prefetch = {}
        local items = self.family.items
        local n = #items
        if n > 1 then
            local options = self:selectedRoofOptions()
            local footprint = self:footprint(Blueprints.get(self.player, self.blueprintId))
            for _, delta in pairs({ 1, -1 }) do
                -- Wrap by hand: Kahlua's % keeps the sign of a negative
                -- operand, so (0 - 1) % n is -1 there, not n - 1.
                local i = self.family.selected + delta
                if i < 1 then i = n elseif i > n then i = 1 end
                local profile = items[i] and items[i].profile or nil
                if profile and profile.pitch == (self:selectedProfile() or {}).pitch then
                    self.prefetch[#self.prefetch + 1] = (self:searchFor(profile, options, footprint))
                end
            end
        end
    end
    local start = getTimestampMs()
    for i = 1, #self.prefetch do
        local job = self.prefetch[i]
        if job.ctx and not job.done then
            repeat
                job.done = RoofPlanner.step(job.ctx, SLICE)
            until job.done or getTimestampMs() - start >= PREFETCH_BUDGET_MS
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- List rows and status
-- ---------------------------------------------------------------------------

local DIRECTION_TEXT = { S = "S", E = "E", N = "N", W = "W" }

local function layoutName(layout)
    local name = getText("IGUI_KBW_RoofKind_" .. layout.kind)
    if layout.kind == "gable" and layout.alongX ~= nil then
        name = name .. " (" .. getText(layout.alongX and "IGUI_KBW_RoofRidgeEW" or "IGUI_KBW_RoofRidgeNS") .. ")"
    end
    return name
end

local function layoutDescription(layout)
    if layout.kind == "shed" and layout.face then
        return getText((layout.leans and "IGUI_KBW_RoofDesc_leanTo_" or "IGUI_KBW_RoofDesc_shed_")
            .. DIRECTION_TEXT[layout.face])
    end
    return getText("IGUI_KBW_RoofDesc_" .. layout.kind)
end

function KBWRoofHelper:rowFor(layout, index, profile)
    local recommended = index == 1 and not layout.reason
    -- Rows are rebuilt only when what they show changes.
    local stamp = tostring(layout.reason) .. "|" .. tostring(recommended)
    if layout.row and layout.rowStamp == stamp then return layout.row end
    local m = layout.metrics or {}
    local roofPieces = (m.roof or 0) + (m.ridges or 0)
    local stats = getText("IGUI_KBW_RoofStats", roofPieces, (m.gables or 0) + (m.fills or 0), m.levels or 1)
    local tags = {}
    if layout.reason then
        tags[#tags + 1] = { text = getText("IGUI_KBW_RoofError_" .. layout.reason), color = Theme.bad }
    elseif recommended then
        tags[#tags + 1] = { text = getText("IGUI_KBW_RoofRecommended"), color = Theme.good }
    end
    if layout.cap and layout.kind ~= "flat" then
        tags[#tags + 1] = { text = getText("IGUI_KBW_RoofTagCrown", layout.cap), color = Theme.textMuted }
    end
    if (m.ridgeGaps or 0) > 0 then
        tags[#tags + 1] = { text = getText("IGUI_KBW_RoofTagRidgeGap", m.ridgeGaps), color = Theme.warn }
    elseif (m.approx or 0) > 0 then
        tags[#tags + 1] = { text = getText("IGUI_KBW_RoofTagApprox", m.approx), color = Theme.warn }
    end
    if (m.missing or 0) > 0 then
        tags[#tags + 1] = { text = getText("IGUI_KBW_RoofTagMissing", m.missing), color = Theme.bad }
    end
    if not layout.model then
        layout.model = RoofModelView.build(layout, profile and profile.stepsPerLevel or 3)
    end
    layout.row = { name = layoutName(layout), description = layoutDescription(layout), stats = stats, tags = tags,
        model = layout.model, blocked = layout.reason ~= nil }
    layout.rowStamp = stamp
    return layout.row
end

function KBWRoofHelper:refreshRows()
    local profile = self.active and self.active.profile or self:selectedProfile()
    local rows = {}
    for index = 1, #self.layouts do rows[index] = self:rowFor(self.layouts[index], index, profile) end
    self.list:setRows(rows)
end

function KBWRoofHelper:selectLayout(index)
    if not self.layouts[index] then return end
    self.selectedIndex = index
    self.selectedRowKey = self.layouts[index].rowKey
    self.selectedKind = self.layouts[index].kind
    self.list:scrollTo(index)
    self:updateStatus()
    local entry = self.active
    Theme.setButtonEnabled(self.apply, entry and (entry.done or not entry.ctx) and self.layouts[index].reason == nil)
end

function KBWRoofHelper:onHoverLayout(index)
    self.hoverIndex = index
end

function KBWRoofHelper:updateStatus()
    if not self.list then return end
    local width = self.width - PAD * 2
    local lines = {}
    local blueprint = Blueprints.get(self.player, self.blueprintId)
    local region = self:getRegion(blueprint)
    if region then
        lines[#lines + 1] = { text = getText("IGUI_KBW_RoofRegionSummary", #region.list, region.w, region.h),
            color = Theme.textMuted }
    end
    local layout = self.layouts[self.selectedIndex or 0]
    local text, color
    if layout and layout.reason then
        text, color = getText("IGUI_KBW_RoofError_" .. layout.reason), Theme.bad
    elseif layout then
        text, color = getText("IGUI_KBW_RoofSummary", #layout.placements,
            (self.room.z or 0) + (value(self.elevation) or 1)), Theme.good
    elseif self.reason then
        text, color = getText("IGUI_KBW_RoofError_" .. self.reason), Theme.bad
    end
    if text then
        local wrapped = wrap(text, width)
        for i = 1, #wrapped do lines[#lines + 1] = { text = wrapped[i], color = color } end
    end
    -- Two lines are reserved; a long reason keeps its first line here and is
    -- shown in full on the layout's row and as a tooltip on Apply.
    while #lines > 2 do table.remove(lines) end
    self.summaryLines = lines
    if self.apply and self.apply.setTooltip then self.apply:setTooltip(text) end
end

function KBWRoofHelper:onApply()
    local layout = self.layouts[self.selectedIndex or 0]
    local entry = self.active
    if not layout or (entry and entry.ctx and not entry.done) then return end
    -- The plan may have changed since the list was built.
    local checker = self:pieceChecker()
    checker.start()
    local reason
    for i = 1, #layout.placements do
        reason = checker.each(layout.placements[i])
        if reason then break end
    end
    if reason then
        layout.reason = reason
        self:refreshRows(); self:updateStatus()
        if HaloTextHelper and HaloTextHelper.addBadText then
            HaloTextHelper.addBadText(self.player, getText("IGUI_KBW_RoofError_" .. reason))
        end
        return
    end
    local added, failure = Blueprints.addPlacements(self.player, self.blueprintId, layout.placements)
    if failure then HaloTextHelper.addBadText(self.player, Blueprints.planErrorText(failure)) end
    self.owner:refreshBlueprints(self.blueprintId)
    if #added > 0 then Blueprints.setActive(self.player, self.blueprintId) end
    self:close()
end

function KBWRoofHelper:update()
    ISCollapsableWindow.update(self)
    local blueprint = Blueprints.get(self.player, self.blueprintId)
    if not blueprint then self:close(); return end
    if blueprint.updated ~= self.checkedUpdated and self.checkedUpdated ~= nil then
        local room = Blueprints.getRoom(blueprint, self.room.id)
        if not room then self:close(); return end
        self.room = copyTable(room)
        -- The plan changed: earlier results may now overlap it.
        self.cache, self.cacheOrder = {}, {}
        self:rebuild()
    elseif self.rebuildAt and getTimestampMs() >= self.rebuildAt then
        self:rebuild()
    else
        self:stepLayouts()
    end
end

function KBWRoofHelper:prerender()
    ISCollapsableWindow.prerender(self)
    for index = 1, #(self.labels or {}) do
        local label = self.labels[index]
        self:drawText(label.text, label.x, label.y, Theme.accent.r, Theme.accent.g, Theme.accent.b, 1, UIFont.Small)
    end
    for index = 1, #(self.summaryLines or {}) do
        local line = self.summaryLines[index]
        self:drawText(line.text, PAD, self.summaryY + (index - 1) * self.summaryLineH,
            line.color.r, line.color.g, line.color.b, 1, UIFont.Small)
    end
end

function KBWRoofHelper:close()
    if self.renderGhosts then Events.OnPostRender.Remove(self.renderGhosts) end
    self.renderGhosts = nil
    self.layouts = {}
    self.cache, self.cacheOrder, self.active, self.prefetch = {}, {}, nil, nil
    self.roofOutline = nil
    self:setVisible(false); self:removeFromUIManager()
    if self.owner.roofWindow == self then self.owner.roofWindow = nil end
end

return KBWRoofHelper
