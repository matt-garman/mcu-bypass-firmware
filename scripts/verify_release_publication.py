#!/usr/bin/env python3
"""Record and verify the exact regular-file bundle passed to publication."""

import hashlib
import json
import os
import re
import stat
import sys


FORMAT = 1
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
MAX_INVENTORY_BYTES = 1024 * 1024


class PublicationError(Exception):
    pass


def identity(st):
    return (
        st.st_dev,
        st.st_ino,
        st.st_mode,
        st.st_nlink,
        st.st_size,
        st.st_mtime_ns,
        st.st_ctime_ns,
    )


def read_open_file(fd, display_name, maximum=None):
    chunks = []
    total = 0
    while True:
        chunk = os.read(fd, 1024 * 1024)
        if not chunk:
            break
        total += len(chunk)
        if maximum is not None and total > maximum:
            raise PublicationError("{} is too large".format(display_name))
        chunks.append(chunk)
    return b"".join(chunks)


def hash_bundle_file(directory_fd, name):
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_NONBLOCK", 0)
    try:
        fd = os.open(name, flags, dir_fd=directory_fd)
    except OSError as exc:
        raise PublicationError("could not open frozen asset {}: {}".format(name, exc))
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise PublicationError("frozen asset is not a regular file: {}".format(name))
        if before.st_size <= 0:
            raise PublicationError("frozen asset is empty: {}".format(name))
        digest = hashlib.sha256()
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        after = os.fstat(fd)
        if identity(before) != identity(after):
            raise PublicationError("frozen asset changed while hashing: {}".format(name))
        return {"name": name, "sha256": digest.hexdigest(), "size": before.st_size}, fd, before
    except Exception:
        os.close(fd)
        raise


def validate_expected_names(expected_names):
    if not expected_names:
        raise PublicationError("expected publication asset set is empty")
    for name in expected_names:
        if not SAFE_NAME.fullmatch(name):
            raise PublicationError("expected publication asset name is unsafe: {!r}".format(name))
    if len(expected_names) != len(set(expected_names)):
        raise PublicationError("expected publication asset set contains duplicates")
    return sorted(expected_names)


def snapshot_bundle(bundle, expected_names=None):
    try:
        path_status = os.lstat(bundle)
    except OSError as exc:
        raise PublicationError("could not inspect frozen bundle: {}".format(exc))
    if stat.S_ISLNK(path_status.st_mode) or not stat.S_ISDIR(path_status.st_mode):
        raise PublicationError("frozen bundle is not a real directory")

    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_DIRECTORY", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        directory_fd = os.open(bundle, flags)
    except OSError as exc:
        raise PublicationError("could not open frozen bundle: {}".format(exc))
    opened = []
    try:
        before = os.fstat(directory_fd)
        names = os.listdir(directory_fd)
        if not names:
            raise PublicationError("frozen bundle is empty")
        for name in names:
            if not SAFE_NAME.fullmatch(name):
                raise PublicationError("frozen bundle has an unsafe or hidden name: {!r}".format(name))
        if len(names) != len(set(names)):
            raise PublicationError("frozen bundle contains duplicate names")
        names = sorted(names)
        if expected_names is not None and names != validate_expected_names(expected_names):
            raise PublicationError("frozen bundle differs from the expected publication asset set")
        files = []
        for name in names:
            record, fd, file_status = hash_bundle_file(directory_fd, name)
            opened.append((name, fd, file_status))
            files.append(record)
        for name, fd, file_status in opened:
            if identity(file_status) != identity(os.fstat(fd)):
                raise PublicationError("frozen asset changed during bundle hashing: {}".format(name))
        after = os.fstat(directory_fd)
        if identity(before) != identity(after):
            raise PublicationError("frozen bundle changed while inventorying")
        return {"files": files, "format": FORMAT}
    finally:
        for _, fd, _ in opened:
            os.close(fd)
        os.close(directory_fd)


def canonical_bytes(payload):
    return (json.dumps(payload, ensure_ascii=True, separators=(",", ":"), sort_keys=True) + "\n").encode("ascii")


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise PublicationError("inventory contains duplicate JSON key: {}".format(key))
        result[key] = value
    return result


