"""A different floor planned over planned floors replaces them.

Building a floor over a floor in the world swaps it (IsoGridSquare.addFloor
removes the old solid floor; walls stay). In a plan the second floor was
refused as an overlap, so changing a planned floor meant erasing it first.
Now a different floor replaces the planned one: the client removes it with
the existing permission-checked BPRemovePlacements, sent before the add, so
the server and every viewer apply the same commands in order. The same floor
twice is still an overlap, and a floor never replaces a non-floor piece.
"""
import unittest

from test_blueprint_limits import limits_runtime

SETUP = """
    function isClient() return true end
    bp.canContribute = function() return true end
    plan = bp.importExported(nil, { name = 'p', relativeLevel = 0, exportSchema = 1, placements = {}, rooms = {} })
    bp.get = function() return plan end
"""


def commands(lua):
    sent = lua.eval("SENT")
    return [sent[i].command for i in range(1, len(sent) + 1)]


class PlanFloorReplaceTests(unittest.TestCase):
    def setUp(self):
        self.lua = limits_runtime()
        self.lua.execute(SETUP)

    def test_a_different_floor_replaces_the_planned_one(self):
        self.lua.execute("""
            first = bp.addPlacement(nil, plan.id, { buildableId = 'floor_wood', x = 5, y = 5, z = 0, direction = 1 })
            assert(first)
            SENT = {}
            second, why = bp.addPlacement(nil, plan.id, { buildableId = 'floor_tile', x = 5, y = 5, z = 0, direction = 1 })
            assert(second, tostring(why))
            assert(#plan.placements == 1 and plan.placements[1].buildableId == 'floor_tile')
            assert(SENT[1].args.placementIds[1] == first.id)
        """)
        self.assertEqual(["BPRemovePlacements", "BPAddPlacement"], commands(self.lua))

    def test_the_same_floor_twice_is_still_an_overlap(self):
        self.lua.execute("""
            assert(bp.addPlacement(nil, plan.id, { buildableId = 'floor_wood', x = 5, y = 5, z = 0, direction = 1 }))
            local again, why = bp.addPlacement(nil, plan.id, { buildableId = 'floor_wood', x = 5, y = 5, z = 0, direction = 1 })
            assert(again == nil and why == 'plan_overlap', tostring(why))
            assert(#plan.placements == 1)
        """)

    def test_a_dragged_floor_sends_one_removal_before_its_adds(self):
        self.lua.execute("""
            local first = {}
            for i = 1, 3 do first[i] = { buildableId = 'floor_wood', x = i, y = 0, z = 0, direction = 1 } end
            assert(#bp.addPlacements(nil, plan.id, first) == 3)
            SENT = {}
            local second = {}
            for i = 1, 3 do second[i] = { buildableId = 'floor_tile', x = i, y = 0, z = 0, direction = 1 } end
            assert(#bp.addPlacements(nil, plan.id, second) == 3)
            assert(#plan.placements == 3)
            for i = 1, 3 do assert(plan.placements[i].buildableId == 'floor_tile') end
            assert(#SENT[1].args.placementIds == 3)
        """)
        self.assertEqual(["BPRemovePlacements", "BPAddPlacements"], commands(self.lua))

    def test_the_server_never_replaces_on_its_own(self):
        self.lua.execute("""
            function isServer() return true end
            assert(bp.addPlacement(nil, plan.id, { buildableId = 'floor_wood', x = 5, y = 5, z = 0, direction = 1 }))
            local second, why = bp.addPlacement(nil, plan.id, { buildableId = 'floor_tile', x = 5, y = 5, z = 0, direction = 1 })
            assert(second == nil and why == 'plan_overlap', tostring(why))
        """)


if __name__ == "__main__":
    unittest.main()
