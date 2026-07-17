---Placement provides the Knox Buildworks construction validation layer.
---@class KBW.PlacementModule
---@type KBW.PlacementModule
local Placement = {}
local LuaCallback = require("KnoxBuildworks/Util/LuaCallback")
local I18n = require("KnoxBuildworks/I18n")
local EntityCompat = require("KnoxBuildworks/Entity/EntityCompat")
local StageConfig = require("KnoxBuildworks/Definitions/StageConfig")

-- Placement.validate returns short internal reason strings (stable for logs
-- and server checks). reasonText maps them to player-facing translations,
-- falling back to the raw reason for anything unmapped.
local REASON_KEYS = {
    ["missing square or player"] = "IGUI_KBW_Reason_MissingSquare",
    ["previous stage missing"] = "IGUI_KBW_Reason_PreviousStageMissing",
    ["previous stage direction mismatch"] = "IGUI_KBW_Reason_PreviousStageDirection",
    ["square already occupied"] = "IGUI_KBW_Reason_SquareOccupied",
    ["wall required"] = "IGUI_KBW_Reason_WallRequired",
    ["stairs below"] = "IGUI_KBW_Reason_StairsBelow",
    ["farming plot blocked"] = "IGUI_KBW_Reason_FarmingPlot",
    ["no adjacent floor support"] = "IGUI_KBW_Reason_NoFloorSupport",
    ["floor required"] = "IGUI_KBW_Reason_FloorRequired",
    ["missing footprint square"] = "IGUI_KBW_Reason_MissingFootprint",
    ["floor already built"] = "IGUI_KBW_Reason_FloorAlreadyBuilt",
    ["garage door blocked"] = "IGUI_KBW_Reason_GarageDoor",
    ["vehicle blocked"] = "IGUI_KBW_Reason_VehicleBlocked",
    ["stairs blocked"] = "IGUI_KBW_Reason_StairsBlocked",
    ["midair footprint blocked"] = "IGUI_KBW_Reason_MidairBlocked",
    ["stack blocked"] = "IGUI_KBW_Reason_StackBlocked",
    ["solid placement blocked"] = "IGUI_KBW_Reason_SolidBlocked",
    ["wall already blocked"] = "IGUI_KBW_Reason_WallAlreadyBlocked",
    ["multi-tile object crossing north wall"] = "IGUI_KBW_Reason_CrossingWall",
    ["window frame required"] = "IGUI_KBW_Reason_WindowFrameRequired",
    ["door needs floor"] = "IGUI_KBW_Reason_DoorNeedsFloor",
    ["door already built"] = "IGUI_KBW_Reason_DoorAlreadyBuilt",
    ["door frame required"] = "IGUI_KBW_Reason_DoorFrameRequired"
}

---@param reason string|nil
function Placement.reasonText(reason)
    reason = tostring(reason or "")
    local key = REASON_KEYS[reason]
    if key then return I18n.text(key, reason) end
    return reason
end

local function objectSpriteBlocksWall(sprite, north)
    if not sprite then return false end
    local props = sprite:getProperties()
    if north then
        return props:has(IsoFlagType.collideN) or props:has(IsoFlagType.WindowN)
            or props:has(IsoFlagType.DoorWallN) or props:has(IsoFlagType.HoppableN)
    end
    return props:has(IsoFlagType.collideW) or props:has(IsoFlagType.WindowW)
        or props:has(IsoFlagType.DoorWallW) or props:has(IsoFlagType.HoppableW)
end

local function spriteProps(spriteName)
    local sprite = spriteName and getSprite(spriteName)
    return sprite, sprite and sprite:getProperties() or nil
end

local function isWallSprite(sprite)
    return sprite and sprite:getType() == IsoObjectType.wall
end

