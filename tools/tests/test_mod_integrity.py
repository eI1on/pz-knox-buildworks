"""Whole-mod integrity checks: every Lua file, every translation file and every
buildable definition shipped from this repository.

These complement the focused behaviour tests. They load the REAL shared
modules (Schema, Registry, Resolver, Requirements, Matrix, StageConfig, Groups)
through kbw_runtime and push all provider manifests through the same
normalize/register/finalize pipeline the game runs. Engine-only facts (sprite
existence, entity CraftRecipe components, rendering) are covered in-game by the
Knox Buildworks Test Runner (debug mode, Menu Dock).

Run with: python -m unittest discover -s tools/tests
"""
import json
import re
import unittest

import kbw_runtime as k

PERK_SOURCE = k.kbw_paths.decompiled_file("zombie/characters/skills/PerkFactory.java")


def strip_lua_strings_and_comments(source):
    """Blank out comments and string literals so syntax scans see code only."""
    out = []
    index, length = 0, len(source)
    while index < length:
        if source.startswith("--", index):
            long_comment = re.match(r"--\[(=*)\[", source[index:])
            if long_comment:
                close = "]" + long_comment.group(1) + "]"
                end = source.find(close, index)
                skipped = source[index:length if end < 0 else end + len(close)]
                out.append("\n" * skipped.count("\n"))
                index = length if end < 0 else end + len(close)
            else:
                end = source.find("\n", index)
                index = length if end < 0 else end
            continue
        long_string = re.match(r"\[(=*)\[", source[index:])
        if long_string:
            close = "]" + long_string.group(1) + "]"
            end = source.find(close, index)
            skipped = source[index:length if end < 0 else end + len(close)]
            out.append('""' + "\n" * skipped.count("\n"))
            index = length if end < 0 else end + len(close)
            continue
        char = source[index]
        if char in "\"'":
            cursor = index + 1
            while cursor < length and source[cursor] != char:
                if source[cursor] == "\\":
                    cursor += 1
                cursor += 1
            out.append('""')
            index = cursor + 1
            continue
        out.append(char)
        index += 1
    return "".join(out)


def line_of(text, offset):
    return text.count("\n", 0, offset) + 1


class LuaSourceTests(unittest.TestCase):
    """Static checks over every Lua file in the B42 mod tree."""

    @classmethod
    def setUpClass(cls):
        cls.files = k.lua_files()
        cls.sources = {path: k.read_text(path) for path in cls.files}
        cls.code = {path: strip_lua_strings_and_comments(text) for path, text in cls.sources.items()}

    def test_every_lua_file_compiles(self):
        from lupa import LuaRuntime
        compile_only = LuaRuntime().eval("function(src, name) local _, err = load(src, '@' .. name); return err end")
        errors = []
        for path, text in self.sources.items():
            err = compile_only(text, str(path.relative_to(k.LUA)))
            if err:
                errors.append(err)
        self.assertEqual([], errors)

    def test_no_forbidden_kahlua_helpers(self):
        # CLAUDE.md: ipairs, pcall, xpcall and next must not be used.
        pattern = re.compile(r"(?<![\w.:])(ipairs|pcall|xpcall|next)\s*\(")
        hits = []
        for path, code in self.code.items():
            for match in pattern.finditer(code):
                hits.append(f"{path.relative_to(k.LUA)}:{line_of(code, match.start())} {match.group(1)}")
        self.assertEqual([], hits)

    def test_no_syntax_newer_than_kahlua_lua_5_1(self):
        # lupa compiles with a modern Lua, so 5.2+ syntax must be caught here.
        patterns = {
            "goto": r"\bgoto\b",
            "label": r"::[A-Za-z_]\w*::",
            "integer division": r"//",
            "bitwise and": r"&",
            "bitwise or": r"\|",
            "bitwise xor/not": r"~(?!=)",
            "bit shift": r"<<|>>",
        }
        hits = []
        for path, code in self.code.items():
            for name, pattern in patterns.items():
                for match in re.finditer(pattern, code):
                    hits.append(f"{path.relative_to(k.LUA)}:{line_of(code, match.start())} {name}")
        self.assertEqual([], hits)

    def test_every_mod_require_resolves(self):
        missing = []
        for path, text in self.sources.items():
            for name in re.findall(r"require\s*\(?\s*[\"']([^\"']+)[\"']", text):
                if name.startswith(("KnoxBuildworks/", "ElyonLib/")) and not k.module_path(name):
                    missing.append(f"{path.relative_to(k.LUA)} -> {name}")
        self.assertEqual([], missing)

    def test_globals_stay_namespaced(self):
        # CLAUDE.md: new globals live under KnoxBuildworks/KBW or KBW*-named UI
        # classes. Only top-level assignments are inspected.
        allowed = re.compile(r"^(KnoxBuildworks|KBW\w*|ISBuildingObject|ISBuildAction)$")
        hits = []
        assignment = re.compile(r"^([A-Za-z_]\w*)\s*=(?!=)", re.M)
        function = re.compile(r"^function\s+([A-Za-z_]\w*)\s*\(", re.M)
        for path, code in self.code.items():
            # Forward-declared locals ("local f" ... "f = function") are fine.
            declared = set()
            for names in re.findall(r"\blocal[ \t]+(?:function[ \t]+)?([A-Za-z_][\w \t,]*)", code):
                declared.update(name.strip() for name in names.split(",") if name.strip())
            for pattern in (assignment, function):
                for match in pattern.finditer(code):
                    if match.group(1) not in declared and not allowed.match(match.group(1)):
                        hits.append(f"{path.relative_to(k.LUA)}:{line_of(code, match.start())} {match.group(1)}")
        self.assertEqual([], hits)

    def test_literal_translation_keys_exist(self):
        k.require_game()
        en = k.translations("EN")
        game = k.game_translations("EN")
        missing = []
        key_call = re.compile(r"getText(?:OrNull)?\s*\(\s*\"([A-Za-z0-9_]+)\"\s*[,)]")
        for path, text in self.sources.items():
            for key in key_call.findall(text):
                if key not in en and key not in game:
                    missing.append(f"{path.relative_to(k.LUA)}: {key}")
        self.assertEqual([], sorted(set(missing)))


