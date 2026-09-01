#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
"""Every reference in the live tree must still resolve.

WHY THIS EXISTS. `docs/pic10f320_merge_plan.md` was 3,432 lines and was cited
by section number from 43 places in the Makefile, the release scripts, the CI
workflows and the test suite. It was deleted once its normative content had
moved into DESIGN_DOCUMENTATION.adoc, and every one of those citations became a
pointer to nothing -- silently, because a comment cannot fail to compile. The
document had even kept its own numbering stable "so that the cross-references
to these numbers elsewhere in the repository stay valid", which is the tell: a
reference that needs a whole document frozen to stay true is a reference that
will outlive it.

Two rules, both lexical, so this runs wherever Python does.

SECTION CITATIONS. A section number is only stable in a document this project
does not control -- a datasheet, which is reissued under a new revision letter
rather than renumbered in place. Inside this repository a section number is a
line count in disguise: it moves when a document is edited and it dangles when
one is deleted, and neither shows up as a broken build. So the section glyph is
reserved for external documents and must name the document it cites. A
repository document is cited by name (and, in AsciiDoc, by anchor), which the
link rule below then checks.

The rule accepts a line that names an external document, and a line that
repeats a section number the SAME FILE has already attributed to one -- a
paragraph that argues about a citation it just made should not have to restate
the document in every sentence.

LINK TARGETS. A relative link or cross-reference in a durable document must
resolve to a file that exists, and its fragment to an anchor that document
actually defines. This is the same defect one layer up: `CHANGELOG.md` carried
a live Markdown link to a document deleted two releases later, so the entry
rendered a dead link on every page view.

SCOPE. Versioned directories under `release/` are excluded: published release
artifacts had links that were correct against the tree of their own tag, and
`test-published-release-immutability` is what holds them. The live
`release/README.md` policy is checked like every other durable document.
`CHANGELOG.md` is excluded from the section rule only: an entry recording what
a since-deleted document said is a true statement about the past, and every
such entry in it names the document, so a reader can see at once what is being
cited. Its links are still checked, because a dead hyperlink is dead whatever
it describes. Branch-only working documents are excluded: they are deleted
before a release and legitimately quote retired wording.

DOCUMENT LIFECYCLES. README.md claims one lifecycle for every durable authority
in its documentation map. That table is executable here: every mapped authority
must occur in exactly one expected row, and per-release paths must name disjoint
file roles rather than assigning a whole release directory to multiple labels.
"""

import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SELF = "test/test_reference_contract.py"

SECTION = re.compile(r"§\s*([0-9]+(?:\.[0-9]+)*)")

# What counts as a document this project does not control. Deliberately short:
# a new kind of external citation is a deliberate edit here, which is the point
# at which someone confirms the numbering is the publisher's and not ours.
EXTERNAL_DOCUMENT = re.compile(
    r"datasheet"
    r"|reference manual"
    r"|application note"
    r"|\bDS[0-9]{5,}[A-Z]?\b",           # Microchip document numbers
    re.IGNORECASE)

BRANCH_ONLY_BANNER = re.compile(
    r"^>\s*\*\*Branch-(only|scoped)\s+working\s+document\.\*\*", re.IGNORECASE)

HISTORICAL_RELEASE_PATH = re.compile(
    r"^release/v[0-9]+(?:\.[0-9]+)+(?:-[^/]+)?/")

MD_LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
ADOC_LINK = re.compile(r"(?:link|xref):([^\[\s]+)\[")
ADOC_XREF = re.compile(r"<<([^,>]+)")
ADOC_ANCHOR = re.compile(r"^\[\[([^\],]+)", re.MULTILINE)
ADOC_SHORT_ANCHOR = re.compile(r"^\[#([^\]\.]+)", re.MULTILINE)
MD_HEADING = re.compile(r"^#{1,6}\s+(.*?)\s*$")
HTML_ANCHOR = re.compile(r"<a\s+(?:id|name)=\"([^\"]+)\"")
CODE_SPAN = re.compile(r"`([^`]+)`")

