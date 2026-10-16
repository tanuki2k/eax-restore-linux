import os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import dbio


class BuildState(unittest.TestCase):
    GAME = {"$schema": "../../schema.json", "name": "T", "stores": {"steam": {"id": 1}}, "eax": {"api": "openal"}}

    def built(self, **over):
        e = {"id": "t", **{k: v for k, v in self.GAME.items() if k != "$schema"}}
        e.update(over)
        return {"t": e}

    def test_current_when_the_built_entry_matches_the_file(self):
        self.assertEqual(dbio.build_state("tested", "t", self.GAME, self.built())["state"], "current")

    def test_changed_names_the_fields_that_differ(self):
        s = dbio.build_state("untested", "t", {**self.GAME, "notes": "x", "name": "U"}, self.built(tested=False))
        self.assertEqual((s["state"], s["fields"]), ("changed", ["name", "notes"]))

    def test_an_untested_game_is_built_with_tested_false(self):
        self.assertEqual(dbio.build_state("untested", "t", self.GAME, self.built(tested=False))["state"], "current")
        self.assertEqual(dbio.build_state("untested", "t", self.GAME, self.built())["state"], "changed")
        self.assertEqual(dbio.build_state("tested", "t", self.GAME, self.built(tested=False))["fields"], ["tested"])

    def test_new_when_not_built_yet_and_draft_never_built(self):
        self.assertEqual(dbio.build_state("untested", "t", self.GAME, {})["state"], "new")
        self.assertEqual(dbio.build_state("drafts", "t", self.GAME, self.built())["state"], "draft")

    def test_schema_line_and_key_order_do_not_count_as_changes(self):
        reordered = {"eax": {"api": "openal"}, "stores": {"steam": {"id": 1}}, "name": "T"}
        self.assertEqual(dbio.build_state("tested", "t", reordered, self.built())["state"], "current")

    def test_every_real_game_has_a_state(self):
        for g in dbio.list_games():
            self.assertIn(g["build"]["state"], ("current", "changed", "new", "draft"))


if __name__ == "__main__":
    unittest.main()

