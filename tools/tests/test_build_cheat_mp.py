"""Build cheat on a dedicated server.

The admin panel's older Build Cheat button and a -debug launch set only the
client's ISBuildMenu.cheat, never the player's synced isBuildCheat. Vanilla's
tryBuild then skipped walking and fetching, the Knox catalogue marked recipes
ready, and the server - which judges by isBuildCheat - refused every build as
out of reach or short of materials. The player saw the action end and nothing
appear, again and again. In multiplayer only the synced flag counts now, and a
refused build tells the player why.
"""
import re
import unittest

import kbw_runtime as k

LUA = k.LUA_ROOTS[0].parent


def source(relative):
    return k.read_text(LUA / relative)


class BuildCheatMultiplayerTests(unittest.TestCase):
    def test_try_build_uses_the_synced_flag_and_restores_the_menu_flag(self):
        text = source("server/KnoxBuildworks/BuildingObjects/KBWBuildingObject.lua")
        body = text.split("function KBWBuildingObject:tryBuild", 1)[1].split("\nend", 1)[0]
        self.assertRegex(body, r"ISBuildMenu\.cheat = effectiveBuildCheat\(self\.character\) end\s*\n\s*"
                               r"local buildAction = ISBuildingObject\.tryBuild")
        self.assertIn("ISBuildMenu.cheat = menuCheat", body)
        helper = text.split("local function effectiveBuildCheat", 1)[1].split("\nend", 1)[0]
        self.assertIn("if isClient() then return synced end", helper)

    def test_catalogue_and_finish_cursor_ignore_the_client_only_flag_in_multiplayer(self):
        catalog = source("client/KnoxBuildworks/UI/Catalog.lua")
        helper = catalog.split("local function buildCheatActive", 1)[1].split("\nend", 1)[0]
        self.assertIn("if isClient() then return false end", helper)
        cursor = source("client/KnoxBuildworks/BuildingObjects/KBWWallFinishCursor.lua")
        self.assertIn("not isClient() and ISBuildMenu and ISBuildMenu.cheat == true", cursor)
        # the plan queue no longer overwrites the player's menu toggle
        self.assertNotIn("ISBuildMenu.cheat =", source("client/KnoxBuildworks/Planning/BuildFromPlan.lua"))

    def test_every_server_refusal_in_create_reaches_the_player(self):
        text = source("server/KnoxBuildworks/BuildingObjects/KBWBuildingObject.lua")
        create = text.split("function KBWBuildingObject:create", 1)[1].split("\nfunction ", 1)[0]
        refusals = len(re.findall(r'Log:\w+\(\s*"Server rejected build', create))
        self.assertGreater(refusals, 0)
        self.assertGreaterEqual(create.count("notifyRejected("), 3)
        client = source("client/KnoxBuildworks/Client.lua")
        self.assertIn('command == "BuildRejected"', client)


if __name__ == "__main__":
    unittest.main()
