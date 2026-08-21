#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
"""Record and verify one retained PIC12F675 aggregate image matrix."""

import argparse
import hashlib
import json
import os
import stat
import sys
import uuid


FORMAT = 2
MANIFEST_NAME = ".pic12f675-qualified-matrix.json"
STAGED_MANIFEST_NAME = MANIFEST_NAME + ".staged"
VARIANTS = (
    "cd4053_simple",
    "cd4053_with_mute",
    "tq2_l2_5v_relay",
)


class EvidenceError(Exception):
    pass


def validate_component(value, label):
    if (not value or value in (".", "..") or os.path.basename(value) != value
            or os.sep in value or (os.altsep and os.altsep in value)):
        raise EvidenceError("%s must be one non-path filename component" % label)


def entry_specs(fw_base, tag):
    specs = []
    for variant in VARIANTS:
        stem = "%s-%s-%s" % (fw_base, tag, variant)
        specs.extend((
            ("shipping_%s" % variant, stem + ".hex", True),
            ("assembly_%s" % variant, stem + ".s", False),
            ("symbols_%s" % variant, stem + ".sym", False),
            ("simcal_%s" % variant,
             os.path.join("simcal", stem + "_simcal.hex"), True),
        ))
    return specs


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceError("matrix evidence contains duplicate JSON key: %s" % key)
        result[key] = value
    return result


def file_identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns)


def inode_identity(info):
    return (info.st_dev, info.st_ino, info.st_mode)


def open_directory(path, label):
    try:
        before = os.lstat(path)
    except OSError as exc:
        raise EvidenceError("%s is missing: %s" % (label, exc))
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISDIR(before.st_mode):
        raise EvidenceError("%s is not a non-symlink directory: %s" % (label, path))
    if os.path.realpath(path) != path:
        raise EvidenceError("%s has a symlinked path component: %s" % (label, path))

    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise EvidenceError("cannot open %s without following links: %s" % (label, exc))
    opened = os.fstat(descriptor)
    if (not stat.S_ISDIR(opened.st_mode)
            or inode_identity(before) != inode_identity(opened)):
        os.close(descriptor)
        raise EvidenceError("%s changed while it was being opened" % label)
    return descriptor, file_identity(opened)


def check_directory_path(path, descriptor, identity, label, allow_changes=False):
    try:
        opened = os.fstat(descriptor)
        final = os.lstat(path)
    except OSError as exc:
        raise EvidenceError("%s changed while it was in use: %s" % (label, exc))
    if os.path.realpath(path) != path:
        raise EvidenceError("%s gained a symlinked path component" % label)
    expected = inode_identity if allow_changes else file_identity
    baseline = identity[:3] if allow_changes else identity
    if expected(opened) != expected(final) or expected(opened) != baseline:
        raise EvidenceError("%s changed while it was in use" % label)


def open_child_directory(parent, name, label):
    validate_component(name, label)
    try:
        before = os.stat(name, dir_fd=parent, follow_symlinks=False)
    except OSError as exc:
        raise EvidenceError("%s is missing: %s" % (label, exc))
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISDIR(before.st_mode):
        raise EvidenceError("%s is not a non-symlink directory" % label)
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(name, flags, dir_fd=parent)
    except OSError as exc:
        raise EvidenceError("cannot open %s without following links: %s" % (label, exc))
    opened = os.fstat(descriptor)
    if (not stat.S_ISDIR(opened.st_mode)
            or inode_identity(before) != inode_identity(opened)):
        os.close(descriptor)
        raise EvidenceError("%s changed while it was being opened" % label)
    return descriptor, file_identity(opened)


def check_child_directory(parent, name, descriptor, identity, label):
    try:
        opened = os.fstat(descriptor)
        final = os.stat(name, dir_fd=parent, follow_symlinks=False)
    except OSError as exc:
        raise EvidenceError("%s changed while it was in use: %s" % (label, exc))
    if file_identity(opened) != identity or file_identity(final) != identity:
        raise EvidenceError("%s changed while it was in use" % label)


