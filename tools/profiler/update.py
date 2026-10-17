"""Checks whether the checkout the editor runs from is behind its upstream branch, and pulls it."""
import os, subprocess, threading

import dbio

STATE = {"behind": 0, "subjects": [], "can_update": False, "reason": ""}
_lock = threading.Lock()


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
    except (OSError, subprocess.SubprocessError, ValueError, IndexError):
        return
    with _lock:
        STATE.update(behind=behind, subjects=subjects, can_update=ahead == 0,
                     reason="" if ahead == 0 else "This checkout has commits of its own that aren't upstream, so it can't be fast-forwarded. Run git pull yourself.")


def state():
    with _lock:
        return dict(STATE)


def apply():
    """Fast-forwards the checkout, then rebuilds dist/ so the script the editor drives matches it."""
    if not state()["can_update"]:
        raise ValueError(state()["reason"] or "Nothing to update.")
    r = _git("pull", "--ff-only", "--quiet", timeout=120)
    if r.returncode:
        raise ValueError((r.stderr or r.stdout).strip()[:400] or "git pull failed")
    b = subprocess.run(["./build.sh"], cwd=dbio.ROOT, capture_output=True, text=True, timeout=120)
    with _lock:
        STATE.update(behind=0, subjects=[], can_update=False)
    return {"ok": True, "build_ok": b.returncode == 0}
