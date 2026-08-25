#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
"""Minimal `java -jar` stand-in for the PIC12F675 flashing-helper regression.

The helper supports two ipecmd forms, and the jar form runs a SECOND binary --
the Java runtime -- which the helper pins, reserves and re-proves exactly like
the jar itself. Without a java on the test host that whole half of the
fail-closed matrix would be unreachable.

Only one argv shape is modelled: `-jar <jar> [args...]` runs the jar under this
interpreter and REPLACES this process, so exit codes, and the fake programmer's
deliberate SIGKILL of its parent, behave as they do in the direct form. Anything
else is refused rather than guessed at.
"""

import os
import sys


def main(argv):
    if len(argv) < 2 or argv[0] != "-jar":
        sys.stderr.write("fake java: expected -jar <jar> [args]: %r\n" % (argv,))
        return 92
    os.execv(sys.executable, [sys.executable, argv[1]] + list(argv[2:]))
    return 93  # unreachable: execv either replaces this process or raises


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
