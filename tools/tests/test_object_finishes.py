"""Paint for furniture the base game tints (OtherPainting: crates, chairs,
tables, doors).

The vanilla Wood Crate entity defines only "face S". WallFinishes read W/N
faces alone, typed the crate a "wall" (paint only after plaster, which a crate
cannot take) and listed no colours, so players never saw the paint options
in the catalogue. Walls keep their W/N behaviour.
"""
import unittest

import kbw_runtime as k

SETUP = """
    PROPS = {
        carpentry_01_16 = { IsPaintable = '', PaintingType = 'crates' },
        wall_w = { IsPaintable = '', WallW = '' },
        wall_n = { IsPaintable = '', WallN = '' },
    }
    function getSprite(name)
        local map = PROPS[name]
        if not map then return nil end
        return { getName = function() return name end, getProperties = function()
            return { has = function(_, key) return map[key] ~= nil end, get = function(_, key) return map[key] end,
                set = function(_, key, value) map[key] = value end }
        end }
    end
    ISPaintMenu = { PaintMenuItems = { { paint = 'PaintBlue', text = 'Blue' }, { paint = 'PaintRed', text = 'Red' } },
        WallpaperMenuItems = {} }
    OtherPainting = { crates = { PaintBlue = { r = 0.35, g = 0.35, b = 0.8 }, PaintRed = { r = 0.63, g = 0.1, b = 0.1 } } }
    Painting = { wall = { plasterTile = 'plaster_w', plasterTileNorth = 'plaster_n', PaintBlue = 'blue_w',
        PaintBlueNorth = 'blue_n' } }
    WallPaper = {}
    IsoFlagType = { WallSE = 'WallSE' }
    WF = require('KnoxBuildworks/Validation/WallFinishes')
"""


class ObjectFinishTests(unittest.TestCase):
    def setUp(self):
        self.lua = k.new_runtime()
        self.lua.execute(SETUP)

    def test_a_crate_facing_only_south_offers_its_paint_colours(self):
        self.lua.execute("""
            local crate = { id = 'kbw.vanilla.wood_crate_lvl2', placement = { kind = 'object' } }
            local stage = { id = 'built', sprites = { S = 'carpentry_01_16' } }
            assert(WF.wallType(crate, stage) == 'crates', WF.wallType(crate, stage))
            local entries = WF.entriesFor(crate, stage)
            local paints = {}
            for i = 1, #entries do
                assert(entries[i].plaster == false, 'a crate is painted directly, never plastered')
                paints[#paints + 1] = entries[i].paintType
            end
            table.sort(paints)
            assert(#paints == 2 and paints[1] == 'PaintBlue' and paints[2] == 'PaintRed', table.concat(paints, ','))
            -- the finished crate keeps its own tile and wears the tint, and
            -- the ghost is drawn in that colour
            local blue = entries[1]
            assert(WF.previewSprite(blue, false, crate, stage) == 'carpentry_01_16')
            assert(WF.customColorFor('crates', blue) ~= nil)
            local tint = WF.previewTint(blue, crate, stage, 'carpentry_01_16')
            assert(tint and tint.r < 1 and tint.b ~= tint.r, 'the crate ghost carries the paint colour')
            assert(WF.previewTint(nil, crate, stage, 'carpentry_01_16') == nil)
        """)

    def test_the_military_crate_mapping_stays_with_the_military_crate(self):
        # Both crates are vanilla type "crates". The Military Crate declares an
        # inline mapping painting to its own tiles; once resolved it was
        # registered under "crates", and the painted Wood Crate ghost then
        # previewed the Military Crate while the built crate was correct.
        self.lua.execute("""
            PROPS.mil_w = { IsPaintable = '' }
            PROPS.mil_paint_w = { IsPaintable = '' }
            local military = { id = 'kbw.military_crate.green', placement = { kind = 'object' } }
            local militaryStage = { id = 'built', sprites = { W = 'mil_w' }, finishes = { wallType = 'crates',
                surface = { canPaint = true, canPlaster = false, paintRequiresPlaster = false },
                mapping = { directPaints = { ['*'] = { W = 'mil_paint_w', N = 'mil_paint_w' } },
                    baseSprites = { 'mil_w', 'mil_paint_w' } } } }
            local militaryEntries = WF.entriesFor(military, militaryStage)
            assert(#militaryEntries > 0, 'the military crate still offers paint')
            assert(WF.previewSprite(militaryEntries[1], false, military, militaryStage, 'mil_w') == 'mil_paint_w')

            local crate = { id = 'kbw.vanilla.wood_crate_lvl2', placement = { kind = 'object' } }
            local stage = { id = 'built', sprites = { S = 'carpentry_01_16' } }
            local entries = WF.entriesFor(crate, stage)
            assert(#entries == 2, #entries)
            for i = 1, #entries do
                local ghost = WF.previewSprite(entries[i], false, crate, stage, 'carpentry_01_16')
                assert(ghost == 'carpentry_01_16', tostring(ghost))
            end
        """)

    def test_walls_still_read_their_west_and_north_faces(self):
        self.lua.execute("""
            local wall = { id = 'wall', placement = { kind = 'wall' } }
            local stage = { id = 'built', sprites = { W = 'wall_w', N = 'wall_n', S = 'carpentry_01_16' } }
            assert(WF.wallType(wall, stage) == 'wall', WF.wallType(wall, stage))
        """)


if __name__ == "__main__":
    unittest.main()
