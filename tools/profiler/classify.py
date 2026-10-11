"""From captured diffs to a drafted game_config: which changes look like the game's own
bookkeeping, the `game_config` fragment, and the optional AI passes (titles and reasons,
noise the heuristics missed, alsoft_ini / EAX suggestions). Pure functions over the diff
structure `capture.diff_snapshots` returns, so each piece is testable without a game."""
import re

import ai

NOISE_KEY = re.compile(r"(^|[^a-z])(last|time|date|stamp|mru|recent)([^a-z]|$)", re.I)
NOISE_SUBSTR = ("windowpos", "windowx", "windowy", "winposx", "winposy", "winpos", "posx", "posy", "lastplayed", "lastused",
                "timestamp", "hwnd", "runcount", "playtime", "uptime")
EPOCH = re.compile(r"^\d{10,}$")
AI_SAMPLE = 150  # changes sent to the AI per request


def noise_keys(diff):
    """(file, section, key) of every change in a diff: what a baseline run shows the game rewrites by itself."""
    return {(d["file"], c["section"], c["key"]) for d in diff for c in d["changes"]}


def noise_reason(key, old, new):
    """Why a changed value looks like the game's own bookkeeping rather than an option the
    player set, or None. Conservative: width/height stay (they're real options)."""
    if NOISE_KEY.search(key) or any(w in key.lower().replace("_", "") for w in NOISE_SUBSTR):
        return "the name looks like a timestamp, window position or counter"
    if EPOCH.match(str(new or "")) or EPOCH.match(str(old or "")):
        return "the value looks like a timestamp"
    return None


def draft_game_config(diffs_audio, diffs_optional, existing=None):
    """Turns diffs into (game_config fragment, notes for a human). The audio run becomes
    audio_settings, the optional run optional_settings. Titles and reasons are placeholders
    for the AI step or the person reviewing."""
    gc = {"files": dict((existing or {}).get("files", {})), "audio_settings": [], "optional_settings": []}
    skipped = []

    def add(diffs, kind):
        group = {}
        for d in diffs:
            if d.get("unparsed"):
                skipped.append(f"{d['file']} changed, but no keys could be read from it (guessed format: {d['format']}) - set its format by hand")
                continue
            if d["format"] == "gadb" and d.get("binary_offsets") is not None:
                skipped.append(f"{d['file']}: changed at byte offsets {d['binary_offsets']}, but it isn't a GADB file the tool can read - set the key by hand")
                continue
            if not d["location"]:
                skipped.append(f"{d['file']} changed outside the game folder and the prefix's user folders, so it has no location to write")
                continue
            gc["files"].setdefault(d["file"], {"format": d["format"], "locations": [d["location"]]})
            if d["created"]:
                gc["files"][d["file"]]["if_missing"] = "create"
            for c in d["changes"]:
                if not c["expressible"] or c["new"] is None:
                    skipped.append(f"{d['file']} {c['section']} {c['key']}: value {c['new']!r} can't be expressed in the schema")
                    continue
                tgt = group.setdefault(d["file"], {})
                if d["format"] in ("ini", "wine_reg"):
                    tgt = tgt.setdefault(c["section"], {})
                tgt[c["key"]] = c["new"]
        if group:
            gc[kind].append({"title": "TODO title", "reason": "TODO reason", "changes": group})

    add(diffs_audio, "audio_settings")
    add(diffs_optional, "optional_settings")
    for k in ("audio_settings", "optional_settings"):
        if not gc[k]:
            del gc[k]
    return gc, skipped


# Speaker layouts, in the order a list of them is written, and the title each gets. The titles are
# the ones the existing speaker settings use (BioShock, Neverwinter Nights).
SPEAKER_ORDER = ["stereo", "headphones", "matrix", "surround", "quad", "surround51", "surround61", "surround71"]
SURROUND = ["quad", "surround51", "surround61", "surround71"]
SPEAKER_TITLES = {
    "stereo": "Enable stereo sound", "headphones": "Enable headphone sound", "matrix": "Enable Pro Logic surround",
    "surround": "Enable surround sound", "quad": "Enable 4.0 surround sound", "surround51": "Enable 5.1 surround sound",
    "surround61": "Enable 6.1 surround sound", "surround71": "Enable 7.1 surround sound",
}


