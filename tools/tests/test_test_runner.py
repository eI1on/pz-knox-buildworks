"""The in-game Test Runner itself: harness scheduling, watchdog and cleanup
semantics, case enumeration over the real registry, and a smoke run of the
definitions suite through the harness against the real shared modules.

World builds, UI windows and rendering need the engine; those suites run in
game from the debug Menu Dock (Tests).
"""
import time
import unittest

import kbw_runtime as k

_release_runtime = k.new_runtime


def _debug_runtime(*args, **kwargs):
    """The runner's files load only under -debug; these tests are a debug session."""
    lua = _release_runtime(*args, **kwargs)
    lua.execute("function isDebugEnabled() return true end")
    return lua


k.new_runtime = _debug_runtime

HARNESS_STUBS = r"""
NOW = 0
function getTimestampMs() return NOW end
ERROR_COUNT = 0
ERRORS = {}
function getLuaDebuggerErrorCount() return ERROR_COUNT end
function getLuaDebuggerErrors()
    return { size = function() return #ERRORS end, get = function(_, i) return ERRORS[i + 1] end }
end
TICK_HANDLERS = {}
Events.OnTick = {
    Add = function(fn) TICK_HANDLERS[fn] = true end,
    Remove = function(fn) TICK_HANDLERS[fn] = nil end
}
FILES = {}
function getFileWriter(path)
    return { write = function(_, text) FILES[path] = text end, close = function() end }
end
function getFileReader(path)
    local text = FILES[path]
    if not text then return nil end
    local lines, index = {}, 0
    for line in string.gmatch(text .. "\n", "(.-)\n") do lines[#lines + 1] = line end
    return { readLine = function() index = index + 1; return lines[index] end, close = function() end }
end
function tick(advance)
    NOW = NOW + (advance or 16)
    local handlers = {}
    for fn in pairs(TICK_HANDLERS) do handlers[#handlers + 1] = fn end
    for i = 1, #handlers do handlers[i]() end
end
Harness = require('KnoxBuildworks/Debug/TestHarness')
"""


def harness_runtime():
    lua = k.new_runtime()
    lua.execute(HARNESS_STUBS)
    return lua


def run_until_done(lua, limit=500):
    for _ in range(limit):
        if not lua.eval("Harness.isRunning()"):
            return
        try:
            lua.globals().tick()
        except Exception:  # a deliberately failing step; the watchdog handles it next tick
            pass
    raise AssertionError("harness run did not finish")


