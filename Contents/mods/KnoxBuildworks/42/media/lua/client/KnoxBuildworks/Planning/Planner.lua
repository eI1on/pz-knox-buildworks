---Planner provides the Knox Buildworks blueprint planning layer.
local Blueprints = require("KnoxBuildworks/Planning/Blueprints")
local GhostRenderer = require("KnoxBuildworks/Planning/GhostRenderer")
local PlanCursor = require("KnoxBuildworks/Planning/PlanCursor")
local RoomCursor = require("KnoxBuildworks/Planning/RoomCursor")
local EraseCursor = require("KnoxBuildworks/Planning/EraseCursor")
local BuildPlanCursor = require("KnoxBuildworks/Planning/BuildPlanCursor")
local GatherAreaCursor = require("KnoxBuildworks/Planning/GatherAreaCursor")
local MoveBlueprintCursor = require("KnoxBuildworks/Planning/MoveBlueprintCursor")
local SelectCursor = require("KnoxBuildworks/Planning/SelectCursor")
local PipetteCursor = require("KnoxBuildworks/Planning/PipetteCursor")
local CaptureCursor = require("KnoxBuildworks/Planning/CaptureCursor")

---@class KBW.PlannerModule
---@type KBW.PlannerModule
local Planner = { highlightPlacementId = nil, highlightRoomId = nil, selection = nil }
Planner.SELECT_COLOR = { r = 0.35, g = 0.80, b = 1.00, a = 0.55 }

local function activateCursor(player, cursor)
    local playerNum = player:getPlayerNum()
    getCell():setDrag(cursor, playerNum)
    if JoypadState and JoypadState.players and JoypadState.players[playerNum + 1] and setJoypadFocus then
        -- The world cursor receives D-pad/A/B only after the catalogue gives
        -- up controller focus. Mouse users can still click its panels.
        setJoypadFocus(playerNum, nil)
    end
    return cursor
end

---@param player IsoPlayer
---@param buildableId string
---@param stageId string|nil
---@param variantId string|nil
---@param materialId string|nil
---@param direction KBW.Direction
---@param finish KBW.WallFinish|nil
function Planner.begin(player, buildableId, stageId, variantId, materialId, direction, finish)
    local cursor = PlanCursor.new(player, buildableId, stageId, variantId, materialId, direction or 1, finish)
    return activateCursor(player, cursor)
end

---@param player IsoPlayer
---@param blueprintId string
---@param onRoomAdded function|nil
function Planner.beginRoom(player, blueprintId, roomTemplate, onRoomAdded)
    local cursor = RoomCursor.new(player, blueprintId, roomTemplate, onRoomAdded)
    return activateCursor(player, cursor)
end

---@param player IsoPlayer
---@param blueprintId string
---@param onErased function|nil
---@param mode string|nil
function Planner.beginErase(player, blueprintId, onErased, mode)
    local cursor = EraseCursor.new(player, blueprintId, onErased, mode)
    return activateCursor(player, cursor)
end

---@param player IsoPlayer
---@param blueprintId string
---@param onBuilt function|nil
function Planner.beginBuildTool(player, blueprintId, onBuilt)
    local cursor = BuildPlanCursor.new(player, blueprintId, onBuilt)
    return activateCursor(player, cursor)
end

---@param player IsoPlayer
---@param blueprintId string
---@param onAreaSet function|nil
function Planner.beginGatherArea(player, blueprintId, onAreaSet)
    local cursor = GatherAreaCursor.new(player, blueprintId, onAreaSet)
    return activateCursor(player, cursor)
end

---@param player IsoPlayer
---@param blueprintId string
---@param onMoved function|nil
function Planner.beginMoveBlueprint(player, blueprintId, onMoved)
    local cursor = MoveBlueprintCursor.new(player, blueprintId, onMoved)
    return activateCursor(player, cursor)
end

---@param player IsoPlayer
---@param blueprintId string
---@param onSelected function|nil
function Planner.beginSelect(player, blueprintId, onSelected)
    local cursor = SelectCursor.new(player, blueprintId, onSelected)
    return activateCursor(player, cursor)
end

---Pick a planned ghost or a built piece and plan more of exactly that piece.
---@param player IsoPlayer
---@param blueprintId string
---@param onPicked function(choice)
function Planner.beginPipette(player, blueprintId, onPicked)
    local cursor = PipetteCursor.new(player, blueprintId, onPicked)
    return activateCursor(player, cursor)
end

---@param player IsoPlayer
---@param onCapture function(area) receives a BuildingCapture area
function Planner.beginCapture(player, onCapture)
    local cursor = CaptureCursor.new(player, onCapture)
    return activateCursor(player, cursor)
end

---The current selection of planned ghosts ({ blueprintId, z, ghosts = {id=true} })
---drawn on top of the plan; nil clears it.
function Planner.setSelection(selection)
    Planner.selection = selection
end

---@param player IsoPlayer
function Planner.cancelCursor(player)
    local playerNum = player and player:getPlayerNum() or 0
    local drag = getCell():getDrag(playerNum)
    if drag
        and (drag.Type == "KBWPlanCursor" or drag.Type == "KBWRoomCursor" or drag.Type == "KBWEraseCursor"
            or drag.Type == "KBWBuildPlanCursor" or drag.Type == "KBWGatherAreaCursor"
            or drag.Type == "KBWMoveBlueprintCursor" or drag.Type == "KBWSelectCursor" or drag.Type == "KBWPipetteCursor"
            or drag.Type == "KBWCaptureCursor") then
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
function Planner.renderWorldPreview()
    -- IngameState selects the current IsoPlayer before each split-screen
    -- OnPostRender call. Kahlua cannot index IsoCamera.frameState's Java field.
    local player = getPlayer()
    if not player then return end
    local playerIndex = player:getPlayerNum()
    GhostRenderer.applyPreferences(player)
    local activeBlueprint = Blueprints.active(player)
    if not activeBlueprint then
        Planner.highlightPlacementId = nil
        Planner.highlightRoomId = nil
        GhostRenderer.flushWorldAreaHighlights(playerIndex)
        return
    end
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
    Planner.renderSelection(activeBlueprint, playerIndex)
    GhostRenderer.flushWorldAreaHighlights(playerIndex)
end

function Planner.renderSelection(blueprint, playerIndex)
    local selection = Planner.selection
    if not selection or selection.blueprintId ~= blueprint.id then return end
    if (selection.ghostCount or 0) > 0 then
        local placements = blueprint.placements or {}
        for index = 1, #placements do
            local placement = placements[index]
            if selection.ghosts[placement.id] then
                GhostRenderer.renderPlacementLayerAll(placement, Planner.SELECT_COLOR)
            end
        end
    end
end

Events.OnPostRender.Add(Planner.renderWorldPreview)

return Planner