def parse_inventory(data):
    try:
        payload = json.loads(data.decode("ascii"), object_pairs_hook=reject_duplicate_keys)
    except (UnicodeDecodeError, ValueError, PublicationError) as exc:
        raise PublicationError("inventory is not canonical JSON: {}".format(exc))
    if not isinstance(payload, dict) or set(payload) != {"files", "format"}:
        raise PublicationError("inventory has an invalid top-level schema")
    if type(payload["format"]) is not int or payload["format"] != FORMAT:
        raise PublicationError("inventory has an unsupported format")
    files = payload["files"]
    if not isinstance(files, list) or not files:
        raise PublicationError("inventory has no file records")
    previous = None
    for record in files:
        if not isinstance(record, dict) or set(record) != {"name", "sha256", "size"}:
            raise PublicationError("inventory has an invalid file record")
        name = record["name"]
        digest = record["sha256"]
        size = record["size"]
        if not isinstance(name, str) or not SAFE_NAME.fullmatch(name):
            raise PublicationError("inventory has an unsafe file name")
        if previous is not None and name <= previous:
            raise PublicationError("inventory file records are not strictly sorted")
        if not isinstance(digest, str) or not SHA256.fullmatch(digest):
            raise PublicationError("inventory has an invalid SHA-256 digest")
        if type(size) is not int or size <= 0:
            raise PublicationError("inventory has an invalid file size")
        previous = name
    if canonical_bytes(payload) != data:
        raise PublicationError("inventory bytes are not in canonical form")
    return payload


def inventory_location_is_safe(bundle, inventory):
    bundle_real = os.path.realpath(bundle)
    inventory_real = os.path.join(
        os.path.realpath(os.path.dirname(os.path.abspath(inventory))),
        os.path.basename(inventory),
    )
    try:
        inside_bundle = os.path.commonpath((bundle_real, inventory_real)) == bundle_real
    except ValueError:
        inside_bundle = False
    if inside_bundle:
        raise PublicationError("inventory must be stored outside the frozen bundle")
    if not SAFE_NAME.fullmatch(os.path.basename(inventory)):
        raise PublicationError("inventory path has an unsafe basename")


def record(bundle, inventory, expected_names):
    inventory_location_is_safe(bundle, inventory)
    if os.path.lexists(inventory):
        raise PublicationError("inventory path already exists")
    payload = snapshot_bundle(bundle, expected_names)
    data = canonical_bytes(payload)
    parent = os.path.dirname(os.path.abspath(inventory))
    if not os.path.isdir(parent) or os.path.islink(parent):
        raise PublicationError("inventory parent is not a real directory")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    fd = None
    try:
        fd = os.open(inventory, flags, 0o400)
        view = memoryview(data)
        while view:
            written = os.write(fd, view)
            if written <= 0:
                raise PublicationError("could not write complete inventory")
            view = view[written:]
        os.fsync(fd)
    except Exception:
        if fd is not None:
            os.close(fd)
            fd = None
        raise
    finally:
        if fd is not None:
            os.close(fd)
    print(hashlib.sha256(data).hexdigest())


def read_inventory(inventory):
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(inventory, flags)
    except OSError as exc:
        raise PublicationError("could not open publication inventory: {}".format(exc))
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_size <= 0:
            raise PublicationError("publication inventory is not a regular nonempty file")
        data = read_open_file(fd, "publication inventory", MAX_INVENTORY_BYTES)
        after = os.fstat(fd)
        if identity(before) != identity(after):
            raise PublicationError("publication inventory changed while reading")
        return data
    finally:
        os.close(fd)


def verify(bundle, inventory, expected_digest):
    inventory_location_is_safe(bundle, inventory)
    if not SHA256.fullmatch(expected_digest):
        raise PublicationError("expected inventory SHA-256 is invalid")
    data = read_inventory(inventory)
    if hashlib.sha256(data).hexdigest() != expected_digest:
        raise PublicationError("publication inventory digest changed")
    expected = parse_inventory(data)
    actual = snapshot_bundle(bundle)
    if actual != expected:
        raise PublicationError("frozen publication bundle differs from its inventory")
    print("publication bundle verified: {} files".format(len(actual["files"])))


def main(argv):
    if len(argv) < 5 or argv[1] not in ("record", "verify"):
        print(
            "usage: verify_release_publication.py record BUNDLE INVENTORY EXPECTED_ASSET...\n"
            "       verify_release_publication.py verify BUNDLE INVENTORY EXPECTED_SHA256",
            file=sys.stderr,
        )
        return 2
    try:
        if argv[1] == "record" and len(argv) >= 5:
            record(argv[2], argv[3], argv[4:])
        elif argv[1] == "verify" and len(argv) == 5:
            verify(argv[2], argv[3], argv[4])
        else:
            return 2
    except (OSError, PublicationError) as exc:
        print("ERROR: {}".format(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
