---Profiler provides opt-in timing, counting, and memory instrumentation.
--
-- Every entry point is a no-op unless profiling is enabled, so production
-- sessions pay only a boolean check per call site. Enable it with the
-- "Performance profiling" mod option, or from the debug console with
--   KnoxBuildworks.Runtime.profile = true
-- and read results with
--   KnoxBuildworks.Profiler.report("console")
--
-- Timing pattern (zero allocation when disabled):
--   local t = Profiler.now()
--   ... work ...
--   Profiler.add("section.name", t)
local KBW = require("KnoxBuildworks/Core")
local Log = require("KnoxBuildworks/Log")

---@class KBW.ProfilerModule
---@type KBW.ProfilerModule
local Profiler = {}

local PREFIX = "[KBWPROF]"

local sections = {}
local sectionOrder = {}
local counters = {}
local counterOrder = {}

local function nowMs()
    return getTimestampMs and getTimestampMs() or 0
end

function Profiler.enabled()
    return KBW.Runtime.profile == true
end

---Returns the current timestamp when profiling is on, nil otherwise.
---Pass the result to Profiler.add; a nil start makes add a no-op.
---@return number|nil
function Profiler.now()
    if KBW.Runtime.profile ~= true then return nil end
    return nowMs()
end

---Accumulates elapsed time since startedMs under the given section name.
---@param name string
---@param startedMs number|nil
function Profiler.add(name, startedMs)
    if startedMs == nil then return end
    local elapsed = nowMs() - startedMs
    local section = sections[name]
    if not section then
        section = { totalMs = 0, calls = 0, maxMs = 0 }
        sections[name] = section
        sectionOrder[#sectionOrder + 1] = name
    end
    section.totalMs = section.totalMs + elapsed
    section.calls = section.calls + 1
    if elapsed > section.maxMs then section.maxMs = elapsed end
end

---Increments a named counter (call count, rows created, icons resolved...).
---@param name string
---@param amount number|nil
function Profiler.count(name, amount)
    if KBW.Runtime.profile ~= true then return end
    local value = counters[name]
    if value == nil then
        value = 0
        counterOrder[#counterOrder + 1] = name
    end
    counters[name] = value + (amount or 1)
end

---Records the current collectgarbage("count") value under a named counter.
---The unit is runtime-defined: kilobytes on stock Lua, but Kahlua reports a
---JVM-derived byte figure — treat it as a trend, not an absolute size.
---@param name string
function Profiler.mem(name)
    if KBW.Runtime.profile ~= true then return end
    if not collectgarbage then return end
    local kb = collectgarbage("count")
    if type(kb) ~= "number" then return end
    if counters[name] == nil then counterOrder[#counterOrder + 1] = name end
    counters[name] = math.floor(kb)
end

function Profiler.reset()
    sections = {}
    sectionOrder = {}
    counters = {}
    counterOrder = {}
end

---Logs every recorded section and counter. Safe to call when disabled or
---empty; it simply logs nothing.
---@param reason string|nil
function Profiler.report(reason)
    if #sectionOrder == 0 and #counterOrder == 0 then return end
    Log:info("%s ---- report (%s) ----", PREFIX, tostring(reason or "manual"))
    for orderIndex = 1, #sectionOrder do
        local name = sectionOrder[orderIndex]
        local section = sections[name]
        local avg = section.calls > 0 and (section.totalMs / section.calls) or 0
        Log:info(
            "%s %s: total %dms, calls %d, avg %.1fms, max %dms",
            PREFIX, name, section.totalMs, section.calls, avg, section.maxMs
        )
    end
    for orderIndex = 1, #counterOrder do
        local name = counterOrder[orderIndex]
        Log:info("%s %s = %d", PREFIX, name, counters[name] or 0)
    end
end

KBW.Profiler = Profiler

return Profiler
