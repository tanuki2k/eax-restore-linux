"""Finds installed games, snapshots their config files and the prefix registry,
diffs snapshots, and drives the unattended install. No dependencies beyond the
standard library."""
import hashlib, json, os, re, shutil, subprocess, sys, time

HOME = os.path.expanduser("~")
STATE = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.join(HOME, ".local/state")),
                     "eax-restore-linux", "profiler")
CONFIG_RE = re.compile(r".*\.(cfg|ini|ltx|gdb|con)$", re.I)
# A .txt is only a config file when it reads as one: [Section] lines and
# key = value lines (TRON 2.0's Profiles/Player.txt), not a readme or licence.
TXT_SECTION_RE = re.compile(r"^\s*\[[^\]\r\n]+\]\s*$", re.M)
TXT_KEY_RE = re.compile(r"^\s*[^=\s\[;#][^=\r\n]*=", re.M)
NOISE_RE = re.compile(r"(^|/)(unins\d*\.|alsoft\.ini$|dxdiag|crash|log|cache|shadercache|"
                      r"openal|dsoal|drivers?\.ini$|goggame|galaxy)", re.I)
MAX_SNAPSHOT_BYTES = 4_000_000
MAX_DEPTH = 5
SPEAKER_LAYOUTS = ("headphones", "matrix", "quad", "surround51", "surround61", "surround71", "stereo")
VALUE_OK = re.compile(r"^[A-Za-z0-9._ ()-]*$")
NAME_OK = re.compile(r"^[A-Za-z0-9._ -]+$")
# Registry keys Wine, Windows components and launchers rewrite on their own.
REG_NOISE = re.compile(r"^Software\\\\(Wow6432Node\\\\)?(Microsoft|Wine|Valve|Classes|Policies|Khronos|"
                       r"GOG\.com|Epic|Microsoft)|^System\\\\|^Control Panel|^Volatile|^Environment|"
                       r"^Software\\\\Wow6432Node\\\\(Microsoft|Wine)", re.I)


def _rd(path, mode="rb", **kw):
    with open(path, mode, **kw) as f:
        return f.read()


def _wr(path, data):
    with open(path, "wb" if isinstance(data, bytes) else "w") as f:
        f.write(data)


# ---------------------------------------------------------------- library

def steam_roots():
    return [p for p in (HOME + "/.local/share/Steam", HOME + "/.steam/steam",
                        HOME + "/.var/app/com.valvesoftware.Steam/.local/share/Steam",
                        HOME + "/.var/app/com.valvesoftware.Steam/data/Steam") if os.path.isdir(p)]


def _vdf_fields(text):
    return dict(re.findall(r'"([^"]+)"\s+"([^"]*)"', text))


def steam_libs():
    """Every Steam library's steamapps folder (default library plus libraryfolders.vdf entries)."""
    libs, seen = [], set()
    for root in steam_roots():
        real = os.path.realpath(root)
        if real in seen:
            continue
        seen.add(real)
        libs.append(os.path.join(root, "steamapps"))
        try:
            vdf = _rd(os.path.join(root, "steamapps", "libraryfolders.vdf"), "r", errors="replace")
        except OSError:
            continue
        for p in re.findall(r'"path"\s+"([^"]+)"', vdf):
            libs.append(os.path.join(p, "steamapps"))
    out = []
    for lib in libs:
        if os.path.isdir(lib) and os.path.realpath(lib) not in [os.path.realpath(x) for x in out]:
            out.append(lib)
    return out


def steam_games():
    out, done = [], set()
    for lib in steam_libs():
        for fn in os.listdir(lib):
            m = re.match(r"appmanifest_(\d+)\.acf$", fn)
            if not m or (lib, m.group(1)) in done:
                continue
            done.add((lib, m.group(1)))
            f = _vdf_fields(_rd(os.path.join(lib, fn), "r", errors="replace"))
            gdir = os.path.join(lib, "common", f.get("installdir", ""))
            if f.get("installdir") and os.path.isdir(gdir) and not re.search(r"Proton|Steam Linux Runtime|Steamworks", f.get("name", "")):
                out.append({"store": "steam", "id": int(m.group(1)), "name": f.get("name", ""),
                            "dir": gdir, "prefix": os.path.join(lib, "compatdata", m.group(1), "pfx"),
                            "prefix_root": os.path.join(lib, "compatdata", m.group(1)), "lib": lib})
    return out


