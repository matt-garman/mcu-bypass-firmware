#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
"""Measure the release images against the reviewed resource ceilings.

WHY THIS EXISTS.  The measured flash/RAM figures for the seven release parts
used to be restated in four current documents -- DESIGN_DOCUMENTATION.adoc's
utilization tables and the prose derived from them, docs/context_seu_detection.md's
"Resource qualification" table, a bounded current-status block in the
since-deleted PIC12F675 port assessment, and CHANGELOG.md's PIC10F322 sentence
-- and this gate
kept those five copies synchronized with each other and with a build.  They had
drifted before it existed, exactly as a hand-maintained table always does: at
the v0.9.10 candidate three of the four tables were several changes behind, the
ATtiny45/85 rows were absent altogether, and two derived sentences had been
computed from the stale numbers.

Keeping the copies synchronized treated the symptom.  A measurement that must be
transcribed into prose to be checked makes documentation editing a precondition
for a firmware size change, and makes prose formatting a tested interface.  The
documents now carry capacities, reviewed ceilings, measurement methods and the
architectural consequences -- the parts that are stable under ordinary code
changes -- and no current figure at all.  Exact per-image measurements belong to
the release record that binds them to a source commit and a pinned toolchain.

So this gate no longer reads documentation.  It measures, and it compares what it
measured against the ceiling the build itself enforces.

WHAT IS CHECKED, in three layers.

1. REVIEWED POLICY, read from the Makefile.  Every ceiling below is owned by one
   Makefile variable and is parsed from it rather than restated here; a missing,
   duplicated or non-numeric definition fails.  The parsed policy is then checked
   for coherence against the datasheet capacities, which are silicon and not
   policy: no flash ceiling may exceed its part's capacity (the Makefile records
   why -- a shared PIC_FLASH_WORDS=512 once silently gated the 256-word part),
   no RAM sub-limit may reach its device's capacity, and no stack reserve may
   consume the hardware stack.

2. IMAGE MEASUREMENT, against those ceilings.  For every canonical image that
   exists in a build directory, the size is measured from the artifact and must
   be a positive figure at or below the part's ceiling.  AVR program size is the
   sum of the loaded, allocated flash sections of the ELF -- what `avr-size`
   reports as `Program:` -- and PIC program size is the number of distinct
   program words the Intel HEX occupies below the device's flash capacity, which
   reproduces XC8's "Program space used" exactly on all nine PIC images.  Both
   are read here rather than shelled out to, so this layer needs no AVR or PIC
   toolchain: it measures whatever the tree already built.

An absent build directory is not a failure in the ordinary mode.  `make test`
runs on runners with no XC8 and no ATtiny_DFP (see .github/workflows/ci.yml), so
requiring all 21 images would fail exactly where the AVR-only evidence is still
worth having.  The count of images actually measured is printed, so this mode
makes no final-candidate claim when it verified nothing.

3. FINAL-CANDIDATE EVIDENCE.  ``--require-all-images`` requires all 21 regular,
   non-symlinked images, validates AVR static data from all 12 ELFs, and consumes
   the release run's full build/test logs.  Those logs must contain nine Classic
   AVR stack high-water observations, the three-report AVR-XT frame-bound result,
   both three-variant PIC12F675 Data-space passes, and all nine PIC return-stack
   measurements.  Each record is checked for internal arithmetic consistency and
   against the reviewed limit it reports against -- a truncated, reordered or
   hand-edited log fails on its own arithmetic -- rather than against a
   remembered figure, which would put this file back in the business of
   restating today's numbers.  On success it emits one machine record per
   published figure, plus a terminal record counting them, all bound to the
   exact source commit.  The release retains and hashes that log and renders its
   published resource tables from those records, so the figure a reader sees is
   the figure this gate passed on rather than one derived a second time by
   whoever displays it.  This mode may never pass at 0/21.

4. AGREEMENT, where one published figure summarizes more than one measurement.
   Publishing a single number for a part means proving the measurements behind
   it agree, so each aggregation is a check: the two AVR static-data oracles
   (allocated ELF sections here, and the SRAM map the canary gate derives from
   the simulated device's symbols) must report the same statics, a part's three
   variants must agree before one figure stands for the part, and the PIC12F675
   qualified build and reproducibility rebuild must agree on Data space.  Each
   was previously checked only against its limit, never against the other.
"""

