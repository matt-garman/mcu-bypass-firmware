#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
"""Check current resource documentation and final-candidate evidence.

WHY THIS EXISTS.  The measured flash/RAM figures for the seven release parts
are restated in four current documents -- DESIGN_DOCUMENTATION.adoc's four
utilization tables and the prose derived from them, docs/context_seu_detection.md's
"Resource qualification" table, docs/pic12f675_feasibility.md's bounded
current-status block, and CHANGELOG.md's PIC10F322 sentence -- and nothing
compared them either with each other or with a build.  They drifted, exactly as
a hand-maintained table always does.  At the v0.9.10 candidate the AVR Classic
table still carried the pre-F1 ATtiny13a images (834/874/864 against a real
838/878/868), the ATtiny202 table was three changes behind (964/1004/994 against
968/1008/1040), the PIC12F675 tables were two behind (546/572/563 against
548/574/583), the ATtiny45/85 rows were absent altogether, and two derived
sentences -- the utilization span and the ATtiny13a's distance from its 90%
ceiling -- had been computed from those stale numbers.  Every one of those is a
number a reader would reasonably act on when deciding whether a change fits.

WHAT IS CHECKED, in four layers.

1. STRUCTURE AND ARITHMETIC, from DESIGN_DOCUMENTATION.adoc alone.  The four
   tables must cover exactly the canonical 7 parts x 3 variants with no row
   missing and none invented; each table's declared device capacity must match
   the datasheet constant below; and every percentage and free-space cell must
   be recomputed from its own size and capacity.  A transcription slip in one
   cell therefore fails even if the size is right.

2. AGREEMENT, across the four documents and the prose derived from the tables.
   The other three documents restate subsets of the same figures and must agree
   digit for digit.  The derived sentences are recomputed rather than matched:
   the span sentence must name the true minimum and maximum utilization and the
   parts that hold them, the binding-image and PIC10F320 free-word claims must
   equal the tables' own margins, the ATtiny13a paragraph must agree with the
   90%-of-1024 gate limit that test/check_flash_budget.sh actually enforces, and
   the PIC12F675-versus-PIC10F322 relay comparison must equal the difference
   between those two rows.

3. OPTIONAL IMAGE COMPARISON, against built images.  For every documented image that exists in a
   build directory, the size is measured from the artifact and must equal the
   documented figure.  AVR program size is the sum of the loaded, allocated
   flash sections of the ELF -- what `avr-size` reports as `Program:` -- and PIC
   program size is the number of distinct program words the Intel HEX occupies
   below the device's flash capacity, which reproduces XC8's "Program space
   used" exactly on all nine PIC images.  Both are read here rather than shelled
   out to, so this layer needs no AVR or PIC toolchain: it measures whatever the
   tree already built.

An absent build directory is not a failure in the ordinary documentation mode.
`make test` runs on runners with no
XC8 and no ATtiny_DFP (see .github/workflows/ci.yml), so requiring all 21 images
would fail exactly where the AVR-only evidence is still worth having.  The count
of images actually measured is printed, so this mode makes no final-candidate
claim when it verified nothing.

4. FINAL-CANDIDATE EVIDENCE.  ``--require-all-images`` requires all 21 regular,
non-symlinked images, validates AVR static data from all 12 ELFs, and consumes
the release run's full build/test logs.  Those logs must contain nine Classic
AVR stack high-water observations, the three-report AVR-XT frame-bound result,
both three-variant PIC12F675 Data-space passes, and all nine PIC return-stack measurements.
On success it emits one machine record bound to the exact source commit.  The
release retains and hashes that record; this mode may never pass at 0/21.
"""

import argparse
import os
import re
import struct
import sys
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

ROOT = None
DESIGN = None
SEU = None
FEASIBILITY = None
PIC320_VALIDATION = None
CHANGELOG = None


def configure_root(root):
    global ROOT, DESIGN, SEU, FEASIBILITY, PIC320_VALIDATION, CHANGELOG
    ROOT = root.resolve()
    DESIGN = ROOT / "DESIGN_DOCUMENTATION.adoc"
    SEU = ROOT / "docs" / "context_seu_detection.md"
    FEASIBILITY = ROOT / "docs" / "pic12f675_feasibility.md"
    PIC320_VALIDATION = ROOT / "docs" / "pic10f320_validation.md"
    CHANGELOG = ROOT / "CHANGELOG.md"


configure_root(Path(__file__).resolve().parent.parent)

VARIANTS = ("cd4053_simple", "cd4053_with_mute", "tq2_l2_5v_relay")

