"""Past installs of the script, and Wine prefixes: find them, show exactly what removing them
would do (dry run), and remove them. Nothing here trusts a path from the browser: every action
takes an entry id from a fresh scan, and every path it deletes is checked against that entry."""
import glob, hashlib, json, os, re, shutil, subprocess, time

import capture, dbio

MANIFEST = ".eax-restore-manifest.txt"
KEYWORD = re.compile(r"^(VCRUN|REGISTRY:|LAUNCHER:|CONFIG:)")
STEAM_ROOT_RE = re.compile(r"^(.*/steamapps/compatdata/\d+)(/|$)")
MAX_DEPTH = 5


class Blocked(Exception):
    """An action that must not run, with the reason shown to the player."""


# ---------------------------------------------------------------- manifest

def parse_manifest(path):
    """-> {'marker': bool, 'files': [abs paths], 'keywords': {kind, ...}}."""
    text = capture._rd(path, "r", errors="replace")
    files, kinds = [], set()
    for ln in text.splitlines():
        if not ln.strip() or ln.startswith("#"):
            continue
        m = KEYWORD.match(ln)
        if m:
            kinds.add(m.group(1).rstrip(":"))
        elif ln.startswith("/"):
            files.append(ln.rstrip("\r"))
    return {"marker": "# EAX Restore: uninstalled" in text, "files": files, "kinds": kinds, "text": text}


def prefix_root_of(path, store=None):
    """The Wine prefix a deployed file sits in, from its path alone."""
    m = STEAM_ROOT_RE.match(path)
    if m:
        return m.group(1)
    if "/drive_c/" in path:
        root = path.split("/drive_c/")[0]
        return os.path.dirname(root) if os.path.basename(root) == "pfx" else root
    return None


# ---------------------------------------------------------------- prefix safety

def heroic_roots():
    return [r for r in (capture.HOME + "/.config/heroic", capture.HOME + "/.var/app/com.heroicgameslauncher.hgl/config/heroic") if os.path.isdir(r)]


def heroic_prefix_bases():
    bases = [os.path.join(capture.HOME, "Games", "Heroic", "Prefixes")]
    for r in heroic_roots():
        try:
            d = json.loads(capture._rd(os.path.join(r, "config.json"))).get("defaultSettings", {}).get("winePrefix")
            if d:
                bases.append(os.path.expanduser(d))
        except (OSError, ValueError):
            pass
    return [os.path.realpath(b) for b in bases]


def heroic_prefix_users(root):
    """How many Heroic game configs point at this prefix (case-insensitively, since two
    entries that differ only by case are the same folder on some setups)."""
    n = 0
    for r in heroic_roots():
        for fn in glob.glob(os.path.join(r, "GamesConfig", "*.json")):
            try:
                for k, v in json.loads(capture._rd(fn)).items():
                    if isinstance(v, dict) and str(v.get("winePrefix", "")).rstrip("/").lower() == root.rstrip("/").lower():
                        n += 1
            except (OSError, ValueError):
                pass
    return n


def check_prefix_root(root, store):
    """Raises Blocked unless root is a prefix this tool may delete."""
    if not root or not os.path.isabs(root):
        raise Blocked("There's no known prefix for this game.")
    if os.path.islink(root):
        raise Blocked("The prefix folder is a symbolic link, so it's left alone.")
    real = os.path.realpath(root)
    if store == "steam":
        m = STEAM_ROOT_RE.match(real)
        libs = [os.path.realpath(x) for x in capture.steam_libs()]
        if not m or m.group(1) != real or os.path.dirname(os.path.dirname(real)) not in libs:
            raise Blocked("That folder isn't a Steam compatdata/<AppID> folder inside one of your Steam libraries.")
    else:
        if not any(real.startswith(b + os.sep) and real != b for b in heroic_prefix_bases()):
            raise Blocked("That prefix isn't inside Heroic's prefix folder, so it's left alone.")
        if heroic_prefix_users(root) > 1:
            raise Blocked("More than one Heroic game uses this prefix, so deleting it would break the others.")
    return True