def heroic_games():
    out = []
    for root in (HOME + "/.config/heroic", HOME + "/.var/app/com.heroicgameslauncher.hgl/config/heroic"):
        try:
            inst = json.loads(_rd(os.path.join(root, "gog_store", "installed.json")))["installed"]
        except (OSError, ValueError, KeyError):
            continue
        for g in inst:
            app = g.get("appName")
            prefix = None
            try:
                prefix = json.loads(_rd(os.path.join(root, "GamesConfig", app + ".json")))[app].get("winePrefix")
            except (OSError, ValueError, KeyError):
                pass
            title = app
            try:
                for e in json.loads(_rd(os.path.join(root, "store_cache", "gog_library.json"))).get("games", []):
                    if e.get("app_name") == app:
                        title = e.get("title", app)
            except (OSError, ValueError):
                pass
            out.append({"store": "gog", "id": int(app) if str(app).isdigit() else app, "name": title,
                        "dir": g.get("install_path", ""), "prefix_root": prefix, "prefix": prefix and os.path.join(prefix, "pfx") if prefix and os.path.isdir(os.path.join(prefix, "pfx")) else prefix})
    return out


def library():
    return steam_games() + heroic_games()


# ---------------------------------------------------------------- snapshots

def _user_dirs(prefix):
    users = os.path.join(prefix, "drive_c", "users")
    out = []
    if os.path.isdir(users):
        for u in os.listdir(users):
            base = os.path.join(users, u)
            if u == "Public":
                out.append(("prefix_public_documents", os.path.join(base, "Documents")))
            else:
                out += [("prefix_documents", os.path.join(base, "Documents")),
                        ("prefix_appdata", os.path.join(base, "AppData", "Roaming")),
                        ("prefix_localappdata", os.path.join(base, "AppData", "Local")),
                        ("prefix_documents", os.path.join(base, "Saved Games"))]
    return out


def roots(game):
    r = [("game_exe", game["dir"])] + (_user_dirs(game["prefix"]) if game.get("prefix") else [])
    return [(b, p) for b, p in r if os.path.isdir(p)]


def location_of(game, abspath):
    """'base:relative/path' for a captured file, the form the database uses."""
    best = None
    for base, root in roots(game):
        if abspath.startswith(root + os.sep) and (best is None or len(root) > len(best[1])):
            best = (base, root)
    if best is None:
        return None
    return f"{best[0]}:{os.path.relpath(abspath, best[1])}"


def _is_config_txt(fn, data):
    return fn.lower().endswith(".txt") and bool(TXT_SECTION_RE.search(data.decode("utf-8", "replace"))
                                                 and TXT_KEY_RE.search(data.decode("utf-8", "replace")))


def snapshot(game, session_dir, label):
    """Copies every config-looking file, plus the registry files, into
    session_dir/<label>/ with an index.json mapping abs path -> sha256."""
    dest = os.path.join(session_dir, label)
    shutil.rmtree(dest, ignore_errors=True)
    os.makedirs(dest)
    index = {}
    for base, root in roots(game):
        for dp, dns, fns in os.walk(root, followlinks=False):
            if dp[len(root):].count(os.sep) >= MAX_DEPTH:
                dns[:] = []
            for fn in fns:
                p = os.path.join(dp, fn)
                is_txt = fn.lower().endswith(".txt")
                if not (CONFIG_RE.match(fn) or is_txt) or os.path.islink(p) or NOISE_RE.search(os.path.relpath(p, root)):
                    continue
                try:
                    if os.path.getsize(p) > MAX_SNAPSHOT_BYTES:
                        continue
                    data = _rd(p)
                except OSError:
                    continue
                if is_txt and not _is_config_txt(fn, data):
                    continue
                h = hashlib.sha256(data).hexdigest()
                index[p] = h
                _wr(os.path.join(dest, h), data)
    for reg in ("system.reg", "user.reg"):
        p = os.path.join(game.get("prefix") or "", reg)
        if os.path.isfile(p):
            data = _rd(p)
            h = hashlib.sha256(data).hexdigest()
            index[p] = h
            _wr(os.path.join(dest, h), data)
    _wr(os.path.join(dest, "index.json"), json.dumps({"time": time.time(), "files": index}))
    return len(index)


