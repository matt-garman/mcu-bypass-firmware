#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
"""Tool-independent regression for strict resource-evidence handling."""

import os
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CHECKER = ROOT / "test" / "test_resource_tables.py"
SOURCE_COMMIT = "a" * 40
VARIANTS = ("cd4053_simple", "cd4053_with_mute", "tq2_l2_5v_relay")
FLASH = {
    "attiny13a": (838, 878, 868),
    "attiny45": (864, 904, 894),
    "attiny85": (864, 904, 894),
    "attiny202": (968, 1008, 1040),
    "pic10f322": (476, 502, 493),
    "pic10f320": (220, 241, 242),
    "pic12f675": (548, 574, 585),
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


def write_elf(path, program_bytes, static_bytes=5):
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


def create_images(fixture):
    for part, values in FLASH.items():
        directory_name, extension = BUILD_DIRS[part]
        directory = fixture / directory_name
        directory.mkdir(exist_ok=True)
        for variant, size in zip(VARIANTS, values):
            path = directory / ("bypass-%s-%s.%s" % (part, variant, extension))
            if extension == "elf":
                write_elf(path, size)
            else:
                write_hex(path, size)


def create_evidence(evidence):
    evidence.mkdir()
    hwm_lines = []
    values = (31, 32, 33)
    sram_bytes = {"attiny13a": 64, "attiny45": 256, "attiny85": 512}
    for part in ("attiny13a", "attiny45", "attiny85"):
        for index, _variant in enumerate(VARIANTS):
            used = values[index]
            margin = sram_bytes[part] - 5 - used
            hwm_lines.append(
                "  stack HWM [%s]: deepest SP=0x080, used=%d B, margin=%d B free "
                "(SRAM 0x060-0x09F, %d B total; static 0x060-0x064, 5 B)"
                % (part, used, margin, sram_bytes[part]))
    (evidence / "test-long.log").write_text(
        "\n".join(hwm_lines) + "\n", encoding="utf-8")
    (evidence / "attiny202-test.log").write_text(
        "OK: 3 fresh AVR-XT reports; all frames <= 32 B\n", encoding="utf-8")
    stack = {
        "PIC10F322": (3, 3, 4),
        "PIC10F320": (3, 3, 3),
        "PIC12F675": (3, 3, 4),
    }
    files = {
        "PIC10F322": "pic10f322-test.log",
        "PIC10F320": "pic10f320-test.log",
        "PIC12F675": "pic12f675-qualification.log",
    }
    for part, depths in stack.items():
        lines = []
        if part == "PIC12F675":
            for _build in range(2):
                lines.extend(
                    "PIC12F675_DATA_BUDGET PASS variant=%s used=40 limit=48 capacity=64"
                    % variant for variant in VARIANTS)
        for variant, depth in zip(VARIANTS, depths):
            lines.append("PIC hardware-stack depth [%s %s]" % (part, variant))
            lines.append("  measured peak : %d level(s)" % depth)
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
        (fixture / "docs").mkdir()
        for relative in ("DESIGN_DOCUMENTATION.adoc", "CHANGELOG.md",
                         "docs/context_seu_detection.md",
                         "docs/pic12f675_feasibility.md",
                         "docs/pic10f320_validation.md"):
            destination = fixture / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, destination)

        result = run(fixture)
        check(result.returncode == 0 and "0 of 21 documented images measured" in result.stdout,
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

        victim = fixture / "build_pic10f320" / "bypass-pic10f320-cd4053_simple.hex"
        victim.unlink()
        result = run(fixture, *strict_arguments(evidence))
        check(result.returncode != 0 and "required final-candidate image is missing" in result.stderr,
              "strict mode accepted a partial image set")
        write_hex(victim, FLASH["pic10f320"][0])

        result = run(fixture, "--require-all-images", "--evidence-dir", str(evidence),
                     "--source-commit", "not-a-commit")
        check(result.returncode != 0 and "full lowercase SHA-1" in result.stderr,
              "strict mode accepted an invalid source identity")

        validation = fixture / "docs" / "pic10f320_validation.md"
        text = validation.read_text(encoding="utf-8")
        changed = text.replace("**3 / 3 / 3** entries", "**3 / 3 / 4** entries", 1)
        check(changed != text, "PIC10F320 stack fixture anchor was not found")
        validation.write_text(changed, encoding="utf-8")
        result = run(fixture)
        check(result.returncode != 0 and "current final-HEX stack claim" in result.stderr,
              "documentation mode accepted stale PIC10F320 3/3/4 current prose")

    print("resource-table contract: %d checks, 0 failures" % checks)
    return 0


if __name__ == "__main__":
    sys.exit(main())
