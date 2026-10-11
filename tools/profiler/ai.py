"""AI drafting. Uses the Anthropic API when ANTHROPIC_API_KEY is set, otherwise the
`claude` CLI's login (`claude -p`). Output is always a suggestion for the UI."""
import json, os, shutil, subprocess, urllib.request

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


def available():
    if os.environ.get("ANTHROPIC_API_KEY"):
        return "api"
    return "cli" if shutil.which("claude") else None


def _call(prompt):
    mode = available()
    if mode == "api":
        body = json.dumps({"model": MODEL, "max_tokens": 2000, "system": STYLE,
                           "messages": [{"role": "user", "content": prompt}]}).encode()
        req = urllib.request.Request("https://api.anthropic.com/v1/messages", body, {
            "x-api-key": os.environ["ANTHROPIC_API_KEY"], "anthropic-version": "2023-06-01",
            "content-type": "application/json"})
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.load(r)["content"][0]["text"]
    if mode == "cli":
        r = subprocess.run(["claude", "-p", "--model", "sonnet", STYLE + "\n\n" + prompt],
                           capture_output=True, text=True, timeout=180)
        if r.returncode:
            raise RuntimeError(r.stderr.strip()[:300])
        return r.stdout
    raise RuntimeError("No AI available: set ANTHROPIC_API_KEY or log in to the claude CLI")


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