# Datasheet flash capacity per release part, and the unit its figures are
# reported in.  AVR parts are measured in bytes by the linker; the PIC parts are
# measured in 14-bit program words by XC8, and reporting either in the other's
# unit is the mistake this pairing exists to prevent.
PARTS = {
    "attiny13a": (1024, "bytes"),
    "attiny45": (4096, "bytes"),
    "attiny85": (8192, "bytes"),
    "attiny202": (2048, "bytes"),
    "pic10f322": (512, "words"),
    "pic10f320": (256, "words"),
    "pic12f675": (1024, "words"),
}

# test/check_flash_budget.sh is invoked for the ATtiny13a with these arguments
# (Makefile, _test-flash-budget-measure) and computes its limit by integer
# truncation, so the ceiling is 921 bytes and not 921.6.
CLASSIC_BUDGET_PERCENT = 90
CLASSIC_BUDGET_LIMIT = PARTS["attiny13a"][0] * CLASSIC_BUDGET_PERCENT // 100

# Where a built image lives, and how to measure it.  The Makefile's own build
# directory variables are honoured so an out-of-tree build is still measured.
BUILD_DIRS = {
    "attiny13a": ("AVR_BUILD_DIR", "build_avr_classic", "elf"),
    "attiny45": ("AVR_BUILD_DIR", "build_avr_classic", "elf"),
    "attiny85": ("AVR_BUILD_DIR", "build_avr_classic", "elf"),
    "attiny202": ("XT_BUILD_DIR", "build_avr_xt", "elf"),
    "pic10f322": ("PIC10F322_BUILD_DIR", "build_pic10f322", "hex"),
    "pic10f320": ("PIC10F320_BUILD_DIR", "build_pic10f320", "hex"),
    "pic12f675": ("PIC12F675_BUILD_DIR", "build_pic12f675", "hex"),
}

failures = []
checks = 0


def check(condition, message):
    global checks
    checks += 1
    if not condition:
        failures.append(message)


def flatten(text):
    """Collapse the line wrapping that both documents use inside a sentence."""
    return re.sub(r"\s+", " ", text)


def capture_numbers(text, pattern, expected, label):
    """Require one prose claim and compare all captured decimal fields."""
    match = re.search(pattern, text)
    check(match is not None, "%s is missing or unparseable" % label)
    if match is not None:
        actual = tuple(int(value) for value in match.groups())
        check(actual == expected,
              "%s reports %s; expected %s"
              % (label, "/".join(str(value) for value in actual),
                 "/".join(str(value) for value in expected)))


def percent(size, capacity):
    """The utilization percentage as avr-size and XC8 both round it."""
    exact = Decimal(size) * 100 / Decimal(capacity)
    return exact.quantize(Decimal("0.1"), rounding=ROUND_HALF_UP)


def block_after(text, heading, path):
    """The first |=== ... |=== table body following an AsciiDoc heading."""
    start = text.find(heading)
    if start < 0:
        failures.append("%s has no '%s' section" % (path.name, heading.strip()))
        return []
    opened = text.find("\n|===", start)
    closed = text.find("\n|===", opened + 1) if opened >= 0 else -1
    if opened < 0 or closed < 0:
        failures.append("%s has no complete table under '%s'"
                        % (path.name, heading.strip()))
        return []
    return text[opened + 5:closed].splitlines()


def cell_split(line):
    return [c.strip() for c in line.strip().lstrip("|").split("|")]


NUMBER_UNIT = re.compile(r"^([0-9]+) (bytes|words)$")
PERCENT_ONLY = re.compile(r"^([0-9]+\.[0-9])%$")
PERCENT_OF = re.compile(r"^([0-9]+\.[0-9])% of ([0-9]+) KB$")