def running_reason(store, gid, root, exe=None):
    """A reason the game or its prefix is in use right now, or None."""
    if exe and capture.game_running(exe):
        return f"{exe} is running. Quit the game first."
    if root and capture.wineserver_running(root):
        return "Wine is still running for this prefix. Quit the game and wait a moment."
    if store == "steam":
        for pid, c in capture._cmdlines():
            if "SteamLaunch" in c and re.search(rf"AppId={gid}(\s|$)", c):
                return "Steam is running this game. Quit it first."
    return None


def launcher_running(store):
    name = "steam" if store == "steam" else "heroic"
    return subprocess.run(["pgrep", "-x", name], capture_output=True).returncode == 0


def tree_size(path):
    if not path or not os.path.isdir(path):
        return 0
    try:
        r = subprocess.run(["du", "-sb", path], capture_output=True, text=True, timeout=30)
        return int(r.stdout.split()[0])
    except (OSError, ValueError, IndexError, subprocess.TimeoutExpired):
        return 0


def profile_info(store, gid):
    """The database entry for this store ID: (file id, exe) or (None, None)."""
    for g in dbio.list_games():
        if g.get(store) == gid:
            try:
                return g["id"], dbio.load(g["folder"], g["id"]).get("exe")
            except (OSError, ValueError):
                return g["id"], None
    return None, None


# ---------------------------------------------------------------- scanning

def _walk_manifests(base):
    found = []
    if not os.path.isdir(base):
        return found
    for dp, dns, fns in os.walk(base, followlinks=False):
        depth = dp[len(base):].count(os.sep)
        if depth >= MAX_DEPTH:
            dns[:] = []
        if MANIFEST in fns:
            found.append(os.path.join(dp, MANIFEST))
    return found


def _eid(*parts):
    return hashlib.sha1("|".join(map(str, parts)).encode()).hexdigest()[:12]


def find_entries():
    """Everything cleanable: installs of the script (live, left behind by a removed game, or
    emptied), plus prefixes of profiled games that have no install."""
    lib = capture.library()
    steam_by_dir = {os.path.realpath(g["dir"]): g for g in lib if g["store"] == "steam"}
    steam_by_id = {g["id"]: g for g in lib if g["store"] == "steam"}
    known_ids = set()
    for g in dbio.list_games():
        for st in ("steam", "gog"):
            if g.get(st):
                known_ids.add((st, g[st]))
    entries, used_roots = [], set()

    def add(e):
        e["prefix_size"] = None
        e["can_reset"] = False
        try:
            if e.get("prefix_root") and os.path.isdir(e["prefix_root"]):
                check_prefix_root(e["prefix_root"], e["store"])
                e["can_reset"] = True
        except Blocked as b:
            e["reset_blocked"] = str(b)
        if e.get("prefix_root"):
            used_roots.add(e["prefix_root"])
        entries.append(e)

    # --- manifests under every Steam library's common/ and Heroic's install folders
    steam_acf = {}
    for libdir in capture.steam_libs():
        for fn in os.listdir(libdir):
            m = re.match(r"appmanifest_(\d+)\.acf$", fn)
            if m:
                f = capture._vdf_fields(capture._rd(os.path.join(libdir, fn), "r", errors="replace"))
                steam_acf[(os.path.realpath(os.path.join(libdir, "common", f.get("installdir", "-"))))] = (int(m.group(1)), f.get("name", ""))
    for libdir in capture.steam_libs():
        common = os.path.join(libdir, "common")
        for mpath in _walk_manifests(common):
            gdir = os.path.dirname(mpath)
            top = os.path.join(common, os.path.relpath(gdir, common).split(os.sep)[0])
            acf = steam_acf.get(os.path.realpath(top))
            add(_manifest_entry(mpath, "steam", acf, steam_by_id))
    heroic_installed = []
    for r in heroic_roots():
        try:
            for g in json.loads(capture._rd(os.path.join(r, "gog_store", "installed.json")))["installed"]:
                heroic_installed.append(g)
        except (OSError, ValueError, KeyError):
            pass
    heroic_dirs = {os.path.realpath(g.get("install_path", "")): g for g in heroic_installed if g.get("install_path")}
    search = set(heroic_dirs) | {os.path.realpath(os.path.join(capture.HOME, "Games", "Heroic"))}
    seen = set()
    for base in sorted(search):
        for mpath in _walk_manifests(base):
            if mpath in seen or os.sep + "Prefixes" + os.sep in mpath:
                continue
            seen.add(mpath)
            gdir = os.path.realpath(os.path.dirname(mpath))
            owner = next((g for d, g in heroic_dirs.items() if gdir == d or gdir.startswith(d + os.sep)), None)
            add(_manifest_entry(mpath, "gog", owner, {}))

    # --- profiled games with a prefix but no manifest (clean install, or the install was removed)
    have_manifest = {(e["store"], e["id"]) for e in entries if e.get("id")}
    for g in lib:
        if (g["store"], g["id"]) in have_manifest or (g["store"], g["id"]) not in known_ids:
            continue
        if g.get("prefix_root") and os.path.isdir(g["prefix_root"]):
            add({"eid": _eid("lib", g["store"], g["id"]), "kind": "prefix", "store": g["store"], "id": g["id"], "name": g["name"],
                 "state": "clean", "dir": g["dir"], "files": [], "backups": 0, "prefix_root": g["prefix_root"], "installed": True})
    # --- prefixes of profiled Steam games that are gone from Steam
    for libdir in capture.steam_libs():
        cd = os.path.join(libdir, "compatdata")
        if not os.path.isdir(cd):
            continue
        for d in os.listdir(cd):
            root = os.path.join(cd, d)
            if d.isdigit() and ("steam", int(d)) in known_ids and int(d) not in steam_by_id and root not in used_roots and os.path.isdir(root):
                pid, _ = profile_info("steam", int(d))
                add({"eid": _eid("pfx", "steam", d), "kind": "prefix", "store": "steam", "id": int(d), "name": pid or f"AppID {d}",
                     "state": "gone", "dir": None, "files": [], "backups": 0, "prefix_root": root, "installed": False})
    entries.sort(key=lambda e: (e["name"].lower(), e["state"]))
    return entries