import argparse
import os
import re
import struct
import sys
from pathlib import Path

ROOT = None
MAKEFILE = None
SIM_TEST = None


def configure_root(root):
    global ROOT, MAKEFILE, SIM_TEST
    ROOT = root.resolve()
    MAKEFILE = ROOT / "Makefile"
    SIM_TEST = ROOT / "test" / "avr" / "test_sim.c"


configure_root(Path(__file__).resolve().parent.parent)

VARIANTS = ("cd4053_simple", "cd4053_with_mute", "tq2_l2_5v_relay")

# Datasheet flash capacity per release part, and the unit its figures are
# reported in.  This is silicon: it is not a ceiling, cannot be overridden, and
# every reviewed ceiling below is checked against it.  AVR parts are measured in
# bytes by the linker; the PIC parts are measured in 14-bit program words by XC8,
# and reporting either in the other's unit is the mistake this pairing exists to
# prevent.
PARTS = {
    "attiny13a": (1024, "bytes"),
    "attiny45": (4096, "bytes"),
    "attiny85": (8192, "bytes"),
    "attiny202": (2048, "bytes"),
    "pic10f322": (512, "words"),
    "pic10f320": (256, "words"),
    "pic12f675": (1024, "words"),
}

# The reviewed ceilings, each owned by exactly one Makefile variable and read
# from it.  Restating a value here would recreate, in the test, the duplication
# the documents were relieved of.
POLICY_VARIABLES = (
    "ATTINY13A_FLASH_BYTES",
    "ATTINY13A_FLASH_BUDGET",
    "XT_FLASH_BYTES",
    "XT_SRAM_BYTES",
    "XT_STATIC_RAM_LIMIT",
    "XT_STACK_MAX_FRAME",
    "PIC10F322_FLASH_WORDS",
    "PIC10F322_STACK_RESERVE",
    "PIC10F320_FLASH_WORDS",
    "PIC10F320_STACK_RESERVE",
    "PIC10F320_RETURN_STACK_LIMIT",
    "PIC12F675_FLASH_WORDS",
    "PIC12F675_DATA_BYTES",
    "PIC12F675_DATA_LIMIT",
    "PIC12F675_STACK_RESERVE",
)

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


def parse_policy():
    """Read every reviewed ceiling from the Makefile that enforces it."""
    try:
        text = MAKEFILE.read_text(encoding="utf-8")
    except OSError as error:
        failures.append("the reviewed ceilings cannot be read: %s" % error)
        return None
    policy = {}
    for name in POLICY_VARIABLES:
        # Count assignments before looking at their values. Otherwise one
        # reviewed constant followed by a computed reassignment appears unique
        # here even though Make consumes the later value.
        assignments = re.findall(
            r"^[ ]*(?:(?:override|export|private)[ \t]+)*%s[ \t]*"
            r"(?:(?::){0,3}|[?+!])=" % re.escape(name),
            text, re.MULTILINE)
        check(len(assignments) == 1,
              "the Makefile must define %s exactly once as a decimal constant; "
              "found %d assignments" % (name, len(assignments)))
        if len(assignments) != 1:
            continue
        # `NAME ?= n`, `NAME = n` and `override NAME := n` are all definitions;
        # anything else (a computed value, a reference to another variable) is
        # not a reviewed constant this gate can check, and fails rather than
        # being skipped.
        matches = re.findall(
            r"^(?:override[ \t]+)?%s[ \t]*[:?]?=[ \t]*([0-9]+)[ \t]*$"
            % re.escape(name),
            text, re.MULTILINE)
        check(len(matches) == 1,
              "the Makefile's sole %s assignment must be a decimal constant"
              % name)
        if len(matches) != 1:
            continue
        value = int(matches[0])
        check(value > 0, "%s must be a positive integer; the Makefile says %d"
              % (name, value))
        policy[name] = value
    return policy if len(policy) == len(POLICY_VARIABLES) else None