class HarnessTests(unittest.TestCase):
    def test_steps_gates_cleanups_and_statuses(self):
        lua = harness_runtime()
        lua.execute(r"""
            LOG = {}
            local function log(s) LOG[#LOG + 1] = s end
            flag = false
            Harness.registerSuite({ id = 'demo', order = 1, titleKey = 'x', collect = function() return {
                { id = 'pass', run = function(t)
                    log('pass:1')
                    t:cleanup(function() log('pass:cleanupA') end)
                    t:cleanup(function() log('pass:cleanupB') end)
                    t:next(function() log('pass:2') end)
                    t:next(function() log('pass:3') end)
                end },
                { id = 'gate', run = function(t)
                    log('gate:1')
                    t:waitUntil(function() return flag end, 1000, 'never')
                    t:next(function() log('gate:2') end)
                end },
                { id = 'timeout', run = function(t)
                    t:cleanup(function() log('timeout:cleanup') end)
                    t:waitUntil(function() return false end, 50, 'waited too long')
                    t:next(function() log('timeout:unreachable') end)
                end },
                { id = 'soft', run = function(t) t:check(false, 'soft one'); t:next(function() log('soft:continued') end) end },
                { id = 'skip', run = function(t) t:cleanup(function() log('skip:cleanup') end); t:skip('not here') end },
            } end })
            run = Harness.start({}, { 'demo' })
        """)
        g = lua.globals()
        g.tick()
        # The gate test is waiting; releasing the flag lets it finish.
        g.flag = True
        run_until_done(lua)
        log = k.lua_list(g.LOG)
        self.assertEqual(log[:5], ["pass:1", "pass:2", "pass:3", "pass:cleanupB", "pass:cleanupA"])
        self.assertIn("gate:2", log)
        self.assertNotIn("timeout:unreachable", log)
        self.assertIn("timeout:cleanup", log)
        self.assertIn("soft:continued", log)
        self.assertIn("skip:cleanup", log)
        status = {t.id: t.status for t in k.lua_list(lua.eval("run.tests"))}
        self.assertEqual(status, {"pass": "passed", "gate": "passed", "timeout": "failed",
                                  "soft": "failed", "skip": "skipped"})
        messages = {t.id: t.message for t in k.lua_list(lua.eval("run.tests"))}
        self.assertEqual(messages["timeout"], "waited too long")
        self.assertEqual(messages["skip"], "not here")

    def test_watchdog_turns_a_raised_step_into_a_failure_and_still_cleans_up(self):
        lua = harness_runtime()
        lua.execute(r"""
            CLEANED = false
            AFTER = false
            Harness.registerSuite({ id = 'boom', collect = function() return {
                { id = 'raises', run = function(t)
                    t:cleanup(function() CLEANED = true end)
                    t:next(function()
                        ERROR_COUNT = ERROR_COUNT + 1
                        ERRORS[#ERRORS + 1] = 'Mod.lua:12: attempt to index nil\nstack'
                        error('attempt to index nil')
                    end)
                end },
                { id = 'after', run = function(t) AFTER = true end },
            } end })
            run = Harness.start({}, { 'boom' })
        """)
        run_until_done(lua)
        g = lua.globals()
        self.assertTrue(g.CLEANED)
        self.assertTrue(g.AFTER, "the run continues after a crashing test")
        tests = k.lua_list(lua.eval("run.tests"))
        self.assertEqual(tests[0].status, "failed")
        self.assertIn("Mod.lua:12", tests[0].message)
        self.assertEqual(tests[1].status, "passed", "a crash must not leak into the next test's error baseline")

    def test_errors_raised_outside_steps_fail_the_running_test(self):
        lua = harness_runtime()
        lua.execute(r"""
            Harness.registerSuite({ id = 'ui', collect = function() return {
                { id = 'renders', run = function(t)
                    -- A window's render callback errors while the test waits.
                    ERROR_COUNT = ERROR_COUNT + 1
                    ERRORS[#ERRORS + 1] = 'Catalog.lua:99: bad render'
                    t:waitTicks(2)
                end },
            } end })
            run = Harness.start({}, { 'ui' })
        """)
        run_until_done(lua)
        test = k.lua_list(lua.eval("run.tests"))[0]
        self.assertEqual(test.status, "failed")
        self.assertIn("Catalog.lua:99", test.message)

    def test_time_budget_spreads_many_tests_over_ticks(self):
        lua = harness_runtime()
        lua.execute(r"""
            Harness.registerSuite({ id = 'many', collect = function()
                local list = {}
                for i = 1, 300 do
                    list[i] = { id = 'n' .. i, run = function(t) NOW = NOW + 1 end }
                end
                return list
            end })
            run = Harness.start({ budgetMs = 8 }, { 'many' })
            ticks = 0
        """)
        g = lua.globals()
        ticks = 0
        while lua.eval("Harness.isRunning()"):
            g.tick(0)
            ticks += 1
            self.assertLess(ticks, 1000)
        # 8 ms budget and 1 ms per test: never everything in one tick.
        self.assertGreater(ticks, 30)
        counts = lua.eval("Harness.summary(run)")
        self.assertEqual(counts.passed, 300)

    def test_stop_finishes_current_cleanup_and_leaves_rest_unrun(self):
        lua = harness_runtime()
        lua.execute(r"""
            CLEANED = 0
            Harness.registerSuite({ id = 'long', collect = function() return {
                { id = 'waiting', run = function(t)
                    t:cleanup(function() CLEANED = CLEANED + 1 end)
                    t:waitUntil(function() return false end, 100000, 'never')
                end },
                { id = 'never-started', run = function(t) end },
            } end })
            FINISHED = nil
            run = Harness.start({ finish = function(r) FINISHED = r.stopReason end }, { 'long' })
        """)
        g = lua.globals()
        g.tick()
        lua.execute("Harness.stop()")
        run_until_done(lua)
        tests = k.lua_list(lua.eval("run.tests"))
        self.assertEqual(tests[0].status, "skipped")
        self.assertEqual(tests[1].status, "pending")
        self.assertEqual(g.CLEANED, 1)
        self.assertEqual(g.FINISHED, "stopped")

    def test_results_persist_and_report_lists_failures(self):
        lua = harness_runtime()
        lua.execute(r"""
            Harness.registerSuite({ id = 'r', collect = function() return {
                { id = 'good', name = 'Good one', run = function(t) end },
                { id = 'bad', name = 'Bad one', run = function(t) t:check(false, 'broken thing') end },
            } end })
            run = Harness.start({}, { 'r' })
        """)
        run_until_done(lua)
        files = lua.globals().FILES
        report = files[lua.eval("Harness.REPORT_PATH")]
        self.assertIn("Passed 1, failed 1", report)
        self.assertIn("Bad one (bad)", report)
        self.assertIn("broken thing", report)
        # A fresh session reads the stored results back.
        lua.execute("package_reset = true")
        stored_text = files[lua.eval("Harness.RESULTS_PATH")]
        fresh = harness_runtime()
        fresh.globals().FILES[fresh.eval("Harness.RESULTS_PATH")] = stored_text
        stored = fresh.eval("Harness.storedResults()")
        self.assertEqual(stored["bad"].status, "failed")
        self.assertEqual(stored["good"].status, "passed")


class CaseEnumerationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = k.new_runtime()
        k.load_registry(cls.lua)
        cls.lua.execute("Runner = require('KnoxBuildworks/Debug/BuildTestRunner')")

    def test_cases_cover_every_stage_option_combination_once(self):
        lua = self.lua
        started = time.perf_counter()
        cases = k.lua_list(lua.eval("Runner.cases()"))
        elapsed = time.perf_counter() - started
        expected = lua.execute(r"""
            local total = 0
            local list = Registry:list()
            for i = 1, #list do
                local d = list[i]
                local function stagesOf(option) return #((option and option.stages) or d.stages) end
                local mats = d.materialOptions or {}
                local vars = d.variants or {}
                local variantSet = { false }
                for v = 1, #vars do variantSet[#variantSet + 1] = vars[v] end
                for v = 1, #variantSet do
                    local variant = variantSet[v] or nil
                    if d.materialRequired ~= true then total = total + stagesOf(variant) end
                    for m = 1, #mats do total = total + stagesOf(mats[m].stages and mats[m] or variant) end
                end
            end
            return total
        """)
        self.assertEqual(len(cases), expected)
        keys = [case.key for case in cases]
        self.assertEqual(len(keys), len(set(keys)), "case keys must be unique")
        sort_keys = [case.sortKey for case in cases]
        self.assertEqual(sort_keys, sorted(sort_keys))
        # The old runner deep-merged every case on open and froze the game.
        # Enumeration must stay cheap and must not resolve definitions.
        self.assertLess(elapsed, 5.0)
        self.assertTrue(lua.eval("Runner.cases() == Runner.cases()"), "cases are cached per registry hash")

    def test_scope_lists_and_names(self):
        lua = self.lua
        cases = lua.eval("Runner.cases()")
        categories = k.lua_list(lua.eval("Runner.categories")(cases))
        self.assertEqual(categories[0], "All")
        self.assertEqual(categories[1:], sorted(categories[1:]))
        subcategories = k.lua_list(lua.eval("Runner.subcategories")(cases, categories[1]))
        self.assertEqual(subcategories[0], "All")
        first = cases[1]
        self.assertTrue(lua.eval("Runner.caseName")(first))
        definition, stage = lua.eval("Runner.resolve")(first)
        self.assertIsNotNone(stage)

    def test_representative_samples_are_simple_single_tile_pieces(self):
        lua = self.lua
        for kind in ("floor", "wall", "object"):
            sample = lua.eval("Runner.representative")(kind)
            self.assertIsNotNone(sample, kind)
            definition = lua.eval("Registry")["get"](lua.eval("Registry"), sample.buildableId)
            placement = lua.eval("require('KnoxBuildworks/Definitions/StageConfig').placement")(definition,
                                                                                               definition.stages[1])
            self.assertEqual(placement.kind, kind)

    def test_prerequisite_mapping(self):
        lua = self.lua
        mapping = lua.execute(r"""
            local stage = { previousStage = { 'WoodenWallFrame', 'MetalWallFrame' } }
            local cursor = { stage = stage }
            local results = {}
            local kind, names = Runner.prerequisiteFor(cursor, 'previous stage missing')
            results[1] = kind .. ':' .. table.concat(names, ',')
            results[2] = tostring(Runner.prerequisiteFor({ stage = {} }, 'door frame required'))
            results[3] = tostring(Runner.prerequisiteFor({ stage = {} }, 'window frame of a different shape'))
            results[4] = tostring(Runner.prerequisiteFor({ stage = {} }, 'wall required'))
            results[5] = tostring(Runner.prerequisiteFor({ stage = {} }, 'square already occupied'))
            return results
        """)
        self.assertEqual(k.lua_list(mapping), ["previous:WoodenWallFrame,MetalWallFrame", "door frame",
                                               "window frame", "wall", "nil"])
        walls = k.lua_list(lua.eval("Runner.providers")("wall", None))
        self.assertTrue(walls, "at least one plain wall can act as a support fixture")


