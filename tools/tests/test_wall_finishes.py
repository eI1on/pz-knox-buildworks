"""Wall finish rules: what the catalogue offers must be what the finish
actions accept on the built wall (found by the in-game Test Runner)."""
import unittest

import kbw_runtime as k

SETUP = r"""
IsoFlagType = setmetatable({}, { __index = function(_, key) return key end })
SPRITE_PROPS = {}
function getSprite(name)
    local props = SPRITE_PROPS[name]
    if not props then return nil end
    return {
        getName = function() return name end,
        getProperties = function() return {
            get = function(_, key) return props[key] end,
            has = function(_, key) return props[key] ~= nil end,
            set = function(_, key, value) props[key] = value end
        } end
    }
end
WallFinishes = require('KnoxBuildworks/Validation/WallFinishes')
"""


def runtime():
    lua = k.new_runtime()
    lua.execute(SETUP)
    return lua


class WallFinishEntryTests(unittest.TestCase):
    def test_custom_colour_types_paint_without_plaster(self):
        # vanillaMapping used "customColors and false or true", which is
        # always true, so crates/doors could never be painted directly.
        lua = runtime()
        lua.execute(r"""
            Painting = {}
            OtherPainting = { crates = { PaintBlue = { r = 0.35, g = 0.35, b = 0.8 } } }
            rules = WallFinishes.surfaceRules(nil, nil, 'crates', nil)
            wallRules = WallFinishes.surfaceRules(nil, nil, 'nosuchtype', nil)
        """)
        self.assertFalse(lua.eval("rules.paintRequiresPlaster"))
        self.assertTrue(lua.eval("wallRules.paintRequiresPlaster"))

    def test_offers_only_finishes_the_built_wall_accepts(self):
        lua = runtime()
        lua.execute(r"""
            Painting, OtherPainting = {}, {}
            -- A Knox wall type that paints directly, registered by some other
            -- definition's finishes config.
            WallFinishes.registerWallType('shared.type', {
                plaster = { W = 'pl_w', N = 'pl_n' },
                paints = { PaintBlue = { W = 'pb_w', N = 'pb_n' } },
                directPaints = { PaintBlue = { W = 'db_w', N = 'db_n' } },
                surface = { canPlaster = true, canPaint = true, paintRequiresPlaster = false }
            })
            -- This stage has no finishes config; its sprite merely carries the
            -- same PaintingType, so the built wall resolves the vanilla table,
            -- where paint needs plaster.
            SPRITE_PROPS.bare_w = { PaintingType = 'shared.type', WallW = '' }
            SPRITE_PROPS.bare_n = { PaintingType = 'shared.type', WallN = '' }
            definition = { id = 'kbw.test.wall', placement = { kind = 'wall' } }
            stage = { id = 'built', sprites = { W = 'bare_w', N = 'bare_n' } }
            candidates = WallFinishes.candidateEntriesFor(definition, stage)
            offered = WallFinishes.entriesFor(definition, stage)
            directCandidates, directOffered = 0, 0
            for i = 1, #candidates do if candidates[i].plaster == false then directCandidates = directCandidates + 1 end end
            for i = 1, #offered do if offered[i].plaster == false then directOffered = directOffered + 1 end end
        """)
        self.assertGreater(lua.eval("directCandidates"), 0, "the definition alone suggests direct paint")
        self.assertEqual(lua.eval("directOffered"), 0, "direct paint the built wall refuses must not be offered")

    def test_configured_walls_keep_their_direct_paints(self):
        lua = runtime()
        lua.execute(r"""
            Painting, OtherPainting = {}, {}
            SPRITE_PROPS.brick_w = { WallW = '' }
            SPRITE_PROPS.brick_n = { WallN = '' }
            definition = { id = 'kbw.test.brick', placement = { kind = 'wall' }, finishes = {
                wallType = 'kbw.test.brick.type',
                mapping = {
                    directPaints = { PaintGrey = { W = 'grey_w', N = 'grey_n' } },
                    surface = { canPlaster = false, canPaint = true, paintRequiresPlaster = false }
                }
            } }
            stage = { id = 'built', sprites = { W = 'brick_w', N = 'brick_n' } }
            WallFinishes.prepareStage(definition, stage)
            offered = WallFinishes.entriesFor(definition, stage)
        """)
        offered = k.lua_list(lua.eval("offered"))
        self.assertTrue(any(entry.paintType == "PaintGrey" and entry.plaster is False for entry in offered))


class CustomColourTests(unittest.TestCase):
    """Doors, chairs, fences: OtherPainting types tint their own sprite."""

    SETUP = r"""
        Painting = {}
        OtherPainting = { door = { PaintBlue = { r = 0.35, g = 0.35, b = 0.8 },
                                   PaintNavy = { r = 0.35, g = 0.35, b = 0.8 },
                                   PaintRed = { r = 0.8, g = 0.2, b = 0.2 } } }
        SPRITE_PROPS.door_w = { PaintingType = 'door', IsPaintable = '' }
        definition = { id = 'kbw.test.door', placement = { kind = 'object' } }
        stage = { id = 'built', sprites = { W = 'door_w' } }
        blue = { actionType = 'wallFinish', plaster = false, paintType = 'PaintBlue' }
        function tintedObject(r, g, b)
            local color = r and { getR = function() return r end, getG = function() return g end,
                                  getB = function() return b end } or nil
            return {
                getSprite = function() return getSprite('door_w') end,
                getProperties = function() return getSprite('door_w'):getProperties() end,
                getModData = function() return {} end,
                getCustomColor = function() return color end
            }
        end
    """

    def test_validation_accepts_what_the_catalogue_offers(self):
        # FinishActions.validate resolved the paint sprite without the stage's
        # base sprite and refused every offered door/chair colour.
        lua = runtime()
        lua.execute(self.SETUP)
        offered = k.lua_list(lua.eval("WallFinishes.entriesFor(definition, stage)"))
        self.assertTrue(any(entry.paintType == "PaintBlue" for entry in offered))
        self.assertTrue(lua.eval("WallFinishes.finishAppliesToStage(definition, stage, blue)"))
        self.assertEqual(lua.eval("WallFinishes.spriteFor('paint', blue, false, definition, stage)"), "door_w")
        lua.execute("FinishActions = require('KnoxBuildworks/Validation/FinishActions')")
        self.assertTrue(lua.eval("FinishActions.validate(nil, definition, stage, blue, false)"))

    def test_signature_reads_the_tint(self):
        # The sprite never changes, so a painted fence used to report nil.
        lua = runtime()
        lua.execute(self.SETUP)
        self.assertEqual(lua.eval("WallFinishes.objectFinishSignature(tintedObject(0.8, 0.2, 0.2))"), "paint:PaintRed")
        # Shared colours resolve to one name regardless of table order.
        self.assertEqual(lua.eval("WallFinishes.objectFinishSignature(tintedObject(0.35, 0.35, 0.8))"), "paint:PaintBlue")
        self.assertIsNone(lua.eval("WallFinishes.objectFinishSignature(tintedObject())"))


if __name__ == "__main__":
    unittest.main()
