"""The editor's HTTP guard (cross-site requests refused) and the exe name checks that gate stopping processes."""
import http.client, json, os, sys, threading, unittest
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import capture, profiler  # noqa: E402


class Guard(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = ThreadingHTTPServer(("127.0.0.1", 0), profiler.H)
        cls.port = cls.srv.server_address[1]
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def post(self, headers, path="/api/cleanup/plan"):
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request("POST", path, body=json.dumps({"action": "bogus"}), headers=headers)
        r = c.getresponse(); r.read()
        return r.status

    def test_cross_site_and_plain_text_posts_are_refused(self):
        self.assertEqual(self.post({"Content-Type": "text/plain"}), 403)
        self.assertEqual(self.post({"Content-Type": "application/json", "Origin": "http://evil.example"}), 403)
        self.assertEqual(self.post({"Content-Type": "application/json", "Sec-Fetch-Site": "cross-site"}), 403)

    def test_the_page_itself_gets_through(self):
        same = {"Content-Type": "application/json", "Origin": f"http://127.0.0.1:{self.port}", "Sec-Fetch-Site": "same-origin"}
        self.assertNotEqual(self.post(same), 403)

    def test_pages_cannot_be_framed(self):
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request("GET", "/api/schema"); r = c.getresponse(); r.read()
        self.assertEqual(r.getheader("X-Frame-Options"), "DENY")


class ExeName(unittest.TestCase):
    def test_only_a_bare_exe_file_name_is_accepted(self):
        for ok in ("game.exe", "Quake4.exe", "Star Trek EF2.exe"):
            self.assertTrue(capture.valid_exe(ok), ok)
        for bad in ("", "/", "a", "exe", ".exe", "../x.exe", "a/b.exe", "x.exe; rm", None, 5):
            self.assertFalse(capture.valid_exe(bad), repr(bad))

    def test_match_is_the_whole_file_name(self):
        self.assertTrue(capture._runs_exe("game.exe", r"Z:\games\Game.exe -windowed"))
        self.assertTrue(capture._runs_exe("game.exe", "wine /opt/g/game.exe"))
        self.assertFalse(capture._runs_exe("game.exe", "tail -f /tmp/mygame.exe.log"))
        self.assertFalse(capture._runs_exe("game.exe", "vim notgame.exe"))


if __name__ == "__main__":
    unittest.main()
