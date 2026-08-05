#!/usr/bin/env python3
"""Shared minimum-version contract for repository host Python gates."""

import sys


MINIMUM = (3, 7)


def is_supported(version_info):
    return tuple(version_info[:2]) >= MINIMUM


def main():
    if is_supported(sys.version_info):
        return 0

    required = ".".join(str(part) for part in MINIMUM)
    found = ".".join(str(part) for part in sys.version_info[:3])
    sys.stderr.write(
        "FAIL: Python {} or newer is required by the repository host gates; "
        "found Python {} at {}. Upgrade Python and ensure `python3` selects "
        "the newer interpreter.\n".format(required, found, sys.executable)
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