class DefinitionSuiteSmokeTests(unittest.TestCase):
    def test_definitions_suite_runs_core_buildables_through_the_harness(self):
        lua = k.new_runtime()
        lua.execute(HARNESS_STUBS)
        k.load_registry(lua, providers=k.PROVIDERS[:1])
        lua.execute(r"""
            -- Engine facts the suite asks for; offline every sprite/icon exists.
            function getSprite(name) return { getName = function() return name end } end
            modules['KnoxBuildworks/UI/IconResolver'] = { textureForDefinition = function() return {} end }
            require('KnoxBuildworks/Debug/Suites/DefinitionSuite')
            ctx = { matchesScope = function() return true end }
            -- Entity components are not emulated offline; JSON-only buildables
            -- (including every variant/material stage list) only.
            function jsonOnly(definition)
                local lists = { definition.stages or {} }
                local options = { definition.variants or {}, definition.materialOptions or {} }
                for o = 1, #options do
                    for i = 1, #options[o] do lists[#lists + 1] = options[o][i].stages or {} end
                end
                for l = 1, #lists do
                    for i = 1, #lists[l] do
                        if lists[l][i].entityCompat then return false end
                    end
                end
                return true
            end
            run = Harness.start(ctx, { 'definitions' }, function(spec)
                return jsonOnly(Registry:get(string.sub(spec.id, #'definition:' + 1)))
            end)
        """)
        run_until_done(lua, limit=5000)
        tests = k.lua_list(lua.eval("run.tests"))
        expected = lua.execute(r"""
            local count = 0
            local list = Registry:list()
            for i = 1, #list do
                if jsonOnly(list[i]) then count = count + 1 end
            end
            return count
        """)
        self.assertGreater(expected, 0)
        self.assertEqual(len(tests), expected)
        failed = [f"{t.id}: {t.message}" for t in tests if t.status != "passed"]
        self.assertEqual([], failed)


class SettleAfterTeleportTests(unittest.TestCase):
    """Regression: building in the tick of a teleport hid the inventory from
    native entity recipes ("native recipe inputs unavailable")."""

    def test_fixtures_and_cases_never_build_in_the_teleport_tick(self):
        lua = harness_runtime()
        k.load_registry(lua, providers=k.PROVIDERS[:1])
        lua.execute(r"""
            Runner = require('KnoxBuildworks/Debug/BuildTestRunner')
            TICK = 0
            local baseTick = tick
            function tick(advance) TICK = TICK + 1; baseTick(advance) end
            EVENTS = {}
            local function log(what) EVENTS[#EVENTS + 1] = what .. '@' .. TICK end
            local square = { getX = function() return 1 end, getY = function() return 2 end, getZ = function() return 0 end }
            local wallBuilt = false
            -- The case needs a wall: validation refuses until the wall
            -- fixture stands on the case's own square, then accepts.
            Runner.findSite = function() return nil, nil, 'wall required' end
            Runner.candidates = function() return { { square = square, direction = 1 } } end
            Runner.accepts = function(cursor)
                if cursor.buildableId == 'case' and not wallBuilt then return false, 'wall required' end
                return true
            end
            Runner.prerequisiteFor = function(cursor, why) return why == 'wall required' and 'wall' or nil, nil end
            Runner.needsOf = function() return { kind = 'wall', shapes = {} } end
            Runner.providers = function() return { { buildableId = 'wall', stageId = 'built' } } end
            Runner.setDirection = function() end
            Runner.newCursor = function(_, id)
                return { buildableId = id, stage = { id = 'built' }, isWallLike = id == 'wall',
                    getFootprint = function() return {} end }
            end
            Runner.resolve = function() return {}, {} end
            Runner.supply = function() return true, nil, {} end
            Runner.cleanupSpawnedItems = function() end
            Runner.standBeside = function() log('teleport') end
            Runner.readyAt = function() log('validate'); return true end
            Runner.worldObjectsAround = function() return {} end
            Runner.createNow = function(_, cursor) log('create:' .. cursor.buildableId); wallBuilt = true; return true end
            Runner.newObjects = function() return { { buildableId = 'wall' } } end
            Harness.registerSuite({ id = 'settle', collect = function() return {
                { id = 'case', run = function(t)
                    local fixtures = {}
                    Runner.prepareSite(t, nil, Runner.newCursor(nil, 'case'), Runner.spiralArea(0, 0, 0, 1),
                        0, fixtures, {}, nil, function(found, direction, why)
                            assert(found, why)
                            assert(#fixtures == 1, 'fixture entry recorded')
                            log('site')
                        end)
                end },
            } end })
            run = Harness.start({}, { 'settle' })
        """)
        run_until_done(lua)
        events = k.lua_list(lua.eval("EVENTS"))
        test = k.lua_list(lua.eval("run.tests"))[0]
        self.assertEqual(test.status, "passed", test.message)
        teleport = int(next(e for e in events if e.startswith("teleport")).split("@")[1])
        create = int(next(e for e in events if e.startswith("create:wall")).split("@")[1])
        self.assertGreaterEqual(create - teleport, lua.eval("Runner.SETTLE_TICKS"))
        self.assertTrue(any(e.startswith("site") for e in events))

    def test_cleanup_skips_parts_removed_with_their_multi_tile_object(self):
        lua = k.new_runtime()
        lua.execute(r"""
            Runner = require('KnoxBuildworks/Debug/BuildTestRunner')
            REMOVED = 0
            local square = { RecalcAllWithNeighbours = function() end }
            square.transmitRemoveItemFromSquare = function(_, object) REMOVED = REMOVED + 1; object.index = -1 end
            local function part() local p = { index = 0 }
                p.getSquare = function() return square end
                p.getObjectIndex = function(self) return self.index end
                return p end
            local a, b = part(), part()
            -- The engine removes the sibling with the first part.
            square.transmitRemoveItemFromSquare = function(_, object)
                REMOVED = REMOVED + 1; a.index = -1; b.index = -1
            end
            Runner.removeEntries({ { object = a, square = square }, { object = b, square = square } })
        """)
        self.assertEqual(lua.eval("REMOVED"), 1)


