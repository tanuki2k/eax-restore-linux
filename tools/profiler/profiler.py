#!/usr/bin/env python3
"""Game profile capture & editor: a local web UI over the game database.

    python3 tools/profiler/profiler.py [--port 8765] [--no-open] [--quit-when-closed]

Standard library only (plus `jsonschema` for validation). See tools/profiler/README.md."""
import argparse, json, os, re, subprocess, sys, threading, time, traceback, webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ai, capture, classify, cleanup, dbio  # noqa: E402

WEB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")
SCRIPT = os.path.join(dbio.ROOT, "dist", "eax-restore-linux.sh")
JOBS = {}  # session id -> {"state": idle|running|done|error, "message": str}
LIVE = {}  # session id -> {"snap": label being taken or None, "until": time it finishes}; set while a live session has the game open
LAST_PING = time.time()  # the page pings every 10 s; --quit-when-closed stops the server when they stop
SERVER = None
QUIET_QUIT_SECONDS = int(os.environ.get("EAX_PROFILER_QUIT_SECONDS", 180))  # generous: a hidden browser tab runs its timers about once a minute
REG_SAVE_WAIT = 35  # Wine writes its registry files to disk about every 30 s while the game runs


def sdir(sid):
    if not re.match(r"^(steam|gog)-[A-Za-z0-9_]+$", sid):
        raise ValueError("bad session id")
    return os.path.join(capture.STATE, sid)


def find_game(sid):
    store, gid = sid.split("-", 1)
    for g in capture.library():
        if g["store"] == store and str(g["id"]) == gid:
            return g
    raise KeyError("game not found in the Steam/Heroic libraries")


def load_session(sid):
    p = os.path.join(sdir(sid), "session.json")
    if os.path.exists(p):
        with open(p) as f:
            return json.load(f)
    return {"id": sid, "steps": {}}


def save_session(sid, s):
    os.makedirs(sdir(sid), exist_ok=True)
    with open(os.path.join(sdir(sid), "session.json"), "w") as f:
        json.dump(s, f, indent=1)


def job(sid, fn, action=None):
    """Runs fn in a thread; the UI polls JOBS[sid]. `action` says which step it is, so the
    page can show the progress on that step."""
    if JOBS.get(sid, {}).get("state") == "running":
        raise RuntimeError("a step is already running")
    JOBS[sid] = {"state": "running", "message": "starting", "action": action}

    def say(msg):
        JOBS[sid]["message"] = msg

    def run():
        try:
            fn(say)
            JOBS[sid] = {"state": "done", "message": JOBS[sid]["message"], "action": action}
        except Exception as e:  # noqa: BLE001 - shown in the UI
            traceback.print_exc()
            JOBS[sid] = {"state": "error", "message": f"{type(e).__name__}: {e}", "action": action}
    threading.Thread(target=run, daemon=True).start()


def mark(sid, step, **extra):
    s = load_session(sid)
    s["steps"][step] = dict(time=time.time(), **extra)
    save_session(sid, s)