def parse_design(text):
    """(part, variant) -> (size, documented percent, documented free or None)."""
    figures = {}

    # AVR Classic: one table for three parts, capacity stated per row in KB.
    for line in block_after(text, "\n=== AVR Classic family", DESIGN):
        cells = cell_split(line)
        if len(cells) != 4 or cells[0] == "Part":
            continue
        part = cells[0].lower()
        size = NUMBER_UNIT.match(cells[2])
        stated = PERCENT_OF.match(cells[3])
        check(part in PARTS, "AVR Classic table names unknown part '%s'" % cells[0])
        check(size is not None and stated is not None,
              "AVR Classic row is unparseable: %s" % line.strip())
        if part not in PARTS or size is None or stated is None:
            continue
        check(int(stated.group(2)) * 1024 == PARTS[part][0],
              "%s row claims a %s KB device; the datasheet capacity is %d bytes"
              % (part, stated.group(2), PARTS[part][0]))
        check(size.group(2) == PARTS[part][1],
              "%s figures must be reported in %s, not %s"
              % (part, PARTS[part][1], size.group(2)))
        figures[(part, cells[1])] = (int(size.group(1)),
                                     Decimal(stated.group(1)), None)

    # One table per remaining part: | Variant | Flash | of <capacity> | Free.
    for part, heading in (("attiny202", "\n=== ATtiny202 (AVR-XT build)"),
                          ("pic10f322", "\n=== PIC10F322 (XC8 build)"),
                          ("pic10f320", "\n=== PIC10F320 (XC8 build)"),
                          ("pic12f675", "\n=== PIC12F675 (XC8 build)")):
        capacity, unit = PARTS[part]
        for line in block_after(text, heading, DESIGN):
            cells = cell_split(line)
            if len(cells) != 4:
                continue
            if cells[0] == "Variant":
                stated = re.match(r"^of ([0-9]+) (KB|words)$", cells[2])
                check(stated is not None,
                      "%s table header does not state a capacity: %s"
                      % (part, line.strip()))
                if stated is not None:
                    declared = int(stated.group(1))
                    if stated.group(2) == "KB":
                        declared *= 1024
                    check(declared == capacity,
                          "%s table declares %d %s of flash; the datasheet says %d"
                          % (part, declared, stated.group(2), capacity))
                continue
            size = NUMBER_UNIT.match(cells[1])
            stated = PERCENT_ONLY.match(cells[2])
            free = NUMBER_UNIT.match(cells[3])
            check(size is not None and stated is not None and free is not None,
                  "%s row is unparseable: %s" % (part, line.strip()))
            if size is None or stated is None or free is None:
                continue
            check(size.group(2) == unit and free.group(2) == unit,
                  "%s figures must be reported in %s: %s" % (part, unit, line.strip()))
            figures[(part, cells[0])] = (int(size.group(1)),
                                         Decimal(stated.group(1)),
                                         int(free.group(1)))
    return figures


def check_tables(figures):
    expected = {(part, variant) for part in PARTS for variant in VARIANTS}
    check(set(figures) == expected,
          "the utilization tables must cover exactly the 21 canonical images; "
          "missing %s, unexpected %s"
          % (sorted(expected - set(figures)) or "none",
             sorted(set(figures) - expected) or "none"))
    for (part, variant), (size, stated, free) in sorted(figures.items()):
        capacity = PARTS[part][0]
        check(0 < size <= capacity,
              "%s %s is %d of %d -- outside the device"
              % (part, variant, size, capacity))
        check(stated == percent(size, capacity),
              "%s %s says %s%% of %d; %d is %s%%"
              % (part, variant, stated, capacity, size, percent(size, capacity)))
        if free is not None:
            check(free == capacity - size,
                  "%s %s says %d free of %d; %d leaves %d"
                  % (part, variant, free, capacity, size, capacity - size))


