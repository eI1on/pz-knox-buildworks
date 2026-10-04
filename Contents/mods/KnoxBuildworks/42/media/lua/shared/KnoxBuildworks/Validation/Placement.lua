--- Placement provides the Knox Buildworks construction validation layer.
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
    ["door frame required"] = "IGUI_KBW_Reason_DoorFrameRequired",
    ["outside required"] = "IGUI_KBW_Reason_OutsideRequired"
}

---@param reason string | nil
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

local function findReplaceableWall(square, north)
    if not square then return nil end
    for objectIndex = 0, square:getSpecialObjects():size() - 1 do
        local object = square:getSpecialObjects():get(objectIndex)
        if instanceof(object, "IsoThumpable") and object:getNorth() == (north == true) then
            local props = object:getProperties()
            local isOpening = object:isDoor() or object:isDoorFrame() or object:isWindow()
            if props then
                isOpening = isOpening or props:has(IsoFlagType.WindowN) or props:has(IsoFlagType.WindowW)
                    or props:has(IsoFlagType.DoorWallN) or props:has(IsoFlagType.DoorWallW)
                    or props:has(IsoFlagType.HoppableN) or props:has(IsoFlagType.HoppableW)
            end
            if not isOpening and objectSpriteBlocksWall(object:getSprite(), north) then return object end
        end
    end
    return nil
end

local function spriteProps(spriteName)
    local sprite = spriteName and getSprite(spriteName)
    return sprite, sprite and sprite:getProperties() or nil
end

local ATTACHMENT_NAMES = { "attachedN", "attachedW", "attachedE", "attachedS" }

local function attachmentName(props)
    if not props then return nil end
    for attachmentIndex = 1, #ATTACHMENT_NAMES do
        local name = ATTACHMENT_NAMES[attachmentIndex]
        if props:has(name) then return name end
    end
    if props:has("Facing") then
        return ({ E = "attachedW", S = "attachedN", W = "attachedE", N = "attachedS" })[props:get("Facing")]
    end
    return nil
end

-- The square holding the wall a fixture attaches to, and whether that wall runs
-- north. A square owns only its north and west walls, so the east and south
-- attachments read the neighbour's.
local function attachmentWall(square, attachment)
    local north = attachment == "attachedN" or attachment == "attachedS"
    if attachment == "attachedE" then
        return getCell():getGridSquare(square:getX() + 1, square:getY(), square:getZ()), north
    elseif attachment == "attachedS" then
        return getCell():getGridSquare(square:getX(), square:getY() + 1, square:getZ()), north
    end
    return square, north
end

-- Corner cabinets are drawn to sit where two walls meet, and the game names
-- them so: "Floating Motel Corner", "Floating Trailer Corner", "Wooden Corner".
local function isCornerFixture(props)
    if not props or not props:has("GroupName") then return false end
    local groupName = string.lower(tostring(props:get("GroupName") or ""))
    return string.find(groupName, "corner", 1, true) ~= nil
end

-- Something hanging at head height clears whatever stands on the floor beneath
-- it, which is what lets an overhead cabinet share a square with a counter.
local function isHighWallObject(props)
    if not props or not props:has("MoveType") or props:get("MoveType") ~= "WallObject" then return false end
    return props:has("IsHigh")
end

local function hasWallProperty(square, north, allowDoorFrame, allowWindowFrame)
    if not square then return false end
    local wallName = north and "WallN" or "WallW"
    local doorName = north and "DoorWallN" or "DoorWallW"
    local windowName = north and "WindowN" or "WindowW"
    if square:has(wallName) or square:has("WallNW")
        or allowDoorFrame and square:has(doorName)
        or allowWindowFrame and square:has(windowName) then
        return true
    end
    for objectIndex = 0, square:getObjects():size() - 1 do
        local object = square:getObjects():get(objectIndex)
        local props = object and object:getProperties()
        if props and (props:has(wallName) or props:has("WallNW")
                or allowDoorFrame and props:has(doorName)
                or allowWindowFrame and props:has(windowName)) then
            return true
        end
    end
    return false
end

