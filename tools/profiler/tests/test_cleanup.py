import json, os, sys, tempfile, unittest
from unittest import mock
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import capture, cleanup


def read(p):
    with open(p) as f:
        return f.read()


def write(p, text="x"):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write(text)


class World:
    """A fake home: one live Steam install, one orphan (game gone from Steam), one clean prefix."""
    def __init__(self, tmp):
        self.home = tmp
        self.steam = f"{tmp}/.local/share/Steam"
        self.apps = f"{self.steam}/steamapps"
        write(f"{self.apps}/libraryfolders.vdf", f'"libraryfolders"\n{{\n"0"\n{{\n"path" "{self.steam}"\n}}\n}}\n')
        write(f"{self.apps}/appmanifest_424242.acf", '"AppState"\n{\n"appid" "424242"\n"name" "Live Game"\n"installdir" "Live Game"\n}\n')
        self.live = f"{self.apps}/common/Live Game"
        self.live_pfx = f"{self.apps}/compatdata/424242"
        write(f"{self.live}/dsound.dll", "ours")
        write(f"{self.live}/dsound.dll.bak.20260101_000000", "original")
        write(f"{self.live_pfx}/pfx/drive_c/windows/syswow64/dsound.dll", "ours")
        write(f"{self.live}/.eax-restore-manifest.txt", "# EAX Restore manifest, format 2\n"
              f"{self.live}/dsound.dll\n{self.live_pfx}/pfx/drive_c/windows/syswow64/dsound.dll\nREGISTRY:OVERRIDE:dsound\nVCRUN\n")
        # orphan: no appmanifest, files + a backup + a path that must not be touched
        self.orphan = f"{self.apps}/common/Gone Game/System"
        self.orphan_pfx = f"{self.apps}/compatdata/555555"
        self.outside = f"{tmp}/precious/important.dll"
        write(self.outside, "keep me")
        write(f"{self.orphan}/dsound.dll", "ours")
        write(f"{self.orphan}/dsound.dll.bak.20260101_000000", "original")
        write(f"{self.orphan}/alsoft.ini", "ini")
        write(f"{self.orphan_pfx}/pfx/drive_c/windows/syswow64/dsoal-aldrv.dll", "ours")
        write(f"{self.orphan}/.eax-restore-manifest.txt", "# EAX Restore manifest, format 2\n"
              f"{self.orphan}/dsound.dll\n{self.orphan}/alsoft.ini\n{self.orphan_pfx}/pfx/drive_c/windows/syswow64/dsoal-aldrv.dll\n{self.outside}\nREGISTRY:COM\n")


class Cleanup(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.w = World(self.tmp.name)
        self.p = mock.patch.object(capture, "HOME", self.tmp.name)
        self.p.start()
        self.q = mock.patch.object(cleanup, "running_reason", lambda *a, **k: None)
        self.q.start()

    def tearDown(self):
        self.q.stop(); self.p.stop(); self.tmp.cleanup()

    def entries(self):
        return {e["name"]: e for e in cleanup.find_entries() if e["kind"] == "manifest"}

    def test_finds_live_and_orphan(self):
        e = self.entries()
        self.assertEqual(e["Live Game"]["state"], "installed")
        self.assertEqual(e["Live Game"]["id"], 424242)
        self.assertEqual(e["System"]["state"] if "System" in e else e["Gone Game"]["state"], "orphan")
        o = e.get("Gone Game") or e["System"]
        self.assertEqual(o["prefix_root"], self.w.orphan_pfx)
        self.assertEqual(o["backups"], 1)

    def test_orphan_removal_restores_backup_and_keeps_outside_paths(self):
        o = next(e for e in self.entries().values() if e["state"] == "orphan")
        plan = cleanup.plan_remove(o)
        self.assertTrue(any(i.startswith("SKIP") and "important.dll" in i for i in plan["items"]))
        cleanup.remove_install(o, "/nonexistent", self.tmp.name + "/s")
        self.assertEqual(read(f"{self.w.orphan}/dsound.dll"), "original")
        self.assertFalse(os.path.exists(f"{self.w.orphan}/alsoft.ini"))
        self.assertFalse(os.path.exists(f"{self.w.orphan}/dsound.dll.bak.20260101_000000"))
        self.assertFalse(os.path.exists(f"{self.w.orphan}/.eax-restore-manifest.txt"))
        self.assertFalse(os.path.exists(f"{self.w.orphan_pfx}/pfx/drive_c/windows/syswow64/dsoal-aldrv.dll"))
        self.assertEqual(read(self.w.outside), "keep me")
        self.assertTrue(os.path.isdir(self.w.orphan))  # not empty: the restored original is there

    def test_dry_run_changes_nothing(self):
        before = sorted(os.path.join(d, f) for d, _, fs in os.walk(self.tmp.name) for f in fs)
        for e in self.entries().values():
            cleanup.plan_remove(e)
            if e.get("prefix_root"):
                cleanup.plan_reset_prefix(e)
        after = sorted(os.path.join(d, f) for d, _, fs in os.walk(self.tmp.name) for f in fs)
        self.assertEqual(before, after)

    def test_prefix_reset_deletes_only_that_prefix_and_cleans_manifest(self):
        e = self.entries()["Live Game"]
        msgs = cleanup.reset_prefix(e)
        self.assertFalse(os.path.exists(self.w.live_pfx))
        self.assertTrue(os.path.isdir(self.w.orphan_pfx))
        text = read(f"{self.w.live}/.eax-restore-manifest.txt")
        self.assertIn(f"{self.w.live}/dsound.dll", text)
        for gone in ("syswow64", "REGISTRY", "VCRUN"):
            self.assertNotIn(gone, text)

    def test_prefix_guards(self):
        with self.assertRaises(cleanup.Blocked):
            cleanup.check_prefix_root(self.tmp.name + "/precious", "steam")          # not compatdata
        with self.assertRaises(cleanup.Blocked):
            cleanup.check_prefix_root(f"{self.w.apps}/compatdata/12/pfx", "steam")   # inside, not the AppID folder
        link = f"{self.w.apps}/compatdata/777"
        os.symlink(self.w.outside.rsplit("/", 1)[0], link)
        with self.assertRaises(cleanup.Blocked):
            cleanup.check_prefix_root(link, "steam")                                  # symlink
        with self.assertRaises(cleanup.Blocked):
            cleanup.check_prefix_root("/etc", "gog")                                  # not in Heroic's prefix folder

    def test_shared_heroic_prefix_is_refused(self):
        base = f"{self.tmp.name}/Games/Heroic/Prefixes/default/Shared"
        os.makedirs(base + "/drive_c")
        for n in ("a", "b"):
            write(f"{self.tmp.name}/.config/heroic/GamesConfig/{n}.json", json.dumps({n: {"winePrefix": base}}))
        with self.assertRaises(cleanup.Blocked):
            cleanup.check_prefix_root(base, "gog")
        os.remove(f"{self.tmp.name}/.config/heroic/GamesConfig/b.json")
        self.assertTrue(cleanup.check_prefix_root(base, "gog"))

    def test_running_game_blocks(self):
        self.q.stop()
        try:
            with mock.patch.object(capture, "game_running", lambda exe: True), \
                    mock.patch.object(cleanup, "profile_info", lambda s, i: ("x", "Game.exe")):
                with self.assertRaises(cleanup.Blocked):
                    cleanup.plan_reset_prefix(self.entries()["Live Game"])
        finally:
            self.q.start()


if __name__ == "__main__":
    unittest.main()