class BuildFixRegressionTests(unittest.TestCase):
    """Mod fixes found by the Test Runner's first full in-game run."""

    def test_validation_and_build_share_one_wall_host_rule(self):
        placement = k.read_text(k.LUA / "shared/KnoxBuildworks/Validation/Placement.lua")
        building = k.read_text(k.LUA / "server/KnoxBuildworks/BuildingObjects/KBWBuildingObject.lua")
        self.assertNotIn("isRelevantOverlayWall", placement)
        self.assertIn("AttachedSprites.findWallHost(square, north, isCorner)", placement)
        self.assertIn("AttachedSprites.isWallDecorationSprite(tile.sprite)", placement)
        self.assertIn("AttachedSprites.isCornerStage(placement, cursor.stage)", placement)
        self.assertIn("AttachedSprites.isCornerStage(placement, self.stage)", building)
        lua = k.new_runtime()
        lua.execute(r"""
            Attached = require('KnoxBuildworks/World/AttachedSprites')
            IsoFlagType = setmetatable({}, { __index = function(_, key) return key end })
            function wallWith(flags, data)
                local set = {}
                for i = 1, #flags do set[flags[i]] = true end
                return {
                    getModData = function() return data or {} end,
                    getProperties = function() return { has = function(_, flag) return set[flag] == true end } end
                }
            end
        """)
        rule = lua.eval("Attached.isRelevantWall")
        wall = lua.eval("wallWith")
        flags = lambda *names: lua.table_from(list(names))
        self.assertTrue(rule(wall(flags("WallN")), True, False))
        self.assertFalse(rule(wall(flags("WallW")), True, False))
        self.assertTrue(rule(wall(flags("HoppableN", "WallNTrans")), True, False), "low walls validation accepted")
        self.assertTrue(rule(wall(flags(), lua.table_from({"WindowWall": True})), False, False))
        self.assertTrue(rule(wall(flags("WallNW")), False, True))
        self.assertFalse(rule(wall(flags("WallN")), True, True), "corners need a corner wall")
        corner = lua.eval("Attached.isCornerStage")
        self.assertTrue(corner(lua.table_from({}), lua.eval("{ object = { isCorner = true } }")),
                        "shipped data declares isCorner on the stage object")
        self.assertFalse(corner(lua.table_from({}), lua.table_from({})))

    def test_props_skip_vanilla_thumpable_callbacks(self):
        source = k.read_text(k.LUA / "server/KnoxBuildworks/BuildingObjects/KBWBuildingObject.lua")
        body = source[source.index("function KBWBuildingObject:runOnCreate"):source.index("-- Vanilla ISBuildingObject:updateModData")]
        self.assertIn("prop = true", source)
        lua = k.new_runtime()
        lua.execute(r"""
            CALLED = {}
            KBWBuildingObject = {}
            ONCREATE = nil
            StageConfig = { sprite = function() return { onCreate = ONCREATE } end }
            LuaCallback = { callObject = function(name) CALLED[#CALLED + 1] = name; return true end }
            function instanceof(object, kind) return kind == 'IsoThumpable' and object.thumpable == true end
            function faceName() return 'W' end
        """ + body.replace("local ", "") + r"""
            local cursor = setmetatable({ nSprite = 1 }, { __index = KBWBuildingObject })
            local plain = { getSquare = function() return nil end }
            local thump = { thumpable = true, getSquare = function() return nil end }
            ONCREATE = 'BuildRecipeCode.canBePlastered.OnCreate'
            cursor:runOnCreate(plain, { prop = true })
            assert(#CALLED == 0, 'vanilla thumpable callback ran on a plain prop')
            cursor:runOnCreate(thump, { prop = true })
            cursor:runOnCreate(plain, {})
            ONCREATE = 'KBW.Callbacks.OnPropCreated'
            cursor:runOnCreate(plain, { prop = true })
            assert(#CALLED == 3, 'thumpables, non-prop paths and Knox callbacks still run')
        """)