local function hasAttachedWallSupport(square, fixtureProps)
    local attachment = attachmentName(fixtureProps)
    if not square or not attachment then return false end
    local wallSquare, north = attachmentWall(square, attachment)
    if not wallSquare then return false end

    -- A door or window frame carries a fixture the same way the wall it sits in
    -- does, so both count rather than only the walls without an opening.
    local supported = hasWallProperty(wallSquare, north, true, true)
    if not supported and isCornerFixture(fixtureProps) then
        -- A corner piece reaches both walls of the corner it stands in, so the
        -- one its Facing happens to name is not the only one that can hold it.
        local attachmentIndex = 1
        while not supported and attachmentIndex <= #ATTACHMENT_NAMES do
            local otherSquare, otherNorth = attachmentWall(square, ATTACHMENT_NAMES[attachmentIndex])
            supported = otherSquare ~= nil and hasWallProperty(otherSquare, otherNorth, true, true)
            attachmentIndex = attachmentIndex + 1
        end
    end
    if not supported then return false end

    -- Match vanilla's high/low overlap behavior while still allowing fixtures
    -- on different faces of a corner square.
    local fixtureHigh, fixtureLow = fixtureProps:has("IsHigh"), fixtureProps:has("IsLow")
    for objectIndex = 0, square:getObjects():size() - 1 do
        local object = square:getObjects():get(objectIndex)
        local props = object and object:getProperties()
        if props and props:has("MoveType") and props:get("MoveType") == "WallObject"
            and attachmentName(props) == attachment then
            local objectHigh, objectLow = props:has("IsHigh"), props:has("IsLow")
            if (not objectHigh and not objectLow) or objectHigh and fixtureHigh or objectLow and fixtureLow then
                return false
            end
        end
    end
    return true
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

local function isRelevantOverlayWall(object, north, isCorner)
    local modData = object:getModData()
    if modData and modData.WindowWall then return true end
    local props = object:getProperties()
    if not props or instanceof(object, "IsoWindow") or props:has(IsoFlagType.solidfloor) then return false end
    if isCorner then return props:has(IsoFlagType.WallNW) or props:has(IsoFlagType.WallSE) end
    if north then
        return props:has(IsoFlagType.WallN) or props:has(IsoFlagType.WindowN) or props:has(IsoFlagType.WallNW)
            or props:has(IsoFlagType.WallSE) or props:has(IsoFlagType.DoorWallN)
            or (props:has(IsoFlagType.HoppableN) and props:has(IsoFlagType.WallNTrans))
    end
    return props:has(IsoFlagType.WallW) or props:has(IsoFlagType.WindowW) or props:has(IsoFlagType.WallNW)
        or props:has(IsoFlagType.WallSE) or props:has(IsoFlagType.DoorWallW)
        or (props:has(IsoFlagType.HoppableW) and props:has(IsoFlagType.WallWTrans))
end

local function hasOverlayWallSupport(square, north, isCorner)
    for objectIndex = 0, square:getObjects():size() - 1 do
        if isRelevantOverlayWall(square:getObjects():get(objectIndex), north, isCorner) then return true end
    end
    return false
end

local function isDeclaredWindowFrame(object, north)
    if not object or not instanceof(object, "IsoThumpable") or object:getNorth() ~= north then return false end
    local modData = object:getModData()
    return modData and modData.KBW and modData.KBW.providesWindowFrame == true
end

local function isDeclaredDoorFrame(object, north)
    if not object or not object.getModData then return false end
    local modData = object:getModData()
    local data = modData and modData.KBW or nil
    if not data or data.providesDoorFrame ~= true then return false end
    local direction = tonumber(data.direction) or 1
    local frameNorth = direction == 2 or direction == 4
    return frameNorth == north
end

-- Shapes 3, 4, 8, 11 and 12 are cutaway and double-door openings rather than
-- punched windows, and the windows drawn for them declare those same shapes. A
-- cut opening therefore counts as a frame when - and only when - the window
-- being placed names the same shape.
local function cutOpeningMatches(props, north, shapeOf)
    if not props or shapeOf == nil then return false end
    local opening = north and props:has(IsoFlagType.cutN)
        or not north and props:has(IsoFlagType.cutW)
    if not opening then return false end
    return Placement.windowShapeOf(props) == shapeOf
end

