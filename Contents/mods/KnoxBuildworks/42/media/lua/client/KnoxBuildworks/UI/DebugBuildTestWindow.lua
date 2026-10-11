if not isDebugEnabled() then return end

require("ISUI/ISCollapsableWindow")
require("ISUI/ISScrollingListBox")
require("ISUI/ISComboBox")
require("ISUI/ISButton")
require("ISUI/ISTickBox")
require("ISUI/ISRichTextPanel")

local Harness = require("KnoxBuildworks/Debug/TestHarness")
local BuildTestRunner = require("KnoxBuildworks/Debug/BuildTestRunner")
local Registry = require("KnoxBuildworks/Definitions/Registry")
require("KnoxBuildworks/Debug/Suites/DefinitionSuite")
require("KnoxBuildworks/Debug/Suites/CatalogSuite")
require("KnoxBuildworks/Debug/Suites/PlanningSuite")
require("KnoxBuildworks/Debug/Suites/BuildSuite")
local I18n = require("KnoxBuildworks/I18n")
local Theme = require("KnoxBuildworks/UI/Theme")
local VirtualListBox = require("KnoxBuildworks/UI/VirtualListBox")

---Debug Test Runner window (Menu Dock > Tests).
---@class KBWDebugBuildTestWindow: ISCollapsableWindow
KBWDebugBuildTestWindow = ISCollapsableWindow:derive("KBWDebugBuildTestWindow")
KBWDebugBuildTestWindow.instance = nil

local PADDING = 10
local GAP = 7
local CONTROL_H = 26
local ACTION_H = 30
local ROW_H = 44
local REFRESH_MS = 500
local QUICK_UI_SAMPLE = 150

local settings = {
    suites = { definitions = true, catalog = true, planning = true, build = false, planqueue = false },
    category = "All",
    subcategory = "All",
    mode = BuildTestRunner.MODE_INSTANT,
    fastActions = true,
    fullSweep = false,
    spawn = true,
    keep = false,
    pause = false,
    finishes = "sample",
    gap = 2,
    resultFilter = "All",
    origin = nil
}

local function comboData(combo)
    return combo and combo:getOptionData(combo.selected) or nil
end

local function chooseComboData(combo, wanted)
    for optionIndex = 1, #combo.options do
        if combo:getOptionData(optionIndex) == wanted then
            combo.selected = optionIndex
            return
        end
    end
    combo.selected = 1
end

local function newCombo(parent, callback)
    local combo = ISComboBox:new(0, 0, 200, CONTROL_H, parent, callback)
    combo:initialise()
    Theme.applyCombo(combo)
    parent:addChild(combo)
    return combo
end

local function newButton(parent, text, callback, primary)
    local button = ISButton:new(0, 0, 100, ACTION_H, text, parent, callback)
    button:initialise()
    button:instantiate()
    Theme.applyActionButton(button, true, primary == true)
    parent:addChild(button)
    return button
end

local function statusColor(status)
    if status == "passed" then return Theme.good end
    if status == "failed" then return Theme.bad end
    if status == "skipped" then return Theme.warn end
    if status == "running" then return Theme.accent end
    return Theme.textMuted
end

local function statusLabel(status)
    if status == "passed" then return getText("IGUI_KBW_DebugTestPassed") end
    if status == "failed" then return getText("IGUI_KBW_DebugTestFailed") end
    if status == "skipped" then return getText("IGUI_KBW_DebugTestSkipped") end
    if status == "running" then return getText("IGUI_KBW_DebugTestRunningStatus") end
    return getText("IGUI_KBW_DebugTestPending")
end

local function firstLine(text)
    text = tostring(text or "")
    local cut = string.find(text, "\n", 1, true)
    return cut and string.sub(text, 1, cut - 1) or text
end

-- Rich text treats < and > as markup.
local function plain(text)
    text = string.gsub(tostring(text or ""), "<", "(")
    return (string.gsub(text, ">", ")"))
end