class LayoutTests(unittest.TestCase):
    """Kept pieces each get their own slot sized to their footprint."""

    def setUp(self):
        self.lua = k.new_runtime()
        k.load_registry(self.lua, providers=k.PROVIDERS[:1])
        self.lua.execute("Runner = require('KnoxBuildworks/Debug/BuildTestRunner')")

    def test_slots_never_overlap_and_keep_the_gap(self):
        slots = self.lua.execute(r"""
            local layout = Runner.newLayout({ x = 100, y = 200, z = 0 }, 2, 12)
            local sizes = { {1,1}, {2,2}, {4,2}, {1,1}, {3,1}, {4,4}, {1,2}, {2,1}, {4,2}, {1,1} }
            local out = {}
            for i = 1, #sizes do out[i] = Runner.allocate(layout, sizes[i][1], sizes[i][2]) end
            return out
        """)
        rects = [(s.x1, s.y1, s.x2, s.y2) for s in k.lua_list(slots)]
        sizes = [(1, 1), (2, 2), (4, 2), (1, 1), (3, 1), (4, 4), (1, 2), (2, 1), (4, 2), (1, 1)]
        for (x1, y1, x2, y2), (w, h) in zip(rects, sizes):
            self.assertEqual((x2 - x1 + 1, y2 - y1 + 1), (w, h), "slot matches the footprint")
            self.assertLessEqual(x2, 100 + 12 - 1, "rows wrap at the row width")
        for i, a in enumerate(rects):
            for b in rects[i + 1:]:
                # At least `gap` free tiles between any two slots.
                apart_x = b[0] > a[2] + 2 or a[0] > b[2] + 2
                apart_y = b[1] > a[3] + 2 or a[1] > b[3] + 2
                self.assertTrue(apart_x or apart_y, f"{a} and {b} are closer than the gap")
        self.assertGreater(len({r[1] for r in rects}), 1, "several rows are used")

    def test_rect_candidates_align_every_footprint_inside_the_slot(self):
        result = self.lua.execute(r"""
            function getCell() return { getGridSquare = function(_, x, y, z)
                return { x = x, y = y, getX = function() return x end, getY = function() return y end }
            end } end
            -- A 4x2 piece whose west face extends left (negative dx) and north face down.
            local faces = {
                [1] = { { dx = -3, dy = 0, sprite = 'a' }, { dx = 0, dy = 1, sprite = 'b' } },
                [2] = { { dx = 0, dy = -1, sprite = 'a' }, { dx = 1, dy = 2, sprite = 'b' } }
            }
            local cursor = { isWallLike = true, nSprite = 1 }
            cursor.getSprite = function() end
            cursor.getFootprint = function(self) return faces[self.nSprite] end
            local area = Runner.rectArea(10, 20, 13, 23, 0)
            local out = {}
            local list = Runner.candidates(cursor, area)
            for i = 1, #list do
                local c = list[i]
                local cells = faces[c.direction]
                for j = 1, #cells do
                    out[#out + 1] = { c.square.x + cells[j].dx, c.square.y + cells[j].dy }
                end
            end
            return out
        """)
        for cell in k.lua_list(result):
            self.assertTrue(10 <= cell[1] <= 13 and 20 <= cell[2] <= 23, f"cell {cell[1]},{cell[2]} leaves the slot")

    def test_extent_uses_the_largest_face(self):
        width, height = self.lua.execute(r"""
            local Matrix = require('KnoxBuildworks/Geometry/Matrix')
            Matrix.getFaceCells = function(stage, face)
                if face == 'W' then return { { dx = 0, dy = 0 }, { dx = 3, dy = 0 } } end
                if face == 'N' then return { { dx = 0, dy = 0 }, { dx = 0, dy = 1 } } end
                return {}
            end
            return Runner.extentOf({})
        """)
        self.assertEqual((width, height), (4, 2))


class VerificationTests(unittest.TestCase):
    def test_native_replacements_count_as_a_successful_build(self):
        lua = k.new_runtime()
        lua.execute(r"""
            Runner = require('KnoxBuildworks/Debug/BuildTestRunner')
            local StageConfig = require('KnoxBuildworks/Definitions/StageConfig')
            StageConfig.placement = function() return { kind = 'object' } end
            local function sq(x, y) return { getX = function() return x end, getY = function() return y end,
                getZ = function() return 0 end } end
            cursor = { definition = {}, stage = {}, getFootprint = function()
                return { { dx = 0, dy = 0, sprite = 'a' }, { dx = 1, dy = 0, sprite = 'b' } } end }
            anchor = sq(5, 5)
            -- Vanilla feedingTrough/chickenHutch OnCreate swap the Knox parts
            -- for one native object.
            nativeOnly = { { native = true, square = sq(5, 5) } }
            knoxMissingTile = { { buildableId = 'kbw.x', square = sq(5, 5) } }
        """)
        problems, notes = lua.eval("Runner.verifyBuilt")(lua.eval("cursor"), lua.eval("anchor"),
                                                         lua.eval("nativeOnly"), "kbw.x", None)
        self.assertEqual(k.lua_list(problems), [])
        self.assertIn("native object", k.lua_list(notes)[0])
        problems, _ = lua.eval("Runner.verifyBuilt")(lua.eval("cursor"), lua.eval("anchor"),
                                                    lua.eval("knoxMissingTile"), "kbw.x", None)
        self.assertEqual(len(k.lua_list(problems)), 1, "an all-Knox build must cover every footprint tile")
        problems, _ = lua.eval("Runner.verifyBuilt")(lua.eval("cursor"), lua.eval("anchor"), lua.table_from([]),
                                                    "kbw.x", None)
        self.assertEqual(k.lua_list(problems), ["nothing appeared in the world"])


class PrerequisiteSelectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = k.new_runtime()
        k.load_registry(cls.lua)
        cls.lua.execute("Runner = require('KnoxBuildworks/Debug/BuildTestRunner')")

    def providers(self, kind, needs):
        return k.lua_list(self.lua.eval("Runner.providers")(kind, None, self.lua.eval(needs)))

    def test_support_walls_are_plain_single_tile_walls(self):
        walls = self.providers("wall", "{ kind = 'wall', shapes = {} }")
        self.assertTrue(walls)
        bad = ("barricade", "fence", "frame", "corner", "roof", "slope", "railing", "gate", "door", "window")
        for provider in walls:
            self.assertFalse(any(word in provider.buildableId for word in bad), provider.buildableId)
        # JSON-only pieces (no entity script) rank first.
        first = self.lua.eval("Registry")["get"](self.lua.eval("Registry"), walls[0].buildableId)
        self.assertIsNone(first.stages[1].entityCompat)

    def test_barricades_ask_for_a_window_or_door_target(self):
        kind = self.lua.execute(r"""
            local StageConfig = require('KnoxBuildworks/Definitions/StageConfig')
            local original = StageConfig.sprite
            StageConfig.sprite = function() return { onIsValid = 'BuildRecipeCode.barricade.OnIsValid' } end
            local kind = Runner.prerequisiteFor({ definition = {}, stage = {} }, 'script OnIsValid rejected')
            StageConfig.sprite = original
            return kind
        """)
        self.assertEqual(kind, "barricadable")
        targets = self.providers("barricadable", "{ kind = 'barricadable', shapes = {} }")
        self.assertIn("windowframe", targets[0].buildableId.replace("_", ""), "real window frames come first")

    def test_window_frames_are_offered_for_windows(self):
        frames = self.providers("window frame", "{ kind = 'window frame', shapes = { N = false, W = false } }")
        self.assertTrue(frames)


class NativeXpTests(unittest.TestCase):
    def test_native_recipes_rely_on_the_engine_xp_award(self):
        # B42.21 CraftRecipeData.perform awards XpAward itself; the old
        # "B42.20 fallback" double-awarded or warned on capped skills.
        source = k.read_text(k.LUA / "server/KnoxBuildworks/BuildingObjects/KBWBuildingObject.lua")
        self.assertNotIn("CraftRecipe fallback", source)
        self.assertNotIn("nativeXpPending", source)
        self.assertNotIn("snapshotXp", source)
        consume = source[source.index("function KBWBuildingObject:consumeConstructionRequirements"):
                         source.index("function KBWBuildingObject:transmitPart")]
        self.assertIn("logic:performCurrentRecipe()", consume)
        self.assertNotIn("addXP", consume)

    def test_level_ups_and_debug_changes_expire_cached_visibility(self):
        lua = k.new_runtime()
        lua.execute(r"""
            HOOKS = {}
            Events.LevelPerk = { Add = function(fn) HOOKS[#HOOKS + 1] = fn end }
            Requirements = require('KnoxBuildworks/Validation/Requirements')
            before = Requirements.inventoryRevision()
            Requirements.invalidate()
            afterInvalidate = Requirements.inventoryRevision()
            HOOKS[1]()
            afterLevel = Requirements.inventoryRevision()
        """)
        g = lua.globals()
        self.assertGreater(g.afterInvalidate, g.before)
        self.assertGreater(g.afterLevel, g.afterInvalidate)