class TranslationFileTests(unittest.TestCase):
    def test_every_translation_file_is_valid_json_of_strings(self):
        problems = []
        for folder, _ in k.PROVIDERS:
            base = k.MODS / folder / "42/media/lua/shared/Translate"
            for path in sorted(base.rglob("*.json")):
                try:
                    data = json.loads(k.read_text(path))
                except ValueError as error:
                    problems.append(f"{path.relative_to(k.MODS)}: {error}")
                    continue
                for key, value in data.items():
                    if not isinstance(value, str):
                        problems.append(f"{path.relative_to(k.MODS)}: {key} is not a string")
        self.assertEqual([], problems)

    def test_translated_files_do_not_keep_keys_removed_from_english(self):
        problems = []
        for folder, _ in k.PROVIDERS:
            base = k.MODS / folder / "42/media/lua/shared/Translate"
            english = {}
            for path in (base / "EN").glob("*.json"):
                english[path.name] = set(json.loads(k.read_text(path)))
            for language in sorted(p for p in base.iterdir() if p.is_dir() and p.name != "EN"):
                for path in sorted(language.glob("*.json")):
                    stale = set(json.loads(k.read_text(path))) - english.get(path.name, set())
                    for key in sorted(stale):
                        problems.append(f"{folder}/{language.name}/{path.name}: {key}")
        self.assertEqual([], problems)


class ManifestTests(unittest.TestCase):
    def test_manifest_lists_exactly_the_definition_files_on_disk(self):
        for folder, _ in k.PROVIDERS:
            mod, data = k.manifest(folder)
            listed = list(data["definitions"])
            self.assertEqual(len(listed), len(set(listed)), f"{folder}: duplicate manifest entries")
            on_disk = sorted(
                str(path.relative_to(mod)).replace("\\", "/")
                for path in (mod / "media/KnoxBuildworks/definitions").rglob("*.json")
            )
            self.assertEqual(on_disk, sorted(listed), folder)
            self.assertEqual(1, data.get("schemaVersion"), folder)


