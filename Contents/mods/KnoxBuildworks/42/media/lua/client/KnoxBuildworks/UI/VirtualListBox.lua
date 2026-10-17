require("ISUI/ISScrollingListBox")

---Fixed-height, viewport-rendered list for large Knox Buildworks datasets.
---Vanilla ISScrollingListBox invokes doDrawItem for every row every frame;
---this implementation keeps its public API while touching visible rows only.
---@class KBWVirtualListBox: ISScrollingListBox
local VirtualListBox = ISScrollingListBox:derive("KBWVirtualListBox")

function VirtualListBox:rowAt(x, y)
    if y < 0 then return -1 end
    local row = math.floor(y / self.itemheight) + 1
    return row >= 1 and row <= #self.items and row or -1
end

function VirtualListBox:topOfItem(index)
    if index < 1 or index > #self.items then return -1 end
    return (index - 1) * self.itemheight
end

function VirtualListBox:ensureVisible(index)
    if not index or index < 1 or index > #self.items then return end
    local y = self:topOfItem(index)
    if not self.smoothScrollTargetY then self.smoothScrollY = self:getYScroll() end
    if y <= -self:getYScroll() then
        self.smoothScrollTargetY = -y
    elseif y + self.itemheight > -self:getYScroll() + self.height then
        self.smoothScrollTargetY = -(y + self.itemheight - self.height)
    end
end

-- Rows are split by a hairline instead of each being boxed, and the selected
-- row carries an accent bar on its left edge. Vanilla's per-row rectangle
-- turned the category panes into a stack of identical outlined buttons.
function VirtualListBox:doDrawItem(y, item, alt)
    local height = item.height or self.itemheight
    local width = self:getWidth()
    local textColor = item.textColor or self.textColor
    local selected = self.selected == item.index
    if selected then
        self:drawSelection(0, y, width, height - 1)
        local accent = self.accentColor
        if accent then self:drawRect(0, y, 3, height - 1, accent.a, accent.r, accent.g, accent.b) end
        textColor = item.selectedTextColor or self.selectedTextColor
    elseif self.mouseoverselected == item.index and self:isMouseOver() and not self:isMouseOverScrollBar() then
        self:drawMouseOverHighlight(0, y, width, height - 1)
    end
    local line = self.borderColor
    self:drawRect(8, y + height - 1, width - 16, 1, line.a * .45, line.r, line.g, line.b)
    local padY = self.itemPadY or (height - self.fontHgt) / 2
    self:drawText(item.text, selected and 14 or 12, y + padY, textColor.r, textColor.g, textColor.b, textColor.a,
        self.font)
    return y + height
end

function VirtualListBox:clear()
    self.items = {}
    self.selected = 0
    self.itemheightoverride = {}
    self.count = 0
    self.smoothScrollTargetY = nil
    self.smoothScrollY = nil
    self:setScrollHeight(0)
    self:setYScroll(0)
end

---Bulk replacement avoids one Java setScrollHeight call per inserted row.
---@param rows table[]
---@param textField string|nil
---@param itemField string|nil
function VirtualListBox:replaceItems(rows, textField, itemField)
    textField = textField or "name"
    itemField = itemField or "definition"
    local items = {}
    for rowIndex = 1, #rows do
        local row = rows[rowIndex]
        items[rowIndex] = {
            text = row[textField],
            item = row[itemField],
            itemindex = rowIndex,
            index = rowIndex,
            height = self.itemheight
        }
    end
    self.items = items
    self.count = #items
    self.smoothScrollTargetY = nil
    self.smoothScrollY = nil
    self:setYScroll(0)
    self:setScrollHeight(self.count * self.itemheight)
end

function VirtualListBox:prerender()
    local count = #self.items
    if self.selected > count then self.selected = count end
    self.listHeight = count * self.itemheight

    self:drawRect(
        0, -self:getYScroll(), self.width, self.height,
        self.backgroundColor.a, self.backgroundColor.r, self.backgroundColor.g, self.backgroundColor.b
    )
    local inset = self.drawBorder and 1 or 0
    if self.drawBorder then
        self:drawRectBorder(
            0, -self:getYScroll(), self.width, self.height,
            self.borderColor.a, self.borderColor.r, self.borderColor.g, self.borderColor.b
        )
    end
    local stencilWidth = self.width - inset * 2
    if self:isVScrollBarVisible() then stencilWidth = self.vscroll.x + 3 - inset end
    self:setStencilRect(inset, inset, stencilWidth, self.height - inset * 2)

    if count > 0 then
        local visibleTop = math.max(0, -self:getYScroll())
        local first = math.max(1, math.floor(visibleTop / self.itemheight) + 1)
        local last = math.min(count, math.ceil((visibleTop + self.height) / self.itemheight) + 1)
        for rowIndex = first, last do
            local item = self.items[rowIndex]
            item.index = rowIndex
            item.height = self.itemheight
            self:doDrawItem((rowIndex - 1) * self.itemheight, item, rowIndex % 2 == 0)
        end
    end

    self:clearStencilRect()
    local mouseY = self:getMouseY()
    self:updateSmoothScrolling()
    if mouseY ~= self:getMouseY() and self:isMouseOver() then
        self:onMouseMove(0, self:getMouseY() - mouseY)
    end
    self:updateTooltip()
    if self.useStencilForChildren then self:setStencilRect(0, 0, self.width, self.height) end
end

return VirtualListBox
