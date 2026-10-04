--- Catalog provides the Knox Buildworks custom user-interface layer.
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
local IconResolver = require("KnoxBuildworks/UI/IconResolver")
local EntityCompat = require("KnoxBuildworks/Entity/EntityCompat")
local StageConfig = require("KnoxBuildworks/Definitions/StageConfig")
local CatalogVisibility = require("KnoxBuildworks/UI/CatalogVisibility")
local WallFinishes = require("KnoxBuildworks/Validation/WallFinishes")
local I18n = require("KnoxBuildworks/I18n")
local CatalogIndex = require("KnoxBuildworks/UI/CatalogIndex")
local Profiler = require("KnoxBuildworks/Util/Profiler")
local BuildableInfo = require("KnoxBuildworks/UI/BuildableInfo")
local Options = require("KnoxBuildworks/Options")
local CatalogSettings = require("KnoxBuildworks/UI/CatalogSettings")
local Guide = require("KnoxBuildworks/UI/Guide")
local Workspace = require("KnoxBuildworks/UI/CatalogWorkspace")
local Readiness = require("KnoxBuildworks/UI/CatalogReadiness")
local VirtualListBox = require("KnoxBuildworks/UI/VirtualListBox")

---@class KBWCatalog: ISCollapsableWindow
KBWCatalog = ISCollapsableWindow:derive("KBWCatalog")
KBWCatalog.instance = nil
KBWCatalog.dragReturnState = nil
KBWCatalog.pendingOpenPlayerNum = nil

local STAR_UNSET = getTexture("media/ui/inventoryPanes/FavouriteNo.png")
local STAR_SET = getTexture("media/ui/inventoryPanes/FavouriteYes.png")
local PIN_TEXTURE = getTexture("media/ui/inventoryPanes/Button_Pin.png")
local VIEW_LIST_TEXTURE = getTexture("media/ui/craftingMenus/Icon_List.png")
local VIEW_GRID_TEXTURE = getTexture("media/ui/craftingMenus/Icon_Grid.png")
local GEAR_TEXTURE = getTexture("media/ui/inventoryPanes/Button_Gear.png")
    or getTexture("media/ui/inventoryPanes/Button_Settings.png")
---@class KBW.META_TEXTURESModule
---@type KBW.META_TEXTURESModule
local META_TEXTURES = {
    time = getTexture("media/ui/craftingMenus/BuildProperty_Clock_16.png"),
    light = getTexture("media/ui/craftingMenus/BuildProperty_Light_16.png"),
    book = getTexture("media/ui/craftingMenus/BuildProperty_Book_16.png"),
    walk = getTexture("media/ui/craftingMenus/BuildProperty_Walking_16.png"),
    surface = getTexture("media/ui/craftingMenus/BuildProperty_Surface_16.png")
}
local DETAILED_MIN_WIDTH = 900
local DETAILED_MIN_HEIGHT = 600
local COMPACT_MIN_WIDTH = 620
local COMPACT_MIN_HEIGHT = 520
local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)

local function compactMinimumHeight()
    -- Fit the icon grid, carousel, and two selector rows at accessibility
    -- font sizes while retaining the existing floor for normal fonts.
    return math.max(COMPACT_MIN_HEIGHT, 260 + getTextManager():getFontHeight(UIFont.Small) * 8)
end

local function detailedMinimumHeight()
    -- At large accessibility fonts the inspector needs room for its preview,
    -- stage selector, readiness line, and both fixed scroll viewports.
    return math.max(DETAILED_MIN_HEIGHT, 430 + getTextManager():getFontHeight(UIFont.Small) * 12)
end

local function displayName(definition)
    return I18n.definitionName(definition)
end

local function definitionDescription(definition)
    return I18n.definitionDescription(definition)
end

local function uiData(player)
    local root = player:getModData()
    root.KBW_UI = root.KBW_UI or { favorites = {}, recent = {}, compact = false }
    if root.KBW_UI.catalogLayoutVersion ~= 2 then
        -- The old catalogue defaulted to full-screen width and stored that as
        -- though the player had resized it. Migrate once to independent,
        -- intentionally smaller detailed and compact window sizes.
        root.KBW_UI.x = nil
        root.KBW_UI.y = nil
        root.KBW_UI.width = nil
        root.KBW_UI.height = nil
        root.KBW_UI.catalogLayoutVersion = 2
    end
    root.KBW_UI.favorites = root.KBW_UI.favorites or {}
    root.KBW_UI.recent = root.KBW_UI.recent or {}
    return root.KBW_UI
end

local function persistUiData(player)
    if isClient() and player and player.transmitModData then player:transmitModData() end
end

local function copyCategorySet(source)
    local result = {}
    if type(source) == "table" then
        for category, selected in pairs(source) do
            if selected == true then result[tostring(category)] = true end
        end
    end
    return result
end

local function hasSelectedCategories(catalog)
    if not catalog or not catalog.selectedCategories then return false end
    for _ in pairs(catalog.selectedCategories) do
        return true
    end
    return false
end

local function firstSelectedCategory(catalog)
    if not catalog or not catalog.selectedCategories then return "All" end
    for category in pairs(catalog.selectedCategories) do
        return category
    end
    return "All"
end

