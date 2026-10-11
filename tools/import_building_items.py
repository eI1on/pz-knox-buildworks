"""Import the author's Buildables Expansion art into the core Knox Buildworks mod.

Run explicitly with the old mod's common/media directory. Items and magazines
are written to the core items script (after ITEMS_MARKER), their models to
knox_buildworks_models.txt and their art under the core KBW names. This does not
copy Lua or overwrite Base items, models, distributions, or the source mod.
"""
import argparse
import json
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MEDIA = ROOT / "Contents/mods/KnoxBuildworks/42/media"
ITEMS_MARKER = "    /* Building components and the magazines that unlock buildables. */\n"


def blocks(text, kind):
    for match in re.finditer(r"\b" + kind + r"\s+(\w+)\s*\{", text):
        start, depth, end = match.end(), 1, match.end()
        while depth:
            depth += (text[end] == "{") - (text[end] == "}")
            end += 1
        yield match.group(1), text[start:end - 1]


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def run(source):
    models = dict(blocks((source / "scripts/models/BuildablesExpansion_Models.txt").read_text(), "model"))
    items = dict(blocks((source / "scripts/items/BuildablesExpansion_Items.txt").read_text(), "item"))
    magazines = [name for name, body in items.items() if "TeachedRecipes" in body]
    materials = ["RefrigerantBottle", "RefrigeratorCompressor", "PlasticSheet", "PlasticSheetSmall",
                 "InsulationFoam", "SmallRubberTube", "ThinCopperPipe", "RubberSeal"]
    names_path = MEDIA / "lua/shared/Translate/EN/ItemName.json"
    names = json.loads(names_path.read_text(encoding="utf-8"))
    recipes_path = MEDIA / "lua/shared/Translate/EN/Recipes.json"
    recipes = json.loads(recipes_path.read_text(encoding="utf-8"))
    output, model_output, used_models, assets = [], [], set(), []

    def copy_asset(relative, target):
        destination = MEDIA / target
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / relative, destination)
        assets.append(str(target).replace("\\", "/"))

    for name in magazines + materials:
        fields = dict(re.findall(r"(\w+)[ \t]*=[ \t]*([^,\r\n]*),", items[name]))
        icon = fields["Icon"].strip()
        if (source / f"textures/Item_{icon}.png").exists():
            copy_asset(Path(f"textures/Item_{icon}.png"), Path(f"textures/Item_KBW_{icon}.png"))
            icon = "KBW_" + icon
        model = fields.get("WorldStaticModel", fields.get("WeaponSprite", "")).strip()
        used_models.add(model)
        display = fields.get("DisplayName", name).strip()
        names[f"KnoxBuildworks.{name}"] = display
        props = {"DisplayCategory": "SkillBook" if name in magazines else "Material",
                 "ItemType": "base:literature" if name in magazines else "base:normal",
                 "Weight": fields["Weight"].strip(), "Icon": icon,
                 "WorldStaticModel": "KnoxBuildworks.KBW_" + model}
        if name in magazines:
            props.update({"StaticModel": "Magazine", "Tags": "base:magazine",
                          "LearnedRecipes": "KBWKnowledge_" + name, "NumberOfPages": "20"})
            recipes["KBWKnowledge_" + name] = display
        elif name in ("RefrigerantBottle", "SmallRubberTube"):
            props.update({"ItemType": "base:drainable", "UseDelta": "0.1", "UseWhileEquipped": "false"})
        output.append("    item " + name + "\n    {\n" + "".join(f"        {k} = {v},\n" for k, v in props.items()) + "    }\n")
    for name in sorted(used_models):
        body = models[name]
        mesh = re.search(r"mesh\s*=\s*([^,\s]+)", body).group(1)
        mesh_file = source / ("models_X/" + mesh + ".fbx")
        if mesh_file.exists():
            target = "WorldItems/KBW" + mesh_file.stem
            copy_asset(Path("models_X/" + mesh + ".fbx"), Path("models_X/" + target + ".fbx"))
            body = re.sub(r"mesh\s*=\s*[^,\s]+", "mesh = " + target, body)
        texture_match = re.search(r"texture\s*=\s*([^,\s]+)", body)
        texture = texture_match.group(1) if texture_match else mesh
        texture_file = source / ("textures/" + texture + ".png")
        if texture_file.exists():
            target = "WorldItems/KBW" + texture_file.stem
            copy_asset(Path("textures/" + texture + ".png"), Path("textures/" + target + ".png"))
            if texture_match:
                body = re.sub(r"texture\s*=\s*[^,\s]+", "texture = " + target, body)
            else:
                body += "        texture = " + target + ",\n"
        model_output.append("    model KBW_" + name + "\n    {" + body + "    }\n")
    items_path = MEDIA / "scripts/knox_buildworks_items.txt"
    core_items = items_path.read_text()
    if ITEMS_MARKER in core_items:
        core_items = core_items[:core_items.index(ITEMS_MARKER)].rstrip() + "\n\n"
    else:
        core_items = core_items.rstrip()[:-1].rstrip() + "\n\n"
    items_path.write_text(core_items + ITEMS_MARKER + "\n" + "\n".join(output) + "}\n")
    (MEDIA / "scripts/knox_buildworks_models.txt").write_text("module KnoxBuildworks\n{\n" + "\n".join(model_output) + "}\n")
    write_json(names_path, names)
    write_json(recipes_path, recipes)
    write_json(ROOT / "docs/building-items.json", {"source": "Buildables Expansion (3463117260), author's supplied copy",
        "permission": "Owner requested reuse in Knox Buildworks", "items": materials, "magazines": magazines,
        "assets": sorted(set(assets))})
    print(f"Imported {len(materials)} materials, {len(magazines)} magazines and {len(set(assets))} assets")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    run(parser.parse_args().source)
