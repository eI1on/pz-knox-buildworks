--- Small helpers shared by the debug Test Runner suites.
if not isDebugEnabled() then return end

local Blueprints = require("KnoxBuildworks/Planning/Blueprints")

---@class KBW.TestUtilModule
local TestUtil = {}

-- UI state Knox persists on the player; UI tests snapshot and restore it.
TestUtil.PERSISTED_KEYS = { "KBW_UI", "KBW_BP_View" }

local function deepCopy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do
        result[key] = deepCopy(child)
    end
    return result
end
TestUtil.deepCopy = deepCopy

function TestUtil.snapshotUiState(player)
    local root = player:getModData()
    local snapshot = {}
    for index = 1, #TestUtil.PERSISTED_KEYS do
        local key = TestUtil.PERSISTED_KEYS[index]
        snapshot[key] = { present = root[key] ~= nil, value = deepCopy(root[key]) }
    end
    return snapshot
end

function TestUtil.restoreUiState(player, snapshot)
    if not player or not snapshot then return end
    local root = player:getModData()
    for key, entry in pairs(snapshot) do
        root[key] = entry.present and deepCopy(entry.value) or nil
    end
end

--- Ids of every blueprint currently in the store.
function TestUtil.blueprintIds()
    local ids = {}
    for id in pairs(Blueprints.sharedItems()) do
        ids[id] = true
    end
    return ids
end

--- Deletes blueprints created since `before` (a set from blueprintIds).
function TestUtil.deleteNewBlueprints(player, before)
    local removed = 0
    for id in pairs(Blueprints.sharedItems()) do
        if not before[id] and Blueprints.delete(player, id) then removed = removed + 1 end
    end
    return removed
end

--- Children of a panel that leave its bounds (visible ones only).
function TestUtil.childrenOutside(panel, slack)
    slack = slack or 1
    local outside = {}
    local children = panel:getChildren()
    for _, child in pairs(children or {}) do
        if child:isVisible() then
            local x, y = child:getX(), child:getY()
            if x < -slack or y < -slack or x + child:getWidth() > panel:getWidth() + slack
                or y + child:getHeight() > panel:getHeight() + slack then
                outside[#outside + 1] = tostring(child.Type or child.title or "child") .. " @"
                    .. math.floor(x) .. ","
                    .. math.floor(y) .. " "
                    .. math.floor(child:getWidth()) .. "x"
                    .. math.floor(child:getHeight())
            end
        end
    end
    return outside
end

--- Evenly spaced sample of at most `limit` entries (all when limit <= 0).
function TestUtil.sample(list, limit)
    if not limit or limit <= 0 or #list <= limit then return list end
    local result = {}
    local step = #list / limit
    for index = 1, limit do
        result[#result + 1] = list[math.floor((index - 1) * step) + 1]
    end
    return result
end

return TestUtil