local function tileProvidesWindowFrame(props, north)
    if not props then return false end
    if north then
        return props:has(IsoPropertyType.WINDOW_N)
            or props:has(IsoPropertyType.WINDOW_FRAME_N)
            or props:has(IsoFlagType.WindowN)
    end
    return props:has(IsoPropertyType.WINDOW_W)
        or props:has(IsoPropertyType.WINDOW_FRAME_W)
        or props:has(IsoFlagType.WindowW)
end

---Matches an exact sprite name or a prefix pattern ending in `*`.
---@param spriteName string|nil
---@param patterns string[]|nil
function Placement.matchesWindowSupportSprite(spriteName, patterns)
    if not spriteName or not patterns then return false end
    for patternIndex = 1, #patterns do
        local pattern = tostring(patterns[patternIndex] or "")
        if pattern == spriteName then return true end
        if string.sub(pattern, -1) == "*" then
            local prefix = string.sub(pattern, 1, #pattern - 1)
            if string.sub(spriteName, 1, #prefix) == prefix then return true end
        end
    end
    return false
end

local function isCompatibleWindowSupport(object, north, patterns)
    local sprite = object and object:getSprite() or nil
    local spriteName = sprite and sprite:getName() or nil
    if not Placement.matchesWindowSupportSprite(spriteName, patterns) then return false end
    if instanceof(object, "IsoThumpable") then return object:getNorth() == north end
    local props = sprite and sprite:getProperties() or nil
    return props and (north and props:has(IsoFlagType.cutN) or not north and props:has(IsoFlagType.cutW)) or false
end

-- Windows and the walls they sit in both declare WindowShape, and the art is
-- drawn to fit: a shape 3 window only fills a shape 3 opening. Older pieces on
-- both sides declare no shape at all, and those belong with each other - so an
-- absent shape is a value here, not a wildcard.
---@param props PropertyContainer|nil
---@return string|nil
function Placement.windowShapeOf(props)
    if not props then return nil end
    local value = props.get and props:get("WindowShape") or nil
    if value == nil then return nil end
    value = tostring(value)
    if value == "" then return nil end
    return value
end

---@param wanted string|nil the shape of the window being placed
---@param frame string|nil the shape of the opening it would sit in
function Placement.windowShapesMatch(wanted, frame)
    return wanted == frame
end

-- shapeOf is nil when nothing should be filtered (the planning preview asks
-- only whether a frame exists at all).
local function frameShapeAccepts(shapeOf, props)
    if shapeOf == nil then return true end
    return Placement.windowShapesMatch(shapeOf, Placement.windowShapeOf(props))
end

local function checkWallFrame(square, north, wantsWindow, windowSupportSprites, shapeOf)
    local hasFrame = false
    local hasBuilt = false
    for i = 0, square:getSpecialObjects():size() - 1 do
        local item = square:getSpecialObjects():get(i)
        if instanceof(item, "IsoThumpable") then
            if wantsWindow and item:getNorth() == north
                and ((( item:isWindow() or isDeclaredWindowFrame(item, north)
                        or tileProvidesWindowFrame(item:getProperties(), north))
                      and frameShapeAccepts(shapeOf, item:getProperties()))
                    or cutOpeningMatches(item:getProperties(), north, shapeOf)) then
                hasFrame = true
            end
            -- windowSupportSprites is an explicit list the definition author
            -- wrote; it already says which sprites this window belongs on, so
            -- the shape filter does not second-guess it.
            if wantsWindow and isCompatibleWindowSupport(item, north, windowSupportSprites) then
                hasFrame = true
            end
            if not wantsWindow and (item:isDoorFrame() and item:getNorth() == north
                or isDeclaredDoorFrame(item, north)) then hasFrame = true end
            if not wantsWindow and item:isDoor() and item:getNorth() == north then hasBuilt = true end
        end
    end
    for i = 0, square:getObjects():size() - 1 do
        local object = square:getObjects():get(i)
        local sprite = object and object:getSprite()
        local props = sprite and sprite:getProperties()
        if wantsWindow then
            if (tileProvidesWindowFrame(props, north) and frameShapeAccepts(shapeOf, props))
                or cutOpeningMatches(props, north, shapeOf) then
                hasFrame = true
            end
            if isCompatibleWindowSupport(object, north, windowSupportSprites) then
                hasFrame = true
            end
            if instanceof(object, "IsoWindow") and object:getNorth() == north then hasBuilt = true end
        else
            if isDeclaredDoorFrame(object, north) then hasFrame = true end
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
---@param square      IsoGridSquare | nil
---@param buildableId string
---@param north       boolean
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
---@param square IsoGridSquare | nil
---@param north  boolean
---@param wantsWindow boolean
---@param windowSupportSprites string[]|nil
---@param windowShape string|nil when given, only an opening of that shape counts
function Placement.hasWallFrame(square, north, wantsWindow, windowSupportSprites, windowShape)
    if not square then return false end
    local hasFrame, hasBuilt = checkWallFrame(
        square, north == true, wantsWindow == true, windowSupportSprites, windowShape
    )
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

---@param square IsoGridSquare | nil
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
    if placement.requiresOutside == true and not square:isOutside() then return false, "outside required" end
    local previousStage = Placement.previousStageOf(cursor.stage)
    local replacementStage = previousStage or Placement.optionalReplacementStageOf(cursor.stage)
    local previous = Placement.findPrevious(square, cursor.definition.id, replacementStage, cursor.north == true)
    if previousStage and not previous then return false, "previous stage missing" end
    local kind = placement.kind
    if not previous and kind == "wall" and cursor.canPassThrough ~= true then
        previous = findReplaceableWall(square, cursor.north == true)
    end
    if not previous and (placement.againstWall or placement.needToBeAgainstWall) then
        if kind == "overlay" then
            local objectConfig = (cursor.stage and cursor.stage.object) or {}
            if not hasOverlayWallSupport(square, cursor.north == true, objectConfig.isCorner == true) then
                return false, "wall required"
            end
        else
            local found = false
            local preview = cursor.getFootprint and cursor:getFootprint() or nil
            local previewSprite = preview and preview[1] and preview[1].sprite or nil
            local selectedSprite, selectedProps = spriteProps(previewSprite)

            if selectedSprite and selectedSprite:getType() == IsoObjectType.lightswitch
                and selectedProps and not selectedProps:has("IsMoveAble") then
                local face = facingName(cursor)
                local wallSquare, north = square, face == "n" or face == "s"
                if face == "e" then
                    wallSquare = getCell():getGridSquare(square:getX() + 1, square:getY(), square:getZ())
                elseif face == "s" then
                    wallSquare = getCell():getGridSquare(square:getX(), square:getY() + 1, square:getZ())
                end
                found = hasWallProperty(wallSquare, north, false)
            elseif selectedProps and selectedProps:has("MoveType")
                and selectedProps:get("MoveType") == "WallObject" then
                found = hasAttachedWallSupport(square, selectedProps)
            else
                local wallSquare = square
                if wallSquare then
                    for i = 0, wallSquare:getObjects():size() - 1 do
                        local wallObject = wallSquare:getObjects():get(i)
                        local props = wallObject and wallObject:getProperties()
                        if props
                            and (props:has(IsoPropertyType.WALL_NW)
                                or (cursor.north and props:has(IsoPropertyType.WALL_N))
                                or (not cursor.north and props:has(IsoPropertyType.WALL_W))) then
                            for j = 0, square:getSpecialObjects():size() - 1 do
                                local special = square:getSpecialObjects():get(j)
                                if special ~= wallObject and instanceof(special, "IsoThumpable")
                                    and not special:isFloor() then
                                    return false, "square already occupied"
                                end
                            end
                            found = true
                            break
                        end
                    end
                end
            end
            if not found then return false, "wall required" end
        end
    end
    if not previous and kind == "floor" then
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
    elseif not previous and placement.requiresFloor ~= false then
        local hasRequiredFloor = square:getFloor() ~= nil
        if kind == "wall" then hasRequiredFloor = square:hasFloor(cursor.north == true) end
        if not hasRequiredFloor then return false, "floor required" end
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
                local spriteType = sprite and sprite:getType() or nil
                if spriteType == IsoObjectType.doorFrN or spriteType == IsoObjectType.doorFrW then
                    local frameNorth = spriteType == IsoObjectType.doorFrN
                    local adjacent = frameNorth and target:getN() or target:getW()
                    if adjacent and adjacent:getModData()["ConnectedToStairs" .. tostring(frameNorth)] then
                        return false, "stairs blocked"
                    end
                end
                local extendsN = (tile.dy or 0) > 0
                local extendsW = (tile.dx or 0) > 0
                local params = {
                    square = target,
                    tileInfo = tileInfoFor(tile),
                    north = cursor.north,
                    canBuildOverWater = false,
                    testCollisions = true,
                    facing = facingName(cursor),
                    character = cursor.character,
                    definition = cursor.definition,
                    stage = cursor.stage,
                    buildObject = cursor,
                    placement = placement,
                    buildableId = cursor.buildableId,
                    stageId = cursor.stage and cursor.stage.id or nil,
                    tile = tile,
                    tileIndex = tileIndex,
                    spriteName = tile.sprite,
                    x = target:getX(),
                    y = target:getY(),
                    z = target:getZ()
                }
                if spriteType == IsoObjectType.lightswitch and props and not props:has("IsMoveAble") then
                    params.testCollisions = false
                end
                if spriteConfig.onIsValid then
                    if not LuaCallback.resolve(spriteConfig.onIsValid) then
                        return false, "script OnIsValid is unavailable"
                    end
                    if not LuaCallback.callBool(spriteConfig.onIsValid, params, false) then
                        return false, "script OnIsValid rejected"
                    end
                end
                if not previous and kind == "floor" then
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
                if not previous and params.testCollisions ~= false then
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
                    if not sprite and buildUtil.stairIsBlockingPlacement(target, true) then
                        return false, "stairs blocked"
                    end
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
                    -- Framing pieces are meant to be combined on one square: a
                    -- post, the beam it carries and its brace all share a tile.
                    -- allowSharedSquare only waives the occupied-square half of
                    -- this test; genuinely solid terrain still rejects.
                    local occupiedBlocks = target:getProperties():has(IsoPropertyType.BLOCKS_PLACEMENT)
                        and placement.allowSharedSquare ~= true
                    -- An overhead fixture hangs above the floor, so a counter or
                    -- a table already on the square is not in its way. The wall
                    -- it attaches to is checked separately, and two high
                    -- fixtures on the same wall still reject each other.
                    if props and not isHighWallObject(props)
                        and (occupiedBlocks or target:isSolid()
                            or target:isSolidTrans())
                        and (props:has(IsoFlagType.solidtrans) or props:has("BlocksPlacement")) then
                        if props:has("IsStackable") or props:has("IsTableTop") then
                            local moveProps = ISMoveableSpriteProps.new(sprite)
                            if not moveProps:canPlaceMoveable(cursor.character, target, nil) then
                                return false, props:has("IsStackable") and "stack blocked" or "solid placement blocked"
                            end
                        else
                            return false, "solid placement blocked"
                        end
                    end
                    -- Sharing a square is only useful for pieces that differ.
                    -- The same sprite placed twice hides perfectly inside its
                    -- own copy, so the player would pay for an invisible build.
                    if placement.allowSharedSquare == true and tile.sprite then
                        for i = 0, target:getObjects():size() - 1 do
                            local existing = target:getObjects():get(i)
                            local existingSprite = existing and existing:getSprite() or nil
                            if existingSprite and existingSprite:getName() == tile.sprite then
                                return false, "square already occupied"
                            end
                        end
                    end
                    if isWallSprite(sprite) then
                        for i = 0, target:getObjects():size() - 1 do
                            local object = target:getObjects():get(i)
                            local osprite = object:getSprite()
                            if object ~= previous and objectSpriteBlocksWall(osprite, cursor.north) then
                                return false, "wall already blocked"
                            end
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
                        -- A window whose WindowShape matches no opening the game
                        -- draws cannot be constrained by it; those say so.
                        local shapeOf = nil
                        if placement.ignoreWindowShape ~= true then
                            shapeOf = Placement.windowShapeOf(sprite and sprite:getProperties())
                        end
                        local hasFrame, hasWindow = checkWallFrame(
                            target, cursor.north, true, placement.windowSupportSprites, shapeOf
                        )
                        if hasWindow then return false, "window already built" end
                        if not hasFrame then
                            return false, shapeOf and "window frame of a different shape"
                                or "window frame required"
                        end
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