local function configureButton(button, selected)
    button:initialise()
    Theme.applyButton(button, selected)
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
    button.textColor = Theme.color(Theme.text)
    button.textColorDisable = Theme.color(Theme.textMuted)
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
    button.backgroundColor = active and Theme.color(Theme.selectedSoft) or { r = 0, g = 0, b = 0, a = 0 }
    button.backgroundColorMouseOver.a = enabled and .18 or 0
    button.borderColor = Theme.color(active and Theme.accent or Theme.borderSoft)
    button.borderColor.a = active and .55 or 0
    button.textColor = Theme.color(Theme.text)
    button.textColorDisable = Theme.color(Theme.textMuted)
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
    if StageConfig.placement(definition, stage).requiresOutside == true then
        entries[#entries + 1] = { text = getText("IGUI_KBW_RequiresOutside") }
    end
    return entries
end

local function metadataChipHeight(entries, width)
    if not entries or #entries == 0 then return 0 end
    local lineHeight = getTextManager():getFontHeight(UIFont.Small) + 8
    local used = 0
    local lines = 1
    for entryIndex = 1, #entries do
        local entry = entries[entryIndex]
        local text = tostring(entry.text or "")
        local horizontalPadding = entry.texture and 34 or 14
        local chipWidth = math.min(width, getTextManager():MeasureStringX(UIFont.Small, text) + horizontalPadding)
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
    local fontHeight = getTextManager():getFontHeight(UIFont.Small)
    local lineHeight = fontHeight + 8
    local chipHeight = fontHeight + 5
    local chipX = x
    local chipY = y
    for entryIndex = 1, #entries do
        local entry = entries[entryIndex]
        local text = tostring(entry.text or "")
        local horizontalPadding = entry.texture and 34 or 14
        local chipWidth = math.min(width, getTextManager():MeasureStringX(UIFont.Small, text) + horizontalPadding)
        if chipX > x and chipX + chipWidth > x + width then
            chipX = x
            chipY = chipY + lineHeight
        end
        panel:drawRect(
            chipX, chipY, chipWidth, chipHeight, Theme.surfaceRaised.a, Theme.surfaceRaised.r, Theme.surfaceRaised.g,
            Theme.surfaceRaised.b
        )
        panel:drawRectBorder(
            chipX, chipY, chipWidth, chipHeight, Theme.borderSoft.a, Theme.borderSoft.r, Theme.borderSoft.g,
            Theme.borderSoft.b
        )
        if entry.texture then
            local iconSize = math.min(18, fontHeight)
            panel:drawTextureScaledAspect(entry.texture, chipX + 3, chipY + 2, iconSize, iconSize, 1, 1, 1, 1)
        end
        local textX = entry.texture and chipX + 23 or chipX + 7
        local displayText = shortenedText(UIFont.Small, text, math.max(10, chipWidth - horizontalPadding))
        panel:drawText(
            displayText, textX, chipY + 3, Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 1, UIFont.Small
        )
        panel.metaHitRows[#panel.metaHitRows + 1] = { x = chipX, y = chipY, w = chipWidth, h = chipHeight, text = text }
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
        return WallFinishes.validateItems(player, finish, definition, stage) == true
    end
    local inventory = player:getInventory()
    if finish.paintType then return WallFinishes.paintItemsIn(inventory, finish.paintType) ~= nil end
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
    local cursor = nil
    if action == "paintThump" then
        local WallFinishCursor = require("KnoxBuildworks/BuildingObjects/KBWWallFinishCursor")
        cursor = WallFinishCursor.new(player, action, args, finish)
    else
        if not ISPaintCursor then require "BuildingObjects/ISPaintCursor" end
        if not ISPaintCursor then return false end
        cursor = ISPaintCursor:new(player, action, args)
    end
    if not cursor then return false end
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
    Theme.applyAccessibility(Options)
    local screenWidth = getPlayerScreenWidth(playerNum) - 8
    local screenHeight = getPlayerScreenHeight(playerNum)
    local compactMinHeight = compactMinimumHeight()
    local detailedMinHeight = detailedMinimumHeight()
    local defaultHeight = compact and math.max(compactMinHeight, math.floor(screenHeight * .46))
        or math.max(detailedMinHeight, math.floor(screenHeight * .72))
    local maxHeight = math.max(280, screenHeight - 36)
    local heightKey = compact and "compactHeight" or "detailedHeight"
    local widthKey = compact and "compactWidth" or "detailedWidth"
    local xKey = compact and "compactX" or "detailedX"
    local yKey = compact and "compactY" or "detailedY"
    local height = math.min(maxHeight, data[heightKey] or defaultHeight)
    height = math.max(compact and compactMinHeight or detailedMinHeight, height)
    local screenLeft = getPlayerScreenLeft(playerNum) + 4
    local screenTop = getPlayerScreenTop(playerNum) + 4
    local defaultWidth = compact and math.max(COMPACT_MIN_WIDTH, math.floor(screenWidth * .48))
        or math.max(DETAILED_MIN_WIDTH, math.floor(screenWidth * .62))
    local width = math.min(screenWidth, data[widthKey] or defaultWidth)
    width = math.max(compact and COMPACT_MIN_WIDTH or DETAILED_MIN_WIDTH, width)
    local x = data[xKey] or (screenLeft + math.floor((screenWidth - width) / 2))
    local y = data[yKey] or (screenTop + math.floor((screenHeight - height) / 2))
    x, y, width, height = clampedWindowRect(playerNum, x, y, width, height)
    local o = ISCollapsableWindow:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.player = player
    o.compact = compact
    o.scope = "All"
    o.selectedCategories = copyCategorySet(data.selectedCategories)
    o.category = firstSelectedCategory(o)
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
    o.minimumHeight = compact and compactMinHeight or detailedMinHeight
    o.resizable = true
    o.pin = true
    o.title = getText("IGUI_KBW_Title")
    o.selected = nil
    o.categoryButtons = {}
    o.backgroundColor = Theme.color(Theme.backdrop)
    o.borderColor = Theme.color(Theme.border)
    o.lastVisibilityGeneration = CatalogIndex.visibilityGeneration
    o:setWantKeyEvents(true)
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
    widget.resizeFunction = false
    widget.onMouseDown = KBWCatalog.resizeWidgetMouseDown
    widget.onMouseMove = KBWCatalog.resizeWidgetMouseMove
    widget.onMouseMoveOutside = KBWCatalog.resizeWidgetMouseMoveOutside
    widget.onMouseUp = KBWCatalog.resizeWidgetMouseUp
    widget.onMouseUpOutside = KBWCatalog.resizeWidgetMouseUpOutside
end

function KBWCatalog:ensureResizeWidgets(resetState)
    self.resizable = true
    local resizeHeight = self:resizeWidgetHeight()
    local visible = self.isCollapsed ~= true
    if resetState then
        self.isResizingFromWidget = false
        self.resizeStartMouseX = nil
        self.resizeStartMouseY = nil
        self.resizeStartWidth = nil
        self.resizeStartHeight = nil
    end
    if self.resizeWidget then
        installResizeHook(self, self.resizeWidget)
        if resetState then
            self.resizeWidget.resizing = false
            self.resizeWidget:setCapture(false)
        end
        self.resizeWidget:setX(self.width - resizeHeight)
        self.resizeWidget:setY(self.height - resizeHeight)
        self.resizeWidget:setWidth(resizeHeight)
        self.resizeWidget:setHeight(resizeHeight)
        self.resizeWidget:setVisible(visible)
    end
    if self.resizeWidget2 then
        installResizeHook(self, self.resizeWidget2)
        if resetState then
            self.resizeWidget2.resizing = false
            self.resizeWidget2:setCapture(false)
        end
        self.resizeWidget2:setX(0)
        self.resizeWidget2:setY(self.height - resizeHeight)
        self.resizeWidget2:setWidth(math.max(1, self.width - resizeHeight))
        self.resizeWidget2:setHeight(resizeHeight)
        self.resizeWidget2:setVisible(visible)
    end
end

function KBWCatalog:bringChromeToTop()
    local controls = {
        self.search,
        self.searchMode,
        self.sortCombo,
        self.clearFiltersButton,
        self.viewButton,
        self.scopeAll,
        self.scopeFav,
        self
            .scopeRecent,
        self.sizeButton,
        self.appearanceButton,
        self.infoButton,
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
        self.recipePinButton,
        self.compactGroups
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
    self.infoButton:setVisible(true)
    setOptionalTooltip(self.infoButton, getText("IGUI_KBW_OpenGuide"))
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
        if box and box.target then box.target.searchDirtyAt = getTimestampMs() end
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
    self.appearanceButton = configureButton(
        ISButton:new(self.width - 116, top + 8, 32, 32, "", self, self.onAppearance), false
    )
    if GEAR_TEXTURE then
        self.appearanceButton:setImage(GEAR_TEXTURE)
        self.appearanceButton:forceImageSize(18, 18)
    else
        self.appearanceButton:setTitle("*")
    end
    setOptionalTooltip(self.appearanceButton, getText("IGUI_KBW_Appearance"))
    self:addChild(self.appearanceButton)
    self.plansButton = configureButton(
        ISButton:new(self.width - 198, top + 8, 76, 32, getText("IGUI_KBW_Plans"), self, self.onPlans), false
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

    local showAllLabel = I18n.text("IGUI_KBW_ShowAllQualities", "All qualities")
    local showAllWidth = 28 + getTextManager():MeasureStringX(UIFont.Small, showAllLabel)
    self.showAllTickBox = ISTickBox:new(12, top + 112, showAllWidth, 24, "", self, self.onShowAllVersionsChanged)
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
    self.grid:setCompactMode(self.compact)
    self:addChild(self.grid)

    self.compactGroups = VirtualListBox:new(10, top + 92, 180, 180)
    self.compactGroups:initialise()
    self.compactGroups:instantiate()
    self.compactGroups.font = UIFont.Small
    self.compactGroups.fontHgt = FONT_HGT_SMALL
    self.compactGroups.itemPadY = 5
    self.compactGroups.itemheight = FONT_HGT_SMALL + 10
    self.compactGroups.drawBorder = true
    self.compactGroups.background = true
    self.compactGroups.backgroundColor = Theme.color(Theme.surface)
    self.compactGroups.borderColor = Theme.color(Theme.borderSoft)
    self.compactGroups.selectionColor = Theme.color(Theme.selected)
    self.compactGroups.mouseOverHighlightColor = Theme.color(Theme.surfaceRaised)
    self.compactGroups.textColor = Theme.color(Theme.text)
    self.compactGroups.selectedTextColor = Theme.color(Theme.text)
    self.compactGroups:setOnMouseDownFunction(self, self.onCompactGroup)
    self.compactGroups:setVisible(false)
    self:addChild(self.compactGroups)

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
    Workspace.create(self)
    self:bringChromeToTop()

    self:refreshCategories()
    self:refreshFilterOptions()
    self:refreshCompactGroups()
    self:updateScopeButtons()
    self:layout()
    self:refreshGrid()
    self:onAppearanceChanged(true)
end

function KBWCatalog:layout(liveResize)
    Theme.applyAccessibility(Options)
    Workspace.layout(self, contentTop(self), liveResize)
end

function KBWCatalog:recipeMetadata()
    return recipeMetadataEntries(self:effectiveDefinition(), self:selectedStage())
end

function KBWCatalog:refreshCategories()
    self.categories = CatalogIndex.get().categories
    local valid = {}
    for categoryIndex = 1, #self.categories do
        valid[self.categories[categoryIndex]] = true
    end
    for category in pairs(self.selectedCategories or {}) do
        if not valid[category] then self.selectedCategories[category] = nil end
    end
    self.category = firstSelectedCategory(self)
end

function KBWCatalog:refreshFilterOptions()
    local index = CatalogIndex.get()
    local sets = index.allFilters
    if hasSelectedCategories(self) then
        sets = { subcategories = {}, materials = {}, skills = {} }
        for category in pairs(self.selectedCategories) do
            local categorySets = index.filtersByCategory[category]
            if categorySets then
                for name in pairs(categorySets.subcategories or {}) do
                    sets.subcategories[name] = true
                end
                for name in pairs(categorySets.materials or {}) do
                    sets.materials[name] = true
                end
                for name in pairs(categorySets.skills or {}) do
                    sets.skills[name] = true
                end
            end
        end
    end
    local subcategories = sets and sets.subcategories or {}
    local materials = sets and sets.materials or {}
    local skills = sets and sets.skills or {}
    local function fill(combo, allLabel, set, display)
        combo:clear()
        combo:addOption(allLabel)
        local values = { false }
        local names = {}
        local labels = {}
        for name in pairs(set) do
            names[#names + 1] = name
            labels[name] = display(name)
        end
        table.sort(names, function (a, b)
            if labels[a] ~= labels[b] then return labels[a] < labels[b] end
            return tostring(a) < tostring(b)
        end)
        for nameIndex = 1, #names do
            local name = names[nameIndex]
            combo:addOption(labels[name])
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

function KBWCatalog:refreshCompactGroups()
    if not self.compactGroups then return end
    local selectedValue = self.subcategoryValues and self.subcategoryValues[self.subcategoryFilter.selected] or false
    local values = self.subcategoryValues or { false }
    local rows = {}
    for valueIndex = 1, #values do
        local value = values[valueIndex]
        local label = value and I18n.subcategory(value) or getText("IGUI_KBW_AllSubcategories")
        rows[#rows + 1] = {name = label, definition = { value = value, comboIndex = valueIndex }}
    end
    self.compactGroups:replaceItems(rows)
    for valueIndex = 1, #self.compactGroups.items do
        local listItem = self.compactGroups.items[valueIndex]
        listItem.tooltip = listItem.text
        if listItem.item.value == selectedValue then self.compactGroups.selected = valueIndex end
    end
end

function KBWCatalog:onCompactGroup(item)
    if not item then return end
    self.subcategoryFilter.selected = item.comboIndex or 1
    self:refreshGrid()
end

function KBWCatalog:onFilterChanged()
    local data = uiData(self.player)
    data.searchModeIndex = self.searchMode and self.searchMode.selected or data.searchModeIndex
    data.sortIndex = self.sortCombo and self.sortCombo.selected or data.sortIndex
    if self.compactGroups then self.compactGroups.selected = self.subcategoryFilter.selected or 1 end
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
end

function KBWCatalog:layoutCategoryButtons(gridWidth)
    if self.workspace then return end
    for buttonIndex = 1, #self.categoryButtons do
        self.categoryButtons[buttonIndex]:setVisible(false)
    end
    local values = { { id = "All", label = getText("IGUI_KBW_AllCategories") } }
    for categoryIndex = 1, #self.categories do
        local category = self.categories[categoryIndex]
        values[#values + 1] = { id = category, label = I18n.category(category) }
    end
    local maximumTextWidth = 80
    for valueIndex = 1, #values do
        maximumTextWidth = math.max(maximumTextWidth, measureFont(UIFont.Small, values[valueIndex].label))
    end
    local availableWidth = math.max(100, gridWidth - 92)
    local buttonWidth = math.min(availableWidth, maximumTextWidth + 22)
    local buttonStep = buttonWidth + 6
    local slots = math.max(1, math.floor((availableWidth + 6) / buttonStep))
    self.categorySlots = slots
    self.categoryCatalogWidth = gridWidth
    local maxOffset = math.max(1, #values - slots + 1)
    self.categoryOffset = clamp(self.categoryOffset or 1, 1, maxOffset)
    self.categoryPage = self.categoryOffset
    local first = self.categoryOffset
    for slot = 1, slots do
        local value = values[first + slot - 1]
        if not value then break end
        local button = self.categoryButtons[slot]
        if not button then
            button = configureButton(ISButton:new(0, 0, buttonWidth, 28, "", self, self.onCategory), false)
            self.categoryButtons[slot] = button
            self:addChild(button)
        end
        button:setX((self.categoryButtonX or 82) + (slot - 1) * buttonStep)
        button:setY(self.categoryRowY or (contentTop(self) + 48))
        button:setWidth(buttonWidth)
        button:setHeight(math.max(28, FONT_HGT_SMALL + 10))
        button.internal = value.id
        button:setTitle(value.label)
        button:setVisible(true)
        setOptionalTooltip(button, getText("Tooltip_KBW_MultiCategory"))
        local selected = value.id == "All" and not hasSelectedCategories(self)
            or value.id ~= "All" and self.selectedCategories[value.id] == true
        Theme.applyButton(button, selected)
    end
    Theme.applyActionButton(self.categoryPrev, self.categoryOffset > 1, false)
    Theme.applyActionButton(self.categoryNext, self.categoryOffset < maxOffset, false)
end

function KBWCatalog:filteredDefinitions()
    local filterStart = Profiler.now()
    local index = CatalogIndex.get()
    local data, query = uiData(self.player), string.lower(self.search:getInternalText() or "")
    local subcategory = self.subcategoryValues and self.subcategoryValues[self.subcategoryFilter.selected]
    local materialTag = self.materialFilterValues and self.materialFilterValues[self.materialFilter.selected]
    local skillName = self.skillFilterValues and self.skillFilterValues[self.skillFilter.selected]
    local searchMode = self.searchModeValues and self.searchModeValues[self.searchMode.selected] or "name"
    local sortMode = self.sortValues and self.sortValues[self.sortCombo.selected] or "none"
    local shouldShowAll = CatalogVisibility.shouldShowAll(self.player)
    local scope = self.scope
    local selectedCategories = self.selectedCategories or {}
    local allCategories = not hasSelectedCategories(self)
    local hasQuery = query ~= ""
    local favorites = data.favorites
    local isFavoritesScope = scope == "Favorites"
    local recentSet = nil
    if scope == "Recent" then
        recentSet = {}
        for recentIndex = 1, #data.recent do
            recentSet[data.recent[recentIndex]] = true
        end
    end
    local source = sortMode == "az" and index.orderByName or index.orderById
    local pinnedIds, pinnedCount = PinnedRecipes.pinnedBuildableIds(self.player)
    local checkPins = pinnedCount > 0
    local pinnedResult = {}
    local result = {}
    for sourceIndex = 1, #source do
        local record = source[sourceIndex]
        local include = allCategories or selectedCategories[record.category] == true
        if include and not CatalogVisibility.definitionEnabled(record.definition) then include = false end
        if include then
            if recentSet then
                include = recentSet[record.id] == true
            else
                if isFavoritesScope then include = favorites[record.id] == true end
                if include and subcategory then include = record.subcategory == subcategory end
                if include and materialTag then include = TableUtil.contains(record.materialTags, materialTag) end
                if include and skillName then include = record.skills[skillName] == true end
                if include and not record.alwaysVisible then
                    include = CatalogIndex.recordVisible(self.player, record, shouldShowAll)
                end
            end
        end
        if include and hasQuery then
            if searchMode == "requirements" then
                include = string.find(CatalogIndex.requirementText(record), query, 1, true) ~= nil
            elseif searchMode == "everything" then
                include = string.find(record.searchText, query, 1, true) ~= nil
                    or string.find(CatalogIndex.requirementText(record), query, 1, true) ~= nil
            else
                include = string.find(record.searchText, query, 1, true) ~= nil
            end
        end
        if include then
            if checkPins and Groups.anyMemberIn(record.definition, pinnedIds) then
                pinnedResult[#pinnedResult + 1] = record.definition
            else
                result[#result + 1] = record.definition
            end
        end
    end
    if #pinnedResult > 0 then
        for resultIndex = 1, #result do
            pinnedResult[#pinnedResult + 1] = result[resultIndex]
        end
        result = pinnedResult
    end
    Profiler.add("catalog.filter", filterStart)
    Profiler.count("catalog.filterRuns")
    return Readiness.filter(self, result)
end

function KBWCatalog:refreshGrid(preserveSelection)
    local refreshStart = Profiler.now()
    local selectedId = self.selected and self.selected.id
    local state
    if preserveSelection and selectedId then
        state = {
            selectedId = selectedId, scope = self.scope, selectedCategories = copyCategorySet(self.selectedCategories),
            search = self.search:getInternalText(), stageIndex = self.stage.selected,
            variantIndex = self.variant.selected, materialIndex = self.material.selected, finishIndex = self.finish.selected,
            subcategory = self.subcategoryValues and self.subcategoryValues[self.subcategoryFilter.selected],
            material = self.materialFilterValues and self.materialFilterValues[self.materialFilter.selected],
            skill = self.skillFilterValues and self.skillFilterValues[self.skillFilter.selected]
        }
    end
    self.grid:setItems(self:filteredDefinitions(), selectedId)
    self.selected = self.grid.items[self.grid.selectedIndex]
    self:refreshSelectionControls()
    if state and self.selected and self.selected.id == selectedId then
        self:restoreState(state)
    else
        Readiness.select(self)
    end
    self:layout()
    Profiler.add("catalog.refreshGrid", refreshStart)
    Profiler.count("catalog.refreshGridRuns")
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
    local materialOptions = baseDefinition and baseDefinition.materialOptions or {}
    local materialRequired = baseDefinition ~= nil and baseDefinition.materialRequired == true and #materialOptions > 0
    self.materialValues = {}
    if not materialRequired then
        self.material:addOption(getText("IGUI_KBW_BaseMaterial"))
        self.materialValues[1] = ""
    end
    for entryIndex = 1, #materialOptions do
        local entry = materialOptions[entryIndex]
        self.material:addOption(I18n.optionName(entry, entry.id))
        self.materialValues[#self.materialValues + 1] = entry.id
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
        self.scopeFav.backgroundColor = Theme.color(Theme.selectedSoft)
        self.scopeFav.borderColor = Theme.color(Theme.accent)
    end
end

function KBWCatalog:onScope(button)
    self.scope = button.internal
    self:updateScopeButtons()
    self:refreshGrid()
end

function KBWCatalog:onCategory(button)
    local category = button.internal
    self.selectedCategories = self.selectedCategories or {}
    if category == "All" then
        self.selectedCategories = {}
    elseif self.workspace then
        self.selectedCategories = { [category] = true }
    elseif isShiftKeyDown() then
        self.selectedCategories[category] = not self.selectedCategories[category] or nil
    else
        self.selectedCategories = { [category] = true }
    end
    self.category = firstSelectedCategory(self)
    uiData(self.player).selectedCategories = copyCategorySet(self.selectedCategories)
    self:refreshFilterOptions()
    self:refreshCompactGroups()
    self:layoutCategoryButtons(self.categoryCatalogWidth or self.grid.width)
    self:refreshGrid()
end

function KBWCatalog:onCategoryPage(button)
    self.categoryOffset = (self.categoryOffset or 1) + button.internal
    self:layoutCategoryButtons(self.categoryCatalogWidth or self.grid.width)
end

function KBWCatalog:onMouseWheel(delta)
    if self.workspace then return false end
    local y = self:getMouseY()
    local categoryY = self.categoryRowY or (contentTop(self) + 48)
    if y >= categoryY - 4 and y <= categoryY + math.max(28, FONT_HGT_SMALL + 10) + 4 then
        self.categoryOffset = (self.categoryOffset or 1) + (delta < 0 and 1 or -1)
        self:layoutCategoryButtons(self.categoryCatalogWidth or self.grid.width)
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
    Readiness.select(self)
    self:layout()
end

---@param definition KBW.BuildableDefinition
function KBWCatalog:onCardActivated(definition)
    self.selected = definition
    self:refreshSelectionControls()
    Readiness.select(self)
    self:onBuild()
end

function KBWCatalog:onClearFilters()
    self.search:setText("")
    self.searchDirtyAt = nil
    self.scope = "All"
    self.selectedCategories = {}
    local data = uiData(self.player)
    data.selectedCategories = {}
    self.showAllTickBox.selected[1] = false
    CatalogVisibility.setShowAll(self.player, false)
    self.readyOnly = false
    Readiness.reset(self)
    Theme.applyActionButton(self.readyButton, true, false)
    self:updateScopeButtons()
    self:refreshFilterOptions()
    self.subcategoryFilter.selected = 1
    self.materialFilter.selected = 1
    self.skillFilter.selected = 1
    self:refreshCompactGroups()
    self:refreshGrid()
end

function KBWCatalog:rawSelectedStage()
    local stages = self.visibleStages or (self.selected and self.selected.stages) or {}
    return stages[self.stage and self.stage.selected or 1]
end

function KBWCatalog:stageCountForSelection()
    local stages = self.visibleStages or (self.selected and self.selected.stages) or {}
    return #stages
end

-- Memoized per (selection, stage, variant, material): render() and the
-- requirement panels call this many times per interaction and per frame, and
-- the variant/material merge deep-copies the definition. The cache is also
-- cleared whenever visibleStages is rebuilt.
function KBWCatalog:effectiveDefinition()
    if not self.selected then return nil end
    local key = tostring(self.selected.id) .. "|" .. tostring(self.stage and self.stage.selected or 1) .. "|"
        .. tostring(self.variant.selected or 1) .. "|" .. tostring(self.material.selected or 1)
    local cached = self.effectiveCache
    if cached and cached.key == key then return cached.value end
    local rawStage = self:rawSelectedStage()
    local baseDefinition = Groups.resolveDefinition(self.selected, rawStage)
    local variantIndex = (self.variant.selected or 1) - 1
    local variant = variantIndex > 0 and baseDefinition.variants and baseDefinition.variants[variantIndex]
    local effective = variant and TableUtil.merge(baseDefinition, variant) or baseDefinition
    local materialId = self:selectedMaterial()
    local material = nil
    if materialId ~= "" then
        local materialOptions = baseDefinition.materialOptions or {}
        for optionIndex = 1, #materialOptions do
            if materialOptions[optionIndex].id == materialId then
                material = materialOptions[optionIndex]
                break
            end
        end
    end
    effective = material and TableUtil.merge(effective, material) or effective
    effective.id = baseDefinition.id
    self.effectiveCache = { key = key, value = effective }
    return effective
end

function KBWCatalog:syncGridSelectionPreview()
    if not self.grid or not self.grid.setSelectionPreview then return end
    self.grid:setSelectionPreview(
        self.selected, self:effectiveDefinition(), self:selectedStage(), self:selectedFinish()
    )
end

function KBWCatalog:refreshSelectionControls()
    self.effectiveCache = nil
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
        self:syncGridSelectionPreview()
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
    self:syncGridSelectionPreview()
    if shouldKeepDrawer then self:updateIngredientDrawerForSelection(true) end
end

function KBWCatalog:refreshStageAndFinish()
    self.effectiveCache = nil
    self.stage:clear()
    local shouldShowAll = CatalogVisibility.shouldShowAll(self.player)
    if Groups.isGroup(self.selected) then
        self.visibleStages = CatalogVisibility.filteredStages(self.player, self.selected, shouldShowAll)
    else
        local effective = self:effectiveDefinition()
        self.visibleStages = CatalogVisibility.filteredStages(self.player, effective or self.selected, shouldShowAll)
    end
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
    self.finish:setVisible(hasEntries)
end

function KBWCatalog:selectedStage()
    if Groups.isGroup(self.selected) then
        local rawStage = self:rawSelectedStage()
        local optionActive = (self.variant.selected or 1) > 1 or self:selectedMaterial() ~= ""
        if not optionActive or not rawStage then return rawStage end
        local effective = self:effectiveDefinition()
        local stages = effective and effective.stages or {}
        local targetId = Groups.resolveStageId(rawStage)
        for stageIndex = 1, #stages do
            if stages[stageIndex].id == targetId then return stages[stageIndex] end
        end
        return stages[1] or rawStage
    end
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
    local values = self.materialValues
    if values then return values[self.material.selected or 1] or "" end
    return ""
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
    if self.requirements and self.requirements.setSelectedRow then
        self.requirements:setSelectedRow(refreshedRow)
    end
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
    self:syncGridSelectionPreview()
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
    self:syncGridSelectionPreview()
    self:layout()
end

function KBWCatalog:onMaterialChanged()
    self:refreshStageAndFinish()
    self:updateIngredientDrawerForSelection(false)
    self:updateActions()
    self:syncGridSelectionPreview()
    self:layout()
end

function KBWCatalog:onFinishChanged()
    -- The finish changes the material list (plaster/paint/paper) and the
    -- preview tile.
    self.requirements:setSelection(self:effectiveDefinition(), self:selectedStage(), self:selectedFinish())
    self:updateIngredientDrawerForSelection(false, true)
    self:updateActions()
    self:syncGridSelectionPreview()
    self:layout()
end

function KBWCatalog:ensureDrawerSpace()
    if self.compact then return end
    local desiredWidth = math.max(self.width, 1250)
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
    persistUiData(self.player)
    self
        :updateFavorite()
    if self.scope == "Favorites" then self:refreshGrid() end
end

---@param definition KBW.BuildableDefinition
function KBWCatalog:onGridFavorite(definition)
    if not definition then return end
    local favorites = uiData(self.player).favorites
    favorites[definition.id] = not favorites[definition.id]
    persistUiData(self.player)
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
    persistUiData(self.player)
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
        selectedCategories = copyCategorySet(self.selectedCategories),
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
    self.selectedCategories = copyCategorySet(state.selectedCategories)
    if not hasSelectedCategories(self) and state.category and state.category ~= "All" then
        self.selectedCategories[state.category] = true
    end
    self.category = firstSelectedCategory(self)
    self.categoryPage = state.categoryPage or self.categoryPage
    self.categoryOffset = state.categoryOffset or state.categoryPage or self.categoryOffset
    self:updateScopeButtons()
    if self.search and state.search then self.search:setText(state.search) end
    self:refreshFilterOptions()
    selectFilterValue(self.subcategoryFilter, self.subcategoryValues, state.subcategory)
    selectFilterValue(self.materialFilter, self.materialFilterValues, state.material)
    selectFilterValue(self.skillFilter, self.skillFilterValues, state.skill)
    self:refreshCompactGroups()
    self:layoutCategoryButtons(self.categoryCatalogWidth or self.grid.width)
    self.grid:setItems(self:filteredDefinitions(), state.selectedId)
    self.selected = self.grid.items[self.grid.selectedIndex]
    self:refreshSelectionControls()
    if self.selected then
        -- A grouped recipe's index changes when callbacks hide earlier stages.
        -- Resolve world picks by their stable member/stage identity first.
        if state.buildableId and state.stageId then
            for index = 1, #(self.visibleStages or {}) do
                local candidate = self.visibleStages[index]
                if Groups.resolveBuildableId(self.selected, candidate) == state.buildableId
                    and Groups.resolveStageId(candidate) == state.stageId then
                    self.stage.selected = index
                    break
                end
            end
            self.effectiveCache = nil
            self:refreshVariantMaterialControls()
        end
        selectComboIndex(self.variant, state.variantIndex)
        selectComboIndex(self.material, state.materialIndex)
        self:refreshStageAndFinish()
        if not state.stageId then selectComboIndex(self.stage, state.stageIndex) end
        self.effectiveCache = nil
        self:refreshFinishOptions()
        selectComboIndex(self.finish, state.finishIndex)
        if state.finishSignature then
            for index = 1, #self.finishValues do
                if WallFinishes.plannedFinishSignature(self.finishValues[index]) == state.finishSignature then
                    self.finish.selected = index
                    break
                end
            end
        end
        self.requirements:setSelection(self:effectiveDefinition(), self:selectedStage(), self:selectedFinish())
        self.accessPanel:setSelection(self:effectiveDefinition(), self:selectedStage())
    end
    self:updateActions()
    self:layout()
end

-- Requirement evaluation does recursive inventory scans, far too heavy to run
-- per frame in prerender. The cache is keyed by selection and the inventory
-- revision, so it only re-evaluates when a container actually changed (with a
-- slow TTL for state the revision cannot see, e.g. daylight or perk levels).
-- onIngredientChoice clears it when manual ingredient choices change.
---@param definition KBW.BuildableDefinition
---@param stage      KBW.BuildStage
function KBWCatalog:cachedSelectionStatus(definition, stage)
    if not definition or not stage then return { ok = false } end
    -- Variant/material indices are part of the key: they swap the effective
    -- stage list without changing definition or stage ids.
    local key = tostring(definition.id) .. "|"
        .. tostring(stage.id) .. "|"
        .. tostring(self.variant.selected or 1) .. "|"
        .. tostring(self.material.selected or 1)
    local now = getTimestampMs()
    local rev = Requirements.inventoryRevision()
    local cache = self.selectionStatusCache
    if cache and cache.key == key then
        local age = now - cache.time
        if (cache.rev == rev and age < 4000) or age < 400 then return cache.status end
    end
    local status = Requirements.evaluate(self.player, definition, stage, nil, self:selectedInputChoices())
    self.selectionStatusCache = { key = key, status = status, time = now, rev = rev }
    local finishOk = hasFinishItem(self.player, self:selectedFinish(), definition, stage)
    Theme.applyActionButton(self.buildButton, Integrity.isAllowed(self.player) and status.ok and finishOk, true)
    return status
end

function KBWCatalog:updateActions()
    local definition, stage = self:effectiveDefinition(), self:selectedStage()
    local status = definition and stage and self:cachedSelectionStatus(definition, stage) or { ok = false }
    local allowed = Integrity.isAllowed(self.player)
    local planningAllowed = KBW.sandboxValue("KnoxBuildworks.EnablePlanningMode", true) == true
    local finishOk = hasFinishItem(self.player, self:selectedFinish(), definition, stage)
    Theme.applyActionButton(self.buildButton, allowed and status.ok and finishOk, true)
    Theme.applyActionButton(self.planButton, planningAllowed and allowed and self.selected ~= nil, false)
    Theme.applyActionButton(self.plansButton, planningAllowed, false)
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
    if KBW.sandboxValue("KnoxBuildworks.EnablePlanningMode", true) ~= true then
        Planner.cancelCursor(self.player)
        if HaloTextHelper and HaloTextHelper.addBadText then
            HaloTextHelper.addBadText(self.player, getText("IGUI_KBW_PlanningDisabled"))
        end
        return
    end
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

function KBWCatalog:onAppearance()
    CatalogSettings.open(self.player, self)
end

function KBWCatalog:onInfo()
    Guide.open(self.player, "welcome")
end

function KBWCatalog:onAppearanceChanged(livePreview, relayout)
    Theme.applyAccessibility(Options)
    self.backgroundColor = Theme.color(Theme.backdrop)
    self.borderColor = Theme.color(Theme.border)
    Theme.applyList(self.categoryList)
    Theme.applyList(self.compactGroups)
    local combos = {
        self.searchMode, self.sortCombo, self.subcategoryFilter, self.materialFilter, self.skillFilter,
        self.stage, self.variant, self.material, self.finish
    }
    for comboIndex = 1, #combos do Theme.applyCombo(combos[comboIndex]) end
    Theme.applyTickBox(self.showAllTickBox)
    local scrollPanels = {
        self.grid, self.requirements, self.accessPanel, self.ingredientDrawer, self.recipeSummary
    }
    for panelIndex = 1, #scrollPanels do
        local panel = scrollPanels[panelIndex]
        if panel then Theme.applyScrollbar(panel.vscroll) end
    end
    if self.ingredientDrawer then
        self.ingredientDrawer.backgroundColor = Theme.color(Theme.backdrop)
        self.ingredientDrawer.borderColor = Theme.color(Theme.border)
    end
    if livePreview then
        if relayout and self.grid then
            self.grid:hideBuildableTooltip()
            self.grid:setCompactMode(self.compact, true)
            self:layout()
            self:ensureResizeWidgets(true)
            self:bringChromeToTop()
        end
        return
    end
    Theme.applyButton(self.sizeButton, false)
    Theme.applyButton(self.appearanceButton, false)
    Theme.applyButton(self.plansButton, false)
    Theme.applyButton(self.clearFiltersButton, false)
    Theme.applyActionButton(self.readyButton, true, self.readyOnly)
    Theme.applyButton(self.categoryPrev, false)
    Theme.applyButton(self.categoryNext, false)
    applyViewButton(self.viewButton, self.viewMode)
    if self.grid then
        self.grid:hideBuildableTooltip()
        self.grid:setCompactMode(self.compact, true)
    end
    self:updateScopeButtons()
    self:updateFavorite()
    self:updateActions()
    self:layout()
    self:ensureResizeWidgets(true)
    self:bringChromeToTop()
end

function KBWCatalog:onToggleSize()
    local data = uiData(self.player)
    self:saveWindowState()
    self.compact = not self.compact
    data.compact = self.compact
    self.minimumWidth = self.compact and COMPACT_MIN_WIDTH or DETAILED_MIN_WIDTH
    local compactMinHeight = compactMinimumHeight()
    local detailedMinHeight = detailedMinimumHeight()
    self.minimumHeight = self.compact and compactMinHeight or detailedMinHeight
    local playerNum = self.player:getPlayerNum()
    local screenWidth = getPlayerScreenWidth(playerNum) - 8
    local screenHeight = getPlayerScreenHeight(playerNum)
    local widthKey = self.compact and "compactWidth" or "detailedWidth"
    local heightKey = self.compact and "compactHeight" or "detailedHeight"
    local xKey = self.compact and "compactX" or "detailedX"
    local yKey = self.compact and "compactY" or "detailedY"
    local defaultWidth = self.compact and math.max(COMPACT_MIN_WIDTH, math.floor(screenWidth * .48))
        or math.max(DETAILED_MIN_WIDTH, math.floor(screenWidth * .62))
    local defaultHeight = self.compact and math.max(compactMinHeight, math.floor(screenHeight * .46))
        or math.max(detailedMinHeight, math.floor(screenHeight * .72))
    local width = math.min(screenWidth, data[widthKey] or defaultWidth)
    local height = math.min(screenHeight - 8, data[heightKey] or defaultHeight)
    width = math.max(self.minimumWidth, width)
    height = math.max(self.minimumHeight, height)
    local screenLeft = getPlayerScreenLeft(playerNum) + 4
    local screenTop = getPlayerScreenTop(playerNum) + 4
    local targetX = data[xKey] or (screenLeft + math.floor((screenWidth - width) / 2))
    local targetY = data[yKey] or (screenTop + math.floor((screenHeight - height) / 2))
    local x, y, newWidth, newHeight = clampedWindowRect(playerNum, targetX, targetY, width, height)
    self:setX(x)
    self:setY(y)
    self:setWidth(newWidth)
    self:setHeight(newHeight)
    -- B42 defers anchored-child movement after a parent resize. Settle that
    -- pass now, then let Knox layout place the resize handles in their final
    -- positions for the newly selected mode.
    if self.recalcSize then self:recalcSize() end
    if self.grid and self.grid.hideBuildableTooltip then self.grid:hideBuildableTooltip() end
    if self.grid then self.grid:setCompactMode(self.compact, true) end
    self:ensureResizeWidgets(true)
    self:positionHeaderActions()
    self.sizeButton:setTitle(self.compact and "^" or "v")
    self:layout()
    self:refreshGrid()
    self:ensureResizeWidgets(true)
    self:bringChromeToTop()
end

function KBWCatalog:positionHeaderActions()
    local top = contentTop(self)
    local controlHeight = math.max(32, FONT_HGT_SMALL + 10)
    self.sizeButton:setX(self.width - 46)
    self.sizeButton:setY(top + 8)
    self.sizeButton:setWidth(34)
    self.sizeButton:setHeight(controlHeight)
    self.appearanceButton:setX(self.width - 84)
    self.appearanceButton:setY(top + 8)
    self.appearanceButton:setWidth(32)
    self.appearanceButton:setHeight(controlHeight)
    self.plansButton:setX(self.width - 170)
    self.plansButton:setY(top + 8)
    self.plansButton:setWidth(80)
    self.plansButton:setHeight(controlHeight)
    if self.compact then
        self.buildButton:setY(top + 8)
        self.planButton:setY(top + 8)
    end
end

-- Debounce window between the last keystroke and the catalogue rebuild.
local SEARCH_DEBOUNCE_MS = 220

function KBWCatalog:update()
    ISPanel.update(self)
    -- Resizing changes the detailed-list width every mouse movement. Hold all
    -- catalogue/index refreshes until release so a background visibility
    -- generation cannot force a full list rebuild during the drag.
    if self.moving or self.isResizingFromWidget then return end
    Readiness.update(self)
    CatalogIndex.pumpVisibility(6)
    if self.lastVisibilityGeneration ~= CatalogIndex.visibilityGeneration then
        self.lastVisibilityGeneration = CatalogIndex.visibilityGeneration
        self:refreshGrid()
        return
    end
    if self.searchDirtyAt and getTimestampMs() - self.searchDirtyAt >= SEARCH_DEBOUNCE_MS then
        self.searchDirtyAt = nil
        self:refreshGrid()
    end
    local now = getTimestampMs()
    if self.lastSafeLayoutCheck and now - self.lastSafeLayoutCheck < 750 then return end;
    self.lastSafeLayoutCheck = now
    if self.workspace then self:updateActions() end
    local x, y, width, height = clampedWindowRect(self.player:getPlayerNum(), self.x, self.y, self.width, self.height)
    if x ~= self.x or y ~= self.y or width ~= self.width or height ~= self.height then
        self:setX(x)
        self:setY(y)
        self:setWidth(width)
        self:setHeight(height)
        self:positionHeaderActions()
        self:layout()
    end
end

function KBWCatalog:saveWindowState()
    local data = uiData(self.player)
    local prefix = self.compact and "compact" or "detailed"
    data[prefix .. "X"] = self.x
    data[prefix .. "Y"] = self.y
    data[prefix .. "Width"] = self.width
    data[prefix .. "Height"] = self.height
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
    if self.grid and self.grid.setLayoutDeferred then self.grid:setLayoutDeferred(true) end
    self:setWidth(newWidth)
    self:setHeight(newHeight)
    self:positionHeaderActions()
    self:layout(true)
end

---@param width  number
---@param height number
function KBWCatalog:resizeFromWidget(width, height)
    local minWidth = self.minimumWidth or DETAILED_MIN_WIDTH
    local minHeight = self.minimumHeight or DETAILED_MIN_HEIGHT
    local newWidth, newHeight = liveResizeSize(
        self.player:getPlayerNum(), self.x, self.y, math.max(minWidth, width), math.max(minHeight, height), minWidth,
        minHeight
    )
    if self.grid and self.grid.setLayoutDeferred then self.grid:setLayoutDeferred(true) end
    self:setWidth(newWidth)
    self:setHeight(newHeight)
    self:positionHeaderActions()
    self:layout(true)
    if self.grid and self.grid.setLayoutDeferred then self.grid:setLayoutDeferred(false) end
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
    -- Apply the final geometry while wrapping is still deferred, then perform
    -- exactly one detailed-list reflow at the released width.
    self:layout(true)
    if self.grid and self.grid.setLayoutDeferred then self.grid:setLayoutDeferred(false) end
    self:ensureResizeWidgets()
    self:bringChromeToTop()
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
        self:layout()
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
        self:layout()
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
        self:ensureResizeWidgets(true)
        self:layout(false)
        self:bringChromeToTop()
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
end

function KBWCatalog:render()
    Workspace.render(self)
    ISCollapsableWindow.render(self)
end

function KBWCatalog:close()
    self:hideMetaTooltip()
    if self.grid and self.grid.hideBuildableTooltip then self.grid:hideBuildableTooltip() end
    CatalogSettings.detach(self)
    self:saveWindowState()
    self:setVisible(false)
    self:removeFromUIManager()
    if KBWCatalog.instance == self then KBWCatalog.instance = nil end
end

---@param key string | number
function KBWCatalog:isKeyConsumed(key)
    return Keyboard and key == Keyboard.KEY_ESCAPE
end

---@param key string | number
function KBWCatalog:onKeyRelease(key)
    if self:isVisible() and self:isKeyConsumed(key) then
        self:close()
        return
    end
end

---@param player IsoPlayer
function KBWCatalog.open(player, restoreState)
    if not KBW.Runtime.loaded then
        local target = player or getPlayer()
        if target and HaloTextHelper and HaloTextHelper.addText then
            HaloTextHelper.addText(target, getText("IGUI_KBW_DefinitionsLoading"))
        end
        if target and KBWCatalog.pendingOpenPlayerNum == nil then
            KBWCatalog.pendingOpenPlayerNum = target:getPlayerNum()
            local Loader = require("KnoxBuildworks/Definitions/Loader")
            Loader.startAsync(function ()
                local playerNum = KBWCatalog.pendingOpenPlayerNum
                KBWCatalog.pendingOpenPlayerNum = nil
                local readyPlayer = playerNum and getSpecificPlayer(playerNum) or nil
                if readyPlayer and not KBWCatalog.instance then KBWCatalog.open(readyPlayer) end
            end)
        end
        return
    end
    if KBWCatalog.instance then KBWCatalog.instance:close() end
    if KBWCatalog.pendingDragReturn then
        KBWCatalog.pendingDragReturn = nil
        Events.OnTick.Remove(KBWCatalog.processDragReturn)
    end
    local openStart = Profiler.now()
    local ui = KBWCatalog:new(player or getPlayer())
    ui:initialise()
    ui:addToUIManager()
    KBWCatalog.instance = ui
    ui:restoreState(restoreState)
    Profiler.add("catalog.open", openStart)
    Profiler.mem("catalog.heapAfterOpen")
    Profiler.report("catalog open")
    return ui
end

function KBWCatalog.processDragReturn()
    Events.OnTick.Remove(KBWCatalog.processDragReturn)
    local state = KBWCatalog.pendingDragReturn
    KBWCatalog.pendingDragReturn = nil
    if not state or KBWCatalog.instance then return end
    local player = getSpecificPlayer(state.playerNum) or getPlayer()
    if player then KBWCatalog.open(player, state) end
end

---@param item      unknown
---@param playerNum number
function KBWCatalog.onSetDragItem(item, playerNum)
    local state = KBWCatalog.dragReturnState
    if not state or item ~= nil then return end
    if playerNum ~= nil and tonumber(playerNum) ~= tonumber(state.playerNum) then return end
    KBWCatalog.dragReturnState = nil
    KBWCatalog.pendingDragReturn = state
    Events.OnTick.Remove(KBWCatalog.processDragReturn)
    Events.OnTick.Add(KBWCatalog.processDragReturn)
end

if not KBWCatalog.eventsInstalled then
    Events.SetDragItem.Add(KBWCatalog.onSetDragItem)
    KBWCatalog.eventsInstalled = true
end

return KBWCatalog
