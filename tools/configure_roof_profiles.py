"""Annotate existing authored roof pieces; never generate or guess sprite IDs."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run():
    directory = ROOT / "Contents/mods/KnoxBuildworks_Vanilla_Expanded/42/media/KnoxBuildworks/definitions/roofing"
    for path in sorted(directory.glob("*.json")):
        if path.stem.startswith("roof_trim") or path.stem == "tent_roofs":
            data = json.loads(path.read_text(encoding="utf-8"))
            for definition in data["buildables"]:
                for stage in definition["stages"]:
                    stage["roof"] = {"family": "tent" if path.stem == "tent_roofs" else "trim",
                                     "pitch": "custom" if path.stem == "tent_roofs" else (30 if path.stem.endswith("_30") else 45),
                                     "role": "detail"}
            path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
            continue
        data = json.loads(path.read_text(encoding="utf-8"))
        family = path.stem.replace("_30_roofs", "").replace("_shallow_roofs", "").replace("_roofs", "").replace("_roof_extras", "")
        for definition in data["buildables"]:
            for stage in definition["stages"]:
                name = definition["id"].split(".")[-1]
                roof = {"family": family, "pitch": 30 if "_30_" in path.stem else ("shallow" if "_shallow_" in path.stem else 45), "role": "detail"}
                if "_30_" in path.stem:
                    match = re.search(r"_30_slope_(\d+)$", name)
                    if match:
                        roof.update(role="slope", step=int(match[1]), stepsPerLevel=6,
                                    faceByEdge={"S": "E", "E": "S", "N": "W", "W": "N"})
                elif "_shallow_" not in path.stem:
                    match = re.search(r"_pitched_(\d+)$", name)
                    if match and "_half_" not in name:
                        roof.update(role="slope", step=int(match[1]), stepsPerLevel=3,
                                    faceByEdge={"S": "W", "E": "N"}, hiddenEdges=["N", "W"])
                    elif definition.get("placement", {}).get("kind") == "floor" and "_valley_" not in name:
                        roof.update(role="flat", pitch=0)
                if roof["pitch"] == 45 and roof["role"] == "detail":
                    for suffix, parts in (("inner", {"W": "hipSE"}), ("outer", {"W": "hipSW", "N": "hipNE"}), ("valley", {"W": "valleySE"})):
                        m = re.search(r"_" + suffix + r"_([123])$", name)
                        if m and "half" not in name and "patio" not in name:
                            roof["partsByFace"] = {face: part + ":" + m[1] for face, part in parts.items()}
                    if name.endswith("_section_r1_1"):
                        roof["partsByFace"] = {"W": "ridgeEW", "N": "ridgeNS"}
                    if "patio" in name and name.endswith("_pitched"):
                        roof["partsByFace"] = {"W": "eaveS", "N": "eaveE"}
                    elif "patio" in name and name.endswith("_inner"):
                        roof["partsByFace"] = {"W": "eaveSE"}
                    elif "patio" in name and name.endswith("_outer"):
                        roof["partsByFace"] = {"W": "eaveSW", "N": "eaveNE"}
                stage["roof"] = roof
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    # Wall gables already have explicit rising/falling/end variants in the
    # catalogue. Their family prefix also identifies the full-height infill.
    walls = directory.parent / "walls"
    families = set()
    files = {}
    for path in sorted(walls.glob("*.json")):
        data = json.loads(path.read_text(encoding="utf-8")); files[path] = data
        for definition in data["buildables"]:
            name = definition["id"].split(".")[-1]
            match = re.match(r"(.+)_roof_slope_wall_([1-6])$", name)
            shallow = re.match(r"(.+)_roof30_(rising|falling|end)_([1-6])$", name)
            end = re.match(r"(.+)_roof_end_(small|medium|big)$", name)
            parts = None
            if match:
                family, number = match[1], int(match[2]); step = (number-1)%3+1
                parts = {"W": ("riseS" if number<=3 else "riseN")+":"+str(step),
                         "N": ("riseW" if number<=3 else "riseE")+":"+str(step)}
                pitch = 45
            elif shallow:
                family, kind, step = shallow[1], shallow[2], shallow[3]; pitch = 30
                parts = ({"W":"peak:"+step,"N":"peak:"+step} if kind=="end" else
                         {"W":("riseS" if kind=="rising" else "riseN")+":"+step,
                          "N":("riseW" if kind=="rising" else "riseE")+":"+step})
            elif end:
                family, kind = end[1], end[2]; pitch=45
                step = {"small":1,"medium":2,"big":3}[kind]
                parts={"W":"peak:"+str(step),"N":"peak:"+str(step)}
            if parts:
                families.add(family)
                for stage in definition["stages"]:
                    stage["roof"]={"family":family,"pitch":pitch,"role":"gable","partsByFace":parts}
    for path, data in files.items():
        changed=False
        for definition in data["buildables"]:
            name=definition["id"].split(".")[-1]
            if name.endswith("_wall") and name[:-5] in families:
                for stage in definition["stages"]:
                    stage["roof"]={"family":name[:-5],"pitch":0,"role":"gable","partsByFace":{"W":"fill","N":"fill"}}
            if any(s.get("roof",{}).get("role")=="gable" for s in definition["stages"]): changed=True
        if changed: path.write_text(json.dumps(data,indent=2,ensure_ascii=False)+"\n",encoding="utf-8")

if __name__ == "__main__":
    run()
