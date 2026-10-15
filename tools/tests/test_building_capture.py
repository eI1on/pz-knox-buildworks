"""Building capture: a world structure turned into a blueprint of catalogue pieces.

Runs the real BuildingCapture engine over the real registry. Only the world
(squares, objects, sprite properties) and the sprite -> recipe lookup
(WorldCatalog, which needs sprite data the tests cannot read) are faked.
"""
import unittest

import kbw_runtime as k

FRAME = "kbw.vanilla.woodenwallframe"
BANK_WALL = "kbw.vanillaexpanded.walls.bank_walls.bank_wall"
FLOOR = "kbw.vanilla.dirtfloor"
GOOD_WALL = "kbw.vanilla.woodenwalllvl3"
SHODDY_WALL = "kbw.vanilla.woodenwalllvl1"
CORNER_PIECE = "kbw.vanillaexpanded.walls.wooden_panel.wooden_panel_corner_wall"
WHITE_DOOR = "kbw.vanillaexpanded.doors.wooden_doors.white_door"

WORLD = """
    modules['KnoxBuildworks/Log'] = { info = function() end, warning = function() end }
    modules['KnoxBuildworks/UI/CatalogVisibility'] = { definitionEnabled = function() return true end }
    local CYAN = { actionType = 'wallFinish', plaster = true, paintType = 'PaintCyan' }
    local PLASTER = { actionType = 'wallFinish', plaster = true }
    -- sprite -> candidate template(s); the anchor comes from the square, as in WorldCatalog
    CANDIDATES = {
        bankW = { buildableId = '%(wall)s', stageId = 'built', direction = 1, kind = 'wall', chain = true,
            finish = { actionType = 'wallFinish', paintType = 'PaintBlue' } },
        bankCorner = { buildableId = '%(wall)s', stageId = 'built', direction = 1, kind = 'wall', corner = true },
        dirt = { buildableId = '%(floor)s', stageId = 'built', direction = 1, kind = 'floor' },
        -- A painted house wall: the corner-only panel happens to come first.
        house_w = {
            { buildableId = '%(corner)s', stageId = 'built', direction = 1, kind = 'wall', cornerPiece = true,
                fromFinish = true, finish = CYAN },
            { buildableId = '%(shoddy)s', stageId = 'built', direction = 1, kind = 'wall', chain = true, level = 1,
                fromFinish = true, finish = CYAN },
            { buildableId = '%(good)s', stageId = 'built', direction = 1, kind = 'wall', chain = true, level = 3,
                fromFinish = true, finish = CYAN } },
        house_n = {
            { buildableId = '%(corner)s', stageId = 'built', direction = 2, kind = 'wall', cornerPiece = true,
                fromFinish = true, finish = CYAN },
            { buildableId = '%(good)s', stageId = 'built', direction = 2, kind = 'wall', chain = true, level = 3,
                fromFinish = true, finish = CYAN } },
        -- What the old capture picked for a map corner tile.
        house_corner = { buildableId = '%(corner)s', stageId = 'built', direction = 1, kind = 'wall',
            cornerPiece = true },
        door_0 = { buildableId = '%(door)s', stageId = 'built', direction = 2, kind = 'object' }
    }
    WALLTYPES = {
        wall = { { buildableId = '%(good)s', stageId = 'built', kind = 'wall', chain = true, level = 3,
            plasterFinish = PLASTER } }
    }
    local function copy(template, square, north)
        local candidate = {}
        for key, value in pairs(template) do candidate[key] = value end
        candidate.x, candidate.y, candidate.z = square:getX(), square:getY(), square:getZ()
        if north ~= nil then candidate.direction = north and 2 or 1 end
        return candidate
    end
    modules['KnoxBuildworks/UI/WorldCatalog'] = {
        isAutoSprite = function(name) return name == 'pillar' end,
        placementsForSprite = function(player, name, square, object, showAll)
            assert(showAll == true, 'capture must not hide hide-until-learned recipes')
            local template = CANDIDATES[name]
            if not template then return {} end
            if template.buildableId then template = { template } end
            local result = {}
            for i = 1, #template do result[i] = copy(template[i], square) end
            return result
        end,
        candidatesForWallType = function(player, wallType, square, north)
            local result = {}
            for i = 1, #(WALLTYPES[wallType] or {}) do result[i] = copy(WALLTYPES[wallType][i], square, north) end
            return result
        end
    }
    IsoFlagType = { solidfloor = 'solidfloor' }
    IsoObjectType = { doorW = 'doorW', doorN = 'doorN', doorFrW = 'doorFrW', doorFrN = 'doorFrN' }
    -- sprite name -> tile properties (flags map to '')
    PROPS = {}
    local function propsFor(name, extra)
        local map = PROPS[name] or {}
        return {
            has = function(_, key) return map[key] ~= nil or (extra ~= nil and extra[key] == true) end,
            get = function(_, key) return map[key] end
        }
    end
    function getSprite(name)
        return { getName = function() return name end, getProperties = function() return propsFor(name) end,
            getType = function() return nil end }
    end
    function instanceof(o, class) return type(o) == 'table' and o.class == class end
    local function list(items)
        return { size = function() return #items end, get = function(_, index) return items[index + 1] end }
    end
    local function object(name, options)
        options = options or {}
        local sprite = { getName = function() return name end,
            getProperties = function() return propsFor(name, { solidfloor = options.floor }) end }
        local attached = nil
        if options.attached then
            local instances = {}
            for i = 1, #options.attached do
                local parent = getSprite(options.attached[i])
                instances[i] = { getParentSprite = function() return parent end }
            end
            attached = list(instances)
        end
        return { class = options.class, getSprite = function() return sprite end,
            getAttachedAnimSprite = function() return attached end,
            getModData = function() return {} end, IsOpen = function() return options.open == true end }
    end
    local function square(x, y, z, objects)
        local room = {}
        return { getX = function() return x end, getY = function() return y end, getZ = function() return z end,
            getObjects = function() return list(objects) end, getRoom = function() return room end,
            getRoomDef = function() return nil end }
    end
    WORLDS = {
        yard = {
            ['0,0,0'] = square(0, 0, 0, { object('dirt', { floor = true }), object('bankCorner'), object('pillar'),
                object('vegetation_01_0') }),
            ['1,0,0'] = square(1, 0, 0, { object('bankW'), object('mystery_01_7') })
        },
        house = {
            ['0,0,0'] = square(0, 0, 0, { object('house_corner') }),
            ['1,0,0'] = square(1, 0, 0, { object('door_2', { class = 'IsoDoor', open = true }),
                object('plaster_odd'), object('shelf', { attached = { 'clutter' } }), object('trash_01_4') })
        }
    }
    PROPS.house_corner = { WallNW = '', CornerWestWall = 'house_w', CornerNorthWall = 'house_n' }
    PROPS.plaster_odd = { WallW = '', PaintingType = 'wall', MaterialType = 'Plaster' }
    PROPS.clutter = { TileOverlay = '' }
    SQUARES = WORLDS.yard
    function getCell()
        return { getGridSquare = function(_, x, y, z) return SQUARES[x .. ',' .. y .. ',' .. z] end }
    end
    REPORT = nil
    function getFileWriter(path)
        return { write = function(_, text) REPORT = { path = path, text = text } end, close = function() end }
    end
"""


