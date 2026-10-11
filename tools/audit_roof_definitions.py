"""Check roof recipes against their authored roles and the installed B42 tiles.

Run: python tools/audit_roof_definitions.py --tiles <game>/media/newtiledefinitions.tiles.txt
The role checks also run when no game installation is available.
"""

import argparse
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ROOF_DIR = ROOT / "Contents/mods/KnoxBuildworks_Vanilla_Expanded/42/media/KnoxBuildworks/definitions/roofing"
WALL_DIR = ROOF_DIR.parent / "walls"
from kbw_paths import TILE_DEFINITIONS as DEFAULT_TILES


def tile_properties(path):
    if not path or not path.exists():
        return None
    text = path.read_text(encoding="utf-8", errors="replace")
    return {
        match.group(1): match.group(2)
        for match in re.finditer(r"// ([A-Za-z_0-9]+)\s+tile\s*\{(.*?)\n    \}", text, re.S)
    }


def audit(tiles_path=None):
    tiles = tile_properties(tiles_path)
    errors = []
    claims = {}
    slope_faces = {}
    sprite_count = 0
    for path in sorted(list(ROOF_DIR.glob("*.json")) + list(WALL_DIR.glob("*.json"))):
        data = json.loads(path.read_text(encoding="utf-8"))
        for definition in data.get("buildables", []):
            for stage in definition.get("stages", []):
                roof = stage.get("roof", {})
                if not roof:
                    continue
                name = definition.get("id", "<unnamed>")
                role = roof.get("role")
                if role in ("slope", "flat"):
                    claim = (roof.get("family"), roof.get("pitch"), role, roof.get("step"))
                    if claim in claims:
                        errors.append(f"{name}: duplicate {claim} (also {claims[claim]})")
                    claims[claim] = name
                faces = (stage.get("geometry") or {}).get("faces") or {}
                if role == "slope":
                    group = (roof.get("family"), roof.get("pitch"))
                    slope_faces.setdefault(group, {})[roof.get("step")] = {
                        face: geometry.get("layers", [{}])[0].get("rows", [[None]])[0][0]
                        for face, geometry in faces.items()
                    }
                    for edge, face in (roof.get("faceByEdge") or {}).items():
                        if face not in faces:
                            errors.append(f"{name}: {edge} maps to missing face {face}")
                for face, part in (roof.get("partsByFace") or {}).items():
                    if face not in faces:
                        errors.append(f"{name}: {part} maps to missing face {face}")
                for face, geometry in faces.items():
                    for layer in geometry.get("layers", []):
                        for row in layer.get("rows", []):
                            for sprite in row:
                                if not sprite:
                                    continue
                                sprite_count += 1
                                if tiles is None:
                                    continue
                                properties = tiles.get(sprite)
                                if properties is None:
                                    errors.append(f"{name}/{face}: missing game sprite {sprite}")
                                    continue
                                if role == "slope" and "BlockRain" not in properties:
                                    errors.append(f"{name}/{face}: slope {sprite} is not a rain-blocking roof")
                                if role == "flat" and "solidfloor" not in properties:
                                    errors.append(f"{name}/{face}: flat roof {sprite} is not a floor")
                                part = (roof.get("partsByFace") or {}).get(face, "")
                                if part.startswith("eave") and "isEave" not in properties:
                                    errors.append(f"{name}/{face}: eave {sprite} lacks the game eave property")
    for group, steps in slope_faces.items():
        expected = 3 if group[1] == 45 else 6 if group[1] == 30 else None
        if expected and sorted(steps) != list(range(1, expected + 1)):
            errors.append(f"{group}: expected slope steps 1 through {expected}, found {sorted(steps)}")
        if expected and len(steps) == expected:
            first = steps[1]
            for face, sprite in first.items():
                match = re.fullmatch(r"(.*_)(\d+)", sprite or "")
                if not match:
                    continue
                numbers = []
                for step in range(1, expected + 1):
                    current = re.fullmatch(r"(.*_)(\d+)", steps[step].get(face, ""))
                    if not current or current.group(1) != match.group(1):
                        errors.append(f"{group}/{face}: slope steps do not share one tile set")
                        break
                    numbers.append(int(current.group(2)))
                if len(numbers) == expected and any(abs(b - a) != 1 or b - a != numbers[1] - numbers[0]
                                                     for a, b in zip(numbers, numbers[1:])):
                    errors.append(f"{group}/{face}: sprite steps are not sequential: {numbers}")
    return errors, sprite_count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tiles", type=Path, default=DEFAULT_TILES)
    args = parser.parse_args()
    errors, count = audit(args.tiles)
    print(f"Checked {count} roof sprite references" + (" against game tiles" if args.tiles else ""))
    for error in errors:
        print(error)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
