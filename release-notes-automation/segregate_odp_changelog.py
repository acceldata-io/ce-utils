#!/usr/bin/env python3
"""Segregate an ODP changelog into CVE Fixes, Bug Fix, and Improvements.

Reads the text file produced by generate_odp_changelog.py and writes a
release-notes file with those three sections under each component.

Classification (first match wins):

1. CVE Fixes — subject starts with ``OSV-``, contains a CVE id (``CVE-`` /
   ``CVE`` / ``CVEs``), or matches ``cve fix``.
2. Bug Fix — leftover subjects matching
   ``fix`` / ``fixes`` / ``issue`` / ``invalid`` / ``NPE`` / ``error`` /
   ``exception`` (any case).
3. Improvements — everything still left.

Example::

    python3 segregate_odp_changelog.py Changelog-ODP-3.4.3.0.txt
    python3 generate_odp_changelog.py 3.4.3.0 && python3 segregate_odp_changelog.py Changelog-ODP-3.4.3.0.txt
"""

from __future__ import annotations

import argparse
import os
import re
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from generate_odp_changelog import COMPONENTS

CVE_FIX = "CVE Fixes"
BUG_FIX = "Bug Fix"
IMPROVEMENT = "Improvements"
SECTION_ORDER = (CVE_FIX, BUG_FIX, IMPROVEMENT)

# Pass-through body lines from generate_odp_changelog.py (not commit subjects).
STATUS_LINES = {
    "no commits",
    "markup message was not found.",
    "no git log changes after the markup message.",
}

CVE_START_OSV = re.compile(r"^(?:Revert\s+[\"']+)?OSV-\d+", re.IGNORECASE)
CVE_ID = re.compile(r"CVE-\d+|\bCVEs?\b", re.IGNORECASE)
CVE_FIX_PHRASE = re.compile(r"cve\s+fix(?:es)?", re.IGNORECASE)
BUG_RE = re.compile(
    r"(?i)(?<![\w])(?:fix(?:es|ed|ing)?|issues?|invalid|npe|errors?|exceptions?)(?![\w])"
    r"|NPE|[A-Za-z]Error\b"
)

SUMMARY_START = re.compile(r"^=+$")
HEADING_TOKEN = re.compile(r"^[A-Za-z][A-Za-z0-9._+-]*$")

KNOWN_HEADINGS = {component.heading for component in COMPONENTS}


def is_cve(subject: str) -> bool:
    text = subject.strip()
    if CVE_START_OSV.match(text):
        return True
    if CVE_ID.search(text):
        return True
    if CVE_FIX_PHRASE.search(text):
        return True
    return False


def is_bug(subject: str) -> bool:
    return bool(BUG_RE.search(subject))


def classify(subject: str) -> str:
    if is_cve(subject):
        return CVE_FIX
    if is_bug(subject):
        return BUG_FIX
    return IMPROVEMENT


def is_status_line(line: str) -> bool:
    lowered = line.strip().lower()
    if lowered in STATUS_LINES:
        return True
    if lowered.startswith("no commits ("):
        return True
    return False


def is_component_heading(line: str, known: set[str]) -> bool:
    text = line.strip()
    if not text or is_status_line(text):
        return False
    if text in known:
        return True
    if text.lower() in {name.lower() for name in known}:
        return True
    # Unknown extra components (e.g. atlas) still look like a single heading token.
    return bool(HEADING_TOKEN.match(text)) and " " not in text and not text.startswith("[")


def parse_changelog(text: str) -> tuple[str, list[tuple[str, list[str]]]]:
    """Return (title, [(component, body_lines), ...])."""
    raw_lines = text.splitlines()
    lines: list[str] = []
    for line in raw_lines:
        if SUMMARY_START.match(line.strip()) or line.strip() == "SUMMARY":
            break
        lines.append(line)

    title = "CHANGELOG"
    body_start = 0
    for index, line in enumerate(lines):
        stripped = line.strip()
        if not stripped:
            continue
        title = stripped
        body_start = index + 1
        break

    known = KNOWN_HEADINGS
    sections: list[tuple[str, list[str]]] = []
    current_name: str | None = None
    current_lines: list[str] = []

    def flush() -> None:
        nonlocal current_name, current_lines
        if current_name is not None:
            sections.append((current_name, current_lines))
        current_name = None
        current_lines = []

    for line in lines[body_start:]:
        stripped = line.strip()
        if not stripped:
            continue
        if is_component_heading(stripped, known):
            flush()
            current_name = stripped
            continue
        if current_name is None:
            continue
        current_lines.append(stripped)

    flush()
    return title, sections


def render_release_notes(title: str, sections: list[tuple[str, list[str]]]) -> str:
    out: list[str] = [title, ""]
    for name, body in sections:
        out.append(name)
        if not body:
            out.append("No commits")
            out.append("")
            continue
        if all(is_status_line(line) for line in body):
            out.extend(body)
            out.append("")
            continue

        buckets = {CVE_FIX: [], BUG_FIX: [], IMPROVEMENT: []}
        passthrough: list[str] = []
        for subject in body:
            if is_status_line(subject):
                passthrough.append(subject)
                continue
            buckets[classify(subject)].append(subject)

        for section_name in SECTION_ORDER:
            items = buckets[section_name]
            if not items:
                continue
            out.append(section_name)
            out.extend(items)

        out.extend(passthrough)
        if not any(buckets[section] for section in SECTION_ORDER) and not passthrough:
            out.append("No commits")
        out.append("")
    return "\n".join(out).rstrip() + "\n"


def default_output_path(input_path: str) -> str:
    directory, filename = os.path.split(os.path.abspath(input_path))
    stem, _ext = os.path.splitext(filename)
    if stem.startswith("Changelog-"):
        stem = stem[len("Changelog-") :]
    return os.path.join(directory, f"{stem}-release-notes.txt")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Split an ODP changelog into CVE Fixes, Bug Fix, and Improvements per component."
    )
    parser.add_argument(
        "changelog",
        help="Path to the changelog text file from generate_odp_changelog.py.",
    )
    parser.add_argument(
        "-o",
        "--output",
        help="Output path. Default: <changelog-dir>/<ODP-version>-release-notes.txt",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    changelog_path = os.path.abspath(args.changelog)
    if not os.path.isfile(changelog_path):
        print(f"error: changelog not found: {changelog_path}", file=sys.stderr)
        return 2

    with open(changelog_path, encoding="utf-8") as handle:
        text = handle.read()

    title, sections = parse_changelog(text)
    rendered = render_release_notes(title, sections)
    output = os.path.abspath(args.output) if args.output else default_output_path(changelog_path)
    with open(output, "w", encoding="utf-8") as handle:
        handle.write(rendered)

    print(f"Wrote {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
