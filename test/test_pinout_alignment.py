#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
"""Check that every ASCII package-pinout diagram draws a square box.

WHY THIS EXISTS. On 2026-08-11 the PIC12F675 DIP-8 diagram in
DESIGN_DOCUMENTATION.adoc had one extra leading space on its V_DD row, so that
row's package walls sat at columns 34 and 39 while the two corner rows and the
other three pin rows sat at 33 and 38. It rendered as a visibly stepped box and
survived review, because a whitespace defect is exactly the kind a reader's eye
completes for them.

These diagrams are not decoration. They are transcribed from each device pack's
own pinout data and they are what somebody wires a board from, so they are held
to the same standard as anything else here: checked, not reviewed.

WHAT A DIAGRAM IS, for this gate's purposes. A corner row -- indentation, a
plus, one or more dashes, a plus, nothing else -- opens one. The next corner row
reached without crossing a blank line closes it. Every row between them must
carry a box character at BOTH of the columns the corners put their pluses in.

That last rule is the one that matters, and it is deliberately stated in terms
of the corners rather than as "every row agrees with every other row". The
historical defect passes a first-two-box-characters comparison in three of the
five other rows; it fails this one outright, because column 33 held a hyphen
from "pin1-" and column 38 held a space.

Diagrams inside release/v*/ are out of scope. Those are published, hashed
artifacts: a gate that demanded an edit there would be demanding a broken
SHA256SUMS.
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Indentation, then +---+ and nothing else. Trailing whitespace is tolerated on
# the match but not on the column arithmetic, which reads the raw line.
CORNER = re.compile(r"^ *\+-+\+ *$")

# A frozenset, NOT a string: `"" in "|+"` is True in Python, so a str here
# silently passes any row too short to reach the wall column. The truncated-row
# probe below caught exactly that while this gate was being written.
BOX_CHARS = frozenset("|+")
DOC_SUFFIXES = (".md", ".adoc")

# Published release artifacts. Their content is pinned by SHA256SUMS, so they
# are read-only to this repository in the strongest sense available.
FROZEN_PREFIX = "release/v"

# Vacuity floor. A parse that found nothing would pass every check below without
# reading a single diagram, and that is precisely how a gate stops working
# without anybody noticing. Four is what the tree holds today (AVR Classic,
# PIC10F32x, PIC12F675, ATtiny202); a fifth part raises it, and losing one is
# meant to fail here rather than pass quietly.
DIAGRAM_FLOOR = 4


def repo_files():
    """Tracked files, plus untracked ones git does not ignore.

    The second query is what lets this gate see a document the run BEFORE it is
    committed. Tracked-only would make every new file exempt until it was added,
    which reports a violation to whoever runs the suite next rather than to the
    person who just wrote it. Same reasoning, and the same idiom, as
    test/test_makefile_name_contract.py.
    """
    seen = set()
    for query in (["git", "ls-files", "-z"],
                  ["git", "ls-files", "-z", "--others", "--exclude-standard"]):
        out = subprocess.run(query, cwd=ROOT, capture_output=True, text=True,
                             check=True).stdout
        seen.update(rel for rel in out.split("\0") if rel)
    return sorted(seen)


def documents():
    for rel in repo_files():
        if not rel.endswith(DOC_SUFFIXES):
            continue
        if rel.startswith(FROZEN_PREFIX):
            continue
        path = ROOT / rel
        try:
            yield rel, path.read_text(encoding="utf-8").split("\n")
        except (OSError, UnicodeDecodeError):
            continue


def corner_columns(line):
    """The two column numbers (1-indexed) a corner row puts its pluses in."""
    cols = [i + 1 for i, ch in enumerate(line) if ch == "+"]
    return cols[0], cols[-1]


def find_diagrams(lines):
    """Yield (top, bottom, left, right) for each box, 1-indexed line numbers.

    A corner row with no partner before the next blank line is reported by
    inspect() as its own finding rather than skipped: in this tree every corner
    row belongs to a box, and a lone one is a half-deleted diagram.
    """
    i = 0
    while i < len(lines):
        if not CORNER.match(lines[i]):
            i += 1
            continue
        left, right = corner_columns(lines[i])
        j = i + 1
        while j < len(lines) and lines[j].strip():
            if CORNER.match(lines[j]):
                break
            j += 1
        closed = j < len(lines) and CORNER.match(lines[j])
        yield (i + 1, (j + 1) if closed else None, left, right)
        i = (j + 1) if closed else (i + 1)


def inspect(where, lines, report):
    """Check every diagram in one document. Returns the diagram count."""
    found = 0
    for top, bottom, left, right in find_diagrams(lines):
        if bottom is None:
            report("%s:%d: corner row has no matching bottom corner before a "
                   "blank line" % (where, top))
            continue
        found += 1
        b_left, b_right = corner_columns(lines[bottom - 1])
        if (b_left, b_right) != (left, right):
            report("%s:%d: bottom corner is at columns %d/%d but the top "
                   "corner (line %d) is at %d/%d"
                   % (where, bottom, b_left, b_right, top, left, right))
            continue
        if bottom - top < 2:
            report("%s:%d: box has no rows between its corners"
                   % (where, top))
            continue
        for n in range(top + 1, bottom):
            row = lines[n - 1]
            for col, side in ((left, "left"), (right, "right")):
                ch = row[col - 1] if len(row) >= col else ""
                if ch not in BOX_CHARS:
                    report("%s:%d: %s wall should be at column %d (where the "
                           "corners are) but that column holds %r"
                           % (where, n, side, col, ch or "end of line"))
    return found


# --------------------------------------------------------------- selftest ---
# Synthetic documents, each named for the defect it carries. The first is the
# real PIC12F675 diagram as it stood at d54ac56, one leading space and all --
# a gate whose probes are all invented can be satisfied by a checker that only
# recognizes inventions.

GOOD = [
    "....",
    "                                +----+",
    "                      V_DD pin1-|    |-pin8 V_SS (GND)",
    "    (T1CKI/OSC1/CLKIN) GP5 pin2-|    |-pin7 GP0 (AN0/CIN+/ICSPDAT)",
    " (AN3/T1G/OSC2/CLKOUT) GP4 pin3-|    |-pin6 GP1 (AN1/CIN-/Vref/ICSPCLK)",
    "          (~MCLR/V_PP) GP3 pin4-|    |-pin5 GP2 (AN2/T0CKI/INT/COUT)",
    "                                +----+",
    "....",
]

PROBES = (
    ("the historical defect: one extra leading space on the V_DD row",
     [ln.replace("                      V_DD", "                       V_DD")
      for ln in GOOD],
     "left wall should be at column 33"),
    ("bottom corner shifted",
     [ln.replace("                                +----+",
                 "                               +----+") if i == 6 else ln
      for i, ln in enumerate(GOOD)],
     "bottom corner is at columns 32/37"),
    ("a row missing its right wall",
     [ln.replace("|-pin7", " -pin7") for ln in GOOD],
     "right wall should be at column 38"),
    ("a row truncated before the left wall",
     [ln[:20] if ln.startswith("    (T1CKI") else ln for ln in GOOD],
     "holds 'end of line'"),
    ("an empty box",
     ["....", "   +----+", "   +----+", "...."],
     "box has no rows between its corners"),
    ("a corner row whose partner was deleted",
     ["....", "   +----+", "   |    |-pin1", "", "prose", "...."],
     "no matching bottom corner"),
)


def selftest(check):
    """Every probe must fail, and fail with its own diagnostic."""
    messages = []
    count = inspect("good.adoc", GOOD, messages.append)
    check(count == 1, "selftest: the known-good diagram was not recognized")
    check(not messages,
          "selftest: the known-good diagram reported %s" % (messages,))

    for label, lines, fragment in PROBES:
        messages = []
        inspect("probe.adoc", lines, messages.append)
        check(bool(messages), "selftest: %s was not caught" % label)
        check(any(fragment in m for m in messages),
              "selftest: %s was caught, but no message contained %r (got %s)"
              % (label, fragment, messages))


def main():
    failures = []
    checks = [0]

    def check(condition, message):
        checks[0] += 1
        if not condition:
            failures.append(message)

    selftest(check)

    diagrams = 0
    scanned = 0
    for rel, lines in documents():
        scanned += 1
        before = len(failures)
        diagrams += inspect(rel, lines, failures.append)
        checks[0] += 1
        if len(failures) > before:
            pass  # already reported, with the line and column

    check(diagrams >= DIAGRAM_FLOOR,
          "found only %d pinout diagrams across %d documents; expected at "
          "least %d -- the format changed or a diagram was lost"
          % (diagrams, scanned, DIAGRAM_FLOOR))

    for message in failures:
        print("FAIL: %s" % message, file=sys.stderr)
    print("pinout alignment: %d checks, %d failures (%d diagrams in %d "
          "documents, %d selftest probes)"
          % (checks[0], len(failures), diagrams, scanned, len(PROBES)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