def read_regular_file(directory, name, label, observed=None):
    validate_component(name, label)
    try:
        before = os.stat(name, dir_fd=directory, follow_symlinks=False)
    except OSError as exc:
        raise EvidenceError("%s is missing: %s" % (label, exc))
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise EvidenceError("%s is not a non-symlink regular file: %s" % (label, name))
    if before.st_size <= 0:
        raise EvidenceError("%s is empty: %s" % (label, name))

    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(name, flags, dir_fd=directory)
    except OSError as exc:
        raise EvidenceError("cannot open %s without following links: %s" % (label, exc))
    chunks = []
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode):
            raise EvidenceError("%s changed to a non-regular file" % label)
        if file_identity(before) != file_identity(opened):
            raise EvidenceError("%s changed while it was being opened" % label)
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)

    try:
        final = os.stat(name, dir_fd=directory, follow_symlinks=False)
    except OSError as exc:
        raise EvidenceError("%s changed after it was read: %s" % (label, exc))
    if (file_identity(before) != file_identity(after)
            or file_identity(after) != file_identity(final)):
        raise EvidenceError("%s changed while it was being read" % label)
    if observed is not None:
        observed.append((directory, name, label, file_identity(final)))
    return b"".join(chunks)


def check_observed_files(observed):
    for directory, name, label, identity in observed:
        try:
            current = os.stat(name, dir_fd=directory, follow_symlinks=False)
        except OSError as exc:
            raise EvidenceError("%s changed after it was read: %s" % (label, exc))
        if file_identity(current) != identity:
            raise EvidenceError("%s changed after it was read" % label)


def collect_entries(build_dir, fw_base, tag, directory=None):
    specs = entry_specs(fw_base, tag)
    expected_top = {
        relative for _, relative, _ in specs if os.sep not in relative
    }
    expected_simcal = {
        os.path.basename(relative) for _, relative, _ in specs
        if os.path.dirname(relative) == "simcal"
    }
    prefix = "%s-%s-" % (fw_base, tag)
    owns_directory = directory is None
    if owns_directory:
        build_fd, build_identity = open_directory(build_dir, "build directory")
    else:
        build_fd = directory
    try:
        simcal_fd, simcal_identity = open_child_directory(
            build_fd, "simcal", "simcal directory")
        observed = []
        for name in os.listdir(build_fd):
            if (name.startswith(prefix) and name.endswith((".hex", ".s", ".sym"))
                    and name not in expected_top):
                raise EvidenceError("unexpected PIC12F675 shipping artifact: %s" % name)
        for name in os.listdir(simcal_fd):
            if name.endswith("_simcal.hex") and name not in expected_simcal:
                raise EvidenceError("unexpected PIC12F675 simulator image: %s" % name)
        entries = {}
        for name, relative, _ in specs:
            directory = simcal_fd if os.path.dirname(relative) == "simcal" else build_fd
            filename = os.path.basename(relative)
            entries[name] = {
                "path": relative.replace(os.sep, "/"),
                "sha256": hashlib.sha256(
                    read_regular_file(directory, filename, name,
                                      observed=observed)).hexdigest(),
            }
        check_observed_files(observed)
        check_child_directory(build_fd, "simcal", simcal_fd,
                              simcal_identity, "simcal directory")
        if owns_directory:
            check_directory_path(build_dir, build_fd, build_identity,
                                 "build directory")
        return entries
    except OSError as exc:
        raise EvidenceError("cannot inventory PIC12F675 matrix directories: %s" % exc)
    finally:
        if "simcal_fd" in locals():
            os.close(simcal_fd)
        if owns_directory:
            os.close(build_fd)


def matrix_record(entries):
    fields = ["PIC12F675_MATRIX_SHA256", "format=%d" % FORMAT]
    for variant in VARIANTS:
        for prefix in ("shipping", "assembly", "symbols", "simcal"):
            name = "%s_%s" % (prefix, variant)
            fields.append("%s=%s" % (name, entries[name]["sha256"]))
    return " ".join(fields)


def manifest_path(build_dir, staged=False):
    return os.path.join(
        build_dir, STAGED_MANIFEST_NAME if staged else MANIFEST_NAME)


