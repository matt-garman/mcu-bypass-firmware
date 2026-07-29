#!/usr/bin/env python3
"""Validate the pinned PIC10F320 image set and its SHA-256 manifest."""

import argparse
from contextlib import redirect_stderr, redirect_stdout
import hashlib
import io
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
from types import SimpleNamespace
from unittest import mock


EXPECTED_NAMES = (
    "bypass_mcu_cd4053-simple_pic10f320.hex",
    "bypass_mcu_cd4053-mute_pic10f320.hex",
    "bypass_mcu_tq2-relay_pic10f320.hex",
)
RECORD_RE = re.compile(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._-]*)")
MAX_MANIFEST_BYTES = 1024
MAX_IMAGE_BYTES = 1024 * 1024
SELFTEST_DIGESTS = (
    "8cee58a123ffc31fb11aa7cf0ccece3c3a3b693de9f64f9603a49aba827c3c45",
    "88961a2a361a4c72d5dbd5d3426732c98b42004999b293b8660eab300e35b268",
    "5b14d6bc2fac107e64a4907bb566d43b05baad6f63022e620aa63583942ce7b6",
)


class ValidationError(Exception):
    pass


def read_regular_file(path, label, size_limit):
    """Read one stable regular file without following a symbolic link."""
    try:
        before = os.lstat(path)
    except OSError as exc:
        raise ValidationError("%s is unavailable: %s" % (label, exc)) from exc
    if stat.S_ISLNK(before.st_mode):
        raise ValidationError("%s is a symbolic link: %s" % (label, path))
    if not stat.S_ISREG(before.st_mode):
        raise ValidationError("%s is not a regular file: %s" % (label, path))
    if before.st_size == 0:
        raise ValidationError("%s is empty: %s" % (label, path))
    if before.st_size > size_limit:
        raise ValidationError("%s exceeds the %d-byte limit: %s" %
                              (label, size_limit, path))

    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise ValidationError("cannot open %s safely: %s" % (label, exc)) from exc

    try:
        with os.fdopen(descriptor, "rb") as handle:
            opened = os.fstat(handle.fileno())
            if not stat.S_ISREG(opened.st_mode):
                raise ValidationError("opened %s is not a regular file" % label)
            if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
                raise ValidationError(
                    "%s changed between path check and open" % label)
            chunks = []
            total = 0
            while True:
                block = handle.read(min(65536, size_limit + 1 - total))
                if not block:
                    break
                chunks.append(block)
                total += len(block)
                if total > size_limit:
                    raise ValidationError("%s exceeds the %d-byte limit" %
                                          (label, size_limit))
            after = os.fstat(handle.fileno())
    except ValidationError:
        raise
    except OSError as exc:
        raise ValidationError("cannot read %s safely: %s" % (label, exc)) from exc

    try:
        after_path = os.lstat(path)
    except OSError as exc:
        raise ValidationError("%s disappeared while being read: %s" %
                              (label, exc)) from exc
    unchanged = (
        opened.st_dev == after.st_dev == after_path.st_dev,
        opened.st_ino == after.st_ino == after_path.st_ino,
        stat.S_ISREG(after_path.st_mode),
        opened.st_size == after.st_size == after_path.st_size == total,
        opened.st_mtime_ns == after.st_mtime_ns == after_path.st_mtime_ns,
        opened.st_ctime_ns == after.st_ctime_ns == after_path.st_ctime_ns,
    )
    if not all(unchanged):
        raise ValidationError("%s changed while it was being read" % label)
    if total == 0:
        raise ValidationError("%s is empty: %s" % (label, path))
    return b"".join(chunks)


def read_manifest(path):
    try:
        raw = read_regular_file(path, "expected-image manifest",
                                MAX_MANIFEST_BYTES)
        text = raw.decode("ascii")
    except UnicodeDecodeError as exc:
        raise ValidationError("cannot read expected-image manifest %s: %s" %
                              (path, exc)) from exc

    if not raw.endswith(b"\n"):
        raise ValidationError("expected-image manifest must end with a newline")

    lines = text[:-1].split("\n")
    if len(lines) != len(EXPECTED_NAMES):
        raise ValidationError(
            "expected-image manifest has %d records; expected %d" %
            (len(lines), len(EXPECTED_NAMES)))

    records = {}
    for index, (line, expected_name) in enumerate(zip(lines, EXPECTED_NAMES), 1):
        match = RECORD_RE.fullmatch(line)
        if match is None:
            raise ValidationError(
                "expected-image manifest line %d is malformed" % index)
        digest, name = match.groups()
        if name != expected_name:
            raise ValidationError(
                "expected-image manifest line %d names %s; expected %s" %
                (index, name, expected_name))
        if name in records:
            raise ValidationError(
                "expected-image manifest repeats image name %s" % name)
        records[name] = digest
    return records