class SortingTests(unittest.TestCase):
    """Regression: Kahlua's table.sort is a recursive quicksort; ~1000 tied,
    already ordered providers overflowed the stack in game."""

    def test_runner_never_uses_the_recursive_engine_sort(self):
        source = k.read_text(k.LUA / "client/KnoxBuildworks/Debug/BuildTestRunner.lua")
        self.assertNotIn("table.sort(", source)

    def test_merge_sort_is_correct_and_stable_on_worst_case_inputs(self):
        lua = k.new_runtime()
        lua.execute("Runner = require('KnoxBuildworks/Debug/BuildTestRunner')")
        ok = lua.execute(r"""
            local function check(list, less, expect)
                Runner.mergeSort(list, less)
                for i = 1, #list do
                    if expect(list, i) == false then return false end
                end
                return true
            end
            local sorted, reversed, tied = {}, {}, {}
            for i = 1, 5000 do
                sorted[i] = i
                reversed[i] = 5001 - i
                tied[i] = { score = i % 3 == 0 and 1 or 0, order = i }
            end
            local asc = function(a, b) return a < b end
            local byScore = function(a, b) return a.score > b.score end
            return check(sorted, asc, function(l, i) return l[i] == i end)
                and check(reversed, asc, function(l, i) return l[i] == i end)
                and check(tied, byScore, function(l, i)
                    if i == 1 then return true end
                    local a, b = l[i - 1], l[i]
                    -- higher scores first, original order kept inside a score
                    return a.score > b.score or (a.score == b.score and a.order < b.order)
                end)
        """)
        self.assertTrue(ok)


class SuiteLoadTests(unittest.TestCase):
    """Every in-game runner file loads and every suite collects real test specs.

    Vanilla UI classes and the Knox windows are replaced by inert stand-ins so
    only the runner's own top-level code and collect() paths execute."""

    def test_window_and_all_suites_load_and_collect(self):
        lua = k.new_runtime()
        lua.execute(HARNESS_STUBS)
        k.load_registry(lua)
        lua.execute(r"""
            local function inert()
                return setmetatable({}, { __index = function(t, key)
                    local value = function() return inert() end
                    rawset(t, key, value)
                    return value
                end })
            end
            local function uiClass()
                local class = {}
                class.derive = function(self, name)
                    local derived = setmetatable({ Type = name }, { __index = self })
                    derived.derive = class.derive
                    return derived
                end
                return class
            end
            ISCollapsableWindow = uiClass()
            ISScrollingListBox = uiClass()
            ISPanel = uiClass()
            ISBuildingObject = uiClass()
            ISBaseTimedAction = uiClass()
            for _, name in pairs({ 'KnoxBuildworks/UI/Catalog', 'KnoxBuildworks/UI/PlanningMode',
                    'KnoxBuildworks/UI/IconResolver', 'KnoxBuildworks/Planning/Planner',
                    'KnoxBuildworks/Planning/GhostRenderer', 'KnoxBuildworks/Planning/BuildQueue',
                    'KnoxBuildworks/UI/CatalogIndex', 'KnoxBuildworks/UI/Theme' }) do
                modules[name] = inert()
            end
            modules['KnoxBuildworks/UI/VirtualListBox'] = uiClass()
            require('KnoxBuildworks/UI/DebugBuildTestWindow')
            assert(KBWDebugBuildTestWindow and KBWDebugBuildTestWindow.open, 'window class missing')
            ctx = { matchesScope = function() return true end, options = {} }
            COUNTS = {}
            IDS = {}
            DUPLICATES = {}
            for i = 1, #Harness.suiteOrder do
                local suite = Harness.suites[Harness.suiteOrder[i]]
                assert(getTextOrNull(suite.titleKey), 'suite title not translated: ' .. suite.id)
                assert(getTextOrNull(suite.descriptionKey), 'suite description not translated: ' .. suite.id)
                local specs = suite.collect(ctx)
                COUNTS[suite.id] = #specs
                for s = 1, #specs do
                    local spec = specs[s]
                    assert(type(spec.id) == 'string' and type(spec.run) == 'function', suite.id .. ' bad spec')
                    if IDS[spec.id] then DUPLICATES[#DUPLICATES + 1] = spec.id end
                    IDS[spec.id] = true
                end
            end
        """)
        counts = dict(lua.eval("COUNTS"))
        self.assertEqual(set(counts), {"definitions", "catalog", "planning", "build", "planqueue"})
        self.assertEqual(counts["definitions"], lua.eval("#Registry:list()"))
        self.assertEqual(counts["build"], lua.eval("#require('KnoxBuildworks/Debug/BuildTestRunner').cases()"))
        self.assertGreaterEqual(counts["catalog"], 8)
        self.assertGreaterEqual(counts["planning"], 8)
        self.assertEqual(k.lua_list(lua.eval("DUPLICATES")), [], "test ids must be unique across suites")



class DebugGateTests(unittest.TestCase):
    def test_release_sessions_load_no_test_code(self):
        lua = _release_runtime()
        lua.execute(r"""
            harness = require('KnoxBuildworks/Debug/TestHarness')
            runner = require('KnoxBuildworks/Debug/BuildTestRunner')
            require('KnoxBuildworks/UI/DebugBuildTestWindow')
        """)
        self.assertNotIsInstance(lua.eval("harness"), type(lua.table()))
        self.assertNotIsInstance(lua.eval("runner"), type(lua.table()))
        self.assertIsNone(lua.eval("KBWDebugBuildTestWindow"))


if __name__ == "__main__":
    unittest.main()
