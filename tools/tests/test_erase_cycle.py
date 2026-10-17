"""The erase tool steps through ghosts stacked on one tile with R.

It used to erase only the topmost planned piece on a tile, so a floor under a
wall or a table could not be picked without erasing what sat on it first. The
cursor now starts on the top piece, the rotate key steps down and wraps, and a
click erases exactly the outlined piece.
"""
import unittest

import kbw_runtime as k

LUA = k.LUA_ROOTS[0].parent


class EraseCycleTests(unittest.TestCase):
    def setUp(self):
        self.lua = k.new_runtime()
        self.lua.execute("""
            Events = Events or {}
            Events.OnGameStart = { Add = function(fn) DEFINE = fn end }
            for _, name in pairs({ 'KnoxBuildworks/Planning/Blueprints', 'KnoxBuildworks/Planning/GhostRenderer',
                    'KnoxBuildworks/Planning/PlanCursor', 'KnoxBuildworks/I18n' }) do
                modules[name] = {}
            end
        """)
        source = k.read_text(LUA / "client/KnoxBuildworks/Planning/EraseCursor.lua")
        self.lua.globals().EraseCursor = self.lua.execute(source)

    def test_starts_on_top_steps_down_and_wraps(self):
        picks = [self.lua.eval(f"EraseCursor.pickIndex(3, {offset})") for offset in range(5)]
        self.assertEqual([3, 2, 1, 3, 2], picks)
        self.assertEqual(1, self.lua.eval("EraseCursor.pickIndex(1, 4)"))
        self.assertEqual(0, self.lua.eval("EraseCursor.pickIndex(0, 0)"))

    def test_a_click_erases_the_outlined_piece_not_the_top_one(self):
        text = k.read_text(LUA / "client/KnoxBuildworks/Planning/EraseCursor.lua")
        create = text.split("function KBWEraseCursor:create", 1)[1].split("\n    end\n", 1)[0]
        self.assertIn("Blueprints.removePlacement(self.character, self.blueprintId, self.target.id)", create)
        self.assertNotIn("erasePlacementAt", create)
        self.assertIn("KeybindId.ROTATE_BUILDING", text)


if __name__ == "__main__":
    unittest.main()
