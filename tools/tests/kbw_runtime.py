"""Shared offline runtime for whole-mod checks.

Unlike the focused doubles in test_catalog_workspace.runtime(), this loads the
REAL Knox Buildworks shared modules through a real ``require`` that resolves
``KnoxBuildworks/...`` and ``ElyonLib/...`` paths to files on disk. Only the
Java engine surface (ScriptManager, sprites, sandbox, translator) is stubbed,
and every stub is explicit so a module that starts depending on a new engine
call fails loudly instead of silently receiving a permissive fake.

Run the whole suite with: python -m unittest discover -s tools/tests
"""
from pathlib import Path
import json
import sys
import unittest
from functools import lru_cache

from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import kbw_paths  # noqa: E402
MODS = ROOT / "Contents/mods"
CORE_MOD = MODS / "KnoxBuildworks/42"
LUA = CORE_MOD / "media/lua"
ELYON = kbw_paths.ELYONLIB_LUA
GAME = kbw_paths.GAME_MEDIA

# Every content provider shipped from this repository: (mod folder, mod id).
PROVIDERS = [
    ("KnoxBuildworks", "KnoxBuildworks"),
    ("KnoxBuildworks_Vanilla_Expanded", "KnoxBuildworksVanillaExpanded"),
]

LUA_ROOTS = [LUA / "shared", LUA / "client", LUA / "server"]
if ELYON is not None:
    LUA_ROOTS += [ELYON / "shared", ELYON / "client"]


def read_text(path):
    return Path(path).read_text(encoding="utf-8-sig")


def lua_files():
    return sorted(LUA.rglob("*.lua"))


def module_path(name):
    """Resolve a require() name exactly like PZ: first match across lua roots."""
    for root in LUA_ROOTS:
        candidate = root / (name + ".lua")
        if candidate.exists():
            return candidate
    return None


def manifest(folder):
    mod = MODS / folder / "42"
    return mod, json.loads(read_text(mod / "media/KnoxBuildworks/manifest.json"))


@lru_cache(maxsize=None)
def translations(language="EN"):
    """Merged {key: text} for every Translate/<language>/*.json in the repo."""
    result = {}
    for folder, _ in PROVIDERS:
        base = MODS / folder / "42/media/lua/shared/Translate" / language
        if not base.exists():
            continue
        for path in sorted(base.glob("*.json")):
            result.update(json.loads(read_text(path)))
    return result


class ScriptIndex:
    """Names declared by the game's and this mod's script .txt files.

    Only names and item tags are indexed: enough to verify that a definition
    points at a real item, tag, timed action, craft recipe or entity. Entity
    component data (native CraftRecipe inputs) is NOT emulated offline; those
    stages are covered by the in-game Test Runner.
    """

    def __init__(self, roots):
        self.items, self.tags = {}, {}
        self.timed_actions, self.craft_recipes, self.entities = set(), set(), set()
        for root in roots:
            if root.exists():
                for path in sorted(root.rglob("*.txt")):
                    self._parse(path)

    def _parse(self, path):
        import re
        module = "Base"
        current_item = None
        depth = 0
        item_depth = None
        for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw.split("//", 1)[0].strip()
            if not line:
                continue
            match = re.match(r"module\s+([A-Za-z0-9_]+)", line)
            if match and depth == 0:
                module = match.group(1)
            match = re.match(r"(item|timedAction|craftRecipe|entity)\s+([A-Za-z0-9_]+)\s*\{?\s*$", line)
            if match and depth == 1:
                kind, name = match.groups()
                full = f"{module}.{name}"
                if kind == "item":
                    self.items.setdefault(full, set())
                    current_item, item_depth = full, depth + 1
                elif kind == "timedAction":
                    self.timed_actions.add(name)
                    self.timed_actions.add(full)
                elif kind == "craftRecipe":
                    self.craft_recipes.add(name)
                    self.craft_recipes.add(full)
                else:
                    self.entities.add(full)
            if current_item and depth == item_depth:
                match = re.match(r"Tags\s*=\s*(.+?),?$", line)
                if match:
                    for tag in match.group(1).split(";"):
                        tag = tag.strip().strip(",").lower()
                        if tag:
                            self.items[current_item].add(tag)
                            self.tags.setdefault(tag, []).append(current_item)
            depth += line.count("{") - line.count("}")
            if current_item and "}" in line and depth < item_depth:
                current_item, item_depth = None, None

    def tag(self, name):
        key = str(name).lower()
        if ":" not in key:
            key = "base:" + key
        return key if key in self.tags else None