def do_action(sid, action):
    game = find_game(sid)
    d = sdir(sid)
    os.makedirs(d, exist_ok=True)
    exe = (load_session(sid).get("exe") or "")

    def has_prefix(g):
        pre = g.get("prefix") or ""
        return any(os.path.isfile(os.path.join(pre, *p)) for p in (("system.reg",), ("pfx", "system.reg")))

    def first_run(say):
        """The prefix only exists after the launcher has run the game once: do that
        ourselves, then close the game as soon as the prefix is initialised."""
        nonlocal game
        say("no Wine prefix yet: launching the game once to create it (can take a minute or two)...")
        capture.launch(game)
        t = time.time()
        while time.time() - t < 420:
            game = find_game(sid)
            if has_prefix(game) and (not game.get("prefix") or os.path.isfile(os.path.join(game["prefix"], "user.reg")) or os.path.isfile(os.path.join(game["prefix"], "pfx", "user.reg"))):
                break
            time.sleep(3)
        else:
            raise RuntimeError("the prefix was never created; launch the game by hand once, close it, then press Run again")
        say("prefix created: closing the game...")
        time.sleep(8)  # let the launcher finish writing the prefix
        t = time.time()
        while exe and capture.game_running(exe) and time.time() - t < 60:
            capture.stop_game(exe)
            time.sleep(3)
        if not exe and capture.wineserver_running(game["prefix"]):
            say("close the game yourself (its name is unknown); waiting...")
        t = time.time()
        while capture.wineserver_running(game["prefix"]) and time.time() - t < 120:
            time.sleep(2)
        game = find_game(sid)

    def start_game(say):
        capture.launch(game)
        say("waiting for the game to start (up to 3 minutes)...")
        t = time.time()
        while not capture.game_running(exe) and time.time() - t < 180:
            time.sleep(2)
        if not capture.game_running(exe):
            raise RuntimeError(f"{exe or 'the game'} never started; launch it by hand, then press the step again")

    def finish_game(say):
        say("game closed, waiting for Wine to save the registry...")
        t = time.time()
        while game.get("prefix") and capture.wineserver_running(game["prefix"]) and time.time() - t < 90:
            time.sleep(2)

    def take(label, say):
        n = capture.snapshot(game, d, label)
        mark(sid, label, files=n)
        say(f"snapshot '{label}' taken ({n} files)")

    def wait_pass(label, say):
        start_game(say)
        say("game running: change the sound options, then quit the game")
        while capture.game_running(exe):
            time.sleep(2)
        finish_game(say)
        take(label, say)

    def live_session(say):
        """The game stays open while the player takes several snapshots from the page."""
        if not exe:
            raise RuntimeError("Enter the game's executable name first so the tool can tell when it is running.")
        start_game(say)
        LIVE[sid] = {"snap": None, "until": 0}
        try:
            say("game running: take each snapshot from this page, then close the game")
            while capture.game_running(exe):
                time.sleep(2)
        finally:
            LIVE.pop(sid, None)
        finish_game(say)
        say("game closed")

    def live_snap(label):
        live = LIVE.get(sid)
        if not live:
            raise ValueError("The game isn't open from this page. Press “Open the game” first.")
        if live["snap"]:
            raise ValueError("A snapshot is already being taken.")
        if label.startswith("spk-"):
            if label[4:] not in capture.SPEAKER_LAYOUTS:
                raise ValueError("unknown speaker layout")
            if "audio" not in load_session(sid)["steps"]:
                raise ValueError("Take the audio snapshot first: speaker layouts are compared with it.")
        elif label not in ("audio", "optional"):
            raise ValueError("unknown snapshot")
        live.update(snap=label, until=time.time() + REG_SAVE_WAIT)

        def run():
            try:
                time.sleep(REG_SAVE_WAIT)  # lets Wine write the registry changes to disk first
                mark(sid, label, files=capture.snapshot(game, d, label))
            except Exception:  # noqa: BLE001 - the page just sees the snapshot missing
                traceback.print_exc()
            finally:
                live.update(snap=None, until=0)
        threading.Thread(target=run, daemon=True).start()

    def prepare(say):
        if not has_prefix(game):
            first_run(say)
        say("recording the config files before anything changes...")
        take("pre", say)
        if not os.path.exists(SCRIPT):
            subprocess.run([os.path.join(dbio.ROOT, "build.sh")], check=True, capture_output=True, cwd=dbio.ROOT)
        say("running the install (empty game database, canned answers)...")
        r = capture.run_install(game, d, SCRIPT)
        if not r["ok"]:
            raise RuntimeError("install did not finish:\n" + r["tail"])
        take("installed", say)
        if not exe:
            say("Install done. The baseline run was skipped because the executable name isn't known yet.")
            return
        start_game(say)
        say("baseline run: the game is starting up on its own, no need to touch it...")
        time.sleep(25)  # long enough for the game to write the files it rewrites on every start
        t = time.time()
        while capture.game_running(exe) and time.time() - t < 60:
            capture.stop_game(exe)
            time.sleep(3)
        finish_game(say)
        take("baseline", say)
        say("Ready for your turn: open the game and change its sound options.")

    if action == "prepare":
        job(sid, prepare, "prepare")
    elif action == "live":
        job(sid, live_session, "live")
    elif action.startswith("snap:"):
        live_snap(action[5:])
    elif action == "stop":
        if not exe:
            raise ValueError("The executable name isn't known.")
        capture.stop_game(exe)
    elif action == "pre":
        def f(say):
            if not has_prefix(game):
                first_run(say)
            n = capture.snapshot(game, d, "pre"); mark(sid, "pre", files=n); say(f"snapshot taken ({n} files)")
        job(sid, f)
    elif action in ("install", "installed"):
        def f(say):
            if not has_prefix(game):
                first_run(say)
            if not os.path.exists(SCRIPT):
                subprocess.run([os.path.join(dbio.ROOT, "build.sh")], check=True, capture_output=True, cwd=dbio.ROOT)
            say("running the install (empty game database, canned answers)...")
            r = capture.run_install(game, d, SCRIPT)
            if not r["ok"]:
                raise RuntimeError("install did not finish:\n" + r["tail"])
            n = capture.snapshot(game, d, "installed"); mark(sid, "installed", files=n)
            say("DSOAL installed, snapshot taken")
        job(sid, f)
    elif action in ("baseline", "audio", "optional"):
        job(sid, lambda say: wait_pass(action, say))
    elif action.startswith("spk-") and action[4:] in capture.SPEAKER_LAYOUTS:
        if "audio" not in load_session(sid)["steps"]:
            raise ValueError("Do the audio run first: speaker layouts are compared with it.")
        job(sid, lambda say: wait_pass(action, say))
    else:
        raise ValueError("unknown action")