def parse_classic_stack_floor():
    """The free-SRAM floor test/avr/test_sim.c's canary gate actually enforces."""
    try:
        text = SIM_TEST.read_text(encoding="utf-8")
    except OSError as error:
        failures.append("the Classic AVR stack floor cannot be read: %s" % error)
        return None
    matches = re.findall(r"margin_bytes >= ([0-9]+)u", text)
    check(len(matches) == 1,
          "test/avr/test_sim.c must state its free-SRAM floor exactly once; "
          "found %d" % len(matches))
    return int(matches[0]) if len(matches) == 1 else None


def flash_ceilings(policy):
    """The reviewed flash ceiling per part, in that part's own unit."""
    return {
        # check_flash_budget.sh computes its limit by integer truncation, so a
        # 90% budget on 1024 B is 921 B and not 921.6.
        "attiny13a": (policy["ATTINY13A_FLASH_BYTES"]
                      * policy["ATTINY13A_FLASH_BUDGET"] // 100),
        # The percentage gate covers the ATtiny13a, the part it binds.  On the
        # tinyx5 parts the same firmware occupies a fifth or a tenth of the
        # device, so the linker's device size is the bound those builds need.
        "attiny45": PARTS["attiny45"][0],
        "attiny85": PARTS["attiny85"][0],
        "attiny202": policy["XT_FLASH_BYTES"],
        "pic10f322": policy["PIC10F322_FLASH_WORDS"],
        "pic10f320": policy["PIC10F320_FLASH_WORDS"],
        "pic12f675": policy["PIC12F675_FLASH_WORDS"],
    }


def check_policy(policy, ceilings):
    """The reviewed ceilings must be coherent with the silicon they bound."""
    check(policy["ATTINY13A_FLASH_BYTES"] == PARTS["attiny13a"][0],
          "the Makefile calls the ATtiny13a %d B of flash; the datasheet says %d"
          % (policy["ATTINY13A_FLASH_BYTES"], PARTS["attiny13a"][0]))
    check(1 <= policy["ATTINY13A_FLASH_BUDGET"] <= 100,
          "ATTINY13A_FLASH_BUDGET is a percentage; the Makefile says %d"
          % policy["ATTINY13A_FLASH_BUDGET"])
    for part in sorted(PARTS):
        capacity, unit = PARTS[part]
        check(0 < ceilings[part] <= capacity,
              "the reviewed %s ceiling is %d %s; the part holds %d"
              % (part, ceilings[part], unit, capacity))
    check(policy["XT_STATIC_RAM_LIMIT"] < policy["XT_SRAM_BYTES"],
          "the ATtiny202 static-RAM ceiling (%d B) leaves no SRAM for the stack "
          "(device %d B)" % (policy["XT_STATIC_RAM_LIMIT"],
                             policy["XT_SRAM_BYTES"]))
    check(policy["XT_STACK_MAX_FRAME"] <= policy["XT_SRAM_BYTES"],
          "the ATtiny202 per-frame ceiling (%d B) exceeds the device's SRAM (%d B)"
          % (policy["XT_STACK_MAX_FRAME"], policy["XT_SRAM_BYTES"]))
    check(policy["PIC12F675_DATA_LIMIT"] < policy["PIC12F675_DATA_BYTES"],
          "the PIC12F675 Data-space ceiling (%d B) is not inside the device's "
          "%d B" % (policy["PIC12F675_DATA_LIMIT"],
                    policy["PIC12F675_DATA_BYTES"]))
    for part in ("PIC10F322", "PIC10F320", "PIC12F675"):
        reserve = policy["%s_STACK_RESERVE" % part]
        check(0 < reserve < policy["PIC10F320_RETURN_STACK_LIMIT"],
              "the %s return-stack reserve (%d) does not leave usable levels "
              "inside the %d-level hardware stack"
              % (part, reserve, policy["PIC10F320_RETURN_STACK_LIMIT"]))


def check_built_images(policy, ceilings, require_all=False):
    """Measure every canonical image, and return what was measured.

    The measurements are returned rather than only counted.  They are the
    figures the release publishes, and a value that is measured here, checked
    against its ceiling and then discarded has to be derived a second time by
    whoever displays it -- which is how the manifest came to carry a flash
    column this gate never saw.
    """
    rows = []
    static_rows = []
    for part in sorted(PARTS):
        variable, default, extension = BUILD_DIRS[part]
        directory = ROOT / os.environ.get(variable) if os.environ.get(variable) \
            else ROOT / default
        capacity, unit = PARTS[part]
        for variant in VARIANTS:
            image = directory / ("bypass-%s-%s.%s" % (part, variant, extension))
            # An ELF is a build artifact and never ships, so every record names
            # the published HEX whatever was measured; a record naming an ELF
            # could not be matched to the release row it has to bind.
            published = "bypass-%s-%s.hex" % (part, variant)
            if not image.exists():
                if require_all:
                    check(False, "required final-candidate image is missing: %s" % image)
                continue
            if image.is_symlink() or not image.is_file():
                check(False, "image is not a regular non-symlinked file: %s" % image)
                continue
            try:
                if extension == "elf":
                    actual, static_data = elf_resource_bytes(image)
                    # 16 B is the project's only reviewed static-RAM ceiling.
                    # Both AVR families allocate the same statics -- the shared
                    # core's context, its check word, and the ISR handshake --
                    # so it bounds them both.  The Classic parts' real guard is
                    # the canary gate's free-SRAM floor, re-checked below from
                    # the release run's own measurements.
                    check(0 < static_data <= policy["XT_STATIC_RAM_LIMIT"],
                          "%s allocates %d B of static data; the reviewed ceiling "
                          "is %d B" % (image, static_data,
                                       policy["XT_STATIC_RAM_LIMIT"]))
                    static_rows.append({
                        "image": published, "part": part, "static": static_data,
                        "ceiling": policy["XT_STATIC_RAM_LIMIT"],
                    })
                else:
                    actual = hex_program_words(image, capacity)
            except (ValueError, OSError) as error:
                check(False, "%s is not a measurable image: %s" % (image, error))
                continue
            check(0 < actual <= ceilings[part],
                  "%s measures %d %s; the reviewed ceiling is %d"
                  % (image, actual, unit, ceilings[part]))
            rows.append({
                "image": published, "part": part, "unit": unit, "used": actual,
                "ceiling": ceilings[part], "capacity": capacity,
                "method": "elf-alloc-sections" if extension == "elf"
                          else "hex-program-words",
            })
    if require_all:
        check(len(rows) == 21,
              "final-candidate mode requires 21 of 21 images; measured %d" % len(rows))
        check(len(static_rows) == 12,
              "final-candidate mode requires static-data measurements from 12 AVR ELFs; measured %d"
              % len(static_rows))
    return rows, static_rows


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


def read_evidence_file(directory, name):
    path = directory / name
    check(path.exists() and path.is_file() and not path.is_symlink() and path.stat().st_size > 0,
          "final-candidate evidence is missing, empty, or not regular: %s" % path)
    if not path.exists() or not path.is_file() or path.is_symlink():
        return ""
    return path.read_text(encoding="utf-8", errors="replace")


CLASSIC_HWM = re.compile(
    r"^\s+stack HWM \[(attiny13a|attiny45|attiny85)\]: deepest SP=0x([0-9A-Fa-f]+), "
    r"used=([0-9]+) B, margin=([0-9]+) B free "
    r"\(SRAM 0x([0-9A-Fa-f]+)-0x([0-9A-Fa-f]+), ([0-9]+) B total; "
    r"static 0x([0-9A-Fa-f]+)-0x([0-9A-Fa-f]+), ([0-9]+) B\)$",
    re.MULTILINE)

# check_stack_depth_pic.sh emits this line from a single printf, so it survives
# the interleaving a parallel release build can produce between the multi-line
# report's separate writes.
PIC_STACK_PASS = r"^STACK-DEPTH PASS \[%s ([a-z0-9_]+)\]: ([0-9]+) \+ ([0-9]+) " \
                 r"reserve <= ([0-9]+) levels \(([0-9]+) spare\)$"


def check_classic_stack_evidence(classic, floor):
    """Nine self-consistent canary observations, each above the gate's floor."""
    observations = []
    rows = CLASSIC_HWM.findall(classic)
    check(len(rows) == 9,
          "test-long.log must contain exactly 9 Classic AVR stack HWM records; found %d"
          % len(rows))
    parts = [row[0] for row in rows]
    check({part: parts.count(part) for part in set(parts)}
          == {"attiny13a": 3, "attiny45": 3, "attiny85": 3},
          "test-long.log must contain three stack HWM records for each Classic AVR part")
    for row in rows:
        part = row[0]
        deepest_sp, sram_bot, sram_top, static_bot, static_top = (
            int(row[index], 16) for index in (1, 4, 5, 7, 8))
        used, sram_size, static_bytes = (int(row[index]) for index in (2, 6, 9))
        margin = int(row[3])
        label = "%s stack HWM record (deepest SP 0x%03X)" % (part, deepest_sp)
        # Each record carries the whole SRAM map it was derived from, so the
        # arithmetic closes on itself: a truncated or edited log fails here
        # without this file knowing what the figures ought to be.
        check(sram_size == sram_top - sram_bot + 1,
              "%s: %d B of SRAM is not 0x%03X-0x%03X"
              % (label, sram_size, sram_bot, sram_top))
        check(static_bot == sram_bot and static_bytes == static_top - sram_bot + 1,
              "%s: %d B of static data is not 0x%03X-0x%03X from the SRAM base "
              "0x%03X" % (label, static_bytes, static_bot, static_top, sram_bot))
        check(used == sram_top - deepest_sp + 1,
              "%s: %d B used does not reach ramend 0x%03X"
              % (label, used, sram_top))
        check(margin == max(0, deepest_sp - (sram_bot + static_bytes)),
              "%s: %d B free does not separate the stack from %d B of static data"
              % (label, margin, static_bytes))
        check(static_bytes + used + margin == sram_size,
              "%s: static + stack + free is %d B of a %d B device"
              % (label, static_bytes + used + margin, sram_size))
        check(margin >= floor,
              "%s: %d B free is below the canary gate's %d B floor"
              % (label, margin, floor))
        observations.append({
            "part": part, "deepest_sp": deepest_sp, "used": used,
            "free": margin, "static": static_bytes, "sram": sram_size,
            "floor": floor,
        })
    return observations


def check_final_evidence(directory, policy, floor):
    """Validate retained non-flash measurements from the release run logs.

    Returns the measurements as well as validating them, for the reason
    check_built_images does: these are the figures the release publishes, and
    the Classic AVR stack observations in particular survive nowhere else --
    they are read out of test-long.log, which staging does not retain.
    """
    classic_stack = check_classic_stack_evidence(
        read_evidence_file(directory, "test-long.log"), floor)

    xt = read_evidence_file(directory, "attiny202-test.log")
    frame = re.findall(
        r"^OK: ([0-9]+) fresh AVR-XT reports; all frames <= ([0-9]+) B$",
        xt, re.MULTILINE)
    check(frame == [(str(len(VARIANTS)), str(policy["XT_STACK_MAX_FRAME"]))],
          "attiny202-test.log must contain one %d-report, %d B frame-bound result"
          % (len(VARIANTS), policy["XT_STACK_MAX_FRAME"]))

    pic_data = read_evidence_file(directory, "pic12f675-qualification.log")
    data_rows = re.findall(
        r"^PIC12F675_DATA_BUDGET PASS variant=([a-z0-9_]+) used=([0-9]+) "
        r"limit=([0-9]+) capacity=([0-9]+)$", pic_data, re.MULTILINE)
    # Two builds report each variant: the qualified build and the
    # reproducibility rebuild.
    check(sorted(row[0] for row in data_rows) == sorted(VARIANTS * 2),
          "pic12f675-qualification.log must contain two Data-space records per "
          "variant (qualified and reproducibility builds); found %d records"
          % len(data_rows))
    data_used = {}
    for variant, used, limit, capacity in data_rows:
        check((int(limit), int(capacity)) == (policy["PIC12F675_DATA_LIMIT"],
                                              policy["PIC12F675_DATA_BYTES"]),
              "the PIC12F675 %s Data-space record reports a %s/%s B budget; the "
              "reviewed budget is %d/%d B"
              % (variant, limit, capacity, policy["PIC12F675_DATA_LIMIT"],
                 policy["PIC12F675_DATA_BYTES"]))
        check(0 < int(used) <= int(limit),
              "the PIC12F675 %s build reserves %s of %s permitted Data-space bytes"
              % (variant, used, limit))
        # Publishing one figure per variant requires the qualified build and the
        # reproducibility rebuild to have reserved the same Data space.  Checking
        # each record against the limit separately, as this gate used to, would
        # accept two builds that disagreed with each other.
        check(data_used.setdefault(variant, int(used)) == int(used),
              "the PIC12F675 %s builds disagree on Data space: %d B and %s B"
              % (variant, data_used.get(variant, -1), used))

    pic_stack = []
    for part, filename in (("PIC10F322", "pic10f322-test.log"),
                           ("PIC10F320", "pic10f320-test.log"),
                           ("PIC12F675", "pic12f675-qualification.log")):
        text = read_evidence_file(directory, filename)
        rows = re.findall(PIC_STACK_PASS % part, text, re.MULTILINE)
        check(sorted(row[0] for row in rows) == sorted(VARIANTS),
              "%s must contain one %s return-stack result for each of the three "
              "variants; found %d" % (filename, part, len(rows)))
        reserve_policy = policy["%s_STACK_RESERVE" % part]
        for variant, peak, reserve, depth, spare in rows:
            label = "%s %s return-stack result" % (part, variant)
            check(int(reserve) == reserve_policy,
                  "%s: %s levels held in reserve; the reviewed reserve is %d"
                  % (label, reserve, reserve_policy))
            check(int(depth) == policy["PIC10F320_RETURN_STACK_LIMIT"],
                  "%s: the device reports %s hardware levels; the reviewed bound "
                  "is %d" % (label, depth,
                             policy["PIC10F320_RETURN_STACK_LIMIT"]))
            check(int(peak) > 0 and int(peak) + int(reserve) + int(spare) == int(depth),
                  "%s: peak %s + reserve %s + spare %s is not the %s-level "
                  "hardware stack" % (label, peak, reserve, spare, depth))
            pic_stack.append({
                "part": part.lower(), "variant": variant, "peak": int(peak),
                "reserve": int(reserve), "spare": int(spare), "depth": int(depth),
            })
    return {
        "classic_stack": classic_stack,
        # The log states "all frames <= N B", which is the reviewed ceiling the
        # reports were checked against -- not a measured maximum.  No largest
        # frame is recorded anywhere, so none is published: a "frame_max" here
        # would be this gate inventing a measurement, and a per-frame static
        # bound is not a whole-path high-water figure in any case.
        "xt_frame": {"reports": int(frame[0][0]),
                     "ceiling": policy["XT_STACK_MAX_FRAME"]} if frame else None,
        "pic_data": [{"part": "pic12f675", "variant": variant,
                      "used": data_used[variant],
                      "ceiling": policy["PIC12F675_DATA_LIMIT"],
                      "capacity": policy["PIC12F675_DATA_BYTES"]}
                     for variant in sorted(data_used)],
        "pic_data_records": len(data_rows),
        "pic_stack": pic_stack,
    }


def static_by_part(static_rows):
    """One reviewed static-RAM figure per AVR part, or None if a part disagrees.

    Every variant of a part allocates the same statics -- the shared core's
    context, its check word and the ISR handshake -- so one figure describes the
    part.  That is checked rather than assumed: aggregating here, in the gate
    that measured the images, keeps the published per-part row backed by a
    record instead of by a renderer's arithmetic.
    """
    parts = {}
    for row in static_rows:
        parts.setdefault(row["part"], []).append(row)
    aggregate = {}
    for part in sorted(parts):
        values = {row["static"] for row in parts[part]}
        check(len(values) == 1,
              "the %s images do not agree on static data: %s B"
              % (part, ", ".join(str(value) for value in sorted(values))))
        if len(values) != 1:
            continue
        aggregate[part] = {"part": part, "static": values.pop(),
                           "ceiling": parts[part][0]["ceiling"],
                           "images": len(parts[part])}
    return aggregate


def check_static_agreement(static_parts, classic_stack):
    """Two independent measurements of the same statics must agree.

    The ELF walker sums allocated data-space sections; the canary gate derives
    its static region from the simulated device's own symbol table.  Nothing
    compared them before, so the release could have published either.  A part
    whose variants ever stop agreeing fails in static_by_part above, and a
    divergence here says the two oracles disagree -- which is the only reason to
    keep both.
    """
    for observation in classic_stack:
        part = observation["part"]
        if part not in static_parts:
            continue
        check(static_parts[part]["static"] == observation["static"],
              "the %s ELF allocates %d B of static data but its canary gate "
              "measured %d B" % (part, static_parts[part]["static"],
                                 observation["static"]))


def deepest_per_part(classic_stack):
    """The worst of each Classic part's stack observations.

    The canary line does not name the variant it came from, so a per-variant row
    would have to invent an attribution the evidence does not carry.  The
    deepest observation is the figure that bounds the part, and because used,
    free and the deepest SP all come from that one record, the published row
    still closes on its own arithmetic.
    """
    worst = {}
    for observation in classic_stack:
        part = observation["part"]
        if part not in worst or observation["used"] > worst[part]["used"]:
            worst[part] = dict(observation, observations=0)
    for observation in classic_stack:
        worst[observation["part"]]["observations"] += 1
    return worst


def emit(record, fields):
    print("%s format=1 %s"
          % (record, " ".join("%s=%s" % pair for pair in fields)))


def emit_records(image_rows, static_parts, evidence):
    """Print every measured figure the release publishes, in a fixed order."""
    emitted = 0
    for row in sorted(image_rows, key=lambda row: row["image"]):
        emit("RESOURCE_IMAGE", (
            ("image", row["image"]), ("part", row["part"]),
            ("unit", row["unit"]), ("used", row["used"]),
            ("ceiling", row["ceiling"]), ("capacity", row["capacity"]),
            ("free", row["ceiling"] - row["used"]), ("method", row["method"])))
        emitted += 1
    for part in sorted(static_parts):
        row = static_parts[part]
        emit("RESOURCE_STATIC", (
            ("part", part), ("unit", "bytes"), ("static", row["static"]),
            ("ceiling", row["ceiling"]),
            ("free", row["ceiling"] - row["static"]),
            ("images", row["images"]), ("method", "elf-alloc-sections")))
        emitted += 1
    for part in sorted(evidence["classic_stack_worst"]):
        row = evidence["classic_stack_worst"][part]
        emit("RESOURCE_STACK", (
            ("part", part), ("unit", "bytes"),
            ("method", "simavr-canary-high-water"),
            ("observations", row["observations"]),
            ("deepest_sp", "0x%03X" % row["deepest_sp"]),
            ("used", row["used"]), ("free", row["free"]),
            ("static", row["static"]), ("sram", row["sram"]),
            ("floor", row["floor"])))
        emitted += 1
    frame = evidence["xt_frame"]
    if frame is not None:
        # method= says what this figure is, because it is the one resource
        # record on the page that is not a measurement of a run: it is a static
        # per-frame bound from the compiler, and reading it as a whole-path
        # high-water would overstate what the release checked.
        emit("RESOURCE_STACK_BOUND", (
            ("part", "attiny202"), ("unit", "bytes"),
            ("method", "gcc-stack-usage-per-frame"),
            ("reports", frame["reports"]), ("ceiling", frame["ceiling"])))
        emitted += 1
    for row in evidence["pic_data"]:
        emit("RESOURCE_DATA", (
            ("part", row["part"]), ("variant", row["variant"]),
            ("unit", "bytes"), ("method", "xc8-data-budget"),
            ("used", row["used"]), ("ceiling", row["ceiling"]),
            ("capacity", row["capacity"]),
            ("free", row["ceiling"] - row["used"])))
        emitted += 1
    for row in sorted(evidence["pic_stack"],
                      key=lambda row: (row["part"], row["variant"])):
        emit("RESOURCE_RETURN_STACK", (
            ("part", row["part"]), ("variant", row["variant"]),
            ("unit", "levels"), ("method", "gpsim-peak-depth"),
            ("peak", row["peak"]), ("reserve", row["reserve"]),
            ("spare", row["spare"]), ("depth", row["depth"])))
        emitted += 1
    return emitted


def report(image_rows=None, require_all=False, source_commit=None,
           static_parts=None, evidence=None):
    for message in failures:
        print("FAIL: %s" % message, file=sys.stderr)
    measured = None if image_rows is None else len(image_rows)
    if measured is None:
        print("resource tables: %d checks, %d failures (no image measured: the "
              "reviewed ceilings must parse first)" % (checks, len(failures)))
    else:
        qualifier = "; complete candidate required" if require_all else ""
        print("resource tables: %d checks, %d failures "
              "(%d of 21 canonical images measured%s)"
              % (checks, len(failures), measured, qualifier))
    if require_all and not failures:
        emitted = emit_records(image_rows, static_parts, evidence)
        print("RESOURCE_TABLES_RESULT format=1 status=pass source_commit=%s "
              "images=%d avr_static=%d classic_stack=%d pic_data=%d pic_stack=%d "
              "records=%d"
              % (source_commit, measured, evidence["avr_static"],
                 len(evidence["classic_stack"]), evidence["pic_data_records"],
                 len(evidence["pic_stack"]), emitted))
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
    policy = parse_policy()
    floor = parse_classic_stack_floor()
    # Nothing below can be judged without the ceilings to judge it against, so an
    # unreadable policy is reported as that rather than as a traceback.
    if policy is None or floor is None:
        return report()
    ceilings = flash_ceilings(policy)
    check_policy(policy, ceilings)
    image_rows, static_rows = check_built_images(
        policy, ceilings, require_all=arguments.require_all_images)
    static_parts = static_by_part(static_rows)
    evidence = None
    if arguments.require_all_images and arguments.evidence_dir is not None:
        evidence = check_final_evidence(
            arguments.evidence_dir.resolve(), policy, floor)
        check_static_agreement(static_parts, evidence["classic_stack"])
    if arguments.require_all_images and evidence is None:
        evidence = {"classic_stack": [], "xt_frame": None, "pic_data": [],
                    "pic_data_records": 0, "pic_stack": []}
    if evidence is not None:
        evidence["avr_static"] = len(static_rows)
        evidence["classic_stack_worst"] = deepest_per_part(
            evidence["classic_stack"])
    return report(image_rows, require_all=arguments.require_all_images,
                  source_commit=arguments.source_commit,
                  static_parts=static_parts, evidence=evidence)


if __name__ == "__main__":
    sys.exit(main())
