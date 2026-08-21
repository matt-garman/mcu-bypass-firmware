#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman

"""Structural contract for watchdog notes printed into PIC fault evidence."""

from pathlib import Path
import re
import sys
from typing import List, Optional, Tuple

from source_contract import (
    normalized_c_code,
    strip_c_comments,
    update_preprocessor_stack,
)


ROOT = Path(__file__).resolve().parent.parent
CORE = ROOT / "test/pic/test_fault_pic_core.h"
ADAPTERS = (
    (
        ROOT / "test/pic/test_fault_pic.cc",
        "PIC10F32x adapter",
        ("WDTPS=0x08", "1.057", "256ms silicon"),
        ("288", "OPTION_REG=0x0C"),
    ),
    (
        ROOT / "test/pic10f320/gpsim/test_fault_pic.cc",
        "PIC10F320 vendored adapter",
        ("WDTPS=0x08", "1.057", "256ms silicon"),
        ("288", "OPTION_REG=0x0C"),
    ),
    (
        ROOT / "test/pic/test_fault_pic12f675.cc",
        "PIC12F675 adapter",
        ("288ms", "160ms", "OPTION_REG=0x0C"),
        ("WDTPS", "256ms silicon"),
    ),
)

EXPECTED_BANNER = r'''printf("FAULT-INJECT START: fw=%s proc=%s FOSC=%lu window=%u ms\n"
       "  %s\n",
       FW_PATH, PROC_NAME, (unsigned long)F_CPU_HZ, WDT_RESET_WINDOW_MS,
       PIC_FAULT_WDT_NOTE);'''


def macro_body(source: str, name: str) -> Tuple[Optional[str], List[str]]:
    clean = strip_c_comments(source)
    lines = clean.splitlines()
    starts = []
    start_re = re.compile(rf"^[ \t]*#[ \t]*define[ \t]+{re.escape(name)}(?:[ \t]+(.*))?$")
    for index, line in enumerate(lines):
        match = start_re.match(line)
        if match:
            starts.append((index, match.group(1) or ""))
    if len(starts) != 1:
        return None, [f"expected one {name} definition, found {len(starts)}"]

    index, first = starts[0]
    parts = []
    current = first
    while True:
        continued = current.rstrip().endswith("\\")
        parts.append(current.rstrip()[:-1] if continued else current)
        if not continued:
            break
        index += 1
        if index >= len(lines):
            return None, [f"unterminated {name} definition"]
        current = lines[index]
    return " ".join(parts), []


def required_guard_present(clean: str) -> bool:
    lines = clean.splitlines()
    stack = []
    start = re.compile(r"^[ \t]*#[ \t]*ifndef[ \t]+PIC_FAULT_WDT_NOTE[ \t]*$")
    error = re.compile(
        r'^[ \t]*#[ \t]*error[ \t]+"PIC_FAULT_WDT_NOTE must be defined by the part adapter"[ \t]*$')
    end = re.compile(r"^[ \t]*#[ \t]*endif[ \t]*$")
    expected_stack = (("ifndef", "TEST_PIC_TEST_FAULT_PIC_CORE_H", False),)
    matches = 0
    for index, line in enumerate(lines):
        if start.match(line):
            if (tuple(stack) == expected_stack and index + 2 < len(lines)
                    and error.match(lines[index + 1])
                    and end.match(lines[index + 2])):
                matches += 1
        unused, stack_error = update_preprocessor_stack(stack, line)
        if stack_error:
            return False
    return not stack and matches == 1


