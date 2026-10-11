--- Planning suite: blueprint model, planning cursor, Planning Mode window and ghosts.
if not isDebugEnabled() then return end

local Harness = require("KnoxBuildworks/Debug/TestHarness")
local TestUtil = require("KnoxBuildworks/Debug/TestUtil")
local BuildTestRunner = require("KnoxBuildworks/Debug/BuildTestRunner")
local Blueprints = require("KnoxBuildworks/Planning/Blueprints")
local SafeJSON = require("KnoxBuildworks/Util/SafeJSON")
local Planner = require("KnoxBuildworks/Planning/Planner")
local GhostRenderer = require("KnoxBuildworks/Planning/GhostRenderer")
local KBW = require("KnoxBuildworks/Core")
require("KnoxBuildworks/UI/PlanningMode")

local function placementFor(sample, x, y, z, direction)
    return {
        buildableId = sample.buildableId,
        stageId = sample.stageId,
        variantId = "",
        materialId = "",
        x = x,
        y = y,
        z = z,
        direction = direction or 1
    }
end

--- Fresh blueprint at the player; everything created is removed afterwards.
local function withBlueprint(t, body)
    local player = t.ctx.player
    local snapshot = TestUtil.snapshotUiState(player)
    local before = TestUtil.blueprintIds()
    t:cleanup(function ()
        Planner.cancelCursor(player)
        if KBWPlanningMode and KBWPlanningMode.instance then KBWPlanningMode.instance:close() end
        TestUtil.deleteNewBlueprints(player, before)
        TestUtil.restoreUiState(player, snapshot)
        GhostRenderer.clearCache()
    end)
    if KBW.sandboxValue("KnoxBuildworks.EnablePlanningMode", true) ~= true then
        return t:skip("planning mode is disabled in sandbox options")
    end
    local z = math.floor(player:getZ())
    local blueprint = Blueprints.create(player, "KBW test " .. tostring(t.id), z)
    if not blueprint then return t:fail("Blueprints.create returned nothing") end
    body(blueprint, math.floor(player:getX()), math.floor(player:getY()), z)
end

local function samples(t, kinds)
    local result = {}
    for index = 1, #kinds do
        local sample = BuildTestRunner.representative(kinds[index])
        if not sample then
            t:skip("no simple " .. kinds[index] .. " buildable is registered")
            return nil
        end
        result[kinds[index]] = sample
    end
    return result
end

local tests = {}

tests[#tests + 1] = {
    id = "planning:lifecycle",
    name = "Blueprint create, rename, level, duplicate, delete",
    run = function (t)
        withBlueprint(t, function (blueprint, x, y, z)
            local player = t.ctx.player
            t:check(Blueprints.get(player, blueprint.id) == blueprint, "created blueprint is not in the store")
            t:check(Blueprints.isActive(player, blueprint.id), "a new blueprint becomes the active one")
            t:check(Blueprints.isOwner(player, blueprint), "creator is not the owner")
            local listed = false
            local list = Blueprints.list(player)
            for index = 1, #list do
                if list[index].id == blueprint.id then listed = true end
            end
            t:check(listed, "blueprint missing from Blueprints.list")
            t:check(Blueprints.rename(player, blueprint.id, "Renamed by test"), "rename refused")
            t:equal(blueprint.name, "Renamed by test", "rename")
            t:check(not Blueprints.rename(player, blueprint.id, ""), "empty names must be refused")
            t:check(Blueprints.setLevel(player, blueprint.id, z + 1), "setLevel refused")
            t:equal(blueprint.level, z + 1, "level")
            t:check(not Blueprints.setLevel(player, blueprint.id, "not a number"), "non-numeric level accepted")
            local copy = Blueprints.duplicate(player, blueprint.id)
            t:check(copy ~= nil and copy.id ~= blueprint.id, "duplicate did not create a new blueprint")
            t:check(Blueprints.delete(player, copy and copy.id), "deleting the duplicate failed")
            t:check(Blueprints.get(player, copy and copy.id) == nil, "deleted blueprint still in the store")
            t:check(
                Blueprints.setActive(player, nil) == nil and Blueprints.active(player) == nil,
                "clearing the active blueprint"
            )
        end)
    end
}

