---Client provides the Knox Buildworks client layer.
local KBW = require("KnoxBuildworks/Core")
local Loader = require("KnoxBuildworks/Definitions/Loader")
local Registry = require("KnoxBuildworks/Definitions/Registry")
local Integrity = require("KnoxBuildworks/Network/Integrity")
local Catalog = require("KnoxBuildworks/UI/Catalog")
local Options = require("KnoxBuildworks/Options")
local Blueprints = require("KnoxBuildworks/Planning/Blueprints")
require("KnoxBuildworks/Planning/Planner")
require("KnoxBuildworks/World/WellSystem")
local PinnedRecipes = require("KnoxBuildworks/UI/PinnedRecipes")
local BuildableRules = require("KnoxBuildworks/Admin/BuildableRules")
require("KnoxBuildworks/UI/Sidebar")
require("KnoxBuildworks/Debug/DebugMenuDock")
require("KnoxBuildworks/Admin/BuildableEditorDock")

local helloPlayer = nil
local helloSentAt = 0
local HELLO_RETRY_MS = 5000

local function hello(player, retry)
    if isClient() then
        if not retry then Integrity.setClient("pending", getText("IGUI_KBW_IntegrityPending")) end
        sendClientCommand(player, KBW.NETWORK_MODULE, "Hello", { hash = Registry.hash })
        helloPlayer = player
        helloSentAt = getTimestampMs()
    else
        Integrity.setClient("ok", getText("IGUI_KBW_IntegritySingleplayer"))
        helloPlayer = nil
    end
end

-- B42.20 can create the player before every server-side Lua listener has
-- finished settling. A dropped first reply used to leave the catalogue in
-- "Waiting for server definition validation" for the entire session.
local function retryIntegrityHandshake(player)
    if not isClient() or not KBW.Runtime.loaded or KBW.Runtime.integrity ~= "pending" then return end
    local target = helloPlayer or player or getPlayer()
    if target and getTimestampMs() - helloSentAt >= HELLO_RETRY_MS then hello(target, true) end
end

-- Definitions load incrementally across ticks; the integrity handshake is
-- deferred until the registry hash exists.
local pendingHelloPlayer = nil

local function onDefinitionsLoaded()
    local player = pendingHelloPlayer
    pendingHelloPlayer = nil
    if player then hello(player) end
end

local function startCatalogPrewarm(player)
    local CatalogIndex = require("KnoxBuildworks/UI/CatalogIndex")
    CatalogIndex.prewarm(player)
end

local function onCreatePlayer(index, player)
    if KBW.sandboxValue("KnoxBuildworks.EnablePlanningMode", true) ~= true then
        Blueprints.setActive(player, nil)
        local Planner = require("KnoxBuildworks/Planning/Planner")
        Planner.cancelCursor(player)
    end
    PinnedRecipes.ensurePanel()
    if KBW.Runtime.loaded then
        hello(player)
        startCatalogPrewarm(player)
    else
        pendingHelloPlayer = player
        Loader.startAsync(function ()
            onDefinitionsLoaded()
            startCatalogPrewarm(player)
        end)
    end
end

local function refreshPlanningUI()
    local GhostRenderer = require("KnoxBuildworks/Planning/GhostRenderer")
    GhostRenderer.clearCache()
    if KBWPlanningMode and KBWPlanningMode.instance and KBWPlanningMode.instance.refreshBlueprints then
        KBWPlanningMode.instance:refreshBlueprints()
    end
end

local function refreshBuildableRuleConsumers()
    local CatalogIndex = require("KnoxBuildworks/UI/CatalogIndex")
    CatalogIndex.invalidate()
    PinnedRecipes.invalidate()
    if KBWCatalog and KBWCatalog.instance then
        local catalog = KBWCatalog.instance
        catalog.selectionStatusCache = nil
        catalog:refreshCategories()
        catalog:refreshFilterOptions()
        catalog:refreshCompactGroups()
        catalog:refreshGrid()
    end
    if KBWPlanningMode and KBWPlanningMode.instance then
        local planning = KBWPlanningMode.instance
        local panel = planning.catalogPanel
        if panel and panel.refreshCategories then panel:refreshCategories() end
        if panel and panel.refreshCatalog then panel:refreshCatalog() end
    end
    if KBWBuildableEditor and KBWBuildableEditor.instance and KBWBuildableEditor.instance.onRulesSync then
        KBWBuildableEditor.instance:onRulesSync(BuildableRules.getDocument(), BuildableRules.revision)
    end