def sha256_file(path):
    raw = read_regular_file(path, "PIC10F320 image", MAX_IMAGE_BYTES)
    return hashlib.sha256(raw).hexdigest()


def validate(manifest, images=(), require_all=False):
    records = read_manifest(manifest)
    image_names = [os.path.basename(path) for path in images]

    if len(set(image_names)) != len(image_names):
        raise ValidationError("an image path was supplied more than once")
    unknown = [name for name in image_names if name not in records]
    if unknown:
        raise ValidationError("unexpected PIC10F320 image name: %s" % unknown[0])
    if require_all and tuple(image_names) != EXPECTED_NAMES:
        raise ValidationError(
            "complete image check requires this exact ordered set: %s" %
            " ".join(EXPECTED_NAMES))

    matches = []
    for path, name in zip(images, image_names):
        actual = sha256_file(path)
        expected = records[name]
        if actual != expected:
            raise ValidationError(
                "%s: SHA-256 mismatch\n  expected: %s\n  actual:   %s" %
                (name, expected, actual))
        matches.append((name, actual))
    return matches


class Selftest:
    def __init__(self):
        self.checks = 0
        self.failures = 0

    def expect_ok(self, label, action):
        self.checks += 1
        try:
            action()
        except (OSError, ValidationError) as exc:
            self.failures += 1
            print("[pic320-hash] FAIL: %s (%s)" % (label, exc), file=sys.stderr)

    def expect_error(self, label, diagnostic, action):
        self.checks += 1
        try:
            action()
        except ValidationError as exc:
            if diagnostic not in str(exc):
                self.failures += 1
                print("[pic320-hash] FAIL: %s reported the wrong error (%s)" %
                      (label, exc), file=sys.stderr)
            return
        self.failures += 1
        print("[pic320-hash] FAIL: %s was accepted" % label, file=sys.stderr)

    def expect_status(self, label, expected, diagnostic, action):
        self.checks += 1
        stdout = io.StringIO()
        stderr = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            actual = action()
        output = stdout.getvalue() + stderr.getvalue()
        if actual != expected or diagnostic not in output:
            self.failures += 1
            print("[pic320-hash] FAIL: %s returned %d, output %r" %
                  (label, actual, output), file=sys.stderr)


def write_manifest(path, digests, names=EXPECTED_NAMES, separator="  ",
                   trailing_newline=True):
    text = "\n".join(digest + separator + name
                     for digest, name in zip(digests, names))
    if trailing_newline:
        text += "\n"
    path.write_text(text, encoding="ascii")