LIFECYCLE_HEADING = "### Document lifecycle"
LIFECYCLE_AUTHORITIES = {
    "DESIGN_DOCUMENTATION.adoc": "Live specification",
    "TOOLCHAIN.adoc": "Live specification",
    "test/README.md": "Live specification",
    "README.md": "Operator guidance",
    "FLASHING.md": "Operator guidance",
    "release/README.md": "Release policy and errata",
    "MISRA_COMPLIANCE.md": "Compliance record",
    "HARDWARE_VALIDATION_LOG.md": "Hardware validation record",
    "CHANGELOG.md": "Change record",
    "TODO.md": "Open-work register",
    "docs/*.md": "Decision/safety record",
    "AGENTS.md": "Contributor policy",
    "CLAUDE.md": "Contributor policy",
    "LICENSE": "Legal terms",
    "release/<version>/QUALIFICATION": "Release result record",
    "release/<version>/MANIFEST.md": "Release result record",
    "release/<version>/README.md": "Release result record",
    "release/<version>/evidence/*": "Release result record",
    "release/<version>/*.hex": "Release payload artifact",
    "release/<version>/flash-*.py": "Release payload artifact",
    "release/<version>/SHA256SUMS": "Release authentication record",
    "release/<version>/SHA256SUMS.asc": "Release authentication record",
}

failures = []
checks = 0


def check(condition, message):
    global checks
    checks += 1
    if not condition:
        failures.append(message)


def tracked_files():
    out = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z"],
                         check=True, capture_output=True, text=True).stdout
    return [name for name in out.split("\0") if name]


def read_text(name):
    """Return the file's text, or None if it is not decodable text."""
    try:
        return (ROOT / name).read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return None


def is_historical_release_path(name):
    return bool(HISTORICAL_RELEASE_PATH.match(name))


def is_branch_only(name, text):
    # Same recognizer as release-documentation.sh: the banner in the opening
    # lines, not the filename, is what declares a document branch-only.
    if "/" in name:
        return False
    return any(BRANCH_ONLY_BANNER.match(line)
               for line in text.split("\n")[:20])


def section_violations(text):
    """Return [(line number, line)] for citations that name no external document.

    First pass records every section number this text attributes to an external
    document; the second pass lets a bare citation repeat one of them.
    """
    lines = text.split("\n")
    attributed = set()
    for line in lines:
        if EXTERNAL_DOCUMENT.search(line):
            attributed.update(match.group(1) for match in SECTION.finditer(line))
    bad = []
    for number, line in enumerate(lines, 1):
        if EXTERNAL_DOCUMENT.search(line):
            continue
        cited = [match.group(1) for match in SECTION.finditer(line)]
        if cited and not set(cited) <= attributed:
            bad.append((number, line.strip()))
    return bad


def md_anchors(text):
    anchors = set()
    for line in text.split("\n"):
        heading = MD_HEADING.match(line)
        if heading:
            slug = re.sub(r"[`*_~]", "", heading.group(1)).strip().lower()
            slug = re.sub(r"[^\w\s-]", "", slug)
            anchors.add(re.sub(r"\s+", "-", slug))
        anchors.update(match.group(1) for match in HTML_ANCHOR.finditer(line))
    return anchors


def adoc_anchors(text):
    return ({match.group(1) for match in ADOC_ANCHOR.finditer(text)} |
            {match.group(1) for match in ADOC_SHORT_ANCHOR.finditer(text)})


def anchors_of(name, text):
    return adoc_anchors(text) if name.endswith(".adoc") else md_anchors(text)


def link_violations(name, text, anchors):
    """Return [(line number, target, reason)] for links that do not resolve."""
    base = os.path.dirname(name)
    bad = []
    for number, line in enumerate(text.split("\n"), 1):
        targets = ([match.group(1) for match in MD_LINK.finditer(line)] +
                   [match.group(1) for match in ADOC_LINK.finditer(line)])
        for target in targets:
            if re.match(r"^[a-z][a-z0-9+.-]*:", target) or target.startswith("#"):
                continue
            path, _, fragment = target.partition("#")
            if not path:
                continue
            resolved = os.path.normpath(os.path.join(base, path))
            if not (ROOT / resolved).exists():
                bad.append((number, target, "names no file in the tree"))
            elif fragment and resolved in anchors and fragment not in anchors[resolved]:
                bad.append((number, target, "names no anchor that document defines"))
        if name.endswith(".adoc"):
            for match in ADOC_XREF.finditer(line):
                anchor = match.group(1).strip()
                if anchor not in anchors[name]:
                    bad.append((number, "<<%s>>" % anchor,
                                "names no anchor this document defines"))
    return bad


