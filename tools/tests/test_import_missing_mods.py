"""Import notice for pieces this game cannot use.

A blueprint keeps every piece it was made with, so one that uses another
mod's buildables still imports when that mod is not active. Blueprints.
missingContent counts those pieces by cause (missing mod, outdated mod,
turned off by the server) and names the inactive mods that Buildworks Studio
files list in studio.requires; missingContentText is the player notice.
"""
import unittest

from test_catalog_workspace import runtime
from test_planning_selection import load


def notice_runtime():
    lua = runtime()
    lua.execute("""
        KNOWN = { ['kbw.vanilla.woodenwallframe'] = true, ['kbw.old.piece'] = true, ['kbw.off.piece'] = true }
        modules['KnoxBuildworks/Definitions/Resolver'] = { resolveStage = function(id, variant, material, stage)
            if not KNOWN[id] then return nil, nil, 'unknown buildable' end
            if id == 'kbw.old.piece' then return { id = id }, nil, 'unknown stage' end
            if id == 'kbw.off.piece' then return { id = id }, nil, 'buildable disabled by server' end
            return { id = id, placement = { kind = 'floor' } }, { id = 'built' }
        end }
        modules['KnoxBuildworks/Geometry/Matrix'] = { getFaceCells = function() return {} end, getFaceSprite = function() end }
        modules['KnoxBuildworks/Validation/Placement'] = { previousStageOf = function() end, optionalReplacementStageOf = function() end }
        modules['KnoxBuildworks/Definitions/StageConfig'] = { placement = function(d) return d.placement end, sprite = function() return {} end }
        modules['KnoxBuildworks/Planning/BlueprintFiles'] = { queueSave = function() end, loadAll = function() return {} end,
            remove = function() end, save = function() end }
        function isClient() return false end
        function isServer() return false end
        modules['KnoxBuildworks/Core'] = { NETWORK_MODULE = 'KnoxBuildworks', Runtime = { loaded = true },
            sandboxValue = function(_, default) return default end }
        ACTIVE = { 'KnoxBuildworks', '\\\\KnoxBuildworksVanillaExpanded' }
        function getActivatedMods()
            return { size = function() return #ACTIVE end, get = function(_, i) return ACTIVE[i + 1] end }
        end
        function getText(key, a, b)
            return key .. '(' .. tostring(a) .. (b and (',' .. tostring(b)) or '') .. ')'
        end
    """)
    shape = load(lua, "shared/KnoxBuildworks/Planning/RoomShape.lua", "RoomShape")
    lua.globals().modules["KnoxBuildworks/Planning/RoomShape"] = shape
    load(lua, "shared/KnoxBuildworks/Planning/Blueprints.lua", "bp")
    return lua


def placements(*ids):
    return "{" + ", ".join(f"{{ buildableId = '{i}', stageId = 'built' }}" for i in ids) + "}"


class ImportMissingModsTests(unittest.TestCase):
    def setUp(self):
        self.lua = notice_runtime()

    def found(self, lua_blueprint):
        return self.lua.eval(f"""(function()
            local r = bp.missingContent({lua_blueprint})
            return r.missing .. '|' .. r.outdated .. '|' .. r.disabled .. '|' .. table.concat(r.mods, ',')
        end)()""")

    def test_counts_pieces_by_cause(self):
        blueprint = "{ placements = " + placements(
            "kbw.vanilla.woodenwallframe", "machinery.lathe", "machinery.press", "kbw.old.piece", "kbw.off.piece"
        ) + " }"
        self.assertEqual(self.found(blueprint), "2|1|1|")

    def test_names_the_inactive_mods_a_studio_file_requires(self):
        blueprint = "{ placements = " + placements("machinery.lathe", "machinery.press") + """,
            studio = { requires = {
                { title = 'Knox Buildworks - Vanilla Expanded', modIds = { 'KnoxBuildworksVanillaExpanded' } },
                { title = 'Machinery', modIds = { 'Machinery' } },
                { title = 'Machinery', modIds = { 'MachineryExtras' } },
            } } }"""
        # Vanilla Expanded is active (B42 prefixes some ids with a backslash); Machinery is named once.
        self.assertEqual(self.found(blueprint), "2|0|0|Machinery")

    def test_untrusted_names_are_one_short_line(self):
        long_title = "x" * 300
        blueprint = "{ placements = " + placements("machinery.lathe") + f""",
            studio = {{ requires = {{ {{ title = 'Evil\\nMod\\t', modIds = {{ 'Evil' }} }},
                {{ title = '{long_title}', modIds = {{ 'Long' }} }}, {{ modIds = {{ 'NoTitle' }} }}, 'junk' }} }} }}"""
        mods = self.found(blueprint).split("|")[3].split(",")
        self.assertIn("Evil Mod", mods)
        self.assertIn("NoTitle", mods)
        self.assertTrue(all(len(name) <= 60 for name in mods))

    def test_notice_text(self):
        self.assertIsNone(self.lua.eval("bp.missingContentText({ placements = " + placements("kbw.vanilla.woodenwallframe") + " })"))
        text = self.lua.eval("bp.missingContentText({ placements = " + placements("machinery.lathe", "kbw.old.piece") + " })")
        # A single piece has its own wording; counts above one fill in %1.
        self.assertEqual(text, "IGUI_KBW_ImportMissingPiecesOne(nil) IGUI_KBW_ImportOutdatedPiecesOne(nil)")
        named = self.lua.eval("bp.missingContentText({ placements = " + placements("machinery.lathe") + ", studio = { requires = { { title = 'Machinery', modIds = { 'Machinery' } } } } })")
        self.assertEqual(named, "IGUI_KBW_ImportMissingModsOne(Machinery)")
        several = self.lua.eval("bp.missingContentText({ placements = " + placements("machinery.lathe", "machinery.press") + " })")
        self.assertEqual(several, "IGUI_KBW_ImportMissingPieces(2)")

    def test_survives_malformed_blueprints(self):
        self.assertEqual(self.found("{}"), "0|0|0|")
        self.assertEqual(self.found("{ placements = { 'junk', 5 } }"), "0|0|0|")


if __name__ == "__main__":
    unittest.main()
