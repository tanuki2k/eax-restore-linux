"""Golden checks: the capture pipeline, fed before/after files for a game that already has a
database entry, must draft the same changes the entry has. The gadb flips are done by the
script's own bash code (src/game-config.sh), so the Python reader is checked against it."""
import json, os, struct, subprocess, sys, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import capture, classify, dbio
from test_capture import world

ROOT = dbio.ROOT
REAL_GDB = os.path.expanduser("~/.local/share/Steam/steamapps/compatdata/21090/pfx/drive_c/users/Public/Documents/Monolith Productions/FEAR/Profiles/Profile000.gdb")
FEAR_GDB = "~drive_c/users/Public/Documents/Monolith Productions/FEAR/Profiles/Profile000.gdb"


def make_gadb(items):
    """A minimal valid GADB file, the same layout tests/helpers.bash make_gadb writes."""
    table, offs = b"", []
    for name, _ in items:
        offs.append(len(table))
        table += name.encode() + b"\0"
    head = b"GADB" + b"\0" * 4 + struct.pack("<I", len(table)) + b"\0" * 16
    pad = b"\0" * ((4 - (28 + len(table)) % 4) % 4)
    return head + table + pad + b"".join(struct.pack("<5I", o, 1, 0, 1, v) for o, (_, v) in zip(offs, items))


def bash(script):
    pre = "; ".join(f'source "{ROOT}/src/{f}.sh"' for f in ("globals", "ui", "common", "game-config", "launcher-config"))
    return subprocess.run(["bash", "-c", pre + "; " + script], capture_output=True, text=True, check=True).stdout


class Fear(unittest.TestCase):
    def test_gadb_flip_matches_the_fear_entry(self):
        entry = dbio.load("tested", "fear")
        want = entry["game_config"]["audio_settings"][0]["changes"]["Profile000.gdb"]
        items = [("Music", 1), ("UseHWSound", 0), ("UseEAX", 0), ("UseEAX4", 0), ("Sfx", 0)]
        with tempfile.TemporaryDirectory() as t:
            before = make_gadb(items)
            f = os.path.join(t, "p.gdb")
            with open(f, "wb") as fh:
                fh.write(before)
            bash("".join(f'config_set_key "{f}" gadb "" {k} 1; ' for k in want))  # the script's own writer
            with open(f, "rb") as fh:
                after = fh.read()
            game, sd = world(t, {FEAR_GDB: before}, {FEAR_GDB: after})
            diffs = capture.diff_snapshots(game, sd, "a", "b")
            gc, skipped = classify.draft_game_config(diffs, [])
        self.assertEqual(skipped, [])
        self.assertEqual(gc["audio_settings"][0]["changes"]["Profile000.gdb"], want)
        self.assertEqual(gc["files"]["Profile000.gdb"], entry["game_config"]["files"]["Profile000.gdb"])

    def test_a_non_gadb_file_is_reported_not_guessed(self):
        with tempfile.TemporaryDirectory() as t:
            game, sd = world(t, {FEAR_GDB: b"not a gadb file"}, {FEAR_GDB: b"not a gadb FILE"})
            gc, skipped = classify.draft_game_config(capture.diff_snapshots(game, sd, "a", "b"), [])
        self.assertTrue(skipped and "isn't a GADB file" in skipped[0])
        self.assertNotIn("audio_settings", gc)

    def test_values_other_than_0_1_are_not_expressible(self):
        with tempfile.TemporaryDirectory() as t:
            game, sd = world(t, {FEAR_GDB: make_gadb([("Vol", 3)])}, {FEAR_GDB: make_gadb([("Vol", 7)])})
            diffs = capture.diff_snapshots(game, sd, "a", "b")
        self.assertFalse(diffs[0]["changes"][0]["expressible"])

    @unittest.skipUnless(os.path.exists(REAL_GDB), "needs a real F.E.A.R. profile on this machine")
    def test_reader_agrees_with_the_script_on_a_real_profile(self):
        with open(REAL_GDB, "rb") as fh:
            data = fh.read()
        parsed = capture.parse_gadb(data)
        self.assertTrue(parsed)
        names = sorted(parsed)[:60]
        out = bash(f'for k in {" ".join(names)}; do echo "$k=$(config_get_key "{REAL_GDB}" gadb "" "$k")"; done')
        self.assertEqual(dict(ln.split("=", 1) for ln in out.split()), {k: parsed[k] for k in names})


class Descent3(unittest.TestCase):
    """The one wine_reg entry: a dword and a string under the game's registry key."""
    HDR = "WINE REGISTRY Version 2\n\n"
    KEY = "Software\\\\Wow6432Node\\\\Outrage\\\\Descent3"

    def test_registry_changes_match_the_entry(self):
        entry = dbio.load("tested", "descent-3")
        want = entry["game_config"]["audio_settings"][0]["changes"]
        before = self.HDR + f'[{self.KEY}] 1\n"SoundMixer"=dword:00000001\n[Software\\\\Wine\\\\Drivers] 1\n"Audio"="alsa"\n'
        after = self.HDR + f'[{self.KEY}] 1\n"SoundMixer"=dword:00000006\n"SoundcardName"="Primary Sound Driver"\n[Software\\\\Wine\\\\Drivers] 1\n"Audio"="pulse"\n'
        with tempfile.TemporaryDirectory() as t:
            game, sd = world(t, {"~system.reg": before}, {"~system.reg": after})
            gc, _ = classify.draft_game_config(capture.diff_snapshots(game, sd, "a", "b"), [])
        self.assertEqual(gc["audio_settings"][0]["changes"], want)
        self.assertEqual(gc["files"]["system.reg"], entry["game_config"]["files"]["system.reg"])


