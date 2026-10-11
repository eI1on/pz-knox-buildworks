--- "build": one test per case (piece, then optional finishes/coverings), built
--- instantly or by walking, then verified. "planqueue": a small plan built by the queue.
if not isDebugEnabled() then return end

local Harness = require("KnoxBuildworks/Debug/TestHarness")
local TestUtil = require("KnoxBuildworks/Debug/TestUtil")
local Runner = require("KnoxBuildworks/Debug/BuildTestRunner")
local Requirements = require("KnoxBuildworks/Validation/Requirements")
local StageConfig = require("KnoxBuildworks/Definitions/StageConfig")
local WallFinishes = require("KnoxBuildworks/Validation/WallFinishes")
local FinishOptions = require("KnoxBuildworks/UI/FinishOptions")
local Blueprints = require("KnoxBuildworks/Planning/Blueprints")
local BuildQueue = require("KnoxBuildworks/Planning/BuildQueue")
local Integrity = require("KnoxBuildworks/Network/Integrity")
local FinishQueue = require("KnoxBuildworks/Planning/FinishQueue")
local KBWFinishAction = require("KnoxBuildworks/TimedActions/KBWFinishAction")
local KBW = require("KnoxBuildworks/Core")
require("KnoxBuildworks/UI/Catalog")

local WALK_TIMEOUT_MS = 9000
local FINISH_TIMEOUT_MS = 4500
local COVERING_SETTLE_TICKS = 90
local QUEUE_TIMEOUT_MS = 24000
local REVIEW_TIMEOUT_MS = 360000

--- True while the character still has queued or running timed actions.
local function busy(player)
    if ISTimedActionQueue.isPlayerDoingAction(player) then return true end
    local queue = ISTimedActionQueue.getTimedActionQueue(player)
    return queue ~= nil and queue.queue ~= nil and #queue.queue > 0
end

local function consumesSomething(definition, stage)
    local inputs = Requirements.getInputs(definition, stage)
    for index = 1, #inputs do
        local input = inputs[index]
        local needed = tonumber(input.uses or input.amount) or 1
        if needed > 0 and input.mode ~= "keep" then return true end
    end
    return false
end

--- Common preconditions; returns false after skipping/failing the test.
local function environmentReady(t)
    local player = t.ctx.player
    if isClient() then
        t:skip("automatic world tests run in single-player debug sessions only")
        return false
    end
    if player:isBuildCheat() then
        t:skip("disable Build Cheat: it bypasses requirement consumption")
        return false
    end
    if not Integrity.isAllowed(player) then
        t:fail("definition integrity check has not passed")
        return false
    end
    if not Runner.ensureBuildingObject() then
        t:fail("KBWBuildingObject is not loaded")
        return false
    end
    return true
end

--- Its own layout slot when pieces are kept, else a spiral cleaned after each test.
local function areaFor(ctx, stage)
    if ctx.options.keep and ctx.layout then
        local width, height = Runner.extentOf(stage)
        return Runner.allocate(ctx.layout, width, height)
    end
    return Runner.spiralArea(ctx.origin.x, ctx.origin.y, ctx.origin.z)
end

--- Holds the test until the tester presses Pass or Fail in the runner window.
local function review(t, label)
    local ctx = t.ctx
    if not ctx.options.pause then return end
    ctx.review = { test = t, label = label }
    t:waitUntil(
        function () return ctx.review == nil or ctx.review.decision ~= nil end, REVIEW_TIMEOUT_MS, "review timed out"
    )
    t:next(function ()
        local decision = ctx.review and ctx.review.decision or nil
        if decision == "fail" then t:check(false, "marked failed during review: " .. label) end
        ctx.review = nil
    end)
end

local function finishLabel(finish)
    if not finish then return "built" end
    return tostring(finish.label or WallFinishes.plannedFinishSignature(finish) or finish.actionType or "finish")
end