end

BuildableRules.addListener(refreshBuildableRuleConsumers)

-- Small server-echoed blueprint deltas (edits made by other players).
---@class KBW.BLUEPRINT_DELTASModule
---@type KBW.BLUEPRINT_DELTASModule
local BLUEPRINT_DELTAS = {
    BPAddPlacement = true,
    BPRemovePlacement = true,
    BPAddRoom = true,
    BPRemoveRoom = true,
    BPUpdateRoom = true,
    BPSetGatherArea = true,
    BPMove = true,
    BPRename = true,
    BPSetLevel = true,
    BPSetAccess = true
}

local function onServerCommand(module, command, args)
    if module ~= KBW.NETWORK_MODULE then return end
    args = args or {}
    if command == "Integrity" then
        helloPlayer = nil
        local message = args.message
        if args.reason == "match" then
            message = getText("IGUI_KBW_IntegrityMatch")
        elseif args.reason == "mismatch" then
            message = getText("IGUI_KBW_IntegrityMismatch", tostring(args.serverHash or "?"))
        end
        Integrity.setClient(args.allowed and "ok" or "mismatch", message or getText("IGUI_KBW_IntegrityPending"))
    elseif command == "BPSyncAll" then
        Blueprints.applySync(args.items or {}, true)
        refreshPlanningUI()
    elseif command == "BPSync" then
        if args.item and args.item.id then
            Blueprints.applySync({ [tostring(args.item.id)] = args.item }, false)
            refreshPlanningUI()
        end
    elseif command == "BPForget" then
        Blueprints.forget(args.id)
        refreshPlanningUI()
    elseif BLUEPRINT_DELTAS[command] then
        Blueprints.applyRemoteDelta(command, args)
        refreshPlanningUI()
    elseif command == "BuildableRulesSync" then
        BuildableRules.applySync(args.document or {}, args.revision)
    elseif command == "BuildableRulesError" then
        if KBWBuildableEditor and KBWBuildableEditor.instance and KBWBuildableEditor.instance.onRulesError then
            KBWBuildableEditor.instance:onRulesError(args.code, args.errors or {}, args.revision)
        end
    end
end

local function onKeyPressed(key)
    if key == (Options:getOption("OpenCatalog"):getValue()) and getPlayer() then Catalog.open(getPlayer()) end
end

local function unwrapInventoryItem(entry)
    if not entry then return nil end
    if entry.getFullType then return entry end
    if type(entry) == "table" and entry.items then
        for itemIndex = 1, #entry.items do
            local item = entry.items[itemIndex]
            if item and item.getFullType then return item end
        end
    end
    return nil
end

local function importBlueprintItem(player, item)
    local blueprint = Blueprints.importBlueprintItem(player, item)
    if not blueprint then
        if HaloTextHelper and HaloTextHelper.addBadText then
            HaloTextHelper.addBadText(player, getText("IGUI_KBW_BlueprintImportFailed"))
        end
        return
    end
    if HaloTextHelper and HaloTextHelper.addText then
        HaloTextHelper.addText(player, getText("IGUI_KBW_PickBlueprintOrigin"))
    end
    -- Imported blueprints land wherever the player stands; let them pick the
    -- real origin with the cursor right away
    local Planner = require("KnoxBuildworks/Planning/Planner")
    Planner.beginMoveBlueprint(player, blueprint.id)
end

local function exportBlueprintToItem(player, item, blueprintId)
    local blueprint = Blueprints.get(player, blueprintId)
    if not blueprint then return end
    Blueprints.writeToItem(item, blueprint)
    if HaloTextHelper and HaloTextHelper.addText then
        HaloTextHelper.addText(player, getText("IGUI_KBW_BlueprintExportedToItem"))
    end
end

local function draftBlueprintFromPaper(player, paperItem, blueprintId)
    local blueprint = Blueprints.get(player, blueprintId)
    if not blueprint then return end
    local container = paperItem:getContainer() or player:getInventory()
    if sendRemoveItemFromContainer then sendRemoveItemFromContainer(container, paperItem) end
    container:Remove(paperItem)
    local item = player:getInventory():AddItem(Blueprints.ITEM_TYPE)
    if not item then return end
    Blueprints.writeToItem(item, blueprint)
    if HaloTextHelper and HaloTextHelper.addText then
        HaloTextHelper.addText(player, getText("IGUI_KBW_BlueprintExportedToItem"))
    end