function KBWDebugBuildTestWindow:createChildren()
    ISCollapsableWindow.createChildren(self)

    self.suiteBox = ISTickBox:new(0, 0, 250, 20, "", self, self.onSuiteToggled)
    self.suiteBox:initialise()
    self.suiteBox.autoWidth = false
    Theme.applyTickBox(self.suiteBox)
    self:addChild(self.suiteBox)
    self.suiteIds = {}
    for index = 1, #Harness.suiteOrder do
        local suiteId = Harness.suiteOrder[index]
        local suite = Harness.suites[suiteId]
        self.suiteIds[#self.suiteIds + 1] = suiteId
        self.suiteBox:addOption(getText(suite.titleKey), suiteId)
        self.suiteBox:setSelected(#self.suiteIds, settings.suites[suiteId] == true)
    end

    self.categoryCombo = newCombo(self, self.onScopeChanged)
    self.subcategoryCombo = newCombo(self, self.onScopeChanged)
    self.modeCombo = newCombo(self, self.onModeChanged)
    self.modeCombo:addOptionWithData(getText("IGUI_KBW_DebugTestModeInstant"), BuildTestRunner.MODE_INSTANT)
    self.modeCombo:addOptionWithData(getText("IGUI_KBW_DebugTestModeWalk"), BuildTestRunner.MODE_WALK)
    chooseComboData(self.modeCombo, settings.mode)
    self.finishCombo = newCombo(self, self.onFinishModeChanged)
    self.finishCombo:addOptionWithData(getText("IGUI_KBW_DebugTestFinishNone"), "none")
    self.finishCombo:addOptionWithData(getText("IGUI_KBW_DebugTestFinishSample"), "sample")
    self.finishCombo:addOptionWithData(getText("IGUI_KBW_DebugTestFinishAll"), "all")
    chooseComboData(self.finishCombo, settings.finishes)
    self.gapCombo = newCombo(self, self.onGapChanged)
    for gap = 1, 4 do self.gapCombo:addOptionWithData(getText("IGUI_KBW_DebugTestGap", gap), gap) end
    chooseComboData(self.gapCombo, settings.gap)

    self.optionBox = ISTickBox:new(0, 0, 250, 20, "", self, self.onOptionToggled)
    self.optionBox:initialise()
    self.optionBox.autoWidth = false
    Theme.applyTickBox(self.optionBox)
    self:addChild(self.optionBox)
    self.optionBox:addOption(getText("IGUI_KBW_DebugTestFastActions"), "fastActions")
    self.optionBox:addOption(getText("IGUI_KBW_DebugTestFullSweep"), "fullSweep")
    self.optionBox:addOption(getText("IGUI_KBW_DebugTestSpawn"), "spawn")
    self.optionBox:addOption(getText("IGUI_KBW_DebugTestKeep"), "keep")
    self.optionBox:addOption(getText("IGUI_KBW_DebugTestPause"), "pause")
    self.optionKeys = { "fastActions", "fullSweep", "spawn", "keep", "pause" }
    for index = 1, #self.optionKeys do
        self.optionBox:setSelected(index, settings[self.optionKeys[index]] == true)
    end

    self.areaButton = newButton(self, getText("IGUI_KBW_DebugTestSetArea"), self.onSetArea, false)
    self.runButton = newButton(self, getText("IGUI_KBW_DebugTestRun"), self.onRun, true)
    self.rerunButton = newButton(self, getText("IGUI_KBW_DebugTestRunFailed"), self.onRunFailed, false)
    self.stopButton = newButton(self, getText("IGUI_KBW_DebugTestStop"), self.onStop, false)
    self.prepareButton = newButton(self, getText("IGUI_KBW_DebugTestPrepare"), self.onPrepare, false)
    self.clearButton = newButton(self, getText("IGUI_KBW_DebugTestClear"), self.onClear, false)
    self.passButton = newButton(self, getText("IGUI_KBW_DebugTestReviewPass"), self.onReviewPass, true)
    self.failButton = newButton(self, getText("IGUI_KBW_DebugTestReviewFail"), self.onReviewFail, false)

    self.resultCombo = newCombo(self, self.onResultFilter)
    self.resultCombo:addOptionWithData(getText("IGUI_KBW_DebugTestAllResults"), "All")
    self.resultCombo:addOptionWithData(getText("IGUI_KBW_DebugTestFailed"), "failed")
    self.resultCombo:addOptionWithData(getText("IGUI_KBW_DebugTestSkipped"), "skipped")
    self.resultCombo:addOptionWithData(getText("IGUI_KBW_DebugTestPassed"), "passed")
    self.resultCombo:addOptionWithData(getText("IGUI_KBW_DebugTestPending"), "pending")
    chooseComboData(self.resultCombo, settings.resultFilter)

    self.resultList = VirtualListBox:new(0, 0, 300, 300)
    self.resultList:initialise()
    self.resultList:instantiate()
    self.resultList.itemheight = ROW_H
    self.resultList.font = UIFont.Small
    self.resultList.drawBorder = true
    self.resultList.doDrawItem = self.drawResult
    self.resultList:setOnMouseDownFunction(self, self.onResultSelected)
    Theme.applyList(self.resultList)
    self:addChild(self.resultList)

    self.details = ISRichTextPanel:new(0, 0, 300, 300)
    self.details:initialise()
    self.details:instantiate()
    self.details.background = true
    self.details.backgroundColor = Theme.color(Theme.surface)
    self.details.borderColor = Theme.color(Theme.borderSoft)
    self.details.marginLeft, self.details.marginRight = 12, 12
    self.details.marginTop, self.details.marginBottom = 10, 10
    self.details.autosetheight = false
    self.details:addScrollBars()
    self:addChild(self.details)

    self.listener = function (event, payload) self:onHarnessEvent(event, payload) end
    Harness.addListener(self.listener)

    self:populateScope()
    self.dirty = true
    self:layout()
    self:refreshDetails()
end

-- SCOPE -------------------------------------------------------------------

function KBWDebugBuildTestWindow:populateScope()
    self.categoryCombo:clear()
    local categories = BuildTestRunner.categories(Registry:list())
    for index = 1, #categories do
        local value = categories[index]
        self.categoryCombo:addOptionWithData(value == "All" and getText("IGUI_KBW_AllCategories") or I18n.category(value), value)
    end
    chooseComboData(self.categoryCombo, settings.category)
    self:populateSubcategories()
end

function KBWDebugBuildTestWindow:populateSubcategories()
    self.subcategoryCombo:clear()
    local subcategories = BuildTestRunner.subcategories(Registry:list(), settings.category)
    for index = 1, #subcategories do
        local value = subcategories[index]
        self.subcategoryCombo:addOptionWithData(
            value == "All" and getText("IGUI_KBW_DebugTestAllSubcategories") or I18n.subcategory(value), value)
    end
    chooseComboData(self.subcategoryCombo, settings.subcategory)
end

function KBWDebugBuildTestWindow:onScopeChanged(combo)
    if combo == self.categoryCombo then
        settings.category = comboData(self.categoryCombo) or "All"
        settings.subcategory = "All"
        self:populateSubcategories()
    else
        settings.subcategory = comboData(self.subcategoryCombo) or "All"
    end
end

function KBWDebugBuildTestWindow:onModeChanged()
    settings.mode = comboData(self.modeCombo) or BuildTestRunner.MODE_INSTANT
end

function KBWDebugBuildTestWindow:onSuiteToggled(index, selected)
    local suiteId = self.suiteIds[index]
    if suiteId then settings.suites[suiteId] = selected == true end
end

function KBWDebugBuildTestWindow:onOptionToggled(index, selected)
    local key = self.optionKeys and self.optionKeys[index]
    if key then settings[key] = selected == true end
    if key == "fastActions" and Harness.isRunning() then self.player:setTimedActionInstantCheat(selected == true) end
end

function KBWDebugBuildTestWindow:onFinishModeChanged()
    settings.finishes = comboData(self.finishCombo) or "sample"
end

function KBWDebugBuildTestWindow:onGapChanged()
    settings.gap = comboData(self.gapCombo) or 2
end

---The review the running test is waiting on (pause after each build).
function KBWDebugBuildTestWindow:pendingReview()
    local run = Harness.run
    local review = run and run.ctx and run.ctx.review or nil
    if review and review.decision == nil then return review end
    return nil
end

function KBWDebugBuildTestWindow:onReviewPass()
    local review = self:pendingReview()
    if review then review.decision = "pass" end
end

function KBWDebugBuildTestWindow:onReviewFail()
    local review = self:pendingReview()
    if review then review.decision = "fail" end
end

function KBWDebugBuildTestWindow:onResultFilter()
    settings.resultFilter = comboData(self.resultCombo) or "All"
    self.dirty = true
end

function KBWDebugBuildTestWindow:onSetArea()
    local player = self.player
    settings.origin = { x = math.floor(player:getX()), y = math.floor(player:getY()), z = math.floor(player:getZ()) }
    self:refreshDetails()
end

-- RUNS --------------------------------------------------------------------

function KBWDebugBuildTestWindow:selectedSuiteIds()
    local ids = {}
    for index = 1, #self.suiteIds do
        if settings.suites[self.suiteIds[index]] then ids[#ids + 1] = self.suiteIds[index] end
    end
    return ids
end

function KBWDebugBuildTestWindow:newContext()
    local player = self.player
    local origin = settings.origin
        or { x = math.floor(player:getX()), y = math.floor(player:getY()), z = math.floor(player:getZ()) }
    local category, subcategory = settings.category, settings.subcategory
    local snapshot = BuildTestRunner.captureCharacter(player)
    local ctx = {
        player = player,
        origin = origin,
        characterSnapshot = snapshot,
        options = {
            mode = settings.mode,
            spawn = settings.spawn,
            keep = settings.keep,
            pause = settings.pause,
            finishes = settings.finishes,
            gap = settings.gap,
            rowWidth = 40,
            uiSampleLimit = settings.fullSweep and 0 or QUICK_UI_SAMPLE
        },
        matchesScope = function (testCategory, testSubcategory)
            return (category == "All" or tostring(testCategory) == category)
                and (subcategory == "All" or tostring(testSubcategory or "General") == subcategory)
        end
    }
    ctx.finish = function ()
        BuildTestRunner.cleanupSpawnedItems(player)
        BuildTestRunner.restoreCharacter(player, snapshot)
    end
    if settings.fastActions then player:setTimedActionInstantCheat(true) end
    return ctx
end

function KBWDebugBuildTestWindow:startRun(filter)
    local suites = self:selectedSuiteIds()
    if #suites == 0 then return self:refreshDetails(getText("IGUI_KBW_DebugTestNoSuites")) end
    local ctx = self:newContext()
    local run, reason = Harness.start(ctx, suites, filter)
    if not run then
        ctx.finish()
        return self:refreshDetails(tostring(reason))
    end
    if #run.tests == 0 then
        Harness.stop()
        return self:refreshDetails(getText("IGUI_KBW_DebugTestNothingToRun"))
    end
    self.shownRun = run
    self.dirty = true
end

function KBWDebugBuildTestWindow:onRun()
    self:startRun(nil)
end

function KBWDebugBuildTestWindow:onRunFailed()
    local stored = Harness.storedResults()
    self:startRun(function (spec)
        local result = stored[spec.id]
        return result ~= nil and result.status == "failed"
    end)
end

function KBWDebugBuildTestWindow:onStop()
    Harness.stop()
end

function KBWDebugBuildTestWindow:onClear()
    if Harness.isRunning() then return end
    Harness.clearStoredResults(nil)
    self.shownRun = nil
    self.dirty = true
    self:refreshDetails()
end

---Manual fallback: supply the selected build case and hand over the cursor.
function KBWDebugBuildTestWindow:onPrepare()
    local t = self:selectedTest()
    local testCase = t and t.spec and t.spec.testCase or nil
    if not testCase then return self:refreshDetails(getText("IGUI_KBW_DebugTestNoSelection")) end
    local ok, reason = BuildTestRunner.prepareManual(self.player, testCase)
    self:refreshDetails(ok and getText("IGUI_KBW_DebugTestPlaceNow") or reason)
end

function KBWDebugBuildTestWindow:onHarnessEvent(event, payload)
    if event == "started" then
        self.shownRun = payload
        self.dirty = true
    elseif event == "finished" then
        self.lastMessage = getText("IGUI_KBW_DebugTestReportSaved", Harness.REPORT_PATH)
        self.dirty = true
    elseif event == "test" then
        -- Rows draw status live; only a status filter rebuilds them.
        if settings.resultFilter ~= "All" then self.dirty = true end
        self.detailsDirty = true
    end
end

-- RESULTS -----------------------------------------------------------------

function KBWDebugBuildTestWindow:selectedTest()
    local row = self.resultList.items[self.resultList.selected]
    return row and row.item or nil
end

function KBWDebugBuildTestWindow:rebuildRows()
    local run = self.shownRun or Harness.run or Harness.lastRun
    local wanted = settings.resultFilter
    local selected = self:selectedTest()
    local rows = {}
    local selectedIndex = 0
    if run then
        for index = 1, #run.tests do
            local t = run.tests[index]
            local status = t.status == "running" and "pending" or t.status
            if wanted == "All" or status == wanted then
                rows[#rows + 1] = { name = t.name, test = t }
                if t == selected then selectedIndex = #rows end
            end
        end
    end
    local scroll = self.resultList:getYScroll()
    self.resultList:replaceItems(rows, "name", "test")
    if selectedIndex > 0 then
        self.resultList.selected = selectedIndex
        self.resultList:setYScroll(scroll)
    else
        self.resultList.selected = #rows > 0 and 1 or 0
    end
    self:refreshDetails()
end

function KBWDebugBuildTestWindow:drawResult(y, item, alt)
    local t = item.item
    if self.selected == item.index then
        self:drawRect(0, y, self.width, self.itemheight - 1, Theme.selected.a, Theme.selected.r, Theme.selected.g,
            Theme.selected.b)
    elseif alt then
        self:drawRect(0, y, self.width, self.itemheight - 1, 0.22, Theme.surfaceRaised.r, Theme.surfaceRaised.g,
            Theme.surfaceRaised.b)
    end
    self:drawRectBorder(0, y, self.width, self.itemheight - 1, Theme.borderSoft.a, Theme.borderSoft.r,
        Theme.borderSoft.g, Theme.borderSoft.b)
    local color = statusColor(t.status)
    self:drawRect(8, y + 9, 6, 6, 1, color.r, color.g, color.b)
    self:drawText(tostring(item.text), 22, y + 4, Theme.text.r, Theme.text.g, Theme.text.b, 1, UIFont.Small)
    local secondary = (t.message and t.message ~= "") and firstLine(t.message) or (t.suiteId .. " - " .. t.group)
    self:drawText(secondary, 22, y + 23, Theme.textMuted.r, Theme.textMuted.g, Theme.textMuted.b, 1, UIFont.Small)
    return y + self.itemheight
end

function KBWDebugBuildTestWindow:onResultSelected()
    self:refreshDetails()
end

function KBWDebugBuildTestWindow:progressText()
    local run = Harness.run or self.shownRun or Harness.lastRun
    if not run then return getText("IGUI_KBW_DebugTestIdle") end
    local counts = Harness.summary(run)
    local done = counts.passed + counts.failed + counts.skipped
    local text = getText("IGUI_KBW_DebugTestProgressLine", done, #run.tests, counts.passed, counts.failed, counts.skipped)
    if run.current then text = text .. "  |  " .. getText("IGUI_KBW_DebugTestRunningName", run.current.name) end
    return text
end

function KBWDebugBuildTestWindow:refreshDetails(message)
    if message then self.lastMessage = message end
    local t = self:selectedTest()
    local origin = settings.origin
    local lines = {}
    if t then
        lines[#lines + 1] = "<H1>" .. plain(t.name)
        lines[#lines + 1] = "<RGB:0.72,0.70,0.64>" .. plain(t.id)
        lines[#lines + 1] = " <LINE> <RGB:0.92,0.91,0.88>" .. getText("IGUI_KBW_DebugTestStatus") .. ": " .. statusLabel(t.status)
        lines[#lines + 1] = " <LINE> " .. getText("IGUI_KBW_DebugTestSuite") .. ": " .. plain(t.suiteId)
            .. (t.group ~= "" and (" - " .. plain(t.group)) or "")
        if t.durationMs then
            lines[#lines + 1] = " <LINE> " .. getText("IGUI_KBW_DebugTestDuration") .. ": " .. tostring(t.durationMs) .. " ms"
        end
        if t.message and t.message ~= "" then
            lines[#lines + 1] = " <LINE> <LINE> <H2>" .. getText("IGUI_KBW_DebugTestMessage") .. " <LINE> "
            local parts = {}
            for part in string.gmatch(t.message, "[^;]+") do parts[#parts + 1] = plain(part) end
            lines[#lines + 1] = table.concat(parts, " <LINE> ")
        end
    else
        lines[#lines + 1] = getText("IGUI_KBW_DebugTestIdle")
        for index = 1, #self.suiteIds do
            local suite = Harness.suites[self.suiteIds[index]]
            lines[#lines + 1] = " <LINE> <LINE> <H2>" .. getText(suite.titleKey) .. " <LINE> <RGB:0.72,0.70,0.64>"
                .. getText(suite.descriptionKey) .. " <RGB:0.92,0.91,0.88>"
        end
    end
    lines[#lines + 1] = " <LINE> <LINE> <RGB:0.64,0.63,0.60>" .. (origin
        and getText("IGUI_KBW_DebugTestArea", origin.x, origin.y, origin.z)
        or getText("IGUI_KBW_DebugTestAreaPlayer"))
    if self.lastMessage and self.lastMessage ~= "" then
        lines[#lines + 1] = " <LINE> <LINE> <RGB:0.95,0.75,0.40>" .. plain(self.lastMessage)
    end
    self.details.text = table.concat(lines, "")
    self.details:paginate()
    local running = Harness.isRunning()
    Theme.applyActionButton(self.runButton, not running, true)
    Theme.applyActionButton(self.rerunButton, not running, false)
    Theme.applyActionButton(self.stopButton, running, false)
    Theme.applyActionButton(self.clearButton, not running, false)
    Theme.applyActionButton(self.areaButton, not running, false)
    Theme.applyActionButton(self.prepareButton, not running and t ~= nil and t.spec and t.spec.testCase ~= nil, false)
end

-- LAYOUT ------------------------------------------------------------------

function KBWDebugBuildTestWindow:layout()
    local top = self:titleBarHeight() + PADDING
    local width = self.width - PADDING * 2
    local columnW = math.floor((width - GAP * 2) / 3)

    self.suiteBox:setX(PADDING)
    self.suiteBox:setY(top)
    self.suiteBox:setWidth(columnW)

    local middleX = PADDING + columnW + GAP
    self.categoryCombo:setX(middleX)
    self.categoryCombo:setY(top)
    self.categoryCombo:setWidth(columnW)
    self.subcategoryCombo:setX(middleX)
    self.subcategoryCombo:setY(top + CONTROL_H + GAP)
    self.subcategoryCombo:setWidth(columnW)
    self.modeCombo:setX(middleX)
    self.modeCombo:setY(top + (CONTROL_H + GAP) * 2)
    self.modeCombo:setWidth(columnW)
    self.finishCombo:setX(middleX)
    self.finishCombo:setY(top + (CONTROL_H + GAP) * 3)
    self.finishCombo:setWidth(columnW)
    self.gapCombo:setX(middleX)
    self.gapCombo:setY(top + (CONTROL_H + GAP) * 4)
    self.gapCombo:setWidth(columnW)

    local rightX = middleX + columnW + GAP
    self.optionBox:setX(rightX)
    self.optionBox:setY(top)
    self.optionBox:setWidth(self.width - PADDING - rightX)
    self.areaButton:setX(rightX)
    self.areaButton:setY(self.optionBox:getBottom() + GAP)
    self.areaButton:setWidth(self.width - PADDING - rightX)

    local headerBottom = math.max(self.suiteBox:getBottom(), self.gapCombo:getBottom(), self.areaButton:getBottom())
    local buttonsY = headerBottom + GAP * 2
    local buttons = { self.runButton, self.rerunButton, self.stopButton, self.prepareButton, self.clearButton }
    local filterW = math.max(150, math.floor(width * 0.18))
    local buttonW = math.floor((width - filterW - GAP * #buttons) / #buttons)
    local x = PADDING
    for index = 1, #buttons do
        local button = buttons[index]
        button:setX(x)
        button:setY(buttonsY)
        button:setWidth(buttonW)
        x = x + buttonW + GAP
    end
    self.resultCombo:setX(x)
    self.resultCombo:setY(buttonsY + math.floor((ACTION_H - CONTROL_H) / 2))
    self.resultCombo:setWidth(self.width - PADDING - x)

    self.reviewY = buttonsY + ACTION_H + GAP
    local reviewW = math.max(130, math.floor(width * 0.16))
    self.failButton:setX(self.width - PADDING - reviewW)
    self.failButton:setY(self.reviewY)
    self.failButton:setWidth(reviewW)
    self.passButton:setX(self.failButton:getX() - GAP - reviewW)
    self.passButton:setY(self.reviewY)
    self.passButton:setWidth(reviewW)
    self.progressY = self.reviewY + ACTION_H + GAP
    local bodyTop = self.progressY + getTextManager():getFontHeight(UIFont.Small) + GAP
    local bodyH = math.max(120, self.height - self:resizeWidgetHeight() - PADDING - bodyTop)
    local listW = math.floor((width - GAP) * 0.48)
    self.resultList:setX(PADDING)
    self.resultList:setY(bodyTop)
    self.resultList:setWidth(listW)
    self.resultList:setHeight(bodyH)
    self.details:setX(PADDING + listW + GAP)
    self.details:setY(bodyTop)
    self.details:setWidth(self.width - PADDING - self.details:getX())
    self.details:setHeight(bodyH)
    self.details:paginate()
    self.lastLayoutWidth, self.lastLayoutHeight = self.width, self.height
end

function KBWDebugBuildTestWindow:prerender()
    if self.width ~= self.lastLayoutWidth or self.height ~= self.lastLayoutHeight then self:layout() end
    local now = getTimestampMs()
    if self.dirty and (not self.lastRefresh or now - self.lastRefresh >= REFRESH_MS) then
        self.dirty = false
        self.detailsDirty = false
        self.lastRefresh = now
        self:rebuildRows()
    elseif self.detailsDirty and (not self.lastDetails or now - self.lastDetails >= REFRESH_MS * 2) then
        self.detailsDirty = false
        self.lastDetails = now
        self:refreshDetails()
    end
    local review = self:pendingReview()
    if (review ~= nil) ~= self.reviewShown then
        self.reviewShown = review ~= nil
        Theme.applyActionButton(self.passButton, self.reviewShown, true)
        Theme.applyActionButton(self.failButton, self.reviewShown, false)
    end
    ISCollapsableWindow.prerender(self)
    local reviewText = review and getText("IGUI_KBW_DebugTestReviewPrompt", tostring(review.test.name),
        tostring(review.label)) or getText("IGUI_KBW_DebugTestReviewIdle")
    local color = review and Theme.accent or Theme.textMuted
    local textY = self.reviewY + math.floor((ACTION_H - getTextManager():getFontHeight(UIFont.Small)) / 2)
    self:drawText(reviewText, PADDING, textY, color.r, color.g, color.b, 1, UIFont.Small)
    self:drawText(self:progressText(), PADDING, self.progressY, Theme.text.r, Theme.text.g, Theme.text.b, 1,
        UIFont.Small)
end

function KBWDebugBuildTestWindow:close()
    Harness.removeListener(self.listener)
    self:setVisible(false)
    self:removeFromUIManager()
    if KBWDebugBuildTestWindow.instance == self then KBWDebugBuildTestWindow.instance = nil end
end

---@param key string|number
function KBWDebugBuildTestWindow:isKeyConsumed(key)
    return Keyboard and key == Keyboard.KEY_ESCAPE
end

---@param key string|number
function KBWDebugBuildTestWindow:onKeyRelease(key)
    if self:isVisible() and self:isKeyConsumed(key) then self:close() end
end

function KBWDebugBuildTestWindow:new(player)
    local screenWidth = getCore():getScreenWidth()
    local screenHeight = getCore():getScreenHeight()
    local width = math.min(1040, screenWidth - 60)
    local height = math.min(760, screenHeight - 60)
    local o = ISCollapsableWindow:new(math.floor((screenWidth - width) / 2), math.floor((screenHeight - height) / 2),
        width, height)
    setmetatable(o, self)
    self.__index = self
    o.player = player
    o.title = getText("IGUI_KBW_DebugTestTitle")
    o.resizable = true
    o.minimumWidth = math.min(820, width)
    o.minimumHeight = math.min(620, height)
    o:setWantKeyEvents(true)
    return o
end

function KBWDebugBuildTestWindow.open(player)
    if not isDebugEnabled() or not player then return end
    if KBWDebugBuildTestWindow.instance then
        KBWDebugBuildTestWindow.instance:close()
        return
    end
    local window = KBWDebugBuildTestWindow:new(player)
    window:initialise()
    window:addToUIManager()
    window:setVisible(true)
    window:bringToTop()
    KBWDebugBuildTestWindow.instance = window
end

return KBWDebugBuildTestWindow
