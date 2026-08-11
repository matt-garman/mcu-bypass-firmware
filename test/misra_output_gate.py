#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
"""Fail a MISRA lane on any unwaived authored-firmware diagnostic.

Cppcheck 2.13.0 does not apply --error-exitcode to diagnostics located in an
included header.  The Makefile therefore gives every diagnostic a machine-
readable prefix and delegates the compliance verdict to this parser.
"""

import argparse
import os
import sys


PREFIX = "MCU_BYPASS_CPPCHECK"


def is_authored_firmware(path, repo_root):
    """Return whether a diagnostic path is lexically inside src/ and is C."""
    if not path:
        return False

    if os.path.isabs(path):
        absolute = os.path.abspath(os.path.normpath(path))
    else:
        absolute = os.path.abspath(os.path.normpath(os.path.join(repo_root, path)))

    try:
        relative = os.path.relpath(absolute, repo_root)
    except ValueError:
        return False

    parts = relative.split(os.sep)
    return (
        len(parts) >= 2
        and parts[0] == "src"
        and parts[0] != os.pardir
        and os.path.splitext(parts[-1])[1] in (".c", ".h")
    )


def check_output(output_path, tool_status, repo_root):
    failures = []

    if tool_status != 0:
        failures.append("cppcheck exited with status %d" % tool_status)

    try:
        with open(output_path, "r", encoding="utf-8", errors="replace") as stream:
            lines = stream.read().splitlines()
    except OSError as exc:
        print("FAIL: cannot read captured cppcheck output %s: %s" % (output_path, exc),
              file=sys.stderr)
        return 1

    for number, line in enumerate(lines, 1):
        if not line:
            continue

        fields = line.split("|", 6)
        if len(fields) != 7 or fields[0] != PREFIX:
            failures.append("unparseable cppcheck stderr line %d: %s" % (number, line))
            continue

        _, path, source_line, column, severity, diagnostic_id, _ = fields
        if (not path or not source_line.isdigit() or not column.isdigit()
                or not severity or not diagnostic_id):
            failures.append("malformed cppcheck diagnostic line %d: %s" % (number, line))
            continue

        if path.startswith("<") and path.endswith(">"):
            failures.append("diagnostic has an unattributed path: %s" % line)
        elif is_authored_firmware(path, repo_root):
            failures.append("unwaived authored-firmware diagnostic: %s" % line)

    for failure in failures:
        print("FAIL: %s" % failure, file=sys.stderr)
    return 1 if failures else 0


def parse_args(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--tool-status", required=True, type=int)
    parser.add_argument("--repo-root", required=True)
    args = parser.parse_args(argv)
    if args.tool_status < 0:
        parser.error("--tool-status must be non-negative")
    return args


def main(argv=None):
    args = parse_args(argv)
    root = os.path.abspath(os.path.normpath(args.repo_root))
    return check_output(args.output, args.tool_status, root)


if __name__ == "__main__":
    sys.exit(main())