def publish_exclusive(build_dir, name, payload, directory=None):
    validate_component(name, "matrix evidence filename")
    owns_directory = directory is None
    if owns_directory:
        directory, identity = open_directory(build_dir, "build directory")
    temporary = ".matrix-evidence.%s" % uuid.uuid4().hex
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(temporary, flags, 0o600, dir_fd=directory)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(temporary, name, src_dir_fd=directory,
                    dst_dir_fd=directory, follow_symlinks=False)
        except FileExistsError:
            raise EvidenceError("matrix evidence already exists: %s" %
                                os.path.join(build_dir, name))
        os.fsync(directory)
        if owns_directory:
            check_directory_path(build_dir, directory, identity,
                                 "build directory", allow_changes=True)
    finally:
        try:
            os.unlink(temporary, dir_fd=directory)
        except FileNotFoundError:
            pass
        if owns_directory:
            os.close(directory)


def record_manifest(build_dir, fw_base, tag, staged=False):
    directory, identity = open_directory(build_dir, "build directory")
    try:
        entries = collect_entries(build_dir, fw_base, tag, directory=directory)
        record = matrix_record(entries)
        manifest = {
            "format": FORMAT,
            "device": "PIC12F675",
            "fw_base": fw_base,
            "tag": tag,
            "variants": list(VARIANTS),
            "entries": entries,
            "record": record,
        }
        payload = (json.dumps(manifest, sort_keys=True, separators=(",", ":")) +
                   "\n").encode("ascii")
        name = STAGED_MANIFEST_NAME if staged else MANIFEST_NAME
        publish_exclusive(build_dir, name, payload, directory=directory)
        if verify_manifest(build_dir, fw_base, tag, staged=staged,
                           directory=directory) != record:
            raise EvidenceError("published matrix evidence record changed")
        check_directory_path(build_dir, directory, identity, "build directory",
                             allow_changes=True)
        return record
    finally:
        os.close(directory)


def parse_manifest(payload, path, fw_base, tag):
    try:
        manifest = json.loads(payload.decode("ascii"),
                              object_pairs_hook=reject_duplicate_keys)
    except (UnicodeError, ValueError) as exc:
        raise EvidenceError("cannot read strict matrix evidence %s: %s" % (path, exc))

    expected_keys = {"format", "device", "fw_base", "tag", "variants", "entries", "record"}
    if not isinstance(manifest, dict) or set(manifest) != expected_keys:
        raise EvidenceError("matrix evidence has unexpected or missing fields")
    if (manifest["format"] != FORMAT or manifest["device"] != "PIC12F675"
            or manifest["fw_base"] != fw_base or manifest["tag"] != tag
            or manifest["variants"] != list(VARIANTS)):
        raise EvidenceError("matrix evidence identity does not match this build request")

    specs = entry_specs(fw_base, tag)
    expected_names = {name for name, _, _ in specs}
    if not isinstance(manifest["entries"], dict) or set(manifest["entries"]) != expected_names:
        raise EvidenceError("matrix evidence artifact inventory is not exact")
    for name, relative, _ in specs:
        entry = manifest["entries"].get(name)
        expected_path = relative.replace(os.sep, "/")
        if (not isinstance(entry, dict) or set(entry) != {"path", "sha256"}
                or entry.get("path") != expected_path
                or not isinstance(entry.get("sha256"), str)
                or len(entry["sha256"]) != 64
                or any(ch not in "0123456789abcdef" for ch in entry["sha256"])):
            raise EvidenceError("matrix evidence entry is malformed: %s" % name)
    expected_record = matrix_record(manifest["entries"])
    if manifest["record"] != expected_record:
        raise EvidenceError("matrix evidence record does not match its artifact hashes")
    return manifest


def read_manifest(build_dir, fw_base, tag, staged=False, directory=None,
                  observed=None):
    name = STAGED_MANIFEST_NAME if staged else MANIFEST_NAME
    path = manifest_path(build_dir, staged=staged)
    owns_directory = directory is None
    if owns_directory:
        directory, identity = open_directory(build_dir, "build directory")
    try:
        payload = read_regular_file(directory, name, "matrix evidence",
                                    observed=observed)
        if owns_directory:
            check_directory_path(build_dir, directory, identity,
                                 "build directory")
    except OSError as exc:
        raise EvidenceError("cannot read strict matrix evidence %s: %s" % (path, exc))
    finally:
        if owns_directory:
            os.close(directory)

    return parse_manifest(payload, path, fw_base, tag)


