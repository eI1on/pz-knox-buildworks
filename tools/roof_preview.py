"""Render Roof Helper layouts with the game's own tile art and check tile joins.

Runs the shipped Lua planner under Lua 5.1 (lupa), so what you see is what the
helper places in game. Needs `pip install lupa pillow` and the 2x tile sheets
from Project Zomboid Modding Tools.

Examples:
  python tools/roof_preview.py --profile brown_shingles:45 --gable white_clapboard:45 --shape L
  python tools/roof_preview.py --profile black:30 --shape U --top 4 --out roof_u.png
  python tools/roof_preview.py --list

Seam check: every pair of neighbouring roof tiles the planner emits is compared
with media/seams.txt, the game's list of tiles that join east/south of each
other. Exact pieces always agree; only deliberate stand-ins (a 45 degree set has
no south-west valley tile) may be reported.
"""
import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / "Contents/mods/KnoxBuildworks/42/media/lua"
DEFS = ROOT / "Contents/mods/KnoxBuildworks_Vanilla_Expanded/42/media/KnoxBuildworks/definitions"
from kbw_paths import MODDING_TILES_2X as DEFAULT_TILES, SEAMS as DEFAULT_SEAMS


def rect(x, y, w, h):
    return [(i, j) for i in range(x, x + w) for j in range(y, y + h)]


SHAPES = {
    "rect": rect(0, 0, 8, 6),
    "odd": rect(0, 0, 7, 5),
    "square": rect(0, 0, 6, 6),
    "L": rect(0, 0, 10, 4) + rect(0, 4, 4, 5),
    "T": rect(0, 0, 12, 4) + rect(4, 4, 4, 5),
    "U": rect(0, 0, 10, 4) + rect(0, 4, 3, 4) + rect(7, 4, 3, 4),
    "plus": rect(4, 0, 4, 12) + rect(0, 4, 12, 4),
    "court": [c for c in rect(0, 0, 12, 12) if not (4 <= c[0] < 8 and 4 <= c[1] < 8)],
    "steps": rect(0, 0, 4, 4) + rect(0, 4, 8, 4) + rect(0, 8, 12, 4),
}


def runtime():
    from lupa import lua51
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute("modules={}; function require(n) return modules[n] end")
    for name in ("RoomShape", "RoofAtlas", "RoofPlanner"):
        source = (LUA / f"shared/KnoxBuildworks/Planning/{name}.lua").read_text(encoding="utf-8")
        lua.globals().modules[f"KnoxBuildworks/Planning/{name}"] = lua.execute(source)
    definitions = []
    for path in sorted(DEFS.rglob("*.json")):
        definitions.extend(json.loads(path.read_text(encoding="utf-8")).get("buildables", []))
    lua.globals().definitions = lua.table_from(definitions, recursive=True)
    lua.execute("""
        roof=modules['KnoxBuildworks/Planning/RoofPlanner']
        profiles=roof.profiles(definitions); gables=roof.gables(definitions)
        byId={}; for i=1,#definitions do byId[definitions[i].id]=definitions[i] end
        function find(list,id) for i=1,#list do if list[i].id==id then return list[i] end end end
        function spriteOf(p)
            local d=byId[p.buildableId]
            for i=1,#d.stages do local s=d.stages[i]
                if s.id==p.stageId then return roof.faceSprite(s,({'W','N','E','S'})[p.direction]) end end
        end
        function kindOf(p) return byId[p.buildableId].placement.kind end
        function footprint(cells)
            local fp={cells={},list={},abut={},blocked={},z=0,roomIds={}}
            for i=1,#cells do local c=cells[i]
                if not fp.cells[c.x..':'..c.y] then fp.cells[c.x..':'..c.y]=true; fp.list[#fp.list+1]={x=c.x,y=c.y} end end
            table.sort(fp.list,function(a,b) return a.y==b.y and a.x<b.x or a.y<b.y end)
            local minX,minY,maxX,maxY=fp.list[1].x,fp.list[1].y,fp.list[1].x,fp.list[1].y
            for i=1,#fp.list do local c=fp.list[i]
                minX=math.min(minX,c.x); maxX=math.max(maxX,c.x); minY=math.min(minY,c.y); maxY=math.max(maxY,c.y) end
            fp.minX,fp.minY,fp.maxX,fp.maxY=minX,minY,maxX,maxY
            fp.w=maxX-minX+1; fp.h=maxY-minY+1; fp.rectangle=#fp.list==fp.w*fp.h
            return fp
        end
    """)
    return lua