--- Finish sub-builds for a stage, according to the window's finish option.
local function finishesFor(definition, stage, mode)
    local entries = FinishOptions.entriesFor(definition, stage)
    local kind = StageConfig.placement(definition, stage).kind
    if kind == "wallCovering" then
        if mode == "all" then return entries end
        return { entries[1] }
    end
    if mode == "none" then return {} end
    local result, seen = {}, {}
    for index = 1, #entries do
        local entry = entries[index]
        if WallFinishes.isWallFinish(entry) then
            local group = entry.wallpaperType and "wallpaper" or entry.paintType and "paint" or "plaster"
            if mode == "all" or not seen[group] then
                seen[group] = true
                result[#result + 1] = entry
            end
        end
    end
    return result
end

local function finishRows(player, definition, stage, finish)
    if not finish then return nil end
    local rows = WallFinishes.statusRows(player, finish, definition, stage)
    if finish.paintType and #rows == 0 then
        rows[#rows + 1] = { id = "covering-paint", items = { finish.paintType } }
    end
    if finish.wallpaperType and #rows == 0 then
        rows[#rows + 1] = { id = "covering-paper", items = { finish.wallpaperType } }
    end
    return rows
end

-- SUB-BUILDS --------------------------------------------------------------

local function verify(t, sub)
    local entries = Runner.newObjects(sub.before, sub.square)
    sub.entries = entries
    local problems, notes = Runner.verifyBuilt(sub.cursor, sub.square, entries, sub.testCase.buildableId, sub.fixtures)
    for index = 1, #problems do
        t:check(false, sub.label .. ": " .. problems[index])
    end
    for index = 1, #notes do
        t:note(sub.label .. ": " .. notes[index])
    end
    if sub.consumes and sub.spawned then
        t:check(Runner.spawnedUnits(t.ctx.player) < sub.unitsBefore, sub.label .. ": no material or use was consumed")
    end
    t:note(
        sub.label .. ": " .. tostring(#entries) .. " object(s)"
            .. (#sub.fixtures > 0 and (", " .. #sub.fixtures .. " prerequisite object(s)") or "")
    )
end

--- Custom-colour objects (crates, doors) report any tint as "paint:*".
local function finishMatches(actual, planned)
    if actual == planned then return true end
    return actual == "paint:*" and planned ~= nil and string.find(planned, "^paint:") ~= nil
end

--- Whether the wall wears the finish; also by sprite, since vanilla reuses some
--- (PaintWhite is the plaster face).
local function wearsFinish(wall, finish, planned)
    if not wall then return false end
    if finishMatches(WallFinishes.objectFinishSignature(wall), planned) then return true end
    local sprite = wall:getSprite()
    local spriteName = sprite and sprite:getName() or nil
    if not spriteName then return false end
    local mode = finish.wallpaperType and "wallpaper" or (finish.paintType and "paint" or "plaster")
    local wallType = WallFinishes.objectWallType(wall)
    local expected = WallFinishes.spriteForWallType(mode, finish, WallFinishes.objectNorth(wall), wallType, spriteName)
    if expected ~= spriteName then return false end
    local color = mode == "paint" and WallFinishes.customColorFor(wallType, finish) or nil
    if not color then return true end
    local tint = wall.getCustomColor and wall:getCustomColor() or nil
    return tint ~= nil and math.abs(tint:getR() - color.r) < 0.01
        and math.abs(tint:getG() - color.g) < 0.01 and math.abs(tint:getB() - color.b) < 0.01
end

local function builtWall(sub)
    local entries = sub.entries or {}
    for index = 1, #entries do
        local entry = entries[index]
        if not entry.attachedSprite and entry.buildableId == sub.testCase.buildableId then return entry.object end
    end
    return nil
end

local function placeCharacter(t, sub)
    local player = t.ctx.player
    Runner.standBeside(player, sub.cursor, sub.square)
    if t.ctx.options.mode == Runner.MODE_WALK then
        -- Start a tile out so the character really walks.
        player:teleportTo(player:getX(), player:getY() + 1, sub.square:getZ())
    end
end

local function buildPiece(t, sub, finished)
    local ctx, player = t.ctx, t.ctx.player
    local cursor, square = sub.cursor, sub.square
    local ready, notReady = Runner.readyAt(cursor, square, sub.direction)
    if not ready then
        if notReady == "requirements not met" then
            local missing = Runner.missingRequirements(player, sub.definition, sub.stage, square, sub.choices)
            if missing and string.find(missing, "requires light", 1, true) then
                return t:skip("too dark to build here; run in daylight or with a light source")
            end
            if not sub.spawned then return t:skip(sub.label .. ": missing requirements: " .. tostring(missing)) end
        end
        return t:fail(sub.label .. ": validation rejected the supplied build: " .. tostring(notReady))
    end
    sub.before = Runner.worldObjectsAround(square)
    local function awaitFinish()
        if not sub.finish then return finished() end
        local planned = WallFinishes.plannedFinishSignature(sub.finish)
        local finishStarted = getTimestampMs()
        t:waitUntil(function ()
            local wall = builtWall(sub)
            if wearsFinish(wall, sub.finish, planned) and not busy(player) then
                return true
            end
            return getTimestampMs() - finishStarted > FINISH_TIMEOUT_MS and not busy(player)
        end, FINISH_TIMEOUT_MS + 15000, sub.label .. ": finish actions did not complete in time")
        t:next(function ()
            local wall = builtWall(sub)
            local actual = wall and WallFinishes.objectFinishSignature(wall) or nil
            local sprite = wall and wall:getSprite() or nil
            t:check(
                wearsFinish(wall, sub.finish, planned),
                sub.label .. ": wall finished as "
                    .. tostring(actual) .. " ("
                    .. tostring(sprite and sprite:getName()) .. "), expected "
                    .. tostring(planned)
            )
            finished()
        end)
    end
    if ctx.options.mode == Runner.MODE_WALK then
        local action = cursor:tryBuild(square:getX(), square:getY(), square:getZ())
        t:check(action ~= nil or busy(player), sub.label .. ": tryBuild queued no build action")
        local started = getTimestampMs()
        t:waitUntil(function ()
            return getTimestampMs() - started > 500 and not busy(player)
        end, WALK_TIMEOUT_MS, sub.label .. ": the character did not finish walking and building in time")
        t:next(function ()
            verify(t, sub)
            awaitFinish()
        end)
    else
        t.yieldAfterStep = true
        -- Arm FinishQueue before the wall exists, as tryBuild does.
        if sub.finish then
            FinishQueue.watch(
                player, sub.testCase.buildableId, square:getX(), square:getY(), square:getZ(), cursor.north == true,
                sub.finish, sub.definition, sub.stage
            )
        end
        t:check(
            Runner.createNow(player, cursor, square), sub.label .. ": create() rejected the build (see console.txt)"
        )
        verify(t, sub)
        awaitFinish()
    end
end

--- First square a covering support wall may go on.
local function coveringSquare(player, area, providers)
    if area.kind == "rect" then return getCell():getGridSquare(area.x1, area.y1, area.z) end
    local provider = providers[1]
    local probe = provider and Runner.newCursor(player, provider.buildableId, provider.stageId, "", "", nil) or nil
    if not probe then return nil end
    local square = Runner.findSite(probe, area)
    return square
end

local PLASTER_FINISH = { actionType = "wallFinish", plaster = true }

--- Plasters a covering's support wall, then done(ok, why).
local function plasterSupport(t, provider, wall, done)
    local player = t.ctx.player
    if WallFinishes.isObjectPlastered(wall) then return done(true) end
    local definition, stage = Runner.resolve(provider)
    local wallType = WallFinishes.prepareObject(wall)
    local base = wall:getSprite() and wall:getSprite():getName() or nil
    local sprite = WallFinishes.spriteForWallType(
        "plaster", PLASTER_FINISH, WallFinishes.objectNorth(wall), wallType, base
    )
    if not sprite then return done(false, provider.buildableId .. " has no plastered face") end
    local ok, why = Runner.supply(
        player, definition, stage, t.ctx.characterSnapshot,
        WallFinishes.statusRows(player, PLASTER_FINISH, definition, stage), true
    )
    if not ok then return done(false, why) end
    local inventory = player:getInventory()
    local bucket = inventory:getFirstTagRecurse(ItemTag.PLASTER_BUCKET)
    local trowel = inventory:getFirstTagRecurse(ItemTag.PLASTER_TROWEL)
    ISTimedActionQueue.add(
        KBWFinishAction:new(player, "plaster", wall, sprite, bucket, trowel, nil, nil, PLASTER_FINISH, true)
    )
    local started = getTimestampMs()
    t:waitUntil(function ()
        return getTimestampMs() - started > 500 and not busy(player)
    end, WALK_TIMEOUT_MS, "plastering the support wall did not finish in time")
    t:next(function ()
        if WallFinishes.isObjectPlastered(wall) then return done(true) end
        done(false, "the support wall " .. provider.buildableId .. " was not plastered")
    end)
end

--- Wall coverings, applied through the catalogue's own cursor.
local function buildCovering(t, sub, finished)
    local ctx, player = t.ctx, t.ctx.player
    local providers = Runner.providers("covering wall", nil, nil)
    local square = coveringSquare(player, sub.area, providers)
    if not square then return t:fail(sub.label .. ": no square for the support wall") end
    local spawn = ctx.options.spawn ~= false

    local function wallState(wall)
        local sprite = wall and wall:getSprite() or nil
        local attached = wall and wall:getAttachedAnimSprite() or nil
        -- Signs are an overlay sprite (ISPaintSignAction).
        local overlay = wall and wall.getOverlaySprite and wall:getOverlaySprite() or nil
        return tostring(sprite and sprite:getName()) .. "|" .. tostring(attached and attached:size() or 0) .. "|"
            .. tostring(wall and WallFinishes.objectFinishSignature(wall)) .. "|"
            .. tostring(overlay and overlay:getName())
    end

    local function applyCovering(provider, wall)
        local ok, supplyReason = Runner.supply(
            player, sub.definition, sub.stage, ctx.characterSnapshot,
            finishRows(player, sub.definition, sub.stage, sub.finish), spawn
        )
        if not ok then return t:fail(sub.label .. ": " .. tostring(supplyReason)) end
        local cursor = KBWCatalog.newWallCoveringCursor(player, sub.definition, sub.stage, sub.finish)
        if not cursor then return t:fail(sub.label .. ": the catalogue could not create a covering cursor") end
        -- isCouldSee lags a few ticks behind a teleport or wall change.
        local waitedFrom = Harness.tickNumber
        t:waitUntil(function ()
            return cursor:isValid(square) or Harness.tickNumber - waitedFrom > COVERING_SETTLE_TICKS
        end, WALK_TIMEOUT_MS, sub.label .. ": the covering cursor never settled")
        t:next(function ()
            if not cursor:isValid(square) then
                if not spawn then return t:skip(sub.label .. ": the character lacks the covering's items") end
                local sprite = wall:getSprite()
                return t:fail(sub.label .. ": the covering cursor finds nothing to cover on "
                        .. provider.buildableId .. " ("
                        .. tostring(sprite and sprite:getName()) .. ", could see "
                        .. tostring(square:isCouldSee(player:getPlayerNum())) .. ", has items "
                        .. tostring(cursor.hasItems == nil or cursor:hasItems()) .. ", plastered "
                        .. tostring(WallFinishes.isObjectPlastered(wall)) .. ")")
            end
            local before = wallState(wall)
            cursor:tryBuild(square:getX(), square:getY(), square:getZ())
            local started = getTimestampMs()
            t:waitUntil(function ()
                return getTimestampMs() - started > 500 and not busy(player)
            end, WALK_TIMEOUT_MS, sub.label .. ": the covering action did not finish in time")
            t:next(function ()
                t:check(wallState(wall) ~= before, sub.label .. ": the wall did not change (" .. before .. ")")
                t:note(sub.label .. ": covered " .. provider.buildableId)
                finished()
            end)
        end)
    end

    local attempt = 0
    local function tryProvider()
        attempt = attempt + 1
        local provider = providers[attempt]
        if not provider or attempt > Runner.MAX_PROVIDER_ATTEMPTS then
            return t:fail(sub.label .. ": no plasterable support wall could be built")
        end
        Runner.buildFixtureAt(t, player, provider, square, 1, 0, sub.fixtures, ctx, function (entries)
            if not entries then return tryProvider() end
            local wall = nil
            for index = 1, #entries do
                if not entries[index].attachedSprite and entries[index].buildableId == provider.buildableId then
                    wall = entries[index].object
                end
            end
            if not wall then return tryProvider() end
            Runner.cleanupSpawnedItems(player)
            local action = FinishOptions.coveringAction(sub.definition, sub.stage)
            local needsPlaster = action == "paintThump" or action == "wallpaper"
            player:teleportTo(square:getX() + 0.5, square:getY() + 1.5, square:getZ())
            t:waitTicks(Runner.SETTLE_TICKS)
            t:next(function ()
                if not needsPlaster then return applyCovering(provider, wall) end
                plasterSupport(t, provider, wall, function (plastered, why)
                    if not plastered then return t:fail(sub.label .. ": " .. tostring(why)) end
                    Runner.cleanupSpawnedItems(player)
                    applyCovering(provider, wall)
                end)
            end)
        end)
    end
    tryProvider()
end

--- One sub-build: site, supply, place the character, build, verify, review.
local function runSub(t, sub, finished)
    local ctx, player = t.ctx, t.ctx.player
    sub.fixtures = {}
    t.state.subs[#t.state.subs + 1] = sub
    local function reviewed()
        review(t, sub.label)
        t:next(finished)
    end
    if sub.covering then return buildCovering(t, sub, reviewed) end
    local probe = Runner.newCursor(
        player, sub.testCase.buildableId, sub.testCase.stageId, sub.testCase.variantId, sub.testCase.materialId, nil
    )
    if not probe then return t:fail(sub.label .. ": no placement cursor could be created") end
    t.yieldAfterStep = true
    local function attempt(area, triesLeft)
        Runner.prepareSite(t, player, probe, area, 0, sub.fixtures, ctx, nil, function (square, direction, why)
            t.yieldAfterStep = true
            if not square then
                if area.kind == "rect" and triesLeft > 0 and #sub.fixtures == 0 then
                    return attempt(areaFor(ctx, sub.stage), triesLeft - 1)
                end
                return t:fail(sub.label .. ": no valid site: " .. tostring(why))
            end
            Runner.cleanupSpawnedItems(player)
            local spawn = ctx.options.spawn ~= false
            local ok, supplyReason, choices = Runner.supply(
                player, sub.definition, sub.stage, ctx.characterSnapshot,
                finishRows(player, sub.definition, sub.stage, sub.finish), spawn
            )
            if not ok then return t:fail(sub.label .. ": " .. tostring(supplyReason)) end
            local cursor = Runner.newCursor(
                player, sub.testCase.buildableId, sub.testCase.stageId, sub.testCase.variantId, sub.testCase.materialId,
                choices
            )
            cursor.finish = sub.finish
            sub.cursor, sub.square, sub.direction, sub.choices, sub.spawned = cursor, square, direction, choices, spawn
            sub.consumes = consumesSomething(sub.definition, sub.stage)
            sub.unitsBefore = Runner.spawnedUnits(player)
            placeCharacter(t, sub)
            t:waitTicks(Runner.SETTLE_TICKS)
            t:next(function () buildPiece(t, sub, reviewed) end)
        end)
    end
    t:next(function () attempt(sub.area, 4) end)
end

local function removeWorld(t)
    local ctx, player = t.ctx, t.ctx.player
    ISTimedActionQueue.clear(player)
    getCell():setDrag(nil, player:getPlayerNum())
    Runner.cleanupSpawnedItems(player)
    if ctx.options.keep then return end
    local subs = t.state and t.state.subs or {}
    for index = #subs, 1, -1 do
        if subs[index].entries then Runner.removeEntries(subs[index].entries) end
        if subs[index].fixtures then Runner.removeEntries(subs[index].fixtures) end
    end
end

local function buildCaseTest(testCase)
    return {
        id = "build:" .. testCase.key,
        name = Runner.caseName(testCase),
        group = testCase.category .. " / " .. testCase.subcategory,
        testCase = testCase,
        run = function (t)
            if not environmentReady(t) then return end
            local ctx = t.ctx
            t.state = { subs = {} }
            t:cleanup(function () removeWorld(t) end)
            local definition, stage, reason = Runner.resolve(testCase)
            if not definition or not stage then
                if reason == "buildable disabled by server" then return t:skip(reason) end
                return t:fail("does not resolve: " .. tostring(reason))
            end
            local covering = StageConfig.placement(definition, stage).kind == "wallCovering"
            local finishes = finishesFor(definition, stage, ctx.options.finishes or "none")
            local plan = {}
            if not covering then
                plan[1] = { finish = nil }
            end
            for index = 1, #finishes do
                plan[#plan + 1] = { finish = finishes[index] }
            end
            if #plan == 0 then return t:skip("no covering option is available for this piece") end
            local index = 0
            local function nextSub()
                index = index + 1
                local entry = plan[index]
                if not entry then return end
                local sub = {
                    testCase = testCase,
                    definition = definition,
                    stage = stage,
                    finish = entry.finish,
                    covering = covering,
                    label = finishLabel(entry.finish),
                    area = areaFor(ctx, stage)
                }
                runSub(t, sub, function ()
                    if not ctx.options.keep then
                        Runner.removeEntries(sub.entries or {})
                        Runner.removeEntries(sub.fixtures or {})
                        sub.entries, sub.fixtures = nil, nil
                    end
                    nextSub()
                end)
            end
            nextSub()
        end
    }
end

local function ensureLayout(ctx)
    if ctx.options.keep and not ctx.layout then
        ctx.layout = Runner.newLayout(ctx.origin, ctx.options.gap, ctx.options.rowWidth)
    end
end

Harness.registerSuite({
    id = "build",
    order = 40,
    titleKey = "IGUI_KBW_TestSuite_Build",
    descriptionKey = "IGUI_KBW_TestSuite_BuildDesc",
    setup = ensureLayout,
    collect = function (ctx)
        local tests = {}
        local cases = Runner.cases()
        for index = 1, #cases do
            local testCase = cases[index]
            if ctx.matchesScope(testCase.category, testCase.subcategory) then
                tests[#tests + 1] = buildCaseTest(testCase)
            end
        end
        return tests
    end
})

-- PLAN + BUILD QUEUE ------------------------------------------------------

local function queueTest()
    return {
        id = "planqueue:floor-wall-object",
        name = "Plan a floor, wall and object, then auto-build the plan",
        run = function (t)
            if not environmentReady(t) then return end
            if KBW.sandboxValue("KnoxBuildworks.EnablePlanningMode", true) ~= true then
                return t:skip("planning mode is disabled in sandbox options")
            end
            local ctx = t.ctx
            local player = ctx.player
            local snapshot = TestUtil.snapshotUiState(player)
            local before = TestUtil.blueprintIds()
            local state = { entries = {}, placements = {} }
            t:cleanup(function ()
                if BuildQueue.isRunning() then BuildQueue.stop() end
                ISTimedActionQueue.clear(player)
                Runner.cleanupSpawnedItems(player)
                if not ctx.options.keep then Runner.removeEntries(state.entries) end
                TestUtil.deleteNewBlueprints(player, before)
                TestUtil.restoreUiState(player, snapshot)
            end)
            local area = ctx.options.keep and ctx.layout and Runner.allocate(ctx.layout, 9, 3)
                or Runner.spiralArea(ctx.origin.x, ctx.origin.y, ctx.origin.z)
            local anchor = area.kind == "rect" and { x = area.x1, y = area.y1, z = area.z } or ctx.origin
            local blueprint = Blueprints.create(player, "KBW test build queue", anchor.z)
            local used = {}
            local kinds = { "floor", "wall", "object" }
            for index = 1, #kinds do
                local sample = Runner.representative(kinds[index])
                if not sample then return t:skip("no simple " .. kinds[index] .. " buildable is registered") end
                local cursor = Runner.newCursor(player, sample.buildableId, sample.stageId, "", "", nil)
                local pieceArea = area.kind == "rect"
                    and Runner.rectArea(area.x1 + (index - 1) * 3, area.y1, area.x1 + (index - 1) * 3, area.y1, area.z)
                    or area
                local square, direction, why = Runner.findSite(cursor, pieceArea, used)
                if not square then return t:fail(kinds[index] .. " has no site: " .. tostring(why)) end
                for dx = -1, 1 do
                    for dy = -1, 1 do
                        used[(square:getX() + dx) .. "," .. (square:getY() + dy) .. "," .. square:getZ()] = true
                    end
                end
                local placement, reason = Blueprints.addPlacement(player, blueprint.id, {
                    buildableId = sample.buildableId,
                    stageId = sample.stageId,
                    variantId = "",
                    materialId = "",
                    x = square:getX(),
                    y = square:getY(),
                    z = square:getZ(),
                    direction = cursor.isWallLike and (direction == 2 and 2 or 1) or direction
                })
                if not placement then return t:fail(kinds[index] .. " placement refused: " .. tostring(reason)) end
                state.placements[#state.placements + 1] = { placement = placement, square = square, sample = sample }
            end
            Runner.cleanupSpawnedItems(player)
            for index = 1, #state.placements do
                local definition, stage = Runner.resolve(state.placements[index].sample)
                local ok, why = Runner.supply(
                    player, definition, stage, ctx.characterSnapshot, nil, ctx.options.spawn ~= false
                )
                if not ok then return t:fail(why) end
            end
            local center = getCell():getGridSquare(anchor.x, anchor.y, anchor.z)
            state.before = Runner.worldObjectsAround(center, 9, 1)
            player:teleportTo(anchor.x + 0.5, anchor.y + 4.5, anchor.z)
            local finished = nil
            t:waitTicks(Runner.SETTLE_TICKS)
            t:next(function ()
                local started = BuildQueue.start(player, blueprint.id, function (built, skipped)
                    finished = { built = built, skipped = skipped }
                end)
                if not started then return t:fail("BuildQueue.start refused the plan") end
                t:waitUntil(
                    function () return finished ~= nil end, QUEUE_TIMEOUT_MS, "the build queue did not finish in time"
                )
            end)
            t:next(function ()
                t:equal(finished.built, #state.placements, "pieces built by the queue")
                t:equal(finished.skipped, 0, "pieces skipped by the queue")
                local now = Runner.worldObjectsAround(center, 9, 1)
                for key, entry in pairs(now) do
                    if not state.before[key] then state.entries[#state.entries + 1] = entry end
                end
                for index = 1, #state.placements do
                    local wanted = state.placements[index].sample.buildableId
                    local found = false
                    for entryIndex = 1, #state.entries do
                        if state.entries[entryIndex].buildableId == wanted then found = true end
                    end
                    t:check(found, wanted .. " is not in the world after the queue finished")
                end
                t:equal(#(blueprint.placements or {}), 0, "built ghosts are removed from the blueprint")
                review(t, "build queue")
            end)
        end
    }
end

Harness.registerSuite({
    id = "planqueue",
    order = 50,
    titleKey = "IGUI_KBW_TestSuite_PlanQueue",
    descriptionKey = "IGUI_KBW_TestSuite_PlanQueueDesc",
    setup = ensureLayout,
    collect = function ()
        return { queueTest() }
    end
})

return true
