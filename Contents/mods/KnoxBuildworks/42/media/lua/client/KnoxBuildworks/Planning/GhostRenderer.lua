---GhostRenderer provides the Knox Buildworks blueprint planning layer.
local Registry = require("KnoxBuildworks/Definitions/Registry")
local Matrix = require("KnoxBuildworks/Geometry/Matrix")
local Blueprints = require("KnoxBuildworks/Planning/Blueprints")
local WallFinishes = require("KnoxBuildworks/Validation/WallFinishes")
local EntityCompat = require("KnoxBuildworks/Entity/EntityCompat")
local RoomShape = require("KnoxBuildworks/Planning/RoomShape")

---@class KBW.GhostRendererModule
---@type KBW.GhostRendererModule
local GhostRenderer = {}

GhostRenderer.PLAN_COLOR = { r = 0.55, g = 0.78, b = 1.00, a = 0.30 }
GhostRenderer.PLAN_COLOR_DIM = { r = 0.36, g = 0.49, b = 0.62, a = 0.18 }
GhostRenderer.CONFLICT_COLOR = { r = 0.80, g = 0.25, b = 0.20, a = 0.34 }
GhostRenderer.HIGHLIGHT_COLOR = { r = 0.95, g = 0.85, b = 0.35, a = 0.42 }
GhostRenderer.GATHER_COLOR = { r = 0.38, g = 0.86, b = 0.56, a = 0.22 }
GhostRenderer.RANGE_COLOR = { r = 0.90, g = 0.95, b = 1.00, a = 0.16 }
GhostRenderer.opacity = 0.5
GhostRenderer.view = { style = "ghost", levels = "adjacent", roofs = true, rooms = true, walls = true }
local OPACITIES = {0.15, 0.35, 0.65, 1.0}

-- Restore the rendering player's preferences even before the planning UI opens.
-- Each split-screen world pass supplies its own player; no settings leak between saves.
function GhostRenderer.applyPreferences(player)
    local data = player and player:getModData().KBW_UI or {}
    data = type(data) == "table" and data or {}
    local saved = type(data.ghostView) == "table" and data.ghostView or {}
    local view = GhostRenderer.view
    view.style = (saved.style == "texture" or saved.style == "solid") and saved.style or "ghost"
    view.levels = (saved.levels == "current" or saved.levels == "below" or saved.levels == "all") and saved.levels or "adjacent"
    view.roofs, view.rooms, view.walls = saved.roofs ~= false, saved.rooms ~= false, saved.walls ~= false
    GhostRenderer.opacity = OPACITIES[data.ghostOpacityIndex] or OPACITIES[2]
end

local spriteCache = {}
local areaQueue = {}
local roomOutlineCache = setmetatable({}, {__mode = "k"})
local queueRoomOutline
local cellCache = {}
local cellCacheCount = 0
local CELL_CACHE_LIMIT = 4096
local orderCaches = {}

---@param value unknown
function GhostRenderer.setOpacity(value)
    value = tonumber(value) or 0.14
    if value < 0.04 then value = 0.04 end
    if value > 1 then value = 1 end
    GhostRenderer.opacity = value
end

local function colorAlpha(color, fallback)
    local opacity = GhostRenderer.opacity or 0.35
    local requested = color and color.a or fallback or 0.14
    local alpha = requested * (opacity / 0.35)
    if alpha < 0.015 then return 0.015 end
    if alpha > 0.55 then return 0.55 end
    return alpha
end

local function roomAlpha(color)
    return colorAlpha({ a = math.max(tonumber(color and color.a) or 0.26, 0.22) }, 0.22)
end

---@param activeLevel number|nil
function GhostRenderer.levelAlpha(cellZ, activeLevel, base)
    if activeLevel == nil then return base end
    local mode = GhostRenderer.view.levels
    if mode == "all" then return base end
    if mode == "below" then return (cellZ or 0) <= activeLevel and base or 0 end
    if mode == "current" then return (cellZ or 0) == activeLevel and base or 0 end
    local diff = math.abs((cellZ or 0) - activeLevel)
    if diff == 0 then return base end
    if diff == 1 then return base * 0.35 end
    return 0
end

