#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
"""Run the shipped PIC12F675 flashing helper with one deterministic hook.

Two of that helper's properties cannot be proved from outside the process.

  * The check-to-use race. The helper hashes the ipecmd it is about to run and
    the image it is about to write, then hands both to a child. Whether it is
    still safe if those objects are replaced BETWEEN the hash and the child's
    consumption of them cannot be tested by replacing them a moment earlier or
    later; something has to fire in exactly that window.
  * Failures inside evidence publication. Whether a crash, a short write, an
    fsync error or a lost race for the final name leaves a valid immutable
    result or a recoverable PENDING transaction cannot be observed by killing
    the process from outside at a lucky instant.

So this driver imports the helper as a module and wraps the single function
each property runs through, leaving the shipped file itself free of any test
hook: nothing here exists in the tool an operator downloads. The helper is
still bound to its bundle exactly as it would be when run directly, because
that binding is computed from the module's own __file__.

    usage: flash_hook.py <helper.py> <helper arguments...>

configured entirely by environment, so the helper's own argv stays untouched:

  FLASH_HOOK_SWAPS     JSON list of [source, target] pairs, renamed in order at
                       the instant the write command is about to be exec'd --
                       after every identity proof the helper makes.
  FLASH_HOOK_FAIL_OP   one of write|fsync|link: which durable primitive to fail.
  FLASH_HOOK_FAIL      substring of that primitive's subject; the first matching
                       call raises OSError instead of running.
  FLASH_HOOK_KILL_OP   as FLASH_HOOK_FAIL_OP, but SIGKILL this process.
  FLASH_HOOK_KILL      substring selecting the call to be killed at.
"""

import importlib.util
import json
import os
import signal
import sys


OPERATIONS = ("write", "fsync", "link")


def load_helper(path):
    spec = importlib.util.spec_from_file_location("pic12f675_flash_helper", path)
    if spec is None or spec.loader is None:
        sys.stderr.write("flash_hook: cannot load helper: %s\n" % path)
        sys.exit(90)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def install_swaps(module, swaps):
    """Replace pathnames in the check-to-exec window of the single write.

    `-M` is the one argument that makes a command a write, so this fires once,
    on the invocation whose next act is the physical erase, and after the
    helper's final identity proof has already passed.
    """
    original = module.run_tool

    def hooked(argv, timeout, label, executable=None, pass_fds=()):
        if "-M" in argv:
            for source, target in swaps:
                os.rename(source, target)
        return original(argv, timeout, label, executable=executable,
                        pass_fds=pass_fds)

    module.run_tool = hooked


def closed_fd():
    """A descriptor number that is guaranteed not to be open."""
    fd = os.open(os.devnull, os.O_RDONLY)
    os.close(fd)
    return fd


def install_fault(module, operation, needle, kill):
    """Fail or kill inside one durable primitive, selected by its subject.

    A failure is injected by handing the REAL primitive an argument the kernel
    must reject -- a closed descriptor, a source name that does not exist -- so
    the syscall fails where it actually would and the helper's own error
    handling is what runs. Raising in place of the primitive would prove only
    that this driver can raise.
    """
    name = "durable_" + operation
    original = getattr(module, name)

    def armed(what):
        if needle not in what:
            return False
        if kill:
            sys.stdout.flush()
            sys.stderr.flush()
            os.kill(os.getpid(), signal.SIGKILL)
        return True

    if operation == "fsync":
        def hooked(fd, what):
            return original(closed_fd() if armed(what) else fd, what)
    elif operation == "write":
        def hooked(fd, data, what):
            return original(closed_fd() if armed(what) else fd, data, what)
    else:
        def hooked(source, target, what, dir_fd=None):
            if armed(what):
                # ENOENT, not EEXIST: an absent source is a failed publication,
                # while a taken destination is the immutability refusal, which
                # is a different outcome with its own coverage.
                source = source + ".absent"
            return original(source, target, what, dir_fd=dir_fd)

    setattr(module, name, hooked)


def selected(op_variable, needle_variable):
    operation = os.environ.get(op_variable, "")
    needle = os.environ.get(needle_variable, "")
    if not operation and not needle:
        return None, None
    if operation not in OPERATIONS or not needle:
        sys.stderr.write("flash_hook: %s must be one of %s and %s must be "
                         "non-empty\n"
                         % (op_variable, "|".join(OPERATIONS), needle_variable))
        sys.exit(91)
    return operation, needle


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__.splitlines()[0] + "\n")
        sys.stderr.write("usage: flash_hook.py <helper.py> <helper arguments...>\n")
        return 92
    module = load_helper(argv[0])

    raw = os.environ.get("FLASH_HOOK_SWAPS", "")
    if raw:
        swaps = json.loads(raw)
        if not isinstance(swaps, list) or not swaps \
                or any(not isinstance(pair, list) or len(pair) != 2
                       for pair in swaps):
            sys.stderr.write("flash_hook: FLASH_HOOK_SWAPS must be a non-empty "
                             "list of [source, target] pairs\n")
            return 93
        install_swaps(module, swaps)

    operation, needle = selected("FLASH_HOOK_FAIL_OP", "FLASH_HOOK_FAIL")
    if operation is not None:
        install_fault(module, operation, needle, kill=False)
    operation, needle = selected("FLASH_HOOK_KILL_OP", "FLASH_HOOK_KILL")
    if operation is not None:
        install_fault(module, operation, needle, kill=True)

    return module.main(argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