def layouts(lua, profile_id, cells, gable_id=None, options=None):
    g = lua.globals()
    g.cellList = lua.table_from([lua.table_from({"x": x, "y": y}) for (x, y) in cells])
    g.request = lua.table_from(options or {"z": 1, "eaves": True})
    if gable_id:
        lua.execute("request.gable=find(gables,%r)" % gable_id)
    result, reason = lua.eval("roof.suggest(find(profiles,%r), footprint(cellList), request)" % profile_id)
    return [result[i] for i in range(1, len(result) + 1)], reason


def pieces(lua, placements):
    g = lua.globals()
    out = []
    for i in range(1, len(placements) + 1):
        p = placements[i]
        out.append({"x": p.x, "y": p.y, "z": p.z, "sprite": g.spriteOf(p), "kind": g.kindOf(p)})
    return out


def load_seams(path):
    """Parse media/seams.txt into {tile: {east|south|belowEast|belowSouth: [tiles]}}."""
    seams, tile, section = {}, None, None
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        text = line.strip().rstrip(",")
        match = re.match(r"/\* (\S+) \*/", text)
        if match:
            tile = match.group(1); seams[tile] = {}; continue
        if tile and text in ("east", "south", "belowEast", "belowSouth"):
            section = text; seams[tile][section] = []; continue
        match = re.match(r"(\S+) =$", text)
        if match and section:
            seams[tile][section].append(match.group(1)); continue
        match = re.match(r"master = (\S+)$", text)
        if match and tile:
            seams[tile]["master"] = match.group(1); continue
        if tile and text == "properties":
            section = "properties"; continue
        if text == "}":
            if section: section = None
            elif tile: tile = None
    return seams


def check_seams(items, seams):
    """Return (agreeing joins, [disagreeing joins]) for roof tiles in `items`."""
    def master(name):
        # Like the engine's RoofProperties: a tile may borrow another's joins.
        return (seams.get(name) or {}).get("master") or name

    roofs = {(i["x"], i["y"], i["z"]): master(i["sprite"]) for i in items
             if i["kind"] == "object" and str(i["sprite"]).startswith("roofs_")}
    ok, bad = 0, []
    offsets = (("east", (1, 0, 0)), ("south", (0, 1, 0)), ("belowEast", (1, 0, -1)), ("belowSouth", (0, 1, -1)))
    for (x, y, z), sprite in roofs.items():
        joins = seams.get(sprite)
        if not joins:
            continue
        for section, (dx, dy, dz) in offsets:
            other = roofs.get((x + dx, y + dy, z + dz))
            if other is None or section not in joins:
                continue
            if other in joins[section]:
                ok += 1
            elif other in seams and other.rsplit("_", 1)[0] == sprite.rsplit("_", 1)[0]:
                bad.append(((x, y, z), sprite, section, other))
    return ok, bad