def _manifest_entry(mpath, store, owner, steam_by_id):
    gdir = os.path.dirname(mpath)
    mf = parse_manifest(mpath)
    files = [{"path": p, "exists": os.path.lexists(p)} for p in mf["files"]]
    backups = sum(len(glob.glob(glob.escape(p) + ".bak*")) for p in mf["files"])
    gid, name = None, os.path.basename(gdir) if os.path.basename(gdir).lower() != "system" else os.path.basename(os.path.dirname(gdir))
    root = next((prefix_root_of(p) for p in mf["files"] if prefix_root_of(p)), None)
    if store == "steam" and owner:
        gid, name = owner
        g = steam_by_id.get(gid)
        root = (g or {}).get("prefix_root") or root
    elif store == "gog" and owner:
        gid, name = owner.get("appName"), owner.get("title") or name
        try:
            gid = int(gid)
        except (TypeError, ValueError):
            pass
        for g in capture.heroic_games():
            if g["id"] == gid and g.get("prefix_root"):
                root = g["prefix_root"]
    elif store == "steam" and root:
        m = re.search(r"/compatdata/(\d+)", root)
        gid = int(m.group(1)) if m else None
    state = "removed" if mf["marker"] else ("installed" if owner else "orphan")
    return {"eid": _eid("m", mpath), "kind": "manifest", "store": store, "id": gid, "name": name or "Unknown game",
            "state": state, "dir": gdir, "manifest": mpath, "files": files, "backups": backups, "kinds": sorted(mf["kinds"]),
            "prefix_root": root, "installed": bool(owner)}


def get_entry(eid):
    for e in find_entries():
        if e["eid"] == eid:
            return e
    raise Blocked("That entry isn't there any more. Refresh the list.")


def describe(e):
    """The list row: what exists, cheaply (no prefix size)."""
    e = dict(e)
    e["files_present"] = sum(1 for f in e["files"] if f["exists"])
    e["prefix_exists"] = bool(e.get("prefix_root") and os.path.isdir(e["prefix_root"]))
    e["can_remove_install"] = e["state"] in ("installed", "orphan") and e.get("kind") == "manifest"
    return e