---@param spriteName string|nil
function GhostRenderer.getSprite(spriteName)
    if not spriteName then return nil end
    local sprite = spriteCache[spriteName]
    if sprite then return sprite end
    sprite = getSprite(spriteName)
    if not sprite then
        sprite = IsoSprite.new()
        sprite:LoadSingleTexture(spriteName)
    end
    spriteCache[spriteName] = sprite
    return sprite
end

function GhostRenderer.getFloorCursorSprite()
    if not GhostRenderer.floorCursorSprite then
        local spriteName = (Core.getTileScale() == 2) and "media/ui/FloorTileCursor2x.png"
            or "media/ui/FloorTileCursor.png"
        GhostRenderer.floorCursorSprite = IsoSprite.new()
        GhostRenderer.floorCursorSprite:LoadSingleTexture(spriteName)
    end
    return GhostRenderer.floorCursorSprite
end

local function drawCell(sprite, x, y, z, color, alpha)
    if not sprite or alpha <= 0 then return end
    sprite:RenderGhostTileColor(x, y, z, color.r or 1, color.g or 1, color.b or 1, alpha)
end

local function queueAreaHighlight(playerIndex, x1, y1, x2, y2, z, color, alpha)
    if alpha <= 0 then return end
    areaQueue[#areaQueue + 1] = {
        playerIndex = playerIndex or 0,
        x1 = x1,
        y1 = y1,
        x2 = x2,
        y2 = y2,
        z = tonumber(z) or 0,
        r = color.r or 0.25,
        g = color.g or 0.65,
        b = color.b or 0.95,
        a = alpha
    }
end

-- Implemented below, after visibleTileBounds. The B42 area-highlight FBO
-- retains entries only for the UI render timestamp; when the world callback
-- is skipped over a panel, its colours blink off. World ghost tiles have no
-- such lifetime and can be painted from the guaranteed post-render pass.

local function finishSignature(finish)
    if type(finish) ~= "table" then return "" end
    return tostring(finish.actionType) .. ":" .. tostring(finish.plaster) .. ":" .. tostring(finish.paintType) .. ":"
        .. tostring(finish.wallpaperType) .. ":" .. tostring(finish.sign)
end

local function placementSignature(placement)
    return tostring(placement.id) .. "|" .. tostring(placement.buildableId) .. "|" .. tostring(placement.stageId) .. "|"
        .. tostring(placement.variantId) .. "|" .. tostring(placement.materialId) .. "|" .. tostring(placement.x) .. "|"
        .. tostring(placement.y) .. "|" .. tostring(placement.z) .. "|" .. tostring(placement.direction) .. "|"
        .. finishSignature(placement.finish) .. "|"
        .. tostring(placement.finishTarget and placement.finishTarget.wallType or "")
end

local function wallCoveringAction(definition, stage)
    if not definition or ((definition.placement or {}).kind ~= "wallCovering") then return nil end
    local compat = EntityCompat.metadata(stage)
    local config = compat.wallCoveringConfig or {}
    return config.type or (definition.placement or {}).wallCoveringType
end

function GhostRenderer.clearCache()
    cellCache = {}
    cellCacheCount = 0
    orderCaches = {}
    roomOutlineCache = setmetatable({}, {__mode = "k"})
end

local function cacheCells(key, entry)
    if cellCacheCount >= CELL_CACHE_LIMIT then GhostRenderer.clearCache() end
    if cellCache[key] == nil then cellCacheCount = cellCacheCount + 1 end
    cellCache[key] = entry
end

-- Stored placements cache by id and revalidate by identity: edits replace the
-- placement table wholesale and blueprint moves shift coordinates in place,
-- so comparing the reference plus coordinates catches every change without
-- rebuilding a signature string per placement per frame. Cursor candidates
-- have no id (fresh tables every frame) and fall back to the signature key.
local function cacheKeyFor(placement)
    if placement.id then return placement.id, true end
    return placementSignature(placement), false
end

local function cachedCellsFor(placement, key, byId)
    local cached = cellCache[key]
    if not cached then return nil end
    if not byId then return cached end
    if cached.placement == placement and cached.x == placement.x and cached.y == placement.y and cached.z == placement.z
        and cached.direction == placement.direction and cached.finish == placement.finish
        and cached.finishTarget == placement.finishTarget then
        return cached
    end
    return nil