def check_design_prose(prose, figures):
    """Checks run against whitespace-normalized prose: these sentences wrap."""
    largest = {part: max(figures[(part, v)][0] for v in VARIANTS) for part in PARTS}
    utilization = {(part, variant): percent(size, PARTS[part][0])
                   for (part, variant), (size, _, _) in figures.items()}
    low = min(utilization.values())
    high = max(utilization.values())

    span = re.search(r"spans from ([0-9]+\.[0-9])% of an? (\w+)'s flash to "
                     r"([0-9]+\.[0-9])% of an? (\w+)'s", prose)
    check(span is not None, "the Resource Utilization span sentence is missing")
    if span is not None:
        check(Decimal(span.group(1)) == low and Decimal(span.group(3)) == high,
              "the span sentence says %s%%-%s%%; the tables span %s%%-%s%%"
              % (span.group(1), span.group(3), low, high))
        holders = {part for (part, _), value in utilization.items() if value == low}
        check(span.group(2).lower() in holders,
              "the span sentence credits the minimum to %s; it belongs to %s"
              % (span.group(2), ", ".join(sorted(holders))))
        holders = {part for (part, _), value in utilization.items() if value == high}
        check(span.group(4).lower() in holders,
              "the span sentence credits the maximum to %s; it belongs to %s"
              % (span.group(4), ", ".join(sorted(holders))))

    binding = re.search(r"binding build with ([0-9]+) words free", prose)
    check(binding is not None, "the binding-image sentence is missing")
    if binding is not None:
        free = PARTS["pic10f322"][0] - largest["pic10f322"]
        check(int(binding.group(1)) == free,
              "the binding image is said to leave %s words free; it leaves %d"
              % (binding.group(1), free))

    smallest = re.search(r"leaves ([0-9]+) of ([0-9]+) words free on its largest "
                         r"variant", prose)
    check(smallest is not None, "the PIC10F320 free-word sentence is missing")
    if smallest is not None:
        free = PARTS["pic10f320"][0] - largest["pic10f320"]
        check(int(smallest.group(1)) == free
              and int(smallest.group(2)) == PARTS["pic10f320"][0],
              "PIC10F320 is said to leave %s of %s words free; it leaves %d of %d"
              % (smallest.group(1), smallest.group(2), free, PARTS["pic10f320"][0]))

    gate = re.search(r"at most ([0-9]+\.[0-9])% of 1 KB against the ([0-9]+)% "
                     r"ceiling enforced by `make test-flash-budget`, leaving "
                     r"([0-9]+) bytes or ([0-9]+\.[0-9]) percentage points", prose)
    check(gate is not None, "the ATtiny13a flash-gate sentence is missing")
    if gate is not None:
        tightest = percent(largest["attiny13a"], PARTS["attiny13a"][0])
        check(Decimal(gate.group(1)) == tightest,
              "the flash-gate sentence says the tightest ATtiny13a image is %s%%; "
              "it is %s%%" % (gate.group(1), tightest))
        check(int(gate.group(2)) == CLASSIC_BUDGET_PERCENT,
              "the flash-gate sentence says a %s%% ceiling; check_flash_budget.sh "
              "is invoked with %d%%" % (gate.group(2), CLASSIC_BUDGET_PERCENT))
        check(int(gate.group(3)) == CLASSIC_BUDGET_LIMIT - largest["attiny13a"],
              "the flash-gate sentence leaves %s bytes; the %d-byte limit leaves %d"
              % (gate.group(3), CLASSIC_BUDGET_LIMIT,
                 CLASSIC_BUDGET_LIMIT - largest["attiny13a"]))
        check(Decimal(gate.group(4)) == CLASSIC_BUDGET_PERCENT - tightest,
              "the flash-gate sentence leaves %s percentage points; %d%% - %s%% is %s"
              % (gate.group(4), CLASSIC_BUDGET_PERCENT, tightest,
                 CLASSIC_BUDGET_PERCENT - tightest))

    shell = re.search(r"on both parts: ([0-9]+) words here against the "
                      r"PIC10F322's ([0-9]+)\. The extra ([0-9]+) words are shell",
                      prose)
    check(shell is not None, "the PIC12F675-versus-PIC10F322 relay sentence is missing")
    if shell is not None:
        big = figures[("pic12f675", "tq2_l2_5v_relay")][0]
        small = figures[("pic10f322", "tq2_l2_5v_relay")][0]
        check(int(shell.group(1)) == big and int(shell.group(2)) == small,
              "the relay comparison says %s against %s; the images are %d and %d"
              % (shell.group(1), shell.group(2), big, small))
        check(int(shell.group(3)) == big - small,
              "the relay comparison calls the difference %s words; it is %d"
              % (shell.group(3), big - small))


# docs/context_seu_detection.md restates five parts as
# "| <label> | <budget> | simple / mute / relay | <margin> ..." rows.  The
# ATtiny13a's budget there is the 90% gate limit, not the device size, which is
# the one row whose "of" number is deliberately not the capacity.
SEU_ROW = re.compile(
    r"^\| (PIC10F322|PIC12F675|ATtiny13a \(AVR classic\)|ATtiny202 \(AVR-XT\)|"
    r"PIC10F320) \| ([0-9]+) (?:words|B) \| ([0-9]+) / ([0-9]+) / ([0-9]+) "
    r"(?:words|B) \| ([0-9]+) (?:words|B)(?: \((\w+)\))?")
SEU_PARTS = {
    "PIC10F322": ("pic10f322", PARTS["pic10f322"][0]),
    "PIC12F675": ("pic12f675", PARTS["pic12f675"][0]),
    "ATtiny13a (AVR classic)": ("attiny13a", CLASSIC_BUDGET_LIMIT),
    "ATtiny202 (AVR-XT)": ("attiny202", PARTS["attiny202"][0]),
    "PIC10F320": ("pic10f320", PARTS["pic10f320"][0]),
}


