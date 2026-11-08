"""Reads, validates and writes the game database files (data/games/*, data/drafts)."""
import json, os, subprocess, shutil, re

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FOLDERS = {
    "tested": "data/games/tested",
    "untested": "data/games/untested",
    "drafts": "data/drafts",
}
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*\Z")  # \Z, not $: "abc\n" is not an id


def _path(folder, gid):
    if folder not in FOLDERS or not ID_RE.match(gid):
        raise ValueError("bad folder or id")
    return os.path.join(ROOT, FOLDERS[folder], gid + ".json")


def schema():
    with open(os.path.join(ROOT, "data", "schema.json")) as f:
        return json.load(f)


def built_entries():
    """id -> entry in the built game-database.json, or {} when it doesn't exist yet."""
    try:
        with open(os.path.join(ROOT, "game-database.json")) as f:
            return {g["id"]: g for g in json.load(f).get("games", [])}
    except (OSError, ValueError, KeyError):
        return {}


def build_state(folder, gid, game, built):
    """How a game file stands against game-database.json, mirroring what
    tools/build-game-database.sh puts there ({id} + the file minus $schema,
    plus tested: false for a game in untested/):
    current, changed (with the top-level fields that differ), new (not built yet),
    or draft (drafts are never built)."""
    if folder == "drafts":
        return {"state": "draft", "fields": []}
    want = {"id": gid, **{k: v for k, v in game.items() if k != "$schema"}}
    if folder == "untested":
        want["tested"] = False  # the build marks these; the browser filters on it
    have = built.get(gid)
    if have is None:
        return {"state": "new", "fields": []}
    if have == want:
        return {"state": "current", "fields": []}
    return {"state": "changed", "fields": sorted(k for k in set(want) | set(have) if want.get(k) != have.get(k))}


def setting_counts(g):
    """How many game settings an entry has and how many still need verifying, for the list filter.
    alsoft.ini values are verified as one, so unverified ones count as one more."""
    gc, inst = g.get("game_config") or {}, g.get("install") or {}
    settings = gc.get("audio_settings", []) + gc.get("optional_settings", [])
    return {"settings": len(settings),
            "unverified": sum(not s.get("tested") for s in settings)
                          + bool(inst.get("alsoft_ini") and not inst.get("alsoft_tested"))}


def list_games():
    out, built, seen = [], built_entries(), set()
    for folder, rel in FOLDERS.items():
        d = os.path.join(ROOT, rel)
        for fn in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            if fn.endswith(".json"):
                try:
                    with open(os.path.join(d, fn)) as f:
                        g = json.load(f)
                except ValueError:
                    g = {}
                stores = g.get("stores", {})
                if folder != "drafts":
                    seen.add(fn[:-5])
                out.append({
                    "id": fn[:-5], "folder": folder, "name": g.get("name", fn[:-5]),
                    "steam": stores.get("steam", {}).get("id"),
                    "gog": stores.get("gog", {}).get("id"),
                    "has_config": bool(g.get("game_config")),
                    **setting_counts(g),
                    "build": build_state(folder, fn[:-5], g, built),
                })
    return out


def stale_entries():
    """Built entries whose source file is gone (or moved to drafts): the next build drops them."""
    have = set()
    for folder in ("tested", "untested"):
        d = os.path.join(ROOT, FOLDERS[folder])
        have |= {fn[:-5] for fn in os.listdir(d) if fn.endswith(".json")} if os.path.isdir(d) else set()
    return sorted(i for i in built_entries() if i not in have)


def load(folder, gid):
    with open(_path(folder, gid)) as f:
        return json.load(f)


def referenced_files_errors(game):
    """The one rule the schema can't express (also checked by build-game-database.sh)."""
    gc = game.get("game_config") or {}
    files = set((gc.get("files") or {}).keys())
    errs = []
    for kind in ("audio_settings", "optional_settings"):
        for i, s in enumerate(gc.get(kind) or []):
            for fn in (s.get("changes") or {}):
                if fn not in files:
                    errs.append(f"game_config.{kind}[{i}].changes: '{fn}' is not defined in game_config.files")
    return errs


