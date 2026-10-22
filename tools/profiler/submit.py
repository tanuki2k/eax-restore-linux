"""Sends a game profile to the project's repo as a pull request (with the GitHub CLI) or
as a pre-filled GitHub page (without it).

Nothing here touches the local clone's git state: the pull request is made on the player's
fork through GitHub's API, from the saved profile. Captured snapshots (the player's config
files and registry) never leave the machine; only the one game file does."""
import base64, getpass, json, os, re, shutil, subprocess, time
from urllib.parse import quote

import dbio

UPSTREAM = os.environ.get("EAX_PROFILER_UPSTREAM", "tanuki2k/eax-restore-linux")
BASE = os.environ.get("EAX_PROFILER_BASE", "dev")  # until dev becomes main
URL_LIMIT = 7000  # GitHub's new-file page takes the content in the address; longer ones get cut off
LONG_NUMBER = re.compile(r"\d{9,}")


class SubmitError(Exception):
    pass


# ---------------------------------------------------------------- checks

def _strings(node, path=""):
    if isinstance(node, str):
        yield path or "(root)", node
    elif isinstance(node, dict):
        for k, v in node.items():
            yield from _strings(k, f"{path}/{k} (key)")
            yield from _strings(v, f"{path}/{k}")
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from _strings(v, f"{path}/{i}")


def privacy_findings(game, home=None, user=None):
    """Values that look like they came from the contributor's own machine: their home
    folder or user name, a /home/ path, or a long number (a key or an account ID).
    Store IDs are numbers, not strings, so they never match."""
    home = home or os.path.expanduser("~")
    user = user or getpass.getuser()
    out = []
    for where, text in _strings(game):
        why = None
        if home and home != "/" and home in text:
            why = "contains your home folder"
        elif "/home/" in text or re.search(r"[A-Za-z]:\\Users\\", text):
            why = "contains a path to someone's home folder"
        elif user and len(user) > 2 and re.search(r"(?<![A-Za-z0-9])" + re.escape(user) + r"(?![A-Za-z0-9])", text):
            why = "contains your user name"
        elif LONG_NUMBER.search(text):
            why = "contains a long number (a key or an account ID?)"
        if why:
            out.append({"where": where, "value": text[:120], "why": why})
    return out


# ---------------------------------------------------------------- the GitHub CLI

