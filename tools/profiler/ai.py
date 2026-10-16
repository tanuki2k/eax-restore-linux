"""AI drafting. Uses the Anthropic API when ANTHROPIC_API_KEY is set, otherwise the
`claude` CLI's login (`claude -p`). Output is always a suggestion for the UI."""
import json, os, re, shutil, subprocess, urllib.error, urllib.request

MODEL = os.environ.get("PROFILER_MODEL", "claude-sonnet-5-5")

STYLE = (
    "You write entries for a community database of classic Windows games whose EAX/DirectSound3D "
    "audio is restored on Linux. Plain, short sentences, no marketing words. Never invent facts: "
    "if unsure, say so in the 'uncertain' field. Reply with ONLY a JSON object."
)

TASKS = {
    "description": 'Write {"description": "..."}: ONE sentence starting with the game\'s name, in '
                   "PCGamingWiki's pattern (\"X is a singleplayer first-person shooter game in the Y series.\"), "
                   "own words, no repeats of store details.",
    "notes": 'Write {"notes": "..."}: caveats not covered by other fields, or "" if none.',
    "research": 'Return {"released": "YYYY-MM-DD or YYYY-MM or YYYY", "exe": "Main.exe", "description": "...", '
                '"eax_versions": ["4.0"], "api": "directsound3d|openal", "uncertain": ["fields you are not sure of"]}. '
                "Do not return store IDs.",
    "setting": 'Given config file diffs, return {"title": "<=60 chars, Enable/Fix/Remove/Raise + result", '
               '"reason": "what the game does out of the box, one or two short sentences"}.',
    "classify": 'Given changed config keys captured while the player switched sound options, return '
                '{"changes": [{"i": <index given>, "keep": true|false, "reason": "<=12 words, why it is noise if keep is false"}]}. '
                "keep=false only for the game's own bookkeeping: timestamps, window positions, run counters, last-used values.",
    "suggest": 'From the game name and captured keys, return {"alsoft_ini": {"reverb": {"boost": "6"}, "general": {"sources": "256"}}, '
               '"eax": {"api": "directsound3d|openal", "versions": ["3.0"]}, "reasons": {"alsoft_ini.reverb.boost": "short reason"}}. '
               "Only include a value when the evidence supports it; omit everything else. Allowed alsoft_ini keys: reverb.boost (number), "
               "general.sources, general.frequency (digits), general.default-reverb, general.resampler.",
}


CONFIG = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
                      "eax-restore-linux", "profiler.json")
class AIError(Exception):
    """A problem to show the player as is."""


KEY_RE = re.compile(r"^sk-ant-[A-Za-z0-9_-]{20,}$")


def claude_path():
    """The claude command. An editor started from the app menu gets the desktop session's PATH,
    which often leaves out ~/.local/bin where Claude Code installs itself, so look there too."""
    found = shutil.which("claude")
    if found:
        return found
    home = os.path.expanduser("~")
    for rel in (".local/bin/claude", ".claude/local/claude", ".npm-global/bin/claude", ".bun/bin/claude", ".volta/bin/claude"):
        p = os.path.join(home, rel)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    for p in ("/usr/local/bin/claude", "/opt/homebrew/bin/claude"):
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


def _config():
    try:
        with open(CONFIG) as f:
            c = json.load(f)
        return c if isinstance(c, dict) else {}
    except (OSError, ValueError):
        return {}


def _write_config(c):
    """Owner-only (0600), in an owner-only folder: it can hold an API key."""
    os.makedirs(os.path.dirname(CONFIG), mode=0o700, exist_ok=True)
    if not c:
        try:
            os.remove(CONFIG)
        except OSError:
            pass
        return
    tmp = CONFIG + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(c, f)
    os.replace(tmp, CONFIG)


def api_key():
    """The key in use: ANTHROPIC_API_KEY when set, else the one saved from the editor."""
    return os.environ.get("ANTHROPIC_API_KEY") or _config().get("anthropic_api_key") or ""


def available():
    if api_key():
        return "api"
    return "cli" if claude_path() else None


