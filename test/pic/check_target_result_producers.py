#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman

"""Require each PIC production core to emit one unconditional lane result."""

from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from source_contract import (  # noqa: E402
    normalized_c_code,
    strip_c_comments,
    update_preprocessor_stack,
)


ROOT = Path(__file__).resolve().parents[2]
PRODUCERS = (
    ("test/pic/test_fault_pic_core.h", "TEST_PIC_TEST_FAULT_PIC_CORE_H",
     "fault", "pass != 0"),
    ("test/pic/test_lockstep_pic_core.h", "TEST_PIC_TEST_LOCKSTEP_PIC_CORE_H",
     "lockstep", "pass != 0"),
    ("test/pic/test_io_pic_core.h", "TEST_PIC_TEST_IO_PIC_CORE_H", "io", "pass"),
)


def fail(message):
    print("FAIL: " + message, file=sys.stderr)
    raise SystemExit(1)


def producer_errors(source, include_guard, lane, pass_expression):
    stack = []
    calls = []
    pending = None
    for line_number, line in enumerate(strip_c_comments(source).splitlines(), 1):
        is_directive, error = update_preprocessor_stack(stack, line)
        if error:
            return [error]
        if is_directive:
            if pending is not None:
                return ["preprocessor directive interrupts result call"]
            continue
        if pending is None and "pic_target_result" in line:
            pending = [line_number, tuple(stack), line]
        elif pending is not None:
            pending[2] += "\n" + line
        if pending is not None and ";" in pending[2]:
            calls.append((pending[0], pending[1], normalized_c_code(pending[2])))
            pending = None

    if stack:
        return ["unbalanced preprocessor condition"]
    if pending is not None:
        return ["unterminated result call"]
    expected = normalized_c_code(
        'pic_target_result("{}", {}, g_checks, g_fails);'.format(
            lane, pass_expression))
    expected_stack = (("ifndef", include_guard, False),)
    if len(calls) != 1 or calls[0][1:] != (expected_stack, expected):
        return ["expected one exact, include-guard-only result call; found {}".format(calls)]
    return []


def main():
    checks = 0
    for relative, include_guard, lane, pass_expression in PRODUCERS:
        path = ROOT / relative
        if not path.is_file():
            fail("missing production result source: " + relative)
        errors = producer_errors(path.read_text(encoding="utf-8"), include_guard,
                                 lane, pass_expression)
        if errors:
            fail("{}: {}".format(relative, "; ".join(errors)))
        checks += 1

    commented = '''
#ifndef FIXTURE_H
// pic_target_result("fault", pass != 0, g_checks, g_fails);
#endif
'''
    if not producer_errors(commented, "FIXTURE_H", "fault", "pass != 0"):
        fail("commented-out producer fixture was accepted")
    checks += 1

    spliced_comment = '''
#ifndef FIXTURE_H
// disabled \\
pic_target_result("fault", pass != 0, g_checks, g_fails);
#endif
'''
    if not producer_errors(spliced_comment, "FIXTURE_H", "fault", "pass != 0"):
        fail("line-spliced comment fixture was accepted")
    checks += 1

    inactive = '''
#ifndef FIXTURE_H
#if 0
pic_target_result("fault", pass != 0, g_checks, g_fails);
#endif
#endif
'''
    if not producer_errors(inactive, "FIXTURE_H", "fault", "pass != 0"):
        fail("conditionally inactive producer fixture was accepted")
    checks += 1

    top_level_inactive = '''
#if 0
pic_target_result("fault", pass != 0, g_checks, g_fails);
#endif
'''
    if not producer_errors(top_level_inactive, "FIXTURE_H", "fault", "pass != 0"):
        fail("top-level inactive producer fixture was accepted")
    checks += 1

    guard_else = '''
#ifndef FIXTURE_H
#else
pic_target_result("fault", pass != 0, g_checks, g_fails);
#endif
'''
    if not producer_errors(guard_else, "FIXTURE_H", "fault", "pass != 0"):
        fail("include-guard else-branch producer fixture was accepted")
    checks += 1

    multiline = '''
#ifndef FIXTURE_H
pic_target_result(
    "fault", pass != 0,
    g_checks, g_fails);
#endif
'''
    errors = producer_errors(multiline, "FIXTURE_H", "fault", "pass != 0")
    if errors:
        fail("multiline producer fixture was rejected: " + "; ".join(errors))
    checks += 1

    print("PIC target result source validation: {} checks, 0 failures".format(checks))


if __name__ == "__main__":
    main()