def decode_c_string_literal(literal: str) -> str:
    simple = {
        "'": "'", '"': '"', "?": "?", "\\": "\\",
        "a": "\a", "b": "\b", "f": "\f", "n": "\n",
        "r": "\r", "t": "\t", "v": "\v",
    }
    body = literal[1:-1]
    result = []
    index = 0
    while index < len(body):
        if body[index] != "\\":
            result.append(body[index])
            index += 1
            continue
        index += 1
        if index >= len(body):
            raise ValueError("trailing backslash")
        escape = body[index]
        if escape in simple:
            result.append(simple[escape])
            index += 1
        elif escape in "01234567":
            end = index + 1
            while end < min(index + 3, len(body)) and body[end] in "01234567":
                end += 1
            value = int(body[index:end], 8)
            if value > 0xFF:
                raise ValueError("octal escape is not representable as a byte")
            result.append(chr(value))
            index = end
        elif escape == "x":
            end = index + 1
            while end < len(body) and body[end] in "0123456789abcdefABCDEF":
                end += 1
            if end == index + 1:
                raise ValueError("hex escape has no digits")
            value = int(body[index + 1:end], 16)
            if value > 0xFF:
                raise ValueError("hex escape is not representable as a byte")
            result.append(chr(value))
            index = end
        elif escape in ("u", "U"):
            digits = 4 if escape == "u" else 8
            end = index + 1 + digits
            text = body[index + 1:end]
            if len(text) != digits or not all(c in "0123456789abcdefABCDEF" for c in text):
                raise ValueError("malformed universal character escape")
            result.append(chr(int(text, 16)))
            index = end
        else:
            raise ValueError("unknown escape: \\" + escape)
    return "".join(result)


def core_errors(source: str) -> List[str]:
    clean = strip_c_comments(source)
    normalized = normalized_c_code(clean)
    expected = normalized_c_code(EXPECTED_BANNER)
    errors = []
    if normalized.count(expected) != 1:
        errors.append("fault banner is not the exact macro-bound printf call")
    if not required_guard_present(clean):
        errors.append("core lost the required PIC_FAULT_WDT_NOTE #error guard")
    if "~1.057s -- recovery reset, not 256ms silicon" in clean:
        errors.append("core again embeds the PIC10F32x watchdog note")
    return errors


def adapter_errors(source: str, required: Tuple[str, ...],
                   forbidden: Tuple[str, ...]) -> List[str]:
    body, errors = macro_body(source, "PIC_FAULT_WDT_NOTE")
    if body is None:
        return errors
    literal_pattern = r'"(?:\\.|[^"\\])*"'
    if not re.fullmatch(r'\s*(?:' + literal_pattern + r'\s*)+', body):
        errors.append("PIC_FAULT_WDT_NOTE must contain only C string literals")
        return errors
    try:
        emitted = "".join(decode_c_string_literal(literal) for literal in
                          re.findall(literal_pattern, body))
    except (ValueError, OverflowError) as error:
        errors.append("PIC_FAULT_WDT_NOTE has an invalid C string literal: " + str(error))
        return errors
    for fact in required:
        if fact not in emitted:
            errors.append(f"watchdog-note definition lacks required fact: {fact}")
    for fact in forbidden:
        if fact in emitted:
            errors.append(f"watchdog-note definition contains wrong-part fact: {fact}")
    return errors


