"""Reads, validates and writes the game database files (data/games/*, data/drafts)."""
import json, os, subprocess, shutil, re

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FOLDERS = {
    "games": "data/games",
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


def built_forms(games):
    """id -> the entry tools/build-game-database.sh would build from each game file,
    by the build's own jq (built_entry), in one run for the whole list."""
    if not games:
        return {}
    r = subprocess.run(["jq", "-c", "-L", os.path.join(ROOT, "tools"),
                        'include "game-database"; with_entries(.key as $id | .value |= built_entry($id))'],
                       input=json.dumps(games), capture_output=True, text=True, cwd=ROOT)
    if r.returncode:
        return {}
    return json.loads(r.stdout)


def build_state(folder, gid, game, built, want=None):
    """How a game file stands against game-database.json: current, changed (with the
    top-level fields that differ), new (not built yet), or draft (drafts are never
    built). want is the entry the build makes from the file (built_forms), worked out
    here when the caller hasn't already."""
    if folder == "drafts":
        return {"state": "draft", "fields": []}
    if want is None:
        want = built_forms({gid: game}).get(gid)
    if want is None:
        return {"state": "changed", "fields": []}
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
            "unverified": sum(not s.get("verified") for s in settings)
                          + bool(inst.get("alsoft_ini") and not inst.get("alsoft_verified"))}


def list_games():
    out, built, files = [], built_entries(), []
    for folder, rel in FOLDERS.items():
        d = os.path.join(ROOT, rel)
        for fn in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            if fn.endswith(".json"):
                try:
                    with open(os.path.join(d, fn)) as f:
                        g = json.load(f)
                except ValueError:
                    g = {}
                files.append((folder, fn[:-5], g if isinstance(g, dict) else {}))
    wants = built_forms({gid: g for folder, gid, g in files if folder == "games" and g.get("stores")})
    for folder, gid, g in files:
        stores = g.get("stores", {})
        out.append({
            "id": gid, "folder": folder, "name": g.get("name", gid),
            "compatibility": g.get("compatibility", "unknown"),
            "steam": stores.get("steam", {}).get("id"),
            "gog": stores.get("gog", {}).get("id"),
            "has_config": bool(g.get("game_config")),
            **setting_counts(g),
            "build": build_state(folder, gid, g, built, wants.get(gid)),
        })
    return out


def stale_entries():
    """Built entries whose source file is gone (or moved to drafts): the next build drops them."""
    have = set()
    d = os.path.join(ROOT, FOLDERS["games"])
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
    schema_ref = "../schema.json"
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
    """An empty entry in data/games/ with no compatibility (unknown). With a store and ID (seen on a local install) the
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
    r = save("games", gid, {"name": name, "stores": stores, "eax": {"api": "directsound3d"}})
    r["id"] = gid
    return r
