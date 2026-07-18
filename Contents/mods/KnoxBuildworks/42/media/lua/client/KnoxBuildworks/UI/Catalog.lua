---Catalog provides the Knox Buildworks custom user-interface layer.
require "ISUI/ISCollapsableWindow"
require "ISUI/ISResizeWidget"
require "ISUI/ISButton"
require "ISUI/ISTextEntryBox"
require "ISUI/ISComboBox"
require "ISUI/ISTickBox"
require "ISUI/ISToolTip"
require "KnoxBuildworks/UI/BuildCardGrid"
require "KnoxBuildworks/UI/RequirementPanel"
require "KnoxBuildworks/UI/AccessPanel"
require "KnoxBuildworks/UI/IngredientDrawer"

local KBW = require("KnoxBuildworks/Core")
local Registry = require("KnoxBuildworks/Definitions/Registry")
local Groups = require("KnoxBuildworks/Definitions/Groups")
local Requirements = require("KnoxBuildworks/Validation/Requirements")
local FinishActions = require("KnoxBuildworks/Validation/FinishActions")
local Integrity = require("KnoxBuildworks/Network/Integrity")
local Planner = require("KnoxBuildworks/Planning/Planner")
local PlanningMode = require("KnoxBuildworks/UI/PlanningMode")
local PinnedRecipes = require("KnoxBuildworks/UI/PinnedRecipes")
local TableUtil = require("KnoxBuildworks/Util/Table")
local Theme = require("KnoxBuildworks/UI/Theme")
local Matrix = require("KnoxBuildworks/Geometry/Matrix")
local IconResolver = require("KnoxBuildworks/UI/IconResolver")
local EntityCompat = require("KnoxBuildworks/Entity/EntityCompat")
local StageConfig = require("KnoxBuildworks/Definitions/StageConfig")
local CatalogVisibility = require("KnoxBuildworks/UI/CatalogVisibility")
local WallFinishes = require("KnoxBuildworks/Validation/WallFinishes")
local I18n = require("KnoxBuildworks/I18n")

---@class KBWCatalog: ISCollapsableWindow
KBWCatalog = ISCollapsableWindow:derive("KBWCatalog")
KBWCatalog.instance = nil
KBWCatalog.dragReturnState = nil

local STAR_UNSET = getTexture("media/ui/inventoryPanes/FavouriteNo.png")
local STAR_SET = getTexture("media/ui/inventoryPanes/FavouriteYes.png")
local PIN_TEXTURE = getTexture("media/ui/inventoryPanes/Button_Pin.png")
local VIEW_LIST_TEXTURE = getTexture("media/ui/craftingMenus/Icon_List.png")
local VIEW_GRID_TEXTURE = getTexture("media/ui/craftingMenus/Icon_Grid.png")
---@class KBW.META_TEXTURESModule
---@type KBW.META_TEXTURESModule
local META_TEXTURES = {
    time = getTexture("media/ui/craftingMenus/BuildProperty_Clock_16.png"),
    light = getTexture("media/ui/craftingMenus/BuildProperty_Light_16.png"),
    book = getTexture("media/ui/craftingMenus/BuildProperty_Book_16.png"),
    walk = getTexture("media/ui/craftingMenus/BuildProperty_Walking_16.png"),
    surface = getTexture("media/ui/craftingMenus/BuildProperty_Surface_16.png")
}
local DETAILED_MIN_WIDTH = 920
local DETAILED_MIN_HEIGHT = 600
local COMPACT_MIN_WIDTH = 720
local COMPACT_MIN_HEIGHT = 300
local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)

local function displayName(definition)
    return I18n.definitionName(definition)
end

local function definitionDescription(definition)
    return I18n.definitionDescription(definition)
end

local function uiData(player)
    local root = player:getModData()
    root.KBW_UI = root.KBW_UI or { favorites = {}, recent = {}, compact = false }
    root.KBW_UI.favorites = root.KBW_UI.favorites or {}
    root.KBW_UI.recent = root.KBW_UI.recent or {}
    return root.KBW_UI
end

local function configureButton(button, selected)
    button:initialise()
    Theme.applyButton(button, selected)
    button.textColor = Theme.text
    return button
end

local function setOptionalTooltip(control, text)
    if control and control.setTooltip then control:setTooltip(text) end
    if control and control.setMouseOverText then control:setMouseOverText(text) end
end

local function applyViewButton(button, viewMode)
    if not button then return end
    button:setTitle("")
    local wantsGrid = viewMode == "list"
    local texture = wantsGrid and VIEW_GRID_TEXTURE or VIEW_LIST_TEXTURE
    if texture then
        button:setImage(texture)
        button:forceImageSize(18, 18)
    end
    setOptionalTooltip(button, wantsGrid and getText("Tooltip_KBW_GridView") or getText("Tooltip_KBW_ListView"))
    Theme.applyButton(button, false)
end

local function configureStarButton(button, tooltip)
    button:initialise()
    button:setImage(STAR_UNSET)
    button:forceImageSize(18, 18)
    button.borderColor.a = 0
    button.backgroundColor.a = 0
    button.backgroundColorMouseOver.a = 0.18
    button.displayBackground = true
    button:setTooltip(tooltip or getText("IGUI_KBW_Favorites"))
    return button
end

local function applyStarButton(button, active)
    if not button then return end
    button:setImage(active and STAR_SET or STAR_UNSET)
    if active then
        button.textureColor = { r = Theme.accent.r, g = Theme.accent.g, b = Theme.accent.b, a = 1 }
    else
        button.textureColor = { r = 1, g = 1, b = 1, a = .72 }
    end
    button.borderColor.a = 0
    button.backgroundColor.a = 0
    button.backgroundColorMouseOver.a = 0.18
    button.textColor = Theme.text
    button.textColorDisable = Theme.textMuted
end

local function configurePinRecipeButton(button)
    button:initialise()
    button:setImage(PIN_TEXTURE)
    button:forceImageSize(18, 18)
    button.borderColor.a = 0
    button.backgroundColor.a = 0
    button.backgroundColorMouseOver.a = 0.18
    button.displayBackground = true
    button:setTooltip(getText("IGUI_KBW_PinRecipe"))
    return button
end

local function applyPinRecipeButton(button, active, enabled)
    if not button then return end
    Theme.setButtonEnabled(button, enabled == true)
    button.textureColor = active and { r = Theme.accent.r, g = Theme.accent.g, b = Theme.accent.b, a = 1 }
        or { r = 1, g = 1, b = 1, a = enabled and .72 or .32 }
    button.backgroundColor = active and Theme.selectedSoft or { r = 0, g = 0, b = 0, a = 0 }
    button.backgroundColorMouseOver.a = enabled and .18 or 0
    button.borderColor = active and Theme.accent or Theme.borderSoft
    button.borderColor.a = active and .55 or 0
    button.textColor = Theme.text
    button.textColorDisable = Theme.textMuted
    button:setTooltip(active and getText("IGUI_KBW_UnpinRecipe") or getText("IGUI_KBW_PinRecipe"))
end