def cli_status():
    """The claude command's own login state: installed, signed in, how."""
    claude = claude_path()
    if not claude:
        return {"installed": False, "logged_in": False}
    try:
        r = subprocess.run([claude, "auth", "status", "--json"], capture_output=True, text=True,
                           stdin=subprocess.DEVNULL, timeout=20)
        j = json.loads(r.stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return {"installed": True, "logged_in": False}
    return {"installed": True, "logged_in": bool(j.get("loggedIn")), "method": j.get("authMethod"), "email": j.get("email")}


_LOGIN = {"proc": None, "out": None}


def status():
    """Everything the AI settings dialog shows. The key itself is never returned, only its end."""
    saved = _config().get("anthropic_api_key") or ""
    proc = _LOGIN["proc"]
    running = bool(proc) and proc.poll() is None
    out = ""
    if _LOGIN["out"]:
        try:
            with open(_LOGIN["out"]) as f:
                out = f.read()[-600:]
        except OSError:
            pass
    return {"in_use": available(), "env_key": bool(os.environ.get("ANTHROPIC_API_KEY")),
            "saved_key": ("…" + saved[-4:]) if saved else None, "config": CONFIG.replace(os.path.expanduser("~"), "~", 1),
            "cli": cli_status(), "login": {"running": running, "output": out}}


def check_key(key):
    """(True, "") when Anthropic accepts the key, (False, why) when it rejects it, (None, why) when
    it couldn't be checked (no network)."""
    body = json.dumps({"model": MODEL, "max_tokens": 1, "messages": [{"role": "user", "content": "hi"}]}).encode()
    req = urllib.request.Request("https://api.anthropic.com/v1/messages", body, {
        "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30):
            return True, ""
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            return False, "Anthropic didn't accept that key."
        return None, f"Anthropic answered with an error ({e.code})."
    except (urllib.error.URLError, OSError):
        return None, "Couldn't reach Anthropic."


def save_key(key):
    key = (key or "").strip()
    if not KEY_RE.match(key):
        raise AIError("That doesn't look like an Anthropic API key (they start with sk-ant-).")
    ok, why = check_key(key)
    if ok is False:
        raise AIError(why)
    c = _config()
    c["anthropic_api_key"] = key
    _write_config(c)
    return {"checked": ok is True, "note": "" if ok else why.rstrip(".") + ", so the key was saved without being checked."}


def forget_key():
    c = _config()
    c.pop("anthropic_api_key", None)
    _write_config(c)


def cli_login():
    """Starts `claude auth login`, which opens the browser; the dialog polls status() until it ends."""
    claude = claude_path()
    if not claude:
        raise AIError("Claude Code wasn't found, so there's nothing to sign in to. Install it or use an API key instead.")
    if _LOGIN["proc"] and _LOGIN["proc"].poll() is None:
        return
    import tempfile
    fd, path = tempfile.mkstemp(prefix="eax-claude-login-")
    _LOGIN["out"] = path
    with os.fdopen(fd, "w") as out:
        _LOGIN["proc"] = subprocess.Popen([claude, "auth", "login"], stdin=subprocess.DEVNULL, stdout=out,
                                          stderr=subprocess.STDOUT, start_new_session=True)


def cli_logout():
    claude = claude_path()
    if claude:
        subprocess.run([claude, "auth", "logout"], capture_output=True, stdin=subprocess.DEVNULL, timeout=30)


def _call(prompt):
    mode = available()
    if mode == "api":
        key = api_key()
        body = json.dumps({"model": MODEL, "max_tokens": 2000, "system": STYLE,
                           "messages": [{"role": "user", "content": prompt}]}).encode()
        req = urllib.request.Request("https://api.anthropic.com/v1/messages", body, {
            "x-api-key": key, "anthropic-version": "2023-06-01",
            "content-type": "application/json"})
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.load(r)["content"][0]["text"]
    if mode == "cli":
        r = subprocess.run([claude_path(), "-p", "--model", "sonnet", STYLE + "\n\n" + prompt],
                           capture_output=True, text=True, timeout=180)
        if r.returncode:
            raise RuntimeError(r.stderr.strip()[:300])
        return r.stdout
    raise RuntimeError("No AI is available yet — add an API key or sign in with Claude in the AI settings.")


def ask(task, context):
    if task not in TASKS:
        raise ValueError("unknown task")
    text = _call(f"{TASKS[task]}\n\nContext (JSON):\n{json.dumps(context, indent=1)[:12000]}")
    a, b = text.find("{"), text.rfind("}")
    return json.loads(text[a:b + 1])


ALLOWED_ALSOFT = {"reverb": {"boost": r"^-?[0-9]+(\.[0-9]+)?$"}, "general": {
    "sources": r"^[0-9]+$", "frequency": r"^[0-9]+$", "default-reverb": r"^[A-Za-z0-9._ ()-]*$", "resampler": r"^[A-Za-z0-9._ ()-]*$"}}


def clean_suggestions(raw):
    """Keeps only what the schema allows, as strings; anything else is dropped."""
    import re
    out = {"alsoft_ini": {}, "eax": {}, "reasons": {}}
    if not isinstance(raw, dict):
        return out
    for sec, keys in (raw.get("alsoft_ini") or {}).items() if isinstance(raw.get("alsoft_ini"), dict) else []:
        for k, v in (keys.items() if isinstance(keys, dict) else []):
            pat = ALLOWED_ALSOFT.get(sec, {}).get(k)
            if pat and re.match(pat, str(v)):
                out["alsoft_ini"].setdefault(sec, {})[k] = str(v)
    eax = raw.get("eax") if isinstance(raw.get("eax"), dict) else {}
    if eax.get("api") in ("directsound3d", "openal"):
        out["eax"]["api"] = eax["api"]
    vers = [v for v in (eax.get("versions") or []) if v in ("1.0", "2.0", "3.0", "4.0", "5.0")] if isinstance(eax.get("versions"), list) else []
    if vers:
        out["eax"]["versions"] = sorted(set(vers))
    if isinstance(raw.get("reasons"), dict):
        out["reasons"] = {str(k): str(v)[:200] for k, v in raw["reasons"].items()}
    return out
