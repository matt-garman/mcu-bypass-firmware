#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
"""Tool-independent regression for strict resource-evidence handling.

Every figure below is arbitrary and deliberately unlike the production matrix.
The checker reads its ceilings from the Makefile and its images from a build
tree, so a fixture can state whatever policy it likes; restating the real one
here would reintroduce, in a test, the duplication the documents were relieved
of, and would make this regression fail on a firmware size change it does not
test.
"""

import os
import struct
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CHECKER = ROOT / "test" / "test_resource_tables.py"
SOURCE_COMMIT = "a" * 40
VARIANTS = ("cd4053_simple", "cd4053_with_mute", "tq2_l2_5v_relay")

# An arbitrary reviewed policy, coherent with the datasheet capacities the
# checker holds and unlike the Makefile's own in every overridable field.
POLICY = {
    "ATTINY13A_FLASH_BYTES": 1024,
    "ATTINY13A_FLASH_BUDGET": 75,
    "XT_FLASH_BYTES": 1500,
    "XT_SRAM_BYTES": 128,
    "XT_STATIC_RAM_LIMIT": 12,
    "XT_STACK_MAX_FRAME": 24,
    "PIC10F322_FLASH_WORDS": 400,
    "PIC10F322_STACK_RESERVE": 1,
    "PIC10F320_FLASH_WORDS": 200,
    "PIC10F320_STACK_RESERVE": 1,
    "PIC10F320_RETURN_STACK_LIMIT": 6,
    "PIC12F675_FLASH_WORDS": 900,
    "PIC12F675_DATA_BYTES": 64,
    "PIC12F675_DATA_LIMIT": 50,
    "PIC12F675_STACK_RESERVE": 1,
}
STACK_FLOOR = 6
STATIC_BYTES = 4