def run_selftest():
    checker = Selftest()
    with tempfile.TemporaryDirectory(prefix="pic320-expected-images-") as temp:
        root = Path(temp)
        images = []
        for index, name in enumerate(EXPECTED_NAMES):
            path = root / name
            path.write_bytes(("image-%d\n" % index).encode("ascii"))
            images.append(path)
        digests = list(SELFTEST_DIGESTS)
        manifest = root / "expected.sha256"
        write_manifest(manifest, digests)

        checker.expect_ok("canonical manifest", lambda: validate(manifest))
        checker.expect_ok(
            "complete matching image set",
            lambda: validate(manifest, images, require_all=True))
        checker.expect_ok(
            "one selected matching image",
            lambda: validate(manifest, images[:1]))

        images[0].write_bytes(b"changed\n")
        checker.expect_error(
            "changed image bytes", "SHA-256 mismatch",
            lambda: validate(manifest, images, require_all=True))
        images[0].write_bytes(b"image-0\n")

        checker.expect_error(
            "incomplete required image set", "complete image check requires",
            lambda: validate(manifest, images[:2], require_all=True))
        checker.expect_error(
            "duplicate image argument", "supplied more than once",
            lambda: validate(manifest, [images[0], images[0]]))

        write_manifest(manifest, digests[:2], EXPECTED_NAMES[:2])
        checker.expect_error("missing manifest record", "has 2 records",
                             lambda: validate(manifest))
        write_manifest(manifest, digests + [digests[0]],
                       EXPECTED_NAMES + ("extra.hex",))
        checker.expect_error("extra manifest record", "has 4 records",
                             lambda: validate(manifest))
        write_manifest(manifest, digests,
                       (EXPECTED_NAMES[1], EXPECTED_NAMES[0], EXPECTED_NAMES[2]))
        checker.expect_error("reordered manifest", "line 1 names",
                             lambda: validate(manifest))
        write_manifest(manifest, [digests[0].upper()] + digests[1:])
        checker.expect_error("uppercase digest", "line 1 is malformed",
                             lambda: validate(manifest))
        write_manifest(manifest, digests, separator=" ")
        checker.expect_error("one-space separator", "line 1 is malformed",
                             lambda: validate(manifest))
        write_manifest(manifest, digests,
                       (EXPECTED_NAMES[0], EXPECTED_NAMES[1], "unknown.hex"))
        checker.expect_error("unknown manifest name", "line 3 names",
                             lambda: validate(manifest))
        write_manifest(manifest, digests, trailing_newline=False)
        checker.expect_error("unterminated manifest", "must end with a newline",
                             lambda: validate(manifest))
        crlf_text = "\r\n".join(digest + "  " + name
                                  for digest, name in
                                  zip(digests, EXPECTED_NAMES)) + "\r\n"
        manifest.write_bytes(crlf_text.encode("ascii"))
        checker.expect_error("CRLF manifest", "line 1 is malformed",
                             lambda: validate(manifest))
        control_text = "\v".join(digest + "  " + name
                                  for digest, name in
                                  zip(digests, EXPECTED_NAMES)) + "\n"
        manifest.write_bytes(control_text.encode("ascii"))
        checker.expect_error("control-separated manifest", "has 1 records",
                             lambda: validate(manifest))
        manifest.write_bytes(b"x" * (MAX_MANIFEST_BYTES + 1))
        checker.expect_error("oversized manifest", "exceeds the 1024-byte limit",
                             lambda: validate(manifest))

        write_manifest(manifest, digests)
        manifest_link = root / "manifest-link.sha256"
        manifest_link.symlink_to(manifest.name)
        checker.expect_error(
            "symlink manifest", "is a symbolic link",
            lambda: validate(manifest_link))
        link_dir = root / "links"
        link_dir.mkdir()
        image_link = link_dir / EXPECTED_NAMES[0]
        image_link.symlink_to(images[0])
        checker.expect_error(
            "symlink image", "is a symbolic link",
            lambda: validate(manifest, [image_link]))
        images[0].write_bytes(b"")
        checker.expect_error(
            "empty image", "is empty", lambda: validate(manifest, images[:1]))
        images[0].write_bytes(b"image-0\n")
        images[0].write_bytes(b"x" * (MAX_IMAGE_BYTES + 1))
        checker.expect_error(
            "oversized image", "exceeds the 1048576-byte limit",
            lambda: validate(manifest, images[:1]))
        images[0].write_bytes(b"image-0\n")

        real_fstat = os.fstat

        def unstable_read():
            calls = [0]

            def changed_fstat(descriptor):
                result = real_fstat(descriptor)
                calls[0] += 1
                if calls[0] != 2:
                    return result
                return SimpleNamespace(
                    st_dev=result.st_dev,
                    st_ino=result.st_ino,
                    st_mode=result.st_mode,
                    st_size=result.st_size + 1,
                    st_mtime_ns=result.st_mtime_ns,
                    st_ctime_ns=result.st_ctime_ns,
                )

            with mock.patch.object(os, "fstat", side_effect=changed_fstat):
                read_regular_file(images[0], "PIC10F320 image", MAX_IMAGE_BYTES)

        checker.expect_error(
            "file stability change", "changed while it was being read",
            unstable_read)

        def failed_fstat_read():
            with mock.patch.object(os, "fstat", side_effect=OSError("fixture")):
                read_regular_file(images[0], "PIC10F320 image", MAX_IMAGE_BYTES)

        checker.expect_error(
            "descriptor read failure", "cannot read PIC10F320 image safely",
            failed_fstat_read)

        checker.expect_status(
            "matching CLI", 0, "expected image: PASS",
            lambda: main(["--require-all", str(manifest)] +
                         [str(path) for path in images]))
        images[0].write_bytes(b"changed\n")
        checker.expect_status(
            "mismatching CLI", 1, "SHA-256 mismatch",
            lambda: main(["--require-all", str(manifest)] +
                         [str(path) for path in images]))

    print("PIC10F320 expected-image selftest: %d checks, %d failures" %
          (checker.checks, checker.failures))
    return 1 if checker.failures else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--require-all", action="store_true")
    parser.add_argument("manifest", nargs="?")
    parser.add_argument("images", nargs="*")
    args = parser.parse_args(argv)

    if args.selftest:
        if args.manifest is not None or args.images or args.require_all:
            parser.error("--selftest accepts no manifest, images, or other options")
        return run_selftest()
    if args.manifest is None:
        parser.error("an expected-image manifest is required")
    if args.require_all and not args.images:
        parser.error("--require-all needs the complete image list")

    try:
        matches = validate(args.manifest, args.images, args.require_all)
    except ValidationError as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return 1

    if matches:
        for name, digest in matches:
            print("PIC10F320 expected image: PASS  %s  %s" % (digest, name))
    else:
        print("PIC10F320 expected-image manifest: PASS (%d records)" %
              len(EXPECTED_NAMES))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