tests[#tests + 1] = {
    id = "planning:placements",
    name = "Placements, overlap and range rules, totals",
    run = function (t)
        withBlueprint(t, function (blueprint, x, y, z)
            local player = t.ctx.player
            local kinds = samples(t, { "floor", "object" })
            if not kinds then return end
            local floor = Blueprints.addPlacement(player, blueprint.id, placementFor(kinds.floor, x + 2, y + 2, z))
            t:check(floor ~= nil and floor.id ~= nil, "floor placement refused")
            local again, reason = Blueprints.addPlacement(
                player, blueprint.id, placementFor(kinds.floor, x + 2, y + 2, z)
            )
            t:check(
                again == nil and reason == "plan_overlap", "same floor twice should overlap, got " .. tostring(reason)
            )
            local far, farReason = Blueprints.addPlacement(
                player, blueprint.id, placementFor(kinds.floor, x + Blueprints.blueprintRadius() * 3, y, z)
            )
            t:check(
                far == nil and farReason == "out_of_range",
                "far placement should be out of range, got " .. tostring(farReason)
            )
            local batch = {}
            for dx = 0, 3 do
                batch[#batch + 1] = placementFor(kinds.floor, x + 4 + dx, y + 2, z)
            end
            local added = Blueprints.addPlacements(player, blueprint.id, batch)
            t:equal(#added, 4, "drag-fill batch")
            local object = Blueprints.addPlacement(player, blueprint.id, placementFor(kinds.object, x + 4, y + 4, z))
            t:check(object ~= nil, "object placement refused")
            t:equal(#blueprint.placements, 6, "placement count")
            local at = Blueprints.placementsAt(blueprint, x + 2, y + 2, z)
            t:check(#at >= 1 and at[1].id == floor.id, "placementsAt does not find the floor")
            local totals = Blueprints.totals(player, blueprint)
            t:equal(totals.placements, 6, "totals placement count")
            t:check(
                totals.buildables[kinds.floor.buildableId] and totals.buildables[kinds.floor.buildableId].count == 5,
                "totals count the five floors"
            )
            t:check(Blueprints.removePlacement(player, blueprint.id, floor.id), "removePlacement refused")
            local ids = {}
            for index = 1, #added do
                ids[index] = added[index].id
            end
            t:equal(Blueprints.removePlacements(player, blueprint.id, ids), 4, "removePlacements count")
            t:equal(#blueprint.placements, 1, "placements left after removal")
        end)
    end
}

tests[#tests + 1] = {
    id = "planning:rooms",
    name = "Rooms: add, extend, cut, update, remove",
    run = function (t)
        withBlueprint(t, function (blueprint, x, y, z)
            local player = t.ctx.player
            local room = Blueprints.addRoom(
                player, blueprint.id,
                {
                    x = x + 1,
                    y = y + 1,
                    w = 4,
                    h = 3,
                    z = z,
                    name = "Test room"
                }
            )
            if not room then return t:fail("addRoom refused a 4x3 room") end
            t:check(#Blueprints.roomsAt(blueprint, x + 2, y + 2, z) == 1, "roomsAt misses the room")
            t:check(
                Blueprints.extendRoom(player, blueprint.id, room.id, { x = x + 5, y = y + 1, w = 2, h = 3 }),
                "extendRoom refused an adjacent rectangle"
            )
            t:check(#Blueprints.roomsAt(blueprint, x + 6, y + 2, z) == 1, "extended tiles are not in the room")
            t:check(
                Blueprints.shrinkRoom(player, blueprint.id, room.id, { x = x + 1, y = y + 1, w = 1, h = 1 }),
                "shrinkRoom refused a corner notch"
            )
            t:check(#Blueprints.roomsAt(blueprint, x + 1, y + 1, z) == 0, "cut tile still in the room")
            t:check(
                Blueprints.updateRoom(player, blueprint.id, room.id, { name = "Renamed room" }), "updateRoom refused"
            )
            t:check(
                not Blueprints.updateRoom(player, blueprint.id, room.id, { owner = "nobody" }),
                "updateRoom accepted a non-display field"
            )
            t:check(Blueprints.removeRoom(player, blueprint.id, room.id), "removeRoom refused")
            t:equal(#(blueprint.rooms or {}), 0, "rooms left")
        end)
    end
}

tests[#tests + 1] = {
    id = "planning:export-import",
    name = "Export to JSON and import round trip",
    run = function (t)
        withBlueprint(t, function (blueprint, x, y, z)
            local player = t.ctx.player
            local kinds = samples(t, { "floor", "wall" })
            if not kinds then return end
            Blueprints.addPlacement(player, blueprint.id, placementFor(kinds.floor, x + 1, y + 1, z))
            Blueprints.addPlacement(player, blueprint.id, placementFor(kinds.wall, x + 2, y + 1, z, 2))
            Blueprints.addRoom(player, blueprint.id, { x = x + 1, y = y + 1, w = 2, h = 2, z = z })
            local text = Blueprints.exportJSON(blueprint)
            t:check(type(text) == "string" and #text > 0, "export produced no JSON")
            local decoded, err = SafeJSON.decode(text)
            if not decoded then return t:fail("exported JSON does not parse: " .. tostring(err)) end
            t:check(
                decoded.id == nil and decoded.owner == nil and decoded.access == nil,
                "export leaks local ownership fields"
            )
            t:equal(decoded.exportSchema, Blueprints.VERSION, "export schema")
            local imported, why = Blueprints.importExported(player, decoded)
            if not imported then return t:fail("import refused: " .. tostring(why)) end
            t:check(imported.id ~= blueprint.id, "import reused the source id")
            t:equal(#imported.placements, 2, "imported placements")
            t:equal(#(imported.rooms or {}), 1, "imported rooms")
            local bad = Blueprints.importExported(player, { placements = {}, exportSchema = 999 })
            t:check(bad == nil, "an unsupported export schema was accepted")
        end)
    end
}

tests[#tests + 1] = {
    id = "planning:move",
    name = "Move shifts placements, rooms and anchor",
    run = function (t)
        withBlueprint(t, function (blueprint, x, y, z)
            local player = t.ctx.player
            local kinds = samples(t, { "floor" })
            if not kinds then return end
            local placement = Blueprints.addPlacement(player, blueprint.id, placementFor(kinds.floor, x + 1, y + 1, z))
            local room = Blueprints.addRoom(player, blueprint.id, { x = x, y = y, w = 2, h = 2, z = z })
            t:check(Blueprints.move(player, blueprint.id, 3, -2, 0), "move refused")
            t:equal(placement.x, x + 4, "placement x after move")
            t:equal(placement.y, y - 1, "placement y after move")
            t:equal(room.x, x + 3, "room x after move")
            t:equal(blueprint.anchor.x, x + 4, "anchor follows the move")
        end)
    end
}

tests[#tests + 1] = {
    id = "planning:cursor",
    name = "Planning cursor places a ghost",
    run = function (t)
        withBlueprint(t, function (blueprint, x, y, z)
            local player = t.ctx.player
            local kinds = samples(t, { "floor" })
            if not kinds then return end
            local cursor = Planner.begin(player, kinds.floor.buildableId, kinds.floor.stageId, "", "", 1)
            if not cursor then return t:fail("Planner.begin returned no cursor") end
            t:equal(cursor.blueprintId, blueprint.id, "cursor targets the active blueprint")
            local square = getCell():getGridSquare(x + 2, y + 2, z)
            if not square then return t:skip("target square is not loaded") end
            cursor:updatePlanPosition(x + 2, y + 2, z)
            local valid = cursor:isValid(square)
            t:check(valid, "planning cursor rejected an open square: " .. tostring(cursor.planInvalidReason))
            if valid then
                cursor:create(x + 2, y + 2, z, false, cursor:getSprite())
                t:equal(#blueprint.placements, 1, "cursor create adds one ghost")
            end
            Planner.cancelCursor(player)
            t:check(getCell():getDrag(player:getPlayerNum()) == nil, "cancelCursor left a drag active")
        end)
    end
}

tests[#tests + 1] = {
    id = "planning:mode-window",
    name = "Planning Mode window opens, lists and closes",
    run = function (t)
        withBlueprint(t, function (blueprint, x, y, z)
            local player = t.ctx.player
            local kinds = samples(t, { "floor", "object" })
            if not kinds then return end
            Blueprints.addPlacement(player, blueprint.id, placementFor(kinds.floor, x + 1, y + 1, z))
            Blueprints.addPlacement(player, blueprint.id, placementFor(kinds.object, x + 3, y + 3, z))
            local ui = KBWPlanningMode.open(player)
            if not ui then return t:fail("KBWPlanningMode.open returned nothing") end
            t:waitTicks(3)
            t:next(function ()
                t:check(KBWPlanningMode.instance == ui, "planning mode closed itself")
                t:check(ui.catalogPanel ~= nil, "planning catalogue panel missing")
                ui:refreshBlueprints(blueprint.id)
                local selected = ui:selectedBlueprint()
                t:check(selected and selected.id == blueprint.id, "test blueprint is not selected in the list")
                local panel = ui.catalogPanel
                if panel then
                    panel:refreshCatalog()
                    local definition = BuildTestRunner.representativeDefinition("object")
                    if definition then
                        ui:onCatalogSelected(definition)
                        t:check(ui.selectedBuildable == definition, "planning catalogue did not select the card")
                        t:check(panel:selectedStage() ~= nil, "planning catalogue selection has no stage")
                    end
                end
                local outside = TestUtil.childrenOutside(ui, 2)
                t:check(#outside == 0, "controls outside the planning panel: " .. table.concat(outside, ", "))
                t:waitTicks(3)
                t:next(function ()
                    ui:close()
                    t:check(KBWPlanningMode.instance == nil, "close() left the instance set")
                end)
            end)
        end)
    end
}

tests[#tests + 1] = {
    id = "planning:ghosts",
    name = "Ghost cells and live rendering",
    run = function (t)
        withBlueprint(t, function (blueprint, x, y, z)
            local player = t.ctx.player
            local kinds = samples(t, { "floor", "wall", "object" })
            if not kinds then return end
            local list = {
                Blueprints.addPlacement(player, blueprint.id, placementFor(kinds.floor, x + 1, y + 1, z)),
                Blueprints.addPlacement(player, blueprint.id, placementFor(kinds.wall, x + 2, y + 1, z, 2)),
                Blueprints.addPlacement(player, blueprint.id, placementFor(kinds.object, x + 3, y + 3, z))
            }
            for index = 1, #list do
                local placement = list[index]
                if not placement then
                    t:check(false, "sample placement " .. index .. " refused")
                else
                    local cells = GhostRenderer.placementCells(placement) or {}
                    t:check(#cells > 0, placement.buildableId .. " expands to no ghost cells")
                end
            end
            Blueprints.setActive(player, blueprint.id)
            GhostRenderer.clearCache()
            t:waitTicks(5)
        end)
    end
}

Harness.registerSuite({
    id = "planning",
    order = 30,
    titleKey = "IGUI_KBW_TestSuite_Planning",
    descriptionKey = "IGUI_KBW_TestSuite_PlanningDesc",
    collect = function ()
        return tests
    end
})

return true
