import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class ReleaseDocumentationTests(unittest.TestCase):
    def test_workshop_description_stays_within_steam_limit(self):
        lines = (ROOT / "workshop.txt").read_text(encoding="utf-8").splitlines()
        description = "\r\n".join(line[len("description="):] for line in lines if line.startswith("description="))
        self.assertLessEqual(len(description.encode("utf-8")), 8000)
        self.assertIn("Personal appearance settings", description)
        self.assertIn("Do not remove Knox", description)
        self.assertIn("Category/Subcategory selectors", description)
        self.assertIn("[url=https://buildworks-studio.elyonmods.com/][b]Buildworks Studio[/b][/url]", description)

    def test_english_guide_describes_the_current_catalogues(self):
        path = ROOT / "Contents/mods/KnoxBuildworks/42/media/lua/shared/Translate/EN/IG_UI.json"
        strings = json.loads(path.read_text(encoding="utf-8"))
        self.assertIn("Materials & Tools and Skills & Knowledge", strings["IGUI_KBW_GuideDetailsBody"])
        self.assertIn("seven panel tones", strings["IGUI_KBW_GuideAppearanceBody"])
        self.assertIn("separate, narrow buildable catalogue", strings["IGUI_KBW_GuidePlanningBody"])
        self.assertIn("WorldDictionary", strings["IGUI_KBW_GuideMultiplayerBody"])

    def test_changelog_opens_with_the_completed_revamp_entry(self):
        text = (ROOT / "CHANGELOG.txt").read_text(encoding="utf-8")
        # The newest entry sits on top; released entries below it stay as shipped.
        self.assertTrue(text.startswith("[b]Buildworks Studio & World Pieces Update - Hotfix[/b]"))
        self.assertIn("[/list]\n\n\n[b]Buildworks Studio & World Pieces Update[/b]", text)
        self.assertIn("[/list]\n\n\n[b]Roof Helper Update - Hotfix[/b]", text)
        studio_entry = text.split("[b]Buildworks Studio & World Pieces Update[/b]", 1)[1].split("[/list]", 1)[0]
        self.assertIn("https://buildworks-studio.elyonmods.com/", studio_entry)
        self.assertIn("[/list]\n\n\n[b]Roof Helper, Magazines & Planning Tools Update[/b]", text)
        self.assertNotIn("[*][b]\n", text.split("[/list]", 1)[0])
        self.assertIn("[b]Catalogue and Planning Revamp & Build 42.21 Compatibility[/b]", text)
        self.assertIn("gear window now previews and saves", text)


if __name__ == "__main__":
    unittest.main()