end

---@param placement KBW.BlueprintPlacement
function GhostRenderer.placementCells(placement)
    local key, byId = cacheKeyFor(placement)
    local cached = cachedCellsFor(placement, key, byId)
    if cached then return cached.cells end
    local entry = {
        placement = byId and placement or nil,
        x = placement.x,
        y = placement.y,
        z = placement.z,
        direction = placement.direction,
        finish = placement.finish,
        finishTarget = placement.finishTarget
    }
    local definition, stage = Blueprints.resolvePlacement(placement)
    if not stage then
        cacheCells(key, entry)
        return nil
    end
    local cells = Matrix.getFaceCells(stage, tonumber(placement.direction) or 1)
    if not cells then
        local sprite = Matrix.getFaceSprite(stage, tonumber(placement.direction) or 1)
        cells = { { dx = 0, dy = 0, dz = 0, sprite = sprite, blocks = true } }
    end
    -- Ghosts preview the finished face when the placement carries a wall
    -- finish (plastered/painted/papered).
    local direction = tonumber(placement.direction) or 1
    local north = direction == 2 or direction == 4
    local coveringAction = wallCoveringAction(definition, stage)
    local targetWallType = placement.finishTarget and placement.finishTarget.wallType or nil
    local out = {}
    for cellIndex = 1, #cells do
        local cell = cells[cellIndex]
        local finishSprite, tint = nil, nil
        if cell.sprite and WallFinishes.isWallFinish(placement.finish) then
            finishSprite = WallFinishes.previewSprite(placement.finish, north, definition, stage, cell.sprite)
            tint = WallFinishes.previewTint(placement.finish, definition, stage, cell.sprite)
        elseif cell.sprite and coveringAction and targetWallType then
            finishSprite = WallFinishes.spriteForWallType(coveringAction, placement.finish, north, targetWallType)
        end
        out[#out + 1] = {
            x = (placement.x or 0) + (cell.dx or 0),
            y = (placement.y or 0) + (cell.dy or 0),
            z = (placement.z or 0) + (cell.dz or 0),
            sprite = (cell.sprite and finishSprite) or cell.sprite,
            tint = tint,
            kind = cell.kind or (stage.placement or {}).kind or ((definition or {}).placement or {}).kind,
            blocks = cell.blocks
        }
    end
    entry.cells = out
    cacheCells(key, entry)
    return out
end

---@param placement KBW.BlueprintPlacement
---@param activeLevel number|nil
function GhostRenderer.renderPlacement(placement, activeLevel, color)
    local cells = GhostRenderer.placementCells(placement)
    if not cells then return end
    color = color or GhostRenderer.PLAN_COLOR
    local normal = color == GhostRenderer.PLAN_COLOR
    local baseAlpha = normal and GhostRenderer.opacity or colorAlpha(color, 0.25)
    if normal and GhostRenderer.view.style ~= "ghost" then
        color = { r = 1, g = 1, b = 1 }
        if GhostRenderer.view.style == "solid" then baseAlpha = 1 end
    end
    for cellIndex = 1, #cells do
        local cell = cells[cellIndex]
        local alpha = GhostRenderer.levelAlpha(cell.z, activeLevel, baseAlpha)
        if cell.sprite then
            -- A tint-painted piece shows its paint colour unless it is flagged
            -- (conflict, selection), which keeps that colour.
            local cellColor = normal and cell.tint or color
            drawCell(GhostRenderer.getSprite(cell.sprite), cell.x, cell.y, cell.z, cellColor, alpha)
        elseif cell.blocks then
            drawCell(GhostRenderer.getFloorCursorSprite(), cell.x, cell.y, cell.z, color, alpha * 0.7)
        end
    end
end

---@param placement KBW.BlueprintPlacement
function GhostRenderer.renderPlacementLayerAll(placement, color)
    GhostRenderer.renderPlacement(placement, nil, color)
end