# Arbitrary image sizes, every one inside the fixture policy above.
FLASH = {
    "attiny13a": (700, 720, 710),
    "attiny45": (700, 720, 710),
    "attiny85": (700, 720, 710),
    "attiny202": (1200, 1220, 1210),
    "pic10f322": (300, 320, 310),
    "pic10f320": (150, 170, 160),
    "pic12f675": (600, 620, 610),
}
# What each part is actually judged against under the fixture policy above,
# derived here independently of the checker: the ATtiny13a's truncated
# percentage budget, the linker's device size for the tinyx5 parts the
# percentage gate does not bind, and the stated ceiling for everything else.
FLASH_CEILINGS = {
    "attiny13a": (POLICY["ATTINY13A_FLASH_BYTES"]
                  * POLICY["ATTINY13A_FLASH_BUDGET"] // 100),
    "attiny45": 4096,
    "attiny85": 8192,
    "attiny202": POLICY["XT_FLASH_BYTES"],
    "pic10f322": POLICY["PIC10F322_FLASH_WORDS"],
    "pic10f320": POLICY["PIC10F320_FLASH_WORDS"],
    "pic12f675": POLICY["PIC12F675_FLASH_WORDS"],
}
BUILD_DIRS = {
    "attiny13a": ("build_avr_classic", "elf"),
    "attiny45": ("build_avr_classic", "elf"),
    "attiny85": ("build_avr_classic", "elf"),
    "attiny202": ("build_avr_xt", "elf"),
    "pic10f322": ("build_pic10f322", "hex"),
    "pic10f320": ("build_pic10f320", "hex"),
    "pic12f675": ("build_pic12f675", "hex"),
}
# SRAM base and size per Classic AVR part, used to synthesize canary records
# whose arithmetic closes the way the simulator's own report does.
CLASSIC_SRAM = {"attiny13a": (0x060, 64), "attiny45": (0x060, 256),
                "attiny85": (0x060, 512)}
CLASSIC_MARGINS = {"attiny13a": (20, 18, 19), "attiny45": (100, 98, 99),
                   "attiny85": (200, 198, 199)}

checks = 0


def fail(message):
    print("FAIL: %s" % message, file=sys.stderr)
    raise SystemExit(1)


def check(condition, message):
    global checks
    checks += 1
    if not condition:
        fail(message)


def run(fixture, *extra):
    return subprocess.run(
        [sys.executable, str(CHECKER), "--root", str(fixture), *extra],
        text=True, capture_output=True, check=False)


def write_policy(fixture, policy=None, floor=STACK_FLOOR):
    """A Makefile and canary gate carrying only what the checker reads."""
    values = POLICY if policy is None else policy
    lines = ["# Fixture policy for the resource-evidence contract regression."]
    for name, value in values.items():
        lines.append("%s ?= %d" % (name, value))
    (fixture / "Makefile").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (fixture / "test" / "avr").mkdir(parents=True, exist_ok=True)
    (fixture / "test" / "avr" / "test_sim.c").write_text(
        "    CHECK(margin_bytes >= %du,\n"
        "          \"stack leaves only %%u free bytes\", margin_bytes);\n" % floor,
        encoding="utf-8")


def write_elf(path, program_bytes, static_bytes=STATIC_BYTES):
    section_offset = 52
    data = bytearray(section_offset + 3 * 40)
    data[:4] = b"\x7fELF"
    data[4] = 1
    data[5] = 1
    struct.pack_into("<I", data, 0x20, section_offset)
    struct.pack_into("<HH", data, 0x2E, 40, 3)
    struct.pack_into("<III", data, section_offset + 40 + 4, 1, 2, 0)
    struct.pack_into("<I", data, section_offset + 40 + 0x14, program_bytes)
    struct.pack_into("<III", data, section_offset + 80 + 4, 8, 2, 0x800060)
    struct.pack_into("<I", data, section_offset + 80 + 0x14, static_bytes)
    path.write_bytes(data)


def ihex_record(address, kind, payload):
    record = bytes((len(payload), address >> 8, address & 0xFF, kind)) + payload
    checksum = (-sum(record)) & 0xFF
    return ":" + (record + bytes((checksum,))).hex().upper()


def write_hex(path, program_words):
    payload = bytes(program_words * 2)
    lines = []
    for address in range(0, len(payload), 16):
        lines.append(ihex_record(address, 0, payload[address:address + 16]))
    lines.append(ihex_record(0, 1, b""))
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def image_path(fixture, part, variant):
    directory_name, extension = BUILD_DIRS[part]
    directory = fixture / directory_name
    directory.mkdir(exist_ok=True)
    return directory / ("bypass-%s-%s.%s" % (part, variant, extension))


def write_image(fixture, part, variant, size):
    path = image_path(fixture, part, variant)
    if BUILD_DIRS[part][1] == "elf":
        write_elf(path, size)
    else:
        write_hex(path, size)
    return path


def create_images(fixture):
    for part, values in FLASH.items():
        for variant, size in zip(VARIANTS, values):
            write_image(fixture, part, variant, size)


def classic_hwm_line(part, margin):
    """One canary record whose SRAM map, use, and margin agree with each other."""
    sram_bot, sram_size = CLASSIC_SRAM[part]
    sram_top = sram_bot + sram_size - 1
    deepest_sp = sram_bot + STATIC_BYTES + margin
    used = sram_top - deepest_sp + 1
    return ("  stack HWM [%s]: deepest SP=0x%03X, used=%u B, margin=%u B free "
            "(SRAM 0x%03X-0x%03X, %u B total; static 0x%03X-0x%03X, %u B)"
            % (part, deepest_sp, used, margin, sram_bot, sram_top, sram_size,
               sram_bot, sram_bot + STATIC_BYTES - 1, STATIC_BYTES))


def create_evidence(evidence):
    evidence.mkdir(exist_ok=True)
    (evidence / "test-long.log").write_text(
        "\n".join(classic_hwm_line(part, margin)
                  for part in CLASSIC_SRAM
                  for margin in CLASSIC_MARGINS[part]) + "\n",
        encoding="utf-8")
    (evidence / "attiny202-test.log").write_text(
        "OK: %d fresh AVR-XT reports; all frames <= %d B\n"
        % (len(VARIANTS), POLICY["XT_STACK_MAX_FRAME"]), encoding="utf-8")
    peaks = {"PIC10F322": (2, 2, 3), "PIC10F320": (2, 2, 2),
             "PIC12F675": (2, 2, 4)}
    files = {"PIC10F322": "pic10f322-test.log",
             "PIC10F320": "pic10f320-test.log",
             "PIC12F675": "pic12f675-qualification.log"}
    for part, depths in peaks.items():
        lines = []
        if part == "PIC12F675":
            for _build in range(2):
                lines.extend(
                    "PIC12F675_DATA_BUDGET PASS variant=%s used=30 limit=%d "
                    "capacity=%d" % (variant, POLICY["PIC12F675_DATA_LIMIT"],
                                     POLICY["PIC12F675_DATA_BYTES"])
                    for variant in VARIANTS)
        reserve = POLICY["%s_STACK_RESERVE" % part]
        depth = POLICY["PIC10F320_RETURN_STACK_LIMIT"]
        for variant, peak in zip(VARIANTS, depths):
            lines.append("PIC hardware-stack depth [%s %s]" % (part, variant))
            lines.append("  measured peak : %d level(s)" % peak)
            lines.append("STACK-DEPTH PASS [%s %s]: %d + %d reserve <= %d "
                         "levels (%d spare)"
                         % (part, variant, peak, reserve, depth,
                            depth - peak - reserve))
        (evidence / files[part]).write_text(
            "\n".join(lines) + "\n", encoding="utf-8")


def strict_arguments(evidence):
    return ("--require-all-images", "--evidence-dir", str(evidence),
            "--source-commit", SOURCE_COMMIT)


def emitted_records(stdout, kind):
    """Every emitted record of one kind, parsed into its key=value fields."""
    found = []
    for line in stdout.splitlines():
        if line.startswith(kind + " "):
            fields = line.split()[1:]
            if any(field.count("=") != 1 for field in fields):
                fail("%s emitted a malformed field" % kind)
            pairs = [field.split("=", 1) for field in fields]
            keys = [pair[0] for pair in pairs]
            if len(keys) != len(set(keys)):
                fail("%s emitted a duplicate field" % kind)
            found.append(dict(pairs))
    return found


# The record counts a complete candidate must emit: one per canonical image,
# one per AVR part's agreed static allocation, one per Classic part's deepest
# observation, the AVR-XT frame bound, one per PIC12F675 variant's Data space,
# and one per PIC return-stack witness.
RECORD_COUNTS = (("RESOURCE_IMAGE", 21), ("RESOURCE_STATIC", 4),
                 ("RESOURCE_STACK", 3), ("RESOURCE_STACK_BOUND", 1),
                 ("RESOURCE_DATA", 3), ("RESOURCE_RETURN_STACK", 9))

RECORD_SCHEMAS = {
    "RESOURCE_IMAGE": {"format", "image", "part", "unit", "used",
                       "ceiling", "capacity", "free", "method"},
    "RESOURCE_STATIC": {"format", "part", "unit", "static", "ceiling",
                        "free", "images", "method"},
    "RESOURCE_STACK": {"format", "part", "unit", "method",
                       "observations", "deepest_sp", "used", "free",
                       "static", "sram", "floor"},
    "RESOURCE_STACK_BOUND": {"format", "part", "unit", "method",
                             "reports", "ceiling"},
    "RESOURCE_DATA": {"format", "part", "variant", "unit", "method",
                      "used", "ceiling", "capacity", "free"},
    "RESOURCE_RETURN_STACK": {"format", "part", "variant", "unit",
                              "method", "peak", "reserve", "spare", "depth"},
    "RESOURCE_TABLES_RESULT": {"format", "status", "source_commit", "images",
                               "avr_static", "classic_stack", "pic_data",
                               "pic_stack", "records"},
}

EXPECTED_IDENTITIES = {
    "RESOURCE_IMAGE": Counter(
        ("bypass-%s-%s.hex" % (part, variant), part)
        for part in FLASH for variant in VARIANTS),
    "RESOURCE_STATIC": Counter((part,) for part in
                               ("attiny13a", "attiny45", "attiny85", "attiny202")),
    "RESOURCE_STACK": Counter((part,) for part in
                              ("attiny13a", "attiny45", "attiny85")),
    "RESOURCE_STACK_BOUND": Counter((("attiny202",),)),
    "RESOURCE_DATA": Counter(("pic12f675", variant) for variant in VARIANTS),
    "RESOURCE_RETURN_STACK": Counter(
        (part, variant)
        for part in ("pic10f322", "pic10f320", "pic12f675")
        for variant in VARIANTS),
}


def record_identity(kind, row):
    if kind == "RESOURCE_IMAGE":
        return row["image"], row["part"]
    if kind in ("RESOURCE_STATIC", "RESOURCE_STACK", "RESOURCE_STACK_BOUND"):
        return row["part"],
    return row["part"], row["variant"]


def main():
    temp_parent = Path(os.environ.get("TMPDIR", str(Path.home())))
    with tempfile.TemporaryDirectory(prefix="resource-contract-",
                                     dir=str(temp_parent)) as temporary:
        fixture = Path(temporary)
        write_policy(fixture)

        result = run(fixture)
        check(result.returncode == 0 and "0 of 21 canonical images measured" in result.stdout,
              "documentation mode did not permit and disclose a zero-image run")

        evidence = fixture / "evidence"
        create_evidence(evidence)
        result = run(fixture, *strict_arguments(evidence))
        check(result.returncode != 0 and "requires 21 of 21 images" in result.stderr,
              "strict mode accepted a zero-image candidate")

        create_images(fixture)
        result = run(fixture, *strict_arguments(evidence))
        machine = ("RESOURCE_TABLES_RESULT format=1 status=pass "
                   "source_commit=%s images=21 avr_static=12 classic_stack=9 "
                   "pic_data=6 pic_stack=9 records=41" % SOURCE_COMMIT)
        check(result.returncode == 0 and machine in result.stdout,
              "strict mode rejected a complete candidate or omitted its machine record")

        # The published figures, not only their count.  Each record has to carry
        # the measurement this fixture built into the image, so a checker that
        # emitted plausible-looking numbers from anywhere else fails here.
        records = {}
        for kind, expected in RECORD_COUNTS:
            found = emitted_records(result.stdout, kind)
            records[kind] = found
            check(len(found) == expected,
                  "a complete candidate emitted %d %s records, expected %d"
                  % (len(found), kind, expected))
            check(all(set(row) == RECORD_SCHEMAS[kind] for row in found),
                  "%s did not emit its exact closed field schema" % kind)
            identities = Counter(record_identity(kind, row) for row in found)
            check(identities == EXPECTED_IDENTITIES[kind],
                  "%s did not emit the exact reviewed identity multiset" % kind)
        results = emitted_records(result.stdout, "RESOURCE_TABLES_RESULT")
        check(len(results) == 1
              and set(results[0]) == RECORD_SCHEMAS["RESOURCE_TABLES_RESULT"],
              "the terminal result did not emit its exact singleton schema")
        ceilings = FLASH_CEILINGS
        for row in records["RESOURCE_IMAGE"]:
            part, variant = row["part"], row["image"].split("-")[2][:-4]
            used = FLASH[part][VARIANTS.index(variant)]
            check(int(row["used"]) == used,
                  "the %s record reports %s %s; the fixture image is %d"
                  % (row["image"], row["used"], row["unit"], used))
            check(int(row["ceiling"]) == ceilings[part],
                  "the %s record reports a ceiling of %s; the fixture policy "
                  "sets %d" % (row["image"], row["ceiling"], ceilings[part]))
            check(int(row["free"]) == int(row["ceiling"]) - int(row["used"]),
                  "the %s record's free figure does not close on its own "
                  "ceiling and use" % row["image"])
            check(0 < int(row["used"]) <= int(row["ceiling"]) <= int(row["capacity"]),
                  "the %s record does not order use, ceiling and capacity"
                  % row["image"])
        for row in records["RESOURCE_STATIC"]:
            check(int(row["static"]) == STATIC_BYTES and int(row["images"]) == 3,
                  "the %s static record reports %s B from %s images; the "
                  "fixture allocates %d B in each of 3"
                  % (row["part"], row["static"], row["images"], STATIC_BYTES))
        for row in records["RESOURCE_STACK"]:
            check(int(row["static"]) + int(row["used"]) + int(row["free"])
                  == int(row["sram"]),
                  "the %s stack record does not account for the whole device "
                  "SRAM" % row["part"])
            check(int(row["free"]) == min(CLASSIC_MARGINS[row["part"]]),
                  "the %s stack record publishes %s B free; the deepest of its "
                  "observations left %d"
                  % (row["part"], row["free"], min(CLASSIC_MARGINS[row["part"]])))
        # The AVR-XT figure is a compiler bound, not a run measurement, so the
        # record must state the ceiling it checked and claim no high-water use.
        bound = records["RESOURCE_STACK_BOUND"][0]
        check(bound["method"] == "gcc-stack-usage-per-frame"
              and int(bound["ceiling"]) == POLICY["XT_STACK_MAX_FRAME"]
              and "used" not in bound and "peak" not in bound,
              "the AVR-XT frame-bound record does not name its method, or "
              "reports a high-water figure the evidence does not contain")

        victim = image_path(fixture, "pic10f320", "cd4053_simple")
        victim.unlink()
        result = run(fixture, *strict_arguments(evidence))
        check(result.returncode != 0 and "required final-candidate image is missing" in result.stderr,
              "strict mode accepted a partial image set")
        write_image(fixture, "pic10f320", "cd4053_simple",
                    FLASH["pic10f320"][0])

        result = run(fixture, "--require-all-images", "--evidence-dir", str(evidence),
                     "--source-commit", "not-a-commit")
        check(result.returncode != 0 and "full lowercase SHA-1" in result.stderr,
              "strict mode accepted an invalid source identity")

        # An image over its reviewed ceiling is the failure this gate exists for,
        # and it must fail in the ordinary mode, without release evidence.
        write_image(fixture, "pic10f322", "cd4053_with_mute",
                    POLICY["PIC10F322_FLASH_WORDS"] + 1)
        result = run(fixture)
        check(result.returncode != 0 and "the reviewed ceiling is" in result.stderr,
              "an image above its reviewed ceiling was accepted")
        write_image(fixture, "pic10f322", "cd4053_with_mute", FLASH["pic10f322"][1])

        # Malformed tool output is rejected rather than measured: flip one
        # checksum nibble in a data record and the whole image is unusable.
        corrupt = image_path(fixture, "pic12f675", "tq2_l2_5v_relay")
        records = corrupt.read_text(encoding="ascii").splitlines()
        digit = records[0][-1]
        records[0] = records[0][:-1] + ("0" if digit != "0" else "1")
        corrupt.write_text("\n".join(records) + "\n", encoding="ascii")
        result = run(fixture)
        check(result.returncode != 0
              and "record checksum does not sum to zero" in result.stderr,
              "a malformed Intel HEX was accepted as a measurement")
        write_image(fixture, "pic12f675", "tq2_l2_5v_relay", FLASH["pic12f675"][2])

        # A ceiling wider than the silicon is the defect the Makefile records
        # from its own history: one shared flash-word budget silently gated the
        # half-size part against the larger part's capacity.
        loosened = dict(POLICY, PIC10F320_FLASH_WORDS=512)
        write_policy(fixture, loosened)
        result = run(fixture)
        check(result.returncode != 0 and "the part holds" in result.stderr,
              "a reviewed ceiling wider than the device's capacity was accepted")

        incomplete = dict(POLICY)
        del incomplete["PIC12F675_DATA_LIMIT"]
        write_policy(fixture, incomplete)
        result = run(fixture)
        check(result.returncode != 0
              and "exactly once as a decimal constant" in result.stderr,
              "a missing reviewed ceiling was treated as absent policy")
        write_policy(fixture)

        policy_file = fixture / "Makefile"
        policy_text = policy_file.read_text(encoding="utf-8")
        policy_file.write_text(
            policy_text + "PIC12F675_DATA_LIMIT ?= 49\n", encoding="utf-8")
        result = run(fixture)
        check(result.returncode != 0 and "found 2 assignments" in result.stderr,
              "duplicate decimal ceiling assignments were accepted")

        policy_file.write_text(
            policy_text
            + "PIC12F675_DATA_LIMIT := $(PIC12F675_DATA_BYTES)\n",
            encoding="utf-8")
        result = run(fixture)
        check(result.returncode != 0 and "found 2 assignments" in result.stderr,
              "a computed reassignment overrode the reviewed decimal ceiling")
        policy_file.write_text(policy_text, encoding="utf-8")

        # Retained evidence is checked against its own arithmetic, so an edited
        # figure fails without this file knowing the true one.
        log = evidence / "test-long.log"
        text = log.read_text(encoding="utf-8")
        edited = text.replace("margin=20 B free", "margin=21 B free", 1)
        check(edited != text, "Classic AVR canary fixture anchor was not found")
        log.write_text(edited, encoding="utf-8")
        result = run(fixture, *strict_arguments(evidence))
        check(result.returncode != 0
              and "does not separate the stack from" in result.stderr,
              "an internally inconsistent canary record was accepted")
        log.write_text(text, encoding="utf-8")

        # The same for the return-stack witness: peak, reserve and spare must
        # account for the whole hardware stack.
        pic_log = evidence / "pic10f322-test.log"
        text = pic_log.read_text(encoding="utf-8")
        edited = text.replace("<= %d levels (3 spare)"
                              % POLICY["PIC10F320_RETURN_STACK_LIMIT"],
                              "<= %d levels (4 spare)"
                              % POLICY["PIC10F320_RETURN_STACK_LIMIT"], 1)
        check(edited != text, "PIC return-stack fixture anchor was not found")
        pic_log.write_text(edited, encoding="utf-8")
        result = run(fixture, *strict_arguments(evidence))
        check(result.returncode != 0
              and "is not the %d-level hardware stack"
              % POLICY["PIC10F320_RETURN_STACK_LIMIT"] in result.stderr,
              "an internally inconsistent return-stack record was accepted")
        pic_log.write_text(text, encoding="utf-8")

        # One published static-RAM figure per part is only honest if the part's
        # variants agree.  Give one variant a different allocation and the
        # aggregate must fail rather than pick a winner -- and a failing run
        # must publish nothing, because these records are evidence of a pass.
        write_elf(image_path(fixture, "attiny45", "cd4053_simple"),
                  FLASH["attiny45"][0], STATIC_BYTES + 1)
        result = run(fixture, *strict_arguments(evidence))
        check(result.returncode != 0
              and "do not agree on static data" in result.stderr,
              "one part's variants were allowed to disagree on static data")
        check(not emitted_records(result.stdout, "RESOURCE_IMAGE"),
              "a failing candidate still published resource records")

        # Both AVR measurements describe the same statics: the ELF walker sums
        # allocated data-space sections, the canary gate reads the simulated
        # device's symbol table.  Move all three variants together and they
        # agree with each other while disagreeing with the simulator.
        for variant, size in zip(VARIANTS, FLASH["attiny45"]):
            write_elf(image_path(fixture, "attiny45", variant), size,
                      STATIC_BYTES + 1)
        result = run(fixture, *strict_arguments(evidence))
        check(result.returncode != 0
              and "but its canary gate measured" in result.stderr,
              "the ELF and canary static-data oracles were allowed to disagree")
        for variant, size in zip(VARIANTS, FLASH["attiny45"]):
            write_elf(image_path(fixture, "attiny45", variant), size)

        # The qualified build and the reproducibility rebuild each report the
        # PIC12F675's Data space.  One figure per variant is published, so the
        # two builds must have reserved the same bytes; checking each against
        # the limit alone would accept builds that disagreed with each other.
        data_log = evidence / "pic12f675-qualification.log"
        text = data_log.read_text(encoding="utf-8")
        edited = text.replace("variant=cd4053_simple used=30",
                              "variant=cd4053_simple used=31", 1)
        check(edited != text, "PIC12F675 Data-space fixture anchor was not found")
        data_log.write_text(edited, encoding="utf-8")
        result = run(fixture, *strict_arguments(evidence))
        check(result.returncode != 0
              and "builds disagree on Data space" in result.stderr,
              "two PIC12F675 builds were allowed to disagree on Data space")
        data_log.write_text(text, encoding="utf-8")

        result = run(fixture, *strict_arguments(evidence))
        check(result.returncode == 0 and machine in result.stdout,
              "the fixture did not return to a passing final-candidate state")

    print("resource-table contract: %d checks, 0 failures" % checks)
    return 0


if __name__ == "__main__":
    sys.exit(main())
