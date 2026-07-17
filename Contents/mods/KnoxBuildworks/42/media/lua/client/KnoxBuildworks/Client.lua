---Client provides the Knox Buildworks client layer.
local KBW = require("KnoxBuildworks/Core")
local Loader = require("KnoxBuildworks/Definitions/Loader")
local Registry = require("KnoxBuildworks/Definitions/Registry")
local Integrity = require("KnoxBuildworks/Network/Integrity")
local Catalog = require("KnoxBuildworks/UI/Catalog")
local Options = require("KnoxBuildworks/Options")
local Blueprints = require("KnoxBuildworks/Planning/Blueprints")
require("KnoxBuildworks/Planning/Planner")
local PinnedRecipes = require("KnoxBuildworks/UI/PinnedRecipes")
require("KnoxBuildworks/UI/Sidebar")

local function hello(player)
    if isClient() then
        Integrity.setClient("pending", getText("IGUI_KBW_IntegrityPending"))
        sendClientCommand(player, KBW.NETWORK_MODULE, "Hello", { hash = Registry.hash })
    else
        Integrity.setClient("ok", getText("IGUI_KBW_IntegritySingleplayer"))
    end
end

-- Definitions load incrementally across ticks; the integrity handshake is
-- deferred until the registry hash exists.
local pendingHelloPlayer = nil

local function onDefinitionsLoaded()
    local player = pendingHelloPlayer
    pendingHelloPlayer = nil
    if player then hello(player) end
end

local function onCreatePlayer(index, player)
    PinnedRecipes.ensurePanel()
    if KBW.Runtime.loaded then
        hello(player)
    else
        pendingHelloPlayer = player
        Loader.startAsync(onDefinitionsLoaded)
    end
end

local function refreshPlanningUI()
    local GhostRenderer = require("KnoxBuildworks/Planning/GhostRenderer")
    GhostRenderer.clearCache()
    if KBWPlanningMode and KBWPlanningMode.instance and KBWPlanningMode.instance.refreshBlueprints then
        KBWPlanningMode.instance:refreshBlueprints()
    end
end

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
        local message = args.message
        if args.reason == "match" then
            message = getText("IGUI_KBW_IntegrityMatch")
        elseif args.reason == "mismatch" then
            message = string.format(getText("IGUI_KBW_IntegrityMismatch"), tostring(args.serverHash or "?"))
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
    end
end

local function onKeyPressed(key)
    if key == (Options:getOption("OpenCatalog"):getValue()) and getPlayer() then Catalog.open(getPlayer()) end
end

-- Nearby shared blueprints are discovery-scoped. Refresh after meaningful
-- movement so the server can both add newly nearby plans and prune plans that
-- have left this client's vicinity without polling every tick.
local discoveryState = {}
local DISCOVERY_MOVE_TILES = 30

local function refreshNearbyBlueprints(player)
    if not isClient() or not player or not sendClientCommand then return end
    local playerIndex = player.getPlayerNum and player:getPlayerNum() or 0
    local x = math.floor(player:getX())
    local y = math.floor(player:getY())
    local previous = discoveryState[playerIndex]
    local moved = previous == nil or math.abs(x - previous.x) >= DISCOVERY_MOVE_TILES
        or math.abs(y - previous.y) >= DISCOVERY_MOVE_TILES
    if not moved then return end
    discoveryState[playerIndex] = { x = x, y = y }
    sendClientCommand(player, KBW.NETWORK_MODULE, "BPRequest", {})
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

Events.OnGameBoot.Add(function ()
        if not KBW.Runtime.loaded then Loader.startAsync() end
    end)
Events.OnCreatePlayer.Add(onCreatePlayer)
Events.OnServerCommand.Add(onServerCommand)
Events.OnKeyPressed.Add(onKeyPressed)
Events.OnPlayerUpdate.Add(refreshNearbyBlueprints)
Events.OnFillInventoryObjectContextMenu.Add(inventoryContextMenu)
return true