def check_seu_table(figures):
    seen = set()
    for line in SEU.read_text(encoding="utf-8").splitlines():
        row = SEU_ROW.match(line)
        if row is None:
            continue
        label = row.group(1)
        part, budget = SEU_PARTS[label]
        seen.add(label)
        documented = tuple(figures[(part, v)][0] for v in VARIANTS)
        stated = tuple(int(row.group(i)) for i in (3, 4, 5))
        check(int(row.group(2)) == budget,
              "%s is budgeted at %s in context_seu_detection.md; it is %d"
              % (label, row.group(2), budget))
        check(stated == documented,
              "%s is %s / %s / %s in context_seu_detection.md; the images are %s"
              % (label, row.group(3), row.group(4), row.group(5),
                 " / ".join(str(n) for n in documented)))
        margin = budget - max(documented)
        check(int(row.group(6)) == margin,
              "%s claims a %s margin in context_seu_detection.md; it is %d"
              % (label, row.group(6), margin))
        if row.group(7) is not None:
            tightest = VARIANTS[documented.index(max(documented))]
            check(row.group(7) == tightest.split("_")[-1]
                  or tightest.startswith(row.group(7)),
                  "%s credits its tightest margin to '%s'; it is %s"
                  % (label, row.group(7), tightest))
    check(seen == set(SEU_PARTS),
          "context_seu_detection.md's resource table is missing rows for %s"
          % (sorted(set(SEU_PARTS) - seen) or "none"))


def check_other_documents(figures):
    triple = re.search(r"uses ([0-9]+)/([0-9]+)/([0-9]+) of ([0-9]+) program words "
                       r"for the simple/mute/relay variants",
                       flatten(FEASIBILITY.read_text(encoding="utf-8")))
    check(triple is not None,
          "docs/pic12f675_feasibility.md states no current program-word triple")
    if triple is not None:
        documented = tuple(figures[("pic12f675", v)][0] for v in VARIANTS)
        check(tuple(int(triple.group(i)) for i in (1, 2, 3)) == documented,
              "the PIC12F675 current-status block says %s/%s/%s; the images are %s"
              % (triple.group(1), triple.group(2), triple.group(3),
                 "/".join(str(n) for n in documented)))
        check(int(triple.group(4)) == PARTS["pic12f675"][0],
              "the PIC12F675 current-status block says %s program words; the part "
              "has %d" % (triple.group(4), PARTS["pic12f675"][0]))

    images = re.search(r"PIC10F322 images at ([0-9]+)/([0-9]+)/([0-9]+) of "
                       r"([0-9]+) words", flatten(CHANGELOG.read_text(encoding="utf-8")))
    check(images is not None, "CHANGELOG.md states no current PIC10F322 triple")
    if images is not None:
        documented = tuple(figures[("pic10f322", v)][0] for v in VARIANTS)
        check(tuple(int(images.group(i)) for i in (1, 2, 3)) == documented,
              "CHANGELOG.md says the PIC10F322 images are %s/%s/%s; they are %s"
              % (images.group(1), images.group(2), images.group(3),
                 "/".join(str(n) for n in documented)))
        check(int(images.group(4)) == PARTS["pic10f322"][0],
              "CHANGELOG.md says %s PIC10F322 words; the part has %d"
              % (images.group(4), PARTS["pic10f322"][0]))


