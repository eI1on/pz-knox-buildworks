"""Roof accent trim: definitions decode to the edge they claim, and the Roof
Helper places rakes, fascia, returns and feet the way the vanilla map does
(east/south gables and eaves only; eave trim one level below the roof)."""
import importlib.util
import json
import unittest

import kbw_runtime as k

_spec = importlib.util.spec_from_file_location("roof_preview", k.ROOT / "tools/roof_preview.py")
preview = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(preview)

ACCENTS = k.MODS / "KnoxBuildworks_Vanilla_Expanded/42/media/KnoxBuildworks/definitions/roofing/roof_accents.json"


def layout(lua, profile, cells, gable=None, overhang=0):
    g = lua.globals()
    g.cellList = lua.table_from([lua.table_from({"x": x, "y": y}) for (x, y) in cells])
    g.request = lua.table_from({"z": 1, "eaves": False, "overhang": overhang})
    lua.execute("request.accents = roof.accents(definitions)[1]")
    if gable:
        lua.execute("request.gable = find(gables, %r)" % gable)
    result, _ = lua.eval("roof.suggest(find(profiles, %r), footprint(cellList), request)" % profile)
    return result[1]


def placed(lua, chosen):
    """{(x, y, z): [sprite, ...]} for every placement of the layout."""
    out = {}
    for item in preview.pieces(lua, chosen.placements):
        out.setdefault((item["x"], item["y"], item["z"]), []).append(item["sprite"])
    return out


class AccentDefinitionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = preview.runtime()
        cls.data = json.loads(ACCENTS.read_text(encoding="utf-8"))

    def test_each_face_carries_the_tile_for_its_own_edge(self):
        # The old trim files put attachedN tiles on the W face.
        decode = self.lua.eval("modules['KnoxBuildworks/Planning/RoofAtlas'].accentPiece")
        for definition in self.data["buildables"]:
            for face, geometry in definition["stages"][0]["geometry"]["faces"].items():
                sprite = geometry["layers"][0]["rows"][0][0]
                piece = decode(sprite)
                self.assertIsNotNone(piece, sprite)
                edge = piece.wall or piece.edge
                if edge in ("W", "N") and piece.kind != "shoe":
                    self.assertEqual(edge, face, f"{definition['id']} {face} carries {sprite}")

    def test_old_trim_ids_stay_valid(self):
        aliases = {alias for d in self.data["buildables"] for alias in d.get("aliases", [])}
        for old in ("kbw.vanillaexpanded.roofing.roof_trim.fascia_2_1",
                    "kbw.vanillaexpanded.roofing.roof_trim.trim_30_fascia_peak_6",
                    "kbw.vanillaexpanded.architecture_plus.roof_accents.eave_trim_top"):
            self.assertIn(old, aliases)


class AccentPlacementTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = preview.runtime()
        cls.atlas = cls.lua.eval("modules['KnoxBuildworks/Planning/RoofAtlas']")

    def rakes_follow_gable_walls(self, profile, gable, pitch, overhang=0):
        chosen = layout(self.lua, profile, preview.rect(0, 0, 6, 4), gable, overhang)
        self.assertEqual(chosen.kind, "gable")
        cells = placed(self.lua, chosen)
        rakes, walls = {}, {}
        for position, sprites in cells.items():
            for sprite in sprites:
                accent = self.atlas.accentPiece(sprite)
                if accent and accent.kind == "rake":
                    rakes[position] = self.atlas.gableKey(accent)
                wall = sprite.startswith("walls_exterior_roofs") and self.atlas.gablePiece(
                    sprite, pitch, 24 if pitch == 45 else None)
                if wall:
                    walls[position] = self.atlas.gableKey(wall)
        self.assertTrue(rakes)
        return rakes, walls, cells

    def test_45_degree_rakes_match_the_east_gable_wall(self):
        rakes, walls, _ = self.rakes_follow_gable_walls("grey:45", "white_clapboard:45", 45)
        self.assertEqual(rakes, {p: k for p, k in walls.items() if p[0] == 6})

    def test_30_degree_rakes_match_the_east_gable_wall(self):
        rakes, walls, _ = self.rakes_follow_gable_walls("grey:30", "white_clapboard:30", 30)
        self.assertEqual(rakes, {p: k for p, k in walls.items() if p[0] == 6})

    def test_overhang_moves_rakes_to_the_roof_edge(self):
        rakes, walls, _ = self.rakes_follow_gable_walls("grey:45", "white_clapboard:45", 45, overhang=1)
        self.assertTrue(all(x == 7 for (x, _y, _z) in rakes), rakes)
        self.assertTrue(all(x in (0, 6) for (x, _y, _z) in walls), walls)

    def test_30_degree_rakes_get_feet_one_level_below(self):
        _, _, cells = self.rakes_follow_gable_walls("grey:30", "white_clapboard:30", 30)
        feet = []
        for position, sprites in cells.items():
            for sprite in sprites:
                accent = self.atlas.accentPiece(sprite)
                if accent and accent.kind == "foot":
                    feet.append((position, accent.low))
        feet.sort()
        self.assertEqual(feet, [((6, 0, 0), "N"), ((6, 3, 0), "S")])

    def test_eaves_get_fascia_and_returns_one_level_below(self):
        _, _, cells = self.rakes_follow_gable_walls("grey:45", "white_clapboard:45", 45)
        boards, returns = [], []
        for position, sprites in cells.items():
            for sprite in sprites:
                accent = self.atlas.accentPiece(sprite)
                if accent and accent.kind == "fascia":
                    boards.append(position)
                if accent and accent.kind == "return":
                    returns.append(position)
        # Gable along x: only the south eave is trimmed, on the squares south of
        # the roof one level down; the east gable's front end gets a return.
        self.assertEqual(sorted(boards), [(x, 4, 0) for x in range(6)])
        self.assertEqual(returns, [(6, 4, 0)])

    def test_flat_roofs_get_a_fascia_ring_and_no_rakes(self):
        g = self.lua.globals()
        g.cellList = self.lua.table_from([self.lua.table_from({"x": x, "y": y}) for (x, y) in preview.rect(0, 0, 3, 3)])
        g.request = self.lua.table_from({"z": 1, "kind": "flat"})
        self.lua.execute("request.accents = roof.accents(definitions)[1]")
        placements, reason, _ = self.lua.eval("roof.generate(find(profiles, 'grey:45'), footprint(cellList), request)")
        self.assertIsNone(reason)
        kinds = {}
        for item in preview.pieces(self.lua, placements):
            accent = self.atlas.accentPiece(item["sprite"])
            if accent:
                kinds[accent.kind] = kinds.get(accent.kind, 0) + 1
        self.assertNotIn("rake", kinds)
        # 3x3: three boards under the south eave, three beside the east eave,
        # one block on the south-east corner.
        self.assertIsNone(kinds.get("fasciaCorner"))
        self.assertEqual(kinds.get("block"), 1)
        self.assertEqual(kinds.get("fascia"), 6)


if __name__ == "__main__":
    unittest.main()
