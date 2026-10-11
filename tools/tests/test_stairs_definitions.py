"""Every staircase must lay its tiles the way the game's stair flags expect.

A north-facing staircase (face N) is one row of west-climbing tiles
(stairsTW, stairsMW, stairsBW from left to right); a west-facing one (face W)
is one column of north-climbing tiles (stairsTN, stairsMN, stairsBN from top to
bottom). Swapping them, as the Vanilla Expanded metal stairs once did, draws
three disconnected flights.
"""
import json
import re
import unittest
from pathlib import Path

import kbw_runtime as k

ROOT = Path(__file__).resolve().parents[2]
TILES = k.kbw_paths.TILE_DEFINITIONS


def stair_flags(path):
    text = path.read_text(encoding="utf-8", errors="replace")
    flags = {}
    for match in re.finditer(r"// (\S+)\s+tile\s*\{(.*?)\n    \}", text, re.S):
        found = re.search(r"\bstairs([TMB][NW]) =", match.group(2))
        if found:
            flags[match.group(1)] = found.group(1)
    return flags


def stair_faces():
    for path in sorted((ROOT / "Contents/mods").glob("*/42/media/KnoxBuildworks/definitions/**/*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        for definition in data.get("buildables", []):
            if (definition.get("placement") or {}).get("kind") != "stairs":
                continue
            for stage in definition.get("stages", []):
                faces = (stage.get("geometry") or {}).get("faces") or {}
                for face, geometry in faces.items():
                    yield definition["id"], face, geometry["layers"][0]["rows"]


class StairDefinitionTests(unittest.TestCase):
    def test_faces_have_the_shape_of_their_direction(self):
        checked = 0
        for buildable, face, rows in stair_faces():
            if face == "N":
                self.assertEqual(1, len(rows), f"{buildable} N must be one row")
                self.assertEqual(3, len(rows[0]), buildable)
            else:
                self.assertEqual(3, len(rows), f"{buildable} {face} must be one column")
                self.assertTrue(all(len(row) == 1 for row in rows), buildable)
            checked += 1
        self.assertGreater(checked, 10)

    @unittest.skipUnless(TILES is not None, "needs the game's newtiledefinitions.tiles.txt")
    def test_tiles_match_the_game_stair_flags(self):
        flags = stair_flags(TILES)
        for buildable, face, rows in stair_faces():
            sprites = rows[0] if face == "N" else [row[0] for row in rows]
            expected = ["TW", "MW", "BW"] if face == "N" else ["TN", "MN", "BN"]
            self.assertEqual(expected, [flags.get(sprite) for sprite in sprites], f"{buildable} face {face}")


if __name__ == "__main__":
    unittest.main()