def snapshot_paths(session_dir, label):
    """The files a snapshot holds (absolute paths), without reading their contents."""
    return sorted(json.loads(_rd(os.path.join(session_dir, label, "index.json")))["files"])


def _load(session_dir, label):
    d = os.path.join(session_dir, label)
    idx = json.loads(_rd(os.path.join(d, "index.json")))["files"]
    return {p: _rd(os.path.join(d, h)) for p, h in idx.items()}


# ---------------------------------------------------------------- parsing

def guess_format(path, text):
    low = path.lower()
    if low.endswith(".reg"):
        return "wine_reg"
    if low.endswith(".gdb"):
        return "gadb"
    if re.search(r"^\s*seta?\s+\S+\s+\"", text, re.M):
        return "idtech_cfg"
    if re.search(r"^\s*\{[^}]+\}\s*=\s*\{", text, re.M):
        return "brace_cfg"
    if re.search(r"^\s*\[[^\]]+\]\s*$", text, re.M):
        return "ini"
    if low.endswith(".ini"):
        return "flat_ini"
    lines = [ln.strip() for ln in text.splitlines() if ln.strip() and not ln.strip().startswith(("//", "#", ";"))]
    eq = sum(1 for ln in lines if re.match(r"^[^=\s]+\s*=", ln))
    kv = sum(1 for ln in lines if re.match(r"^[A-Za-z_][\w.]*\s+\S", ln))
    if low.endswith((".cfg", ".con", ".ini")) and kv > eq and kv >= 3:
        return "dark_cfg"  # "Key Value" lines, e.g. Alpha Prime's settings.cfg
    if low.endswith(".ltx"):
        return "ltx"  # X-Ray's user.ltx: "key value" lines
    if low.endswith(".cfg") or low.endswith(".con"):
        return "dark_cfg" if re.search(r"^;?[A-Za-z_]\w*\s*$", text, re.M) and not eq else "flat_ini"
    return "flat_ini"


def parse_values(fmt, text):
    """-> {(section, key): value}. Section is '' for formats without sections."""
    out = {}
    if fmt == "ini":
        sec = ""
        for ln in text.splitlines():
            ln = ln.strip()
            m = re.match(r"^\[(.+)\]$", ln)
            if m:
                sec = m.group(1).strip()
            elif "=" in ln and not ln.startswith((";", "#")):
                k, v = ln.split("=", 1)
                out[(sec, k.strip())] = v.strip()
    elif fmt == "flat_ini":
        for ln in text.splitlines():
            if "=" in ln and not ln.strip().startswith((";", "#", "//")):
                k, v = ln.split("=", 1)
                out[("", k.strip())] = v.strip()
    elif fmt == "idtech_cfg":
        for m in re.finditer(r'^\s*(?:seta|set|setu|sets)\s+(\S+)\s+"?([^"\r\n]*)"?\s*$', text, re.M):
            out[("", m.group(1))] = m.group(2)
    elif fmt == "brace_cfg":
        for m in re.finditer(r"^\s*\{([^}]*)\}\s*=\s*\{([^}]*)\}", text, re.M):
            out[("", m.group(1).strip())] = m.group(2).strip()
    elif fmt == "ltx":
        for ln in text.splitlines():
            m = re.match(r"^\s*([A-Za-z_][\w.]*)(?:\s+(.*?))?\s*$", ln)
            if m:
                out[("", m.group(1))] = m.group(2) or ""
    elif fmt == "dark_cfg":
        for ln in text.splitlines():
            ln = ln.strip()
            m = re.match(r"^(;?)([A-Za-z_][\w.]*)(?:\s+(.*))?$", ln)
            if m:
                off, k, v = m.groups()
                out[("", k)] = (v.strip() if v else ("false" if off else "true"))
    elif fmt == "wine_reg":
        out = parse_reg(text)
    return out


def parse_reg(text):
    out, sec = {}, None
    for ln in text.splitlines():
        m = re.match(r"^\[(.+?)\](?: \d+)?$", ln)
        if m:
            sec = m.group(1)
            continue
        if sec is None:
            continue
        m = re.match(r'^"((?:[^"\\]|\\.)*)"=(dword:([0-9a-fA-F]{8})|"((?:[^"\\]|\\.)*)")$', ln)
        if m:
            name = m.group(1)
            out[(sec, name)] = str(int(m.group(3), 16)) if m.group(3) else m.group(4)
    return out


