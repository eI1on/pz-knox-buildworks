---SelectCursor: drag a box on the planning level to select planned ghosts,
---for deleting several at once. A ghost is selected when any of its cells
---falls inside the box. Hold Shift to add to the current selection.
local Blueprints = require("KnoxBuildworks/Planning/Blueprints")
local GhostRenderer = require("KnoxBuildworks/Planning/GhostRenderer")
local PlanCursor = require("KnoxBuildworks/Planning/PlanCursor")

local SelectCursor = {}

-- Largest box side, in tiles.
SelectCursor.MAX_SIDE = 48
SelectCursor.COLOR = { r = 0.35, g = 0.80, b = 1.00, a = 0.30 }

local function floorInt(value)
    return math.floor(tonumber(value) or 0)
end

local function clampBox(anchorX, anchorY, x, y)
    local max = SelectCursor.MAX_SIDE - 1
    if x > anchorX + max then x = anchorX + max elseif x < anchorX - max then x = anchorX - max end
    if y > anchorY + max then y = anchorY + max elseif y < anchorY - max then y = anchorY - max end
    return math.min(anchorX, x), math.min(anchorY, y), math.max(anchorX, x), math.max(anchorY, y)
end

---Ghost ids of a blueprint with a cell inside the box on level z.
function SelectCursor.ghostsIn(blueprint, minX, minY, maxX, maxY, z)
    local ids, count = {}, 0
    local placements = blueprint and blueprint.placements or {}
    for index = 1, #placements do
        local placement = placements[index]
        local cells = Blueprints.placementCellsOf(placement)
        for c = 1, #cells do
            local cell = cells[c]
            if cell.z == z and cell.x >= minX and cell.x <= maxX and cell.y >= minY and cell.y <= maxY then
                ids[placement.id] = true
                count = count + 1
                break
            end
        end
    end
    return ids, count
end

local function defineClass()
    KBWSelectCursor = ISBuildingObject:derive("KBWSelectCursor")

    function KBWSelectCursor:new(player, blueprintId, onSelected)
        local o = {}
        setmetatable(o, self)
        self.__index = self
        o:init()
        o.character = player
        o.player = player:getPlayerNum()
        o.onSelected = onSelected
        o.skipBuildAction = true
        o.dragNilAfterPlace = false
        local blueprint = Blueprints.get(player, blueprintId) or Blueprints.activeOrCreate(player)
        o.blueprintId = blueprint.id
        o.planZ = floorInt(blueprint.level ~= nil and blueprint.level or player:getZ())
        return o
    end

    function KBWSelectCursor:walkTo(x, y, z) return true end
    function KBWSelectCursor:haveMaterial(square) return true end
    function KBWSelectCursor:rotateMouse(x, y) end
    function KBWSelectCursor:rotateKey(key) end
    function KBWSelectCursor:getSprite() return nil end
    function KBWSelectCursor:isValid(square) return self.currentX ~= nil end

    function KBWSelectCursor:render(x, y, z, square)
        local blueprint = Blueprints.get(self.character, self.blueprintId)
        if blueprint and blueprint.level ~= nil then self.planZ = floorInt(blueprint.level) end
        self.currentX, self.currentY = PlanCursor.pickTileAt(self.player, self.planZ)
        if self.isLeftDown then
            if self.anchorX == nil then self.anchorX, self.anchorY = self.currentX, self.currentY end
        elseif not self.build then
            self.anchorX, self.anchorY = nil, nil
        end
        self.canBeBuild = true
        local ax, ay = self.anchorX or self.currentX, self.anchorY or self.currentY
        local minX, minY, maxX, maxY = clampBox(ax, ay, self.currentX, self.currentY)
        GhostRenderer.renderRoomRect(minX, minY, maxX, maxY, self.planZ, SelectCursor.COLOR, self.player)
    end

    function KBWSelectCursor:create(x, y, z, north, sprite)
        local ax, ay = self.anchorX or self.currentX, self.anchorY or self.currentY
        if ax == nil or self.currentX == nil then return end
        local minX, minY, maxX, maxY = clampBox(ax, ay, self.currentX, self.currentY)
        self.anchorX, self.anchorY = nil, nil
        local blueprint = Blueprints.get(self.character, self.blueprintId)
        local selection = { blueprintId = self.blueprintId, z = self.planZ, ghosts = {}, ghostCount = 0 }
        selection.ghosts, selection.ghostCount = SelectCursor.ghostsIn(blueprint, minX, minY, maxX, maxY, self.planZ)
        if self.onSelected then self.onSelected(selection, isShiftKeyDown and isShiftKeyDown()) end
    end
end

Events.OnGameStart.Add(defineClass)

---@param player IsoPlayer
---@param blueprintId string
---@param onSelected function(selection, additive)
function SelectCursor.new(player, blueprintId, onSelected)
    return KBWSelectCursor:new(player, blueprintId, onSelected)
end

return SelectCursor