def check_nonflash_claims(design_text):
    """Pin every exact current RAM/stack number the documents publish."""
    design = flatten(design_text)
    capture_numbers(
        design,
        r"totalling ([0-9]+) bytes\. Peak stack.*?measures ([0-9]+)-([0-9]+) "
        r"bytes.*?aggregate occupancy is ([0-9]+)-([0-9]+) bytes.*?leaving "
        r"([0-9]+)-([0-9]+) bytes of free headroom",
        (5, 31, 33, 36, 38, 28, 26),
        "AVR Classic static/stack/headroom claim")
    capture_numbers(
        design,
        r"Measured today: ([0-9]+)-([0-9]+) free bytes across the variants",
        (26, 28), "AVR Classic measured free-SRAM claim")
    capture_numbers(
        design,
        r"build reports ([0-9]+) bytes of static data in every variant.*?"
        r"([0-9]+)-byte build limit leaves at least ([0-9]+) bytes",
        (5, 16, 112), "ATtiny202 static-RAM claim")
    capture_numbers(
        design,
        r"rejects any frame above ([0-9]+) bytes",
        (32,), "ATtiny202 frame-bound claim")
    check("No AVR-XT lane measures that maximum" in design,
          "ATtiny202 must not claim a measured whole-program stack high-water mark")
    capture_numbers(
        design,
        r"PIC12F675.*?XC8 reserves ([0-9]+) of the device's ([0-9]+) Data-space "
        r"bytes \(([0-9]+)\.([0-9]+)%\).*?fails above ([0-9]+)/([0-9]+) bytes",
        (40, 64, 62, 5, 48, 64), "PIC12F675 Data-space claim")

    seu = flatten(SEU.read_text(encoding="utf-8"))
    check("(`make test` and `make test-long`)" in seu,
          "context_seu_detection.md must name both aggregates that run the Classic AVR stack gate")
    capture_numbers(
        seu,
        r"measures ([0-9]+)-([0-9]+) B of stack use.*?With ([0-9]+) B of "
        r"static data, aggregate occupancy is ([0-9]+)-([0-9]+) B.*?leaves "
        r"([0-9]+) B free.*?gate's ([0-9]+) B floor",
        (31, 33, 5, 36, 38, 26, 8),
        "context-SEU Classic AVR RAM/stack claim")
    capture_numbers(
        seu,
        r"PIC10F322 return-stack depth is unchanged at ([0-9]+) levels "
        r"\(`cd4053_simple`, `cd4053_with_mute`\) and ([0-9]+) "
        r"\(`tq2_l2_5v_relay`\)",
        (3, 4), "context-SEU PIC10F322 return-stack claim")

    feasibility = flatten(FEASIBILITY.read_text(encoding="utf-8"))
    capture_numbers(
        feasibility,
        r"XC8 reserves ([0-9]+) of the device's ([0-9]+) Data-space bytes in "
        r"all three variants.*?rejects use above ([0-9]+) of those ([0-9]+) bytes",
        (40, 64, 48, 64), "PIC12F675 current-status Data-space claim")

    pic320 = flatten(PIC320_VALIDATION.read_text(encoding="utf-8"))
    capture_numbers(
        pic320,
        r"they agree.*?\*\*([0-9]+) / ([0-9]+) / ([0-9]+)\*\* entries for simple / "
        r"mute / relay since `v0\.9\.10`",
        (3, 3, 3), "PIC10F320 current final-HEX stack claim")
    check(re.search(
        r"Historical hardware return-stack depth.*?3 / 3 / 4.*?through "
        r"`v0\.9\.9`.*?superseded", pic320) is not None,
        "PIC10F320's old 3/3/4 stack row must be explicitly historical and superseded")


def elf_resource_bytes(path):
    """Return AVR program and statically allocated SRAM bytes from one ELF."""
    data = path.read_bytes()
    if data[:4] != b"\x7fELF" or data[4] != 1:
        raise ValueError("not a 32-bit ELF")
    endian = "<" if data[5] == 1 else ">"
    shoff = struct.unpack_from(endian + "I", data, 0x20)[0]
    shentsize, shnum = struct.unpack_from(endian + "HH", data, 0x2E)
    program = 0
    static_data = 0
    for index in range(shnum):
        header = shoff + index * shentsize
        sh_type, sh_flags, sh_addr = struct.unpack_from(endian + "III", data, header + 4)
        sh_size = struct.unpack_from(endian + "I", data, header + 0x14)[0]
        # SHF_ALLOC and not SHT_NOBITS, in the flash address space: avr-gcc
        # gives SRAM sections the 0x800000 data-space bias, so the comparison
        # separates .data's flash copy from .bss without naming sections.
        if (sh_flags & 0x2) and sh_type != 8 and sh_addr < 0x800000:
            program += sh_size
        if (sh_flags & 0x2) and 0x800000 <= sh_addr < 0x810000:
            static_data += sh_size
    return program, static_data


def elf_program_bytes(path):
    """Compatibility wrapper used by the program-size comparison."""
    return elf_resource_bytes(path)[0]


def hex_program_words(path, capacity):
    """Distinct program words an Intel HEX occupies below the flash capacity."""
    extended = 0
    occupied = set()
    saw_eof = False
    for line in path.read_text(encoding="ascii").splitlines():
        line = line.strip()
        if not line:
            continue
        if not line.startswith(":"):
            raise ValueError("record does not start with ':'")
        record = bytes.fromhex(line[1:])
        count, high, low, kind = record[0], record[1], record[2], record[3]
        if len(record) != count + 5:
            raise ValueError("record length does not match its byte count")
        if sum(record) & 0xFF:
            raise ValueError("record checksum does not sum to zero")
        payload = record[4:4 + count]
        if kind == 0:
            base = extended + ((high << 8) | low)
            for offset in range(0, count, 2):
                word = (base + offset) // 2
                if word < capacity:
                    occupied.add(word)
        elif kind == 1:
            saw_eof = True
        elif kind == 2:
            extended = ((payload[0] << 8) | payload[1]) << 4
        elif kind == 4:
            extended = ((payload[0] << 8) | payload[1]) << 16
        else:
            raise ValueError("unsupported record type %d" % kind)
    if not saw_eof:
        raise ValueError("no end-of-file record")
    return len(occupied)