def _run_gh(args, stdin=None):
    # Without input, gh gets no stdin at all, so it can never sit waiting for a prompt.
    try:
        return subprocess.run(["gh", *args], input=stdin, stdin=None if stdin is not None else subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        raise SubmitError("GitHub didn't answer in time. Check the connection and try again.")


def _gh(args, stdin=None, check=True):
    r = _run_gh(args, stdin)
    if check and r.returncode:
        raise SubmitError((r.stderr or r.stdout).strip()[:400] or f"gh {args[0]} failed")
    return r.stdout


def gh_login():
    """The GitHub user the CLI is logged in as, or None when it isn't installed or logged in."""
    if not shutil.which("gh"):
        return None
    r = _run_gh(["api", "user", "--jq", ".login"])
    return r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else None


def _api_json(path, method="GET", body=None):
    args = ["api", "-X", method, path]
    if body is not None:
        args += ["--input", "-"]
    out = _gh(args, stdin=json.dumps(body) if body is not None else None)
    return json.loads(out) if out.strip() else {}


def _exists_upstream(path):
    r = _run_gh(["api", f"repos/{UPSTREAM}/contents/{path}?ref={BASE}", "--jq", ".sha"])
    if r.returncode == 0:
        return r.stdout.strip()
    # Only a 404 means "not there"; a rate limit or a dropped connection must not
    # send an existing tested profile to untested/ as a second copy.
    if "404" in (r.stderr or "") or "Not Found" in (r.stderr or ""):
        return None
    raise SubmitError("Couldn't check GitHub for an existing profile. Try again in a moment.")


def target_folder(gid):
    """Where the profile belongs upstream: the folder it's already in (a fix to a game that's
    there), else untested/ — a maintainer promotes it after checking it."""
    for folder in ("tested", "untested"):
        if _exists_upstream(f"{dbio.FOLDERS[folder]}/{gid}.json"):
            return folder
    return "untested"


# ---------------------------------------------------------------- what gets sent

def database_entry(gid, text, folder):
    """The built game-database.json entry for this file, by the build tool's own jq."""
    r = subprocess.run(["jq", "-c", "-L", os.path.join(dbio.ROOT, "tools"), "--arg", "id", gid,
                        "--argjson", "untested", "true" if folder == "untested" else "false",
                        'include "game-database"; built_entry($id; $untested)'],
                       input=text, capture_output=True, text=True)
    if r.returncode:
        raise SubmitError("jq failed: " + r.stderr[:300])
    return r.stdout.strip()


def splice_database(db_text, entry_json):
    """The built database with the entry added or replaced, byte for byte what
    tools/build-game-database.sh writes when upstream's own copy is current."""
    r = subprocess.run(["jq", "-L", os.path.join(dbio.ROOT, "tools"), "--argjson", "entry", entry_json,
                        'include "game-database"; splice_entry($entry)'],
                       input=db_text, capture_output=True, text=True)
    if r.returncode:
        raise SubmitError("jq failed: " + r.stderr[:300])
    return r.stdout


def pr_body(game, gid, store_ids, note, checked_install, checked_ids, replaced):
    lines = [f"{'Updates' if replaced else 'Adds'} the profile for **{game.get('name', gid)}**"
             f" (`{gid}`), sent from the profile editor.", ""]
    if store_ids:
        lines += ["Store IDs: " + ", ".join(store_ids), ""]
    if note.strip():
        lines += [note.strip(), ""]
    lines += [f"- [{'x' if checked_install else ' '}] Checked on my own install",
              f"- [{'x' if checked_ids else ' '}] Store IDs checked on the store's page", "",
              "It goes in `data/games/untested/`, unverified, until someone has tried it on a real install."
              if not replaced else "It keeps the folder it's already in."]
    return "\n".join(lines) + "\n"


def _store_ids(game):
    return [f"{k} {v.get('id')}" for k, v in (game.get("stores") or {}).items() if isinstance(v, dict) and v.get("id")]


# ---------------------------------------------------------------- the two routes

def prepare(folder, gid, game):
    """What the Submit dialog shows before anything is sent."""
    errors = dbio.validate(game)
    if "TODO" in json.dumps(game.get("game_config") or {}):
        errors.append("A setting still has a TODO title or reason. Write them before sending.")
    if not _store_ids(game):
        errors.append("Add at least one store with its ID, so the profile can be matched to a game.")
    login = gh_login()
    return {"errors": errors, "findings": privacy_findings(game), "gh_user": login,
            "upstream": UPSTREAM, "base": BASE,
            "path": f"{dbio.FOLDERS['untested']}/{gid}.json", "name": game.get("name", gid)}


def _commit_file(fork, branch, path, content, message):
    sha = None
    r = _run_gh(["api", f"repos/{fork}/contents/{path}?ref={branch}", "--jq", ".sha"])
    if r.returncode == 0 and r.stdout.strip():
        sha = r.stdout.strip()
    body = {"message": message, "branch": branch, "content": base64.b64encode(content.encode()).decode()}
    if sha:
        body["sha"] = sha
    _api_json(f"repos/{fork}/contents/{path}", "PUT", body)


def submit_with_gh(gid, game, note, checked_install, checked_ids):
    login = gh_login()
    if not login:
        raise SubmitError("The GitHub CLI isn't installed or isn't logged in, so use the browser instead.")
    folder = target_folder(gid)
    text = dbio.canonical(folder, game)
    path = f"{dbio.FOLDERS[folder]}/{gid}.json"
    replaced = folder == "tested" or _exists_upstream(path) is not None

    name = UPSTREAM.split("/")[1]
    _gh(["repo", "fork", UPSTREAM, "--clone=false"], check=False)  # fine when the fork already exists
    fork = f"{login}/{name}"
    for attempt in range(8):  # a fork made just now takes a moment to exist
        try:
            _api_json(f"repos/{fork}")
            break
        except Exception:  # noqa: BLE001 - retried, then raised below
            if attempt == 7:
                raise
            time.sleep(1.5)
    head = _gh(["api", f"repos/{UPSTREAM}/git/ref/heads/{BASE}", "--jq", ".object.sha"]).strip()
    branch = f"profile/{gid}-{time.strftime('%Y%m%d%H%M%S')}"
    _api_json(f"repos/{fork}/git/refs", "POST", {"ref": f"refs/heads/{branch}", "sha": head})

    title = f"{'Update' if replaced else 'Add'} {game.get('name', gid)}"
    _commit_file(fork, branch, path, text, title)
    db_raw = _gh(["api", "-H", "Accept: application/vnd.github.raw", f"repos/{UPSTREAM}/contents/game-database.json?ref={BASE}"])
    _commit_file(fork, branch, "game-database.json", splice_database(db_raw, database_entry(gid, text, folder)),
                 f"Rebuild game-database.json for {game.get('name', gid)}")

    body = pr_body(game, gid, _store_ids(game), note, checked_install, checked_ids, replaced)
    url = _gh(["pr", "create", "--repo", UPSTREAM, "--base", BASE, "--head", f"{login}:{branch}",
               "--title", title, "--body-file", "-"], stdin=body).strip().splitlines()[-1]
    return {"mode": "gh", "url": url}


def submit_with_browser(gid, game):
    """GitHub's new-file page with the profile filled in. A maintainer rebuilds game-database.json
    when merging, since a page in the browser can only add the one file."""
    text = dbio.canonical("untested", game)
    path = f"{dbio.FOLDERS['untested']}/{gid}.json"
    plain = f"https://github.com/{UPSTREAM}/new/{BASE}?filename={quote(path)}"
    url = f"{plain}&value={quote(text)}"
    if len(url) <= URL_LIMIT:
        return {"mode": "browser", "url": url}
    return {"mode": "browser", "url": plain, "json": text}


def submit(folder, gid, game, note="", checked_install=False, checked_ids=False, via="gh"):
    problems = prepare(folder, gid, game)["errors"]
    if problems:
        raise SubmitError("The profile has problems to fix first:\n" + "\n".join(problems[:5]))
    if via == "gh" and gh_login():
        return submit_with_gh(gid, game, note, checked_install, checked_ids)
    return submit_with_browser(gid, game)