def render(items, out_path, tiles, base_cells=None, title=None, scale=0.5):
    from PIL import Image, ImageDraw
    cache = {}

    def sprite(name):
        sheet, index = name.rsplit("_", 1)
        if sheet not in cache:
            path = Path(tiles) / (sheet + ".png")
            cache[sheet] = Image.open(path).convert("RGBA") if path.exists() else None
        image = cache[sheet]
        if image is None:
            return None
        index = int(index); columns = image.size[0] // 128
        x, y = (index % columns) * 128, (index // columns) * 256
        return image.crop((x, y, x + 128, y + 256)) if y + 256 <= image.size[1] else None

    every = list(items)
    for (x, y) in base_cells or []:
        cells = set(base_cells)
        if (x - 1, y) not in cells: every.append({"x": x, "y": y, "z": 0, "sprite": "walls_exterior_house_01_0", "kind": "wall"})
        if (x, y - 1) not in cells: every.append({"x": x, "y": y, "z": 0, "sprite": "walls_exterior_house_01_1", "kind": "wall"})
        if (x + 1, y) not in cells: every.append({"x": x + 1, "y": y, "z": 0, "sprite": "walls_exterior_house_01_0", "kind": "wall"})
        if (x, y + 1) not in cells: every.append({"x": x, "y": y + 1, "z": 0, "sprite": "walls_exterior_house_01_1", "kind": "wall"})
    left = min((i["x"] - i["y"]) for i in every) * 64 - 64
    right = max((i["x"] - i["y"]) for i in every) * 64 + 192
    top = min((i["x"] + i["y"]) * 32 - i["z"] * 192 for i in every) - 256
    bottom = max((i["x"] + i["y"]) * 32 - i["z"] * 192 for i in every) + 96
    image = Image.new("RGBA", (right - left, bottom - top), (96, 116, 92, 255))
    order = {"floor": 0, "wall": 1, "object": 2}
    missing = set()
    for item in sorted(every, key=lambda i: (i["z"], i["x"] + i["y"], i["x"], order.get(i["kind"], 2))):
        tile = sprite(item["sprite"])
        if tile is None:
            missing.add(item["sprite"].rsplit("_", 1)[0]); continue
        image.alpha_composite(tile, ((item["x"] - item["y"]) * 64 - 64 - left,
                                     (item["x"] + item["y"]) * 32 - 192 - item["z"] * 192 - top))
    if title:
        ImageDraw.Draw(image).text((8, 8), title, fill=(255, 255, 255, 255))
    if scale != 1:
        image = image.resize((int(image.size[0] * scale), int(image.size[1] * scale)))
    image.save(out_path)
    return missing


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--profile", default="brown_shingles:45")
    parser.add_argument("--gable", default=None)
    parser.add_argument("--shape", default="L", choices=sorted(SHAPES))
    parser.add_argument("--top", type=int, default=3, help="how many ranked layouts to render")
    parser.add_argument("--out", default="roof_preview.png")
    parser.add_argument("--tiles", type=Path, default=DEFAULT_TILES)
    parser.add_argument("--seams", type=Path, default=DEFAULT_SEAMS)
    parser.add_argument("--list", action="store_true", help="list roof and gable families")
    args = parser.parse_args()
    lua = runtime()
    if args.list:
        print("roofs:", " ".join(lua.eval("profiles")[i].id for i in range(1, len(lua.eval("profiles")) + 1)))
        print("gables:", " ".join(lua.eval("gables")[i].id for i in range(1, len(lua.eval("gables")) + 1)))
        return 0
    cells = sorted(set(SHAPES[args.shape]))
    found, reason = layouts(lua, args.profile, cells, args.gable)
    if not found:
        print("no layout:", reason)
        return 1
    seams = load_seams(args.seams) if args.seams and args.seams.exists() else None
    out = Path(args.out)
    for rank, layout in enumerate(found[: args.top], 1):
        m = layout.metrics
        items = pieces(lua, layout.placements)
        line = (f"{rank}. {layout.kind:14s} score={layout.score:.2f} pieces={m.pieces} "
                f"gable walls={m.gables + m.fills} storeys={m.levels} stand-ins={m.approx}")
        if seams:
            ok, bad = check_seams(items, seams)
            line += f" joins ok={ok} other={len(bad)}"
        print(line)
        target = out if args.top == 1 else out.with_name(f"{out.stem}_{rank}_{layout.kind}{out.suffix}")
        if args.tiles and args.tiles.exists():
            missing = render(items, target, args.tiles, cells, f"{layout.kind}  {args.profile}")
            if missing:
                print("   tile sheets not found:", ", ".join(sorted(missing)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
