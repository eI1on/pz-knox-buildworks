"""Add the missing 45 degree roof pieces and name the odd-span ones properly.

The roofs_01..05 sheets hold two families each (blocks at 0 and 32) plus
per-sheet extras. Meanings come from BuildingEd's roof_slopes table
(TileZed/BuildingTiles.txt), the tile art and the vanilla map; RoofAtlas
decodes the same indices. This script

* writes roofing/roof_pieces_45.json with the pieces no buildable used yet:
  odd-span ridges for sage green, pink and white, 2.5-step ridges, alternate
  ridge art, raised flats and the slope edge variants of roofs_03/04;
* renames the existing odd-span pieces (ridges at 1.5 and 2.5 steps, ridge
  junctions, hip ends) in every family file and the English translations.

Requirements are copied from each family's own slope (or flat) piece.

    python tools/configure_roof_pieces_45.py
"""
import copy
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / "Contents/mods/KnoxBuildworks_Vanilla_Expanded/42/media"
ROOFING = MOD / "KnoxBuildworks/definitions/roofing"
OUT = ROOFING / "roof_pieces_45.json"
MANIFEST = MOD / "KnoxBuildworks/manifest.json"
EN = MOD / "lua/shared/Translate/EN"

FAMILIES = {  # family -> (definition file, sheet, block base)
    "black": ("black_roofs.json", "roofs_01", 0), "brown_shakes": ("brown_shakes_roofs.json", "roofs_01", 32),
    "brown_shingles": ("brown_shingles_roofs.json", "roofs_02", 0), "glass": ("glass_roofs.json", "roofs_02", 32),
    "light_brown": ("light_brown_roofs.json", "roofs_03", 0), "sage_green": ("sage_green_roofs.json", "roofs_03", 32),
    "pink": ("pink_roofs.json", "roofs_04", 0), "white": ("white_roofs.json", "roofs_04", 32),
    "green": ("green_roofs.json", "roofs_05", 0), "grey": ("grey_roofs.json", "roofs_05", 32),
}
HALF = {1: "0.5", 2: "1.5", 3: "2.5"}

# (family, slug, name suffix, W sprite index, N sprite index, kind)
NEW = [
    ("sage_green", "odd_ridge", "Odd-Span Ridge (1.5 Steps)", 47, 46, "ridge"),
    ("sage_green", "odd_ridge_alt", "Odd-Span Ridge (1.5 Steps, Alternate)", 49, 48, "ridge"),
    ("sage_green", "odd_ridge_high", "Odd-Span Ridge (2.5 Steps)", 103, 102, "ridge"),
    ("sage_green", "raised_flat_1", "Raised Flat Roof (1 Step)", 122, None, "flat"),
    ("sage_green", "raised_flat_1_alt", "Raised Flat Roof (1 Step, Alternate)", 123, None, "flat"),
    ("sage_green", "raised_flat_2", "Raised Flat Roof (2 Steps)", 124, None, "flat"),
    ("sage_green", "raised_flat_2_alt", "Raised Flat Roof (2 Steps, Alternate)", 125, None, "flat"),
    ("light_brown", "odd_ridge_alt", "Odd-Span Ridge (1.5 Steps, Alternate)", 17, 16, "ridge"),
    ("pink", "odd_ridge", "Odd-Span Ridge (1.5 Steps)", 15, 14, "ridge"),
    ("pink", "odd_ridge_alt", "Odd-Span Ridge (1.5 Steps, Alternate)", 17, 16, "ridge"),
    ("pink", "odd_ridge_high", "Odd-Span Ridge (2.5 Steps)", 71, 70, "ridge"),
    ("pink", "raised_flat_1", "Raised Flat Roof (1 Step)", 90, None, "flat"),
    ("pink", "raised_flat_1_alt", "Raised Flat Roof (1 Step, Alternate)", 91, None, "flat"),
    ("pink", "raised_flat_2", "Raised Flat Roof (2 Steps)", 92, None, "flat"),
    ("pink", "raised_flat_2_alt", "Raised Flat Roof (2 Steps, Alternate)", 93, None, "flat"),
    ("white", "odd_ridge", "Odd-Span Ridge (1.5 Steps)", 47, 46, "ridge"),
    ("white", "odd_ridge_alt", "Odd-Span Ridge (1.5 Steps, Alternate)", 65, 64, "ridge"),
    ("white", "odd_ridge_high", "Odd-Span Ridge (2.5 Steps)", 103, 102, "ridge"),
    ("white", "raised_flat_1", "Raised Flat Roof (1 Step)", 48, None, "flat"),
    ("white", "raised_flat_1_alt", "Raised Flat Roof (1 Step, Alternate)", 49, None, "flat"),
    ("white", "raised_flat_2", "Raised Flat Roof (2 Steps)", 50, None, "flat"),
    ("white", "raised_flat_2_alt", "Raised Flat Roof (2 Steps, Alternate)", 51, None, "flat"),
]
# Slope edge variants (roofs_03/04 rows 9 and 13): south-facing tile on W,
# east-facing tile on N, steps 1 and 2, two edge treatments each.
for family, base in (("light_brown", 72), ("sage_green", 104), ("pink", 72), ("white", 104)):
    for variant, (s1, e1, s2, e2) in (("A", (0, 5, 1, 4)), ("B", (2, 7, 3, 6))):
        NEW.append((family, f"slope_edge_{variant.lower()}_1", f"Pitched Slope 1 (Edge Variant {variant})",
                    base + s1, base + e1, "slope"))
        NEW.append((family, f"slope_edge_{variant.lower()}_2", f"Pitched Slope 2 (Edge Variant {variant})",
                    base + s2, base + e2, "slope"))