def lifecycle_violations(text):
    """Return defects in README.md's durable-authority lifecycle table."""
    lines = text.splitlines()
    starts = [number for number, line in enumerate(lines)
              if line == LIFECYCLE_HEADING]
    if len(starts) != 1:
        return ["expected one %r heading, found %d"
                % (LIFECYCLE_HEADING, len(starts))]

    start = starts[0] + 1
    end = next((number for number in range(start, len(lines))
                if lines[number].startswith("### ")), len(lines))
    classified = {}
    for line in lines[start:end]:
        if not line.startswith("|"):
            continue
        cells = line.split("|")
        if len(cells) < 5:
            continue
        label = cells[1].strip()
        if label in ("Label", "---"):
            continue
        for authority in CODE_SPAN.findall(cells[3]):
            classified.setdefault(authority, []).append(label)

    violations = []
    for authority, expected in LIFECYCLE_AUTHORITIES.items():
        found = classified.get(authority, [])
        if found != [expected]:
            violations.append("%s must occur once under %s, found %s"
                              % (authority, expected,
                                 ", ".join(found) if found else "no row"))
    broad = classified.get("release/<version>/", [])
    if broad:
        violations.append("release/<version>/ assigns every retained file to %s"
                          % ", ".join(broad))
    return violations


def self_test():
    """Prove each rule rejects the exact defect it exists for."""
    check(section_violations("# see merge plan §5.6 for why\n") != [],
          "negative case -- a section citation naming no document was accepted")
    check(section_violations("# ATtiny13A datasheet §7.3 says so\n") == [],
          "negative case -- a citation naming a datasheet was rejected")
    check(section_violations("# DS41190G §9.6.1\n# ties it to §9.6.1\n") == [],
          "negative case -- a repeat of an attributed number was rejected")
    check(section_violations("# DS41190G §9.6.1\n# and also §12.4\n") != [],
          "negative case -- an unattributed number beside an attributed one "
          "was accepted")
    anchors = {"fixture.md": {"heading"}}
    check(link_violations("fixture.md", "[x](docs/gone.md)\n", anchors) != [],
          "negative case -- a link to a deleted file was accepted")
    check(link_violations("fixture.md", "[x](#missing)\n", anchors) == [],
          "negative case -- a same-document fragment was treated as a path")
    check(link_violations("fixture.md", "[x](README.md#nope)\n", anchors) == [],
          "negative case -- a fragment into an unscanned document was checked")
    check(link_violations("fixture.md", "[x](https://example.invalid/a.md)\n",
                          anchors) == [],
          "negative case -- an absolute URL was resolved against the tree")
    check(not is_historical_release_path("release/README.md"),
          "negative case -- the live release policy was excluded")
    check(is_historical_release_path("release/v0.9.11/MANIFEST.md"),
          "negative case -- a historical release document was included")
    check(link_violations("release/README.md", "[x](missing.md)\n", {}) != [],
          "negative case -- a broken link in the live release policy was "
          "accepted")

    readme = read_text("README.md") or ""
    check(lifecycle_violations(readme) == [],
          "control case -- the checked-in lifecycle table is malformed")
    missing = readme.replace("`CHANGELOG.md` |", "`missing-change-record.md` |", 1)
    check(any("CHANGELOG.md" in item for item in lifecycle_violations(missing)),
          "negative case -- an omitted durable authority was accepted")
    duplicate = readme.replace("`TODO.md` |", "`TODO.md`, `CHANGELOG.md` |", 1)
    check(any("CHANGELOG.md" in item for item in lifecycle_violations(duplicate)),
          "negative case -- one authority under two lifecycle labels was accepted")
    broad = readme.replace(
        "`release/<version>/QUALIFICATION`",
        "`release/<version>/`, `release/<version>/QUALIFICATION`", 1)
    check(any("assigns every retained file" in item
              for item in lifecycle_violations(broad)),
          "negative case -- overlapping whole-release classifications were accepted")


def main():
    self_test()

    documents = {}
    scanned = 0
    for name in tracked_files():
        if is_historical_release_path(name) or name == SELF:
            continue
        text = read_text(name)
        if text is None or is_branch_only(name, text):
            continue
        scanned += 1
        if name != "CHANGELOG.md":
            for number, line in section_violations(text):
                check(False,
                      "%s:%d cites a section of a document it does not name "
                      "(cite repository documents by name and anchor): %s"
                      % (name, number, line))
        if name.endswith((".md", ".adoc")):
            documents[name] = text

    anchors = {name: anchors_of(name, text) for name, text in documents.items()}
    for name, text in sorted(documents.items()):
        for number, target, reason in link_violations(name, text, anchors):
            check(False, "%s:%d links to '%s', which %s"
                  % (name, number, target, reason))

    lifecycle = lifecycle_violations(documents.get("README.md", ""))
    check(not lifecycle, "README.md lifecycle contract: %s"
          % "; ".join(lifecycle))

    check(scanned > 0, "no tracked files were scanned")
    check(len(documents) > 0, "no durable documents were scanned")

    for message in failures:
        print("FAIL: %s" % message, file=sys.stderr)
    print("reference contract: %d checks, %d failures (%d files, %d documents)"
          % (checks, len(failures), scanned, len(documents)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
