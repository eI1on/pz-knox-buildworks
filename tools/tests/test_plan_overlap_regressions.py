"""Plan-overlap regressions found by Buildworks Studio's parity runs.

* stageNameMatches built its candidate list as a table literal with nil
  holes and looped to #candidates. The length of such a table is undefined:
  Kahlua and Lua 5.4 reached the entity name, Lua 5.5 (this suite) stopped at
  the first hole, so a planned wall frame did not count as the previous stage
  of a wall planned over it.
* Roof Helper layouts with eaves and accents put fascia on the squares their
  own eave pieces use. Without allowSharedSquare on the accents the plan
  rules rejected them in addPlacements (pieces silently left out).
"""
import importlib.util
import json
import unittest

import kbw_runtime as k

_spec = importlib.util.spec_from_file_location("roof_preview", k.ROOT / "tools/roof_preview.py")
preview = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(preview)

ACCENTS = k.MODS / "KnoxBuildworks_Vanilla_Expanded/42/media/KnoxBuildworks/definitions/roofing/roof_accents.json"
FRAME = "kbw.vanilla.woodenwallframe"
BANK_WALL = "kbw.vanillaexpanded.walls.bank_walls.bank_wall"


class PreviousStageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = k.load_registry(k.new_runtime())

    def test_planned_frame_is_the_previous_stage_of_a_wall(self):
        matches = self.lua.eval("""(function()
            local Blueprints = require("KnoxBuildworks/Planning/Blueprints")
            local frame = { id = "f", buildableId = "%s", stageId = "built", variantId = "", materialId = "",
                x = 0, y = 0, z = 0, direction = 1 }
            return Blueprints.placementMatchesPrevious({ "WoodenWallFrame", "MetalWallFrame" }, frame)
        end)()""" % FRAME)
        self.assertTrue(matches)

    def test_wall_over_planned_frame_is_an_upgrade_not_an_overlap(self):
        conflicts = self.lua.eval("""(function()
            local Blueprints = require("KnoxBuildworks/Planning/Blueprints")
            local frame = { id = "f", buildableId = "%s", stageId = "built", variantId = "", materialId = "",
                x = 0, y = 0, z = 0, direction = 1 }
            local wall = { id = "w", buildableId = "%s", stageId = "built", variantId = "", materialId = "",
                x = 0, y = 0, z = 0, direction = 1 }
            return #Blueprints.findIntersections({ placements = { frame } }, wall)
        end)()""" % (FRAME, BANK_WALL))
        self.assertEqual(conflicts, 0)


class AccentSharingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = k.load_registry(k.new_runtime())

    def test_every_accent_may_share_its_square(self):
        data = json.loads(ACCENTS.read_text(encoding="utf-8"))
        for definition in data["buildables"]:
            self.assertTrue(definition["placement"].get("allowSharedSquare"), definition["id"])

    def test_gable_with_eaves_and_accents_adds_every_piece(self):
        # A 4 x 6 room, 45 degree black roof, overhang 1, eaves and accents:
        # every piece of the suggested layout must survive the plan rules
        # addPlacements applies, in order.
        dropped = self.lua.eval("""(function()
            local RoofPlanner = require("KnoxBuildworks/Planning/RoofPlanner")
            local Registry = require("KnoxBuildworks/Definitions/Registry")
            local Blueprints = require("KnoxBuildworks/Planning/Blueprints")
            local definitions = Registry:list()
            local profiles = RoofPlanner.profiles(definitions)
            local profile
            for i = 1, #profiles do if profiles[i].id == "black:45" then profile = profiles[i] end end
            local region = RoofPlanner.findRegion({ { id = "r", x = 0, y = 0, z = 0, w = 4, h = 6 } }, "r")
            local options = { z = 1, eaves = true, overhang = 1, accents = RoofPlanner.accents(definitions)[1] }
            local layouts = RoofPlanner.suggest(profile, region, options)
            local chosen = layouts and layouts[1]
            if not chosen then return "no layout" end
            local plan = { placements = {} }
            local occupied = Blueprints.intersectionIndex(plan)
            local out = {}
            for i = 1, #chosen.placements do
                local piece = {}
                for key, value in pairs(chosen.placements[i]) do piece[key] = value end
                piece.id = "p" .. i
                if #Blueprints.findIntersections(plan, piece, occupied) > 0 then
                    out[#out + 1] = piece.buildableId .. "@" .. piece.x .. "," .. piece.y .. "," .. piece.z
                else
                    plan.placements[#plan.placements + 1] = piece
                    Blueprints.indexPlacement(occupied, piece)
                end
            end
            return table.concat(out, " ")
        end)()""")
        self.assertEqual(dropped, "")


if __name__ == "__main__":
    unittest.main()