TOOLTIPS = {
    "Tooltip_KBWVE_RoofPiece_OddRidge": "Ridge for a roof with an odd number of squares across: the middle row sits half a step above the slopes beside it. The 1.5-step piece goes above step 1 slopes, the 2.5-step piece above step 2 slopes; one square south-east of its place the 1.5-step piece draws half a step high.",
    "Tooltip_KBWVE_RoofPiece_Junction": "Where two odd-span ridges meet in an L over a south-east valley.",
    "Tooltip_KBWVE_RoofPiece_HipEnd": "Hip end of an odd-span hip roof, where the half-step ridge meets the hips.",
    "Tooltip_KBWVE_RoofPiece_RaisedFlat": "Flat roof drawn one or two steps above the floor of its level, for a flat top part-way up a storey.",
    "Tooltip_KBWVE_RoofPiece_EdgeVariant": "The pitched slope with a different board edge, for finishing the end of a slope run.",
}


def family_label(definition):
    return (definition.get("subcategory") or "").replace(" Roofs", "")


def template(buildables, role):
    for definition in buildables:
        stage = definition["stages"][0]
        if (stage.get("roof") or {}).get("role") == role:
            return definition
    return None


def faces(w, n):
    out = {"W": {"layers": [{"rows": [[w]]}]}}
    if n:
        out["N"] = {"layers": [{"rows": [[n]]}]}
    return out


def build_new():
    result, strings = [], {}
    for family, slug, suffix, w, n, kind in NEW:
        path, sheet, _base = FAMILIES[family]
        buildables = json.loads((ROOFING / path).read_text(encoding="utf-8"))["buildables"]
        source = template(buildables, "flat" if kind == "flat" else "slope")
        definition = copy.deepcopy(source)
        stage = definition["stages"][0]
        label = family_label(source)
        key = f"{family}_{slug}"
        definition["id"] = f"kbw.vanillaexpanded.roofing.roof_pieces_45.{key}"
        definition["translationKey"] = f"IGUI_KBWVE_Buildable_roofing_pieces45_{key}"
        definition["displayName"] = f"{label} {suffix}"
        definition["tooltipKey"] = {"ridge": "Tooltip_KBWVE_RoofPiece_OddRidge", "flat": "Tooltip_KBWVE_RoofPiece_RaisedFlat",
                                    "slope": "Tooltip_KBWVE_RoofPiece_EdgeVariant"}[kind]
        definition["iconSprite"] = f"{sheet}_{w}"
        for field in ("aliases", "group"):
            definition.pop(field, None)
        stage.pop("sprites", None)
        stage["geometry"] = {"faces": faces(f"{sheet}_{w}", f"{sheet}_{n}" if n is not None else None)}
        stage["roof"] = {"family": family, "pitch": 45, "role": "detail"}
        definition["allowSpriteReuse"] = True
        result.append(definition)
        strings[definition["translationKey"]] = definition["displayName"]
    return result, strings


