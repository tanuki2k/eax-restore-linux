import os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))


class MergeCapture(unittest.TestCase):
    def setUp(self):
        self.entry = {"files": {"g.ini": {"format": "ini", "locations": ["game:g.ini"]}},
                      "audio_settings": [{"title": "Enable EAX", "reason": "r", "changes": {"g.ini": {"Audio": {"EAX": "1"}}}}]}

    def merge(self, new):
        import classify
        return classify.merge_game_config(self.entry, new)

    def cap(self, changes, title="T", only_if=None, kind="audio_settings", files=None):
        st = {"title": title, "reason": "TODO reason", "changes": changes}
        if only_if:
            st["only_if"] = only_if
        return {"files": files or {"g.ini": {"format": "ini", "locations": ["game:g.ini"]}}, kind: [st]}

    def test_an_identical_setting_is_not_added_again(self):
        merged, rep = self.merge(self.cap({"g.ini": {"Audio": {"EAX": "1"}}}))
        self.assertEqual(len(merged["audio_settings"]), 1)
        self.assertEqual((rep["added"], rep["skipped"]), ([], ["T"]))

    def test_the_same_change_in_the_other_list_counts_as_already_there(self):
        merged, rep = self.merge(self.cap({"g.ini": {"Audio": {"EAX": "1"}}}, kind="optional_settings"))
        self.assertNotIn("optional_settings", merged)
        self.assertEqual(rep["skipped"], ["T"])

    def test_a_partly_new_setting_keeps_only_the_new_keys(self):
        merged, rep = self.merge(self.cap({"g.ini": {"Audio": {"EAX": "1", "Reverb": "2"}}}))
        self.assertEqual(merged["audio_settings"][1]["changes"], {"g.ini": {"Audio": {"Reverb": "2"}}})
        self.assertEqual(len(rep["trimmed"]), 1)

    def test_a_different_value_is_kept_and_reported(self):
        merged, rep = self.merge(self.cap({"g.ini": {"Audio": {"EAX": "0"}}}))
        self.assertEqual(merged["audio_settings"][1]["changes"], {"g.ini": {"Audio": {"EAX": "0"}}})
        self.assertEqual(len(rep["conflicts"]), 1)

    def test_the_same_key_under_a_different_speaker_gate_is_new(self):
        merged, rep = self.merge(self.cap({"g.ini": {"Audio": {"EAX": "1"}}}, only_if={"speakers": "quad"}))
        self.assertEqual(len(merged["audio_settings"]), 2)
        self.assertEqual(rep["skipped"], [])

    def test_existing_file_definitions_are_not_overwritten(self):
        other = {"g.ini": {"format": "ini", "locations": ["prefix_documents:g.ini"]}}
        merged, rep = self.merge(self.cap({"g.ini": {"Audio": {"New": "1"}}}, files=other))
        self.assertEqual(merged["files"]["g.ini"]["locations"], ["game:g.ini"])
        self.assertEqual(rep["files_differ"], ["g.ini"])

    def test_merging_twice_adds_nothing_the_second_time(self):
        import classify
        new = self.cap({"g.ini": {"Audio": {"Reverb": "2"}}})
        once, _ = classify.merge_game_config(self.entry, new)
        twice, rep = classify.merge_game_config(once, new)
        self.assertEqual(once, twice)
        self.assertEqual(rep["added"], [])

    def test_the_input_entry_is_not_modified(self):
        import copy
        before = copy.deepcopy(self.entry)
        self.merge(self.cap({"g.ini": {"Audio": {"Reverb": "2"}}}))
        self.assertEqual(self.entry, before)


if __name__ == "__main__":
    unittest.main()
