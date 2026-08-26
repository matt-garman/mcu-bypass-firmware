#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
"""Run the shipped PIC12F675 flashing helper with one deterministic hook.

Several of that helper's properties cannot be proved from outside the process.

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
                       the instant the write command is about to be exec'd.
  FLASH_HOOK_REWRITES  JSON list of [source, target] pairs. Each source's bytes
                       are written into the existing target inode in that same
                       check-to-exec window.
  FLASH_HOOK_NO_MEMFD  make immutable storage unavailable before any tool runs.
  FLASH_HOOK_HIDE_OS_MEMFD
                       hide os.memfd_create to exercise the libc fallback.
  FLASH_HOOK_MISSING_SEALS
                       report a sealed copy without its write seal.
  FLASH_HOOK_CORRUPT_COPY
                       substring selecting a private copy to corrupt in memory.
  FLASH_HOOK_UNSEALED  ipecmd|java runtime|image: replace that one sealed copy
                       with its ordinary source descriptor (negative control).
  FLASH_HOOK_UNSEALED_PATH
                        selected image pathname for the image negative control.
  FLASH_HOOK_PARENT_SWAP JSON object describing an evidence-parent replacement
                        immediately before mkdir. The fixture also verifies the
                        parent fsync descriptor; optional fields select absolute
                        mkdir and pre/post-attachment child-move controls.
  FLASH_HOOK_MISSING_EVIDENCE_OP
                        remove one named operation from os.supports_dir_fd.
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


def install_rewrites(module, rewrites):
    """Rewrite existing inodes after the final hash and before child use."""
    original = module.run_tool

    def hooked(argv, timeout, label, executable=None, pass_fds=()):
        if "-M" in argv:
            for source, target in rewrites:
                with open(source, "rb") as handle:
                    data = handle.read()
                mode = os.stat(target).st_mode & 0o777
                os.chmod(target, mode | 0o200)
                fd = os.open(target, os.O_WRONLY | os.O_TRUNC)
                try:
                    written = 0
                    while written < len(data):
                        written += os.write(fd, data[written:])
                    os.fsync(fd)
                finally:
                    os.close(fd)
                    os.chmod(target, mode)
        return original(argv, timeout, label, executable=executable,
                        pass_fds=pass_fds)

    module.run_tool = hooked


def install_unsealed_control(module, target, image_path):
    """Restore one vulnerable ordinary descriptor for a negative control."""
    if target in ("ipecmd", "java runtime"):
        original = module.open_identity

        def hooked(path, label, max_bytes, executable=False):
            handle = original(path, label, max_bytes, executable=executable)
            if label == target:
                os.close(handle["consume_fd"])
                handle["consume_fd"] = handle["fd"]
            return handle

        module.open_identity = hooked
        return
    if target != "image" or not image_path:
        raise ValueError("image unsealed control needs FLASH_HOOK_UNSEALED_PATH")

    def unsealed_image(data, name, label):
        fd = os.open(image_path, os.O_RDONLY)
        if module.sha256_fd(fd, label, module.MAX_FILE_BYTES) \
                != module.sha256_bytes(data):
            os.close(fd)
            raise ValueError("unsealed image source differs from validated bytes")
        return fd

    module.sealed_copy = unsealed_image


def install_no_memfd(module):
    def unavailable(name, label, executable=False):
        del executable
        raise module.FlashError(
            "immutable sealed storage is unavailable for %s (forced by test); "
            "no device command was issued" % label)

    module.create_memfd = unavailable


def install_missing_seals(module):
    original = module.fcntl.fcntl

    def hooked(fd, operation, *args):
        result = original(fd, operation, *args)
        if operation == module.F_GET_SEALS:
            return result & ~module.F_SEAL_WRITE
        return result

    module.fcntl.fcntl = hooked


def install_corrupt_copy(module, needle):
    original = module.durable_write
    armed = [True]

    def hooked(fd, data, what):
        if armed[0] and needle in what and data:
            armed[0] = False
            data = bytes((data[0] ^ 1,)) + data[1:]
        return original(fd, data, what)

    module.durable_write = hooked


def install_parent_swap(module, config):
    """Replace the evidence parent after it is opened but before child mkdir."""
    parent = config["parent"]
    moved = config["moved"]
    child = config["child"]
    prepopulate = config.get("prepopulate", False)
    absolute_mkdir = config.get("absolute_mkdir", False)
    replace_child = config.get("replace_child_before_attach", False)
    move_child_before_fsync = config.get("move_child_before_fsync", "")
    original_mkdir = module.os.mkdir
    original_fsync = module.durable_fsync
    original_attach = module.Evidence._attach
    armed = [True]
    swapped = [False]
    moved_child = [False]

    def mkdir_hook(path, mode=0o777, *, dir_fd=None):
        if armed[0]:
            armed[0] = False
            parent_mode = module.os.stat(parent).st_mode & 0o7777
            module.os.rename(parent, moved)
            original_mkdir(parent, parent_mode)
            if prepopulate:
                decoy_child = module.os.path.join(parent, child)
                original_mkdir(decoy_child, 0o700)
                marker = module.os.open(
                    module.os.path.join(decoy_child, "decoy.marker"),
                    module.os.O_WRONLY | module.os.O_CREAT | module.os.O_EXCL,
                    0o600)
                try:
                    module.os.write(marker, b"pre-existing decoy evidence\n")
                finally:
                    module.os.close(marker)
            swapped[0] = True
            if absolute_mkdir:
                return original_mkdir(module.os.path.join(parent, path), mode)
        return original_mkdir(path, mode, dir_fd=dir_fd)

    def fsync_hook(fd, what):
        if swapped[0] and what == "the evidence directory's parent":
            if move_child_before_fsync and not moved_child[0]:
                moved_child[0] = True
                module.os.rename(
                    child, module.os.path.join(move_child_before_fsync, child),
                    src_dir_fd=fd)
                original_mkdir(child, 0o700, dir_fd=fd)
            try:
                module.os.stat(child, dir_fd=fd, follow_symlinks=False)
            except OSError as exc:
                raise module.FlashError(
                    "parent fsync descriptor does not contain the created "
                    "evidence child: %s" % exc) from exc
        return original_fsync(fd, what)

    def attach_hook(parent_fd, name, path, expected=None):
        if replace_child and expected is not None:
            module.os.rename(
                name, name + ".created", src_dir_fd=parent_fd,
                dst_dir_fd=parent_fd)
            original_mkdir(name, 0o700, dir_fd=parent_fd)
        return original_attach(parent_fd, name, path, expected)

    module.os.mkdir = mkdir_hook
    module.durable_fsync = fsync_hook
    module.Evidence._attach = staticmethod(attach_hook)


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

    raw = os.environ.get("FLASH_HOOK_REWRITES", "")
    if raw:
        rewrites = json.loads(raw)
        if not isinstance(rewrites, list) or not rewrites \
                or any(not isinstance(pair, list) or len(pair) != 2
                       for pair in rewrites):
            sys.stderr.write("flash_hook: FLASH_HOOK_REWRITES must be a "
                             "non-empty list of [source, target] pairs\n")
            return 94
        install_rewrites(module, rewrites)

    if os.environ.get("FLASH_HOOK_HIDE_OS_MEMFD", ""):
        if hasattr(module.os, "memfd_create"):
            delattr(module.os, "memfd_create")
    if os.environ.get("FLASH_HOOK_NO_MEMFD", ""):
        install_no_memfd(module)
    if os.environ.get("FLASH_HOOK_MISSING_SEALS", ""):
        install_missing_seals(module)
    corrupt_copy = os.environ.get("FLASH_HOOK_CORRUPT_COPY", "")
    if corrupt_copy:
        install_corrupt_copy(module, corrupt_copy)
    unsealed = os.environ.get("FLASH_HOOK_UNSEALED", "")
    if unsealed:
        if unsealed not in ("ipecmd", "java runtime", "image"):
            sys.stderr.write("flash_hook: FLASH_HOOK_UNSEALED must be "
                             "ipecmd|java runtime|image\n")
            return 95
        install_unsealed_control(
            module, unsealed, os.environ.get("FLASH_HOOK_UNSEALED_PATH", ""))
    missing_evidence_op = os.environ.get("FLASH_HOOK_MISSING_EVIDENCE_OP", "")
    if missing_evidence_op:
        operation = getattr(module.os, missing_evidence_op, None)
        if operation not in module.EVIDENCE_DIR_OPERATIONS:
            sys.stderr.write(
                "flash_hook: FLASH_HOOK_MISSING_EVIDENCE_OP must name a "
                "required evidence operation\n")
            return 96
        module.os.supports_dir_fd = set(module.os.supports_dir_fd) - {operation}

    operation, needle = selected("FLASH_HOOK_FAIL_OP", "FLASH_HOOK_FAIL")
    if operation is not None:
        install_fault(module, operation, needle, kill=False)
    operation, needle = selected("FLASH_HOOK_KILL_OP", "FLASH_HOOK_KILL")
    if operation is not None:
        install_fault(module, operation, needle, kill=True)

    raw = os.environ.get("FLASH_HOOK_PARENT_SWAP", "")
    if raw:
        config = json.loads(raw)
        required = ("parent", "moved", "child")
        if not isinstance(config, dict) \
                or any(not isinstance(config.get(key), str) or not config[key]
                       for key in required) \
                or any(key in config and not isinstance(config[key], bool)
                       for key in ("prepopulate", "absolute_mkdir",
                                   "replace_child_before_attach")) \
                or ("move_child_before_fsync" in config
                    and (not isinstance(config["move_child_before_fsync"], str)
                         or not config["move_child_before_fsync"])):
            sys.stderr.write(
                "flash_hook: FLASH_HOOK_PARENT_SWAP must be an object with "
                "non-empty parent/moved/child strings and boolean options\n")
            return 97
        install_parent_swap(module, config)

    return module.main(argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