local function hasWallSupport(square, north, isPole)
    local hasFloor = square:hasFloor(north)
    if isPole and not hasFloor then
        local poleSq = getSquare(square:getX() - 1, square:getY() - 1, square:getZ())
        if poleSq then hasFloor = poleSq:hasFloor() end
        if not hasFloor then
            poleSq = getSquare(square:getX() - 1, square:getY(), square:getZ())
            if poleSq then hasFloor = poleSq:hasFloor() end
        end
    end
    if hasFloor then return true end
    local below = getCell():getGridSquare(square:getX(), square:getY(), square:getZ() - 1)
    if not below then return false end
    if north then
        return below:has(
            IsoPropertyType.WALL_N, IsoPropertyType.WALL_NW, IsoPropertyType.WINDOW_FRAME_N, IsoPropertyType.DOOR_WALL_N
        )
    end
    return below:has(
        IsoPropertyType.WALL_W, IsoPropertyType.WALL_NW, IsoPropertyType.WINDOW_FRAME_W, IsoPropertyType.DOOR_WALL_W
    )
end

local function checkWallFrame(square, north, wantsWindow)
    local hasFrame = false
    local hasBuilt = false
    for i = 0, square:getSpecialObjects():size() - 1 do
        local item = square:getSpecialObjects():get(i)
        if instanceof(item, "IsoThumpable") then
            if wantsWindow and item:isWindow() and item:getNorth() == north then hasFrame = true end
            if not wantsWindow and item:isDoorFrame() and item:getNorth() == north then hasFrame = true end
            if not wantsWindow and item:isDoor() and item:getNorth() == north then hasBuilt = true end
        end
    end
    for i = 0, square:getObjects():size() - 1 do
        local object = square:getObjects():get(i)
        local sprite = object and object:getSprite()
        local props = sprite and sprite:getProperties()
        if wantsWindow then
            if north and props and props:has(IsoPropertyType.WINDOW_N) then hasFrame = true end
            if not north and props and props:has(IsoPropertyType.WINDOW_W) then hasFrame = true end
            if instanceof(object, "IsoWindow") and object:getNorth() == north then hasBuilt = true end
        else
            if north and object:getType() == IsoObjectType.doorFrN then hasFrame = true end
            if not north and object:getType() == IsoObjectType.doorFrW then hasFrame = true end
            if north and props and props:has(IsoPropertyType.DOOR_WALL_N) then hasFrame = true end
            if not north and props and props:has(IsoPropertyType.DOOR_WALL_W) then hasFrame = true end
            if instanceof(object, "IsoDoor") and object:getNorth() == north then hasBuilt = true end
        end
    end
    return hasFrame, hasBuilt
end

local function facingName(cursor)
    local value = ({ "w", "n", "e", "s" })[cursor.nSprite or cursor.direction or 1]
    return value or "w"
end

local function compactName(value)
    value = string.lower(tostring(value or ""))
    value = string.gsub(value, "[%s_%-%(%)%.:]+", "")
    value = string.gsub(value, "wooden", "wood")
    return value
end

