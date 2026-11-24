import os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import dbio


class BuildState(unittest.TestCase):
    GAME = {"$schema": "../schema.json", "name": "T", "stores": {"steam": {"id": 1}}, "eax": {"api": "openal"}}

    def built(self, game=None, **over):
        e = dbio.built_forms({"t": game or self.GAME})["t"]
        e.update(over)
        return {"t": e}

    def test_current_when_the_built_entry_matches_the_file(self):
        self.assertEqual(dbio.build_state("games", "t", self.GAME, self.built())["state"], "current")

    def test_changed_names_the_fields_that_differ(self):
        s = dbio.build_state("games", "t", {**self.GAME, "notes": "x", "name": "U"}, self.built())
        self.assertEqual((s["state"], s["fields"]), ("changed", ["name", "notes"]))

    def test_an_unknown_game_is_built_with_tested_false_and_a_verified_one_without(self):
        unknown = self.built()["t"]
        self.assertEqual((unknown["tested"], unknown["stores"]["steam"]["compatibility"]), (False, "unknown"))
        verified = self.built({**self.GAME, "compatibility": "verified"})["t"]
        self.assertNotIn("tested", verified)
        self.assertEqual(verified["stores"]["steam"]["compatibility"], "verified")
        self.assertEqual(dbio.build_state("games", "t", {**self.GAME, "compatibility": "verified"}, self.built())["fields"],
                         ["compatibility", "stores", "tested"])

    def test_new_when_not_built_yet_and_draft_never_built(self):
        self.assertEqual(dbio.build_state("games", "t", self.GAME, {})["state"], "new")
        self.assertEqual(dbio.build_state("drafts", "t", self.GAME, self.built())["state"], "draft")

    def test_schema_line_and_key_order_do_not_count_as_changes(self):
        reordered = {"eax": {"api": "openal"}, "stores": {"steam": {"id": 1}}, "name": "T"}
        self.assertEqual(dbio.build_state("games", "t", reordered, self.built())["state"], "current")

    def test_setting_counts(self):
        s = lambda verified=None: {"title": "t", "reason": "r", "changes": {}, **({"verified": verified} if verified is not None else {})}
        self.assertEqual(dbio.setting_counts({"name": "T"}), {"settings": 0, "unverified": 0})
        self.assertEqual(dbio.setting_counts({"game_config": {"files": {"a": {}}}}), {"settings": 0, "unverified": 0})
        g = {"game_config": {"audio_settings": [s(True), s()], "optional_settings": [s(False)]}}
        self.assertEqual(dbio.setting_counts(g), {"settings": 3, "unverified": 2})
        g["install"] = {"alsoft_ini": {"reverb": {"boost": "6"}}}
        self.assertEqual(dbio.setting_counts(g)["unverified"], 3)
        g["install"]["alsoft_verified"] = True
        self.assertEqual(dbio.setting_counts(g)["unverified"], 2)

    def test_every_real_game_has_a_state(self):
        for g in dbio.list_games():
            self.assertIn(g["build"]["state"], ("current", "changed", "new", "draft"))


if __name__ == "__main__":
    unittest.main()