def _u32(b, i):
    return b[i] | b[i + 1] << 8 | b[i + 2] << 16 | b[i + 3] << 24


def parse_gadb(data):
    """name -> "0"/"1"/... for every setting that has exactly one on/off record, read the way
    the script's _gadb_find does (src/game-config.sh): a "GADB" header, the string table's size
    at byte 8, NUL-separated names from byte 28, then 4-byte-aligned little-endian records of
    [name offset, 1, 0, 1, value]. None when the data isn't a GADB file."""
    n = len(data)
    if n < 28 or data[:4] != b"GADB":
        return None
    end = 28 + _u32(data, 8)
    if end > n:
        return None
    first, start = {}, 28  # lower-cased name -> (offset, name as written); first spelling wins
    for i in range(28, end):
        if data[i] == 0:
            s = data[start:i].decode("latin-1")
            first.setdefault(s.lower(), (start - 28, s))
            start = i + 1
    by_off = {off: (low, s) for low, (off, s) in first.items()}
    hits = {}
    i = end + (4 - end % 4) % 4
    while i + 20 <= n:
        off = _u32(data, i)
        if off in by_off and _u32(data, i + 4) == 1 and _u32(data, i + 8) == 0 and _u32(data, i + 12) == 1:
            hits.setdefault(by_off[off][0], []).append(_u32(data, i + 16))
        i += 4
    return {by_off[first[low][0]][1]: str(v[0]) for low, v in hits.items() if len(v) == 1}


def diff_snapshots(game, session_dir, a, b, ignore=()):
    """Per changed file: location, guessed format, and the changed values."""
    A, B = _load(session_dir, a), _load(session_dir, b)
    result = []
    for p in sorted(set(A) | set(B)):
        if A.get(p) == B.get(p):
            continue
        is_reg = p.endswith(".reg")
        fmt_text = (B.get(p) or A.get(p) or b"").decode("utf-8", "replace")
        fmt = guess_format(p, fmt_text)
        entry = {"path": p, "file": os.path.basename(p), "format": fmt,
                 "location": ("prefix:" + os.path.basename(p)) if is_reg else location_of(game, p),
                 "created": p not in A, "changes": []}
        if fmt == "gadb":
            ga, gb = parse_gadb(A.get(p, b"")), parse_gadb(B.get(p, b""))
            if ga is None and p not in A:
                ga = {}
            if ga is not None and gb is not None:
                for key in sorted(set(ga) | set(gb)):
                    if ga.get(key) != gb.get(key) and (entry["file"], "", key) not in ignore:
                        entry["changes"].append({"section": "", "key": key, "old": ga.get(key), "new": gb.get(key),
                                                 "expressible": gb.get(key) in ("0", "1") and bool(NAME_OK.match(key))})
                if entry["changes"]:
                    result.append(entry)
                continue
            old, new = A.get(p, b""), B.get(p, b"")  # not readable as a GADB file: report where it changed
            entry["binary_offsets"] = [i for i in range(min(len(old), len(new))) if old[i] != new[i]][:64]
            result.append(entry)
            continue
        va = parse_values(fmt, (A.get(p) or b"").decode("utf-8", "replace"))
        vb = parse_values(fmt, fmt_text)
        for k in sorted(set(va) | set(vb)):
            if va.get(k) == vb.get(k):
                continue
            sec, key = k
            if is_reg and REG_NOISE.match(sec):
                continue
            if (entry["file"], sec, key) in ignore:
                continue
            entry["changes"].append({"section": sec.replace("\\\\", "\\") if is_reg else sec, "key": key,
                                     "old": va.get(k), "new": vb.get(k),
                                     "expressible": bool(VALUE_OK.match(vb.get(k) or "")) and bool(NAME_OK.match(key) or is_reg)})
        if entry["changes"]:
            result.append(entry)
        elif not is_reg:
            entry["unparsed"] = True  # the file changed but no keys could be read from it
            result.append(entry)
    return result


# ---------------------------------------------------------------- process control

def _cmdlines():
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            yield int(pid), _rd(f"/proc/{pid}/cmdline").replace(b"\0", b" ").decode("utf-8", "replace")
        except OSError:
            continue