TWO_PT5 = {("roofs_03", 32): {102, 103}, ("roofs_04", 32): {102, 103}}
EXTRA_FILES = {"light_brown": ["light_brown_roof_extras.json"]}


def rename_existing():
    """Name odd-span pieces by what they are; returns {translationKey: name}."""
    strings = {}
    for family, (path, sheet, base) in FAMILIES.items():
        for name_ in [path] + EXTRA_FILES.get(family, []):
            file = ROOFING / name_
            data = json.loads(file.read_text(encoding="utf-8"))
            changed = False
            two = TWO_PT5.get((sheet, base), {70, 71} if base == 0 else {78, 79})
            for definition in data["buildables"]:
                sprites = sorted(set(re.findall(r'"(roofs_0\d_\d+)"', json.dumps(definition["stages"]))))
                indices = {int(s.rsplit("_", 1)[1]) for s in sprites if s.startswith(sheet + "_")}
                if not indices:
                    continue
                name = None
                label = family_label(definition)
                if indices <= {base + 14, base + 15}:
                    name = "Odd-Span Ridge (1.5 Steps)"
                elif indices <= two:
                    name = "Odd-Span Ridge (2.5 Steps)"
                elif sheet in ("roofs_01", "roofs_02", "roofs_05"):
                    outer, inner = (64, 67) if base == 0 else (72, 75)
                    if len(indices) == 1:
                        index = next(iter(indices))
                        if outer <= index < outer + 3:
                            name = f"Odd-Span Hip End ({HALF[index - outer + 1]} Steps)"
                            definition["tooltipKey"] = "Tooltip_KBWVE_RoofPiece_HipEnd"
                        elif inner <= index < inner + 3:
                            name = f"Odd-Span Ridge Junction ({HALF[index - inner + 1]} Steps)"
                            definition["tooltipKey"] = "Tooltip_KBWVE_RoofPiece_Junction"
                if name and name.startswith("Odd-Span Ridge ("):
                    definition["tooltipKey"] = "Tooltip_KBWVE_RoofPiece_OddRidge"
                if name:
                    changed = True
                    full = f"{label} {name}"
                    if definition.get("displayName") != full:
                        definition["displayName"] = full
                        changed = True
                    strings[definition["translationKey"]] = full
            if changed:
                file.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return strings


def set_strings(path, values):
    lines = path.read_text(encoding="utf-8").splitlines()
    keys = set(values)
    kept = [line for line in lines if not (re.match(r'\s*"([^"]+)"\s*:', line)
                                           and re.match(r'\s*"([^"]+)"\s*:', line).group(1) in keys)]
    close = max(i for i, line in enumerate(kept) if line.strip() == "}")
    body = kept[:close]
    for key, value in values.items():
        body.append("  " + json.dumps(key) + ": " + json.dumps(value, ensure_ascii=False) + ",")
    entries = [i for i, line in enumerate(body) if re.match(r'\s*"', line)]
    for i in entries:
        body[i] = body[i].rstrip().rstrip(",") + ("," if i != entries[-1] else "")
    path.write_text("\n".join(body + kept[close:]) + "\n", encoding="utf-8")
    json.loads(path.read_text(encoding="utf-8"))


def main():
    renamed = rename_existing()
    buildables, strings = build_new()
    OUT.write_text(json.dumps({"schemaVersion": 1, "buildables": buildables}, indent=2, ensure_ascii=False) + "\n",
                   encoding="utf-8")
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    entry = "media/KnoxBuildworks/definitions/roofing/roof_pieces_45.json"
    if entry not in manifest["definitions"]:
        anchor = "media/KnoxBuildworks/definitions/roofing/white_shallow_roofs.json"
        index = manifest["definitions"].index(anchor) + 1 if anchor in manifest["definitions"] else len(manifest["definitions"])
        manifest["definitions"].insert(index, entry)
        MANIFEST.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    renamed.update(strings)
    set_strings(EN / "IG_UI.json", renamed)
    set_strings(EN / "Tooltip.json", TOOLTIPS)
    print(f"{len(buildables)} new pieces, {len(renamed) - len(strings)} renamed")


if __name__ == "__main__":
    main()
