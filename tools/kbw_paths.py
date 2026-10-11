"""Locations outside this repository (game install, decompiled sources, ElyonLib).

Each one is read from an environment variable. Values can also go in an
untracked ``tools/paths.local.env`` (see ``tools/paths.example.env``); real
environment variables win. Anything unset or missing resolves to ``None`` so
callers can skip the checks that need it.
"""
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCAL_ENV = ROOT / "tools" / "paths.local.env"


def _load_local_env():
    if not LOCAL_ENV.exists():
        return {}
    values = {}
    for line in LOCAL_ENV.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


_LOCAL = _load_local_env()


def _directory(name, default=None):
    value = os.environ.get(name) or _LOCAL.get(name)
    path = Path(value).expanduser() if value else default
    return path if path is not None and path.exists() else None


def _child(base, relative):
    if base is None:
        return None
    path = base / relative
    return path if path.exists() else None


# Project Zomboid install folder (the one containing media/).
GAME_DIR = _directory("PZ_GAME_DIR")
GAME_MEDIA = _child(GAME_DIR, "media")
TILE_DEFINITIONS = _child(GAME_MEDIA, "newtiledefinitions.tiles.txt")
SEAMS = _child(GAME_MEDIA, "seams.txt")

# "Project Zomboid Modding Tools" folder (tile sheets for the roof preview).
MODDING_TOOLS_DIR = _directory("PZ_MODDING_TOOLS_DIR")
MODDING_TILES_2X = _child(MODDING_TOOLS_DIR, "Tiles/2x")

# Root of a decompiled B42 source tree (the folder containing zombie/).
DECOMPILED_SOURCE = _directory("PZ_DECOMPILED_SOURCE")

# ElyonLib checkout; defaults to a sibling of this repository.
ELYONLIB_DIR = _directory("ELYONLIB_DIR", ROOT.parent / "pz-elyonlib")
ELYONLIB_LUA = _child(ELYONLIB_DIR, "Contents/mods/ElyonLib/42/media/lua")


def game_file(relative):
    """A file under the game's media folder, or None."""
    return _child(GAME_MEDIA, relative)


def decompiled_file(relative):
    """A file under the decompiled source root, or None."""
    return _child(DECOMPILED_SOURCE, relative)