local function compactMatches(candidate, names)
    candidate = compactName(candidate)
    if candidate == "" then return false end
    for nameIndex = 1, #names do
        local name = compactName(names[nameIndex])
        if candidate == name or string.sub(candidate, - #name) == name then return true end
    end
    return false
end

local function tileInfoFor(tile)
    local info = { spriteName = tile and tile.sprite or nil, blocks = tile and tile.blocks == true }
    function info:getSpriteName()
        return self.spriteName
    end

    function info:isBlocking()
        return self.blocks
    end

    return info
end

-- Previous stages match any IsoThumpable whose NAME equals one of the stage
-- names, exactly like vanilla ISBuildIsoEntity:isValidPerSquare. Knox-built
-- thumpables are named after the vanilla entity (see KBWBuildingObject:new),
-- so both vanilla-built and Knox-built frames match. Knox modData is checked
-- too: the recorded entity name, the stage id (for multi-stage buildables),
-- and the buildable id all count, so `previousStage` can name either a
-- vanilla entity or a Knox stage/buildable.
---@param square IsoGridSquare|nil
---@param buildableId string
---@param north boolean
function Placement.findPrevious(square, buildableId, previousStage, north)
    if not previousStage then return nil end
    local names = {}
    if type(previousStage) == "table" then
        for nameIndex = 1, #previousStage do
            names[#names + 1] = string.lower(tostring(previousStage[nameIndex]))
        end
    else
        names[1] = string.lower(tostring(previousStage))
    end
    local function requestedEdge(object)
        return north == nil or (object.getNorth and object:getNorth() == (north == true))
    end
    for i = 0, square:getSpecialObjects():size() - 1 do
        local object = square:getSpecialObjects():get(i)
        if instanceof(object, "IsoThumpable") then
            local objectName = object.getName and object:getName() or nil
            if objectName then
                local lowered = string.lower(objectName)
                for nameIndex = 1, #names do
                    if lowered == names[nameIndex] and requestedEdge(object) then return object end
                end
                if compactMatches(objectName, names) and requestedEdge(object) then return object end
            end
            local data = object:getModData()
            local kbw = data and data.KBW or nil
            if kbw then
                if kbw.buildableId == buildableId then
                    for nameIndex = 1, #names do
                        if string.lower(tostring(kbw.stageId)) == names[nameIndex] and requestedEdge(object) then
                            return object
                        end
                    end
                end
                if requestedEdge(object)
                    and (compactMatches(kbw.entity, names) or compactMatches(kbw.stageId, names)
                        or compactMatches(kbw.buildableId, names)) then
                    return object
                end
            end
        end
    end
    return nil
end

-- Public frame lookup for the planning system: does the square already hold
-- a door frame (wantsWindow=false) or window frame (wantsWindow=true) on the
-- given edge, without a door/window already hung there?
---@param square IsoGridSquare|nil
---@param north boolean
function Placement.hasWallFrame(square, north, wantsWindow)
    if not square then return false end
    local hasFrame, hasBuilt = checkWallFrame(square, north == true, wantsWindow == true)
    return hasFrame and not hasBuilt
end

-- The stage's previous-stage requirement can live on the stage itself or in
-- the referenced entity's native SpriteConfig metadata.
---@param stage KBW.BuildStage
function Placement.previousStageOf(stage)
    if not stage then return nil end
    return StageConfig.sprite(nil, stage).previousStage
end

---@param stage KBW.BuildStage
function Placement.optionalReplacementStageOf(stage)
    if not stage then return nil end
    local entity = compactName(EntityCompat.metadata(stage).entity or "")
    if string.find(entity, "wooddoorframe", 1, true) then return { "WoodenWallFrame", "MetalWallFrame" } end
    if string.find(entity, "metaldoorframe", 1, true) then return { "MetalWallFrame", "WoodenWallFrame" } end
    return nil
end

---@param square IsoGridSquare|nil
function Placement.validate(cursor, square)
    if not square or not cursor.character then return false, "missing square or player" end
    local placement = StageConfig.placement(cursor.definition, cursor.stage)
    local dx, dy = cursor.character:getX() - square:getX(), cursor.character:getY() - square:getY()
    if placement.maxDistance and placement.maxDistance > 0 and dx * dx + dy * dy > placement.maxDistance ^ 2 then
        return false, "too far away"
    end
    if (isClient() or isServer()) and SafeHouse.isSafeHouse(square, cursor.character:getUsername(), true) then
        return false, "safehouse denied"
    end
    local previousStage = Placement.previousStageOf(cursor.stage) or Placement.optionalReplacementStageOf(cursor.stage)
    local previous = Placement.findPrevious(square, cursor.definition.id, previousStage, cursor.north == true)
    if previousStage and not previous then return false, "previous stage missing" end
    -- A matching previous stage short-circuits the remaining collision and
    -- support checks, mirroring vanilla ISBuildIsoEntity:isValidPerSquare
    -- (the frame being replaced would otherwise fail the wall-blocked tests).
    if previous then return true, nil, previous end
    if placement.againstWall or placement.needToBeAgainstWall then
        -- Vanilla checks the square the shelf FACES INTO (n -> y+1, w -> x+1)
        -- for the wall, and refuses when another special object already sits on
        -- the original square (ISBuildIsoEntity "AGAINST WALLS").
        local face = facingName(cursor)
        local wallX, wallY = square:getX(), square:getY()
        if face == "n" then wallY = wallY + 1 end
        if face == "w" then wallX = wallX + 1 end
        local wallSquare = getSquare(wallX, wallY, square:getZ())
        local found = false
        if wallSquare then
            for i = 0, wallSquare:getObjects():size() - 1 do
                local wallObject = wallSquare:getObjects():get(i)
                local props = wallObject and wallObject:getProperties()
                if props
                    and (props:has(IsoPropertyType.WALL_NW) or (cursor.north and props:has(IsoPropertyType.WALL_N))
                        or (not cursor.north and props:has(IsoPropertyType.WALL_W))) then
                    for j = 0, square:getSpecialObjects():size() - 1 do
                        local special = square:getSpecialObjects():get(j)
                        if special ~= wallObject and instanceof(special, "IsoThumpable") and not special:isFloor() then
                            return false, "square already occupied"
                        end
                    end
                    found = true
                    break
                end
            end
        end
        if not found then return false, "wall required" end
    end
    local kind = placement.kind
    if kind == "floor" then
        -- Floors provide their own floor and may extend over open air when an
        -- adjacent floor or wall supports them - mirrors vanilla
        -- BuildRecipeCode.floor.OnIsValid (which also disables collision tests).
        if square.HasStairsBelow and square:HasStairsBelow() then return false, "stairs below" end
        for i = 0, square:getObjects():size() - 1 do
            local object = square:getObjects():get(i)
            local textureName = object:getTextureName()
            local spriteName = object:getSpriteName()
            if (textureName and luautils.stringStarts(textureName, "vegetation_farming"))
                or (spriteName and luautils.stringStarts(spriteName, "vegetation_farming")) then
                return false, "farming plot blocked"
            end
        end
        if not square:connectedWithFloor() then return false, "no adjacent floor support" end
    elseif placement.requiresFloor ~= false and not square:getFloor() then
        return false, "floor required"
    end
    local spriteConfig = StageConfig.sprite(cursor.definition, cursor.stage)
    local footprint = cursor.getFootprint and cursor:getFootprint() or nil
    if footprint then
        for tileIndex = 1, #footprint do
            local tile = footprint[tileIndex]
            if tile.sprite or tile.blocks then
                local target = getCell()
                    :getGridSquare(square:getX() + (tile.dx or 0), square:getY() + (tile.dy or 0), square:getZ()
                        + (tile.dz or 0))
                if not target then return false, "missing footprint square" end
                local sprite, props = spriteProps(tile.sprite)
                local extendsN = (tile.dy or 0) > 0
                local extendsW = (tile.dx or 0) > 0
                local params = {
                    square = target,
                    tileInfo = tileInfoFor(tile),
                    north = cursor.north,
                    canBuildOverWater = false,
                    testCollisions = true,
                    facing = facingName(cursor)
                }
                if spriteConfig.onIsValid and not LuaCallback.callBool(spriteConfig.onIsValid, params, true) then
                    return false, "script OnIsValid rejected"
                end
                if kind == "floor" then
                    -- Vanilla floor OnIsValid rejects rebuilding the same floor
                    -- sprite and skips the generic collision tests entirely.
                    for i = 0, target:getObjects():size() - 1 do
                        local object = target:getObjects():get(i)
                        if (object:getTextureName() and object:getTextureName() == tile.sprite)
                            or (object:getSpriteName() and object:getSpriteName() == tile.sprite) then
                            return false, "floor already built"
                        end
                    end
                    params.testCollisions = false
                end
                if params.testCollisions ~= false then
                    if target:has(IsoPropertyType.GARAGE_DOOR) then return false, "garage door blocked" end
                    if extendsN
                        and (target:getProperties():has(IsoFlagType.collideN) or target:getProperties():has(IsoFlagType.WallN)
                            or target:getProperties():has(IsoFlagType.WallNW)
                            or target:getProperties():has(IsoFlagType.WindowN)
                            or target:getProperties():has(IsoFlagType.DoorWallN)
                            or target:getProperties():has(IsoFlagType.HoppableN)) then
                        return false, "north edge blocked"
                    end
                    if extendsW
                        and (target:getProperties():has(IsoFlagType.collideW) or target:getProperties():has(IsoFlagType.WallW)
                            or target:getProperties():has(IsoFlagType.WallNW)
                            or target:getProperties():has(IsoFlagType.WindowW)
                            or target:getProperties():has(IsoFlagType.DoorWallW)
                            or target:getProperties():has(IsoFlagType.HoppableW)) then
                        return false, "west edge blocked"
                    end
                    if target:isVehicleIntersecting() then return false, "vehicle blocked" end
                    if buildUtil.stairIsBlockingPlacement(target, true) then return false, "stairs blocked" end
                    -- Vanilla ISBuildIsoEntity only runs the isFree tests for
                    -- blocking cells WITHOUT a sprite (a parenthesization quirk
                    -- the game's balance depends on); sprite tiles are governed
                    -- by the solid-on-solid check below. Mirroring this is what
                    -- lets door frames go onto wall-frame squares.
                    if tile.blocks and not tile.sprite then
                        if placement.requiresFloor ~= false then
                            if not target:isFree(true) and not (params.canBuildOverWater and target:getFloor()
                                and target:getFloor():getSprite() and target:getFloor():getSprite():getProperties():has(IsoFlagType.water))
                                and not (props and props:has("IsStackable") and target:getFloor()) then
                                return false, "footprint blocked"
                            end
                        elseif not target:isFreeOrMidair(true) then
                            return false, "midair footprint blocked"
                        end
                    end
                    if props and (target:getProperties():has(IsoPropertyType.BLOCKS_PLACEMENT) or target:isSolid()
                            or target:isSolidTrans())
                        and (props:has(IsoFlagType.solidtrans) or props:has("BlocksPlacement")) then
                        -- Stackable furniture (crates) may go on top of an
                        -- existing stack; ISMoveableSpriteProps enforces the
                        -- height limit (vanilla ISBuildIsoEntity CHECK SOLID).
                        if props:has("IsStackable") then
                            local moveProps = ISMoveableSpriteProps.new(sprite)
                            if not moveProps:canPlaceMoveable("bogus", target, nil) then
                                return false, "stack blocked"
                            end
                        else
                            return false, "solid placement blocked"
                        end
                    end
                    if isWallSprite(sprite) then
                        for i = 0, target:getObjects():size() - 1 do
                            local object = target:getObjects():get(i)
                            local osprite = object:getSprite()
                            if objectSpriteBlocksWall(osprite, cursor.north) then return false, "wall already blocked" end
                            local spriteGrid = osprite and osprite:getSpriteGrid()
                            if spriteGrid then
                                local gridX = spriteGrid:getSpriteGridPosX(osprite)
                                local gridY = spriteGrid:getSpriteGridPosY(osprite)
                                if cursor.north and gridY > 0 then return false, "multi-tile object crossing north wall" end
                                if not cursor.north and gridX > 0 then
                                    return false, "multi-tile object crossing west wall"
                                end
                            end
                        end
                        if not hasWallSupport(target, cursor.north, placement.isPole) then
                            return false, "wall support missing"
                        end
                    end
                    if placement.needWindowFrame then
                        local hasFrame, hasWindow = checkWallFrame(target, cursor.north, true)
                        if not hasFrame or hasWindow then return false, "window frame required" end
                    end
                    -- DOOR STUFF (vanilla ISBuildIsoEntity:isValidPerSquare):
                    -- doors need a floor, a frame on the same edge (unless the
                    -- script says dontNeedFrame) and no door already hung there.
                    local isDoorSprite = sprite
                        and (sprite:getType() == IsoObjectType.doorW or sprite:getType() == IsoObjectType.doorN)
                    if isDoorSprite then
                        if not target:hasFloor(cursor.north) then return false, "door needs floor" end
                        local hasFrame, hasDoor = checkWallFrame(target, cursor.north, false)
                        local dontNeedFrame = placement.dontNeedFrame == true or spriteConfig.dontNeedFrame == true
                        if hasDoor then return false, "door already built" end
                        if not dontNeedFrame and not hasFrame then return false, "door frame required" end
                    end
                end
            end
        end
    end
    return true, nil, previous
end

return Placement
