---Server provides the Knox Buildworks server layer.
local KBW = require("KnoxBuildworks/Core")
local Loader = require("KnoxBuildworks/Definitions/Loader")
local Registry = require("KnoxBuildworks/Definitions/Registry")
local Integrity = require("KnoxBuildworks/Network/Integrity")
local Blueprints = require("KnoxBuildworks/Planning/Blueprints")
local BlueprintFiles = require("KnoxBuildworks/Planning/BlueprintFiles")
local Log = require("KnoxBuildworks/Log")
require "KnoxBuildworks/BuildingObjects/KBWBuildingObject"

---@class KBW.ServerModule
---@type KBW.ServerModule
local Server = {}
local buildBatches = {}

local function batchKey(player, blueprintId)
    return tostring(player and player:getUsername() or "?") .. "|" .. tostring(blueprintId or "")
end

local function closePlayerBatches(player)
    local username = tostring(player and player:getUsername() or "?")
    for key, batch in pairs(buildBatches) do
        if batch.username == username then
            BlueprintFiles.endBatch(batch.id)
            buildBatches[key] = nil
        end
    end
end

local function handleBuildBatch(player, command, args)
    local blueprint = Blueprints.get(player, args.id)
    if not blueprint or not Blueprints.canBuild(player, blueprint) then return end
    local key = batchKey(player, args.id)
    if command == "BPBuildBatchStart" then
        if not buildBatches[key] then
            buildBatches[key] = { username = player:getUsername(), id = tostring(args.id) }
            BlueprintFiles.beginBatch(args.id)
        end
    elseif buildBatches[key] then
        BlueprintFiles.endBatch(args.id)
        buildBatches[key] = nil
    end
end

-- Every blueprint mutation a client can request. Each is applied
-- authoritatively (permissions / range / limits enforced inside
-- Blueprints.applyServerCommand). Accepted changes are echoed as the same
-- small delta to the other players who may view the blueprint; rejected ones
-- roll the sender back with the authoritative blueprint. Full blueprint
-- payloads only travel on login sync, creation, access changes and rollbacks.
local BLUEPRINT_COMMANDS = {
    BPCreate = true,
    BPDelete = true,
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

local function handleBlueprintCommand(player, command, args)
    -- Visibility can change under access edits, deletion and moving a plan's
    -- proximity radius; capture the previous nearby viewer set first.
    local viewersBefore = nil
    if command == "BPSetAccess" or command == "BPDelete" or command == "BPMove" then
        viewersBefore = Blueprints.onlineViewers(Blueprints.get(player, args.id))
    end
    local blueprint, applied = Blueprints.applyServerCommand(player, command, args)
    if not applied then
        -- Roll the sender's optimistic local change back.
        if blueprint then
            Blueprints.serverSyncTo(player, blueprint)
        elseif args.id then
            Blueprints.serverForgetTo(player, args.id)
        end
        return
    end
    if command == "BPCreate" then
        Blueprints.serverBroadcastFull(blueprint, player)
    elseif command == "BPDelete" then
        local sender = player:getUsername()
        for username, target in pairs(viewersBefore or {}) do
            if username ~= sender then Blueprints.serverForgetTo(target, args.id) end
        end
    elseif command == "BPSetAccess" or command == "BPMove" then
        Blueprints.serverBroadcastAccessChange(blueprint, viewersBefore or {}, player)
    else
        args.updated = blueprint.updated
        Blueprints.serverBroadcastDelta(blueprint, command, args, player)
    end
end

---@param command string
---@param player IsoPlayer
---@param args table
function Server.onClientCommand(module, command, player, args)
    if module ~= KBW.NETWORK_MODULE then return end
    args = args or {}
    if command == "Hello" then
        closePlayerBatches(player)
        local allowed = args.hash == Registry.hash
        local logMessage = allowed and "Definitions match server"
            or string.format("Definition mismatch: server %s, client %s", Registry.hash, tostring(args.hash))
        Integrity.setServer(player, allowed, logMessage)
        sendServerCommand(
            player, KBW.NETWORK_MODULE, "Integrity",
            { allowed = allowed, reason = allowed and "match" or "mismatch", serverHash = Registry.hash }
        )
        Log[allowed and "info" or "warning"](Log, "%s: %s", player:getUsername(), logMessage)
        -- Push every blueprint this player may see on connect.
        Blueprints.serverSyncAll(player)
    elseif command == "BPRequest" then
        Blueprints.serverSyncAll(player)
    elseif command == "BPBuildBatchStart" or command == "BPBuildBatchEnd" then
        if not Integrity.isAllowed(player) then return end
        handleBuildBatch(player, command, args)
    elseif BLUEPRINT_COMMANDS[command] then
        if not Integrity.isAllowed(player) then return end
        handleBlueprintCommand(player, command, args)
    end
end

Events.OnServerStarted.Add(function ()
    Loader.loadAll()
end)
Events.OnClientCommand.Add(Server.onClientCommand)
return Server

