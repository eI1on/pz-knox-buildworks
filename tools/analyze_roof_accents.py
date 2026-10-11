"""Compare the Roof Helper's accent trim with the vanilla map.

Decodes the shipped lotheader/lotpack files (format from IsoMetaGrid and
IsoLot), finds rectangular 30 degree gable roofs whose eave sits on the storey
line, plans the same footprint with RoofPlanner and reports which accent tiles
differ. Needs PZ_GAME_DIR (see tools/paths.example.env), lupa and pillow.

    python tools/analyze_roof_accents.py
"""
import collections
import struct
import sys
from pathlib import Path

import kbw_paths
import roof_preview as rp

MAPS = kbw_paths.GAME_MEDIA / "maps" if kbw_paths.GAME_MEDIA else None


def read_header(path):
    data = path.read_bytes()
    pos = 0
    if data[:4] == b"LOTH":
        pos = 4
    version = struct.unpack_from("<i", data, pos)[0]; pos += 4
    count = struct.unpack_from("<i", data, pos)[0]; pos += 4
    tiles = []
    for _ in range(count):
        end = data.index(b"\n", pos)
        tiles.append(data[pos:end].decode("utf-8", "replace").strip())
        pos = end + 1
    if version == 0:
        pos += 1
    width, height = struct.unpack_from("<ii", data, pos); pos += 8
    if version == 0:
        min_level = 0
        max_level = struct.unpack_from("<i", data, pos)[0] - 1; pos += 4
    else:
        min_level, max_level = struct.unpack_from("<ii", data, pos); pos += 8
    return {"version": version, "tiles": tiles, "min": min_level, "max": max_level}


def read_cell(folder, cx, cy, header):
    """{(x, y, z): [tile names]} in world coordinates for one 256x256 cell."""
    data = (folder / f"world_{cx}_{cy}.lotpack").read_bytes()
    base = 0
    version = 0
    if data[:4] == b"LOTP":
        version = struct.unpack_from("<i", data, 4)[0]
        base = 8
    tiles = header["tiles"]
    out = {}
    min_z = max(header["min"], -32)
    max_z = min(header["max"], 31)
    for lwx in range(32):
        for lwy in range(32):
            index = lwx * 32 + lwy
            pos = struct.unpack_from("<i", data, base + 4 + index * 8)[0]
            skip = 0
            for z in range(min_z, max_z + 1):
                for x in range(8):
                    for y in range(8):
                        if skip > 0:
                            skip -= 1
                            continue
                        count = struct.unpack_from("<i", data, pos)[0]; pos += 4
                        if count == -1:
                            skip = struct.unpack_from("<i", data, pos)[0]; pos += 4
                            if skip > 0:
                                skip -= 1
                                continue
                        if count > 1:
                            pos += 4  # room
                            names = []
                            for _ in range(1, count):
                                names.append(tiles[struct.unpack_from("<i", data, pos)[0]]); pos += 4
                            wx = cx * 256 + lwx * 8 + x
                            wy = cy * 256 + lwy * 8 + y
                            out[(wx, wy, z)] = names
    return out


def cells_with(substring, folders=None):
    for folder in sorted(MAPS.iterdir()) if folders is None else folders:
        if not folder.is_dir():
            continue
        for header_path in sorted(folder.glob("*.lotheader")):
            stem = header_path.stem
            try:
                cx, cy = (int(v) for v in stem.split("_"))
            except ValueError:
                continue
            raw = header_path.read_bytes()
            if substring.encode() not in raw:
                continue
            yield folder, cx, cy, read_header(header_path)


lua = rp.runtime()
atlas = lua.eval("modules['KnoxBuildworks/Planning/RoofAtlas']")
lua.execute("accentSet = roof.accents(definitions)[1]")


def roofkey(name):
    if not name.startswith('roofs_30_'):
        return None
    p = atlas.roofPiece(name)
    return p


def accents_of(names):
    return [n for n in names if n.startswith('roofs_accents')]


def components(cell):
    roofs = {}
    for (x, y, z), names in cell.items():
        for n in names:
            p = roofkey(n)
            if p is not None and p.kind == 'slope':
                roofs[(x, y, z)] = p.facing
    seen, comps = set(), []
    for start in roofs:
        if start in seen:
            continue
        stack, comp = [start], []
        seen.add(start)
        while stack:
            c = stack.pop(); comp.append(c)
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                n = (c[0] + dx, c[1] + dy, c[2])
                if n in roofs and n not in seen:
                    seen.add(n); stack.append(n)
        comps.append((comp, {c: roofs[c] for c in comp}))
    return comps


def planner_accents(w, h, along_x):
    g = lua.globals()
    g.cellList = lua.table_from([lua.table_from({"x": x, "y": y}) for x in range(w) for y in range(h)])
    g.request = lua.table_from({"z": 1, "kind": "gable", "direction": "N" if along_x else "W"})
    lua.execute("request.accents = accentSet")
    placements, reason, _ = lua.eval("roof.generate(find(profiles, 'grey:30'), footprint(cellList), request)")
    if placements is None:
        return None, reason
    out = set()
    for item in rp.pieces(lua, placements):
        if item["sprite"].startswith("roofs_accents"):
            out.add((item["x"], item["y"], item["z"] - 1, item["sprite"]))
    return out, None


def main():
    matched = mismatched = 0
    shown = 0
    for folder, cx, cy, h in cells_with('roofs_accents_30'):
        cell = read_cell(folder, cx, cy, h)
        for comp, facing in components(cell):
            xs = [c[0] for c in comp]; ys = [c[1] for c in comp]; z = comp[0][2]
            x0, y0, w, hh = min(xs), min(ys), max(xs) - min(xs) + 1, max(ys) - min(ys) + 1
            if len(comp) != w * hh or w < 3 or hh < 3 or len(comp) > 120:
                continue
            faces = set(facing.values())
            if faces == {'N', 'S'}:
                along_x = True
            elif faces == {'E', 'W'}:
                along_x = False
            else:
                continue
            # only roofs whose first slope row starts at step 1 (eave on the storey line)
            steps = [atlas.roofPiece(n).step for (cx_, cy_, cz) in comp for n in cell[(cx_, cy_, cz)] if roofkey(n) is not None and roofkey(n).kind == 'slope']
            if min(steps) != 1:
                continue
            vanilla = set()
            for dz in (0, -1):
                for x in range(x0 - 1, x0 + w + 2):
                    for y in range(y0 - 1, y0 + hh + 2):
                        for n in accents_of(cell.get((x, y, z + dz), [])):
                            vanilla.add((x - x0, y - y0, dz, n))
            if not vanilla:
                continue
            ours, reason = planner_accents(w, hh, along_x)
            if ours is None:
                continue
            ours = {(x, y, dz, n) for (x, y, dz, n) in ours}
            if ours == vanilla:
                matched += 1
            else:
                mismatched += 1
                if shown < 6:
                    shown += 1
                    print(f"{folder.name} roof at {x0},{y0},{z} {w}x{hh} alongX={along_x}")
                    print("   only vanilla:", sorted(vanilla - ours))
                    print("   only ours   :", sorted(ours - vanilla))
    print("matched", matched, "mismatched", mismatched)


if __name__ == "__main__":
    if MAPS is None:
        sys.exit("Set PZ_GAME_DIR (see tools/paths.example.env).")
    main()