local function shortenedText(font, text, width)
    text = tostring(text or "")
    text = string.gsub(text, "[\r\n]+", " ")
    if getTextManager():MeasureStringX(font, text) <= width then return text end
    while #text > 3 and getTextManager():MeasureStringX(font, text .. "...") > width do
        text = string.sub(text, 1, #text - 1)
    end
    return text .. "..."
end

local function cleanInlineText(text)
    text = tostring(text or "")
    return string.gsub(text, "[\r\n]+", " ")
end

local function measureFont(font, text)
    return getTextManager():MeasureStringX(font, text)
end

local function wrapLongWordForFont(font, lines, word, width)
    local chunk = ""
    for charIndex = 1, #word do
        local char = string.sub(word, charIndex, charIndex)
        local candidate = chunk .. char
        if chunk ~= "" and measureFont(font, candidate) > width then
            lines[#lines + 1] = chunk
            chunk = char
        else
            chunk = candidate
        end
    end
    if chunk ~= "" then lines[#lines + 1] = chunk end
end

local function wrapTextForFont(font, text, width)
    text = cleanInlineText(text)
    local lines = {}
    if text == "" then return lines end
    if width < 24 then
        lines[#lines + 1] = text
        return lines
    end
    local current = ""
    for word in string.gmatch(text, "%S+") do
        local candidate = current == "" and word or current .. " " .. word
        if measureFont(font, candidate) <= width then
            current = candidate
        else
            if current ~= "" then
                lines[#lines + 1] = current
                current = ""
            end
            if measureFont(font, word) <= width then
                current = word
            else
                wrapLongWordForFont(font, lines, word, width)
            end
        end
    end
    if current ~= "" then lines[#lines + 1] = current end
    return lines
end

local function drawLinesForFont(panel, font, lines, x, y, color, alpha)
    local lineHeight = getTextManager():getFontHeight(font) + 2
    for lineIndex = 1, #lines do
        panel:drawText(lines[lineIndex], x, y, color.r, color.g, color.b, alpha or 1, font)
        y = y + lineHeight
    end
    return y
end

local function stageRecipe(definition, stage)
    return StageConfig.recipe(definition, stage)
end

local function recipeHasTag(recipe, tag)
    local tags = recipe and recipe.tags or {}
    for tagIndex = 1, #tags do
        if tags[tagIndex] == tag then return true end
    end
    return false
end

local function recipeSeconds(recipe)
    local time = tonumber(recipe and recipe.time)
    if not time or time <= 0 then return nil end
    local seconds = math.floor((time / 10) * 10 + 0.5) / 10
    if seconds == math.floor(seconds) then seconds = math.floor(seconds) end
    return seconds
end

local function recipeMetadataEntries(definition, stage)
    local recipe = stageRecipe(definition, stage)
    local entries = {}
    local seconds = recipeSeconds(recipe)
    if seconds then
        entries[#entries + 1] = {
            texture = META_TEXTURES.time,
            text = getText("IGUI_CraftingWindow_CraftTime") .. " "
                .. tostring(seconds) .. " "
                .. getText("IGUI_CraftingWindow_Seconds")
        }
    end
    if recipe.canWalk == true then
        entries[#entries + 1] = { texture = META_TEXTURES.walk, text = getText("IGUI_CraftingWindow_CanWalk") }
    end
    if not recipeHasTag(recipe, "CanBeDoneInDark") then
        entries[#entries + 1] = { texture = META_TEXTURES.light, text = getText("IGUI_CraftingWindow_RequiresLight") }
    end
    if recipe.needToBeLearn == true then
        entries[#entries + 1] = { texture = META_TEXTURES.book, text = getText("IGUI_CraftingWindow_RequiresLearning") }
    end
    if recipeHasTag(recipe, "AnySurfaceCraft") then
        entries[#entries + 1] = {
            texture = META_TEXTURES.surface,
            text = getText("IGUI_CraftingWindow_RequiresSurface")
        }
    end
    return entries
end

local function metadataChipHeight(entries, width)
    if not entries or #entries == 0 then return 0 end
    local lineHeight = 24
    local used = 0
    local lines = 1
    for entryIndex = 1, #entries do
        local text = tostring(entries[entryIndex].text or "")
        local chipWidth = math.min(width, getTextManager():MeasureStringX(UIFont.Small, text) + 34)
        if used > 0 and used + chipWidth > width then
            lines = lines + 1
            used = 0
        end
        used = used + chipWidth + 6
    end
    return lines * lineHeight
end

local function drawMetadataChips(panel, entries, x, y, width)
    panel.metaHitRows = {}
    if not entries or #entries == 0 then return y end
    local lineHeight = 24
    local chipX = x
    local chipY = y
    for entryIndex = 1, #entries do
        local entry = entries[entryIndex]
        local text = tostring(entry.text or "")
        local chipWidth = math.min(width, getTextManager():MeasureStringX(UIFont.Small, text) + 34)
        if chipX > x and chipX + chipWidth > x + width then
            chipX = x
            chipY = chipY + lineHeight
        end
        panel:drawRect(
            chipX, chipY, chipWidth, 20, Theme.surfaceRaised.a, Theme.surfaceRaised.r, Theme.surfaceRaised.g,
            Theme.surfaceRaised.b
        )
        panel:drawRectBorder(
            chipX, chipY, chipWidth, 20, Theme.borderSoft.a, Theme.borderSoft.r, Theme.borderSoft.g, Theme.borderSoft.b
        )
        if entry.texture then panel:drawTextureScaledAspect(entry.texture, chipX + 3, chipY + 2, 16, 16, 1, 1, 1, 1) end
        panel:drawText(
            text, chipX + 23, chipY + 3, Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 1, UIFont.Small
        )
        panel.metaHitRows[#panel.metaHitRows + 1] = { x = chipX, y = chipY, w = chipWidth, h = 20, text = text }
        chipX = chipX + chipWidth + 6
    end
    return chipY + lineHeight
end

local function stageDisplayText(stage, index, count)
    if not stage then return "" end
    local label = stage.label or stage.displayName or stage.id or tostring(index)
    if count and count > 1 then
        return tostring(label) .. "  (" .. tostring(index) .. "/" .. tostring(count) .. ")"
    end
    return tostring(label)
end

local function shouldShowStageLabel(stage, count)
    if count and count > 1 then return true end
    if not stage then return false end
    local id = tostring(stage.id or "")
    local label = tostring(stage.label or stage.displayName or "")
    if label ~= "" and label ~= id then return true end
    return id ~= "" and id ~= "built" and id ~= "default"
end

local function hasOptions(values)
    -- Java-backed ISUI setters (notably setVisible) must receive a real
    -- boolean. Returning nil here is fine for Lua if-tests, but PZ's Java
    -- bridge throws while unboxing nil as a boolean.
    return values ~= nil and #values > 0
end

local function clamp(value, minValue, maxValue)
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

local function clampedWindowRect(playerNum, x, y, width, height)
    local left = getPlayerScreenLeft(playerNum) + 4
    local top = getPlayerScreenTop(playerNum) + 4
    local right = getPlayerScreenLeft(playerNum) + getPlayerScreenWidth(playerNum) - 4
    local bottom = getPlayerScreenTop(playerNum) + getPlayerScreenHeight(playerNum) - 4
    width = math.min(width, right - left)
    height = math.min(height, math.max(240, bottom - top))
    return clamp(x, left, math.max(left, right - width)), clamp(y, top, math.max(top, bottom - height)), width, height
end

local function liveResizeSize(playerNum, x, y, width, height, minWidth, minHeight)
    local right = getPlayerScreenLeft(playerNum) + getPlayerScreenWidth(playerNum) - 4
    local bottom = getPlayerScreenTop(playerNum) + getPlayerScreenHeight(playerNum) - 4
    local maxWidth = math.max(260, right - x)
    local maxHeight = math.max(220, bottom - y)
    width = clamp(width, math.min(minWidth, maxWidth), maxWidth)
    height = clamp(height, math.min(minHeight, maxHeight), maxHeight)
    return width, height
end

local function contentTop(window)
    return window:titleBarHeight()
end

function KBWCatalog:resizeWidgetHeight()
    local baseHeight = ISCollapsableWindow.resizeWidgetHeight and ISCollapsableWindow.resizeWidgetHeight(self) or 14
    return math.max(20, baseHeight)
end

local function itemType(fullType)
    if type(fullType) ~= "string" then return nil end
    local dot = string.find(fullType, ".", 1, true)
    if dot then return string.sub(fullType, dot + 1) end
    return fullType
end

local function rowHasTag(row, tag)
    local tags = row.possibleTags or {}
    for tagIndex = 1, #tags do
        local value = tags[tagIndex]
        if value == tag then return true end
    end
    return false
end

local function firstAvailableFromRow(row)
    local availableItems = row.availableItems or {}
    for itemIndex = 1, #availableItems do
        local entry = availableItems[itemIndex]
        if (entry.available or 0) > 0 then return entry.fullType end
    end
    return row.possibleItems and row.possibleItems[1] or nil
end

local function findRecipeItem(player, definition, stage, tag)
    local status = Requirements.evaluate(player, definition, stage)
    local rows = status.rows or {}
    for rowIndex = 1, #rows do
        local row = rows[rowIndex]
        if row.kind == "input" and rowHasTag(row, tag) then return firstAvailableFromRow(row) end
    end
    return nil
end

local FinishOptions = require("KnoxBuildworks/UI/FinishOptions")

local function translated(key, fallback)
    local text = key and getText(key) or nil
    if text and text ~= key then return text end
    return fallback or tostring(key or "?")
end

local paintColorFor = FinishOptions.paintColorFor

local finishEntriesFor = FinishOptions.entriesFor

local function hasFinishItem(player, finish, definition, stage)
    if player:isBuildCheat() then return true end
    if definition and stage and (definition.placement or {}).kind == "wallCovering" then
        return FinishActions.validate(player, definition, stage, finish, true) == true
    end
    if not finish or finish.none then return true end
    if WallFinishes.isWallFinish(finish) then
        return WallFinishes.validateItems(player, finish) == true
    end
    local inventory = player:getInventory()
    if finish.paintType then return inventory:getFirstTypeRecurse(finish.paintType) ~= nil end
    if finish.wallpaperType then return inventory:getFirstTypeRecurse(finish.wallpaperType) ~= nil end
    return true
end

local function predicateNotBroken(item)
    if not item then return false end
    if item.isBroken and item:isBroken() then return false end
    if item.isDestroyed and item:isDestroyed() then return false end
    return true
end

local function predicateEnoughDrain(item)
    if not item then return false end
    if item.isDestroyed and item:isDestroyed() then return false end
    if item.getCurrentUsesFloat then return item:getCurrentUsesFloat() >= 0.1 end
    if item.getCurrentUses then return item:getCurrentUses() > 0 end
    return true
end

local function buildCheatActive(player)
    if player and player.isBuildCheat and player:isBuildCheat() then return true end
    return ISBuildMenu and ISBuildMenu.cheat == true
end

local function patchPlasterCursor(cursor)
    function cursor:hasItems()
        if buildCheatActive(self.character) then return true end
        local inventory = self.character:getInventory()
        return inventory:getFirstTagEvalRecurse(ItemTag.PLASTER_TROWEL, predicateNotBroken) ~= nil
            and inventory:getFirstTagEvalRecurse(ItemTag.PLASTER_BUCKET, predicateEnoughDrain) ~= nil
    end

    function cursor:create(x, y, z, north, sprite)
        local playerObj = self.character
        local inventory = playerObj:getInventory()
        local object = self:getObjectList()[self.objectIndex]
        if not object then return end
        local trowel = nil
        local bucket = nil
        if not buildCheatActive(playerObj) then
            trowel = inventory:getFirstTagEvalRecurse(ItemTag.PLASTER_TROWEL, predicateNotBroken)
            bucket = inventory:getFirstTagEvalRecurse(ItemTag.PLASTER_BUCKET, predicateEnoughDrain)
            if not trowel or not bucket then return end
            ISWorldObjectContextMenu.transferIfNeeded(playerObj, trowel)
            ISWorldObjectContextMenu.transferIfNeeded(playerObj, bucket)
        end
        local northSuffix = object:getNorth() and "North" or ""
        local wallType = ISPaintMenu.getWallType(object)
        local spriteName = Painting and Painting[wallType] and Painting[wallType]["plasterTile" .. northSuffix] or nil
        if not spriteName then return end
        local KBWFinishAction = require("KnoxBuildworks/TimedActions/KBWFinishAction")
        ISTimedActionQueue.add(KBWFinishAction:new(playerObj, "plaster", object, spriteName, bucket, trowel))
    end
end

local function beginWallCoveringCursor(player, definition, stage, finish)
    local compat = EntityCompat.metadata(stage)
    local wall = compat.wallCoveringConfig or {}
    local action = wall.type or ((definition and definition.placement or {}).wallCoveringType)
    if not action then return false end
    if action == "wallpaper" then
        if not ISPaperCursor then require "BuildingObjects/ISPaperCursor" end
        local wallpaperType = (finish and finish.wallpaperType) or itemType(
                findRecipeItem(player, definition, stage, "base:wallpaper")
            ) or wall.wallpaperType
        if not wallpaperType then return false end
        local spriteTable = WallPaper and WallPaper["wall"]
        local sprite = spriteTable and spriteTable[wallpaperType]
        if not sprite then return false end
        getCell():setDrag(ISPaperCursor:new(player, wallpaperType, sprite), player:getPlayerNum())
        return true
    end
    if not ISPaintCursor then require "BuildingObjects/ISPaintCursor" end
    local args = { actionType = action }
    if action == "paintThump" or action == "paintSign" then
        local paintType = (finish and finish.paintType)
            or itemType(findRecipeItem(player, definition, stage, "base:paint"))
        if not paintType then return false end
        args.paintType = paintType
        local color = (finish and finish.color) or paintColorFor(paintType)
        if color then
            args.r = color[1] or color.r
            args.g = color[2] or color.g
            args.b = color[3] or color.b
        end
    end
    if action == "paintSign" then args.sign = (finish and finish.sign) or wall.sign or wall.signIndex end
    local cursor = ISPaintCursor:new(player, action, args)
    if action == "plaster" then patchPlasterCursor(cursor) end
    getCell():setDrag(cursor, player:getPlayerNum())
    return true
end

---@param player IsoPlayer
---@return KBWCatalog
function KBWCatalog:new(player)
    local data = uiData(player)
    local compact = data.compact == true
    local playerNum = player:getPlayerNum()
    local screenHeight = getPlayerScreenHeight(playerNum)
    local defaultHeight = compact and 320 or math.min(760, math.max(640, math.floor(screenHeight * .68)))
    local maxHeight = math.max(280, screenHeight - 36)
    local height = math.min(maxHeight, data.height or defaultHeight)
    height = math.max(compact and COMPACT_MIN_HEIGHT or DETAILED_MIN_HEIGHT, height)
    local screenWidth = getPlayerScreenWidth(playerNum) - 8
    local screenLeft = getPlayerScreenLeft(playerNum) + 4
    local screenTop = getPlayerScreenTop(playerNum) + 4
    local width = math.min(screenWidth, data.width or screenWidth)
    width = math.max(compact and COMPACT_MIN_WIDTH or DETAILED_MIN_WIDTH, width)
    local x = data.x or screenLeft
    local y = data.y or math.max(screenTop, getPlayerScreenTop(playerNum) + screenHeight - height - 4)
    x, y, width, height = clampedWindowRect(playerNum, x, y, width, height)
    local o = ISCollapsableWindow:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.player = player
    o.compact = compact
    o.scope = "All"
    o.category = "All"
    o.categoryPage = 1
    o.categoryOffset = 1
    o.viewMode = data.viewMode == "list" and "list" or "grid"
    o.finishValues = {}
    o.drawerPinnedOpen = data.drawerPinnedOpen == true
    o.inputChoices = data.inputChoices or {}
    data.inputChoices = o.inputChoices
    o.inputChoiceItems = data.inputChoiceItems or {}
    data.inputChoiceItems = o.inputChoiceItems
    o.minimumWidth = compact and COMPACT_MIN_WIDTH or DETAILED_MIN_WIDTH
    o.minimumHeight = compact and COMPACT_MIN_HEIGHT or DETAILED_MIN_HEIGHT
    o.resizable = true
    o.pin = true
    o.title = getText("IGUI_KBW_Title")
    o.selected = nil
    o.categoryButtons = {}
    o.backgroundColor = Theme.backdrop
    o.borderColor = Theme.border
    return o
end

---@param x number
---@param y number
function KBWCatalog.resizeWidgetMouseDown(widget, x, y)
    if not widget:getIsVisible() then return false end
    local owner = widget.kbwOwner
    if owner then
        owner.resizeStartMouseX = getMouseX()
        owner.resizeStartMouseY = getMouseY()
        owner.resizeStartWidth = owner.width
        owner.resizeStartHeight = owner.height
        owner.isResizingFromWidget = true
    end
    widget.resizing = true
    widget:setCapture(true)
    return true
end

---@param dx number
---@param dy number
function KBWCatalog.resizeWidgetMouseMove(widget, dx, dy)
    widget.mouseOver = true
    if widget.resizing and widget.kbwOwner then widget.kbwOwner:resizeFromWidgetMouse(widget) end
    return true
end

---@param dx number
---@param dy number
function KBWCatalog.resizeWidgetMouseMoveOutside(widget, dx, dy)
    widget.mouseOver = false
    if widget.resizing and widget.kbwOwner then widget.kbwOwner:resizeFromWidgetMouse(widget) end
    return true
end

---@param x number
---@param y number
function KBWCatalog.resizeWidgetMouseUp(widget, x, y)
    if not widget:getIsVisible() then return false end
    widget.resizing = false
    widget:setCapture(false)
    if widget.kbwOwner then widget.kbwOwner:finishResize() end
    return true
end

---@param x number
---@param y number
function KBWCatalog.resizeWidgetMouseUpOutside(widget, x, y)
    if not widget:getIsVisible() then return false end
    widget.resizing = false
    widget:setCapture(false)
    if widget.kbwOwner then widget.kbwOwner:finishResize() end
    return true
end

local function installResizeHook(owner, widget)
    if not widget then return end
    widget.kbwOwner = owner
    -- ISResizeWidget calculates drag deltas from the widget's local mouse
    -- coordinates. Knox relayouts the resize handles while resizing, so the
    -- native local delta feeds back into itself and makes the window explode in
    -- size. Use absolute mouse coordinates instead; the widget may move, but the
    -- drag baseline stays stable.
    widget.resizeFunction = false
    widget.onMouseDown = KBWCatalog.resizeWidgetMouseDown
    widget.onMouseMove = KBWCatalog.resizeWidgetMouseMove
    widget.onMouseMoveOutside = KBWCatalog.resizeWidgetMouseMoveOutside
    widget.onMouseUp = KBWCatalog.resizeWidgetMouseUp
    widget.onMouseUpOutside = KBWCatalog.resizeWidgetMouseUpOutside
end

function KBWCatalog:ensureResizeWidgets()
    self.resizable = true
    if self.resizeWidget then
        installResizeHook(self, self.resizeWidget)
        self.resizeWidget:setVisible(true)
    end
    if self.resizeWidget2 then
        installResizeHook(self, self.resizeWidget2)
        self.resizeWidget2:setVisible(true)
    end
end

function KBWCatalog:bringChromeToTop()
    local controls = {
        self.search,
        self.searchMode,
        self.sortCombo,
        self.viewButton,
        self.scopeAll,
        self.scopeFav,
        self
            .scopeRecent,
        self.sizeButton,
        self.plansButton,
        self.planButton,
        self.buildButton,
        self.categoryPrev,
        self.categoryNext,
        self.subcategoryFilter,
        self
            .materialFilter,
        self.skillFilter,
        self.showAllTickBox,
        self.stage,
        self.stagePrevButton,
        self.stageNextButton,
        self.variant,
        self.material,
        self
            .finish,
        self.favoriteButton,
        self.recipePinButton
    }
    for controlIndex = 1, #controls do
        local control = controls[controlIndex]
        if control and control:isVisible() then control:bringToTop() end
    end
    local buttons = self.categoryButtons or {}
    for buttonIndex = 1, #buttons do
        local button = buttons[buttonIndex]
        if button and button:isVisible() then button:bringToTop() end
    end
    if self.ingredientDrawer and self.ingredientDrawer:isVisible() then self.ingredientDrawer:bringToTop() end
    if self.resizeWidget2 then self.resizeWidget2:bringToTop() end
    if self.resizeWidget then self.resizeWidget:bringToTop() end
end

function KBWCatalog:createChildren()
    ISCollapsableWindow.createChildren(self)
    installResizeHook(self, self.resizeWidget)
    installResizeHook(self, self.resizeWidget2)
    local top = contentTop(self)
    self.search = ISTextEntryBox:new("", 150, top + 10, 190, 28)
    self.search:initialise()
    self.search:instantiate()
    if self.search.setClearButton then self.search:setClearButton(true) end
    if self.search.javaObject and self.search.javaObject.setCentreVertically then
        self.search.javaObject
            :setCentreVertically(true)
    end
    if self.search.setPlaceholderText then self.search:setPlaceholderText(getText("IGUI_KBW_SearchPlaceholder")) end
    self.search.onTextChange = function (box)
        if box and box.target then box.target:refreshGrid() end
    end
    self.search.target = self
    self
        :addChild(self.search)
    setOptionalTooltip(self.search, getText("Tooltip_KBW_Search"))
    self.searchMode = ISComboBox:new(0, top + 10, 124, 28, self, self.onFilterChanged)
    self.searchMode:initialise()
    self
        :addChild(self.searchMode)
    self.searchMode:addOption(getText("IGUI_KBW_SearchNames"))
    self.searchMode:addOption(getText("IGUI_KBW_SearchRequirements"))
    self.searchMode:addOption(getText("IGUI_KBW_SearchEverything"))
    self.searchModeValues = { "name", "requirements", "everything" }
    self.searchMode.selected = uiData(self.player).searchModeIndex or 1
    setOptionalTooltip(self.searchMode, getText("Tooltip_KBW_SearchMode"))
    self.sortCombo = ISComboBox:new(0, top + 10, 134, 28, self, self.onFilterChanged)
    self.sortCombo:initialise()
    self
        :addChild(self.sortCombo)
    self.sortCombo:addOption(getText("IGUI_KBW_SortNone"))
    self.sortCombo:addOption(getText("IGUI_KBW_SortAZ"))
    self.sortValues = { "none", "az" }
    self.sortCombo.selected = uiData(self.player).sortIndex or 1
    setOptionalTooltip(self.sortCombo, getText("Tooltip_KBW_Sort"))
    self.viewButton = configureButton(ISButton:new(0, top + 10, 34, 28, "", self, self.onToggleView), false)
    self
        :addChild(self.viewButton)
    applyViewButton(self.viewButton, self.viewMode)

    self.scopeAll = configureButton(
        ISButton:new(346, top + 10, 52, 28, getText("IGUI_KBW_All"), self, self.onScope), true
    )
    self.scopeAll.internal = "All"
    self:addChild(self.scopeAll)
    self.scopeFav = configureStarButton(
        ISButton:new(404, top + 10, 36, 28, "", self, self.onScope), getText("IGUI_KBW_Favorites")
    )
    self.scopeFav.internal = "Favorites"
    self:addChild(self.scopeFav)
    self.scopeRecent = configureButton(
        ISButton:new(446, top + 10, 62, 28, getText("IGUI_KBW_RecentShort"), self, self.onScope), false
    )
    self.scopeRecent.internal = "Recent"
    self:addChild(self.scopeRecent)

    self.sizeButton = configureButton(
        ISButton:new(self.width - 78, top + 8, 32, 32, self.compact and "^" or "v", self, self.onToggleSize), false
    )
    self
        :addChild(self.sizeButton)
    self.plansButton = configureButton(
        ISButton:new(self.width - 160, top + 8, 76, 32, getText("IGUI_KBW_Plans"), self, self.onPlans), false
    )
    self:addChild(self.plansButton)
    self.planButton = configureButton(
        ISButton:new(self.width - 260, top + 8, 94, 32, getText("IGUI_KBW_Plan"), self, self.onPlan), false
    )
    self:addChild(self.planButton)
    self.buildButton = configureButton(
        ISButton:new(self.width - 376, top + 8, 110, 32, getText("IGUI_KBW_Build"), self, self.onBuild), false
    )
    self:addChild(self.buildButton)

    self.categoryPrev = configureButton(ISButton:new(12, top + 48, 30, 28, "<", self, self.onCategoryPage), false)
    self.categoryPrev.internal = -1
    self
        :addChild(self.categoryPrev)
    self.categoryNext = configureButton(ISButton:new(46, top + 48, 30, 28, ">", self, self.onCategoryPage), false)
    self.categoryNext.internal = 1
    self
        :addChild(self.categoryNext)

    self.subcategoryFilter = ISComboBox:new(12, top + 80, 174, 27, self, self.onFilterChanged)
    self.subcategoryFilter
        :initialise()
    self:addChild(self.subcategoryFilter)
    self.materialFilter = ISComboBox:new(192, top + 80, 174, 27, self, self.onFilterChanged)
    self.materialFilter
        :initialise()
    self
        :addChild(self.materialFilter)
    self.skillFilter = ISComboBox:new(372, top + 80, 174, 27, self, self.onFilterChanged)
    self.skillFilter:initialise()
    self
        :addChild(self.skillFilter)

    local showAllLabel = getText("IGUI_CraftingUI_ShowAllVersion")
    local showAllWidth = 28 + getTextManager():MeasureStringX(UIFont.Small, showAllLabel)
    self.showAllTickBox = ISTickBox:new(
        12, top + 112, showAllWidth, 24, "", self, self.onShowAllVersionsChanged
    )
    self.showAllTickBox:initialise()
    self.showAllTickBox:addOption(showAllLabel)
    self.showAllTickBox.selected[1] = CatalogVisibility.shouldShowAll(self.player)
    self:addChild(self.showAllTickBox)
    setOptionalTooltip(self.showAllTickBox, getText("Tooltip_KBW_ShowAllVersions"))

    self.grid = KBWBuildCardGrid:new(
        10, top + 144, 600, self.height - top - 154, self.player, self, self.onCardSelected, self.onCardActivated
    )
    self.grid:initialise()
    self.grid:setViewMode(self.viewMode)
    self:addChild(self.grid)

    self.stage = ISComboBox:new(0, 0, 220, 27, self, self.onStageChanged)
    self.stage:initialise()
    self:addChild(self
            .stage)
    self.stagePrevButton = configureButton(ISButton:new(0, 0, 30, 30, "<", self, self.onStageCarousel), false)
    self.stagePrevButton.internal = -1
    self
        :addChild(self.stagePrevButton)
    self.stageNextButton = configureButton(ISButton:new(0, 0, 30, 30, ">", self, self.onStageCarousel), false)
    self.stageNextButton.internal = 1
    self
        :addChild(self.stageNextButton)
    setOptionalTooltip(self.stagePrevButton, getText("Tooltip_KBW_PreviousLevel"))
    setOptionalTooltip(self.stageNextButton, getText("Tooltip_KBW_NextLevel"))
    self.variant = ISComboBox:new(0, 0, 220, 27, self, self.onVariantChanged)
    self.variant:initialise()
    self:addChild(self.variant)
    self.material = ISComboBox:new(0, 0, 220, 27, self, self.onMaterialChanged)
    self.material:initialise()
    self
        :addChild(self.material)
    self.finish = ISComboBox:new(0, 0, 220, 27, self, self.onFinishChanged)
    self.finish:initialise()
    self
        :addChild(self.finish)
    self.favoriteButton = configureStarButton(
        ISButton:new(0, 0, 24, 24, "", self, self.onFavorite), getText("IGUI_KBW_Favorites")
    )
    self:addChild(self.favoriteButton)
    self.recipePinButton = configurePinRecipeButton(ISButton:new(0, 0, 24, 24, "", self, self.onPinRecipe))
    self
        :addChild(self.recipePinButton)
    self.requirements = KBWRequirementPanel:new(0, 0, 320, 120, self.player, self, self.onRequirementSelected)
    self
        .requirements:initialise()
    self
        :addChild(self.requirements)
    self.accessPanel = KBWAccessPanel:new(0, 0, 320, 84, self.player, self, self.onRequirementSelected)
    self
        .accessPanel:initialise()
    self
        :addChild(self.accessPanel)
    self.ingredientDrawer = KBWIngredientDrawer:new(
        0, top + 48, 310, self.height - top - 58, self, self.onIngredientDrawerClosed, self.onIngredientChoice
    )
    self
        .ingredientDrawer:initialise()
    self.ingredientDrawer:setVisible(false)
    self:addChild(self.ingredientDrawer)
    self:bringChromeToTop()

    self:refreshCategories()
    self:refreshFilterOptions()
    self:updateScopeButtons()
    self:layout()
    self:refreshGrid()
end

function KBWCatalog:layout(liveResize)
    local resizeHeight = self:resizeWidgetHeight()
    local top = contentTop(self)
    local contentBottom = self.height - resizeHeight
    local drawerVisible = (not self.compact) and self.ingredientDrawer and self.ingredientDrawer:isVisible()
    local drawerWidth = 0
    if drawerVisible then drawerWidth = math.min(360, math.max(310, math.floor(self.width * .26))) end
    local availableWidth = self.width - 20 - drawerWidth
    if drawerVisible then availableWidth = availableWidth - 8 end
    local inspectorWidth = 0
    if not self.compact then
        inspectorWidth = math.min(400, math.max(330, math.floor(availableWidth * .36)))
        local minGridWidth = 340
        if availableWidth - inspectorWidth < minGridWidth then
            inspectorWidth = math.max(300, availableWidth - minGridWidth)
        end
    end
    if inspectorWidth < 0 then inspectorWidth = 0 end
    local drawerX = self.width - drawerWidth - 8
    self.drawerWidth = drawerWidth
    self.drawerX = drawerX
    self.inspectorWidth = inspectorWidth
    self.inspectorX = self.compact and self.width
        or (drawerVisible and (drawerX - inspectorWidth - 8) or (self.width - inspectorWidth))
    if self.inspectorX < 10 then self.inspectorX = 10 end
    local headerX = 150
    local rightReserve = self.compact and 74 or 178
    local headerRight = math.max(headerX + 360, self.width - rightReserve)
    local modeWidth = self.compact and 104 or 116
    local sortWidth = self.compact and 106 or 122
    local viewWidth = self.compact and 36 or 40
    local scopeWidth = self.compact and (52 + 36 + 12) or (52 + 36 + 62 + 18)
    local headerGap = 6
    local searchWidth = math.max(
        120, math.min(190, headerRight - headerX - modeWidth - sortWidth - viewWidth - scopeWidth - headerGap * 6)
    )
    if self.search then
        self.search:setX(headerX)
        self.search:setY(top + 10)
        self.search:setWidth(searchWidth)
    end
    local nextX = headerX + searchWidth + headerGap
    if self.searchMode then
        self.searchMode:setX(nextX)
        self.searchMode:setY(top + 10)
        self.searchMode:setWidth(modeWidth)
    end
    nextX = nextX + modeWidth + headerGap
    if self.sortCombo then
        self.sortCombo:setX(nextX)
        self.sortCombo:setY(top + 10)
        self.sortCombo:setWidth(sortWidth)
    end
    nextX = nextX + sortWidth + headerGap
    if self.viewButton then
        self.viewButton:setX(nextX)
        self.viewButton:setY(top + 10)
        self.viewButton:setWidth(viewWidth)
    end
    nextX = nextX + viewWidth + headerGap
    if self.scopeAll then
        self.scopeAll:setX(nextX)
        self.scopeAll:setY(top + 10)
    end
    nextX = nextX + 58
    if self.scopeFav then
        self.scopeFav:setX(nextX)
        self.scopeFav:setY(top + 10)
    end
    nextX = nextX + 42
    if self.scopeRecent then
        self.scopeRecent:setX(nextX)
        self.scopeRecent:setY(top + 10)
        self.scopeRecent:setVisible(not self.compact)
    end
    if self.categoryPrev then self.categoryPrev:setY(top + 48) end
    if self.categoryNext then self.categoryNext:setY(top + 48) end
    if self.subcategoryFilter then self.subcategoryFilter:setY(top + 80) end
    if self.materialFilter then self.materialFilter:setY(top + 80) end
    if self.skillFilter then self.skillFilter:setY(top + 80) end
    if self.showAllTickBox then
        self.showAllTickBox:setX(12)
        self.showAllTickBox:setY(top + 112)
    end
    self:positionHeaderActions()
    local gridWidth = self.compact and self.width - 20 or self.inspectorX - 18
    if gridWidth < 260 then gridWidth = 260 end
    local filterGap = 6
    local filterWidth = math.floor((gridWidth - 24 - (filterGap * 2)) / 3)
    if filterWidth < 72 then filterWidth = 72 end
    local filterY = top + 80
    self.subcategoryFilter:setX(12)
    self.subcategoryFilter:setY(filterY)
    self.subcategoryFilter:setWidth(filterWidth)
    self.materialFilter:setX(12 + filterWidth + filterGap)
    self.materialFilter:setY(filterY)
    self.materialFilter
        :setWidth(filterWidth)
    self.skillFilter:setX(12 + (filterWidth + filterGap) * 2)
    self.skillFilter:setY(filterY)
    self.skillFilter:setWidth(filterWidth)
    local gridY = top + 144
    local compactActionHeight = self.compact and 44 or 0
    local gridHeight = math.max(90, contentBottom - gridY - compactActionHeight)
    self.grid:setY(gridY)
    self.grid:setWidth(gridWidth)
    self.grid:setHeight(gridHeight)
    self.grid:setScrollHeight(self.grid
            :contentHeight())
    if self.grid.onResize then self.grid:onResize() end
    self:layoutCategoryButtons(gridWidth)
    local visible = not self.compact
    local controls = {
        self.stage,
        self.stagePrevButton,
        self.stageNextButton,
        self.variant,
        self.material,
        self.finish,
        self.favoriteButton,
        self.recipePinButton,
        self
            .requirements,
        self.accessPanel
    }
    for i = 1, #controls do
        controls[i]:setVisible(visible)
    end
    self.buildButton:setVisible(true)
    self.planButton:setVisible(true)
    self.plansButton:setVisible(true)
    if self.compact then
        local gap = 6
        local plansW = 84
        local planW = 112
        local buildW = 104
        local totalW = buildW + planW + plansW + gap * 2
        local actionX = math.max(12, self.width - totalW - 12)
        local actionY = contentBottom - 38
        self.buildButton:setX(actionX)
        self.buildButton:setY(actionY)
        self.buildButton:setWidth(buildW)
        self
            .buildButton:setHeight(32)
        self.planButton:setX(actionX + buildW + gap)
        self.planButton:setY(actionY)
        self.planButton:setWidth(planW)
        self
            .planButton:setHeight(32)
        self.plansButton:setX(actionX + buildW + planW + gap * 2)
        self.plansButton:setY(actionY)
        self.plansButton
            :setWidth(plansW)
        self.plansButton:setHeight(32)
    end
    if visible then
        local definition, stage = self:effectiveDefinition(), self:selectedStage()
        local infoX = self.inspectorX + 16
        local textWidth = math.max(120, inspectorWidth - 32)
        local titleWidth = math.max(120, textWidth - 64)
        self.infoNameY = top + 56
        self.infoNameLines = definition and wrapTextForFont(UIFont.Medium, displayName(definition), titleWidth) or {}
        local nameBottom = self.infoNameY + (#self.infoNameLines * (FONT_HGT_MEDIUM + 2))
        local tooltip = definitionDescription(definition)
        self.infoTooltipY = nameBottom + 4
        self.infoTooltipLines = wrapTextForFont(UIFont.Small, tooltip, textWidth)
        local tooltipBottom = self.infoTooltipY + (#self.infoTooltipLines * (FONT_HGT_SMALL + 2))
        if #self.infoTooltipLines == 0 then tooltipBottom = nameBottom end
        self.infoMetaEntries = recipeMetadataEntries(definition, stage)
        self.infoMetaY = tooltipBottom + 8
        self.infoMetaHeight = metadataChipHeight(self.infoMetaEntries, textWidth)
        self.previewWidth = 112
        self.previewHeight = 116
        self.previewX = infoX + math.floor((textWidth - self.previewWidth) / 2)
        self.previewY = math.max(top + 98, self.infoMetaY + self.infoMetaHeight + 10)
        local stageCount = self:stageCountForSelection()
        self.stage:setVisible(false)
        self.stagePrevButton:setVisible(stageCount > 1)
        self.stageNextButton:setVisible(stageCount > 1)
        self.stagePrevButton:setX(self.previewX - 38)
        self.stagePrevButton:setY(self.previewY + 38)
        self.stageNextButton:setX(self.previewX + self.previewWidth + 8)
        self.stageNextButton:setY(self.previewY + 38)
        Theme.applyActionButton(self.stagePrevButton, stageCount > 1, false)
        Theme.applyActionButton(self.stageNextButton, stageCount > 1, false)

        local comboX = infoX
        local comboWidth = textWidth
        self.stageLabelY = self.previewY + self.previewHeight + 8
        self.showStageLabel = shouldShowStageLabel(stage, stageCount)
        local stageLines = self.showStageLabel
            and wrapTextForFont(
                UIFont.Small, stageDisplayText(stage, self.stage and self.stage.selected or 1, stageCount), textWidth
            )
            or {}
        local stageBlockHeight = self.showStageLabel
            and math.max(28, (#stageLines * (FONT_HGT_SMALL + 2)) + (stageCount > 1 and 18 or 8))
            or (stageCount > 1 and 18 or 8)
        local selectorY = self.stageLabelY + stageBlockHeight
        local baseDefinition = Groups.resolveDefinition(self.selected, self:rawSelectedStage()) or self.selected
        self.showVariantControl = hasOptions(baseDefinition and baseDefinition.variants)
        self.showMaterialControl = hasOptions(baseDefinition and baseDefinition.materialOptions)
        self.variant:setVisible(self.showVariantControl)
        self.material:setVisible(self.showMaterialControl)
        if self.showVariantControl then
            self.variantLabelY = selectorY
            self.variant:setX(comboX)
            self.variant:setY(selectorY + 16)
            self.variant:setWidth(comboWidth)
            selectorY = selectorY + 50
        else
            self.variantLabelY = nil
        end
        if self.showMaterialControl then
            self.materialLabelY = selectorY
            self.material:setX(comboX)
            self.material:setY(selectorY + 16)
            self.material:setWidth(comboWidth)
            selectorY = selectorY + 50
        else
            self.materialLabelY = nil
        end
        if not self.finishValues or #self.finishValues == 0 then self.finish:setVisible(false) end
        if self.finish:isVisible() then
            self.finishLabelY = selectorY
            self.finish:setX(comboX)
            self.finish:setY(selectorY + 16)
            self.finish:setWidth(comboWidth)
            selectorY = selectorY + 50
        else
            self.finishLabelY = nil
        end
        local titleButtonY = self.infoNameY
        self.favoriteButton:setX(infoX + textWidth - 26)
        self.favoriteButton:setY(titleButtonY)
        self.recipePinButton:setX(infoX + textWidth - 54)
        self.recipePinButton:setY(titleButtonY)
        local panelX = self.inspectorX + 14
        local panelWidth = math.max(250, inspectorWidth - 26)
        local selectorBottom = selectorY
        local panelsTop = math.max(self.previewY + 102, selectorBottom) + 32
        self.actionY = contentBottom - 44
        local panelBottom = self.actionY - 12
        local panelsHeight = math.max(0, panelBottom - panelsTop)
        local listBudget = math.max(0, panelsHeight - 58)
        local accessHeight = math.floor(listBudget * .32)
        if accessHeight < 34 then accessHeight = math.min(34, listBudget) end
        if accessHeight > 132 then accessHeight = 132 end
        local requirementsHeight = listBudget - accessHeight
        if requirementsHeight < 40 then requirementsHeight = math.max(0, requirementsHeight) end
        self.statusY = panelsTop - 24
        self.skillsHeaderY = panelsTop
        local accessY = panelsTop + 22
        accessHeight = math.max(0, math.min(accessHeight, panelBottom - accessY))
        self.accessPanel:setX(panelX)
        self.accessPanel:setY(accessY)
        self.accessPanel:setWidth(panelWidth)
        self
            .accessPanel:setHeight(accessHeight)
        self.accessPanel:setVisible(accessHeight > 12)
        self.requirementsHeaderY = accessY + accessHeight + 10
        local requirementsY = self.requirementsHeaderY + 22
        requirementsHeight = math.max(0, math.min(requirementsHeight, panelBottom - requirementsY))
        self.requirements:setX(panelX)
        self.requirements:setY(self.requirementsHeaderY + 22)
        self.requirements
            :setWidth(panelWidth)
        self.requirements:setHeight(requirementsHeight)
        self.requirements:setVisible(requirementsHeight > 12)
        local actionGap = 6
        local actionWidth = math.floor((panelWidth - actionGap) / 2)
        self.buildButton:setX(panelX)
        self.buildButton:setY(self.actionY)
        self.buildButton:setWidth(actionWidth)
        self
            .buildButton:setHeight(32)
        self.planButton:setX(panelX + actionWidth + actionGap)
        self.planButton:setY(self.actionY)
        self.planButton
            :setWidth(actionWidth)
        self.planButton:setHeight(32)
        if self.accessPanel.onResize then self.accessPanel:onResize() end
        if self.requirements.onResize then self.requirements:onResize() end
    else
        self.infoNameLines = nil
        self.infoTooltipLines = nil
        self.infoMetaEntries = nil
        self.previewX = nil
        self.previewY = nil
    end
    -- Requirement details use a separate right-side column, mirroring vanilla's
    -- ingredient browser without letting the requirement rows draw underneath it.
    self.ingredientDrawer:setX(drawerVisible and drawerX or self.width + 20)
    self.ingredientDrawer:setY(top + 48)
    self
        .ingredientDrawer:setWidth(math
                .max(1, drawerWidth))
    self.ingredientDrawer:setHeight(math.max(120, contentBottom - top - 58))
    if self.ingredientDrawer.onResize then self.ingredientDrawer:onResize() end
    if self.compact then self.ingredientDrawer:setVisible(false) end
    if self.resizeWidget then
        self.resizeWidget:setX(self.width - resizeHeight)
        self.resizeWidget:setY(self.height - resizeHeight)
        self.resizeWidget:setWidth(resizeHeight)
        self.resizeWidget:setHeight(resizeHeight)
    end
    if self.resizeWidget2 then
        self.resizeWidget2:setX(0)
        self.resizeWidget2:setY(self.height - resizeHeight)
        self.resizeWidget2:setWidth(self.width - resizeHeight)
        self.resizeWidget2:setHeight(resizeHeight)
    end
    self:ensureResizeWidgets()
    if not liveResize then
        self:bringChromeToTop()
    end
end

function KBWCatalog:definitionList()
    local hash = Registry.hash or ""
    if self.definitionListCache and self.definitionListHash == hash then return self.definitionListCache end
    self.definitionListHash = hash
    self.definitionListCache = Groups.groupedList(Registry:list())
    return self.definitionListCache
end

function KBWCatalog:refreshCategories()
    local seen = {}
    local categories = {}
    local definitions = self:definitionList()
    for definitionIndex = 1, #definitions do
        local definition = definitions[definitionIndex]
        if not seen[definition.category] then
            seen[definition.category] = true
            categories[#categories + 1] = definition.category
        end
    end
    table.sort(categories, function (a, b) return I18n.category(a) < I18n.category(b) end)
    self.categories = categories
end

function KBWCatalog:refreshFilterOptions()
    local subcategories, materials, skills = {}, {}, {}
    local definitions = self:definitionList()
    for definitionIndex = 1, #definitions do
        local definition = definitions[definitionIndex]
        if self.category == "All" or definition.category == self.category then
            subcategories[definition.subcategory or "General"] = true
            local materialTags = definition.materialTags or {}
            for tagIndex = 1, #materialTags do
                materials[materialTags[tagIndex]] = true
            end
            local stages = definition.stages or {}
            for stageIndex = 1, #stages do
                local stage = stages[stageIndex]
                for skill in pairs((stage.requirements or {}).skills or {}) do
                    skills[skill] = true
                end
            end
        end
    end
    local function fill(combo, allLabel, set, display)
        combo:clear()
        combo:addOption(allLabel)
        local values = { false }
        local names = {}
        for name in pairs(set) do
            names[#names + 1] = name
        end
        table.sort(names, function (a, b) return display(a) < display(b) end)
        for nameIndex = 1, #names do
            local name = names[nameIndex]
            combo:addOption(display(name))
            values[#values + 1] = name
        end
        combo.selected = 1
        return values
    end
    self.subcategoryValues = fill(
        self.subcategoryFilter, getText("IGUI_KBW_AllSubcategories"), subcategories, I18n.subcategory
    )
    self.materialFilterValues = fill(self.materialFilter, getText("IGUI_KBW_AllMaterials"), materials, I18n.materialTag)
    self.skillFilterValues = fill(self.skillFilter, getText("IGUI_KBW_AllSkills"), skills, I18n.skill)
end

function KBWCatalog:onFilterChanged()
    local data = uiData(self.player)
    data.searchModeIndex = self.searchMode and self.searchMode.selected or data.searchModeIndex
    data.sortIndex = self.sortCombo and self.sortCombo.selected or data.sortIndex
    self:refreshGrid()
end

function KBWCatalog:onShowAllVersionsChanged(clickedOption, enabled)
    CatalogVisibility.setShowAll(self.player, enabled == true)
    self.visibleStages = nil
    self:refreshGrid()
end

function KBWCatalog:onToggleView()
    self.viewMode = self.viewMode == "list" and "grid" or "list"
    uiData(self.player).viewMode = self.viewMode
    if self.grid then self.grid:setViewMode(self.viewMode) end
    applyViewButton(self.viewButton, self.viewMode)
    self:layout()
    self:refreshGrid()
end

function KBWCatalog:layoutCategoryButtons(gridWidth)
    for buttonIndex = 1, #self.categoryButtons do
        self.categoryButtons[buttonIndex]:setVisible(false)
    end
    local top = contentTop(self)
    local slots = math.max(1, math.floor((gridWidth - 92) / 106))
    self.categorySlots = slots
    local values = { { id = "All", label = getText("IGUI_KBW_AllCategories") } }
    for categoryIndex = 1, #self.categories do
        local category = self.categories[categoryIndex]
        values[#values + 1] = { id = category, label = I18n.category(category) }
    end
    local maxOffset = math.max(1, #values - slots + 1)
    self.categoryOffset = clamp(self.categoryOffset or 1, 1, maxOffset)
    self.categoryPage = self.categoryOffset
    local first = self.categoryOffset
    for slot = 1, slots do
        local value = values[first + slot - 1]
        if not value then break end
        local button = self.categoryButtons[slot]
        if not button then
            button = configureButton(
                ISButton:new(82 + (slot - 1) * 106, top + 48, 100, 28, "", self, self.onCategory), false
            )
            self.categoryButtons[slot] = button
            self:addChild(button)
        end
        button:setY(top + 48)
        button.internal = value.id
        button:setTitle(shortenedText(UIFont.Small, value.label, 88))
        button
            :setVisible(true)
        Theme.applyButton(button, self.category == value.id)
    end
    Theme.applyActionButton(self.categoryPrev, self.categoryOffset > 1, false)
    Theme.applyActionButton(self.categoryNext, self.categoryOffset < maxOffset, false)
end

local requirementsMatchQuery

function KBWCatalog:filteredDefinitions()
    local result, data, query = {}, uiData(self.player), string.lower(self.search:getInternalText() or "")
    local subcategory = self.subcategoryValues and self.subcategoryValues[self.subcategoryFilter.selected]
    local materialTag = self.materialFilterValues and self.materialFilterValues[self.materialFilter.selected]
    local skillName = self.skillFilterValues and self.skillFilterValues[self.skillFilter.selected]
    local searchMode = self.searchModeValues and self.searchModeValues[self.searchMode.selected] or "name"
    local sortMode = self.sortValues and self.sortValues[self.sortCombo.selected] or "none"
    local definitions = self:definitionList()
    for definitionIndex = 1, #definitions do
        local definition = definitions[definitionIndex]
        local include = self.category == "All" or definition.category == self.category
        if include then
            include = CatalogVisibility.definitionPasses(
                self.player, definition, CatalogVisibility.shouldShowAll(self.player)
            )
        end
        if include and subcategory then include = (definition.subcategory or "General") == subcategory end
        if include and materialTag then include = TableUtil.contains(definition.materialTags or {}, materialTag) end
        if include and skillName then
            include = false
            local stages = definition.stages or {}
            for stageIndex = 1, #stages do
                local stage = stages[stageIndex]
                if ((stage.requirements or {}).skills or {})[skillName] then include = true end
            end
        end
        if self.scope == "Favorites" then include = include and data.favorites[definition.id] == true end
        if self.scope == "Recent" then
            include = false
            for recentIndex = 1, #data.recent do
                local id = data.recent[recentIndex]
                if id == definition.id and (self.category == "All" or definition.category == self.category) then
                    include = true
                end
            end
        end
        if include and query ~= "" then
            local nameMatch = string.find(string.lower(displayName(definition) .. " "
                        .. definition.id .. " "
                        .. table.concat(definition.tags or {}, " ")), query, 1, true) ~= nil
            local requirementMatch = requirementsMatchQuery(definition, query)
            if searchMode == "requirements" then
                include = requirementMatch
            elseif searchMode == "everything" then
                include = nameMatch or requirementMatch
            else
                include = nameMatch
            end
        end
        if include then result[#result + 1] = definition end
    end
    table.sort(result, function (a, b)
        local pinnedA = PinnedRecipes.hasPinnedDefinition(self.player, a)
        local pinnedB = PinnedRecipes.hasPinnedDefinition(self.player, b)
        if pinnedA ~= pinnedB then return pinnedA end
        if sortMode == "az" then
            local nameA = string.lower(displayName(a))
            local nameB = string.lower(displayName(b))
            if nameA ~= nameB then return nameA < nameB end
        end
        return tostring(a.id) < tostring(b.id)
    end)
    return result
end

function KBWCatalog:refreshGrid()
    local selectedId = self.selected and self.selected.id
    self.grid:setItems(self:filteredDefinitions(), selectedId)
    self.selected = self.grid.items[self.grid.selectedIndex]
    self:refreshSelectionControls()
    self:layout()
end

function KBWCatalog:refreshVariantMaterialControls()
    self.variant:clear()
    self.material:clear()
    local baseDefinition = Groups.resolveDefinition(self.selected, self:rawSelectedStage()) or self.selected
    self.variant:addOption(getText("IGUI_KBW_DefaultVariant"))
    local variants = baseDefinition and baseDefinition.variants or {}
    for entryIndex = 1, #variants do
        local entry = variants[entryIndex]
        self.variant:addOption(I18n.optionName(entry, entry.id))
    end
    self.variant.selected = 1
    self.material:addOption(getText("IGUI_KBW_BaseMaterial"))
    local materialOptions = baseDefinition and baseDefinition.materialOptions or {}
    for entryIndex = 1, #materialOptions do
        local entry = materialOptions[entryIndex]
        self.material:addOption(I18n.optionName(entry, entry.id))
    end
    self.material.selected = 1
    self.variant:setEnabled(#variants > 0)
    self.material:setEnabled(#materialOptions > 0)
end

function KBWCatalog:updateScopeButtons()
    Theme.applyButton(self.scopeAll, self.scope == "All")
    Theme.applyButton(self.scopeRecent, self.scope == "Recent")
    Theme.applyButton(self.scopeFav, self.scope == "Favorites")
    applyStarButton(self.scopeFav, self.scope == "Favorites")
    if self.scope == "Favorites" then
        self.scopeFav.backgroundColor = Theme.selectedSoft
        self.scopeFav.borderColor = Theme.accent
    end
end

function KBWCatalog:onScope(button)
    self.scope = button.internal
    self:updateScopeButtons()
    self:refreshGrid()
end

function KBWCatalog:onCategory(button)
    self.category = button.internal
    self:layoutCategoryButtons(self.grid.width)
    self
        :refreshFilterOptions()
    self
        :refreshGrid()
end

function KBWCatalog:onCategoryPage(button)
    self.categoryOffset = (self.categoryOffset or 1) + button.internal
    self:layoutCategoryButtons(self.grid.width)
end

local function itemDisplayNameForSearch(fullType)
    if type(fullType) == "string" and string.find(fullType, ".", 1, true) then
        return getItemNameFromFullType(fullType) .. " " .. fullType
    end
    return tostring(fullType or "")
end

local function textMatchesQuery(text, query)
    return string.find(string.lower(tostring(text or "")), query, 1, true) ~= nil
end

local function inputMatchesQuery(input, query)
    if textMatchesQuery(input.id, query) or textMatchesQuery(input.label, query) or textMatchesQuery(input.role, query) then
        return true
    end
    local items = input.items or {}
    for itemIndex = 1, #items do
        if textMatchesQuery(itemDisplayNameForSearch(items[itemIndex]), query) then return true end
    end
    local tags = input.tags or {}
    for tagIndex = 1, #tags do
        if textMatchesQuery(tags[tagIndex], query) then return true end
    end
    local flags = input.flags or {}
    for flagIndex = 1, #flags do
        if textMatchesQuery(flags[flagIndex], query) then return true end
    end
    return false
end

---@param definition KBW.BuildableDefinition
function requirementsMatchQuery(definition, query)
    local definitionTools = definition.tools or {}
    for toolIndex = 1, #definitionTools do
        if inputMatchesQuery(definitionTools[toolIndex], query) then return true end
    end
    local stages = definition.stages or {}
    for stageIndex = 1, #stages do
        local req = stages[stageIndex].requirements or {}
        local inputs = req.inputs or {}
        for inputIndex = 1, #inputs do
            if inputMatchesQuery(inputs[inputIndex], query) then return true end
        end
        local materials = req.materials or {}
        for materialIndex = 1, #materials do
            if inputMatchesQuery(materials[materialIndex], query) then return true end
        end
        local tools = req.tools or {}
        for toolIndex = 1, #tools do
            if inputMatchesQuery(tools[toolIndex], query) then return true end
        end
        local skills = req.skills or {}
        for skillName in pairs(skills) do
            if textMatchesQuery(skillName, query)
                or textMatchesQuery(getText("IGUI_perks_" .. tostring(skillName)), query) then
                return true
            end
        end
        local recipes = req.recipes or {}
        for recipeIndex = 1, #recipes do
            local recipe = recipes[recipeIndex]
            if textMatchesQuery(recipe.id or recipe.name or recipe, query) then return true end
        end
    end
    return false
end

function KBWCatalog:onMouseWheel(delta)
    local top = contentTop(self)
    local y = self:getMouseY()
    if y >= top + 44 and y <= top + 80 then
        self.categoryOffset = (self.categoryOffset or 1) + (delta < 0 and 1 or -1)
        self:layoutCategoryButtons(self.grid.width)
        return true
    end
    return false
end

---@param x number
---@param y number
function KBWCatalog:onStageDotMouseDown(x, y)
    local hits = self.stageDotHits or {}
    for hitIndex = 1, #hits do
        local hit = hits[hitIndex]
        if x >= hit.x and x <= hit.x + hit.w and y >= hit.y and y <= hit.y + hit.h then
            if self.stage and self.stage.selected ~= hit.index then
                self.stage.selected = hit.index
                self:onStageChanged()
            end
            return true
        end
    end
    return false
end

---@param x number
---@param y number
function KBWCatalog:onMouseDown(x, y)
    if self:onStageDotMouseDown(x, y) then return true end
    return ISCollapsableWindow.onMouseDown(self, x, y)
end

---@param definition KBW.BuildableDefinition
function KBWCatalog:onCardSelected(definition)
    self.selected = definition
    self:refreshSelectionControls()
    self:layout()
end

---@param definition KBW.BuildableDefinition
function KBWCatalog:onCardActivated(definition)
    self.selected = definition
    self:refreshSelectionControls()
    self:onBuild()
end

function KBWCatalog:rawSelectedStage()
    local stages = self.visibleStages or (self.selected and self.selected.stages) or {}
    return stages[self.stage and self.stage.selected or 1]
end

function KBWCatalog:stageCountForSelection()
    local stages = self.visibleStages or (self.selected and self.selected.stages) or {}
    return #stages
end

function KBWCatalog:effectiveDefinition()
    if not self.selected then return nil end
    local rawStage = self:rawSelectedStage()
    local baseDefinition = Groups.resolveDefinition(self.selected, rawStage)
    local variantIndex = (self.variant.selected or 1) - 1
    local variant = variantIndex > 0 and baseDefinition.variants and baseDefinition.variants[variantIndex]
    local effective = variant and TableUtil.merge(baseDefinition, variant) or baseDefinition
    local materialIndex = (self.material.selected or 1) - 1
    local material = materialIndex > 0 and baseDefinition.materialOptions
        and baseDefinition.materialOptions[materialIndex]
    effective = material and TableUtil.merge(effective, material) or effective
    effective.id = baseDefinition.id
    return effective
end

function KBWCatalog:refreshSelectionControls()
    self.stage:clear()
    self.variant:clear()
    self.material:clear()
    self.finish:clear()
    self.finishValues = {}
    local shouldKeepDrawer = self.drawerPinnedOpen == true
        or (self.ingredientDrawer and self.ingredientDrawer:isVisible())
    if not self.selected then
        self.visibleStages = nil
        self.finish:setVisible(false)
        self.requirements:setSelection(nil, nil)
        self.accessPanel:setSelection(nil, nil)
        if not shouldKeepDrawer then self.ingredientDrawer:setRow(nil) end
        self:updateActions()
        if shouldKeepDrawer then self:updateIngredientDrawerForSelection(true) end
        return
    end
    self.visibleStages = CatalogVisibility.filteredStages(
        self.player, self.selected, CatalogVisibility.shouldShowAll(self.player)
    )
    self.stage.selected = 1
    self:refreshVariantMaterialControls()
    self:refreshStageAndFinish()
    self:updateFavorite()
    self:updateActions()
    if shouldKeepDrawer then self:updateIngredientDrawerForSelection(true) end
end

function KBWCatalog:refreshStageAndFinish()
    self.stage:clear()
    self.visibleStages = CatalogVisibility.filteredStages(
        self.player, self.selected, CatalogVisibility.shouldShowAll(self.player)
    )
    local definition = self:effectiveDefinition()
    if not self.selected or not definition then return end
    local stages = self.visibleStages or {}
    local previous = self.stage.selected or 1
    for entryIndex = 1, #stages do
        local entry = stages[entryIndex]
        local label = I18n.optionName(
            entry, getText("IGUI_KBW_Level") .. " " .. tostring(entry.level) .. " - " .. tostring(entry.id)
        )
        self.stage:addOption(label)
    end
    self.stage.selected = clamp(previous, 1, math.max(1, #stages))
    self:refreshFinishOptions()
    self.requirements:setSelection(definition, self:selectedStage(), self:selectedFinish())
    self.accessPanel:setSelection(definition, self:selectedStage())
end

function KBWCatalog:refreshFinishOptions()
    local definition, stage = self:effectiveDefinition(), self:selectedStage()
    self.finish:clear()
    self.finishValues = {}
    local entries = definition and stage and finishEntriesFor(definition, stage) or {}
    for entryIndex = 1, #entries do
        local entry = entries[entryIndex]
        self.finish:addOption(I18n.optionName(entry, entry.id or "?"))
        self.finishValues[#self.finishValues + 1] = entry
    end
    local hasEntries = #self.finishValues > 0
    self.finish.selected = 1
    self.finish:setEnabled(hasEntries)
    self.finish:setVisible((not self.compact) and hasEntries)
end

function KBWCatalog:selectedStage()
    if Groups.isGroup(self.selected) then return self:rawSelectedStage() end
    local definition = self:effectiveDefinition()
    if self.visibleStages then return self.visibleStages[self.stage.selected or 1] end
    return definition and definition.stages[self.stage.selected or 1]
end

function KBWCatalog:selectedVariant()
    local definition = Groups.resolveDefinition(self.selected, self:rawSelectedStage()) or self.selected
    local index = (self.variant.selected or 1) - 1
    return index > 0 and definition.variants and definition.variants[index] and definition.variants[index].id or ""
end

function KBWCatalog:selectedMaterial()
    local definition = Groups.resolveDefinition(self.selected, self:rawSelectedStage()) or self.selected
    local index = (self.material.selected or 1) - 1
    return index > 0 and definition.materialOptions
        and definition.materialOptions[index] and definition.materialOptions[index].id or ""
end

function KBWCatalog:selectedFinish()
    local entry = self.finishValues and self.finishValues[self.finish.selected or 1] or nil
    if entry and entry.none then return nil end
    return entry
end

function KBWCatalog:firstIngredientRow(preferFinish)
    local rows = self.requirements and self.requirements.rows or {}
    if preferFinish then
        for rowIndex = 1, #rows do
            local row = rows[rowIndex]
            if row and row.isFinish and row.kind ~= "skill" and row.kind ~= "knowledge" then return row end
        end
    end
    for rowIndex = 1, #rows do
        local row = rows[rowIndex]
        if row and row.kind ~= "skill" and row.kind ~= "knowledge" then return row end
    end
    return nil
end

function KBWCatalog:updateIngredientDrawerForSelection(forceOpen, preferFinish)
    if not self.ingredientDrawer then return end
    if self.compact then
        self.ingredientDrawer:setVisible(false)
        return
    end
    if not forceOpen and not self.drawerPinnedOpen then return end
    local row = self:firstIngredientRow(preferFinish)
    if row then
        self.drawerPinnedOpen = true
        uiData(self.player).drawerPinnedOpen = true
        if self.requirements and self.requirements.setSelectedRow then self.requirements:setSelectedRow(row) end
        if self.accessPanel and self.accessPanel.setSelectedRow then self.accessPanel:setSelectedRow(row) end
        self.ingredientDrawer:setRow(row, self:getInputChoice(row), self:getInputChoiceItem(row))
    else
        self.ingredientDrawer:setRow(nil)
    end
end

---@param row KBW.RequirementRow
function KBWCatalog:choiceKey(row)
    local definition, stage = self:effectiveDefinition(), self:selectedStage()
    if not definition or not stage or not row then return nil end
    return tostring(definition.id) .. "|" .. tostring(Groups.resolveStageId(stage) or stage.id) .. "|"
        .. tostring(row.id or row.name or row.kind)
end

---@param row KBW.RequirementRow
function KBWCatalog:getInputChoice(row)
    local key = self:choiceKey(row)
    return key and self.inputChoices and self.inputChoices[key] or nil
end

---@param row KBW.RequirementRow
function KBWCatalog:getInputChoiceItem(row)
    local key = self:choiceKey(row)
    return key and self.inputChoiceItems and self.inputChoiceItems[key] or nil
end

function KBWCatalog:selectedInputChoices()
    local definition, stage = self:effectiveDefinition(), self:selectedStage()
    local choices = {}
    if not definition or not stage or not self.inputChoices then return choices end
    local validIds = {}
    local inputs = Requirements.getInputs(definition, stage)
    for inputIndex = 1, #inputs do
        validIds[tostring(inputs[inputIndex].id)] = true
    end
    local prefix = tostring(definition.id) .. "|" .. tostring(Groups.resolveStageId(stage) or stage.id) .. "|"
    local prefixLength = #prefix
    for key, value in pairs(self.inputChoices) do
        if string.sub(key, 1, prefixLength) == prefix then
            local inputId = string.sub(key, prefixLength + 1)
            if validIds[inputId] then choices[inputId] = value end
        end
    end
    return choices
end

---@param row KBW.RequirementRow
function KBWCatalog:onIngredientChoice(row, fullType, itemKey)
    -- Finish requirements are a separate action pipeline, not construction
    -- recipe inputs. Persisting their UI row ids made authoritative recipe
    -- validation reject builds as "unknown input id finish-*".
    if row and row.isFinish then
        if self.ingredientDrawer then self.ingredientDrawer:setRow(row, fullType, itemKey or fullType) end
        self:updateActions()
        return
    end
    local key = self:choiceKey(row)
    if not key or not fullType then return end
    self.inputChoices[key] = fullType
    self.inputChoiceItems[key] = itemKey or fullType
    uiData(self.player).inputChoices = self.inputChoices
    uiData(self.player).inputChoiceItems = self.inputChoiceItems
    if row then row.selectedFullType = fullType end
    self.selectionStatusCache = nil
    if self.requirements then
        self.requirements:setSelection(self:effectiveDefinition(), self:selectedStage(), self:selectedFinish())
    end
    local refreshedRow = row
    if self.requirements and self.requirements.rows then
        for rowIndex = 1, #self.requirements.rows do
            local candidate = self.requirements.rows[rowIndex]
            if candidate and candidate.id == row.id then
                refreshedRow = candidate
                break
            end
        end
    end
    if self.accessPanel and self.accessPanel.setSelectedRow then self.accessPanel:setSelectedRow(refreshedRow) end
    if self.requirements and self.requirements.setSelectedRow then self.requirements:setSelectedRow(refreshedRow) end
    if self.ingredientDrawer then
        self.ingredientDrawer:setRow(refreshedRow, fullType, self.inputChoiceItems[key])
    end
    self:updateActions()
end

function KBWCatalog:onStageChanged()
    self:refreshVariantMaterialControls()
    self:refreshFinishOptions()
    self.requirements:setSelection(self:effectiveDefinition(), self:selectedStage(), self:selectedFinish())
    self.accessPanel:setSelection(self:effectiveDefinition(), self:selectedStage())
    self:updateIngredientDrawerForSelection(false)
    self:updateActions()
    self:layout()
end

function KBWCatalog:onStageCarousel(button)
    local count = self:stageCountForSelection()
    if count <= 1 then return end
    local selected = self.stage.selected or 1
    selected = selected + (button and button.internal or 1)
    if selected < 1 then selected = count end
    if selected > count then selected = 1 end
    self.stage.selected = selected
    self:onStageChanged()
end

function KBWCatalog:onVariantChanged()
    self:refreshStageAndFinish()
    self:updateIngredientDrawerForSelection(false)
    self:updateActions()
    self:layout()
end

function KBWCatalog:onMaterialChanged()
    self:refreshStageAndFinish()
    self:updateIngredientDrawerForSelection(false)
    self:updateActions()
    self:layout()
end

function KBWCatalog:onFinishChanged()
    -- The finish changes the material list (plaster/paint/paper) and the
    -- preview tile.
    self.requirements:setSelection(self:effectiveDefinition(), self:selectedStage(), self:selectedFinish())
    self:updateIngredientDrawerForSelection(false, true)
    self:updateActions()
    self:layout()
end

function KBWCatalog:ensureDrawerSpace()
    if self.compact then return end
    local desiredWidth = math.max(self.width, 1120)
    local playerNum = self.player:getPlayerNum()
    local maxWidth = math.max(1, getPlayerScreenLeft(playerNum) + getPlayerScreenWidth(playerNum) - 4 - self.x)
    local newWidth = math.min(desiredWidth, maxWidth)
    if newWidth > self.width then
        self:setWidth(newWidth)
        self:saveWindowState()
    end
end

---@param row KBW.RequirementRow
function KBWCatalog:onRequirementSelected(row)
    if not row then return end
    self.drawerPinnedOpen = true
    uiData(self.player).drawerPinnedOpen = true
    if self.requirements and self.requirements.setSelectedRow then self.requirements:setSelectedRow(row) end
    if self.accessPanel and self.accessPanel.setSelectedRow then self.accessPanel:setSelectedRow(row) end
    self.ingredientDrawer:setRow(row, self:getInputChoice(row), self:getInputChoiceItem(row))
    self:ensureDrawerSpace()
    self:layout()
    self.ingredientDrawer:bringToTop()
    if self.resizeWidget2 then self.resizeWidget2:bringToTop() end
    if self.resizeWidget then self.resizeWidget:bringToTop() end
end

function KBWCatalog:onIngredientDrawerClosed()
    self.drawerPinnedOpen = false
    uiData(self.player).drawerPinnedOpen = false
    self:layout()
end

---@param definition KBW.BuildableDefinition
function KBWCatalog:isFavorite(definition)
    return definition and uiData(self.player).favorites[definition.id] == true
end

---@param definition KBW.BuildableDefinition
function KBWCatalog:isPinnedDefinition(definition)
    return PinnedRecipes.hasPinnedDefinition(self.player, definition)
end

function KBWCatalog:updateFavorite()
    applyStarButton(self.favoriteButton, self.selected and uiData(self.player).favorites[self.selected.id] == true)
end

function KBWCatalog:onFavorite()
    if not self.selected then return end
    local favorites = uiData(self.player).favorites
    favorites[self.selected.id] = not favorites[self.selected.id]
    self
        :updateFavorite()
    if self.scope == "Favorites" then self:refreshGrid() end
end

---@param definition KBW.BuildableDefinition
function KBWCatalog:onGridFavorite(definition)
    if not definition then return end
    local favorites = uiData(self.player).favorites
    favorites[definition.id] = not favorites[definition.id]
    if self.selected and self.selected.id == definition.id then self:updateFavorite() end
    if self.scope == "Favorites" then self:refreshGrid() end
end

---@param definition KBW.BuildableDefinition
function KBWCatalog:onGridPin(definition)
    if not definition then return end
    PinnedRecipes.toggleDefault(self.player, definition)
    self:refreshGrid()
    self:updateActions()
end

function KBWCatalog:remember()
    local data = uiData(self.player)
    local recent = { self.selected.id }
    for recentIndex = 1, #data.recent do
        local id = data.recent[recentIndex]
        if id ~= self.selected.id and #recent < 12 then recent[#recent + 1] = id end
    end
    data.recent = recent
end

local function selectedFilterValue(values, combo)
    return values and combo and values[combo.selected] or nil
end

local function selectFilterValue(combo, values, value)
    if not combo or not values then return end
    combo.selected = 1
    if not value then return end
    for index = 1, #values do
        local entry = values[index]
        if entry == value then
            combo.selected = index
            return
        end
    end
end

local function selectComboIndex(combo, index)
    if not combo or not index or index < 1 then return end
    local max = combo.options and #combo.options or index
    combo.selected = index <= max and index or 1
end

function KBWCatalog:rememberDragReturn()
    if not self.selected then return end
    KBWCatalog.dragReturnState = {
        playerNum = self.player:getPlayerNum(),
        selectedId = self.selected.id,
        scope = self.scope,
        category = self.category,
        categoryPage = self.categoryPage,
        categoryOffset = self.categoryOffset,
        search = self.search and self.search:getInternalText() or "",
        subcategory = selectedFilterValue(self.subcategoryValues, self.subcategoryFilter),
        material = selectedFilterValue(self.materialFilterValues, self.materialFilter),
        skill = selectedFilterValue(self.skillFilterValues, self.skillFilter),
        stageIndex = self.stage and self.stage.selected or 1,
        variantIndex = self.variant and self.variant.selected or 1,
        materialIndex = self.material and self.material.selected or 1,
        finishIndex = self.finish and self.finish.selected or 1
    }
end

function KBWCatalog:restoreState(state)
    if not state then return end
    self.scope = state.scope or self.scope
    self.category = state.category or self.category
    self.categoryPage = state.categoryPage or self.categoryPage
    self.categoryOffset = state.categoryOffset or state.categoryPage or self.categoryOffset
    self:updateScopeButtons()
    if self.search and state.search then self.search:setText(state.search) end
    self:refreshFilterOptions()
    selectFilterValue(self.subcategoryFilter, self.subcategoryValues, state.subcategory)
    selectFilterValue(self.materialFilter, self.materialFilterValues, state.material)
    selectFilterValue(self.skillFilter, self.skillFilterValues, state.skill)
    self:layoutCategoryButtons(self.grid.width)
    self.grid:setItems(self:filteredDefinitions(), state.selectedId)
    self.selected = self.grid.items[self.grid.selectedIndex]
    self:refreshSelectionControls()
    if self.selected then
        selectComboIndex(self.variant, state.variantIndex)
        selectComboIndex(self.material, state.materialIndex)
        self:refreshStageAndFinish()
        selectComboIndex(self.stage, state.stageIndex)
        self:refreshFinishOptions()
        selectComboIndex(self.finish, state.finishIndex)
        self.requirements:setSelection(self:effectiveDefinition(), self:selectedStage(), self:selectedFinish())
        self.accessPanel:setSelection(self:effectiveDefinition(), self:selectedStage())
    end
    self:updateActions()
    self:layout()
end

-- Requirement evaluation does recursive inventory scans, far too heavy to run
-- per frame in prerender. updateActions() (event-driven) refreshes this cache
-- eagerly; prerender reuses it and only re-evaluates on a slow TTL.
---@param definition KBW.BuildableDefinition
---@param stage KBW.BuildStage
function KBWCatalog:cachedSelectionStatus(definition, stage)
    if not definition or not stage then return { ok = false } end
    local key = tostring(definition.id) .. "|" .. tostring(stage.id)
    local now = getTimestampMs()
    local cache = self.selectionStatusCache
    if cache and cache.key == key and (now - cache.time) < 1200 then return cache.status end
    local status = Requirements.evaluate(self.player, definition, stage, nil, self:selectedInputChoices())
    self.selectionStatusCache = { key = key, status = status, time = now }
    local finishOk = hasFinishItem(self.player, self:selectedFinish(), definition, stage)
    Theme.applyActionButton(self.buildButton, Integrity.isAllowed(self.player) and status.ok and finishOk, true)
    return status
end

function KBWCatalog:updateActions()
    local definition, stage = self:effectiveDefinition(), self:selectedStage()
    local status = definition and stage
        and Requirements.evaluate(self.player, definition, stage, nil, self:selectedInputChoices())
        or { ok = false }
    if definition and stage then
        self.selectionStatusCache = {
            key = tostring(definition.id) .. "|" .. tostring(stage.id),
            status = status,
            time = getTimestampMs()
        }
    end
    local allowed = Integrity.isAllowed(self.player)
    local finishOk = hasFinishItem(self.player, self:selectedFinish(), definition, stage)
    Theme.applyActionButton(self.buildButton, allowed and status.ok and finishOk, true)
    Theme.applyActionButton(self.planButton, allowed and self.selected ~= nil, false)
    Theme.applyActionButton(self.plansButton, true, false)
    local variantId = ""
    local materialId = ""
    if definition and stage then
        variantId = self:selectedVariant()
        materialId = self:selectedMaterial()
    end
    applyPinRecipeButton(
        self.recipePinButton,
        PinnedRecipes.isPinned(self.player, definition, stage, variantId, materialId, self:selectedFinish()),
        definition ~= nil and stage ~= nil
    )
end

function KBWCatalog:onPinRecipe()
    local definition, stage = self:effectiveDefinition(), self:selectedStage()
    if not definition or not stage then return end
    PinnedRecipes.toggle(
        self.player, definition, stage, self:selectedVariant(), self:selectedMaterial(), self:selectedFinish(),
        self:selectedInputChoices()
    )
    self:updateActions()
    self:refreshGrid()
end

function KBWCatalog:onBuild()
    if not self.selected or not Integrity.isAllowed(self.player) then return end
    local definition, stage = self:effectiveDefinition(), self:selectedStage()
    if not stage
        or not Requirements
            .evaluate(self.player, definition, stage, nil, self:selectedInputChoices())
            .ok then
        return
    end
    if not hasFinishItem(self.player, self:selectedFinish(), definition, stage) then return end
    if (definition.placement or {}).kind == "wallCovering" then
        self:remember()
        self:rememberDragReturn()
        local state = KBWCatalog.dragReturnState
        self:close()
        if not beginWallCoveringCursor(self.player, definition, stage, self:selectedFinish()) then
            KBWCatalog.dragReturnState = nil
            KBWCatalog.open(self.player, state)
        end
        return
    end
    if not KBWBuildingObject then require "KnoxBuildworks/BuildingObjects/KBWBuildingObject" end
    self:remember()
    self:rememberDragReturn()
    self:close()
    local cursor = KBWBuildingObject:new(
        self.player, Groups.resolveBuildableId(definition, stage), Groups.resolveStageId(stage), self:selectedVariant(),
        self:selectedMaterial(), 1, self:selectedInputChoices()
    )
    cursor.finish = self:selectedFinish()
    getCell():setDrag(cursor, self.player:getPlayerNum())
end

function KBWCatalog:onPlan()
    if not self.selected or not Integrity.isAllowed(self.player) then return end
    local definition, stage = self:effectiveDefinition(), self:selectedStage()
    if not stage or not definition then return end
    self:remember()
    self:rememberDragReturn()
    self:close()
    Planner.begin(
        self.player, Groups.resolveBuildableId(definition, stage), Groups.resolveStageId(stage), self:selectedVariant(),
        self:selectedMaterial(), 1, self:selectedFinish()
    )
end

function KBWCatalog:onPlans()
    self:close()
    PlanningMode.open(self.player)
end

function KBWCatalog:onToggleSize()
    local data = uiData(self.player)
    self.compact = not self.compact
    data.compact = self.compact
    self.minimumWidth = self.compact and COMPACT_MIN_WIDTH or DETAILED_MIN_WIDTH
    self.minimumHeight = self.compact and COMPACT_MIN_HEIGHT or DETAILED_MIN_HEIGHT
    local screenHeight = getPlayerScreenHeight(self.player:getPlayerNum())
    local defaultHeight = self.compact and 320 or math.min(760, math.max(640, math.floor(screenHeight * .68)))
    local height = data.height or defaultHeight
    if self.compact and height > 360 then height = 320 end
    height = math.max(self.minimumHeight, height)
    local playerNum = self.player:getPlayerNum()
    local screenWidth = getPlayerScreenWidth(playerNum) - 8
    local width = math.min(screenWidth, data.width or screenWidth)
    width = math.max(self.minimumWidth, width)
    local x, y, newWidth, newHeight = clampedWindowRect(playerNum, self.x, self.y, width, height)
    self:setX(x)
    self:setY(y)
    self:setWidth(newWidth)
    self:setHeight(newHeight)
    self:saveWindowState()
    self:ensureResizeWidgets()
    self:positionHeaderActions()
    self.sizeButton:setTitle(self.compact and "^" or "v")
    self:layout()
    self:refreshGrid()
end

function KBWCatalog:positionHeaderActions()
    local top = contentTop(self)
    self.sizeButton:setX(self.width - 78)
    self.sizeButton:setY(top + 8)
    self.plansButton:setX(self.width - 164)
    self.plansButton:setY(top + 8)
    self.plansButton:setWidth(80)
    self
        .plansButton:setHeight(32)
    if self.compact then
        self.buildButton:setY(top + 8)
        self.planButton:setY(top + 8)
    end
end

function KBWCatalog:update()
    ISPanel.update(self)
    if self.moving or self.isResizingFromWidget then return end;
    local now = getTimestampMs()
    if self.lastSafeLayoutCheck and now - self.lastSafeLayoutCheck < 750 then return end;
    self.lastSafeLayoutCheck = now
    local x, y, width, height = clampedWindowRect(self.player:getPlayerNum(), self.x, self.y, self.width, self.height)
    if x ~= self.x or y ~= self.y or width ~= self.width or height ~= self.height then
        self:setX(x)
        self:setY(y)
        self:setWidth(width)
        self:setHeight(height)
        self:positionHeaderActions()
        self:layout()
        self:refreshGrid()
    end
end

function KBWCatalog:saveWindowState()
    local data = uiData(self.player)
    data.x = self.x
    data.y = self.y
    data.width = self.width
    data.height = self.height
end

function KBWCatalog:resizeFromWidgetMouse(widget)
    local minWidth = self.minimumWidth or DETAILED_MIN_WIDTH
    local minHeight = self.minimumHeight or DETAILED_MIN_HEIGHT
    local width = (self.resizeStartWidth or self.width)
    local height = (self.resizeStartHeight or self.height) + (getMouseY() - (self.resizeStartMouseY or getMouseY()))
    if not widget or not widget.yonly then
        width = width + (getMouseX() - (self.resizeStartMouseX or getMouseX()))
    end
    local newWidth, newHeight = liveResizeSize(
        self.player:getPlayerNum(), self.x, self.y, math.max(minWidth, width), math.max(minHeight, height), minWidth,
        minHeight
    )
    self.isResizingFromWidget = true
    self:setWidth(newWidth)
    self:setHeight(newHeight)
    self:positionHeaderActions()
    self:layout(true)
end

---@param width number
---@param height number
function KBWCatalog:resizeFromWidget(width, height)
    local minWidth = self.minimumWidth or DETAILED_MIN_WIDTH
    local minHeight = self.minimumHeight or DETAILED_MIN_HEIGHT
    local newWidth, newHeight = liveResizeSize(
        self.player:getPlayerNum(), self.x, self.y, math.max(minWidth, width), math.max(minHeight, height), minWidth,
        minHeight
    )
    self:setWidth(newWidth)
    self:setHeight(newHeight)
    self:positionHeaderActions()
    self:layout(true)
    self:saveWindowState()
end

function KBWCatalog:finishResize()
    if not self.isResizingFromWidget then return end
    self.isResizingFromWidget = false
    self.resizeStartMouseX = nil
    self.resizeStartMouseY = nil
    self.resizeStartWidth = nil
    self.resizeStartHeight = nil
    local newX, newY, newWidth, newHeight = clampedWindowRect(
        self.player:getPlayerNum(), self.x, self.y, self.width, self.height
    )
    self:setX(newX)
    self:setY(newY)
    self:setWidth(newWidth)
    self:setHeight(newHeight)
    self:positionHeaderActions()
    self:refreshGrid()
    self:saveWindowState()
end

---@param x number
---@param y number
function KBWCatalog:onMouseUp(x, y)
    ISCollapsableWindow.onMouseUp(self, x, y)
    self:finishResize()
    local newX, newY, newWidth, newHeight = clampedWindowRect(
        self.player:getPlayerNum(), self.x, self.y, self.width, self.height
    )
    if newX ~= self.x or newY ~= self.y or newWidth ~= self.width or newHeight ~= self.height then
        self:setX(newX)
        self:setY(newY)
        self:setWidth(newWidth)
        self:setHeight(newHeight)
        self:refreshGrid()
    end
    self:saveWindowState()
    return true
end

---@param x number
---@param y number
function KBWCatalog:onMouseUpOutside(x, y)
    ISCollapsableWindow.onMouseUpOutside(self, x, y)
    self:finishResize()
    local newX, newY, newWidth, newHeight = clampedWindowRect(
        self.player:getPlayerNum(), self.x, self.y, self.width, self.height
    )
    if newX ~= self.x or newY ~= self.y or newWidth ~= self.width or newHeight ~= self.height then
        self:setX(newX)
        self:setY(newY)
        self:setWidth(newWidth)
        self:setHeight(newHeight)
        self:refreshGrid()
    end
    self:saveWindowState()
    return true
end

function KBWCatalog:hideMetaTooltip()
    if self.metaTooltip then
        self.metaTooltip:setVisible(false)
        self.metaTooltip:removeFromUIManager()
        self.metaTooltip = nil
    end
end

---@param dx number
---@param dy number
function KBWCatalog:onMouseMove(dx, dy)
    local wasCollapsed = self.isCollapsed == true
    if ISCollapsableWindow.onMouseMove then ISCollapsableWindow.onMouseMove(self, dx, dy) end
    if wasCollapsed and not self.isCollapsed then
        self.pin = true
        if self.collapseButton then
            self.collapseButton:setVisible(true)
            self.collapseButton:bringToTop()
        end
        if self.pinButton then self.pinButton:setVisible(false) end
        self:ensureResizeWidgets()
        self:layout(true)
    end
    local mx = self:getMouseX()
    local my = self:getMouseY()
    local rows = self.metaHitRows or {}
    for rowIndex = 1, #rows do
        local hit = rows[rowIndex]
        if mx >= hit.x and mx <= hit.x + hit.w and my >= hit.y and my <= hit.y + hit.h then
            if not self.metaTooltip then
                self.metaTooltip = ISToolTip:new()
                self.metaTooltip:addToUIManager()
                self.metaTooltip.owner = self
            end
            self.metaTooltip:setName(hit.text)
            self.metaTooltip:setVisible(true)
            self.metaTooltip:setAlwaysOnTop(true)
            return
        end
    end
    self:hideMetaTooltip()
end

---@param dx number
---@param dy number
function KBWCatalog:onMouseMoveOutside(dx, dy)
    if ISCollapsableWindow.onMouseMoveOutside then ISCollapsableWindow.onMouseMoveOutside(self, dx, dy) end
    self:hideMetaTooltip()
end

function KBWCatalog:prerender()
    ISCollapsableWindow.prerender(self)
    local top = contentTop(self)
    self:drawRect(0, top, self.width, 44, .94, Theme.backdrop.r, Theme.backdrop.g, Theme.backdrop.b)
    if not self.compact then
        local inspectorTop = top + 48
        local inspectorHeight = self.height - self:resizeWidgetHeight() - inspectorTop - 10
        self:drawRect(
            self.inspectorX + 4, inspectorTop, self.inspectorWidth - 12, inspectorHeight, Theme.surface.a,
            Theme.surface.r, Theme.surface.g, Theme.surface.b
        )
        self:drawRectBorder(
            self.inspectorX + 4, inspectorTop, self.inspectorWidth - 12, inspectorHeight, Theme.borderSoft.a,
            Theme.borderSoft.r, Theme.borderSoft.g, Theme.borderSoft.b
        )
    end
end

function KBWCatalog:render()
    local top = contentTop(self)
    self.stageDotHits = {}
    if not self.compact then
        local definition, stage = self:effectiveDefinition(), self:selectedStage()
        if definition and stage then
            local x = self.inspectorX + 16
            local textWidth = math.max(120, self.inspectorWidth - 32)
            drawLinesForFont(
                self, UIFont.Medium,
                self.infoNameLines or wrapTextForFont(UIFont.Medium, displayName(definition), textWidth), x,
                self.infoNameY or (top + 56), Theme.text, 1
            )
            drawLinesForFont(
                self, UIFont.Small, self.infoTooltipLines or {}, x, self.infoTooltipY or (top + 78), Theme.textMuted, 1
            )
            drawMetadataChips(self, self.infoMetaEntries or {}, x, self.infoMetaY or (top + 96), textWidth)
            local texture, textureColor = IconResolver.textureForDefinition(definition, stage)
            -- Preview the finished face when a wall finish is selected.
            local selectedFinish = self:selectedFinish()
            if WallFinishes.isWallFinish(selectedFinish) then
                local finishSpriteName = WallFinishes.previewSprite(selectedFinish, false, definition, stage)
                local finishTexture = finishSpriteName and IconResolver.textureForSpriteName(finishSpriteName) or nil
                if finishTexture then
                    texture = finishTexture
                    textureColor = { r = 1, g = 1, b = 1, a = 1 }
                end
            end
            local previewX = self.previewX or x
            local previewY = self.previewY or (top + 104)
            local previewWidth = self.previewWidth or 112
            local previewHeight = self.previewHeight or 116
            self:drawRect(
                previewX, previewY, previewWidth, previewHeight, Theme.surfaceRaised.a, Theme.surfaceRaised.r,
                Theme.surfaceRaised.g, Theme.surfaceRaised.b
            )
            self:drawRectBorder(
                previewX, previewY, previewWidth, previewHeight, Theme.border.a, Theme.border.r, Theme.border.g,
                Theme.border.b
            )
            if texture then
                self:drawTextureScaledAspect(
                    texture, previewX + 16, previewY + 9, 80, 80, 1, textureColor.r, textureColor.g, textureColor.b
                )
            end
            local cells = Matrix.getFaceCells(stage, "S") or {}
            local bounds = Matrix.getBounds(cells)
            self:drawTextCentre(
                string.format("%dx%dx%d", bounds.width, bounds.height, bounds.depth),
                previewX + math.floor(previewWidth / 2), previewY + previewHeight - 28,
                Theme.accent
                    .r,
                Theme.accent.g, Theme.accent.b, 1, UIFont.Small
            )
            local stageCount = self:stageCountForSelection()
            local stageIndex = self.stage and self.stage.selected or 1
            local stageLines = self.showStageLabel
                and wrapTextForFont(UIFont.Small, stageDisplayText(stage, stageIndex, stageCount), textWidth)
                or {}
            local stageY = self.stageLabelY or (previewY + previewHeight + 8)
            if #stageLines > 0 then drawLinesForFont(self, UIFont.Small, stageLines, x, stageY, Theme.accent, 1) end
            self.stageDotHits = {}
            if stageCount > 1 then
                local dotSize = 5
                local dotGap = 5
                local totalDots = stageCount * dotSize + (stageCount - 1) * dotGap
                local dotX = x + math.floor((textWidth - totalDots) / 2)
                local dotY = stageY + (#stageLines * (FONT_HGT_SMALL + 2)) + 5
                for dotIndex = 1, stageCount do
                    local color = dotIndex == stageIndex and Theme.accent or Theme.borderSoft
                    self:drawRect(dotX, dotY, dotSize, dotSize, 1, color.r, color.g, color.b)
                    self.stageDotHits[#self.stageDotHits + 1] = {
                        x = dotX - 4,
                        y = dotY - 4,
                        w = dotSize + 8,
                        h = dotSize + 8,
                        index = dotIndex
                    }
                    dotX = dotX + dotSize + dotGap
                end
            end
            if self.variant:isVisible() and self.variantLabelY then
                self:drawText(
                    getText("IGUI_KBW_Variant"), x, self.variantLabelY, Theme.textMuted.r, Theme.textMuted.g,
                    Theme.textMuted.b, 1, UIFont.Small
                )
            end
            if self.material:isVisible() and self.materialLabelY then
                self:drawText(
                    getText("IGUI_KBW_MaterialSet"), x, self.materialLabelY, Theme.textMuted.r, Theme.textMuted.g,
                    Theme.textMuted.b, 1, UIFont.Small
                )
            end
            if self.finish:isVisible() then
                self:drawText(
                    getText("IGUI_KBW_Finish"), x, self.finishLabelY or (top + 240), Theme.textMuted.r,
                    Theme.textMuted.g, Theme.textMuted.b, 1, UIFont.Small
                )
            end
            local statusY = self.statusY or (top + 274)
            local actions = definition.postBuildActions or {}
            if #actions > 0 then
                local names = {}
                for actionIndex = 1, #actions do
                    local action = actions[actionIndex]
                    names[#names + 1] = action.label or action.kind or action.id
                end
                local postLines = wrapTextForFont(
                    UIFont.Small, getText("IGUI_KBW_PostBuild") .. ": " .. table.concat(names, ", "), textWidth
                )
                drawLinesForFont(
                    self, UIFont.Small, postLines, x, statusY - (#postLines * (FONT_HGT_SMALL + 2)) - 4, Theme.textMuted,
                    1
                )
            end
            local status = self:cachedSelectionStatus(definition, stage)
            local finishOk = hasFinishItem(self.player, self:selectedFinish(), definition, stage)
            local ready = status.ok and finishOk and Integrity.isAllowed(self.player)
            local color = ready and Theme.good or Theme.warn
            self:drawText(
                ready and getText("IGUI_KBW_ReadyToBuild") or getText("IGUI_KBW_CannotBuild"), x, statusY, color.r,
                color.g, color.b, 1, UIFont.Small
            )
            if KnoxBuildworks.Runtime.debug then
                self:drawText(
                    definition.id, x, statusY - 19, Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 1,
                    UIFont.Small
                )
            end
            if not Integrity.isAllowed(self.player) then
                self:drawText(
                    KnoxBuildworks.Runtime.integrityMessage or getText("IGUI_KBW_IntegrityPending"), x, statusY - 19,
                    Theme.bad
                        .r,
                    Theme.bad.g, Theme.bad.b, 1, UIFont.Small
                )
            end
            if self.skillsHeaderY and self.accessPanel:isVisible() then
                self:drawText(
                    getText("IGUI_KBW_SkillsKnowledge"), x, self.skillsHeaderY, Theme.accent.r, Theme.accent.g,
                    Theme.accent.b, 1, UIFont.Small
                )
                self:drawRect(
                    x, self.skillsHeaderY + FONT_HGT_SMALL + 3, self.inspectorWidth - 32, 1, Theme.borderSoft.a,
                    Theme.borderSoft.r, Theme.borderSoft.g, Theme.borderSoft.b
                )
            end
            if self.requirementsHeaderY and self.requirements:isVisible() then
                self:drawText(
                    getText("IGUI_KBW_MaterialsTools"), x, self.requirementsHeaderY, Theme.accent.r, Theme.accent.g,
                    Theme.accent.b, 1, UIFont.Small
                )
                self:drawRect(
                    x, self.requirementsHeaderY + FONT_HGT_SMALL + 3, self.inspectorWidth - 32, 1, Theme.borderSoft.a,
                    Theme.borderSoft.r, Theme.borderSoft.g, Theme.borderSoft.b
                )
            end
        end
    end
    ISCollapsableWindow.render(self)
end

function KBWCatalog:close()
    self:hideMetaTooltip()
    self:saveWindowState()
    self:setVisible(false)
    self:removeFromUIManager()
    if KBWCatalog.instance == self then KBWCatalog.instance = nil end
end

---@param player IsoPlayer
function KBWCatalog.open(player, restoreState)
    if not KBW.Runtime.loaded then
        local target = player or getPlayer()
        if target and HaloTextHelper and HaloTextHelper.addText then
            HaloTextHelper.addText(target, getText("IGUI_KBW_DefinitionsLoading"))
        end
        return
    end
    if KBWCatalog.instance then KBWCatalog.instance:close() end
    local ui = KBWCatalog:new(player or getPlayer())
    ui:initialise()
    ui:addToUIManager()
    KBWCatalog.instance = ui
    ui:restoreState(restoreState)
end

---@param item unknown
---@param playerNum number
function KBWCatalog.onSetDragItem(item, playerNum)
    local state = KBWCatalog.dragReturnState
    if not state or item ~= nil then return end
    if playerNum ~= nil and tonumber(playerNum) ~= tonumber(state.playerNum) then return end
    KBWCatalog.dragReturnState = nil
    local player = getSpecificPlayer(state.playerNum) or getPlayer()
    if player then KBWCatalog.open(player, state) end
end

if Events.SetDragItem and not KBWCatalog.eventsInstalled then
    Events.SetDragItem.Add(KBWCatalog.onSetDragItem)
    KBWCatalog.eventsInstalled = true
end

return KBWCatalog
