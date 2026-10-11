--- Catalogue UI suite: drives the real KBWCatalog window and checks its state.
if not isDebugEnabled() then return end

local Harness = require("KnoxBuildworks/Debug/TestHarness")
local TestUtil = require("KnoxBuildworks/Debug/TestUtil")
local CatalogIndex = require("KnoxBuildworks/UI/CatalogIndex")
local CatalogVisibility = require("KnoxBuildworks/UI/CatalogVisibility")
local Groups = require("KnoxBuildworks/Definitions/Groups")
local Planner = require("KnoxBuildworks/Planning/Planner")
local KBW = require("KnoxBuildworks/Core")
require("KnoxBuildworks/UI/Catalog")

local NO_MATCH = "zz-kbw-test-no-such-buildable-zz"

--- Opens a fresh catalogue for the test and closes/restores everything after.
local function withCatalog(t, body)
    local player = t.ctx.player
    local snapshot = TestUtil.snapshotUiState(player)
    local blueprints = TestUtil.blueprintIds()
    t:cleanup(function ()
        if KBWCatalog.instance then KBWCatalog.instance:close() end
        Planner.cancelCursor(player)
        TestUtil.deleteNewBlueprints(player, blueprints)
        TestUtil.restoreUiState(player, snapshot)
    end)
    if not KBW.Runtime.loaded then return t:skip("definitions are still loading") end
    if KBWCatalog.instance then KBWCatalog.instance:close() end
    local catalog = KBWCatalog.open(player)
    if not catalog then return t:fail("KBWCatalog.open returned nothing") end
    t.catalog = catalog
    t:waitTicks(2)
    t:next(function ()
        if KBWCatalog.instance ~= catalog then return t:fail("catalogue closed itself after opening") end
        body(catalog)
    end)
end

local function clearFilters(catalog)
    catalog:onClearFilters()
end

local function gridCount(catalog)
    return #(catalog.grid.items or {})
end

local function categoryOf(entry)
    return tostring(entry and entry.category or "")
end

local tests = {}