@lru_cache(maxsize=None)
def script_index():
    """Game + repository scripts, or None when the game install is absent."""
    if GAME is None or not (GAME / "scripts").exists():
        return None
    return ScriptIndex([GAME / "scripts"] + [MODS / folder / "42/media/scripts" for folder, _ in PROVIDERS])


SCRIPT_STUBS = r"""
local function javaList(values)
    return { size = function() return #values end, get = function(_, i) return values[i + 1] end }
end
local function scriptItem(fullType)
    return {
        getFullName = function() return fullType end,
        getFullType = function() return fullType end,
        getDisplayName = function() return fullType end
    }
end
local manager = {
    FindItem = function(_, name) local full = py_find_item(name); return full and scriptItem(full) or nil end,
    getItem = function(_, name) local full = py_find_item(name); return full and scriptItem(full) or nil end,
    getTimedActionScript = function(_, name) return py_timed_action(name) and { getName = function() return name end } or nil end,
    -- Entity existence is real; components are not emulated offline (see
    -- ScriptIndex docstring), so every component lookup reports none.
    getGameEntityScript = function(_, name)
        if not py_entity(name) then return nil end
        local module, entity = string.match(tostring(name), "^([^.]+)%.(.+)$")
        return {
            getComponentScriptFor = function() return nil end,
            getModuleName = function() return module end,
            getName = function() return entity end
        }
    end,
    getCraftRecipe = function(_, name) return py_craft_recipe(name) and {} or nil end,
    getRecipe = function() return nil end,
    getMannequinScript = function() return {} end,
    getItemsTag = function(_, tag)
        local values = {}
        local list = py_items_for_tag(tag)
        for i = 1, #list do values[i] = scriptItem(list[i]) end
        return javaList(values)
    end
}
ScriptManager = { instance = manager }
function getScriptManager() return manager end
ComponentType = setmetatable({}, { __index = function(_, key) return key end })
ResourceLocation = { of = function(name) return tostring(name) end }
ItemTag = { get = function(location) return py_tag(location) end }
"""


@lru_cache(maxsize=None)
def game_translations(language="EN"):
    """Vanilla keys (Tooltip_craft_*, IGUI_perks_*), empty without the game."""
    result = {}
    base = GAME / "lua/shared/Translate" / language if GAME is not None else None
    if base is not None and base.exists():
        for path in sorted(base.glob("*.json")):
            try:
                result.update(json.loads(path.read_text(encoding="utf-8-sig", errors="replace")))
            except ValueError:
                pass
    return result


BOOT = r"""
modules = {}
loading = {}
KBW_TEST_LOG = {}
function require(name)
    local cached = modules[name]
    if cached ~= nil then return cached end
    if loading[name] then error("circular require: " .. name) end
    local source = py_module_source(name)
    if not source then
        -- PZ's require of a vanilla file (ISUI/...) returns nothing; mirror it.
        if not string.find(name, "^KnoxBuildworks/") and not string.find(name, "^ElyonLib/") then
            return nil
        end
        error("module not found: " .. name)
    end
    loading[name] = true
    local chunk, err = load(source, "@" .. name)
    if not chunk then error(err) end
    local value = chunk()
    loading[name] = nil
    if value == nil then value = true end
    modules[name] = value
    return value
end

-- Kahlua-visible engine surface used while loading definitions. Kept minimal
-- on purpose; see module docstring.
function isServer() return false end
function isClient() return false end
function isDebugEnabled() return false end
function getDebug() return false end
function getTimestampMs() return 1000 end
function getGameTime() return nil end
function getSandboxOptions() return nil end
function getActivatedMods() return nil end
function getScriptManager() return nil end
ScriptManager = { instance = nil }
-- Sprite data lives in .pack/.tiles files the tests cannot read; sprite
-- existence and properties are checked by the in-game Test Runner.
getSprite = nil
function getText(key, ...) return py_translate(key) or key end
function getTextOrNull(key) return py_translate(key) end
function instanceof() return false end
Perks = setmetatable({}, { __index = function(_, k) return py_perk(k) and { name = k } or nil end })
Events = setmetatable({}, { __index = function(t, k)
    local event = { Add = function() end, Remove = function() end }
    rawset(t, k, event)
    return event
end })
function triggerEvent() end
function getFileReader() return nil end
function getFileWriter() return nil end
function getModFileReader() return nil end
function copyTable(t)
    if type(t) ~= "table" then return t end
    local r = {}
    for k, v in pairs(t) do r[k] = copyTable(v) end
    return r
end
-- ElyonLib's logger prints; route it into a table the tests can inspect.
function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    KBW_TEST_LOG[#KBW_TEST_LOG + 1] = table.concat(parts, " ")
end
"""