def read_manifest_file(path, fw_base, tag):
    path = os.path.abspath(os.path.normpath(path))
    parent = os.path.dirname(path)
    name = os.path.basename(path)
    validate_component(name, "matrix evidence filename")
    directory, identity = open_directory(parent, "matrix evidence directory")
    try:
        payload = read_regular_file(directory, name, "matrix evidence")
        check_directory_path(parent, directory, identity,
                             "matrix evidence directory")
    finally:
        os.close(directory)
    return parse_manifest(payload, path, fw_base, tag)


def verify_qualification_log(payload, matrix_record):
    try:
        text = payload.decode("ascii")
    except UnicodeError as exc:
        raise EvidenceError("PIC12F675 qualification log is not ASCII: %s" % exc)
    if "\r" in text:
        raise EvidenceError("PIC12F675 qualification log contains a carriage return")
    lines = text.splitlines()
    expected = [
        "=== PIC12F675 retained matrix qualified: %s ===" % matrix_record,
        "=== all PIC12F675 pre-hardware checks complete: %s ===" % matrix_record,
    ]
    expected.extend(
        "=== PIC12F675 target fault/lock-step/I-O PASS (variant %s): %s ===" %
        (variant, matrix_record) for variant in VARIANTS)
    expected.append(
        "=== PIC12F675 target fault/lock-step/I-O validated for all variants: %s ===" %
        matrix_record)
    for record in expected:
        if lines.count(record) != 1:
            raise EvidenceError(
                "PIC12F675 qualification log does not contain one exact "
                "matrix-bound PASS: %s" % record)
    matrix_lines = [line for line in lines if "PIC12F675_MATRIX_SHA256" in line]
    if len(matrix_lines) != len(expected):
        raise EvidenceError(
            "PIC12F675 qualification log has unexpected or duplicate matrix records")


def verify_release_manifest(manifest_path, qualification_log, release_dir,
                            expected_manifest_sha256, fw_base, tag):
    manifest_path = os.path.abspath(os.path.normpath(manifest_path))
    qualification_log = os.path.abspath(os.path.normpath(qualification_log))
    evidence_dir = os.path.dirname(manifest_path)
    if os.path.dirname(qualification_log) != evidence_dir:
        raise EvidenceError(
            "PIC12F675 matrix manifest and qualification log do not share one directory")
    manifest_name = os.path.basename(manifest_path)
    log_name = os.path.basename(qualification_log)
    validate_component(manifest_name, "matrix evidence filename")
    validate_component(log_name, "qualification log filename")
    if (len(expected_manifest_sha256) != 64
            or any(ch not in "0123456789abcdef"
                   for ch in expected_manifest_sha256)):
        raise EvidenceError("expected matrix manifest SHA-256 is malformed")

    evidence_directory, evidence_identity = open_directory(
        evidence_dir, "matrix evidence directory")
    release_dir = os.path.abspath(os.path.normpath(release_dir))
    directory = None
    observed = []
    try:
        directory, identity = open_directory(release_dir, "release directory")
        manifest_payload = read_regular_file(
            evidence_directory, manifest_name, "matrix evidence",
            observed=observed)
        manifest_digest = hashlib.sha256(manifest_payload).hexdigest()
        if manifest_digest != expected_manifest_sha256:
            raise EvidenceError(
                "retained PIC12F675 matrix digest does not match QUALIFICATION")
        manifest = parse_manifest(
            manifest_payload, manifest_path, fw_base, tag)
        log_payload = read_regular_file(
            evidence_directory, log_name, "PIC12F675 qualification log",
            observed=observed)
        verify_qualification_log(log_payload, manifest["record"])

        checksum_payload = read_regular_file(
            directory, "SHA256SUMS", "release checksums", observed=observed)
        try:
            checksum_text = checksum_payload.decode("ascii")
        except UnicodeError as exc:
            raise EvidenceError("release checksums are not ASCII: %s" % exc)
        if "\r" in checksum_text:
            raise EvidenceError("release checksums contain a carriage return")
        checksums = {}
        for line_no, line in enumerate(checksum_text.splitlines(), 1):
            if (len(line) < 67 or line[64:66] != "  "
                    or any(ch not in "0123456789abcdef" for ch in line[:64])):
                raise EvidenceError("malformed SHA256SUMS line %d" % line_no)
            name = line[66:]
            validate_component(name, "SHA256SUMS filename")
            if name in checksums:
                raise EvidenceError("duplicate SHA256SUMS filename: %s" % name)
            checksums[name] = line[:64]

        for name, relative, is_image in entry_specs(fw_base, tag):
            if not is_image or not name.startswith("shipping_"):
                continue
            filename = os.path.basename(relative)
            digest = hashlib.sha256(read_regular_file(
                directory, filename, "released %s" % name,
                observed=observed)).hexdigest()
            expected = manifest["entries"][name]["sha256"]
            if digest != expected:
                raise EvidenceError("released image does not match qualified matrix: %s" % filename)
            if checksums.get(filename) != expected:
                raise EvidenceError("SHA256SUMS does not match qualified matrix: %s" % filename)
        check_observed_files(observed)
        check_directory_path(evidence_dir, evidence_directory,
                             evidence_identity, "matrix evidence directory")
        check_directory_path(release_dir, directory, identity,
                             "release directory")
    finally:
        if directory is not None:
            os.close(directory)
        os.close(evidence_directory)
    return manifest["record"]


