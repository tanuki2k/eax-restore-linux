import json, os, sys, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import capture, classify, dbio


def world(tmp, before, after):
    """A fake game folder with one file whose content changes between two snapshots."""
    game_dir = os.path.join(tmp, "game"); prefix = os.path.join(tmp, "pfx")
    os.makedirs(game_dir); os.makedirs(os.path.join(prefix, "drive_c/users/steamuser/Documents"))
    game = {"store": "steam", "id": 1, "name": "T", "dir": game_dir, "prefix": prefix}
    sd = os.path.join(tmp, "sess")
    for label, files in (("a", before), ("b", after)):
        for rel, text in files.items():
            p = os.path.join(game_dir if not rel.startswith("~") else prefix, rel.lstrip("~"))
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "wb" if isinstance(text, bytes) else "w") as f:
                f.write(text)
        capture.snapshot(game, sd, label)
    return game, sd


class Capture(unittest.TestCase):
    def test_idtech_matches_quake4_database_entry(self):
        q4 = dbio.load("tested", "quake-4")
        want = q4["game_config"]["audio_settings"][0]["changes"]["Quake4Config.cfg"]
        before = 'seta s_useOpenAL "0"\nseta s_useEAXReverb "0"\nseta s_useEAXOcclusion "0"\nseta s_volume_dB "0"\n'
        after = 'seta s_useOpenAL "1"\nseta s_useEAXReverb "1"\nseta s_useEAXOcclusion "1"\nseta s_volume_dB "0"\n'
        with tempfile.TemporaryDirectory() as t:
            game, sd = world(t, {"q4base/Quake4Config.cfg": before}, {"q4base/Quake4Config.cfg": after})
            diffs = capture.diff_snapshots(game, sd, "a", "b")
            gc, skipped = classify.draft_game_config(diffs, [])
        self.assertEqual(gc["audio_settings"][0]["changes"]["Quake4Config.cfg"], want)
        self.assertEqual(gc["files"]["Quake4Config.cfg"], {"format": "idtech_cfg", "locations": ["game:q4base/Quake4Config.cfg"]})
        self.assertEqual(skipped, [])

    def test_ini_sections_and_noise(self):
        a = "[Audio]\nEAX=0\nVolume=5\n[Window]\nX=10\n"
        b = "[Audio]\nEAX=1\nVolume=5\n[Window]\nX=99\n"
        with tempfile.TemporaryDirectory() as t:
            game, sd = world(t, {"game.ini": a}, {"game.ini": b})
            diffs = capture.diff_snapshots(game, sd, "a", "b", ignore={("game.ini", "Window", "X")})
            gc, _ = classify.draft_game_config(diffs, [])
        self.assertEqual(gc["audio_settings"][0]["changes"], {"game.ini": {"Audio": {"EAX": "1"}}})

    def test_registry_dword_and_wine_noise(self):
        hdr = "WINE REGISTRY Version 2\n\n"
        a = hdr + '[Software\\\\Wow6432Node\\\\Outrage\\\\Descent3] 1\n"SoundMixer"=dword:00000001\n[Software\\\\Wine\\\\X] 1\n"a"="1"\n'
        b = hdr + '[Software\\\\Wow6432Node\\\\Outrage\\\\Descent3] 1\n"SoundMixer"=dword:00000006\n[Software\\\\Wine\\\\X] 1\n"a"="2"\n'
        with tempfile.TemporaryDirectory() as t:
            game, sd = world(t, {"~system.reg": a}, {"~system.reg": b})
            diffs = capture.diff_snapshots(game, sd, "a", "b")
            gc, _ = classify.draft_game_config(diffs, [])
        self.assertEqual(gc["audio_settings"][0]["changes"],
                         {"system.reg": {"Software\\Wow6432Node\\Outrage\\Descent3": {"SoundMixer": "6"}}})
        self.assertEqual(gc["files"]["system.reg"]["locations"], ["prefix:system.reg"])

    def test_unexpressible_value_goes_to_skipped(self):
        with tempfile.TemporaryDirectory() as t:
            game, sd = world(t, {"g.ini": "[S]\nk=a\n"}, {"g.ini": "[S]\nk=C:\\x\\y\n"})
            gc, skipped = classify.draft_game_config(capture.diff_snapshots(game, sd, "a", "b"), [])
        self.assertTrue(skipped)

    def test_draft_validates_against_schema(self):
        game = {"name": "T", "stores": {"steam": {"id": 1}}, "eax": {"api": "openal"},
                "game_config": {"files": {"g.ini": {"format": "ini", "locations": ["game:g.ini"]}},
                                "audio_settings": [{"title": "t", "reason": "r", "changes": {"g.ini": {"S": {"k": "1"}}}}]}}
        self.assertEqual(dbio.validate(game), [])
        game["game_config"]["audio_settings"][0]["changes"] = {"other.ini": {"S": {"k": "1"}}}
        self.assertTrue(dbio.validate(game))


class NewStub(unittest.TestCase):
    def test_stub_with_store_validates_and_slug_collides(self):
        gid = "zz-profiler-test"
        path = dbio._path("untested", gid)
        try:
            r = dbio.new_stub(gid, "ZZ Test", "steam", 999999)
            self.assertEqual(r["errors"], [])
            self.assertEqual(dbio.load("untested", gid)["stores"], {"steam": {"id": 999999, "id_source": "local_install_verified"}})
            r2 = dbio.new_stub(gid, "ZZ Test", "gog", 5)
            self.assertEqual(r2["id"], gid + "-5")
            with self.assertRaises(ValueError):
                dbio.new_stub(gid, "ZZ Test")
        finally:
            for g in (gid, gid + "-5"):
                if os.path.exists(dbio._path("untested", g)):
                    os.remove(dbio._path("untested", g))