def check_built_images(figures, require_all=False):
    measured = 0
    avr_static_measured = 0
    for part in sorted(PARTS):
        variable, default, extension = BUILD_DIRS[part]
        directory = ROOT / os.environ.get(variable) if os.environ.get(variable) \
            else ROOT / default
        for variant in VARIANTS:
            image = directory / ("bypass-%s-%s.%s" % (part, variant, extension))
            if not image.exists():
                if require_all:
                    check(False, "required final-candidate image is missing: %s" % image)
                continue
            if image.is_symlink() or not image.is_file():
                check(False, "image is not a regular non-symlinked file: %s" % image)
                continue
            documented = figures[(part, variant)][0]
            try:
                if extension == "elf":
                    actual, static_data = elf_resource_bytes(image)
                    avr_static_measured += 1
                    check(static_data == 5,
                          "%s has %d bytes of static data; the documentation says 5"
                          % (image, static_data))
                else:
                    actual = hex_program_words(image, PARTS[part][0])
            except (ValueError, OSError) as error:
                check(False, "%s is not a measurable image: %s" % (image, error))
                continue
            measured += 1
            check(actual == documented,
                  "%s measures %d %s; the documentation says %d"
                  % (image, actual, PARTS[part][1], documented))
    if require_all:
        check(measured == 21,
              "final-candidate mode requires 21 of 21 images; measured %d" % measured)
        check(avr_static_measured == 12,
              "final-candidate mode requires static-data measurements from 12 AVR ELFs; measured %d"
              % avr_static_measured)
    return measured, avr_static_measured


def read_evidence_file(directory, name):
    path = directory / name
    check(path.exists() and path.is_file() and not path.is_symlink() and path.stat().st_size > 0,
          "final-candidate evidence is missing, empty, or not regular: %s" % path)
    if not path.exists() or not path.is_file() or path.is_symlink():
        return ""
    return path.read_text(encoding="utf-8", errors="replace")


def check_final_evidence(directory):
    """Validate retained non-flash measurements from the release run logs."""
    classic = read_evidence_file(directory, "test-long.log")
    hwm = re.findall(
        r"^\s+stack HWM \[(attiny13a|attiny45|attiny85)\]: "
        r".*?used=([0-9]+) B, margin=([0-9]+) B free "
        r".*?static .*?, ([0-9]+) B\)$", classic, re.MULTILINE)
    check(len(hwm) == 9,
          "test-long.log must contain exactly 9 Classic AVR stack HWM records; found %d"
          % len(hwm))
    if len(hwm) == 9:
        parts = [row[0] for row in hwm]
        used = [int(row[1]) for row in hwm]
        margins = [int(row[2]) for row in hwm]
        static = [int(row[3]) for row in hwm]
        part_counts = {part: parts.count(part) for part in set(parts)}
        expected_part_counts = {"attiny13a": 3, "attiny45": 3, "attiny85": 3}
        check(part_counts == expected_part_counts,
              "test-long.log must contain three stack HWM records for each Classic AVR part")
        check((min(used), max(used)) == (31, 33),
              "Classic AVR stack HWM span is %d-%d B; documentation says 31-33 B"
              % (min(used), max(used)))
        if part_counts == expected_part_counts:
            attiny13a_margins = [margin for part, margin in zip(parts, margins)
                                 if part == "attiny13a"]
            check((min(attiny13a_margins), max(attiny13a_margins)) == (26, 28),
                  "ATtiny13a free-SRAM span is %d-%d B; documentation says 26-28 B"
                  % (min(attiny13a_margins), max(attiny13a_margins)))
        check(set(static) == {5},
              "Classic AVR stack evidence does not report 5 static bytes in every run")

    xt = read_evidence_file(directory, "attiny202-test.log")
    frame = re.findall(
        r"^OK: ([0-9]+) fresh AVR-XT reports; all frames <= ([0-9]+) B$",
        xt, re.MULTILINE)
    check(frame == [("3", "32")],
          "attiny202-test.log must contain one three-report, 32-byte frame-bound result")

    pic_data = read_evidence_file(directory, "pic12f675-qualification.log")
    data_rows = re.findall(
        r"^PIC12F675_DATA_BUDGET PASS variant=([a-z0-9_]+) used=([0-9]+) "
        r"limit=([0-9]+) capacity=([0-9]+)$", pic_data, re.MULTILINE)
    expected_data = {(variant, "40", "48", "64") for variant in VARIANTS}
    check(set(data_rows) == expected_data and len(data_rows) == 6
          and all(data_rows.count(row) == 2 for row in expected_data),
          "pic12f675-qualification.log must contain two exact 40/48/64 Data-space records per variant (qualified and reproducibility builds)")

    expected_stack = {
        "PIC10F322": dict(zip(VARIANTS, (3, 3, 4))),
        "PIC10F320": dict(zip(VARIANTS, (3, 3, 3))),
        "PIC12F675": dict(zip(VARIANTS, (3, 3, 4))),
    }
    for part, filename in (("PIC10F322", "pic10f322-test.log"),
                           ("PIC10F320", "pic10f320-test.log"),
                           ("PIC12F675", "pic12f675-qualification.log")):
        text = read_evidence_file(directory, filename)
        rows = re.findall(
            r"PIC hardware-stack depth \[%s ([a-z0-9_]+)\].*?"
            r"measured peak\s*: ([0-9]+) level\(s\)" % part,
            text, re.DOTALL)
        actual = {variant: int(depth) for variant, depth in rows}
        check(len(rows) == 3 and actual == expected_stack[part],
              "%s must contain exact current stack depths for all three variants"
              % filename)
    return len(hwm), len(data_rows), 9


