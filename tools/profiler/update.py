"""Checks whether the checkout the editor runs from is behind its upstream branch, and pulls it."""
import os, subprocess, threading

import dbio

STATE = {"behind": 0, "subjects": [], "can_update": False, "reason": ""}
_lock = threading.Lock()
_apply_lock = threading.Lock()  # one pull and build at a time


def _git(*args, timeout=30):
    return subprocess.run(["git", *args], cwd=dbio.ROOT, capture_output=True, text=True, timeout=timeout,
                          env={**os.environ, "GIT_TERMINAL_PROMPT": "0"})


def check():
    """Fetches and records how far behind the upstream branch the checkout is. Silent on any failure
    (offline, not a git checkout, no upstream): there is then simply nothing to offer."""
    if os.environ.get("EAX_PROFILER_NO_UPDATE_CHECK"):
        return
    try:
        if _git("rev-parse", "--abbrev-ref", "@{u}").returncode:
            return
        if _git("fetch", "--quiet", timeout=20).returncode:
            return
        counts = _git("rev-list", "--left-right", "--count", "HEAD...@{u}").stdout.split()
        ahead, behind = int(counts[0]), int(counts[1])
        subjects = _git("log", "--format=%s", "-n", "5", "HEAD..@{u}").stdout.splitlines()
        target = _git("rev-parse", "@{u}").stdout.strip()
    except (OSError, subprocess.SubprocessError, ValueError, IndexError):
        return
    with _lock:
        STATE.update(behind=behind, subjects=subjects, can_update=ahead == 0, target=target,
                     reason="" if ahead == 0 else "This checkout has commits of its own that aren't upstream, so it can't be fast-forwarded. Run git pull yourself.")


def version():
    """The editor's build number (how many commits have touched tools/profiler) and the checkout it runs
    from: branch, short commit, and whether it has uncommitted changes. Empty strings outside a git checkout."""
    try:
        branch = _git("branch", "--show-current").stdout.strip() or "detached"
        commit = _git("rev-parse", "--short", "HEAD").stdout.strip()
        dirty = bool(_git("status", "--porcelain").stdout.strip())
        count = _git("rev-list", "--count", "HEAD", "--", "tools/profiler").stdout.strip()
    except (OSError, subprocess.SubprocessError):
        branch = commit = count = ""
        dirty = False
    return {"build": count if count.isdigit() else "", "branch": branch, "commit": commit, "dirty": dirty}


def state():
    with _lock:
        return dict(STATE)


def apply():
    """Fast-forwards the checkout, then rebuilds dist/ so the script the editor drives matches it."""
    if not _apply_lock.acquire(blocking=False):
        raise ValueError("An update is already running.")
    try:
        st = state()
        if not st["can_update"]:
            raise ValueError(st["reason"] or "Nothing to update.")
        # Merge the commit the player was shown, not whatever upstream has by now.
        target = st.get("target")
        try:
            r = _git("merge", "--ff-only", "--quiet", target, timeout=120) if target else _git("pull", "--ff-only", "--quiet", timeout=120)
        except subprocess.TimeoutExpired:
            raise ValueError("git took too long. Check the connection and try again.")
        if r.returncode:
            raise ValueError((r.stderr or r.stdout).strip()[:400] or "git pull failed")
        with _lock:
            STATE.update(behind=0, subjects=[], can_update=False)
        try:
            b = subprocess.run(["./build.sh"], cwd=dbio.ROOT, capture_output=True, text=True, timeout=120)
            build_ok = b.returncode == 0
        except subprocess.TimeoutExpired:
            build_ok = False
        return {"ok": True, "build_ok": build_ok}
    finally:
        _apply_lock.release()
