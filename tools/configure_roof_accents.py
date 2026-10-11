"""Generate the roof accent buildables (roofs_accents_01, roofs_accents_30_01).

Every non-empty tile of both sheets becomes one buildable, named by what it
trims and which roof it belongs to. The tile meaning was measured from the art
(board line projected back to its wall edge and height) and matches the game's
attachedN/attachedW tile properties; RoofAtlas.accentPiece decodes the same
indices for the Roof Helper. The W face always carries the attachedW tile and
the N face the attachedN tile.

Replaces roofing/roof_trim.json, roofing/roof_trim_30.json and
architecture_plus/roof_accents.json; their ids stay valid as aliases.

    python tools/configure_roof_accents.py
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / "Contents/mods/KnoxBuildworks_Vanilla_Expanded/42/media"
DEFS = MOD / "KnoxBuildworks/definitions"
OUT = DEFS / "roofing/roof_accents.json"
MANIFEST = MOD / "KnoxBuildworks/manifest.json"
TRANSLATE = MOD / "lua/shared/Translate"
OLD_FILES = ["roofing/roof_trim.json", "roofing/roof_trim_30.json", "architecture_plus/roof_accents.json"]
OLD_KEY_PREFIXES = ("IGUI_KBWVE_Buildable_roofing_trim_", "IGUI_KBW_Group_roofing_trim_",
                    "IGUI_KBWVE_Buildable_architecture_plus_roof_accents_")
OLD_KEYS = {"Tooltip_KBWVE_Buildable_RoofTrim"}

S45, S30 = "roofs_accents_01_", "roofs_accents_30_01_"
TRIM, OLD_AP = "kbw.vanillaexpanded.roofing.roof_trim.", "kbw.vanillaexpanded.architecture_plus.roof_accents."
THIRDS = ["Bottom Third", "Middle Third", "Top Third"]
HEIGHTS = {"low": "Low", "third": "One Third Up", "two_thirds": "Two Thirds Up", "top": "Wall Top"}

HAMMER = {"id": "tool_hammer", "role": "tool", "mode": "keep", "resourceType": "Item", "tags": ["base:hammer"],
          "amount": 1, "flags": ["Prop1", "MayDegradeVeryLight"]}
SAW = {"id": "tool_saw", "role": "tool", "mode": "keep", "resourceType": "Item", "tags": ["base:saw", "base:crudesaw"],
       "amount": 1, "flags": ["Prop2", "MayDegradeLight"]}
PLANK = {"id": "lumber", "role": "material", "mode": "consume", "resourceType": "Item", "items": ["Base.Plank"], "amount": 1}
NAILS = {"id": "fasteners_nails", "role": "material", "mode": "consume", "resourceType": "Item", "items": ["Base.Nails"], "amount": 2}
SCREWDRIVER = {"id": "tool_screwdriver", "role": "tool", "mode": "keep", "resourceType": "Item",
               "tags": ["base:screwdriver"], "amount": 1, "flags": ["Prop1", "MayDegradeVeryLight"]}
SHEET = {"id": "small_sheet_metal", "role": "material", "mode": "consume", "resourceType": "Item",
         "items": ["Base.SmallSheetMetal"], "amount": 1}
SCREWS = {"id": "screws", "role": "material", "mode": "consume", "resourceType": "Item", "items": ["Base.Screws"], "amount": 2}
MAGAZINE = "TheFamilyHandyman_StairsFences"

TOOLTIPS = {
    "Tooltip_KBWVE_RoofAccent_Rake": "White trim board for the sloped edge of a gable end facing east or south. Front half: the half that slopes down toward the south (on a north-south wall) or the east (on a west-east wall); back half: the other one. Place it on the same square and level as the gable wall piece of the same height.",
    "Tooltip_KBWVE_RoofAccent_Apex": "Trim board for the peak of a gable end on an odd-width roof, where both halves meet on one square. Place it with the gable wall peak piece of the same height.",
    "Tooltip_KBWVE_RoofAccent_ShallowRake": "Trim board for the sloped edge of a shallow roof's gable end. The eave row sits on the low square, the ridge row next to the ridge.",
    "Tooltip_KBWVE_RoofAccent_Fascia": "Horizontal trim board under a south or east eave, on the square just outside the roof. Wall Top boards go one level below the roof; the lower heights finish eaves that start part-way up a storey and go on the roof's own level.",
    "Tooltip_KBWVE_RoofAccent_FasciaCorner": "Inside corner where a south eave's fascia meets an east eave's fascia on one square.",
    "Tooltip_KBWVE_RoofAccent_Return": "Closes the end of a fascia run under the low end of a gable rake, in the plane of the gable wall.",
    "Tooltip_KBWVE_RoofAccent_Block": "Corner block over the joint where the south and east fascia runs meet at a south-east outside corner.",
    "Tooltip_KBWVE_RoofAccent_Foot": "Lower end of a 30 degree rake board, where it meets the eave. Place it one level below the roof, on the square of the rake's lowest piece.",
    "Tooltip_KBWVE_RoofAccent_DownpipeShoe": "Bottom bend of a rain downpipe that turns the water away from the wall.",
}


def faces(w=None, n=None):
    result = {}
    if w is not None:
        result["W"] = {"layers": [{"rows": [[w]]}]}
    if n is not None:
        result["N"] = {"layers": [{"rows": [[n]]}]}
    return result


def knowledge(alternative):
    return {"recipes": ["KBWKnowledge_" + MAGAZINE], "hideUntilLearned": True, "needToBeLearned": True,
            "sources": [{"type": "magazine", "item": "KnoxBuildworks." + MAGAZINE}],
            "skillAlternatives": [{"mode": "all", "skills": alternative}]}


def wood_stage(geometry, pitch):
    return {"id": "built", "geometry": {"faces": geometry},
            "requirements": {"inputs": [dict(HAMMER), dict(SAW), dict(PLANK), dict(NAILS)],
                             "skills": {"Woodwork": 3}, "knowledge": knowledge({"Woodwork": 7})},
            "construction": {"time": 100, "timedAction": "BuildWallHammer", "completionSound": "BuildWoodenStructureSmall",
                             "xp": {"Woodwork": 10}, "category": "Carpentry"},
            "object": {"isThumpable": True, "blockAllSquare": False, "canPassThrough": True, "canBarricade": False},
            "roof": {"family": "white_trim", "pitch": pitch, "role": "accent"}}


def metal_stage(geometry):
    stage = wood_stage(geometry, 45)
    stage["requirements"] = {"inputs": [dict(SCREWDRIVER), dict(SHEET), dict(SCREWS)],
                             "skills": {"MetalWelding": 1}, "knowledge": knowledge({"MetalWelding": 5})}
    stage["construction"] = {"time": 80, "timedAction": "BuildMetalStructureSmall",
                             "completionSound": "BuildMetalStructureSmall", "xp": {"MetalWelding": 5}, "category": "Metalworking"}
    stage["object"]["isThumpable"] = False
    return stage


# (slug, name, W sprite, N sprite, group slug, level, tooltip, pitch, aliases, metal)
PIECES = []


def piece(slug, name, w, n, group, level, tooltip, pitch=45, aliases=(), metal=False):
    PIECES.append((slug, name, w, n, group, level, tooltip, pitch, list(aliases), metal))


GROUPS = {
    "rake45_front": "45 Degree Gable Rake (Front Half)",
    "rake45_back": "45 Degree Gable Rake (Back Half)",
    "apex45": "45 Degree Gable Apex Trim",
    "shallow_front": "Shallow Gable Rake (Front Half)",
    "shallow_back": "Shallow Gable Rake (Back Half)",
    "fascia": "Eave Fascia Board",
    "fascia_corner": "Eave Fascia Corner",
    "fascia_return": "Fascia End Return",
    "corner_block": "Fascia Corner Block",
    "rake30_front": "30 Degree Gable Rake (Front Half)",
    "rake30_back": "30 Degree Gable Rake (Back Half)",
    "apex30": "30 Degree Gable Apex Trim",
    "foot30": "30 Degree Rake Foot",
}

# 45 degree rakes, one per third of a storey (gable wall keys W/N:low*:k, W/N:peak:k).
for k in range(1, 4):
    third = THIRDS[k - 1]
    piece(f"rake45_front_{k}", f"45 Degree Gable Rake, Front Half - {third}", S45 + str(27 + k), S45 + str(7 - k),
          "rake45_front", k, "Rake", aliases=[TRIM + f"fascia_2_{4 - k}",
                                              OLD_AP + ["slope_trim_accent_big_bottom", "slope_trim_accent_big_middle", "slope_trim_accent_big_top"][k - 1]])
    piece(f"rake45_back_{k}", f"45 Degree Gable Rake, Back Half - {third}", S45 + str(35 + k), S45 + str(15 - k),
          "rake45_back", k, "Rake", aliases=[TRIM + f"fascia_3_{4 - k}",
                                             OLD_AP + ["eave_trim_middle", "eave_trim_bottom", "eave_trim_top"][k - 1]])
    piece(f"apex45_{k}", f"45 Degree Gable Apex Trim - {third}", S45 + str(23 + k), S45 + str(35 - k),
          "apex45", k, "Apex", aliases=[TRIM + f"fascia_4_{k}"])

# Shallow roof rakes: an eave row and a ridge row on each half.
piece("shallow_front_eave", "Shallow Gable Rake, Front Half - Eave Row", S45 + "8", S45 + "3", "shallow_front", 1,
      "ShallowRake", "shallow", [TRIM + "fascia_1_4", OLD_AP + "slope_trim_accent_1_south_east_side"])
piece("shallow_front_ridge", "Shallow Gable Rake, Front Half - Ridge Row", S45 + "9", S45 + "2", "shallow_front", 2,
      "ShallowRake", "shallow", [TRIM + "fascia_1_3", OLD_AP + "slope_trim_accent_2_south_east_side"])
piece("shallow_back_eave", "Shallow Gable Rake, Back Half - Eave Row", S45 + "11", S45 + "0", "shallow_back", 1,
      "ShallowRake", "shallow", [TRIM + "fascia_1_1", OLD_AP + "slope_trim_accent_1_north_west_side"])
piece("shallow_back_ridge", "Shallow Gable Rake, Back Half - Ridge Row", S45 + "10", S45 + "1", "shallow_back", 2,
      "ShallowRake", "shallow", [TRIM + "fascia_1_2", OLD_AP + "slope_trim_accent_2_north_west_side"])

# Eave fascia boards by height within the storey (1/6, 1/3, 2/3, wall top).
piece("fascia_low", "Eave Fascia Board - Low", S45 + "18", S45 + "17", "fascia", 1, "Fascia",
      aliases=[TRIM + "fascia_6_1", OLD_AP + "fascia_accent_bottom"])
piece("fascia_third", "Eave Fascia Board - One Third Up", S45 + "41", S45 + "40", "fascia", 2, "Fascia",
      aliases=[TRIM + "fascia_7_1"])
piece("fascia_two_thirds", "Eave Fascia Board - Two Thirds Up", S45 + "50", S45 + "51", "fascia", 3, "Fascia",
      aliases=[TRIM + "fascia_8_1"])
# The vanilla map pairs 45 (south eaves) with 22 (east eaves) under sloped roofs.
piece("fascia_top", "Eave Fascia Board - Wall Top", S45 + "22", S45 + "45", "fascia", 4, "Fascia",
      aliases=[TRIM + "fascia_5_1", OLD_AP + "fascia_accent_top"])
piece("fascia_top_alt", "Eave Fascia Board - Wall Top (Alternate)", S45 + "21", S45 + "44", "fascia", 5, "Fascia",
      aliases=[TRIM + "fascia_5_2"])
for level, (key, index, alias) in enumerate([("low", 15, "fascia_corner_1"), ("third", 42, "fascia_corner_3"),
                                             ("two_thirds", 48, "fascia_corner_4"), ("top", 23, "fascia_corner_2")], 1):
    piece(f"fascia_corner_{key}", f"Eave Fascia Corner - {HEIGHTS[key]}", S45 + str(index), None, "fascia_corner",
          level, "FasciaCorner", aliases=[TRIM + alias])
for level, (key, w, n, alias, extra) in enumerate([("third", 54, 55, "downpipe_7", None),
                                                   ("two_thirds", 52, 49, "downpipe_5", None),
                                                   ("top", 46, 20, "downpipe_2", "fascia_accent_top_corner_slope")], 1):
    piece(f"fascia_return_{key}", f"Fascia End Return - {HEIGHTS[key]}", S45 + str(w), S45 + str(n), "fascia_return",
          level, "Return", aliases=[TRIM + alias] + ([OLD_AP + extra] if extra else []))
for level, (key, index, alias, extra) in enumerate([("third", 43, "downpipe_3", None), ("two_thirds", 53, "downpipe_6", None),
                                                    ("top", 47, "downpipe_4", "fascia_accent_top_corner")], 1):
    piece(f"corner_block_{key}", f"Fascia Corner Block - {HEIGHTS[key]}", S45 + str(index), None, "corner_block",
          level, "Block", aliases=[TRIM + alias] + ([OLD_AP + extra] if extra else []))
piece("downpipe_shoe", "Downpipe Shoe", S45 + "16", S45 + "19", None, None, "DownpipeShoe",
      aliases=[TRIM + "downpipe_1", OLD_AP + "fascia_accent_bottom_corner"], metal=True)

# 30 degree rakes: the same 48-tile layout as the 30 degree gable wall sheets.
for k in range(1, 7):
    piece(f"rake30_front_{k}", f"30 Degree Gable Rake, Front Half - Step {k}", S30 + str(k - 1), S30 + str(30 - k),
          "rake30_front", k, "Rake", 30, [TRIM + f"trim_30_fascia_{k}"])
    piece(f"rake30_back_{k}", f"30 Degree Gable Rake, Back Half - Step {k}", S30 + str(14 - k), S30 + str(15 + k),
          "rake30_back", k, "Rake", 30)
    piece(f"apex30_{k}", f"30 Degree Gable Apex Trim - Step {k}", S30 + str(31 + k), S30 + str(39 + k),
          "apex30", k, "Apex", 30, [TRIM + f"trim_30_fascia_peak_{k}"])
# Rake feet hang one level below the roof, under a rake's eave end.
piece("foot30_front", "30 Degree Rake Foot - Front Half", S30 + "6", S30 + "30", "foot30", 1, "Foot", 30,
      [TRIM + "trim_30_fascia_7"])
piece("foot30_back", "30 Degree Rake Foot - Back Half", S30 + "14", S30 + "22", "foot30", 2, "Foot", 30)


def buildables():
    result = []
    for slug, name, w, n, group, level, tooltip, pitch, aliases, metal in PIECES:
        geometry = faces(w, n)
        definition = {
            "id": "kbw.vanillaexpanded.roofing.roof_accents." + slug,
            "translationKey": "IGUI_KBWVE_Buildable_roofing_accents_" + slug,
            "displayName": name,
            "tooltipKey": "Tooltip_KBWVE_RoofAccent_" + tooltip,
            "category": "Roofing",
            "subcategory": "Roof Accents",
            "material": "Metal" if metal else "Wood",
            "iconSprite": w,
            "placement": {"kind": "object"},
            "stages": [metal_stage(geometry) if metal else wood_stage(geometry, pitch)],
        }
        if aliases:
            definition["aliases"] = aliases
        if group:
            definition["group"] = {"id": "kbw.vanillaexpanded.group.roofing.roof_accents." + group, "level": level,
                                   "name": GROUPS[group], "translationKey": "IGUI_KBW_Group_roofing_accents_" + group}
        definition["allowSpriteReuse"] = True
        result.append(definition)
    return result


def strings():
    ig = {"IGUI_KBW_Subcategory_Roof_Accents": "Roof Accents"}
    for slug, name, *_ in PIECES:
        ig["IGUI_KBWVE_Buildable_roofing_accents_" + slug] = name
    for group, name in GROUPS.items():
        ig["IGUI_KBW_Group_roofing_accents_" + group] = name
    return ig, dict(TOOLTIPS)


def edit_translation(path, add=None):
    """Drop retired keys and set `add`, editing lines so other entries keep their formatting."""
    if not path.exists():
        return
    lines = path.read_text(encoding="utf-8").splitlines()
    kept = []
    for line in lines:
        match = re.match(r'\s*"([^"]+)"\s*:', line)
        if match and (match.group(1).startswith(OLD_KEY_PREFIXES) or match.group(1) in OLD_KEYS
                      or (add and match.group(1) in add)):
            continue
        kept.append(line)
    close = max(i for i, line in enumerate(kept) if line.strip() == "}")
    body = [line for line in kept[:close]]
    for key, value in (add or {}).items():
        body.append("  " + json.dumps(key) + ": " + json.dumps(value, ensure_ascii=False) + ",")
    entries = [i for i, line in enumerate(body) if re.match(r'\s*"', line)]
    for i in entries:
        body[i] = body[i].rstrip().rstrip(",") + ("," if i != entries[-1] else "")
    path.write_text("\n".join(body + kept[close:]) + "\n", encoding="utf-8")
    json.loads(path.read_text(encoding="utf-8"))


def main():
    data = {"schemaVersion": 1, "buildables": buildables()}
    OUT.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    entries = manifest["definitions"]
    target = "media/KnoxBuildworks/definitions/roofing/roof_accents.json"
    old = ["media/KnoxBuildworks/definitions/" + name for name in OLD_FILES]
    position = next((i for i, entry in enumerate(entries) if entry in old), len(entries))
    entries = [entry for entry in entries if entry not in old and entry != target]
    entries.insert(min(position, len(entries)), target)
    manifest["definitions"] = entries
    MANIFEST.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    for name in OLD_FILES:
        path = DEFS / name
        if path.exists():
            path.unlink()

    ig, tooltips = strings()
    for language in sorted(p.name for p in TRANSLATE.iterdir() if p.is_dir()):
        english = language == "EN"
        edit_translation(TRANSLATE / language / "IG_UI.json", ig if english else None)
        edit_translation(TRANSLATE / language / "Tooltip.json", tooltips if english else None)
    print(f"{len(data['buildables'])} roof accent buildables -> {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