def capture_runtime():
    lua = k.load_registry(k.new_runtime())
    lua.execute(WORLD % {"wall": BANK_WALL, "floor": FLOOR, "good": GOOD_WALL, "shoddy": SHODDY_WALL,
                         "corner": CORNER_PIECE, "door": WHITE_DOOR})
    lua.execute("""
        KBW = require('KnoxBuildworks/Core')
        KBW.Runtime.loaded = true
        Blueprints = require('KnoxBuildworks/Planning/Blueprints')
        ADDED = {}
        Blueprints.create = function(player, name, level, reserve)
            CREATED = { id = 'bp1', name = name, level = level, placements = {}, importedSize = reserve }
            return CREATED
        end
        Blueprints.maxPlacements = function() return MAX or 1000 end
        Blueprints.importLimit = function() return MAX or 10000 end
        Blueprints.addPlacements = function(player, id, chunk, onRejected)
            for i = 1, #chunk do ADDED[#ADDED + 1] = chunk[i] end
            return chunk
        end
        Blueprints.addRoom = function() return true end
        Capture = require('KnoxBuildworks/Planning/BuildingCapture')
        function runCapture(area)
            DONE = nil
            assert(Capture.start({}, area, function(job) DONE = job end))
            for _ = 1, 1000 do
                if DONE then return DONE end
                Capture.onTick()
            end
            error('capture never finished')
        end
    """)
    return lua


class BuildingCaptureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = capture_runtime()

    def capture(self, maximum=None, world="yard"):
        self.lua.globals().MAX = maximum
        self.lua.execute("SQUARES = WORLDS.%s" % world)
        return self.lua.eval("""(function()
            ADDED = {}
            local job = runCapture(Capture.rectArea(0, 0, 1, 0, 0))
            local rows = {}
            for i = 1, #ADDED do
                local p = ADDED[i]
                local finish = p.finish and (p.finish.paintType or (p.finish.plaster and 'plaster')) or nil
                rows[i] = p.buildableId .. '@' .. p.x .. ',' .. p.y .. ',' .. p.z .. ':' .. p.direction
                    .. (finish and ('+' .. tostring(finish)) or '')
            end
            return job, rows
        end)()""")

    def test_walls_get_their_frames_corners_split_and_build_order(self):
        job, rows = self.capture()
        rows = k.lua_list(rows)
        self.assertEqual(rows, [
            FLOOR + "@0,0,0:1",
            FRAME + "@0,0,0:1", FRAME + "@0,0,0:2", FRAME + "@1,0,0:1",
            BANK_WALL + "@0,0,0:1", BANK_WALL + "@0,0,0:2", BANK_WALL + "@1,0,0:1+PaintBlue",
        ])
        self.assertEqual(job.prerequisites, 3)
        self.assertEqual(job.finishes, 1)
        self.assertEqual(job.added, 7)
        self.assertEqual(job.blueprint.level, 0)
        self.assertEqual(job.blueprint.importedSize, 7)

    def test_report_lists_unmatched_construction_but_not_scenery(self):
        job, _rows = self.capture()
        self.assertEqual(job.unmatched["mystery_01_7"], 1)
        self.assertIsNone(job.unmatched["vegetation_01_0"])
        self.assertIsNone(job.unmatched["pillar"])
        report = self.lua.globals().REPORT
        self.assertTrue(str(report.path).startswith("KnoxBuildworks/captures/"))
        self.assertIn("mystery_01_7: 1", str(report.text))

    def test_piece_limit_keeps_the_structure_first(self):
        job, rows = self.capture(maximum=4)
        rows = k.lua_list(rows)
        self.assertEqual(job.truncated, 3)
        self.assertEqual(rows[0], FLOOR + "@0,0,0:1")
        self.assertTrue(all(row.startswith(FRAME) for row in rows[1:]))

    def test_house_corner_becomes_two_good_wooden_walls_with_their_paint(self):
        job, rows = self.capture(world="house")
        rows = k.lua_list(rows)
        self.assertEqual(job.cornersSplit, 1)
        self.assertIn(GOOD_WALL + "@0,0,0:1+PaintCyan", rows)
        self.assertIn(GOOD_WALL + "@0,0,0:2+PaintCyan", rows)
        self.assertFalse(any(row.startswith(CORNER_PIECE) for row in rows))
        self.assertFalse(any(row.startswith(SHODDY_WALL) for row in rows))

    def test_open_door_is_read_closed_and_odd_plaster_is_approximated(self):
        job, rows = self.capture(world="house")
        rows = k.lua_list(rows)
        self.assertIn(WHITE_DOOR + "@1,0,0:2", rows)
        self.assertIn(GOOD_WALL + "@1,0,0:1+plaster", rows)
        self.assertEqual(job.approximated["plaster_odd"], 1)
        self.assertIn("plaster_odd: 1", str(self.lua.globals().REPORT.text))

    def test_overlay_clutter_and_litter_stay_out_of_the_gap_list(self):
        job, _rows = self.capture(world="house")
        self.assertEqual(job.overlaysSkipped, 1)
        self.assertIsNone(job.unmatched["clutter"])
        self.assertIsNone(job.unmatched["trash_01_4"])
        self.assertEqual(job.litter["trash_01_4"], 1)
        self.assertIsNone(job.unmatched["house_corner"])


if __name__ == "__main__":
    unittest.main()
