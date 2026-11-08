#!/usr/bin/env python3
"""Builds the wiki's files from docs/ and the profile editor's README.

GitHub wikis ignore folders: a page is addressed by its file name alone, so
docs/script/how-it-works.md has to become how-it-works.md, and every link to it
has to lose its folder and its .md. The repo keeps its folders (they are what
makes the docs readable there), and this does the flattening for the wiki only.

Usage: build-wiki.py DOCS_DIR EDITOR_README OUT_DIR
"""
import re
import shutil
import sys
from pathlib import Path

# [text](folder/page.md#anchor) -> [text](page#anchor). External links, anchors
# and anything that isn't a .md file are left alone.
LINK = re.compile(r'(\]\()(?!https?:|mailto:|#)[^)\s#]*?([A-Za-z0-9_.-]+)\.md(#[^)\s]*)?(\))')


def flatten_links(text):
    return LINK.sub(lambda m: m.group(1) + m.group(2) + (m.group(3) or "") + m.group(4), text)


def main(docs, editor_readme, out):
    docs, editor_readme, out = Path(docs), Path(editor_readme), Path(out)
    out.mkdir(parents=True, exist_ok=True)
    written = {}
    pages = [(p, p.name) for p in sorted(docs.rglob("*.md")) if "images" not in p.relative_to(docs).parts]
    pages.append((editor_readme, "profile-editor.md"))
    for path, name in pages:
        if name in written:
            sys.exit(f"build-wiki.py: {path} and {written[name]} would both become the wiki page {name}")
        written[name] = path
        (out / name).write_text(flatten_links(path.read_text(encoding="utf-8")), encoding="utf-8")
    if (docs / "images").is_dir():
        shutil.copytree(docs / "images", out / "images", dirs_exist_ok=True)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
