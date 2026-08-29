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
                   "pic_data=6 pic_stack=9" % SOURCE_COMMIT)
        check(result.returncode == 0 and machine in result.stdout,
              "strict mode rejected a complete candidate or omitted its machine record")

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

        result = run(fixture, *strict_arguments(evidence))
        check(result.returncode == 0 and machine in result.stdout,
              "the fixture did not return to a passing final-candidate state")

    print("resource-table contract: %d checks, 0 failures" % checks)
    return 0


if __name__ == "__main__":
    sys.exit(main())
