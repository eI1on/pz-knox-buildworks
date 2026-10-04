require "ISUI/ISButton"
require "ISUI/ISCollapsableWindow"
require "ISUI/ISPanel"

local Blueprints = require("KnoxBuildworks/Planning/Blueprints")
local GhostRenderer = require("KnoxBuildworks/Planning/GhostRenderer")
local IconResolver = require("KnoxBuildworks/UI/IconResolver")
local Theme = require("KnoxBuildworks/UI/Theme")

local PAD = 12
local GAP = 6
local BUTTON_H = 28
local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local MAX_ZONE_TILES = 4096

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function textureScale(texture)
    if not texture then return 1 end
    local width = texture:getWidthOrig()
    local height = texture:getHeightOrig()
    if width == 128 and height == 256 then return 2 end
    if width == 64 and height == 128 then return 1 end
    return math.max(1, Core.getTileScale())
end

local function addLevel(map, level)
    level = math.floor(tonumber(level) or 0)
    map[level] = true
end

local function blueprintLevels(blueprint)
    local found = {}
    addLevel(found, blueprint and blueprint.level or 0)
    local placements = blueprint and blueprint.placements or {}
    for placementIndex = 1, #placements do
        local cells = GhostRenderer.placementCells(placements[placementIndex]) or {}
        if #cells == 0 then addLevel(found, placements[placementIndex].z) end
        for cellIndex = 1, #cells do addLevel(found, cells[cellIndex].z) end
    end
    local rooms = blueprint and blueprint.rooms or {}
    for roomIndex = 1, #rooms do addLevel(found, rooms[roomIndex].z or blueprint.level) end
    if blueprint and blueprint.gatherArea then addLevel(found, blueprint.gatherArea.z or blueprint.level) end
    local levels = {}
    for level in pairs(found) do levels[#levels + 1] = level end
    table.sort(levels)
    return levels
end

local function zoneBounds(zone)
    if not zone then return nil end
    local x1 = tonumber(zone.x1 or zone.x) or 0
    local y1 = tonumber(zone.y1 or zone.y) or 0
    local width = tonumber(zone.w or zone.width)
    local height = tonumber(zone.h or zone.height)
    local x2 = tonumber(zone.x2) or (x1 + math.max(1, width or 1) - 1)
    local y2 = tonumber(zone.y2) or (y1 + math.max(1, height or 1) - 1)
    return math.min(x1, x2), math.min(y1, y2), math.max(x1, x2), math.max(y1, y2)
end

local function includePoint(model, x, y)
    model.minX = math.min(model.minX, x)
    model.minY = math.min(model.minY, y)
    model.maxX = math.max(model.maxX, x)
    model.maxY = math.max(model.maxY, y)
end

local function addSprite(model, cell)
    local texture = cell.sprite and IconResolver.textureForSpriteName(cell.sprite) or nil
    local record = { texture = texture, gridX = cell.x, gridY = cell.y, gridZ = cell.z }
    if texture then
        local assetScale = textureScale(texture)
        local widthOrig = texture:getWidthOrig()
        local heightOrig = texture:getHeightOrig()
        record.x = (cell.x - cell.y) * 32 - widthOrig / assetScale / 2 + texture:getOffsetX() / assetScale
        record.y = (cell.x + cell.y) * 16 - (heightOrig - 16 * assetScale) / assetScale
            + texture:getOffsetY() / assetScale
        record.width = texture:getWidth() / assetScale
        record.height = texture:getHeight() / assetScale
    end
    model.sprites[#model.sprites + 1] = record
end

local function buildModel(blueprint, level)
    local model = {
        level = level, sprites = {}, cells = {}, rooms = {}, supply = nil,
        minX = math.huge, minY = math.huge, maxX = -math.huge, maxY = -math.huge
    }
    local placements = blueprint and blueprint.placements or {}
    for placementIndex = 1, #placements do
        local cells = GhostRenderer.placementCells(placements[placementIndex]) or {}
        for cellIndex = 1, #cells do
            local cell = cells[cellIndex]
            if math.floor(tonumber(cell.z) or 0) == level then
                includePoint(model, cell.x, cell.y)
                model.cells[#model.cells + 1] = cell
                addSprite(model, cell)
            end
        end
    end
    local rooms = blueprint and blueprint.rooms or {}
    for roomIndex = 1, #rooms do
        local room = rooms[roomIndex]
        if math.floor(tonumber(room.z or blueprint.level) or 0) == level then
            local x1, y1, x2, y2 = zoneBounds(room)
            model.rooms[#model.rooms + 1] = {
                x1 = x1, y1 = y1, x2 = x2, y2 = y2,
                color = room.color or { r = 0.20, g = 0.62, b = 1.00, a = 0.26 },
                name = room.name or room.type
            }
            includePoint(model, x1, y1)
            includePoint(model, x2, y2)
        end
    end
    local area = blueprint and blueprint.gatherArea or nil
    if area and math.floor(tonumber(area.z or blueprint.level) or 0) == level then
        local x1, y1, x2, y2 = zoneBounds(area)
        model.supply = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
        includePoint(model, x1, y1)
        includePoint(model, x2, y2)
    end
    if model.minX == math.huge then
        local origin = blueprint and (blueprint.origin or blueprint.anchor) or nil
        local x = origin and tonumber(origin.x) or 0
        local y = origin and tonumber(origin.y) or 0
        includePoint(model, x, y)
    end
    table.sort(model.sprites, function(a, b)
        if a.gridZ ~= b.gridZ then return a.gridZ < b.gridZ end
        local aDepth = a.gridX + a.gridY
        local bDepth = b.gridX + b.gridY
        if aDepth ~= bDepth then return aDepth < bDepth end
        return a.gridX < b.gridX
    end)
    return model
end

---@class KBWBlueprintPreviewCanvas: ISPanel
KBWBlueprintPreviewCanvas = ISPanel:derive("KBWBlueprintPreviewCanvas")

function KBWBlueprintPreviewCanvas:new(owner, x, y, width, height)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.owner = owner
    o.background = true
    o.backgroundColor = { r = 0.018, g = 0.020, b = 0.019, a = 0.96 }
    o.borderColor = Theme.color(Theme.borderSoft)
    return o
end

local function isoPoint(x, y)
    return (x - y) * 32, (x + y) * 16
end

local function isoBounds(model)
    local minX, minY = math.huge, math.huge
    local maxX, maxY = -math.huge, -math.huge
    local function includeTile(x, y)
        local sx, sy = isoPoint(x, y)
        minX = math.min(minX, sx - 32)
        minY = math.min(minY, sy)
        maxX = math.max(maxX, sx + 32)
        maxY = math.max(maxY, sy + 32)
    end
    includeTile(model.minX, model.minY)
    includeTile(model.minX, model.maxY)
    includeTile(model.maxX, model.minY)
    includeTile(model.maxX, model.maxY)
    for spriteIndex = 1, #model.sprites do
        local sprite = model.sprites[spriteIndex]
        if sprite.texture then
            minX = math.min(minX, sprite.x)
            minY = math.min(minY, sprite.y)
            maxX = math.max(maxX, sprite.x + sprite.width)
            maxY = math.max(maxY, sprite.y + sprite.height)
        end
    end
    return { x = minX, y = minY, width = math.max(1, maxX - minX), height = math.max(1, maxY - minY) }
end

function KBWBlueprintPreviewCanvas:drawDiamond(texture, x, y, scale, color, alpha)
    local sx, sy = isoPoint(x, y)
    local drawX = self.previewOriginX + sx * scale - 32 * scale
    local drawY = self.previewOriginY + sy * scale
    if texture then
        self:drawTextureScaled(texture, drawX, drawY, 64 * scale, 32 * scale, alpha, color.r, color.g, color.b)
    else
        self:drawRect(drawX, drawY + 8 * scale, 64 * scale, 16 * scale, alpha, color.r, color.g, color.b)
    end
end

local function eachZoneTile(zone, callback, borderOnly)
    local width = zone.x2 - zone.x1 + 1
    local height = zone.y2 - zone.y1 + 1
    local area = width * height
    borderOnly = borderOnly or area > MAX_ZONE_TILES
    if borderOnly then
        for x = zone.x1, zone.x2 do
            callback(x, zone.y1)
            if zone.y2 ~= zone.y1 then callback(x, zone.y2) end
        end
        for y = zone.y1 + 1, zone.y2 - 1 do
            callback(zone.x1, y)
            if zone.x2 ~= zone.x1 then callback(zone.x2, y) end
        end
        return
    end
    for y = zone.y1, zone.y2 do
        for x = zone.x1, zone.x2 do
            callback(x, y)
        end
    end
end

function KBWBlueprintPreviewCanvas:drawIso(model)
    local bounds = isoBounds(model)
    local availableW = math.max(1, self.width - 48)
    local availableH = math.max(1, self.height - 48)
    local scale = math.min(availableW / bounds.width, availableH / bounds.height) * self.owner.zoom
    scale = clamp(scale, 0.08, 4)
    self.previewOriginX = (self.width - bounds.width * scale) / 2 - bounds.x * scale + self.owner.panX
    self.previewOriginY = (self.height - bounds.height * scale) / 2 - bounds.y * scale + self.owner.panY
    local floorTexture = self.owner.floorTexture
    if self.owner.showGrid then
        local spanX = model.maxX - model.minX + 1
        local spanY = model.maxY - model.minY + 1
        local area = spanX * spanY
        local step = math.max(1, math.ceil(math.sqrt(area / 1800)))
        for y = model.minY, model.maxY, step do
            for x = model.minX, model.maxX, step do
                self:drawDiamond(floorTexture, x, y, scale, Theme.borderSoft, 0.16)
            end
        end
    end
    if model.supply then
        eachZoneTile(model.supply, function(x, y)
            self:drawDiamond(floorTexture, x, y, scale, GhostRenderer.GATHER_COLOR, 0.38)
        end, true)
    end
    for roomIndex = 1, #model.rooms do
        local room = model.rooms[roomIndex]
        eachZoneTile(room, function(x, y)
            self:drawDiamond(floorTexture, x, y, scale, room.color, 0.48)
        end, false)
    end
    for spriteIndex = 1, #model.sprites do
        local sprite = model.sprites[spriteIndex]
        if sprite.texture then
            self:drawTextureScaled(
                sprite.texture, self.previewOriginX + sprite.x * scale, self.previewOriginY + sprite.y * scale,
                sprite.width * scale, sprite.height * scale, 1, 1, 1, 1
            )
        elseif sprite.gridX then
            self:drawDiamond(floorTexture, sprite.gridX, sprite.gridY, scale, Theme.accent, 0.72)
        end
    end
end

function KBWBlueprintPreviewCanvas:drawTopDown(model)
    local spanX = math.max(1, model.maxX - model.minX + 1)
    local spanY = math.max(1, model.maxY - model.minY + 1)
    local scale = math.min((self.width - 48) / spanX, (self.height - 48) / spanY) * self.owner.zoom
    scale = clamp(scale, 3, 96)
    local originX = (self.width - spanX * scale) / 2 + self.owner.panX
    local originY = (self.height - spanY * scale) / 2 + self.owner.panY
    local function rectFor(zone)
        return originX + (zone.x1 - model.minX) * scale, originY + (zone.y1 - model.minY) * scale,
            (zone.x2 - zone.x1 + 1) * scale, (zone.y2 - zone.y1 + 1) * scale
    end
    if self.owner.showGrid then
        local gridStep = math.max(1, math.ceil(math.max(spanX, spanY) / 80))
        for x = 0, spanX, gridStep do
            self:drawRect(originX + x * scale, originY, 1, spanY * scale, 0.38, Theme.borderSoft.r, Theme.borderSoft.g, Theme.borderSoft.b)
        end
        for y = 0, spanY, gridStep do
            self:drawRect(originX, originY + y * scale, spanX * scale, 1, 0.38, Theme.borderSoft.r, Theme.borderSoft.g, Theme.borderSoft.b)
        end
    end
    if model.supply then
        local x, y, width, height = rectFor(model.supply)
        local color = GhostRenderer.GATHER_COLOR
        self:drawRect(x, y, width, height, 0.20, color.r, color.g, color.b)
        self:drawRectBorder(x, y, width, height, 0.86, color.r, color.g, color.b)
    end
    for roomIndex = 1, #model.rooms do
        local room = model.rooms[roomIndex]
        local x, y, width, height = rectFor(room)
        self:drawRect(x, y, width, height, 0.42, room.color.r, room.color.g, room.color.b)
        self:drawRectBorder(x, y, width, height, 0.95, room.color.r, room.color.g, room.color.b)
    end
    for cellIndex = 1, #model.cells do
        local cell = model.cells[cellIndex]
        local x = originX + (cell.x - model.minX) * scale
        local y = originY + (cell.y - model.minY) * scale
        self:drawRect(x + 2, y + 2, math.max(2, scale - 4), math.max(2, scale - 4), 0.82,
            Theme.accent.r, Theme.accent.g, Theme.accent.b)
        self:drawRectBorder(x, y, scale, scale, 0.92, Theme.text.r, Theme.text.g, Theme.text.b)
    end
end

function KBWBlueprintPreviewCanvas:prerender()
    ISPanel.prerender(self)
    self:setStencilRect(1, 1, math.max(1, self.width - 2), math.max(1, self.height - 2))
    local model = self.owner:model()
    if self.owner.viewMode == "top" then self:drawTopDown(model) else self:drawIso(model) end
    self:clearStencilRect()
end

function KBWBlueprintPreviewCanvas:onMouseWheel(delta)
    self.owner:setZoom(self.owner.zoom - delta * 0.1)
    return true
end

function KBWBlueprintPreviewCanvas:onMouseDown(x, y)
    self.dragging = true
    self.dragMouseX = getMouseX()
    self.dragMouseY = getMouseY()
    self.dragPanX = self.owner.panX
    self.dragPanY = self.owner.panY
    self:setCapture(true)
    return true
end

function KBWBlueprintPreviewCanvas:onMouseMove(dx, dy)
    if not self.dragging then return false end
    self.owner.panX = self.dragPanX + getMouseX() - self.dragMouseX
    self.owner.panY = self.dragPanY + getMouseY() - self.dragMouseY
    return true
end

function KBWBlueprintPreviewCanvas:onMouseMoveOutside(dx, dy)
    return self:onMouseMove(dx, dy)
end

function KBWBlueprintPreviewCanvas:onMouseUp(x, y)
    self.dragging = false
    self:setCapture(false)
    return true
end

function KBWBlueprintPreviewCanvas:onMouseUpOutside(x, y)
    return self:onMouseUp(x, y)
end

---@class KBWBlueprintPreview: ISCollapsableWindow
KBWBlueprintPreview = ISCollapsableWindow:derive("KBWBlueprintPreview")
KBWBlueprintPreview.instance = nil

local function makeButton(owner, x, width, title, callback)
    local button = ISButton:new(x, 0, width, BUTTON_H, title, owner, callback)
    button:initialise()
    Theme.applyButton(button, false)
    owner:addChild(button)
    return button
end

function KBWBlueprintPreview:new(owner, player, blueprint)
    local screenW = getCore():getScreenWidth()
    local screenH = getCore():getScreenHeight()
    local width = math.min(900, screenW - 80)
    local height = math.min(680, screenH - 80)
    local o = ISCollapsableWindow:new(math.floor((screenW - width) / 2), math.floor((screenH - height) / 2), width, height)
    setmetatable(o, self)
    self.__index = self
    o.owner = owner
    o.player = player
    o.blueprintId = blueprint and blueprint.id or nil
    o.title = getText("IGUI_KBW_BlueprintPreview")
    o.backgroundColor = Theme.color(Theme.backdrop)
    o.borderColor = Theme.color(Theme.border)
    o.resizable = true
    o.minimumWidth = 620
    o.minimumHeight = 440
    o.moveWithMouse = true
    o.viewMode = "iso"
    o.showGrid = true
    o.zoom = 1
    o.panX = 0
    o.panY = 0
    o.levels = blueprintLevels(blueprint)
    o.levelIndex = 1
    local wantedLevel = math.floor(tonumber(blueprint and blueprint.level) or 0)
    for levelIndex = 1, #o.levels do
        if o.levels[levelIndex] == wantedLevel then o.levelIndex = levelIndex end
    end
    o.floorTexture = getTexture((Core.getTileScale() == 2) and "media/ui/FloorTileCursor2x.png" or "media/ui/FloorTileCursor.png")
    o:setWantKeyEvents(true)
    return o
end

function KBWBlueprintPreview:blueprint()
    return Blueprints.get(self.player, self.blueprintId)
end

function KBWBlueprintPreview:level()
    return self.levels[self.levelIndex] or 0
end

function KBWBlueprintPreview:model()
    local blueprint = self:blueprint()
    local revision = blueprint and tostring(blueprint.updated) or "missing"
    local key = revision .. "|" .. tostring(self:level())
    if self.modelKey ~= key then
        self.modelKey = key
        self.cachedModel = buildModel(blueprint, self:level())
    end
    return self.cachedModel
end

function KBWBlueprintPreview:createChildren()
    ISCollapsableWindow.createChildren(self)
    self.viewButton = makeButton(self, PAD, 112, "", self.onToggleView)
    self.gridButton = makeButton(self, PAD + 118, 96, "", self.onToggleGrid)
    self.levelDownButton = makeButton(self, PAD + 220, 38, getText("IGUI_KBW_FloorDown"), self.onLevelDown)
    self.levelUpButton = makeButton(self, PAD + 264, 38, getText("IGUI_KBW_FloorUp"), self.onLevelUp)
    self.zoomOutButton = makeButton(self, 0, 38, "-", self.onZoomOut)
    self.fitButton = makeButton(self, 0, 58, getText("IGUI_KBW_FitPreview"), self.onFit)
    self.zoomInButton = makeButton(self, 0, 38, "+", self.onZoomIn)
    self.doneButton = makeButton(self, 0, 78, getText("IGUI_KBW_Close"), self.close)
    self.canvas = KBWBlueprintPreviewCanvas:new(self, PAD, 0, self.width - PAD * 2, self.height - 120)
    self.canvas:initialise()
    self.canvas:instantiate()
    self:addChild(self.canvas)
    self:syncControls()
    self:layout()
end

function KBWBlueprintPreview:layout()
    local top = self:titleBarHeight() + PAD
    self.viewButton:setY(top)
    self.gridButton:setY(top)
    self.levelDownButton:setY(top)
    self.levelUpButton:setY(top)
    local right = self.width - PAD
    self.doneButton:setX(right - self.doneButton.width)
    self.doneButton:setY(top)
    right = self.doneButton.x - GAP
    self.zoomInButton:setX(right - self.zoomInButton.width)
    self.zoomInButton:setY(top)
    right = self.zoomInButton.x - GAP
    self.fitButton:setX(right - self.fitButton.width)
    self.fitButton:setY(top)
    right = self.fitButton.x - GAP
    self.zoomOutButton:setX(right - self.zoomOutButton.width)
    self.zoomOutButton:setY(top)
    local canvasY = top + BUTTON_H + 28
    self.canvas:setX(PAD)
    self.canvas:setY(canvasY)
    self.canvas:setWidth(self.width - PAD * 2)
    self.canvas:setHeight(math.max(160, self.height - canvasY - 34))
    self._layoutWidth = self.width
    self._layoutHeight = self.height
end

function KBWBlueprintPreview:syncControls()
    self.viewButton:setTitle(getText(self.viewMode == "iso" and "IGUI_KBW_ViewIsometric" or "IGUI_KBW_ViewTopDown"))
    self.gridButton:setTitle(getText(self.showGrid and "IGUI_KBW_GridOn" or "IGUI_KBW_GridOff"))
    Theme.applyButton(self.viewButton, self.viewMode == "top")
    Theme.applyButton(self.gridButton, self.showGrid)
    Theme.setButtonEnabled(self.levelDownButton, self.levelIndex > 1)
    Theme.setButtonEnabled(self.levelUpButton, self.levelIndex < #self.levels)
end

function KBWBlueprintPreview:setZoom(value)
    self.zoom = clamp(tonumber(value) or 1, 0.45, 3)
end

function KBWBlueprintPreview:onToggleView()
    self.viewMode = self.viewMode == "iso" and "top" or "iso"
    self.panX, self.panY = 0, 0
    self:syncControls()
end

function KBWBlueprintPreview:onToggleGrid()
    self.showGrid = not self.showGrid
    self:syncControls()
end

function KBWBlueprintPreview:onLevelDown()
    if self.levelIndex > 1 then
        self.levelIndex = self.levelIndex - 1
        self.panX, self.panY = 0, 0
        self:syncControls()
    end
end

function KBWBlueprintPreview:onLevelUp()
    if self.levelIndex < #self.levels then
        self.levelIndex = self.levelIndex + 1
        self.panX, self.panY = 0, 0
        self:syncControls()
    end
end

function KBWBlueprintPreview:onZoomOut()
    self:setZoom(self.zoom - 0.15)
end

function KBWBlueprintPreview:onZoomIn()
    self:setZoom(self.zoom + 0.15)
end

function KBWBlueprintPreview:onFit()
    self.zoom = 1
    self.panX, self.panY = 0, 0
end

function KBWBlueprintPreview:prerender()
    if self.width ~= self._layoutWidth or self.height ~= self._layoutHeight then self:layout() end
    ISCollapsableWindow.prerender(self)
    local model = self:model()
    local textY = self:titleBarHeight() + PAD + math.floor((BUTTON_H - FONT_HGT_SMALL) / 2)
    local levelText = getText("IGUI_KBW_BlueprintLevel", tostring(self:level()))
    self:drawText(levelText, self.levelUpButton.x + self.levelUpButton.width + 8, textY,
        Theme.text.r, Theme.text.g, Theme.text.b, 1, UIFont.Small)
    local status = getText("IGUI_KBW_BlueprintPreviewSummary", tostring(#model.cells), tostring(#model.rooms),
        tostring(model.supply and 1 or 0))
    self:drawText(status, PAD, self.canvas.y - 21, Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 1, UIFont.Small)
    self:drawTextRight(getText("IGUI_KBW_BlueprintPreviewHint"), self.width - PAD, self.canvas.y - 21,
        Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 1, UIFont.Small)
end

function KBWBlueprintPreview:isKeyConsumed(key)
    return Keyboard and key == Keyboard.KEY_ESCAPE
end

function KBWBlueprintPreview:onKeyRelease(key)
    if self:isKeyConsumed(key) then self:close() end
end

function KBWBlueprintPreview:close()
    ISCollapsableWindow.close(self)
    self:removeFromUIManager()
    if self.owner and self.owner.previewWindow == self then self.owner.previewWindow = nil end
    if KBWBlueprintPreview.instance == self then KBWBlueprintPreview.instance = nil end
end

function KBWBlueprintPreview.open(owner, player, blueprint)
    if not blueprint then return nil end
    if KBWBlueprintPreview.instance then KBWBlueprintPreview.instance:close() end
    local window = KBWBlueprintPreview:new(owner, player, blueprint)
    window:initialise()
    window:addToUIManager()
    window:bringToTop()
    KBWBlueprintPreview.instance = window
    return window
end

return KBWBlueprintPreview