def game_running(exe):
    return bool(exe) and any(exe.lower() in c.lower() for pid, c in _cmdlines() if pid != os.getpid())


def wineserver_running(prefix):
    for pid, c in _cmdlines():
        if "wineserver" in c:
            try:
                env = _rd(f"/proc/{pid}/environ").split(b"\0")
            except OSError:
                continue
            if any(e.startswith(b"WINEPREFIX=") and prefix.encode().rstrip(b"/") in e for e in env):
                return True
    return False


def stop_game(exe):
    """Asks the game's processes (matched by exe name) to quit."""
    for pid, c in _cmdlines():
        if pid != os.getpid() and exe.lower() in c.lower() and "profiler" not in c:
            try:
                os.kill(pid, 15)
            except OSError:
                pass


def launch(game):
    if game["store"] == "steam":
        cmd = ["xdg-open", f"steam://rungameid/{game['id']}"]
    else:
        cmd = ["xdg-open", f"heroic://launch?appName={game['id']}&runner=gog"]
    subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# ---------------------------------------------------------------- unattended install

# Mirrors tests/integration/env.bash install_answers / heroic_install_answers; a bats
# test (tests/integration/profiler-answers.bats) fails when the script's prompts drift.
def install_answers(game_dir, store):
    registry_route = "2"  # leaves the launcher (and so a running Steam/Heroic) alone
    e = ""
    if store == "steam":
        lines = ["m", e, game_dir, e, e, e, e, e, e, e, e, e, e, "n", e, e, e, e, registry_route, e, e]
    else:
        lines = ["m", e, game_dir, e, e, e, e, e, e, e, e, e, "n", e, e, e, e, e, e, e]
    return lines


def find_exe_dir(root, exe):
    """The folder under root holding exe (shallowest first, any letter case); root
    when it isn't found. Many games keep their exe in bin/, not the install root."""
    want = (exe or "").lower()
    if not want or not os.path.isdir(root):
        return root
    best = None
    for d, _, files in os.walk(root):
        if want in (f.lower() for f in files):
            depth = os.path.relpath(d, root).count(os.sep)
            if best is None or depth < best[0]:
                best = (depth, d)
    return best[1] if best else root


def profile_db(game, profile):
    """A database with just this game: its exe, API and extra exe folders, and none
    of its Game Settings (the capture needs the config files untouched). None when
    the profile doesn't name an exe or an API, so the script has nothing to go by."""
    if not profile or not profile.get("exe") or not profile.get("api"):
        return None
    store = {"id": game["id"]}
    if profile.get("extra_exe_folders"):
        store["extra_exe_folders"] = profile["extra_exe_folders"]
    eax = {"api": profile["api"], "versions": profile.get("versions") or ["2.0"]}
    entry = {"id": "capture", "name": profile.get("name") or "capture", "exe": profile["exe"],
             "stores": {game["store"]: store}, "eax": eax}
    return json.dumps({"schema_version": 3, "games": [entry]})


def run_install(game, session_dir, script, profile=None):
    """Runs the built script with canned answers and a database that holds no Game
    Settings: empty, or just this game's exe and API when the profile has them."""
    db = os.path.join(session_dir, "capture-db.json")
    text = profile_db(game, profile)
    _wr(db, text or '{"schema_version": 3, "games": []}')
    exe_dir = find_exe_dir(game["dir"], profile.get("exe") if profile else "")
    answers = os.path.join(session_dir, "answers.txt")
    _wr(answers, "\n".join(install_answers(exe_dir, game["store"])) + "\n")
    env = dict(os.environ, EAX_RESTORE_SKIP_PREFLIGHT="1", EAX_RESTORE_DSOAL_PIN="1",
               EAX_RESTORE_GAME_DATABASE_FILE=db, EAX_RESTORE_ANSWERS_FILE=answers)
    log = os.path.join(session_dir, "install.log")
    with open(log, "w") as lf:
        r = subprocess.run([script], env=env, stdin=subprocess.DEVNULL, stdout=lf, stderr=subprocess.STDOUT, timeout=900)
    text = _rd(log, "r", errors="replace")
    return {"ok": "INSTALLATION COMPLETE" in text, "returncode": r.returncode, "tail": text[-3000:]}


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--print-answers":
        print("\n".join(install_answers(sys.argv[3], sys.argv[2])))
    else:
        print(json.dumps(library(), indent=1))
