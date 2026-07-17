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

return Overrides
