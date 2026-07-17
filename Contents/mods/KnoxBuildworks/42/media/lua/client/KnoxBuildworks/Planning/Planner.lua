---Planner provides the Knox Buildworks blueprint planning layer.
local Blueprints = require("KnoxBuildworks/Planning/Blueprints")
local GhostRenderer = require("KnoxBuildworks/Planning/GhostRenderer")
local PlanCursor = require("KnoxBuildworks/Planning/PlanCursor")
local RoomCursor = require("KnoxBuildworks/Planning/RoomCursor")
local EraseCursor = require("KnoxBuildworks/Planning/EraseCursor")
local BuildPlanCursor = require("KnoxBuildworks/Planning/BuildPlanCursor")
local GatherAreaCursor = require("KnoxBuildworks/Planning/GatherAreaCursor")
local MoveBlueprintCursor = require("KnoxBuildworks/Planning/MoveBlueprintCursor")

---@class KBW.PlannerModule
---@type KBW.PlannerModule
local Planner = { highlightPlacementId = nil, highlightRoomId = nil }

---@param player IsoPlayer
---@param buildableId string
---@param stageId string|nil
---@param variantId string|nil
---@param materialId string|nil
---@param direction KBW.Direction
---@param finish KBW.WallFinish|nil
function Planner.begin(player, buildableId, stageId, variantId, materialId, direction, finish)
    local cursor = PlanCursor.new(player, buildableId, stageId, variantId, materialId, direction or 1, finish)
    getCell():setDrag(cursor, player:getPlayerNum())
    return cursor
end

---@param player IsoPlayer
---@param blueprintId string
---@param onRoomAdded function|nil
function Planner.beginRoom(player, blueprintId, roomTemplate, onRoomAdded)
    local cursor = RoomCursor.new(player, blueprintId, roomTemplate, onRoomAdded)
    getCell():setDrag(cursor, player:getPlayerNum())
    return cursor
end

---@param player IsoPlayer
---@param blueprintId string
---@param onErased function|nil
---@param mode string|nil
function Planner.beginErase(player, blueprintId, onErased, mode)
    local cursor = EraseCursor.new(player, blueprintId, onErased, mode)
    getCell():setDrag(cursor, player:getPlayerNum())
    return cursor
end

---@param player IsoPlayer
---@param blueprintId string
---@param onBuilt function|nil
function Planner.beginBuildTool(player, blueprintId, onBuilt)
    local cursor = BuildPlanCursor.new(player, blueprintId, onBuilt)
    getCell():setDrag(cursor, player:getPlayerNum())
    return cursor
end

---@param player IsoPlayer
---@param blueprintId string
---@param onAreaSet function|nil
function Planner.beginGatherArea(player, blueprintId, onAreaSet)
    local cursor = GatherAreaCursor.new(player, blueprintId, onAreaSet)
    getCell():setDrag(cursor, player:getPlayerNum())
    return cursor
end

---@param player IsoPlayer
---@param blueprintId string
---@param onMoved function|nil
function Planner.beginMoveBlueprint(player, blueprintId, onMoved)
    local cursor = MoveBlueprintCursor.new(player, blueprintId, onMoved)
    getCell():setDrag(cursor, player:getPlayerNum())
    return cursor
end

---@param player IsoPlayer
function Planner.cancelCursor(player)
    local playerNum = player and player:getPlayerNum() or 0
    local drag = getCell():getDrag(playerNum)
    if drag
        and (drag.Type == "KBWPlanCursor" or drag.Type == "KBWRoomCursor" or drag.Type == "KBWEraseCursor"
            or drag.Type == "KBWBuildPlanCursor" or drag.Type == "KBWGatherAreaCursor"
            or drag.Type == "KBWMoveBlueprintCursor") then
        getCell():setDrag(nil, playerNum)
    end
end

---@param placementId string
function Planner.setHighlight(placementId)
    Planner.highlightPlacementId = placementId
end

---@param roomId string
function Planner.setHighlightRoom(roomId)
    Planner.highlightRoomId = roomId
end

-- Ghost drawing follows the player's active blueprint; when no blueprint is
-- active (Hide ghosts in planning mode) nothing is drawn.
---@param playerIndex integer
---@param x number
---@param y number
---@param z number
---@param square IsoGridSquare|nil
function Planner.renderWorldPreview(playerIndex, x, y, z, square)
    local player = getSpecificPlayer(playerIndex or 0) or getPlayer()
    if not player then return end
    local activeBlueprint = Blueprints.active(player)
    if not activeBlueprint then return end
    local activeLevel = tonumber(activeBlueprint.level) or math.floor(player:getZ())
    GhostRenderer.renderBlueprint(
        activeBlueprint, activeLevel, Planner.highlightPlacementId, Planner.highlightRoomId, playerIndex
    )
    -- Outline the blueprint's allowed square (range) once it is anchored.
    if activeBlueprint.anchored and activeBlueprint.anchor then
        local radius = tonumber(activeBlueprint.radius) or 200
        GhostRenderer.renderRectBorder(
            activeBlueprint.anchor.x - radius, activeBlueprint.anchor.y - radius, activeBlueprint.anchor.x + radius,
            activeBlueprint.anchor.y + radius, activeLevel, GhostRenderer.RANGE_COLOR, playerIndex
        )
    end
end

Events.RenderOpaqueObjectsInWorld.Add(Planner.renderWorldPreview)

return Planner
