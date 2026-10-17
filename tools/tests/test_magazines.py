"""Magazines: what they unlock must show up without a relog, and their
tooltip lists it from the definitions rather than the item script."""
import unittest

import kbw_runtime as k

PLAYER = r"""
NOW = 1000
function getTimestampMs() return NOW end
KNOWN = {}
PLAYER = {}
function PLAYER:isRecipeActuallyKnown(name) return KNOWN[name] == true end
function PLAYER:isBuildCheat() return false end
function PLAYER:getPerkLevel() return 0 end
function PLAYER:getModData() self.md = self.md or {} return self.md end
function magazine(recipes)
    return { getLearnedRecipes = function() return {
        isEmpty = function() return #recipes == 0 end,
        size = function() return #recipes end,
        get = function(_, i) return recipes[i + 1] end
    } end }
end
"""


class MagazineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = k.load_registry(k.new_runtime())
        cls.lua.execute(PLAYER)
        cls.lua.execute(r"""
            ISToolTipInv = { render = function() end }
            function instanceof(_, class) return class == 'Literature' end
            Requirements = require('KnoxBuildworks/Validation/Requirements')
            Index = require('KnoxBuildworks/UI/CatalogIndex')
            MagazineTooltip = require('KnoxBuildworks/UI/MagazineTooltip')
            -- the hide-until-learned path (option off)
            require('KnoxBuildworks/UI/CatalogVisibility').setShowUnlearned(false)
        """)

    def test_reading_shows_the_cards_without_a_relog(self):
        # The cached visibility only refreshed when a filter pass asked for
        # the card again, which an open catalogue never did.
        lua = self.lua
        lua.execute(r"""
            local records = Index.get().records
            target, recipe = nil, nil
            for i = 1, #records do
                local stages = records[i].callbackStages or {}
                for s = 1, #stages do
                    local knowledge = (stages[s].stage.requirements or {}).knowledge or {}
                    if not target and knowledge.hideUntilLearned and knowledge.recipes and knowledge.recipes[1] then
                        target, recipe = records[i], knowledge.recipes[1]
                    end
                end
            end
            before = Index.recordVisible(PLAYER, target, false)
            generation = Index.visibilityGeneration
            KNOWN[recipe] = true
            Requirements.invalidate()   -- what the known-recipe watcher does
            Index.pumpVisibility(100000)
        """)
        self.assertFalse(lua.eval("before"))
        self.assertGreater(lua.eval("Index.visibilityGeneration"), lua.eval("generation"))
        self.assertTrue(lua.eval("target.visibleCache.value"))

    def test_tooltip_lists_unlocks_from_definitions(self):
        lua = self.lua
        lines = k.lua_list(lua.eval("(MagazineTooltip.unlocksFor(magazine({'KBWKnowledge_HomeMechanix_Bathroom'}), PLAYER))"))
        self.assertIn("Toilets", lines)
        summary = k.lua_list(lua.eval(
            "(MagazineTooltip.unlocksFor(magazine({'KBWKnowledge_TheFamilyHandyman_StairsFences'}), PLAYER))"))
        self.assertTrue(any(line.startswith("Roofing / ") for line in summary), "large unlock sets summarise by section")
        self.assertIsNone(lua.eval("(MagazineTooltip.unlocksFor(magazine({'NotAKnoxRecipe'}), PLAYER))"))

if __name__ == "__main__":
    unittest.main()