def verify_manifest(build_dir, fw_base, tag, staged=False, directory=None):
    owns_directory = directory is None
    if owns_directory:
        directory, identity = open_directory(build_dir, "build directory")
    manifest_observed = []
    try:
        manifest = read_manifest(build_dir, fw_base, tag, staged=staged,
                                 directory=directory,
                                 observed=manifest_observed)
        current = collect_entries(build_dir, fw_base, tag,
                                  directory=directory)
        check_observed_files(manifest_observed)
        if owns_directory:
            check_directory_path(build_dir, directory, identity,
                                 "build directory")
    finally:
        if owns_directory:
            os.close(directory)
    if current != manifest["entries"]:
        for name in sorted(current):
            if current[name] != manifest["entries"].get(name):
                raise EvidenceError("qualified matrix artifact changed: %s" % name)
        raise EvidenceError("qualified matrix artifact inventory changed")
    return manifest["record"]


def compare_shipping(build_dir, candidate_dir, fw_base, tag, staged=False):
    build_fd, build_identity = open_directory(build_dir, "build directory")
    candidate_fd, candidate_identity = open_directory(
        candidate_dir, "candidate build directory")
    observed = []
    try:
        manifest = read_manifest(build_dir, fw_base, tag, staged=staged,
                                 directory=build_fd, observed=observed)
        for name, relative, is_image in entry_specs(fw_base, tag):
            if name.startswith("simcal_"):
                continue
            label = "reproducibility_%s" % name
            candidate = hashlib.sha256(read_regular_file(
                candidate_fd, os.path.basename(relative), label,
                observed=observed)).hexdigest()
            if candidate != manifest["entries"][name]["sha256"]:
                kind = "image" if is_image else "sidecar"
                raise EvidenceError("private compiler witness changed %s %s" %
                                    (kind, name))
        check_observed_files(observed)
        check_directory_path(build_dir, build_fd, build_identity,
                             "build directory")
        check_directory_path(candidate_dir, candidate_fd, candidate_identity,
                             "candidate build directory")
        return manifest["record"]
    finally:
        os.close(candidate_fd)
        os.close(build_fd)


def promote_manifest(build_dir, fw_base, tag):
    directory, identity = open_directory(build_dir, "build directory")
    try:
        record = verify_manifest(build_dir, fw_base, tag, staged=True,
                                 directory=directory)
        staged = read_manifest(build_dir, fw_base, tag, staged=True,
                               directory=directory)
        payload = (json.dumps(staged, sort_keys=True, separators=(",", ":")) +
                   "\n").encode("ascii")
        publish_exclusive(build_dir, MANIFEST_NAME, payload,
                          directory=directory)
        if verify_manifest(build_dir, fw_base, tag,
                           directory=directory) != record:
            raise EvidenceError("promoted matrix evidence record changed")
        check_directory_path(build_dir, directory, identity, "build directory",
                             allow_changes=True)
        return record
    finally:
        os.close(directory)