tests[#tests + 1] = {
    id = "catalog:open-close",
    name = "Open, render and close",
    run = function (t)
        withCatalog(t, function (catalog)
            t:check(catalog:isVisible(), "catalogue is not visible")
            t:check(gridCount(catalog) > 0, "catalogue grid is empty")
            t:check(catalog.selected ~= nil, "no card is selected after opening")
            local outside = TestUtil.childrenOutside(catalog, 2)
            t:check(#outside == 0, "controls outside the window: " .. table.concat(outside, ", "))
            catalog:close()
            t:check(KBWCatalog.instance == nil, "close() left KBWCatalog.instance set")
        end)
    end
}

tests[#tests + 1] = {
    id = "catalog:search",
    name = "Search narrows and clears",
    run = function (t)
        withCatalog(t, function (catalog)
            clearFilters(catalog)
            local total = gridCount(catalog)
            local index = CatalogIndex.get()
            local record = index.orderById[math.max(1, math.floor(#index.orderById / 2))]
            if not record then return t:fail("catalogue index is empty") end
            local word = string.match(record.searchText or "", "[%a][%a][%a][%a]+") or record.id
            catalog.search:setText(word)
            catalog:refreshGrid()
            local narrowed = gridCount(catalog)
            t:check(narrowed > 0, "search '" .. word .. "' found nothing")
            t:check(narrowed <= total, "search widened the grid")
            local found = false
            for itemIndex = 1, narrowed do
                local entry = catalog.grid.items[itemIndex]
                if Groups.anyMemberIn(entry, { [record.id] = true }) or entry.id == record.id then found = true end
            end
            t:check(
                found or not CatalogIndex.recordVisible(t.ctx.player, record, false),
                "search did not return " .. record.id
            )
            catalog.search:setText(NO_MATCH)
            catalog:refreshGrid()
            t:equal(gridCount(catalog), 0, "nonsense search should be empty")
            t:check(catalog.selected == nil, "selection survived an empty result")
            catalog.search:setText("")
            catalog:refreshGrid()
            t:equal(gridCount(catalog), total, "clearing the search restores the grid")
        end)
    end
}

tests[#tests + 1] = {
    id = "catalog:categories",
    name = "Every category filters to itself",
    run = function (t)
        withCatalog(t, function (catalog)
            clearFilters(catalog)
            local total = gridCount(catalog)
            local categories = catalog.categories or {}
            t:check(#categories > 0, "no categories")
            local seen = 0
            for categoryIndex = 1, #categories do
                local category = categories[categoryIndex]
                catalog:onCategory({ internal = category })
                local count = gridCount(catalog)
                seen = seen + count
                for itemIndex = 1, count do
                    local entry = catalog.grid.items[itemIndex]
                    if categoryOf(entry) ~= category then
                        t:check(
                            false,
                            "category " .. category
                                .. " shows " .. tostring(entry.id)
                                .. " from " .. categoryOf(entry)
                        )
                        break
                    end
                end
            end
            catalog:onCategory({ internal = "All" })
            t:equal(gridCount(catalog), total, "All restores every card")
            t:check(seen >= total, "categories cover fewer cards than All (" .. seen .. " < " .. total .. ")")
        end)
    end
}

tests[#tests + 1] = {
    id = "catalog:scopes",
    name = "Favourites and recent scopes",
    run = function (t)
        withCatalog(t, function (catalog)
            clearFilters(catalog)
            local first = catalog.grid.items[1]
            if not first then return t:fail("grid is empty") end
            local wasFavorite = catalog:isFavorite(first)
            if not wasFavorite then catalog:onGridFavorite(first) end
            t:check(catalog:isFavorite(first), "favouriting did not stick")
            catalog:onScope({ internal = "Favorites" })
            local count = gridCount(catalog)
            t:check(count > 0, "favourites scope is empty after favouriting")
            for itemIndex = 1, count do
                t:check(catalog:isFavorite(catalog.grid.items[itemIndex]), "non-favourite in favourites scope")
            end
            catalog:onScope({ internal = "Recent" })
            local recent = gridCount(catalog)
            catalog:onScope({ internal = "All" })
            t:check(
                gridCount(catalog) >= count and gridCount(catalog) >= recent,
                "All scope shows fewer cards than Favourites or Recent"
            )
        end)
    end
}

tests[#tests + 1] = {
    id = "catalog:view-size",
    name = "List/grid view and compact/detailed size",
    run = function (t)
        withCatalog(t, function (catalog)
            local mode = catalog.viewMode
            catalog:onToggleView()
            t:check(catalog.viewMode ~= mode, "view toggle did not change mode")
            t:equal(catalog.grid.viewMode, catalog.viewMode, "grid view mode follows the window")
            t:waitTicks(2)
            t:next(function ()
                catalog:onToggleView()
                t:equal(catalog.viewMode, mode, "second toggle restores the view")
                local compact = catalog.compact == true
                catalog:onToggleSize()
                t:check((catalog.compact == true) ~= compact, "size toggle did not switch compact mode")
                t:check(catalog.width >= catalog.minimumWidth, "compact width below its minimum")
                t:waitTicks(2)
                t:next(function ()
                    local outside = TestUtil.childrenOutside(catalog, 2)
                    t:check(#outside == 0, "controls outside the toggled window: " .. table.concat(outside, ", "))
                    catalog:onToggleSize()
                    t:equal(catalog.compact == true, compact, "second size toggle restores the mode")
                end)
            end)
        end)
    end
}

tests[#tests + 1] = {
    id = "catalog:resize",
    name = "Layout at minimum and large sizes",
    run = function (t)
        withCatalog(t, function (catalog)
            local width, height = catalog.width, catalog.height
            catalog:setWidth(catalog.minimumWidth)
            catalog:setHeight(catalog.minimumHeight)
            catalog:layout()
            t:waitTicks(2)
            t:next(function ()
                local outside = TestUtil.childrenOutside(catalog, 2)
                t:check(#outside == 0, "minimum size: " .. table.concat(outside, ", "))
                local screenW = getPlayerScreenWidth(t.ctx.player:getPlayerNum())
                local screenH = getPlayerScreenHeight(t.ctx.player:getPlayerNum())
                catalog:setWidth(math.max(catalog.minimumWidth, screenW - 40))
                catalog:setHeight(math.max(catalog.minimumHeight, screenH - 40))
                catalog:layout()
                t:waitTicks(2)
                t:next(function ()
                    local large = TestUtil.childrenOutside(catalog, 2)
                    t:check(#large == 0, "large size: " .. table.concat(large, ", "))
                    catalog:setWidth(width)
                    catalog:setHeight(height)
                    catalog:layout()
                end)
            end)
        end)
    end
}

tests[#tests + 1] = {
    id = "catalog:selection-sweep",
    name = "Select every card (options, requirements, drawer)",
    run = function (t)
        withCatalog(t, function (catalog)
            clearFilters(catalog)
            local entries = {}
            for index = 1, gridCount(catalog) do
                entries[index] = catalog.grid.items[index]
            end
            entries = TestUtil.sample(entries, t.ctx.options.uiSampleLimit or 0)
            local cursor = 1
            local function batch()
                local last = math.min(#entries, cursor + 24)
                for index = cursor, last do
                    local entry = entries[index]
                    catalog:onCardSelected(entry)
                    if catalog.selected ~= entry then
                        t:check(false, "selecting " .. tostring(entry.id) .. " did not select it")
                    else
                        local stages = catalog.visibleStages or {}
                        -- A stale card is fine if selecting it settles it as hidden.
                        local hidden = #stages == 0
                            and CatalogIndex.refreshRecordVisibility(
                                catalog.player, entry.id, CatalogVisibility.shouldShowAll(catalog.player)
                            ) == false
                        t:check(
                            #stages > 0 or hidden or not catalog:effectiveDefinition(),
                            tostring(entry.id) .. " has no visible stage"
                        )
                        for stageIndex = 1, #stages do
                            catalog.stage.selected = stageIndex
                            catalog:onStageChanged()
                            t:check(
                                catalog:selectedStage() ~= nil,
                                tostring(entry.id) .. " stage "
                                    .. stageIndex .. " does not resolve"
                            )
                        end
                        local variants = catalog.variant.options or {}
                        for variantIndex = 1, #variants do
                            catalog.variant.selected = variantIndex
                            catalog:onVariantChanged()
                            t:check(
                                catalog:effectiveDefinition() ~= nil,
                                tostring(entry.id) .. " variant "
                                    .. variantIndex .. " does not resolve"
                            )
                        end
                        local materials = catalog.material.options or {}
                        for materialIndex = 1, #materials do
                            catalog.material.selected = materialIndex
                            catalog:onMaterialChanged()
                            t:check(
                                catalog:effectiveDefinition() ~= nil,
                                tostring(entry.id) .. " material "
                                    .. materialIndex .. " does not resolve"
                            )
                        end
                        if not catalog.compact then catalog:updateIngredientDrawerForSelection(true) end
                    end
                end
                cursor = last + 1
                t.yieldAfterStep = true
                if cursor <= #entries then
                    t:waitTicks(1)
                    t:next(batch)
                end
            end
            t:note(tostring(#entries) .. " card(s) selected")
            batch()
        end)
    end
}

tests[#tests + 1] = {
    id = "catalog:plan-handoff",
    name = "Plan button hands off to the planning cursor",
    run = function (t)
        withCatalog(t, function (catalog)
            if KBW.sandboxValue("KnoxBuildworks.EnablePlanningMode", true) ~= true then
                return t:skip("planning mode is disabled in sandbox options")
            end
            clearFilters(catalog)
            catalog:onCardSelected(catalog.grid.items[1])
            catalog:onPlan()
            t:check(KBWCatalog.instance == nil, "catalogue stayed open after Plan")
            local drag = getCell():getDrag(t.ctx.player:getPlayerNum())
            t:check(drag ~= nil and drag.isPlanCursor == true, "Plan did not activate a planning cursor")
        end)
    end
}

Harness.registerSuite({
    id = "catalog",
    order = 20,
    titleKey = "IGUI_KBW_TestSuite_Catalog",
    descriptionKey = "IGUI_KBW_TestSuite_CatalogDesc",
    collect = function ()
        return tests
    end
})

return true
