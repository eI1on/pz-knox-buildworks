"""Apply reviewed progression/material mappings to the expanded catalogue (idempotent)."""
import collections
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MEDIA = ROOT / "Contents/mods/KnoxBuildworks/42/media"
EXPANDED = ROOT / "Contents/mods/KnoxBuildworks_Vanilla_Expanded/42/media/KnoxBuildworks/definitions"
FWW = "FineWoodWorking_"


def magazine_for(path, definition):
    category = definition.get("category", "")
    sub = definition.get("subcategory", "").lower()
    name = definition.get("displayName", "").lower()
    relative = path.relative_to(EXPANDED).as_posix()
    if relative == "appliances/bathroom.json": return "HomeMechanix_Bathroom", "Woodwork", 6
    if relative.startswith("appliances/") or category == "Appliances": return "PopularMechanics_HomeAppliances", "Electricity", 7
    if relative.startswith("lighting/"): return "PopularMechanics_Lighting", "Electricity", 5
    if category == "Roofing" or relative.startswith("structural/"): return "TheFamilyHandyman_StairsFences", "Woodwork", 7
    if category in ("Stairs", "Fencing"): return "TheFamilyHandyman_StairsFences", "Woodwork", 6
    if category in ("Doors", "Windows"): return FWW + "DoorsWindows", "Woodwork", 6
    if relative in ("decorations/rugs.json",) or sub == "carpets": return "ArchitecturalDigest_RugsCarpets", "Tailoring", 5
    if category == "Floors":
        if sub == "wooden": return "OldHouseJournal_WoodenFloors", "Woodwork", 5
        return "FlooringGuide_Ceramic", "Masonry", 5
    if relative.startswith("road_work/"):
        return ("FlooringGuide_Paved", "Masonry", 5) if any(x in relative for x in ("asphalt", "dirt", "sidewalk")) else ("DecorationsGuide_RoadwayGarage", "Woodwork", 5)
    if relative in ("decorations/garage.json", "decorations/roadway.json", "decorations/signs.json"): return "DecorationsGuide_RoadwayGarage", "Woodwork", 5
    if category in ("Furniture", "Containers"):
        if any(x in sub for x in ("metal", "locker", "filing")): return "ProjectsInMetal_Diverse", "MetalWelding", 6
        if any(x in sub for x in ("bed", "couch")) or "armchair" in name: return FWW + "Furniture_BedsCouchesArmchairs", "Woodwork", 6
        if any(x in sub for x in ("chair", "bench")): return FWW + "Furniture_ChairsBenches", "Woodwork", 5
        if "dresser" in sub or "clothing" in sub: return FWW + "Furniture_Dressers", "Woodwork", 6
        if "crate" in sub: return FWW + "Furniture_Crates", "Woodwork", 5
        if any(x in sub for x in ("counter", "restaurant")): return FWW + "Furniture_Counters", "Woodwork", 6
        return FWW + "Furniture_DesksTables", "Woodwork", 6
    if definition.get("material") == "Metal": return "ProjectsInMetal_Diverse", "MetalWelding", 6
    return None


def input_row(name, amount=1, drain=False):
    return {"id": "expansion_" + name.lower(), "role": "component", "mode": "drain" if drain else "consume",
            "items": ["KnoxBuildworks." + name], "uses" if drain else "amount": amount}


def run():
    counts = collections.Counter()
    for path in sorted(EXPANDED.rglob("*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        original = json.dumps(data)
        for definition in data.get("buildables", []):
            gate = magazine_for(path, definition)
            for stage in definition.get("stages", []):
                req = stage.setdefault("requirements", {})
                if gate:
                    name, perk, level = gate
                    knowledge = req.setdefault("knowledge", {})
                    recipes = knowledge.setdefault("recipes", [])
                    recipe = "KBWKnowledge_" + name
                    if recipe not in recipes: recipes.append(recipe)
                    knowledge["hideUntilLearned"] = True
                    knowledge["needToBeLearned"] = True
                    sources = knowledge.setdefault("sources", [])
                    source = "KnoxBuildworks." + name
                    sources[:] = [value for value in sources if value != source]
                    if not any(isinstance(value, dict) and value.get("item") == source for value in sources):
                        sources.append({"type": "magazine", "item": source})
                    skills = dict(req.get("skills", {}))
                    skills[perk] = max(level, skills.get(perk, 0))
                    knowledge["skillAlternatives"] = [{"mode": "all", "skills": skills}]
                    counts[name] += 1
                # These parts supplement the existing structure/tools, rather than
                # replacing the original buildable's exact quantities or callbacks.
                relative = path.relative_to(EXPANDED).as_posix()
                parts = []
                if relative == "appliances/refrigeration.json" or (definition.get("category") == "Appliances" and definition.get("subcategory") == "Refrigeration"):
                    parts = [input_row("RefrigeratorCompressor"), input_row("RefrigerantBottle", 2, True),
                             input_row("InsulationFoam", 2), input_row("ThinCopperPipe", 2), input_row("RubberSeal", 2), input_row("PlasticSheet", 2)]
                elif relative in ("appliances/bathroom.json", "appliances/laundry.json"):
                    parts = [input_row("SmallRubberTube", 2, True), input_row("RubberSeal"), input_row("ThinCopperPipe"), input_row("PlasticSheetSmall")]
                if parts:
                    inputs = req.setdefault("inputs", [])
                    present = {row["id"] for row in inputs}
                    inputs.extend(row for row in parts if row["id"] not in present)
        if json.dumps(data) != original:
            path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    (ROOT / "docs/magazine-progression.json").write_text(json.dumps(dict(sorted(counts.items())), indent=2) + "\n")
    print(f"Gated {sum(counts.values())} stages using {len(counts)} magazines")


if __name__ == "__main__":
    run()