end

local function addBlueprintChoices(context, parentOption, player, item, callback)
    local blueprints = Blueprints.list(player)
    if #blueprints == 0 then
        parentOption.notAvailable = true
        return
    end
    local submenu = ISContextMenu:getNew(context)
    context:addSubMenu(parentOption, submenu)
    for blueprintIndex = 1, #blueprints do
        local blueprint = blueprints[blueprintIndex]
        submenu:addOption(tostring(blueprint.name or blueprint.id), player, callback, item, blueprint.id)
    end
end

local function isPlainPaper(item)
    return item:getFullType() == "Base.SheetPaper2"
end

local function inventoryContextMenu(playerNum, context, items)
    local player = getSpecificPlayer(playerNum)
    if not player then return end
    items = items or {}
    for itemIndex = 1, #items do
        local item = unwrapInventoryItem(items[itemIndex])
        if item and item:getFullType() == Blueprints.ITEM_TYPE then
            if Blueprints.readBlueprintItem(item) then
                context:addOption(getText("IGUI_KBW_ImportBlueprint"), player, importBlueprintItem, item)
            end
            local exportOption = context:addOption(getText("IGUI_KBW_ExportBlueprintToItem"), player, nil)
            addBlueprintChoices(context, exportOption, player, item, exportBlueprintToItem)
            return
        end
        if item and isPlainPaper(item) then
            local draftOption = context:addOption(getText("IGUI_KBW_DraftBlueprint"), player, nil)
            addBlueprintChoices(context, draftOption, player, item, draftBlueprintFromPaper)
            return
        end
    end
end

local POINT_LIGHT_SWITCH_IDS = {
    ["kbw.vanillaexpanded.lighting.indoor.light_switch"] = true,
    ["kbw.vanillaexpanded.lighting.indoor.light_switch_alternate"] = true
}

local function kbwPointLightSwitch(worldObjects)
    local visitedSquares = {}
    worldObjects = worldObjects or {}
    for worldIndex = 1, #worldObjects do
        local worldObject = worldObjects[worldIndex]
        local square = worldObject and worldObject.getSquare and worldObject:getSquare() or nil
        local squareKey = square and tostring(square) or nil
        if square and not visitedSquares[squareKey] then
            visitedSquares[squareKey] = true
            local objects = square:getObjects()
            for objectIndex = 0, objects:size() - 1 do
                local object = objects:get(objectIndex)
                local data = object and object.getModData and object:getModData() or nil
                local kbw = data and data.KBW or nil
                if kbw and POINT_LIGHT_SWITCH_IDS[tostring(kbw.buildableId)] and object.getLightSourceRadius
                    and object:getLightSourceRadius() > 0 then
                    return object
                end
            end
        end
    end
    return nil
end

-- Player-built switches use a bounded thumpable point light instead of a
-- native room switch. Native room switches depend on map-authored room bounds,
-- which can be absent (no light) or cover an oversized custom structure after
-- an MP chunk reload. The vanilla timed action still owns synchronization.
local function lightSwitchContextMenu(playerNum, context, worldObjects, test)
    if test and ISWorldObjectContextMenu.Test then return true end
    local lightSwitch = kbwPointLightSwitch(worldObjects)
    if not lightSwitch then return false end
    if test then return ISWorldObjectContextMenu.setTest() end
    local label = lightSwitch:isLightSourceOn() and getText("ContextMenu_Turn_Off")
        or getText("ContextMenu_Turn_On")
    local option = context:addGetUpOption(
        label, lightSwitch, ISWorldObjectContextMenu.onToggleThumpableLight, playerNum
    )
    option.iconTexture = getTexture("Item_LightBulb")
    return true
end

Events.OnGameBoot.Add(function ()
        if not KBW.Runtime.loaded then Loader.startAsync() end
    end)
Events.OnCreatePlayer.Add(onCreatePlayer)
Events.OnServerCommand.Add(onServerCommand)
Events.OnKeyPressed.Add(onKeyPressed)
Events.OnPlayerUpdate.Add(retryIntegrityHandshake)
Events.OnFillInventoryObjectContextMenu.Add(inventoryContextMenu)
Events.OnFillWorldObjectContextMenu.Add(lightSwitchContextMenu)
return true
