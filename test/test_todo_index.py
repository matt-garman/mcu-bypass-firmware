#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
"""Check TODO.md's priority summary against its own sections.

WHY THIS EXISTS. TODO.md states the invariant itself -- "The stable ID in each
row matches exactly one open section above" -- and nothing checked it. On
2026-08-11 the file had drifted: T25-misra-header-gate had been added as a
section with no summary row, so the index silently under-reported the open
work. That is the failure mode a hand-maintained index always has, and it is
invisible precisely because both halves look fine in isolation.

The IDs also encode their tier (T2 = Tier 2, T25 = Tier 2.5, T3, T4), which is
easy to read as a serial number and get wrong -- the same 2026-08-11 pass first
filed a "T26" item into the Tier 2.5 section. Both spellings are checked here
so neither mistake survives review.

Sections under "Considered and declined" are deliberately NOT indexed: they are
closed, and a row for one would misreport declined work as open. They need no
check of their own -- they carry prose headings with no ID at all, so a row
invented for one matches no open section and fails as an orphan row.
"""

import re
import sys
from pathlib import Path

TODO = Path(__file__).resolve().parent.parent / "TODO.md"

TIER_HEADING = re.compile(r"^## Tier ([0-9.]+)\b")
SECTION_HEADING = re.compile(r"^### ([A-Za-z0-9][A-Za-z0-9-]*) - ")
SUMMARY_ROW = re.compile(r"^\| ([A-Za-z0-9][A-Za-z0-9-]*) \|[^|]*\| ([0-9.]+) \|")
# Prefix -> the tier a section carrying it must live in.
PREFIX_TIER = {"T2": "2", "T25": "2.5", "T3": "3", "T4": "4"}

failures = []
checks = 0


def check(condition, message):
    global checks
    checks += 1
    if not condition:
        failures.append(message)


def main():
    global checks
    text = TODO.read_text(encoding="utf-8")

    sections = {}       # id -> tier of the section it lives under
    rows = {}           # id -> tier column
    duplicates = []
    tier = None
    where = None        # "tier" | "summary" | None

    for line in text.splitlines():
        heading = TIER_HEADING.match(line)
        if heading:
            where, tier = "tier", heading.group(1)
            continue
        if line.startswith("## Priority summary"):
            where, tier = "summary", None
            continue
        if line.startswith("## "):
            where, tier = None, None
            continue

        section = SECTION_HEADING.match(line)
        if section and where == "tier":
            if section.group(1) in sections:
                duplicates.append("section %s" % section.group(1))
            sections[section.group(1)] = tier
            continue
        if where == "summary":
            row = SUMMARY_ROW.match(line)
            if row and row.group(1) != "ID":
                if row.group(1) in rows:
                    duplicates.append("summary row %s" % row.group(1))
                rows[row.group(1)] = row.group(2)

    # A parse that found nothing would pass every comparison below vacuously.
    check(len(sections) >= 10,
          "parsed only %d tier sections from TODO.md; the format changed" % len(sections))
    check(len(rows) >= 10,
          "parsed only %d priority-summary rows; the table format changed" % len(rows))
    check(not duplicates, "duplicate IDs: %s" % ", ".join(duplicates))

    for ident in sorted(set(sections) - set(rows)):
        check(False, "open section %s has no priority-summary row" % ident)
    for ident in sorted(set(rows) - set(sections)):
        check(False, "priority-summary row %s matches no open section" % ident)

    for ident in sorted(set(sections) & set(rows)):
        check(sections[ident] == rows[ident],
              "%s is in Tier %s but its summary row says Tier %s"
              % (ident, sections[ident], rows[ident]))

    for ident, section_tier in sorted(sections.items()):
        prefix = ident.split("-", 1)[0]
        expected = PREFIX_TIER.get(prefix)
        check(expected is not None,
              "%s has an unknown tier prefix '%s' (known: %s)"
              % (ident, prefix, ", ".join(sorted(PREFIX_TIER))))
        if expected is not None:
            check(expected == section_tier,
                  "%s is filed under Tier %s but its '%s' prefix means Tier %s"
                  % (ident, section_tier, prefix, expected))

    for message in failures:
        print("FAIL: %s" % message, file=sys.stderr)
    print("TODO index: %d checks, %d failures" % (checks, len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
