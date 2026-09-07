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

One further real property is modelled, because the helper's jar handling depends
on it and nothing else here could see it: a real JVM CANONICALISES the jar
pathname it is given and resolves every relative manifest Class-Path entry
against the directory that canonical path sits in. A jar handed over as a sealed
anonymous copy canonicalises to "/memfd:<name> (deleted)", which has no
directory, so its siblings vanish and a real ipecmd.jar -- a manifest stub whose
Class-Path names about two hundred sibling jars -- dies with
NoClassDefFoundError before it can print anything. Requiring one sibling to be
reachable from the jar path reproduces exactly that failure in the suite.
"""

import os
import sys

# Stands in for the ../mplablibs/... tree every real ipecmd.jar Class-Path
# entry points at. The jar layout under test mirrors the installed one:
# <root>/mplab_ipe/ipecmd.jar beside <root>/mplablibs/.
SIBLING = os.path.join("..", "mplablibs", "dep.marker")


def main(argv):
    if len(argv) < 2 or argv[0] != "-jar":
        sys.stderr.write("fake java: expected -jar <jar> [args]: %r\n" % (argv,))
        return 92
    sibling = os.path.join(os.path.dirname(os.path.realpath(argv[1])), SIBLING)
    if not os.path.exists(sibling):
        # Word for word the shape a real JVM fails with, so the helper is tested
        # against the diagnostic an operator would actually be handed.
        sys.stdout.write(
            "Error: Unable to initialize main class "
            "com.microchip.mplab.ipecmd.IPECMD\n"
            "Caused by: java.lang.NoClassDefFoundError: "
            "org/apache/commons/cli/Options\n")
        return 1
    os.execv(sys.executable, [sys.executable, argv[1]] + list(argv[2:]))
    return 93  # unreachable: execv either replaces this process or raises


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