if __name__ == "__main__":
    unittest.main()


def snaps(tmp, states):
    """Snapshots of one game folder in several states: {label: {relative file: text}}."""
    game_dir, prefix = os.path.join(tmp, "game"), os.path.join(tmp, "pfx")
    os.makedirs(game_dir)
    os.makedirs(os.path.join(prefix, "drive_c/users/steamuser/AppData/Roaming"))
    game = {"store": "steam", "id": 1, "name": "T", "dir": game_dir, "prefix": prefix}
    sd = os.path.join(tmp, "sess")
    for label, files in states.items():
        for rel, text in files.items():
            p = os.path.join(prefix if rel.startswith("~") else game_dir, rel.lstrip("~"))
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w") as f:
                f.write(text)
        capture.snapshot(game, sd, label)
    return game, sd


def speaker_settings(entry):
    """(speakers as a list, changes) for each speaker-gated audio setting of an entry."""
    rows = []
    for s in entry["game_config"].get("audio_settings", []):
        sp = s.get("only_if", {}).get("speakers")
        if sp:
            rows.append(([sp] if isinstance(sp, str) else list(sp), s["changes"]))
    return sorted(rows, key=lambda r: json.dumps(r))


def draft_speakers(game, sd, layouts):
    diffs = {f"spk-{l}": capture.diff_snapshots(game, sd, "audio", f"spk-{l}") for l in layouts}
    gc = {"files": {}}
    skipped = classify.draft_speaker_settings(diffs, gc)
    return gc, skipped


class Speakers(unittest.TestCase):
    def test_bioshock_layouts_group_like_the_entry(self):
        entry = dbio.load("tested", "bioshock")
        sec = "ShockGame.ShockUserSettings"
        rel = "~drive_c/users/steamuser/AppData/Roaming/Bioshock/Bioshock.ini"
        ini = lambda mode: f"[{sec}]\nbEAXEnabled=True\nSpeakerMode={mode}\nBrightness=0.5\n"
        modes = {"quad": "SM_Quad", "surround51": "SM_5_1", "surround61": "SM_5_1", "surround71": "SM_7_1", "matrix": "SM_ProLogic"}
        states = {"audio": {rel: ini("SM_Stereo")}}
        for layout, mode in modes.items():
            states[f"spk-{layout}"] = {rel: ini(mode)}
        with tempfile.TemporaryDirectory() as t:
            game, sd = snaps(t, states)
            gc, skipped = draft_speakers(game, sd, modes)
        self.assertEqual(skipped, [])
        self.assertEqual(speaker_settings({"game_config": gc}), speaker_settings(entry))
        self.assertEqual(gc["files"]["Bioshock.ini"]["locations"], ["prefix_appdata:Bioshock/Bioshock.ini"])

    def test_nwn_numeric_values_and_headphones(self):
        entry = dbio.load("tested", "neverwinter-nights-diamond")
        ini = lambda n: f"[Sound Options]\nEnvironment Effects=1\nSpeaker Type={n}\n"
        values = {"headphones": 1, "matrix": 2, "quad": 3, "surround51": 4, "surround61": 4, "surround71": 5}
        states = {"audio": {"nwn.ini": ini(0)}}
        for layout, n in values.items():
            states[f"spk-{layout}"] = {"nwn.ini": ini(n)}
        with tempfile.TemporaryDirectory() as t:
            game, sd = snaps(t, states)
            gc, _ = draft_speakers(game, sd, values)
        self.assertEqual(speaker_settings({"game_config": gc}), speaker_settings(entry))

    def test_four_identical_surround_runs_become_surround(self):
        entry = dbio.load("tested", "quake-4")
        cfg = lambda n: f'seta s_numberOfSpeakers "{n}"\nseta s_volume_dB "0"\n'
        layouts = ("quad", "surround51", "surround61", "surround71")
        states = {"audio": {"q4base/Quake4Config.cfg": cfg(2)}}
        for l in layouts:
            states[f"spk-{l}"] = {"q4base/Quake4Config.cfg": cfg(6)}
        with tempfile.TemporaryDirectory() as t:
            game, sd = snaps(t, states)
            gc, _ = draft_speakers(game, sd, layouts)
        self.assertEqual(speaker_settings({"game_config": gc}), speaker_settings(entry))

    def test_a_layout_that_changes_nothing_makes_no_setting(self):
        states = {"audio": {"g.cfg": "A 1\nB 2\nC 3\n"}, "spk-quad": {"g.cfg": "A 1\nB 2\nC 3\n"}}
        with tempfile.TemporaryDirectory() as t:
            game, sd = snaps(t, states)
            gc, _ = draft_speakers(game, sd, ["quad"])
        self.assertNotIn("audio_settings", gc)

    def test_bookkeeping_keys_do_not_split_identical_layouts(self):
        mk = lambda mode, t: f"Mode {mode}\nLastPlayed {t}\nB 2\nC 3\n"
        states = {"audio": {"g.cfg": mk(1, 100)}, "spk-surround51": {"g.cfg": mk(2, 101)}, "spk-surround61": {"g.cfg": mk(2, 102)}}
        with tempfile.TemporaryDirectory() as t:
            game, sd = snaps(t, states)
            gc, _ = draft_speakers(game, sd, ["surround51", "surround61"])
        self.assertEqual([s["only_if"]["speakers"] for s in gc["audio_settings"]], [["surround51", "surround61"]])

    def test_speaker_snapshots_do_not_become_the_previous_snapshot(self):
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
        import profiler
        steps = {"audio": {"time": 10}, "spk-quad": {"time": 20}, "optional": {"time": 30}}
        self.assertEqual(profiler.previous_label(steps, "optional"), "audio")