def draft_speaker_settings(layout_diffs, gc):
    """layout_diffs: {"spk-<layout>": [diff entries against the audio run]}. Adds one
    audio_settings entry per group of layouts whose changes are identical, gated with
    only_if.speakers (all four surround layouts together become "surround"), and registers
    the files they change in gc["files"]. Returns notes for a human."""
    skipped, groups, by_layout = [], {}, {}
    for label, diffs in layout_diffs.items():
        layout = label[len("spk-"):]
        changes = {}
        for d in diffs:
            if d.get("unparsed") or not d.get("location") or d.get("binary_offsets") is not None:
                skipped.append(f"{d['file']} changed in the {layout} run, but it can't be written as a setting - set it by hand")
                continue
            for c in d["changes"]:
                if noise_reason(c["key"], c["old"], c["new"]):
                    continue  # the game's own bookkeeping would stop identical layouts matching
                if not c["expressible"] or c["new"] is None:
                    skipped.append(f"{d['file']} {c['key']} in the {layout} run: value {c['new']!r} can't be expressed in the schema")
                    continue
                changes[(d["file"], d["format"], c["section"], c["key"])] = c["new"]
                gc["files"].setdefault(d["file"], {"format": d["format"], "locations": [d["location"]]})
                if d["created"]:
                    gc["files"][d["file"]]["if_missing"] = "create"
        if changes:
            by_layout[layout] = changes
    for layout, changes in by_layout.items():
        groups.setdefault(frozenset(changes.items()), []).append(layout)
    out = []
    for key, layouts in groups.items():
        speakers = [l for l in SPEAKER_ORDER if l in layouts]
        if all(l in layouts for l in SURROUND):
            speakers = ["surround"] + [l for l in speakers if l not in SURROUND]
        changes = {}
        for (file, fmt, section, k), v in sorted(key):
            tgt = changes.setdefault(file, {})
            if fmt in ("ini", "wine_reg"):
                tgt = tgt.setdefault(section, {})
            tgt[k] = v
        speakers = sorted(speakers, key=SPEAKER_ORDER.index)
        out.append((SPEAKER_ORDER.index(speakers[0]), {
            "title": SPEAKER_TITLES[speakers[0]], "reason": "TODO reason",
            "only_if": {"speakers": speakers[0] if len(speakers) == 1 else speakers}, "changes": changes}))
    if out:
        gc.setdefault("audio_settings", []).extend(s for _, s in sorted(out, key=lambda t: t[0]))
    return skipped


def flag_suspects(diffs):
    """Marks each change with `suspect_reason` (heuristics) and returns the ones still
    unflagged, as (file entry, change) pairs, for the AI to look at."""
    rest = []
    for lst in diffs.values():
        for f in lst:
            for c in f["changes"]:
                c["suspect_reason"] = noise_reason(c["key"], c["old"], c["new"])
                if not c["suspect_reason"]:
                    rest.append((f, c))
    return rest


def ai_pass(game_name, gc, rest):
    """The AI's three jobs; raises on failure so the caller can report it. Returns suggestions."""
    for kind in ("audio_settings", "optional_settings"):
        for st in gc.get(kind, []):
            r = ai.ask("setting", {"game": game_name, "kind": kind, "changes": st["changes"], "only_if": st.get("only_if")})
            st["title"], st["reason"] = r.get("title", st["title"])[:60], r.get("reason", st["reason"])
    sample = rest[:AI_SAMPLE]
    r = ai.ask("classify", {"game": game_name, "changes": [
        {"i": i, "file": f["file"], "section": c["section"], "key": c["key"], "old": c["old"], "new": c["new"]}
        for i, (f, c) in enumerate(sample)]})
    for item in r.get("changes", []) if isinstance(r, dict) else []:
        try:
            f, c = sample[int(item["i"])]
        except (KeyError, ValueError, IndexError, TypeError):
            continue
        if item.get("keep") is False:
            c["suspect_reason"] = "AI: " + str(item.get("reason") or "looks like noise")[:120]
    keys = [{"file": f["file"], "key": c["key"], "new": c["new"]} for f, c in rest[:AI_SAMPLE]]
    return ai.clean_suggestions(ai.ask("suggest", {"game": game_name, "keys": keys}))


def build(game_name, diffs, use_ai):
    """Everything the Capture tab shows after "Build settings from the captures"."""
    gc, skipped = draft_game_config(diffs.get("audio", []), diffs.get("optional", []))
    skipped += draft_speaker_settings({k: v for k, v in diffs.items() if k.startswith("spk-")}, gc)
    out = {"diffs": diffs, "game_config": gc, "skipped": skipped, "ai": None, "suggestions": None}
    rest = flag_suspects(diffs)
    if use_ai and ai.available():
        try:
            out["suggestions"] = ai_pass(game_name, gc, rest)
            out["ai"] = "ok"
        except Exception as e:  # noqa: BLE001 - shown to the player; the heuristic draft stays usable
            out["ai"] = f"AI failed: {e}"
    return out