def new_runtime(perks=None):
    """Fresh Lua state with the real require() wired to the repository."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    g = lua.globals()

    def module_source(name):
        path = module_path(str(name))
        return read_text(path) if path else None

    en = dict(game_translations("EN"))
    en.update(translations("EN"))
    g.py_module_source = module_source
    g.py_translate = lambda key: en.get(str(key))
    g.py_perk = (lambda name: True) if perks is None else (lambda name: str(name) in perks)
    lua.execute(BOOT)
    scripts = script_index()
    if scripts is not None:
        def find_item(name):
            name = str(name)
            if name in scripts.items:
                return name
            if "." not in name and "Base." + name in scripts.items:
                return "Base." + name
            return None

        g.py_find_item = find_item
        g.py_timed_action = lambda name: str(name) in scripts.timed_actions
        g.py_craft_recipe = lambda name: str(name) in scripts.craft_recipes
        g.py_entity = lambda name: str(name) in scripts.entities
        g.py_tag = scripts.tag
        g.py_items_for_tag = lambda tag: lua.table_from(sorted(scripts.tags.get(str(tag), [])))
        lua.execute(SCRIPT_STUBS)
    return lua


def require_game():
    """Skip the calling test when the game install is not configured."""
    if GAME is None:
        raise unittest.SkipTest("needs the Project Zomboid install (set PZ_GAME_DIR, see tools/paths.example.env)")


def load_registry(lua, providers=PROVIDERS):
    """Run the same accept/normalize/register/finalize pipeline as Loader.loadAll."""
    require_game()
    lua.execute("""
        Loader = require('KnoxBuildworks/Definitions/Loader')
        Registry = require('KnoxBuildworks/Definitions/Registry')
        Schema = require('KnoxBuildworks/Definitions/Schema')
        SafeJSON = require('KnoxBuildworks/Util/SafeJSON')
        Overrides = require('KnoxBuildworks/Definitions/Overrides')
        Hash = require('KnoxBuildworks/Util/Hash')
        Registry:reset()
        STATE = { templates = {}, groups = {}, bundles = {}, overrides = {}, patches = {} }
        LOAD_ERRORS = {}
        function acceptText(source, text)
            local bundle, err = SafeJSON.decode(text)
            if not bundle then LOAD_ERRORS[#LOAD_ERRORS + 1] = source .. ': ' .. tostring(err); return end
            local errors = Schema.validateBundle(bundle)
            for i = 1, #errors do LOAD_ERRORS[#LOAD_ERRORS + 1] = source .. ': ' .. errors[i] end
            if #errors > 0 then return end
            Registry.files[source] = Hash.string(text)
            Overrides.collect(STATE.patches, bundle, source)
            for name, value in pairs(bundle.templates or {}) do STATE.templates[name] = value end
            for name, value in pairs(bundle.materialGroups or {}) do STATE.groups[name] = value end
            STATE.bundles[#STATE.bundles + 1] = { source = source, data = bundle }
        end
        function normalizeAll()
            for b = 1, #STATE.bundles do
                local bundle = STATE.bundles[b]
                local list = bundle.data.buildables or {}
                for i = 1, #list do
                    local raw = list[i]
                    local patched = Overrides.apply(Overrides.applyPatch(raw, STATE.patches), STATE.overrides)
                    local normalized, errors = Schema.normalize(patched, STATE.templates, STATE.groups)
                    if #errors > 0 then
                        for e = 1, #errors do
                            LOAD_ERRORS[#LOAD_ERRORS + 1] = tostring(raw.id) .. ' in ' .. bundle.source .. ': ' .. errors[e]
                        end
                    elseif not Registry:register(normalized, bundle.source) then
                        LOAD_ERRORS[#LOAD_ERRORS + 1] = 'duplicate id ' .. tostring(raw.id) .. ' in ' .. bundle.source
                    end
                end
            end
            Registry:finalize()
        end
    """)
    accept = lua.globals().acceptText
    for folder, mod_id in providers:
        mod, data = manifest(folder)
        for rel in data["definitions"]:
            accept(f"{mod_id}:{rel}", read_text(mod / rel))
    lua.globals().normalizeAll()
    return lua


def lua_list(table):
    return [table[i] for i in range(1, len(table) + 1)] if table is not None else []
