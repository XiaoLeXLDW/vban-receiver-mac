#!/usr/bin/env python3
"""Check repository Markdown local file links (not remote URLs or heading anchors).

Includes inline links/images, reference definitions and HTML src/href attributes.
Fenced code blocks are skipped. No packages or network access required.
"""
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent.parent


def links(text):
    text = re.sub(r"(?ms)^\s*(`{3,}|~{3,})[^\n]*\n.*?^\s*\1\s*$", "", text)
    # Keep backticks inside Markdown link labels; they are common filename labels.
    pattern = r'!?\[[^\]\n]*\]\(\s*(<[^>]+>|[^\s()]+(?:\([^()]*\)[^\s()]*)*)'
    yield from re.findall(pattern, text)
    yield from re.findall(r'(?m)^\s*\[[^\]]+\]:\s*(<[^>]+>|\S+)', text)
    yield from re.findall(r'(?:src|href)=["\']([^"\']+)["\']', text)


def check(paths):
    errors = []
    count = 0
    for path in paths:
        for raw in links(path.read_text(encoding="utf-8")):
            url = urlsplit(raw.strip("<>"))
            if url.scheme or url.netloc or not url.path:
                continue
            count += 1
            target = (ROOT / unquote(url.path).lstrip("/") if url.path.startswith("/")
                      else path.parent / unquote(url.path)).resolve()
            if not target.is_relative_to(ROOT) or not target.exists():
                errors.append(f"{path.relative_to(ROOT)}: missing/outside repository: {raw}")
    for error in errors:
        print(error, file=sys.stderr)
    print(f"Checked {len(paths)} Markdown files and {count} local links; {len(errors)} failures. "
          "Remote URLs and heading anchors are not checked.")
    return bool(errors)


if __name__ == "__main__":
    paths = sorted(set(ROOT.glob("*.md")) | set((ROOT / "docs").rglob("*.md")) |
                   set((ROOT / "Tools").rglob("*.md")) | set((ROOT / ".github").rglob("*.md")))
    sys.exit(check(paths))
