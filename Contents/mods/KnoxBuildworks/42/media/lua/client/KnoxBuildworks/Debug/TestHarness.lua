--- Test Runner harness: tests are step queues run on OnTick under a time budget.
-- No pcall: a step that raised leaves inStep set (watchdog), and the engine's
-- Lua error counter catches errors from UI callbacks.
if not isDebugEnabled() then return end

local JSON = require("ElyonLib/FileUtils/JSON")
local SafeJSON = require("KnoxBuildworks/Util/SafeJSON")

---@class KBW.TestHarnessModule
local Harness = {
    suites = {},
    suiteOrder = {},
    run = nil,
    tickNumber = 0,
    listeners = {},
    REPORT_PATH = "KnoxBuildworks/tests/report-latest.txt",
    RESULTS_PATH = "KnoxBuildworks/tests/results.txt",
    TICK_BUDGET_MS = 8,
    DEFAULT_TIMEOUT_MS = 2000
}

local storedResults = nil

local function nowMs()
    return getTimestampMs()
end

local function errorCount()
    return getLuaDebuggerErrorCount and getLuaDebuggerErrorCount() or 0
end

local function lastErrors(since)
    if not getLuaDebuggerErrors then return "" end
    local errors = getLuaDebuggerErrors()
    local total = errors:size()
    local first = math.max(0, total - math.max(1, since))
    local lines = {}
    for index = first, total - 1 do
        local text = tostring(errors:get(index))
        local cut = string.find(text, "\n", 1, true)
        lines[#lines + 1] = cut and string.sub(text, 1, cut - 1) or text
    end
    return table.concat(lines, " | ")
end

-- SUITES -----------------------------------------------------------------

---@param suite table { id, titleKey, descriptionKey, order, collect(ctx) -> tests[] }
function Harness.registerSuite(suite)
    if not Harness.suites[suite.id] then Harness.suiteOrder[#Harness.suiteOrder + 1] = suite.id end
    Harness.suites[suite.id] = suite
    table.sort(Harness.suiteOrder, function (a, b)
        local left, right = Harness.suites[a], Harness.suites[b]
        if (left.order or 0) ~= (right.order or 0) then return (left.order or 0) < (right.order or 0) end
        return a < b
    end)
end

function Harness.addListener(callback)
    Harness.listeners[#Harness.listeners + 1] = callback
end

function Harness.removeListener(callback)
    for index = #Harness.listeners, 1, -1 do
        if Harness.listeners[index] == callback then table.remove(Harness.listeners, index) end
    end
end

local function notify(event, payload)
    for index = 1, #Harness.listeners do
        Harness.listeners[index](event, payload)
    end
end

-- TEST HANDLE -------------------------------------------------------------

---@class KBW.TestHandle
local Test = {}
Test.__index = Test

local function newTest(spec, suite, ctx)
    local t = setmetatable({}, Test)
    t.id = spec.id
    t.name = spec.name or spec.id
    t.group = spec.group or ""
    t.suiteId = suite.id
    t.spec = spec
    t.ctx = ctx
    t.queue = { spec.run }
    t.inserted = nil
    t.gate = nil
    t.cleanups = {}
    t.failures = {}
    t.notes = {}
    t.status = "pending"
    return t
end

--- Queues fn to run after the current step (and after any gate).
function Test:next(fn)
    self.inserted = self.inserted or {}
    self.inserted[#self.inserted + 1] = fn
    return self
end

--- Holds the next step until predicate(t) is true; fails after timeoutMs.
function Test:waitUntil(predicate, timeoutMs, message)
    self.gate = {
        predicate = predicate,
        deadline = nowMs() + (timeoutMs or Harness.DEFAULT_TIMEOUT_MS),
        message = message or "timed out"
    }
    return self
end

--- Holds the next step until `count` further game ticks have started.
function Test:waitTicks(count)
    local target = Harness.tickNumber + math.max(1, count or 1)
    return self:waitUntil(function ()
        return Harness.tickNumber >= target
    end, 60000, "tick wait")
end

--- Registers a cleanup; cleanups run last-in first-out whatever the result.
function Test:cleanup(fn)
    self.cleanups[#self.cleanups + 1] = fn
    return self
end

function Test:note(message)
    self.notes[#self.notes + 1] = tostring(message)
end

--- Soft assertion: records the failure and keeps running.
function Test:check(condition, message)
    if not condition then self.failures[#self.failures + 1] = tostring(message or "check failed") end
    return condition and true or false
end

function Test:equal(actual, expected, message)
    return self:check(
        actual == expected,
        tostring(message or "values differ") .. " (expected "
            .. tostring(expected) .. ", got "
            .. tostring(actual) .. ")"
    )
end

--- Hard failure: stops the remaining steps (cleanups still run).
function Test:fail(message)
    self.failures[#self.failures + 1] = tostring(message or "failed")
    self.queue, self.inserted, self.gate = {}, nil, nil
    self.aborted = true
end

--- Ends the test as skipped (cleanups still run).
function Test:skip(message)
    self.skipReason = tostring(message or "skipped")
    self.queue, self.inserted, self.gate = {}, nil, nil
    self.aborted = true
end

-- RESULT STORE ------------------------------------------------------------

local function readText(path)
    local reader = getFileReader(path, false)
    if not reader then return nil end
    local lines, line = {}, reader:readLine()
    while line do
        lines[#lines + 1] = line
        line = reader:readLine()
    end
    reader:close()
    return table.concat(lines, "\n")
end

local function writeText(path, text)
    local writer = getFileWriter(path, true, false)
    if not writer then return false end
    writer:write(text)
    writer:close()
    return true
end

--- Last recorded result per test id across runs (status, message, time).
function Harness.storedResults()
    if storedResults then return storedResults end
    storedResults = {}
    local text = readText(Harness.RESULTS_PATH)
    local data = text and SafeJSON.decode(text) or nil
    if type(data) == "table" and data.version == 1 and type(data.results) == "table" then
        storedResults = data.results
    end
    return storedResults
end

function Harness.saveResults()
    writeText(Harness.RESULTS_PATH, JSON.stringify({ version = 1, results = Harness.storedResults() }))
end

function Harness.clearStoredResults(ids)
    local stored = Harness.storedResults()
    if not ids then
        storedResults = {}
    else
        for index = 1, #ids do
            stored[ids[index]] = nil
        end
    end
    Harness.saveResults()
end

-- RUN LOOP ----------------------------------------------------------------

local function summary(run)
    local counts = { passed = 0, failed = 0, skipped = 0, pending = 0 }
    for index = 1, #run.tests do
        local status = run.tests[index].status
        if status == "running" then status = "pending" end
        counts[status] = (counts[status] or 0) + 1
    end
    return counts
end
Harness.summary = summary

local function resultMessage(t)
    if t.skipReason then return t.skipReason end
    if #t.failures > 0 then return table.concat(t.failures, "; ") end
    return table.concat(t.notes, "; ")
end

local function finishTest(run, t)
    if #t.failures > 0 then
        t.status = "failed"
    elseif t.skipReason then
        t.status = "skipped"
    else
        t.status = "passed"
    end
    t.message = resultMessage(t)
    t.durationMs = nowMs() - (t.startedAt or nowMs())
    Harness.storedResults()[t.id] = { status = t.status, message = string.sub(t.message, 1, 400), suite = t.suiteId }
    run.index = run.index + 1
    run.current = nil
    notify("test", t)
end

local function beginCleanup(run, t)
    t.queue = {}
    t.inserted, t.gate = nil, nil
    for index = #t.cleanups, 1, -1 do
        t.queue[#t.queue + 1] = t.cleanups[index]
    end
    t.cleanups = {}
    t.cleaning = true
end

local function startTest(run)
    local t = run.tests[run.index]
    if not t then return nil end
    t.status = "running"
    t.startedAt = nowMs()
    t.errorBaseline = errorCount()
    run.current = t
    notify("start", t)
    return t
end

local function finishRun(run, reason)
    Events.OnTick.Remove(Harness.onTick)
    run.finished = true
    run.finishedAt = nowMs()
    run.stopReason = reason
    if Harness.run == run then Harness.run = nil end
    for index = 1, #run.teardowns do
        run.teardowns[index](run.ctx)
    end
    if run.ctx.finish then run.ctx.finish(run) end
    Harness.saveResults()
    Harness.writeReport(run)
    Harness.lastRun = run
    notify("finished", run)
end

--- Runs one queued step (or gate check) under the watchdog.
---@return string "continue" | "yield" | "done"
local function stepTest(run, t)
    if t.gate then
        run.inStep = t
        local satisfied = t.gate.predicate(t)
        run.inStep = nil
        if not satisfied then
            if nowMs() > t.gate.deadline then
                local message = t.gate.message
                t.gate = nil
                if t.cleaning then
                    t:note("cleanup " .. message)
                else
                    t:fail(message)
                end
            else
                return "yield"
            end
        else
            t.gate = nil
        end
        return "continue"
    end
    local step = table.remove(t.queue, 1)
    if not step then
        if not t.cleaning then
            local newErrors = errorCount() - (t.errorBaseline or 0)
            if newErrors > 0 then
                t:check(false, tostring(newErrors) .. " Lua error(s) while testing: " .. lastErrors(newErrors))
            end
            beginCleanup(run, t)
            if #t.queue > 0 then return "continue" end
        end
        finishTest(run, t)
        return "done"
    end
    run.inStep = t
    run.stepStartedAt = nowMs()
    step(t)
    run.inStep = nil
    if t.inserted then
        for index = #t.inserted, 1, -1 do
            table.insert(t.queue, 1, t.inserted[index])
        end
        t.inserted = nil
    end
    if t.aborted and not t.cleaning then
        t.aborted = false
        beginCleanup(run, t)
    end
    return "continue"
end

function Harness.onTick()
    Harness.tickNumber = Harness.tickNumber + 1
    local run = Harness.run
    if not run then
        Events.OnTick.Remove(Harness.onTick)
        return
    end
    -- Watchdog: the previous tick raised inside a step or gate.
    local crashed = run.inStep
    if crashed then
        run.inStep = nil
        local detail = lastErrors(1)
        if crashed.cleaning then
            crashed:note("cleanup raised a Lua error: " .. detail)
        else
            crashed.failures[#crashed.failures + 1] = "Lua error: " .. (detail ~= "" and detail or "see console.txt")
            crashed.errorBaseline = errorCount()
            beginCleanup(run, crashed)
        end
    end
    if run.stopRequested and not (run.current and run.current.cleaning) then
        if run.current then
            run.current:skip("stopped")
            beginCleanup(run, run.current)
        else
            return finishRun(run, "stopped")
        end
    end
    local deadline = nowMs() + (run.budgetMs or Harness.TICK_BUDGET_MS)
    while nowMs() < deadline do
        if run.stopRequested and not run.current then return finishRun(run, "stopped") end
        local t = run.current or startTest(run)
        if not t then return finishRun(run, "complete") end
        local outcome = stepTest(run, t)
        if outcome == "yield" then break end
        if t.yieldAfterStep then
            t.yieldAfterStep = nil
            break
        end
    end
    notify("progress", run)
end

--- Starts a run over the given suite ids.
---@param ctx      table          shared context: player, options, scope
---@param suiteIds string[]
---@param filter   function | nil optional filter(testSpec, suite) -> boolean
function Harness.start(ctx, suiteIds, filter)
    if Harness.run then return nil, "a run is already in progress" end
    local run = {
        ctx = ctx,
        tests = {},
        index = 1,
        teardowns = {},
        startedAt = nowMs(),
        suiteIds = suiteIds,
        budgetMs = ctx.budgetMs
    }
    ctx.run = run
    for suiteIndex = 1, #suiteIds do
        local suite = Harness.suites[suiteIds[suiteIndex]]
        if suite then
            if suite.setup then suite.setup(ctx) end
            if suite.teardown then run.teardowns[#run.teardowns + 1] = suite.teardown end
            local specs = suite.collect(ctx) or {}
            for specIndex = 1, #specs do
                local spec = specs[specIndex]
                if not filter or filter(spec, suite) then run.tests[#run.tests + 1] = newTest(spec, suite, ctx) end
            end
        end
    end
    Harness.run = run
    Events.OnTick.Remove(Harness.onTick)
    Events.OnTick.Add(Harness.onTick)
    notify("started", run)
    return run
end

function Harness.stop()
    if Harness.run then Harness.run.stopRequested = true end
end

function Harness.isRunning()
    return Harness.run ~= nil
end

-- REPORT ------------------------------------------------------------------

function Harness.writeReport(run)
    local counts = summary(run)
    local lines = {
        "Knox Buildworks test report",
        "Finished: " .. tostring(run.stopReason)
            .. " in " .. tostring(math.floor((run.finishedAt - run.startedAt) / 100) / 10)
            .. " s",
        string.format(
            "Passed %d, failed %d, skipped %d, not run %d", counts.passed, counts.failed, counts.skipped, counts.pending
        ),
        ""
    }
    local sections = { "failed", "skipped" }
    for sectionIndex = 1, #sections do
        local wanted = sections[sectionIndex]
        lines[#lines + 1] = "== " .. string.upper(wanted)
        for index = 1, #run.tests do
            local t = run.tests[index]
            if t.status == wanted then
                lines[#lines + 1] = "[" .. t.suiteId .. "] " .. t.name .. " (" .. t.id .. ")"
                lines[#lines + 1] = "    " .. tostring(t.message)
            end
        end
        lines[#lines + 1] = ""
    end
    writeText(Harness.REPORT_PATH, table.concat(lines, "\n"))
end

return Harness
