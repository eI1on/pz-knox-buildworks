---Overrides provides the Knox Buildworks data-driven definition layer.
local KBW = require("KnoxBuildworks/Core")
local SafeJSON = require("KnoxBuildworks/Util/SafeJSON")
local TableUtil = require("KnoxBuildworks/Util/Table")
local Hash = require("KnoxBuildworks/Util/Hash")
local Log = require("KnoxBuildworks/Log")

---@class KBW.OverridesModule
---@type KBW.OverridesModule
local Overrides = {}

-- Returns the override map plus the hash of the raw file text; the hash feeds
-- the registry integrity hash so client/server overrides must match too.
function Overrides.load()
    local reader = getFileReader(KBW.OVERRIDE_PATH, false)
    if not reader then return {}, nil end
    local lines, line = {}, reader:readLine()
    while line do
        lines[#lines + 1] = line
        line = reader:readLine()
    end
    reader:close()
    local text = table.concat(lines, "\n")
    if text == "" then return {}, nil end
    local data, err = SafeJSON.decode(text)
    if not data then
        Log:error("Invalid override file: %s", err)
        return {}, nil
    end
    return data.buildables or data, Hash.string(text)
end

---@param definition KBW.BuildableDefinition
function Overrides.apply(definition, all)
    local override = all[definition.id]
    return override and TableUtil.merge(definition, override) or definition
end

-- Buildable ids are unique, so a companion mod cannot restate a buildable
-- another mod already owns. A `patches` map lets it amend one instead, which is
-- how the vanilla add-on re-files vanilla entries into its own categories.
-- Collected from every bundle before any definition is normalized, so this does
-- not depend on mod load order.
---@param patches table<string, table>
---@param bundle table
---@param source string
function Overrides.collect(patches, bundle, source)
    for id, patch in pairs(bundle.patches or {}) do
        if type(patch) ~= "table" then
            Log:error("Patch for '%s' in %s must be an object; skipped", tostring(id), tostring(source))
        elseif patches[id] then
            patches[id] = TableUtil.merge(patches[id], patch)
        else
            patches[id] = patch
        end
    end
end

-- Applied before the player's own overrides file, so a player can still
-- override whatever a mod patched.
---@param definition KBW.BuildableDefinition
---@param patches table<string, table>
function Overrides.applyPatch(definition, patches)
    local patch = patches[definition.id]
    return patch and TableUtil.merge(definition, patch) or definition
end

return Overrides