# ---------------------------------------------------------------- planning & removing an install

def _inside(path, base):
    return os.path.realpath(path).startswith(os.path.realpath(base) + os.sep)


def _safe_orphan_path(p, e):
    """A manifest path is only touched when it's inside the game folder or a prefix this tool may delete."""
    if _inside(p, e["dir"]):
        return True
    root = prefix_root_of(p)
    try:
        return bool(root) and _inside(p, root) and check_prefix_root(root, e["store"])
    except Blocked:
        return False


def plan_remove(e):
    if e["state"] not in ("installed", "orphan") or e.get("kind") != "manifest":
        raise Blocked("There's no install of the script to remove here.")
    plan = {"title": f"Remove the script's install from {e['name']}", "warnings": [], "items": []}
    exe = profile_info(e["store"], e["id"])[1] if e["id"] else None
    why = running_reason(e["store"], e["id"], e.get("prefix_root"), exe)
    if why:
        raise Blocked(why)
    if e["state"] == "installed":
        plan["items"].append("Runs the script's own uninstall for this game (files restored from their backups, registry and game settings put back).")
        if launcher_running(e["store"]):
            plan["warnings"].append(f"{'Steam' if e['store'] == 'steam' else 'Heroic'} is running, so its launch-option override is left in place (close it and run this again to remove that too).")
        elif "LAUNCHER" in e.get("kinds", []):
            plan["items"].append(f"Removes the DLL override from {'Steam' if e['store'] == 'steam' else 'Heroic'}'s launch options.")
    else:
        plan["warnings"].append("This game isn't in your library any more, so the tool removes the files itself rather than running the script.")
        if "LAUNCHER" in e.get("kinds", []):
            plan["warnings"].append("A launch-option override for this game stays in the launcher's settings; it's merged if you reinstall.")
    for f in e["files"]:
        if f["exists"]:
            ok = e["state"] == "installed" or _safe_orphan_path(f["path"], e)
            plan["items"].append(("Delete " if ok else "SKIP (outside the game and prefix folders) ") + capture_tilde(f["path"]))
    if e["backups"]:
        plan["items"].append(f"Puts back {e['backups']} backed-up original file(s).")
    if e["state"] == "orphan":
        plan["items"].append("Deletes the install record and the game folder if nothing else is in it.")
    return plan


def capture_tilde(p):
    return p.replace(capture.HOME, "~", 1) if p.startswith(capture.HOME) else p


def uninstall_answers(game_dir, store, remove_override):
    """Mirrors tests/integration/env.bash's uninstall answers, picking the game by typing its
    folder: the prefix lookup (three questions for Steam, two for Heroic), the file list, the
    launch-option override (the one answer that varies), then spares for the optional VC++ /
    game-settings prompts and "Proceed?". tests/integration/profiler-answers.bats fails if the
    script's prompts drift from this."""
    e = ""
    lookup = [e, e, e] if store == "steam" else [e, e]
    return ["u", "m", game_dir] + lookup + [e, e if remove_override else "n", e, e, e]


