import json, os, stat, subprocess, sys, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import dbio, submit

FAKE_GH = r'''#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
log = os.environ["FAKE_GH_LOG"]
stdin = "" if sys.stdin.isatty() else sys.stdin.read()
with open(log, "a") as f:
    f.write(json.dumps({"args": a, "stdin": stdin}) + "\n")
s = " ".join(a)
if a[:2] == ["api", "user"]: print("tester")
elif a[:2] == ["repo", "fork"]: print("already exists")
elif a[:1] == ["api"] and "git/ref/heads/" in s: print("abc123")
elif a[:1] == ["api"] and "game-database.json" in s and "Accept" in s: sys.stdout.write(open(os.environ["FAKE_GH_DB"]).read())
elif a[:1] == ["api"] and "?ref=" in s and "--jq" in a:
    sys.exit(1)  # no such file yet, anywhere
elif a[:1] == ["api"]: print("{}")
elif a[:2] == ["pr", "create"]: print("https://github.com/up/repo/pull/7")
'''


class Privacy(unittest.TestCase):
    def test_flags_home_user_and_long_numbers_but_not_store_ids(self):
        g = {"name": "T", "stores": {"steam": {"id": 123456789012}},
             "notes": "see /home/ben/games and C:\\Users\\ben\\x, key 123456789012345",
             "game_config": {"files": {"a.ini": {"locations": ["game:a.ini"]}}}}
        why = [f["why"] for f in submit.privacy_findings(g, home="/home/ben", user="ben")]
        self.assertTrue(any("home folder" in w for w in why))
        self.assertTrue(any("long number" in w or "home folder" in w for w in why))
        clean = {"name": "T", "stores": {"steam": {"id": 123456789012}}, "game_config": g["game_config"]}
        self.assertEqual(submit.privacy_findings(clean, home="/home/ben", user="ben"), [])

    def test_user_name_matches_whole_words_only(self):
        self.assertEqual(submit.privacy_findings({"n": "Benchmark mode"}, home="/home/ben", user="ben"), [])
        self.assertEqual(len(submit.privacy_findings({"n": "saved by ben"}, home="/home/ben", user="ben")), 1)


class Splice(unittest.TestCase):
    def test_splicing_a_game_back_gives_the_committed_database_byte_for_byte(self):
        with open(os.path.join(dbio.ROOT, "game-database.json")) as f:
            full = f.read()
        for folder in ("untested", "tested"):
            gid = sorted(fn[:-5] for fn in os.listdir(os.path.join(dbio.ROOT, dbio.FOLDERS[folder])))[3]
            without = json.loads(full)
            without["games"] = [g for g in without["games"] if g["id"] != gid]
            with open(os.path.join(dbio.ROOT, dbio.FOLDERS[folder], gid + ".json")) as f:
                text = f.read()
            entry = submit.database_entry(gid, text, folder)
            got = submit.splice_database(json.dumps(without, indent=2, ensure_ascii=False), entry)
            self.assertEqual(got, full, folder)

    def test_replacing_an_existing_entry_does_not_duplicate_it(self):
        with open(os.path.join(dbio.ROOT, "game-database.json")) as f:
            full = f.read()
        gid = sorted(fn[:-5] for fn in os.listdir(os.path.join(dbio.ROOT, dbio.FOLDERS["untested"])))[0]
        with open(os.path.join(dbio.ROOT, dbio.FOLDERS["untested"], gid + ".json")) as f:
            entry = submit.database_entry(gid, f.read(), "untested")
        self.assertEqual(submit.splice_database(full, entry), full)


class Routes(unittest.TestCase):
    GAME = {"name": "Test Game", "stores": {"steam": {"id": 424242}}, "eax": {"api": "openal"}}

    def test_browser_route_fills_the_page_in_when_it_is_short(self):
        r = submit.submit_with_browser("test-game", self.GAME)
        self.assertEqual(r["mode"], "browser")
        self.assertIn("new/dev?filename=data/games/untested/test-game.json&value=", r["url"])
        self.assertNotIn("json", r)

    def test_browser_route_hands_over_the_json_when_it_is_too_long(self):
        big = dict(self.GAME, notes="x" * 9000)
        r = submit.submit_with_browser("test-game", big)
        self.assertNotIn("&value=", r["url"])
        self.assertIn('"Test Game"', r["json"])

    def test_problems_stop_the_submission(self):
        with self.assertRaises(submit.SubmitError):
            submit.submit("drafts", "bad", {"name": "No stores", "eax": {"api": "openal"}}, via="browser")

    def test_gh_route_makes_a_branch_commits_both_files_and_opens_the_pull_request(self):
        with tempfile.TemporaryDirectory() as d:
            gh = os.path.join(d, "gh")
            with open(gh, "w") as f:
                f.write(FAKE_GH)
            os.chmod(gh, os.stat(gh).st_mode | stat.S_IXUSR)
            log = os.path.join(d, "log")
            with open(os.path.join(dbio.ROOT, "game-database.json")) as f:
                full = json.load(f)
            dbfile = os.path.join(d, "db.json")
            with open(dbfile, "w") as f:
                json.dump(full, f, indent=2, ensure_ascii=False)
            env = {"PATH": d + os.pathsep + os.environ["PATH"], "FAKE_GH_LOG": log, "FAKE_GH_DB": dbfile}
            old = {k: os.environ.get(k) for k in env}
            os.environ.update(env)
            try:
                r = submit.submit("drafts", "test-game", self.GAME, note="Works for me", checked_install=True)
            finally:
                for k, v in old.items():
                    os.environ.pop(k) if v is None else os.environ.__setitem__(k, v)
            self.assertEqual(r, {"mode": "gh", "url": "https://github.com/up/repo/pull/7"})
            with open(log) as lf:
                calls = [json.loads(l) for l in lf]
            puts = [c for c in calls if "PUT" in c["args"]]
            self.assertEqual(len(puts), 2)
            paths = [c["args"][-3] for c in puts]
            self.assertEqual(paths, [f"repos/tester/{submit.UPSTREAM.split('/')[1]}/contents/data/games/untested/test-game.json",
                                     f"repos/tester/{submit.UPSTREAM.split('/')[1]}/contents/game-database.json"])
            self.assertTrue(all(json.loads(c["stdin"])["branch"].startswith("profile/test-game-") for c in puts))
            pr = next(c for c in calls if c["args"][:2] == ["pr", "create"])
            self.assertIn("--base", pr["args"]); self.assertEqual(pr["args"][pr["args"].index("--base") + 1], submit.BASE)
            self.assertIn("Works for me", pr["stdin"]); self.assertIn("[x] Checked on my own install", pr["stdin"])


if __name__ == "__main__":
    unittest.main()