def cleanup_plan(e, action):
    """What an action would do, or raises cleanup.Blocked with the reason."""
    steps = []
    if action in ("remove", "fresh") and e["state"] in ("installed", "orphan") and e.get("kind") == "manifest":
        steps.append(cleanup.plan_remove(e))
    elif action == "remove":
        raise cleanup.Blocked("There's no install of the script to remove here.")
    if action in ("prefix", "fresh") and e.get("prefix_root") and os.path.isdir(e["prefix_root"]):
        steps.append(cleanup.plan_reset_prefix(e))
    elif action == "prefix":
        raise cleanup.Blocked("This game has no prefix on disk.")
    if action == "fresh" and not steps:
        raise cleanup.Blocked("Nothing to clean up for this game.")
    return {"title": {"remove": "Remove the script's install", "prefix": "Delete the Wine prefix", "fresh": "Start fresh"}[action] + f": {e['name']}",
            "steps": steps, "also_session": action == "fresh"}


def cleanup_run(e, action):
    def run(say):
        done = []
        if action in ("remove", "fresh") and e["state"] in ("installed", "orphan") and e.get("kind") == "manifest":
            if e["state"] == "installed" and not os.path.exists(SCRIPT):
                subprocess.run([os.path.join(dbio.ROOT, "build.sh")], check=True, capture_output=True, cwd=dbio.ROOT)
            say("removing the script's install...")
            done += cleanup.remove_install(e, SCRIPT, os.path.join(capture.STATE, "cleanup"))
        if action in ("prefix", "fresh") and e.get("prefix_root") and os.path.isdir(e["prefix_root"]):
            say("deleting the prefix...")
            done += cleanup.reset_prefix(e)
        if action == "fresh":
            done += cleanup.reset_session(e)
        say("\n".join(done) or "Nothing to do.")
    return run


def previous_label(steps, label):
    """What this snapshot is compared with. The audio and optional runs compare with each
    other when the other came first (the game keeps the earlier run's options), otherwise
    with the baseline, the install or the pre-install snapshot. Redoing an unrelated step
    can't change it."""
    if label.startswith("spk-"):
        return "audio"
    if label in ("audio", "optional"):
        other = "optional" if label == "audio" else "audio"
        if other in steps and steps[other]["time"] < steps[label]["time"]:
            return other
    order = ["pre", "installed", "baseline"]
    if label in order:
        return order[order.index(label) - 1] if order.index(label) and order[order.index(label) - 1] in steps else None
    return next((k for k in ("baseline", "installed", "pre") if k in steps), None)