class DefinitionTests(unittest.TestCase):
    """Every buildable through the real loader pipeline, then every resolved case."""

    @classmethod
    def setUpClass(cls):
        perks = None
        if PERK_SOURCE is not None:
            perks = set(re.findall(r'new PerkFactory\.Perk\("([A-Za-z0-9_]+)"\)', PERK_SOURCE.read_text(encoding="utf-8")))
        cls.has_scripts = k.script_index() is not None
        cls.lua = k.new_runtime(perks=perks)
        k.load_registry(cls.lua)
        scripts = k.script_index()
        names = sorted({name.split(".", 1)[-1] for name in scripts.entities}) if scripts else []
        cls.lua.globals().py_entity_names = lambda: cls.lua.table_from(names)
        cls.lua.execute(CASE_WALK)
        cls.g = cls.lua.globals()
        cls.g.walkCases()

    def problems(self, kind):
        return [entry for entry in k.lua_list(self.g.PROBLEMS) if entry.startswith(kind + " ")]

    def test_every_definition_file_normalizes_without_errors(self):
        self.assertEqual([], k.lua_list(self.g.LOAD_ERRORS))

    def test_every_buildable_in_json_is_registered_once(self):
        expected = 0
        for folder, _ in k.PROVIDERS:
            mod, data = k.manifest(folder)
            for rel in data["definitions"]:
                expected += len(json.loads(k.read_text(mod / rel)).get("buildables", []))
        self.assertEqual(expected, self.lua.eval("#Registry:list()"))
        self.assertNotEqual("00000000", self.lua.eval("Registry.hash"))

    def test_registry_finalize_reports_no_warnings(self):
        # Sprite warnings need the engine; everything else (duplicate sprites
        # without allowSpriteReuse, missing name/tooltip translations) must
        # be clean.
        log = k.lua_list(self.g.KBW_TEST_LOG)
        self.assertEqual([], [line for line in log if "Missing sprite" not in line])

    def test_every_variant_material_and_stage_resolves(self):
        self.assertGreater(self.g.CASES, 0)
        self.assertEqual([], self.problems("resolve"))

    def test_translation_keys_use_routed_prefixes_and_exist(self):
        self.assertEqual([], self.problems("prefix"))
        self.assertEqual([], self.problems("translation"))

    def test_categories_and_subcategories_are_translated(self):
        self.assertEqual([], self.problems("category"))
        self.assertEqual([], self.problems("subcategory"))

    def test_placement_kinds_are_known(self):
        self.assertEqual([], self.problems("kind"))

    def test_json_stages_place_at_least_one_sprite(self):
        # Entity-backed stages take their sprites from the entity SpriteConfig,
        # which only exists in-game.
        self.assertEqual([], self.problems("nosprite"))

    def test_footprints_are_well_formed(self):
        self.assertEqual([], self.problems("footprint"))

    def test_stage_chain_references_exist(self):
        self.assertEqual([], self.problems("chain"))

    def test_skills_reference_real_perks(self):
        if PERK_SOURCE is None:
            self.skipTest("decompiled PerkFactory not available")
        self.assertEqual([], self.problems("perk"))

    def test_requirement_rows_resolve_to_real_items(self):
        if not self.has_scripts:
            self.skipTest("Project Zomboid scripts not available")
        self.assertEqual([], self.problems("noitems"))

    def test_groups_point_at_registered_members(self):
        self.assertEqual([], self.problems("group"))