def remove_install(e, script, session_dir):
    plan_remove(e)  # raises Blocked
    if e["state"] == "installed":
        empty_db = os.path.join(session_dir, "empty-db.json")
        os.makedirs(session_dir, exist_ok=True)
        capture._wr(empty_db, '{"schema_version": 3, "games": []}')
        answers = os.path.join(session_dir, "uninstall-answers.txt")
        capture._wr(answers, "\n".join(uninstall_answers(e["dir"], e["store"], not launcher_running(e["store"]))) + "\n")
        env = dict(os.environ, EAX_RESTORE_SKIP_PREFLIGHT="1", EAX_RESTORE_SKIP_CACHE_CHECK="1",
                   EAX_RESTORE_GAME_DATABASE_FILE=empty_db, EAX_RESTORE_ANSWERS_FILE=answers)
        log = os.path.join(session_dir, "uninstall.log")
        with open(log, "w") as lf:
            r = subprocess.run([script], env=env, stdin=subprocess.DEVNULL, stdout=lf, stderr=subprocess.STDOUT, timeout=900)
        text = capture._rd(log, "r", errors="replace")
        if "UNINSTALL COMPLETE" not in text:
            raise RuntimeError("The script's uninstall didn't finish:\n" + text[-2500:])
        return ["Ran the script's uninstall for " + e["name"] + "."]
    msgs = []
    for f in e["files"]:
        p = f["path"]
        if not os.path.lexists(p):
            continue
        if not _safe_orphan_path(p, e):
            msgs.append("Skipped " + capture_tilde(p) + " (outside the game and prefix folders).")
            continue
        baks = sorted(glob.glob(glob.escape(p) + ".bak*"), key=os.path.getmtime)
        if os.path.isdir(p) and not os.path.islink(p):
            shutil.rmtree(p)
        else:
            os.remove(p)
        if baks:
            os.replace(baks[0], p)
            for extra in baks[1:]:
                os.remove(extra)
            msgs.append("Restored the original " + os.path.basename(p) + ".")
    os.remove(e["manifest"])
    d, stop = e["dir"], None
    for libdir in capture.steam_libs():
        if _inside(e["dir"], os.path.join(libdir, "common")):
            stop = os.path.join(libdir, "common")
    while d and stop and _inside(d, stop) and os.path.isdir(d) and not os.listdir(d):
        os.rmdir(d)
        msgs.append("Removed the empty folder " + capture_tilde(d) + ".")
        d = os.path.dirname(d)
    msgs.append("Removed what the script installed in " + e["name"] + ".")
    return msgs


# ---------------------------------------------------------------- prefix reset

def plan_reset_prefix(e):
    root = e.get("prefix_root")
    if not root or not os.path.isdir(root):
        raise Blocked("This game has no prefix on disk.")
    check_prefix_root(root, e["store"])
    exe = profile_info(e["store"], e["id"])[1] if e["id"] else None
    why = running_reason(e["store"], e["id"], root, exe)
    if why:
        raise Blocked(why)
    size = tree_size(root)
    return {"title": f"Delete {e['name']}'s Wine prefix", "size": size, "path": capture_tilde(root),
            "items": [f"Deletes {capture_tilde(root)} ({size / 1e6:.0f} MB).",
                      f"{'Steam' if e['store'] == 'steam' else 'Heroic'} creates a fresh one the next time the game is launched.",
                      "Game saves kept inside the prefix are lost. Saves and settings in the game's own folder are not touched."],
            "warnings": []}


def reset_prefix(e):
    plan_reset_prefix(e)  # raises Blocked
    root = e["prefix_root"]
    shutil.rmtree(root)
    msgs = [f"Deleted {capture_tilde(root)}."]
    mp = e.get("manifest")
    if mp and os.path.isfile(mp):
        mf = parse_manifest(mp)
        if not mf["marker"]:
            keep = []
            for ln in mf["text"].splitlines():
                if ln.startswith("#"):
                    keep.append(ln)
                elif re.match(r"^(VCRUN|REGISTRY:)", ln) or (ln.startswith("/") and _inside_str(ln.rstrip("\r"), root)):
                    continue
                else:
                    keep.append(ln)
            capture._wr(mp, "\n".join(keep) + "\n")
            msgs.append("Took the prefix's entries out of the install record.")
    return msgs


def _inside_str(path, base):
    return path == base or path.startswith(base.rstrip("/") + "/")


def reset_session(e):
    if e.get("id") is None:
        return []
    d = os.path.join(capture.STATE, f"{e['store']}-{e['id']}")
    if os.path.isdir(d):
        shutil.rmtree(d, ignore_errors=True)
        return ["Reset the capture session for " + e["name"] + "."]
    return []


if __name__ == "__main__":
    import sys
    if len(sys.argv) in (4, 5) and sys.argv[1] == "--print-answers":
        print("\n".join(uninstall_answers(sys.argv[3], sys.argv[2], len(sys.argv) < 5 or sys.argv[4] != "keep")))