def parse_args(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=(
        "record", "stage", "verify", "verify-staged", "compare-shipping",
        "compare-shipping-staged", "promote", "verify-file", "verify-release"))
    parser.add_argument("--build-dir")
    parser.add_argument("--candidate-build-dir")
    parser.add_argument("--manifest")
    parser.add_argument("--qualification-log")
    parser.add_argument("--release-dir")
    parser.add_argument("--expected-manifest-sha256")
    parser.add_argument("--fw-base", required=True)
    parser.add_argument("--tag", required=True)
    args = parser.parse_args(argv)
    validate_component(args.fw_base, "--fw-base")
    validate_component(args.tag, "--tag")
    build_commands = {
        "record", "stage", "verify", "verify-staged", "compare-shipping",
        "compare-shipping-staged", "promote",
    }
    if args.command in build_commands:
        if not args.build_dir:
            parser.error("%s requires --build-dir" % args.command)
        if (args.manifest or args.qualification_log or args.release_dir
                or args.expected_manifest_sha256):
            parser.error("release evidence arguments are not valid for build commands")
        args.build_dir = os.path.abspath(os.path.normpath(args.build_dir))
        build_fd, _ = open_directory(args.build_dir, "build directory")
        os.close(build_fd)
    elif args.build_dir or args.candidate_build_dir:
        parser.error("--build-dir/--candidate-build-dir require a build command")

    if args.command in ("compare-shipping", "compare-shipping-staged"):
        if not args.candidate_build_dir:
            parser.error("compare-shipping requires --candidate-build-dir")
        args.candidate_build_dir = os.path.abspath(
            os.path.normpath(args.candidate_build_dir))
        candidate_fd, _ = open_directory(
            args.candidate_build_dir, "candidate build directory")
        os.close(candidate_fd)
    elif args.candidate_build_dir:
        parser.error("--candidate-build-dir is valid only for compare-shipping")
    if args.command == "verify-file":
        if (not args.manifest or args.qualification_log or args.release_dir
                or args.expected_manifest_sha256):
            parser.error("verify-file requires only --manifest")
    elif args.command == "verify-release":
        if (not args.manifest or not args.qualification_log
                or not args.release_dir or not args.expected_manifest_sha256):
            parser.error(
                "verify-release requires --manifest, --qualification-log, "
                "--release-dir, and --expected-manifest-sha256")
    elif (args.manifest or args.qualification_log or args.release_dir
          or args.expected_manifest_sha256):
        parser.error("release evidence arguments require verify-file or verify-release")
    return args


def main(argv=None):
    try:
        args = parse_args(argv)
        if args.command == "verify-file":
            record = read_manifest_file(args.manifest, args.fw_base, args.tag)["record"]
        elif args.command == "verify-release":
            record = verify_release_manifest(
                args.manifest, args.qualification_log, args.release_dir,
                args.expected_manifest_sha256, args.fw_base, args.tag)
        elif args.command == "record":
            record = record_manifest(args.build_dir, args.fw_base, args.tag)
        elif args.command == "stage":
            record = record_manifest(
                args.build_dir, args.fw_base, args.tag, staged=True)
        elif args.command == "verify":
            record = verify_manifest(args.build_dir, args.fw_base, args.tag)
        elif args.command == "verify-staged":
            record = verify_manifest(
                args.build_dir, args.fw_base, args.tag, staged=True)
        elif args.command in ("compare-shipping", "compare-shipping-staged"):
            record = compare_shipping(args.build_dir, args.candidate_build_dir,
                                       args.fw_base, args.tag,
                                       staged=args.command.endswith("-staged"))
        else:
            record = promote_manifest(
                args.build_dir, args.fw_base, args.tag)
        print(record)
        return 0
    except EvidenceError as exc:
        print("FAIL: %s" % exc, file=sys.stderr)
        return 1
    except OSError as exc:
        print("FAIL: matrix evidence filesystem operation failed: %s" % exc,
              file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
