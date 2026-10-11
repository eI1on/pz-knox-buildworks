"""45 degree and shallow roof pieces: the odd-span, raised-flat and shallow
tiles decode to what they are, every family can lay out odd spans, and the
Roof Helper uses the exact vanilla pieces instead of stand-ins."""
import importlib.util
import json
import re
import unittest

import kbw_runtime as k

_spec = importlib.util.spec_from_file_location("roof_preview", k.ROOT / "tools/roof_preview.py")
preview = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(preview)


def suggest(lua, profile, cells, accents=False):
    g = lua.globals()
    g.cellList = lua.table_from([lua.table_from({"x": x, "y": y}) for (x, y) in cells])
    g.request = lua.table_from({"z": 1, "eaves": False})
    if accents:
        lua.execute("request.accents = roof.accents(definitions)[1]")
    result, _ = lua.eval("roof.suggest(find(profiles, %r), footprint(cellList), request)" % profile)
    return [result[i] for i in range(1, len(result) + 1)]


class RoofPieceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = preview.runtime()
        cls.atlas = cls.lua.eval("modules['KnoxBuildworks/Planning/RoofAtlas']")

    def key(self, sprite):
        piece = self.atlas.roofPiece(sprite)
        return piece and (str(piece.pitch), self.atlas.key(piece))

    def test_extra_tiles_decode_to_what_they_draw(self):
        self.assertEqual(self.key("roofs_01_70"), ("45", "ridge:NS:3"))
        self.assertEqual(self.key("roofs_05_79"), ("45", "ridge:EW:3"))
        self.assertEqual(self.key("roofs_03_103"), ("45", "ridge:EW:3"))
        self.assertEqual(self.key("roofs_01_68"), ("45", "innerHalf:SE:2"))
        self.assertEqual(self.key("roofs_05_74"), ("45", "outerHalf:SE:3"))
        self.assertEqual(self.key("roofs_03_122"), ("45", "raisedFlat:1"))
        self.assertEqual(self.key("roofs_04_92"), ("45", "raisedFlat:2"))
        self.assertEqual(self.key("roofs_01_87"), ("shallow", "slope:S:1"))
        self.assertEqual(self.key("roofs_shallow_01_76"), ("shallow", "slope:N:1"))

    def test_every_45_degree_family_lays_out_odd_spans(self):
        # pink, sage green and white had no ridge pieces at all.
        for family in ("pink", "sage_green", "white", "black"):
            gables = [l for l in suggest(self.lua, family + ":45", preview.rect(0, 0, 7, 5))
                      if l.kind == "gable" and not l.reason]
            self.assertTrue(gables, family)
            self.assertFalse(gables[0].metrics.ridgeGaps, family)

    def test_odd_span_ridges_use_the_two_and_a_half_step_tile_in_place(self):
        cells = preview.rect(0, 0, 11, 5) + preview.rect(0, 5, 5, 6)
        cross = [l for l in suggest(self.lua, "black:45", cells) if l.kind == "crossGable"][0]
        sprites = {item["sprite"] for item in preview.pieces(self.lua, cross.placements)}
        self.assertIn("roofs_01_71", sprites)
        self.assertEqual(cross.metrics.shifted, 0)

    def test_odd_span_ridge_junction_uses_the_inner_half_tile(self):
        cells = preview.rect(0, 0, 9, 3) + preview.rect(0, 3, 3, 6)
        hip = [l for l in suggest(self.lua, "black:45", cells) if l.kind == "hip"][0]
        sprites = {item["sprite"] for item in preview.pieces(self.lua, hip.placements)}
        self.assertTrue(sprites & {"roofs_01_67", "roofs_01_68", "roofs_01_69"}, sprites)
        self.assertEqual(hip.metrics.approx, 0)

    def test_shallow_sets_only_cover_two_rows(self):
        kinds = lambda cells: {l.kind for l in suggest(self.lua, "black:shallow", cells) if not l.reason}
        self.assertIn("gable", kinds(preview.rect(0, 0, 6, 4)))
        self.assertIn("shed", kinds(preview.rect(0, 0, 6, 2)))
        self.assertNotIn("gable", kinds(preview.rect(0, 0, 6, 3)))  # no ridge tile for odd spans
        self.assertEqual(kinds(preview.rect(0, 0, 6, 6)), {"flat"})

    def test_shallow_eaves_get_the_low_board_on_the_roof_level(self):
        gable = [l for l in suggest(self.lua, "black:shallow", preview.rect(0, 0, 6, 4), accents=True)
                 if l.kind == "gable"][0]
        boards = [(i["x"], i["y"], i["z"]) for i in preview.pieces(self.lua, gable.placements)
                  if i["sprite"] == "roofs_accents_01_17"]
        self.assertEqual(sorted(boards), [(x, 4, 1) for x in range(6)])


@unittest.skipUnless(k.kbw_paths.MODDING_TILES_2X is not None, "needs the 2x tile sheets (PZ_MODDING_TOOLS_DIR)")
class RoofSheetCoverageTests(unittest.TestCase):
    def test_every_roof_tile_with_art_has_a_buildable(self):
        from PIL import Image
        used = set()
        for path in (k.MODS / "KnoxBuildworks_Vanilla_Expanded/42/media/KnoxBuildworks/definitions/roofing").glob("*.json"):
            used.update(re.findall(r'"(roofs_(?:0\d|30_\d\d)_\d+)"', path.read_text(encoding="utf-8")))
        sheets = [f"roofs_0{i}" for i in range(1, 6)] + [f"roofs_30_{i:02d}" for i in range(1, 11)]
        missing = []
        for sheet in sheets:
            image = Image.open(k.kbw_paths.MODDING_TILES_2X / f"{sheet}.png").convert("RGBA")
            alpha = image.getchannel("A")
            for index in range((image.size[0] // 128) * (image.size[1] // 256)):
                x, y = (index % (image.size[0] // 128)) * 128, (index // (image.size[0] // 128)) * 256
                box = alpha.crop((x, y, x + 128, y + 256))
                if sum(box.histogram()[41:]) >= 30 and f"{sheet}_{index}" not in used:
                    missing.append(f"{sheet}_{index}")
        self.assertEqual(missing, [])


if __name__ == "__main__":
    unittest.main()