# Lua walk over every resolvable case. Written with numeric loops (no ipairs)
# to stay in the mod's own dialect even though this runs under lupa.
CASE_WALK = r"""
Resolver = require('KnoxBuildworks/Definitions/Resolver')
Requirements = require('KnoxBuildworks/Validation/Requirements')
Matrix = require('KnoxBuildworks/Geometry/Matrix')
StageConfig = require('KnoxBuildworks/Definitions/StageConfig')
Placement = require('KnoxBuildworks/Validation/Placement')
Groups = require('KnoxBuildworks/Definitions/Groups')
I18n = require('KnoxBuildworks/I18n')

PROBLEMS = {}
CASES = 0
local KINDS = { object = true, wall = true, floor = true, overlay = true, stairs = true, wallCovering = true }
local FACES = { 'W', 'N', 'E', 'S' }

local function problem(kind, text) PROBLEMS[#PROBLEMS + 1] = kind .. ' ' .. text end

local function routed(key)
    return type(key) == 'string' and (string.find(key, '^IGUI_') ~= nil or string.find(key, '^Tooltip_') ~= nil)
end

local function optionIds(options, required)
    local ids = {}
    if required ~= true then ids[1] = '' end
    options = options or {}
    for i = 1, #options do ids[#ids + 1] = options[i].id end
    return ids
end

-- Mirrors Placement's compactName: previousStage names match built objects by
-- compacted name or suffix (entity name, KBW stage id or buildable id).
local function compactName(value)
    value = string.lower(tostring(value or ''))
    value = string.gsub(value, '[%s_%-%(%)%.:]+', '')
    value = string.gsub(value, 'wooden', 'wood')
    return value
end

local function chainMatches(wanted)
    wanted = compactName(wanted)
    for i = 1, #CHAIN_NAMES do
        local candidate = CHAIN_NAMES[i]
        if candidate == wanted or string.sub(candidate, -#wanted) == wanted then return true end
    end
    return false
end

local function addChainNames(definition)
    CHAIN_NAMES[#CHAIN_NAMES + 1] = compactName(definition.id)
    local stages = definition.stages or {}
    for i = 1, #stages do
        local stage = stages[i]
        CHAIN_NAMES[#CHAIN_NAMES + 1] = compactName(stage.id)
        if stage.entityCompat and stage.entityCompat.entity then
            CHAIN_NAMES[#CHAIN_NAMES + 1] = compactName(stage.entityCompat.entity)
        end
    end
end

local function checkStage(base, variantId, materialId, definition, stage)
    local label = base.id .. ':' .. tostring(stage.id) .. ' v=' .. variantId .. ' m=' .. materialId
    local placement = StageConfig.placement(definition, stage)
    if not KINDS[placement.kind or ''] then problem('kind', label .. ' kind=' .. tostring(placement.kind)) end
    local anySprite = false
    for f = 1, #FACES do
        local cells = Matrix.getFaceCells(stage, FACES[f]) or {}
        for c = 1, #cells do
            local cell = cells[c]
            if cell.sprite then anySprite = true end
            if type(cell.dx or 0) ~= 'number' or type(cell.dy or 0) ~= 'number' or type(cell.dz or 0) ~= 'number' then
                problem('footprint', label .. ' face ' .. FACES[f] .. ' has a non-numeric offset')
            end
        end
    end
    if not anySprite and placement.kind ~= 'wallCovering' and stage.entityCompat == nil then
        problem('nosprite', label .. ' kind=' .. tostring(placement.kind))
    end
    local inputs = Requirements.getInputs(definition, stage)
    for i = 1, #inputs do
        local input = inputs[i]
        local needed = tonumber(input.uses or input.amount or 1) or 0
        if (input.resourceType or 'Item') == 'Item' and needed > 0 and #Requirements.possibleItems(input) == 0 then
            problem('noitems', label .. ' input ' .. tostring(input.id))
        end
    end
    local skills = (stage.requirements or {}).skills or {}
    for perk in pairs(skills) do
        if Perks[perk] == nil then problem('perk', label .. ' skill ' .. tostring(perk)) end
    end
    local previous = Placement.previousStageOf(stage)
    if previous then
        local names = type(previous) == 'table' and previous or { previous }
        local any = false
        for i = 1, #names do
            if chainMatches(names[i]) then any = true end
        end
        if not any then problem('chain', label .. ' previousStage ' .. table.concat(names, ',')) end
    end
end

function walkCases()
    CHAIN_NAMES = {}
    local list = Registry:list()
    for i = 1, #list do addChainNames(list[i]) end
    -- Vanilla-built frames are valid previous stages too.
    local entities = py_entity_names and py_entity_names() or {}
    for i = 1, #entities do CHAIN_NAMES[#CHAIN_NAMES + 1] = compactName(entities[i]) end
    for i = 1, #list do
        local base = list[i]
        if not routed(base.translationKey) then problem('prefix', base.id .. ' translationKey ' .. tostring(base.translationKey)) end
        if base.tooltipKey and base.tooltipKey ~= '' and not routed(base.tooltipKey) then
            problem('prefix', base.id .. ' tooltipKey ' .. tostring(base.tooltipKey))
        end
        if routed(base.translationKey) and not getTextOrNull(base.translationKey) then
            problem('translation', base.id .. ' ' .. base.translationKey)
        end
        local categoryKey = 'IGUI_KBW_Category_' .. I18n.keyPart(base.category)
        if not getTextOrNull(categoryKey) then problem('category', base.id .. ' ' .. categoryKey) end
        local subcategoryKey = 'IGUI_KBW_Subcategory_' .. I18n.keyPart(base.subcategory or 'General')
        if not getTextOrNull(subcategoryKey) then problem('subcategory', base.id .. ' ' .. subcategoryKey) end
        local variants = optionIds(base.variants, false)
        local materials = optionIds(base.materialOptions, base.materialRequired == true)
        for v = 1, #variants do
            for m = 1, #materials do
                local definition, reason = Resolver.resolve(base.id, variants[v], materials[m])
                if not definition then
                    problem('resolve', base.id .. ' v=' .. variants[v] .. ' m=' .. materials[m] .. ' ' .. tostring(reason))
                else
                    local stages = definition.stages or {}
                    for s = 1, #stages do
                        local resolved, stage, why = Resolver.resolveStage(base.id, variants[v], materials[m], stages[s].id)
                        if not stage then
                            problem('resolve', base.id .. ':' .. tostring(stages[s].id) .. ' ' .. tostring(why))
                        else
                            CASES = CASES + 1
                            checkStage(base, variants[v], materials[m], resolved, stage)
                        end
                    end
                end
            end
        end
    end
    local grouped = Groups.groupedList(list)
    for i = 1, #grouped do
        local entry = grouped[i]
        if Groups.isGroup(entry) then
            local ids = Groups.memberIds(entry)
            for j = 1, #ids do
                if not Registry:get(ids[j]) then problem('group', tostring(entry.id) .. ' member ' .. tostring(ids[j])) end
            end
        end
    end
end
"""


if __name__ == "__main__":
    unittest.main()