def validate(game):
    import jsonschema
    v = jsonschema.Draft202012Validator(schema())
    errs = []
    for e in sorted(v.iter_errors(game), key=lambda e: list(e.absolute_path)):
        loc = "/".join(str(p) for p in e.absolute_path) or "(root)"
        errs.append(f"{loc}: {e.message[:200]}")
    return errs + referenced_files_errors(game)


def _format_all():
    r = subprocess.run([os.path.join(ROOT, "tools", "format-game-database.sh")],
                       capture_output=True, text=True, cwd=ROOT)
    return r.returncode == 0, r.stderr


def save(folder, gid, game):
    """Writes the game in canonical form. Invalid games are still saved (a draft
    in progress), with the errors returned."""
    p = _path(folder, gid)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    game = dict(game)
    game.pop("id", None)
    with open(p, "w") as f:
        json.dump(game, f, indent=2, ensure_ascii=False)
        f.write("\n")
    ok, err = _format_all()
    with open(p) as f:
        text = f.read()
    return {"errors": validate(json.loads(text)), "format_ok": ok, "format_error": err, "json": text}


def canonical(folder, game):
    """The game in the formatter's canonical form, without writing anything."""
    schema_ref = "../schema.json" if folder == "drafts" else "../../schema.json"
    g = dict(game); g.pop("id", None); g["$schema"] = schema_ref
    r = subprocess.run(["jq", "-r", "-L", os.path.join(ROOT, "tools"), "--arg", "schema", schema_ref,
                        'include "game-database"; .["$schema"] = $schema | normalize_game | render_game'],
                       input=json.dumps(g), capture_output=True, text=True, cwd=ROOT)
    if r.returncode:
        raise ValueError("jq failed: " + r.stderr[:300])
    return r.stdout if r.stdout.endswith("\n") else r.stdout + "\n"


def preview(folder, gid, game):
    """Unified diff of what Save would change on disk."""
    import difflib
    p = _path(folder, gid)
    old = ""
    if os.path.exists(p):
        with open(p) as f:
            old = f.read()
    new = canonical(folder, game)
    diff = "".join(difflib.unified_diff(old.splitlines(True), new.splitlines(True),
                                        f"{FOLDERS[folder]}/{gid}.json (on disk)", f"{FOLDERS[folder]}/{gid}.json (new)", n=2))
    return {"diff": diff, "same": old == new, "new_file": not os.path.exists(p)}


def rebuild():
    r = subprocess.run([os.path.join(ROOT, "tools", "build-game-database.sh")],
                       capture_output=True, text=True, cwd=ROOT)
    return r.returncode == 0, (r.stderr or r.stdout)


def promote(gid, src, dst):
    a, b = _path(src, gid), _path(dst, gid)
    if os.path.exists(b):
        raise ValueError(f"{gid} already exists in {dst}")
    os.makedirs(os.path.dirname(b), exist_ok=True)
    # git mv only knows tracked files; a profile just made with "+ Add game" is not one yet.
    tracked = shutil.which("git") and subprocess.run(["git", "ls-files", "--error-unmatch", a], cwd=ROOT,
                                                       capture_output=True).returncode == 0
    subprocess.run(["git", "mv", a, b], cwd=ROOT, check=True) if tracked else os.rename(a, b)
    _format_all()


def new_stub(gid, name, store=None, store_id=None):
    """An empty untested entry. With a store and ID (seen on a local install) the
    entry gets that store, marked local_install_verified until a human checks it."""
    if any(os.path.exists(_path(f, gid)) for f in FOLDERS):
        if not store_id:
            raise ValueError(f"{gid} already exists")
        gid = f"{gid}-{store_id}"
        if any(os.path.exists(_path(f, gid)) for f in FOLDERS):
            raise ValueError(f"{gid} already exists")
    stores = {}
    if store in ("steam", "gog") and store_id:
        stores[store] = {"id": int(store_id), "id_source": "local_install_verified"}
    r = save("untested", gid, {"name": name, "stores": stores, "eax": {"api": "directsound3d"}})
    r["id"] = gid
    return r