---@param room KBW.BlueprintRoom
---@param activeLevel number|nil
---@param playerIndex number
function GhostRenderer.renderRoom(room, defaultZ, activeLevel, highlightRoomId, playerIndex)
    local roomZ = tonumber(room.z)
    if roomZ == nil then roomZ = tonumber(defaultZ) or 0 end
    local color = room.color or { r = 0.20, g = 0.62, b = 1.00, a = 0.26 }
    local highlighted = highlightRoomId and room.id == highlightRoomId
    local base = roomAlpha(color)
    if highlighted then base = math.min(0.34, base + 0.08) end
    local alpha = GhostRenderer.levelAlpha(roomZ, activeLevel, base)
    if alpha <= 0 then return end
    queueRoomOutline(playerIndex, room, roomZ, color, alpha, 0, 0)
end

-- Draw layer inside one square, back to front: wall structure (frames, walls),
-- then what covers a wall (finishes, overlays such as trims and lower panels),
-- then pieces hung against a wall, then free-standing pieces. Overlays used to
-- tie with free-standing pieces and fell back to placement order, so a trim on
-- a wall could draw over a chair standing in front of it (captured buildings
-- list pieces in scan order).
local function cellLayer(cellKind, placementInfo)
    if cellKind == "wall" then return 1 end
    if cellKind == "wallCovering" or cellKind == "overlay" then return 2 end
    if placementInfo.needToBeAgainstWall == true then return 3 end
    return 4
end