def fail(label: str, errors: List[str]) -> None:
    print(f"FAIL: {label}: {'; '.join(errors)}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    checks = 0
    paths = (CORE,) + tuple(adapter[0] for adapter in ADAPTERS)
    for path in paths:
        if not path.is_file():
            fail(str(path), ["source file is missing"])
        checks += 1

    errors = core_errors(CORE.read_text(encoding="utf-8"))
    if errors:
        fail("shared fault core", errors)
    checks += 1

    spliced_required = (
        '#define PIC_FAULT_WDT_NOTE "WDTPS=\\\n'
        '0x08 1.057 256ms silicon"\n')
    errors = adapter_errors(spliced_required,
                            ("WDTPS=0x08", "1.057", "256ms silicon"), ("288",))
    if errors:
        fail("line-spliced required fixture", errors)
    checks += 1

    escaped_required = r'''
#define PIC_FAULT_WDT_NOTE "\x57" "DTPS=0x08 1.057 256ms silicon"
'''
    errors = adapter_errors(escaped_required,
                            ("WDTPS=0x08", "1.057", "256ms silicon"), ("288",))
    if errors:
        fail("escaped-required fixture", errors)
    checks += 1

    greedy_hex = r'''
#define PIC_FAULT_WDT_NOTE "\x57DTPS=0x08 1.057 256ms silicon"
'''
    if not adapter_errors(greedy_hex,
                          ("WDTPS=0x08", "1.057", "256ms silicon"), ("288",)):
        fail("greedy-hex fixture", ["overlong C hex escape was accepted"])
    checks += 1

    for path, label, required, forbidden in ADAPTERS:
        errors = adapter_errors(path.read_text(encoding="utf-8"), required, forbidden)
        if errors:
            fail(label, errors)
        checks += 1

    wrong_argument = EXPECTED_BANNER.replace(
        "       PIC_FAULT_WDT_NOTE);", "       PIC_FAULT_PROGRAM_STATE_NOTE);")
    wrong_argument_errors = core_errors(wrong_argument)
    if "fault banner is not the exact macro-bound printf call" not in wrong_argument_errors:
        fail("wrong-argument fixture", ["non-note banner argument was accepted"])
    checks += 1

    wrong_guard = EXPECTED_BANNER + '''
#ifdef PIC_FAULT_WDT_NOTE
#  error "PIC_FAULT_WDT_NOTE must be defined by the part adapter"
#endif
'''
    wrong_guard_errors = core_errors(wrong_guard)
    if "core lost the required PIC_FAULT_WDT_NOTE #error guard" not in wrong_guard_errors:
        fail("wrong-guard fixture", ["incorrectly conditioned #error was accepted"])
    checks += 1

    inactive_guard = EXPECTED_BANNER + '''
#ifndef FIXTURE_H
#if 0
#ifndef PIC_FAULT_WDT_NOTE
#  error "PIC_FAULT_WDT_NOTE must be defined by the part adapter"
#endif
#endif
#endif
'''
    inactive_guard_errors = core_errors(inactive_guard)
    if "core lost the required PIC_FAULT_WDT_NOTE #error guard" not in inactive_guard_errors:
        fail("inactive-guard fixture", ["inactive #error guard was accepted"])
    checks += 1

    comments_only = '''
/* #define PIC_FAULT_WDT_NOTE "WDTPS=0x08 1.057 256ms silicon" */
#define PIC_FAULT_WDT_NOTE "generic watchdog note"
'''
    if not adapter_errors(comments_only,
                          ("WDTPS=0x08", "1.057", "256ms silicon"), ("288",)):
        fail("comment-only fixture", ["facts in comments were accepted"])
    checks += 1

    split_required = '''
#define PIC_FAULT_WDT_NOTE "WDTPS=" "0x08 1." "057 256ms silicon"
'''
    errors = adapter_errors(split_required,
                            ("WDTPS=0x08", "1.057", "256ms silicon"), ("288",))
    if errors:
        fail("split-required fixture", errors)
    checks += 1

    split_forbidden = '''
#define PIC_FAULT_WDT_NOTE "OPTION_REG=0x0C 288ms 160ms WD" "TPS"
'''
    if not adapter_errors(split_forbidden,
                          ("OPTION_REG=0x0C", "288ms", "160ms"), ("WDTPS",)):
        fail("split-forbidden fixture", ["split wrong-part fact was accepted"])
    checks += 1

    facts_outside = '''
#define PIC_FAULT_WDT_NOTE "generic watchdog note"
static char const *facts = "OPTION_REG=0x0C 288ms 160ms";
'''
    if not adapter_errors(facts_outside,
                          ("OPTION_REG=0x0C", "288ms", "160ms"), ("WDTPS",)):
        fail("outside-definition fixture", ["facts outside the macro were accepted"])
    checks += 1

    print(f"fault-inject watchdog-note contract: {checks} checks, 0 failures")


if __name__ == "__main__":
    main()
