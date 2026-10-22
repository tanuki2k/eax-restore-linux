"""Profiler hardening: shared Heroic prefix, snapshot roots, session file, API key file."""
import json, os, stat, sys, tempfile, threading, unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import ai, capture, cleanup, profiler  # noqa: E402


def write(p, text="x"):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write(text)


class Hardening(unittest.TestCase):
    def test_heroic_shared_prefix_is_not_deletable(self):
        with tempfile.TemporaryDirectory() as home:
            conf = f"{home}/.config/heroic"
            write(f"{conf}/config.json", json.dumps({"defaultSettings": {"winePrefix": f"{home}/Games/Heroic/Prefixes"},
                                                    "defaultWinePrefixDir": f"{home}/Games/Heroic/Prefixes"}))
            shared = f"{home}/Games/Heroic/Prefixes/shared"
            write(f"{shared}/drive_c/x")
            with mock.patch.object(capture, "HOME", home):
                self.assertIn(os.path.realpath(shared).lower(), cleanup.heroic_shared_prefixes())
                with self.assertRaises(cleanup.Blocked):
                    cleanup.check_prefix_root(shared, "gog")

    def test_snapshot_skips_user_folders_linked_outside_the_prefix(self):
        with tempfile.TemporaryDirectory() as t:
            pfx, game, real_docs = f"{t}/pfx", f"{t}/game", f"{t}/home/Documents"
            os.makedirs(f"{game}"); os.makedirs(real_docs)
            os.makedirs(f"{pfx}/drive_c/users/steamuser")
            os.symlink(real_docs, f"{pfx}/drive_c/users/steamuser/Documents")
            os.makedirs(f"{pfx}/drive_c/users/steamuser/AppData/Roaming")
            g = {"dir": game, "prefix": pfx}
            paths = [p for _, p in capture.roots(g)]
            self.assertNotIn(f"{pfx}/drive_c/users/steamuser/Documents", paths)
            self.assertIn(f"{pfx}/drive_c/users/steamuser/AppData/Roaming", paths)

    def test_session_file_is_replaced_whole_and_survives_parallel_marks(self):
        with tempfile.TemporaryDirectory() as t:
            with mock.patch.object(profiler, "sdir", lambda sid: f"{t}/{sid}"):
                threads = [threading.Thread(target=profiler.mark, args=("steam-1", f"s{i}")) for i in range(20)]
                [x.start() for x in threads]; [x.join() for x in threads]
                self.assertEqual(len(profiler.load_session("steam-1")["steps"]), 20)
                self.assertFalse(os.path.exists(f"{t}/steam-1/session.json.tmp"))

    def test_api_key_file_is_owner_only_even_after_a_loose_leftover(self):
        with tempfile.TemporaryDirectory() as t:
            cfg = f"{t}/c/ai.json"
            os.makedirs(os.path.dirname(cfg))
            write(cfg + ".tmp", "old"); os.chmod(cfg + ".tmp", 0o644)
            with mock.patch.object(ai, "CONFIG", cfg):
                ai._write_config({"anthropic_api_key": "k"})
            self.assertEqual(stat.S_IMODE(os.stat(cfg).st_mode), 0o600)


if __name__ == "__main__":
    unittest.main()


class IdAndValues(unittest.TestCase):
    def test_an_id_with_a_trailing_newline_is_not_an_id(self):
        import dbio
        self.assertIsNotNone(dbio.ID_RE.match("abc"))
        self.assertIsNone(dbio.ID_RE.match("abc\n"))

    def test_ai_alsoft_values_must_match_whole(self):
        out = ai.clean_suggestions({"alsoft_ini": {"general": {"sources": "6\n"}, "reverb": {"boost": "3"}}})
        self.assertNotIn("general", out["alsoft_ini"])
        self.assertEqual(out["alsoft_ini"]["reverb"]["boost"], "3")

    def test_unfinished_todo_text_blocks_sending(self):
        import submit
        g = {"name": "T", "stores": {"steam": {"id": 1}}, "eax": {"api": "directsound3d"},
             "game_config": {"files": {}, "audio_settings": [{"title": "TODO title", "reason": "TODO reason", "changes": {}}]}}
        with mock.patch.object(submit, "gh_login", lambda: "x"):
            self.assertTrue(any("TODO" in e for e in submit.prepare("untested", "t", g)["errors"]))