-- Sort expanded cells, not anchors: stairs and multi-tile pieces cross both
-- diagonals and storeys. Keep floors first on each level, then use isometric
-- depth with deterministic ties. World coordinates must never be packed into
-- a weighted scalar (large X/Y values previously overwhelmed the Z term).
local function sortedCells(blueprint)
    local placements = blueprint.placements or {}
    for index = #orderCaches, 1, -1 do
        local cached = orderCaches[index]
        if cached.source == placements then
            if cached.updated == blueprint.updated and cached.count == #placements then return cached.order end
            table.remove(orderCaches, index)
        end
    end
    local order = {}
    for index = 1, #placements do
        local placement = placements[index]
        local definition = Registry:get(placement.buildableId)
        local placementInfo = (definition and definition.placement) or {}
        local kind = placementInfo.kind
        local cells = GhostRenderer.placementCells(placement) or {}
        for cellIndex = 1, #cells do
            local cellKind = cells[cellIndex].kind or kind
            order[#order + 1] = { placement = placement, cell = cells[cellIndex],
                floor = cellKind == "floor", wall = cellKind == "wall" or cellKind == "wallCovering",
                layer = cellLayer(cellKind, placementInfo),
                roof = definition and definition.category == "Roofing", sequence = #order + 1 }
        end
    end
    table.sort(order, function(a, b)
        local ac, bc = a.cell, b.cell
        if ac.z ~= bc.z then return ac.z < bc.z end
        if a.floor ~= b.floor then return a.floor end
        local ad, bd = ac.x + ac.y, bc.x + bc.y
        if ad ~= bd then return ad < bd end
        if ac.y ~= bc.y then return ac.y < bc.y end
        if a.layer ~= b.layer then return a.layer < b.layer end
        return a.sequence < b.sequence
    end)
    if #orderCaches >= 8 then table.remove(orderCaches, 1) end
    orderCaches[#orderCaches + 1] = { source = placements, updated = blueprint.updated, count = #placements, order = order }
    return order
end

-- World-tile bounds of the visible screen (plus margin for multi-tile
-- footprints and z offsets), so far-away ghosts of a large blueprint cost
-- nothing at all.
local CULL_MARGIN = 12

local function finiteWorldValue(value)
    return type(value) == "number" and value == value and math.abs(value) < 10000000
end

local function fallbackTileBounds(playerIndex)
    local player = getSpecificPlayer(playerIndex or 0) or getPlayer()
    local centerX = player and tonumber(player:getX()) or 0
    local centerY = player and tonumber(player:getY()) or 0
    local radius = 96
    return centerX - radius, centerY - radius, centerX + radius, centerY + radius
end

local function visibleTileBounds(playerIndex, z)
    playerIndex = playerIndex or 0
    local left = getPlayerScreenLeft(playerIndex)
    local top = getPlayerScreenTop(playerIndex)
    local right = left + getPlayerScreenWidth(playerIndex)
    local bottom = top + getPlayerScreenHeight(playerIndex)
    z = tonumber(z) or 0
    local x1 = screenToIsoX(playerIndex, left, top, z)
    local y1 = screenToIsoY(playerIndex, left, top, z)
    local x2 = screenToIsoX(playerIndex, right, top, z)
    local y2 = screenToIsoY(playerIndex, right, top, z)
    local x3 = screenToIsoX(playerIndex, left, bottom, z)
    local y3 = screenToIsoY(playerIndex, left, bottom, z)
    local x4 = screenToIsoX(playerIndex, right, bottom, z)
    local y4 = screenToIsoY(playerIndex, right, bottom, z)
    if not finiteWorldValue(x1) or not finiteWorldValue(y1) or not finiteWorldValue(x2)
        or not finiteWorldValue(y2) or not finiteWorldValue(x3) or not finiteWorldValue(y3)
        or not finiteWorldValue(x4) or not finiteWorldValue(y4) then
        return fallbackTileBounds(playerIndex)
    end
    local minX = math.min(x1, x2, x3, x4) - CULL_MARGIN
    local minY = math.min(y1, y2, y3, y4) - CULL_MARGIN
    local maxX = math.max(x1, x2, x3, x4) + CULL_MARGIN
    local maxY = math.max(y1, y2, y3, y4) + CULL_MARGIN
    local player = getSpecificPlayer(playerIndex or 0) or getPlayer()
    local playerX = player and tonumber(player:getX()) or nil
    local playerY = player and tonumber(player:getY()) or nil
    if maxX <= minX or maxY <= minY or maxX - minX > 1000 or maxY - minY > 1000
        or (playerX and playerY
            and (playerX < minX - CULL_MARGIN or playerX > maxX + CULL_MARGIN
                or playerY < minY - CULL_MARGIN or playerY > maxY + CULL_MARGIN)) then
        return fallbackTileBounds(playerIndex)
    end
    return minX, minY, maxX, maxY
end

queueRoomOutline = function(playerIndex, room, z, color, alpha, dx, dy)
    if alpha <= 0 then return end
    local cached = roomOutlineCache[room]
    if not cached or cached.x ~= room.x or cached.y ~= room.y or cached.rects ~= room.rects
        or cached.w ~= room.w or cached.h ~= room.h then
        cached = {x = room.x, y = room.y, rects = room.rects, w = room.w, h = room.h,
            lines = RoomShape.perimeter(room)}
        roomOutlineCache[room] = cached
    end
    areaQueue[#areaQueue + 1] = {
        playerIndex = playerIndex or 0, z = z, lines = cached.lines, dx = dx or 0, dy = dy or 0,
        r = color.r or 0.25, g = color.g or 0.65, b = color.b or 0.95, a = alpha
    }
end

function GhostRenderer.flushWorldAreaHighlights(playerIndex, throughZ)
    local pending = areaQueue
    areaQueue = {}
    if #pending == 0 then return end
    local bounds = {}
    for areaIndex = 1, #pending do
        local area = pending[areaIndex]
        if (playerIndex ~= nil and area.playerIndex ~= playerIndex)
            or (throughZ ~= nil and area.z > throughZ) then
            areaQueue[#areaQueue + 1] = area
        else
            if not bounds[area.playerIndex] then bounds[area.playerIndex] = {} end
            local playerBounds = bounds[area.playerIndex]
            if not playerBounds[area.z] then playerBounds[area.z] = {visibleTileBounds(area.playerIndex, area.z)} end
            local minX,minY,maxX,maxY = unpack(playerBounds[area.z])
            if area.lines then
                for lineIndex = 1, #area.lines do
                    local line = area.lines[lineIndex]
                    local dx, dy = area.dx, area.dy
                    local x1, y1, x2, y2 = line[1] + dx, line[2] + dy, line[3] + dx, line[4] + dy
                    if math.max(x1, x2) >= minX and math.min(x1, x2) <= maxX
                        and math.max(y1, y2) >= minY and math.min(y1, y2) <= maxY then
                        if renderIsoLine then
                            renderIsoLine(x1, y1, area.z + 0.02, x2, y2, area.z + 0.02,
                                2, area.r, area.g, area.b, area.a)
                        elseif renderLine then
                            renderLine(x1, y1, area.z + 0.02, x2, y2, area.z + 0.02,
                                area.r, area.g, area.b, area.a)
                        end
                    end
                end
            else
                local sprite = GhostRenderer.getFloorCursorSprite()
                local x1 = math.max(area.x1, math.floor(minX))
                local y1 = math.max(area.y1, math.floor(minY))
                local x2 = math.min(area.x2 - 1, math.ceil(maxX))
                local y2 = math.min(area.y2 - 1, math.ceil(maxY))
                local width,height = area.x2-area.x1,area.y2-area.y1
                local borderOnly = width*height > 64
                for y = y1,y2 do
                    for x = x1,x2 do
                        local border = x==area.x1 or x==area.x2-1 or y==area.y1 or y==area.y2-1
                        if not borderOnly or border then
                            local alpha = border and area.a or area.a*0.4
                            drawCell(sprite,x,y,area.z,area,alpha)
                        end
                    end
                end
            end
        end
    end
end

---@param blueprint KBW.Blueprint
---@param activeLevel number|nil
---@param playerIndex number
function GhostRenderer.renderBlueprint(blueprint, activeLevel, highlightId, highlightRoomId, playerIndex, previewColor)
    local area = blueprint.gatherArea
    if area then
        queueAreaHighlight(
            playerIndex, area.x1 or 0, area.y1 or 0, (area.x2 or 0) + 1, (area.y2 or 0) + 1, area.z or 0,
            GhostRenderer.GATHER_COLOR, colorAlpha(GhostRenderer.GATHER_COLOR, 0.13)
        )
    end
    local rooms = blueprint.rooms or {}
    for roomIndex = 1, GhostRenderer.view.rooms and #rooms or 0 do
        GhostRenderer.renderRoom(rooms[roomIndex], blueprint.level, activeLevel, highlightRoomId, playerIndex)
    end
    local order = sortedCells(blueprint)
    local bounds = {}
    local lastZ
    for index = 1, #order do
        local entry = order[index]
        local cell, placement = entry.cell, entry.placement
        if cell.z ~= lastZ then
            -- Interleave room floors with objects by storey: upper room
            -- colours must not end up underneath lower-storey ghosts.
            GhostRenderer.flushWorldAreaHighlights(playerIndex, cell.z)
            lastZ = cell.z
        end
        if not bounds[cell.z] then bounds[cell.z] = { visibleTileBounds(playerIndex, cell.z) } end
        local minX, minY, maxX, maxY = unpack(bounds[cell.z])
        if (previewColor or GhostRenderer.view.roofs or not entry.roof) and (previewColor or GhostRenderer.view.walls or not entry.wall)
            and cell.x >= minX and cell.x <= maxX and cell.y >= minY and cell.y <= maxY then
            local color, base = GhostRenderer.PLAN_COLOR, GhostRenderer.opacity
            if previewColor or highlightId and placement.id == highlightId then
                color = previewColor or GhostRenderer.HIGHLIGHT_COLOR
                base = colorAlpha(color, 0.25)
            elseif GhostRenderer.view.style ~= "ghost" then
                color = {r = 1, g = 1, b = 1}
                if GhostRenderer.view.style == "solid" then base = 1 end
            end
            local alpha = GhostRenderer.levelAlpha(cell.z, activeLevel, base)
            if cell.sprite then
                drawCell(GhostRenderer.getSprite(cell.sprite), cell.x, cell.y, cell.z, color, alpha)
            elseif cell.blocks then
                drawCell(GhostRenderer.getFloorCursorSprite(), cell.x, cell.y, cell.z, color, alpha * 0.7)
            end
        end
    end
    GhostRenderer.flushWorldAreaHighlights(playerIndex)
end

-- Preview of a whole blueprint shifted by (dx, dy); the move-blueprint cursor
-- uses this so the player sees where everything lands before committing.
---@param blueprint KBW.Blueprint
---@param dx number
---@param dy number
---@param playerIndex number
function GhostRenderer.renderBlueprintOffset(blueprint, dx, dy, playerIndex)
    local color = GhostRenderer.HIGHLIGHT_COLOR
    local alpha = colorAlpha(color, 0.30)
    local order, bounds = sortedCells(blueprint), {}
    for index = 1, #order do
        local cell = order[index].cell
        if not bounds[cell.z] then bounds[cell.z] = {visibleTileBounds(playerIndex, cell.z)} end
        local minX,minY,maxX,maxY = unpack(bounds[cell.z])
        local x,y = cell.x+dx,cell.y+dy
        if x >= minX and x <= maxX and y >= minY and y <= maxY then
            if cell.sprite then
                drawCell(GhostRenderer.getSprite(cell.sprite), x, y, cell.z, color, alpha)
            elseif cell.blocks then
                drawCell(GhostRenderer.getFloorCursorSprite(), x, y, cell.z, color, alpha*0.7)
            end
        end
    end
    local rooms = blueprint.rooms or {}
    for roomIndex = 1, #rooms do
        local room = rooms[roomIndex]
        local roomZ = tonumber(room.z) or tonumber(blueprint.level) or 0
        local roomColor = room.color or { r = 0.20, g = 0.62, b = 1.00, a = 0.26 }
        queueRoomOutline(playerIndex, room, roomZ, roomColor, roomAlpha(roomColor), dx, dy)
    end
end

function GhostRenderer.renderRoomRect(x1, y1, x2, y2, z, color, playerIndex)
    local left, top = math.min(x1, x2), math.min(y1, y2)
    local room = {x = left, y = top, w = math.abs(x2 - x1) + 1, h = math.abs(y2 - y1) + 1}
    color = color or GhostRenderer.HIGHLIGHT_COLOR
    queueRoomOutline(playerIndex, room, z, color, roomAlpha(color), 0, 0)
end

function GhostRenderer.renderOutline(lines, z, color, playerIndex)
    if not lines or #lines == 0 then return end
    color = color or GhostRenderer.HIGHLIGHT_COLOR
    areaQueue[#areaQueue + 1] = {
        playerIndex = playerIndex or 0, z = tonumber(z) or 0, lines = lines, dx = 0, dy = 0,
        r = color.r or 0.9, g = color.g or 0.85, b = color.b or 0.35,
        a = colorAlpha(color, 0.35)
    }
end

---@param z number
---@param playerIndex number
function GhostRenderer.renderRect(x1, y1, x2, y2, z, color, playerIndex)
    local minX, maxX = math.min(x1, x2), math.max(x1, x2)
    local minY, maxY = math.min(y1, y2), math.max(y1, y2)
    color = color or { r = 0.20, g = 0.62, b = 1.00, a = 0.26 }
    local alpha = colorAlpha(color, 0.12)
    queueAreaHighlight(playerIndex, minX, minY, maxX + 1, maxY + 1, z, color, alpha)
end

---@param z number
---@param playerIndex number
function GhostRenderer.renderRectBorder(x1, y1, x2, y2, z, color, playerIndex)
    local minX, maxX = math.min(x1, x2), math.max(x1, x2)
    local minY, maxY = math.min(y1, y2), math.max(y1, y2)
    color = color or GhostRenderer.RANGE_COLOR
    local alpha = colorAlpha(color, 0.14)
    local right = maxX + 1
    local bottom = maxY + 1
    queueAreaHighlight(playerIndex, minX, minY, right, minY + 1, z, color, alpha)
    if bottom > minY + 1 then
        queueAreaHighlight(playerIndex, minX, bottom - 1, right, bottom, z, color, alpha)
    end
    if bottom > minY + 2 then
        queueAreaHighlight(playerIndex, minX, minY + 1, minX + 1, bottom - 1, z, color, alpha)
        if right > minX + 1 then
            queueAreaHighlight(playerIndex, right - 1, minY + 1, right, bottom - 1, z, color, alpha)
        end
    end
end

---@param x number
---@param y number
---@param z number
---@param playerIndex number
function GhostRenderer.renderTileHighlight(x, y, z, color, alpha, playerIndex)
    color = color or GhostRenderer.PLAN_COLOR_DIM
    queueAreaHighlight(
        playerIndex, x, y, x + 1, y + 1, z, color,
        colorAlpha({ r = color.r, g = color.g, b = color.b, a = alpha or 0.24 }, alpha or 0.24)
    )
end

return GhostRenderer