def step_view(sid, label):
    game, s = find_game(sid), load_session(sid)
    steps, d = s["steps"], sdir(sid)
    if label not in steps:
        raise ValueError("That step hasn't been captured yet.")
    ref = previous_label(steps, label)
    noise = set()
    if "baseline" in steps and label != "baseline":
        noise = classify.noise_keys(capture.diff_snapshots(game, d, "installed", "baseline"))
    return classify.step_view(game, d, label, ref, noise)


def draft(sid, use_ai):
    game, s = find_game(sid), load_session(sid)
    d, steps = sdir(sid), s["steps"]
    noise = set()
    if "baseline" in steps:
        noise = classify.noise_keys(capture.diff_snapshots(game, d, "installed", "baseline"))
    diffs = {}
    for label in ("audio", "optional"):
        if label in steps:
            diffs[label] = capture.diff_snapshots(game, d, previous_label(steps, label), label, ignore=noise)
    if "audio" in steps:
        for label in sorted(k for k in steps if k.startswith("spk-")):
            diffs[label] = capture.diff_snapshots(game, d, "audio", label, ignore=noise)
    out = classify.build(game["name"], diffs, use_ai)
    s["draft"], s["drop"], s["cats"] = out, None, None
    save_session(sid, s)
    return out


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, obj, code=200, ctype="application/json"):
        body = obj if isinstance(obj, bytes) else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def route(self, method):
        # Only the page itself and /api: no way to read arbitrary files.
        if self.headers.get("Host", "").split(":")[0] not in ("127.0.0.1", "localhost"):
            return self.reply({"error": "forbidden"}, 403)
        p = self.path.split("?")[0]
        try:
            if method == "GET" and p in ("/", "/app.js", "/app.css"):
                fn = "index.html" if p == "/" else p[1:]
                ct = {"html": "text/html", "js": "text/javascript", "css": "text/css"}[fn.rsplit(".", 1)[1]]
                with open(os.path.join(WEB, fn), "rb") as f:
                    return self.reply(f.read(), ctype=ct + "; charset=utf-8")
            if method == "GET" and p == "/api/_sleep" and os.environ.get("PROFILER_DEBUG"):
                time.sleep(4)  # lets a headless screenshot wait for the async page load
                return self.reply(b"", ctype="image/gif")
            if method == "GET" and p == "/api/schema":
                return self.reply(dbio.schema())
            if method == "GET" and p == "/api/games":
                return self.reply({"games": dbio.list_games(), "stale": dbio.stale_entries(), "ai": ai.available()})
            m = re.match(r"^/api/game/(tested|untested|drafts)/([a-z0-9-]+)$", p)
            if m and method == "GET":
                g = dbio.load(*m.groups())
                return self.reply({"game": g, "errors": dbio.validate(g)})
            if m and method == "PUT":
                return self.reply(dbio.save(*m.groups(), self.body()))
            ms = re.match(r"^/api/session/([a-z]+-[A-Za-z0-9_]+)/step/([a-z0-9-]+)$", p)
            if ms and method == "GET":
                return self.reply(step_view(*ms.groups()))
            if p == "/api/cleanup" and method == "GET":
                return self.reply({"entries": [cleanup.describe(e) for e in cleanup.find_entries()],
                                   "launchers": {"steam": cleanup.launcher_running("steam"), "heroic": cleanup.launcher_running("gog")}})
            if p == "/api/cleanup/status" and method == "GET":
                return self.reply(JOBS.get("cleanup", {"state": "idle", "message": ""}))
            if p in ("/api/cleanup/plan", "/api/cleanup/run") and method == "POST":
                b = self.body()
                if b.get("action") not in ("remove", "prefix", "fresh"):
                    raise ValueError("unknown action")
                try:
                    e = cleanup.get_entry(b["eid"])
                    plan = cleanup_plan(e, b["action"])
                    if p.endswith("/plan"):
                        return self.reply(plan)
                    job("cleanup", cleanup_run(e, b["action"]))
                    return self.reply({"ok": True})
                except cleanup.Blocked as x:
                    return self.reply({"blocked": str(x)})
            m2 = re.match(r"^/api/preview/(tested|untested|drafts)/([a-z0-9-]+)$", p)
            if m2 and method == "POST":
                return self.reply(dbio.preview(*m2.groups(), self.body()))
            if method == "POST" and p == "/api/merge-config":
                b = self.body()
                merged, report = classify.merge_game_config(b.get("existing"), b.get("new") or {})
                return self.reply({"game_config": merged, "report": report})
            if method == "POST" and p == "/api/validate":
                return self.reply({"errors": dbio.validate(self.body())})
            if method == "POST" and p == "/api/new":
                b = self.body()
                return self.reply(dbio.new_stub(b["id"], b["name"], b.get("store"), b.get("store_id")))
            if method == "POST" and p == "/api/promote":
                b = self.body()
                dbio.promote(b["id"], b["from"], b["to"])
                return self.reply({"ok": True})
            if method == "POST" and p == "/api/rebuild":
                ok, msg = dbio.rebuild()
                return self.reply({"ok": ok, "message": msg})
            if method == "POST" and p == "/api/ai":
                b = self.body()
                return self.reply(ai.ask(b["task"], b.get("context", {})))
            if method == "GET" and p == "/api/ping":
                global LAST_PING
                LAST_PING = time.time()
                return self.reply({"ok": True})
            if method == "POST" and p == "/api/quit":
                self.reply({"ok": True})
                threading.Thread(target=SERVER.shutdown, daemon=True).start()
                return
            if method == "GET" and p == "/api/library":
                return self.reply({"games": capture.library()})
            m = re.match(r"^/api/session/([a-z]+-[A-Za-z0-9_]+)(?:/(\w+))?$", p)
            if m:
                sid, what = m.groups()
                if method == "GET" and not what:
                    return self.reply({"session": load_session(sid), "job": JOBS.get(sid, {"state": "idle"}), "live": LIVE.get(sid)})
                if method == "POST" and what == "drop":
                    b = self.body(); s = load_session(sid); s["drop"] = b["drop"]; s["cats"] = b.get("cats", {}); save_session(sid, s)
                    return self.reply({"ok": True})
                if method == "POST" and what == "exe":
                    s = load_session(sid); s["exe"] = self.body()["exe"]; save_session(sid, s)
                    return self.reply({"ok": True})
                if method == "POST" and what == "action":
                    do_action(sid, self.body()["action"])
                    return self.reply({"ok": True})
                if method == "POST" and what == "draft":
                    return self.reply(draft(sid, self.body().get("ai", True)))
                if method == "POST" and what == "reset":
                    import shutil; shutil.rmtree(sdir(sid), ignore_errors=True); JOBS.pop(sid, None)
                    return self.reply({"ok": True})
            return self.reply({"error": "not found"}, 404)
        except (KeyError, ValueError, RuntimeError, FileNotFoundError) as e:
            return self.reply({"error": f"{type(e).__name__}: {e}"}, 400)
        except Exception as e:  # noqa: BLE001
            traceback.print_exc()
            return self.reply({"error": f"{type(e).__name__}: {e}"}, 500)

    def do_GET(self): self.route("GET")
    def do_POST(self): self.route("POST")
    def do_PUT(self): self.route("PUT")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--no-open", action="store_true")
    ap.add_argument("--quit-when-closed", action="store_true", help="exit once the page has stopped pinging and no capture is running")
    a = ap.parse_args()
    global SERVER
    srv = SERVER = ThreadingHTTPServer(("127.0.0.1", a.port), H)
    url = f"http://127.0.0.1:{a.port}/"
    print(f"Game profile editor: {url}  (AI: {ai.available() or 'off - set ANTHROPIC_API_KEY or log in to claude'})")
    if not a.no_open:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    if a.quit_when_closed:
        def watch():
            while True:
                time.sleep(5)
                busy = LIVE or any(j.get("state") == "running" for j in JOBS.values())
                if not busy and time.time() - LAST_PING > QUIET_QUIT_SECONDS:
                    srv.shutdown()
                    return
        threading.Thread(target=watch, daemon=True).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
