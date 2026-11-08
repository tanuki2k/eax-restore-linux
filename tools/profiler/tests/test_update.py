"""update.py against throwaway git repos: an origin, and a clone that is up to date, behind, or diverged."""
import os, subprocess, sys, tempfile, unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import dbio, update  # noqa: E402

ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}


def git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, env=ENV)


def commit(cwd, name, text="x"):
    with open(os.path.join(cwd, name), "w") as f:
        f.write(text)
    git(cwd, "add", name)
    git(cwd, "commit", "-m", f"add {name}")


class UpdateTest(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.TemporaryDirectory()
        self.origin, self.clone = (os.path.join(self.t.name, n) for n in ("origin", "clone"))
        os.mkdir(self.origin)
        git(self.origin, "init", "-q", "-b", "main")
        commit(self.origin, "a")
        git(self.t.name, "clone", "-q", self.origin, self.clone)
        with open(os.path.join(self.clone, "build.sh"), "w") as f:
            f.write("#!/bin/sh\nexit 0\n")
        os.chmod(os.path.join(self.clone, "build.sh"), 0o755)
        self._root, dbio.ROOT = dbio.ROOT, self.clone
        update.STATE.update(behind=0, subjects=[], can_update=False, reason="")

    def tearDown(self):
        dbio.ROOT = self._root
        self.t.cleanup()

    def test_up_to_date_offers_nothing(self):
        update.check()
        self.assertEqual(update.state()["behind"], 0)

    def test_behind_lists_the_changes_and_pulls(self):
        commit(self.origin, "b")
        update.check()
        s = update.state()
        self.assertEqual((s["behind"], s["can_update"], s["subjects"]), (1, True, ["add b"]))
        self.assertTrue(update.apply()["build_ok"])
        self.assertTrue(os.path.exists(os.path.join(self.clone, "b")))
        self.assertEqual(update.state()["behind"], 0)

    def test_diverged_is_not_pulled(self):
        commit(self.origin, "b")
        commit(self.clone, "c")
        update.check()
        s = update.state()
        self.assertEqual((s["behind"], s["can_update"]), (1, False))
        with self.assertRaises(ValueError):
            update.apply()
        self.assertFalse(os.path.exists(os.path.join(self.clone, "b")))

    def test_no_upstream_is_silent(self):
        git(self.clone, "branch", "--unset-upstream")
        update.check()
        self.assertEqual(update.state()["behind"], 0)

    def test_build_counts_the_commits_that_touched_the_editor(self):
        self.assertEqual(update.version()["build"], "0")  # the origin's commit is outside tools/profiler
        os.makedirs(os.path.join(self.clone, "tools", "profiler"))
        git(self.clone, "add", "build.sh")  # setUp's stub is untracked
        git(self.clone, "commit", "-m", "add build.sh")
        self.assertEqual(update.version()["build"], "0")
        commit(self.clone, os.path.join("tools", "profiler", "x.py"))
        self.assertEqual(update.version()["build"], "1")

    def test_version_names_the_branch_and_commit_and_flags_changes(self):
        git(self.clone, "add", "build.sh")  # setUp's stub is untracked
        git(self.clone, "commit", "-m", "add build.sh")
        v = update.version()
        self.assertEqual((v["branch"], v["dirty"]), ("main", False))
        self.assertRegex(v["commit"], r"^[0-9a-f]{7,}$")
        with open(os.path.join(self.clone, "a"), "w") as f:
            f.write("changed")
        self.assertTrue(update.version()["dirty"])

    def test_opt_out(self):
        commit(self.origin, "b")
        os.environ["EAX_PROFILER_NO_UPDATE_CHECK"] = "1"
        try:
            update.check()
        finally:
            del os.environ["EAX_PROFILER_NO_UPDATE_CHECK"]
        self.assertEqual(update.state()["behind"], 0)


if __name__ == "__main__":
    unittest.main()