class ConfigTxt(unittest.TestCase):
    def test_sectioned_txt_is_captured_as_ini_but_a_readme_is_not(self):
        before = "[Sound]\r\nsoundvolume = 75\r\neaxenabled = 0\r\n"
        after = before.replace("eaxenabled = 0", "eaxenabled = 1")
        readme = "Thanks for playing.\nSee the manual = good\n"
        with tempfile.TemporaryDirectory() as t:
            game, sd = world(t, {"Profiles/Player.txt": before, "readme.txt": readme},
                             {"Profiles/Player.txt": after, "readme.txt": readme + "x\n"})
            self.assertEqual([d["file"] for d in capture.diff_snapshots(game, sd, "a", "b")], ["Player.txt"])
            gc, skipped = classify.draft_game_config(capture.diff_snapshots(game, sd, "a", "b"), [])
        self.assertEqual(gc["files"]["Player.txt"], {"format": "ini", "locations": ["game:Profiles/Player.txt"]})


class Noise(unittest.TestCase):
    def test_flags_bookkeeping_not_options(self):
        self.assertTrue(classify.noise_reason("WindowPosX", "1", "2"))
        self.assertTrue(classify.noise_reason("LastPlayed", "", "x"))
        self.assertTrue(classify.noise_reason("whatever", "1", "1700000000"))
        for k in ("s_useEAXReverb", "UseEAX", "Width", "ScreenHeight", "SoundMixer", "Timeout_Disabled_Sound"[:0] or "EAXEnabled"):
            self.assertIsNone(classify.noise_reason(k, "0", "1"), k)

    def test_clean_suggestions_drops_what_the_schema_forbids(self):
        import ai
        raw = {"alsoft_ini": {"reverb": {"boost": "6", "evil": "x"}, "general": {"sources": "abc", "frequency": "48000"}, "bogus": {"a": "1"}},
               "eax": {"api": "nope", "versions": ["3.0", "9.0"]}, "reasons": {"eax.versions": "r"}}
        out = ai.clean_suggestions(raw)
        self.assertEqual(out["alsoft_ini"], {"reverb": {"boost": "6"}, "general": {"frequency": "48000"}})
        self.assertEqual(out["eax"], {"versions": ["3.0"]})
        self.assertEqual(ai.clean_suggestions("garbage"), {"alsoft_ini": {}, "eax": {}, "reasons": {}})


class Preview(unittest.TestCase):
    def test_preview_empty_for_unchanged_and_one_line_for_a_rename(self):
        g = dbio.load("tested", "quake-4")
        self.assertTrue(dbio.preview("tested", "quake-4", g)["same"])
        g["name"] = "Quake IV"
        d = dbio.preview("tested", "quake-4", g)
        self.assertFalse(d["same"])
        self.assertEqual([l for l in d["diff"].splitlines() if l[:1] in "+-" and l[:3] not in ("+++", "---")],
                         ['-  "name": "Quake 4",', '+  "name": "Quake IV",'])
        self.assertTrue(dbio.preview("untested", "zz-not-there", {"name": "x", "stores": {}, "eax": {"api": "openal"}})["new_file"])


class Existing(unittest.TestCase):
    def test_every_game_file_validates(self):
        bad = {}
        for g in dbio.list_games():
            e = dbio.validate(dbio.load(g["folder"], g["id"]))
            if e:
                bad[g["id"]] = e
        self.assertEqual(bad, {})


if __name__ == "__main__":
    unittest.main()


class KeyValueFormat(unittest.TestCase):
    def test_space_separated_cfg_is_read(self):
        a = "//video\nScreenWidth 1024\nFSAA 0\n//audio\nEnableEAX 1\nSpeakers 2\n"
        b = a.replace("EnableEAX 1", "EnableEAX 0").replace("FSAA 0", "FSAA 3")
        with tempfile.TemporaryDirectory() as t:
            game, sd = world(t, {"settings.cfg": a}, {"settings.cfg": b})
            diffs = capture.diff_snapshots(game, sd, "a", "b")
        self.assertEqual(diffs[0]["format"], "dark_cfg")
        self.assertEqual({c["key"]: c["new"] for c in diffs[0]["changes"]}, {"EnableEAX": "0", "FSAA": "3"})

    def test_unreadable_change_is_reported_not_silent(self):
        with tempfile.TemporaryDirectory() as t:
            game, sd = world(t, {"x.cfg": "\x00\x01"}, {"x.cfg": "\x00\x02"})
            diffs = capture.diff_snapshots(game, sd, "a", "b")
            gc, skipped = classify.draft_game_config(diffs, [])
        self.assertTrue(skipped and "no keys could be read" in skipped[0])


class StepView(unittest.TestCase):
    def test_a_step_shows_its_files_and_what_changed_with_the_reasons(self):
        a = "Width 800\nLastPlayed 100\nEAX 0\n"
        b = "Width 800\nLastPlayed 200\nEAX 1\n"
        with tempfile.TemporaryDirectory() as t:
            game, sd = world(t, {"g.cfg": a}, {"g.cfg": b})
            v = classify.step_view(game, sd, "b", "a", baseline_noise={("g.cfg", "", "Width")})
            first = classify.step_view(game, sd, "a", None)
        self.assertEqual([f["location"] for f in v["files"]], ["game:g.cfg"])
        rows = {c["key"]: c for f in v["diffs"] for c in f["changes"]}
        self.assertEqual(set(rows), {"LastPlayed", "EAX"})
        self.assertTrue(rows["LastPlayed"]["suspect_reason"])
        self.assertIsNone(rows["EAX"]["suspect_reason"])
        self.assertEqual((first["reference"], first["diffs"]), (None, []))