def report(measured=None, require_all=False, source_commit=None,
           avr_static_measured=0, evidence_counts=None):
    for message in failures:
        print("FAIL: %s" % message, file=sys.stderr)
    if measured is None:
        print("resource tables: %d checks, %d failures (no image measured: the "
              "tables must parse first)" % (checks, len(failures)))
    else:
        qualifier = "; complete candidate required" if require_all else ""
        print("resource tables: %d checks, %d failures "
              "(%d of 21 documented images measured%s)"
              % (checks, len(failures), measured, qualifier))
    if require_all and not failures:
        classic_stack, pic_data, pic_stack = evidence_counts
        print("RESOURCE_TABLES_RESULT format=1 status=pass source_commit=%s "
              "images=%d avr_static=%d classic_stack=%d pic_data=%d pic_stack=%d"
              % (source_commit, measured, avr_static_measured, classic_stack,
                 pic_data, pic_stack))
    return 1 if failures else 0


def parse_arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT,
                        help="repository root (used by the isolated contract regression)")
    parser.add_argument("--require-all-images", action="store_true",
                        help="require complete final-candidate image and log evidence")
    parser.add_argument("--evidence-dir", type=Path,
                        help="release run's unstaged evidence directory")
    parser.add_argument("--source-commit",
                        help="full source commit bound into final-candidate evidence")
    return parser.parse_args()


def main():
    arguments = parse_arguments()
    configure_root(arguments.root)
    if arguments.require_all_images:
        check(arguments.source_commit is not None
              and re.fullmatch(r"[0-9a-f]{40}", arguments.source_commit) is not None,
              "final-candidate mode requires --source-commit as a full lowercase SHA-1")
        check(arguments.evidence_dir is not None,
              "final-candidate mode requires --evidence-dir")
    text = DESIGN.read_text(encoding="utf-8")
    figures = parse_design(text)
    if failures:
        return report()
    check_tables(figures)
    # Everything below indexes every canonical row, so an incomplete table is
    # reported as the missing-row failure it is rather than as a traceback.
    if set(figures) != {(part, variant) for part in PARTS for variant in VARIANTS}:
        return report()
    check_design_prose(flatten(text), figures)
    check_seu_table(figures)
    check_other_documents(figures)
    check_nonflash_claims(text)
    measured, avr_static_measured = check_built_images(
        figures, require_all=arguments.require_all_images)
    evidence_counts = None
    if arguments.require_all_images and arguments.evidence_dir is not None:
        evidence_counts = check_final_evidence(arguments.evidence_dir.resolve())
    if arguments.require_all_images and evidence_counts is None:
        evidence_counts = (0, 0, 0)
    return report(measured, require_all=arguments.require_all_images,
                  source_commit=arguments.source_commit,
                  avr_static_measured=avr_static_measured,
                  evidence_counts=evidence_counts)


if __name__ == "__main__":
    sys.exit(main())
