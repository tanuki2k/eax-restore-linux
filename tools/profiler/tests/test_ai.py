import json, os, stat, sys, tempfile, time, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import ai

KEY = "sk-ant-api03-" + "A" * 30 + "wxyz"
FAKE_CLAUDE = """#!/bin/sh
case "$1 $2" in
  "auth status") echo '{"loggedIn": true, "authMethod": "claude.ai", "email": "me@example.com"}' ;;
  "auth login") echo "Open https://example.com/login"; sleep 3 ;;
  "auth logout") echo "bye" ;;
esac
"""


class Base(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.old = (ai.CONFIG, dict(os.environ))
        ai.CONFIG = os.path.join(self.d, "cfg", "profiler.json")
        os.environ.pop("ANTHROPIC_API_KEY", None)
        os.environ["PATH"] = self.d + os.pathsep + "/usr/bin:/bin"  # no real claude on it
        os.environ["HOME"] = self.d  # nor in ~/.local/bin
        self._check = ai.check_key
        ai.check_key = lambda key: (True, "")

    def tearDown(self):
        ai.CONFIG = self.old[0]
        ai.check_key = self._check
        os.environ.clear(); os.environ.update(self.old[1])
        if ai._LOGIN["proc"] and ai._LOGIN["proc"].poll() is None:
            ai._LOGIN["proc"].kill()
        ai._LOGIN.update(proc=None, out=None)

    def fake_claude(self):
        p = os.path.join(self.d, "claude")
        with open(p, "w") as f:
            f.write(FAKE_CLAUDE)
        os.chmod(p, os.stat(p).st_mode | stat.S_IXUSR)


class Key(Base):
    def test_saved_key_is_private_used_and_never_returned(self):
        self.assertIsNone(ai.available())
        ai.save_key("  " + KEY + "\n")
        self.assertEqual(stat.S_IMODE(os.stat(ai.CONFIG).st_mode), 0o600)
        self.assertEqual(ai.available(), "api")
        self.assertEqual(ai.api_key(), KEY)
        st = ai.status()
        self.assertEqual(st["saved_key"], "…wxyz")
        self.assertNotIn(KEY, json.dumps(st))

    def test_the_environment_variable_wins_over_a_saved_key(self):
        ai.save_key(KEY)
        os.environ["ANTHROPIC_API_KEY"] = "sk-ant-from-env"
        self.assertEqual(ai.api_key(), "sk-ant-from-env")
        self.assertTrue(ai.status()["env_key"])

    def test_forgetting_removes_the_key_and_the_file(self):
        ai.save_key(KEY)
        ai.forget_key()
        self.assertFalse(os.path.exists(ai.CONFIG))
        self.assertIsNone(ai.status()["saved_key"])

    def test_forgetting_keeps_other_settings(self):
        os.makedirs(os.path.dirname(ai.CONFIG))
        with open(ai.CONFIG, "w") as f:
            json.dump({"anthropic_api_key": KEY, "other": 1}, f)
        ai.forget_key()
        with open(ai.CONFIG) as f:
            self.assertEqual(json.load(f), {"other": 1})

    def test_something_that_is_not_a_key_is_refused(self):
        for bad in ("", "hello", "sk-ant-short", "sk-proj-" + "a" * 40):
            with self.assertRaises(ai.AIError):
                ai.save_key(bad)
        self.assertFalse(os.path.exists(ai.CONFIG))

    def test_a_key_anthropic_rejects_is_not_saved(self):
        ai.check_key = lambda key: (False, "Anthropic didn't accept that key.")
        with self.assertRaises(ai.AIError):
            ai.save_key(KEY)
        self.assertFalse(os.path.exists(ai.CONFIG))

    def test_a_key_that_could_not_be_checked_is_saved_with_a_note(self):
        ai.check_key = lambda key: (None, "Couldn't reach Anthropic.")
        r = ai.save_key(KEY)
        self.assertFalse(r["checked"])
        self.assertIn("without being checked", r["note"])
        self.assertTrue(os.path.exists(ai.CONFIG))


class Cli(Base):
    def test_not_installed(self):
        self.assertEqual(ai.cli_status(), {"installed": False, "logged_in": False})
        with self.assertRaises(ai.AIError):
            ai.cli_login()

    def test_found_in_local_bin_when_the_session_path_leaves_it_out(self):
        # An editor started from the app menu gets a PATH without ~/.local/bin.
        os.makedirs(os.path.join(self.d, ".local", "bin"))
        with open(os.path.join(self.d, ".local", "bin", "claude"), "w") as f:
            f.write(FAKE_CLAUDE)
        os.chmod(os.path.join(self.d, ".local", "bin", "claude"), 0o755)
        os.environ["PATH"] = "/usr/bin:/bin"
        self.assertEqual(ai.claude_path(), os.path.join(self.d, ".local", "bin", "claude"))
        self.assertTrue(ai.cli_status()["logged_in"])
        self.assertEqual(ai.available(), "cli")

    def test_status_reads_the_claude_commands_login(self):
        self.fake_claude()
        self.assertEqual(ai.cli_status(), {"installed": True, "logged_in": True, "method": "claude.ai", "email": "me@example.com"})
        self.assertEqual(ai.available(), "cli")

    def test_login_runs_in_the_background_and_shows_its_output(self):
        self.fake_claude()
        ai.cli_login()
        for _ in range(30):
            st = ai.status()
            if "https://example.com/login" in st["login"]["output"]:
                break
            time.sleep(0.1)
        self.assertTrue(st["login"]["running"])
        self.assertIn("https://example.com/login", st["login"]["output"])


if __name__ == "__main__":
    unittest.main()
