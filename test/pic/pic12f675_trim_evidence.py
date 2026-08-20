#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
"""Validate and retain PIC12F675 factory-trim programming evidence."""

import argparse
import base64
import datetime
import hashlib
import json
import os
import re
import shutil
import stat
import sys
import tempfile


SCHEMA = "mcu-bypass-pic12f675-trim-evidence-v2"
PART = "PIC12F675"
MAX_FILE_BYTES = 1024 * 1024
CAL_WORD_ADDR = 0x03FF
CONFIG_WORD_ADDR = 0x2007
BG_MASK = 0x3000
HEX_DIGITS = frozenset("0123456789abcdefABCDEF")
BASELINE_KEYS = frozenset({
    "schema", "record_type", "created_utc", "part", "reader_kind",
    "reader_path", "reader_realpath", "reader_sha256",
    "reader_version_base64", "reader_version_sha256",
    "device_read_base64", "device_read_sha256", "read_hex_base64",
    "read_hex_sha256",
    "device_id", "device_revision", "osccal_word", "osccal_value",
    "config_word", "bg_bits",
})
RESERVATION_KEYS = frozenset({
    "schema", "record_type", "status", "created_utc", "part", "variant",
    "release_tag", "release_source_commit",
    "baseline_sha256", "image_base64", "image_sha256",
    "reader_path", "reader_realpath", "reader_sha256",
    "reader_version_base64", "reader_version_sha256",
    "device_read_base64", "device_read_sha256", "read_hex_base64",
    "read_hex_sha256", "device_id", "device_revision", "osccal_word",
    "osccal_value", "config_word", "bg_bits", "writer_kind", "writer_path",
    "writer_realpath", "writer_sha256", "writer_version_base64",
    "writer_version_sha256",
})
RESULT_KEYS = frozenset({
    "schema", "record_type", "finalization_mode", "created_utc", "status",
    "failures", "part", "variant", "release_tag", "release_source_commit",
    "image_sha256",
    "programmed_image_bytes_verified", "baseline_sha256", "reservation_sha256",
    "baseline_osccal_word", "baseline_osccal_value", "baseline_config_word",
    "baseline_bg_bits", "prewrite_osccal_word", "prewrite_osccal_value",
    "prewrite_config_word", "prewrite_bg_bits", "post_osccal_word",
    "post_osccal_value", "post_config_word", "post_bg_bits", "device_id",
    "device_revision", "post_device_id", "post_device_revision", "reader_path",
    "reader_realpath", "reader_sha256", "reader_version_base64",
    "reader_version_sha256", "prewrite_read_base64", "prewrite_read_sha256",
    "prewrite_hex_base64", "prewrite_hex_sha256", "writer_kind", "writer_path",
    "writer_realpath", "writer_sha256", "writer_version_base64",
    "writer_version_sha256", "program_exit", "program_base64", "program_sha256",
    "post_read_exit", "post_read_base64", "post_read_sha256",
    "post_read_hex_base64", "post_read_hex_sha256",
})
RECOVERY_RESULT_KEYS = RESULT_KEYS | frozenset({"reader_version_exit"})


class EvidenceError(Exception):
    pass


def read_regular_bytes(path, label, allow_empty=False):
    try:
        info = os.lstat(path)
    except OSError as exc:
        raise EvidenceError("%s is unavailable: %s" % (label, exc)) from exc
    if stat.S_ISLNK(info.st_mode):
        raise EvidenceError("%s is a symbolic link: %s" % (label, path))
    if not stat.S_ISREG(info.st_mode):
        raise EvidenceError("%s is not a regular file: %s" % (label, path))
    if info.st_size == 0 and not allow_empty:
        raise EvidenceError("%s is empty: %s" % (label, path))
    if info.st_size > MAX_FILE_BYTES:
        raise EvidenceError("%s exceeds the %d-byte limit: %s"
                            % (label, MAX_FILE_BYTES, path))
    try:
        with open(path, "rb") as handle:
            return handle.read()
    except OSError as exc:
        raise EvidenceError("%s could not be read: %s" % (label, exc)) from exc


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def release_identity(release_tag, release_source_commit):
    tag = None if release_tag in (None, "") else release_tag
    commit = None if release_source_commit in (None, "") else release_source_commit
    if (tag is None) != (commit is None):
        raise EvidenceError("release tag and source commit must be supplied together")
    if tag is None:
        return None, None
    if not isinstance(tag, str) or re.fullmatch(
            r"v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?", tag) is None:
        raise EvidenceError("release tag is invalid")
    if not isinstance(commit, str) or re.fullmatch(r"[0-9a-f]{40}", commit) is None:
        raise EvidenceError("release source commit is not a full lowercase SHA-1")
    return tag, commit


def parse_hex_bytes(raw, label):
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError as exc:
        raise EvidenceError("%s is not ASCII: %s" % (label, exc)) from exc
    memory = {}
    saw_eof = False
    saw_record = False
    for lineno, raw_line in enumerate(text.splitlines(), 1):
        line = raw_line.strip()
        if not line:
            continue
        if saw_eof:
            raise EvidenceError("%s line %d: record follows EOF" % (label, lineno))
        if not line.startswith(":") or len(line) < 11 or len(line) % 2 == 0:
            raise EvidenceError("%s line %d: malformed Intel HEX record"
                                % (label, lineno))
        body = line[1:]
        if any(character not in HEX_DIGITS for character in body):
            raise EvidenceError("%s line %d: non-hexadecimal record"
                                % (label, lineno))
        try:
            record = bytes.fromhex(body)
        except ValueError as exc:
            raise EvidenceError("%s line %d: malformed hexadecimal bytes"
                                % (label, lineno)) from exc
        count = record[0]
        address = (record[1] << 8) | record[2]
        record_type = record[3]
        data = record[4:-1]
        if count != len(data) or sum(record) & 0xFF:
            raise EvidenceError("%s line %d: bad byte count or checksum"
                                % (label, lineno))
        saw_record = True
        if record_type == 1:
            if line.upper() != ":00000001FF":
                raise EvidenceError("%s line %d: malformed EOF" % (label, lineno))
            saw_eof = True
            continue
        # scripts/validate-ihex.sh accepts record types 02/03/04/05, and the
        # Makefile runs it on this same file immediately before this parser.
        # Accept the ones that cannot move or omit a byte, so the two cannot
        # disagree about a programmer's export: a zero extended-address base is
        # a no-op, and a start-address record has no memory effect. Every data
        # byte still lands at its literal 16-bit address, which is the property
        # the trim and image comparisons rest on.
        if record_type in (2, 4):
            if count != 2 or (data[0] | data[1]):
                raise EvidenceError(
                    "%s line %d: address relocation is not supported; record "
                    "type 0x%02X carries a non-zero base"
                    % (label, lineno, record_type))
            continue
        if record_type in (3, 5):
            if count != 4:
                raise EvidenceError("%s line %d: malformed start-address record"
                                    % (label, lineno))
            continue
        if record_type != 0 or count == 0:
            raise EvidenceError("%s line %d: unsupported record type 0x%02X"
                                % (label, lineno, record_type))
        if address + count > 0x10000:
            raise EvidenceError("%s line %d: record crosses 16-bit address space"
                                % (label, lineno))
        for offset, value in enumerate(data):
            byte_address = address + offset
            if byte_address in memory:
                raise EvidenceError("%s line %d: duplicate byte address 0x%04X"
                                    % (label, lineno, byte_address))
            memory[byte_address] = value
    if not saw_record or not saw_eof:
        raise EvidenceError("%s has no records or EOF" % label)
    return memory


def parse_hex(path, label):
    return parse_hex_bytes(read_regular_bytes(path, label), label)


def encoded_file(path, label, allow_empty=False):
    data = read_regular_bytes(path, label, allow_empty=allow_empty)
    return base64.b64encode(data).decode("ascii"), sha256_bytes(data), data


def executable_identity(path):
    invoked = os.path.abspath(path)
    resolved = os.path.realpath(invoked)
    data = read_regular_bytes(resolved, "programmer executable")
    try:
        if not os.access(resolved, os.X_OK):
            raise EvidenceError("programmer executable is not executable: %s" % path)
    except OSError as exc:
        raise EvidenceError("could not inspect programmer executable: %s" % exc) from exc
    return invoked, resolved, sha256_bytes(data)


def parse_device_report(data, label):
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError as exc:
        raise EvidenceError("%s is not ASCII: %s" % (label, exc)) from exc
    if PART not in text.upper():
        raise EvidenceError("%s does not identify %s" % (label, PART))
    id_match = re.search(
        r"(?im)^\s*device\s+id\s*(?:=|:)\s*(?:0x)?([0-9a-f]+)\b", text)
    revision_match = re.search(
        r"(?im)^\s*(?:device\s+)?revision\s*(?:=|:)\s*(?:0x)?([0-9a-f]+)\b",
        text)
    if id_match is None or revision_match is None:
        raise EvidenceError(
            "%s must report both Device ID and Device Revision" % label)
    return ("0x" + id_match.group(1).upper(),
            "0x" + revision_match.group(1).upper())


def extract_trim_memory(memory, label):
    def word_at(word_address, word_label):
        byte_address = word_address * 2
        if byte_address not in memory or byte_address + 1 not in memory:
            raise EvidenceError("%s contains no complete %s at word 0x%04X"
                                % (label, word_label, word_address))
        word = memory[byte_address] | (memory[byte_address + 1] << 8)
        if word & ~0x3FFF:
            raise EvidenceError("%s %s is not a 14-bit word: 0x%04X"
                                % (label, word_label, word))
        return word

    osccal = word_at(CAL_WORD_ADDR, "OSCCAL calibration instruction")
    if osccal & 0x3C00 != 0x3400:
        raise EvidenceError(
            "%s word 0x3FF is not RETLW k: 0x%04X" % (label, osccal))
    config = word_at(CONFIG_WORD_ADDR, "CONFIG")
    return {
        "osccal_word": "0x%04X" % osccal,
        "osccal_value": "0x%02X" % (osccal & 0xFF),
        "config_word": "0x%04X" % config,
        "bg_bits": "0x%04X" % (config & BG_MASK),
    }


def extract_trim(path, label):
    return extract_trim_memory(parse_hex(path, label), label)


def extract_trim_bytes(data, label):
    return extract_trim_memory(parse_hex_bytes(data, label), label)


def verify_programmed_image_memory(image_data, actual):
    # Proves: every byte the checked image requests arrived at the address it
    # requested, and CONFIG matches outside the factory BG<1:0> field.
    #
    # Does NOT prove: that flash the image does not cover reads erased. A
    # writer that programs this image correctly while leaving stale data
    # elsewhere still passes here. Asserting that would require knowing what
    # the reader exports for unprogrammed regions, which no lane here can
    # establish without a device.
    expected = parse_hex_bytes(image_data, "reserved programming image")
    config_byte = CONFIG_WORD_ADDR * 2
    compared = 0
    for address, value in expected.items():
        if address in (config_byte, config_byte + 1):
            continue
        if address not in actual:
            raise EvidenceError(
                "post-program read omits image byte address 0x%04X" % address)
        if actual[address] != value:
            raise EvidenceError(
                "post-program image byte differs at 0x%04X: expected 0x%02X, got 0x%02X"
                % (address, value, actual[address]))
        compared += 1
    for address in (config_byte, config_byte + 1):
        if address not in expected or address not in actual:
            raise EvidenceError("programming image or post-read omits CONFIG")
    expected_config = expected[config_byte] | (expected[config_byte + 1] << 8)
    actual_config = actual[config_byte] | (actual[config_byte + 1] << 8)
    if (expected_config & ~BG_MASK) != (actual_config & ~BG_MASK):
        raise EvidenceError(
            "post-program CONFIG differs outside factory BG<1:0>: expected 0x%04X, got 0x%04X"
            % (expected_config, actual_config))
    return compared + 2


def verify_programmed_image(image_data, post_read_path):
    actual = parse_hex(post_read_path, "post-program read HEX")
    return verify_programmed_image_memory(image_data, actual)


def verify_programmed_image_bytes(image_data, post_read_data):
    actual = parse_hex_bytes(post_read_data, "terminal post-read HEX")
    return verify_programmed_image_memory(image_data, actual)


def utc_now():
    # datetime.utcnow() is deprecated from Python 3.12, and because it would be
    # called from __main__ the default warning filter PRINTS the notice. Every
    # record this tool emits is compared for exact equality by the Makefile, so
    # one stray line is a false failure. Build the same naive-UTC string from an
    # aware value instead; datetime.timezone.utc predates the 3.7 minimum.
    return datetime.datetime.now(datetime.timezone.utc).replace(
        microsecond=0, tzinfo=None).isoformat() + "Z"


def fsync_file(path):
    try:
        with open(path, "rb") as handle:
            os.fsync(handle.fileno())
    except OSError as exc:
        raise EvidenceError("could not synchronize evidence file %s: %s"
                            % (path, exc)) from exc


def fsync_directory(path):
    try:
        descriptor = os.open(path, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    except OSError as exc:
        raise EvidenceError("could not synchronize evidence directory %s: %s"
                            % (path, exc)) from exc


def publish_json(path, record, label):
    destination = os.path.abspath(path)
    directory = os.path.dirname(destination) or "."
    if not os.path.isdir(directory):
        raise EvidenceError("output directory does not exist: %s" % directory)
    if os.path.lexists(destination):
        raise EvidenceError("%s already exists: %s" % (label, path))
    text = json.dumps(record, indent=2, sort_keys=True) + "\n"
    handle = tempfile.NamedTemporaryFile(
        mode="w", encoding="ascii", dir=directory, prefix=".trim-evidence-",
        delete=False)
    linked = False

    def rollback():
        for candidate in (handle.name, destination if linked else None):
            if candidate is not None:
                try:
                    os.unlink(candidate)
                except OSError:
                    pass
        if linked:
            try:
                fsync_directory(directory)
            except EvidenceError:
                pass

    try:
        with handle:
            handle.write(text)
        os.chmod(handle.name, 0o400)
        fsync_file(handle.name)
        os.link(handle.name, destination)
        linked = True
        os.unlink(handle.name)
        fsync_directory(directory)
    except FileExistsError as exc:
        rollback()
        raise EvidenceError("%s appeared while it was being published: %s"
                            % (label, path)) from exc
    except EvidenceError:
        rollback()
        raise
    except OSError as exc:
        rollback()
        raise EvidenceError("could not publish %s: %s" % (label, exc)) from exc


def publish_bytes(path, data, label):
    destination = os.path.abspath(path)
    directory = os.path.dirname(destination) or "."
    if not os.path.isdir(directory):
        raise EvidenceError("output directory does not exist: %s" % directory)
    if os.path.lexists(destination):
        raise EvidenceError("%s already exists: %s" % (label, path))
    handle = tempfile.NamedTemporaryFile(
        mode="wb", dir=directory, prefix=".trim-evidence-", delete=False)
    linked = False

    def rollback():
        for candidate in (handle.name, destination if linked else None):
            if candidate is not None:
                try:
                    os.unlink(candidate)
                except OSError:
                    pass
        if linked:
            try:
                fsync_directory(directory)
            except EvidenceError:
                pass

    try:
        with handle:
            handle.write(data)
        os.chmod(handle.name, 0o400)
        fsync_file(handle.name)
        os.link(handle.name, destination)
        linked = True
        os.unlink(handle.name)
        fsync_directory(directory)
    except FileExistsError as exc:
        rollback()
        raise EvidenceError("%s appeared while it was being published: %s"
                            % (label, path)) from exc
    except EvidenceError:
        rollback()
        raise
    except OSError as exc:
        rollback()
        raise EvidenceError("could not publish %s: %s" % (label, exc)) from exc


def seal_result_directory(output_dir, result_path):
    directory = os.path.abspath(output_dir)
    parent = os.path.dirname(directory) or "."
    try:
        os.chmod(directory, 0o500)
        fsync_directory(directory)
        fsync_directory(parent)
    except (EvidenceError, OSError) as exc:
        # Do not leave a visible verdict alongside a failed finalization command.
        try:
            os.chmod(directory, 0o700)
            os.unlink(result_path)
            fsync_directory(directory)
            fsync_directory(parent)
        except (EvidenceError, OSError):
            pass
        raise EvidenceError("could not seal terminal result directory: %s" % exc) from exc


def load_baseline(path):
    raw = read_regular_bytes(path, "baseline evidence")
    try:
        record = json.loads(raw.decode("ascii"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise EvidenceError("baseline evidence is not valid ASCII JSON: %s" % exc) from exc
    if not isinstance(record, dict) or frozenset(record) != BASELINE_KEYS:
        raise EvidenceError("baseline evidence does not have the exact v2 field set")
    if record["schema"] != SCHEMA or record["record_type"] != "baseline" \
            or record["part"] != PART or record["reader_kind"] != "pk2cmd":
        raise EvidenceError("baseline evidence has the wrong schema, type, part, or reader")
    for key in ("reader_sha256", "reader_version_sha256", "device_read_sha256",
                "read_hex_sha256"):
        value = record[key]
        if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
            raise EvidenceError("baseline evidence has an invalid %s" % key)
    decoded_fields = {}
    for key in ("reader_version_base64", "device_read_base64", "read_hex_base64"):
        try:
            decoded = base64.b64decode(record[key], validate=True)
        except (TypeError, ValueError) as exc:
            raise EvidenceError("baseline evidence has invalid %s" % key) from exc
        digest_key = key.replace("_base64", "_sha256")
        if not decoded or sha256_bytes(decoded) != record[digest_key]:
            raise EvidenceError("baseline evidence %s does not match its digest" % key)
        decoded_fields[key] = decoded
    device_id, revision = parse_device_report(
        decoded_fields["device_read_base64"], "retained device read transcript")
    trim = extract_trim_bytes(decoded_fields["read_hex_base64"], "retained read HEX")
    if record["device_id"] != device_id or record["device_revision"] != revision:
        raise EvidenceError("baseline device fields do not match the retained transcript")
    for key, value in trim.items():
        if record[key] != value:
            raise EvidenceError("baseline %s does not match the retained read HEX" % key)
    return record, raw


def load_reservation(path):
    raw = read_regular_bytes(path, "program reservation")
    try:
        record = json.loads(raw.decode("ascii"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise EvidenceError("program reservation is not valid ASCII JSON: %s" % exc) from exc
    if not isinstance(record, dict) or frozenset(record) != RESERVATION_KEYS:
        raise EvidenceError("program reservation does not have the exact v2 field set")
    if record["schema"] != SCHEMA or record["record_type"] != "program-reservation" \
            or record["status"] != "PENDING" or record["part"] != PART:
        raise EvidenceError("program reservation has the wrong schema, type, status, or part")
    release_identity(record["release_tag"], record["release_source_commit"])
    for key in ("baseline_sha256", "image_sha256", "reader_sha256",
                "reader_version_sha256", "device_read_sha256", "read_hex_sha256",
                "writer_sha256", "writer_version_sha256"):
        if not isinstance(record[key], str) \
                or re.fullmatch(r"[0-9a-f]{64}", record[key]) is None:
            raise EvidenceError("program reservation has an invalid %s" % key)
    decoded_fields = {}
    for key in ("image_base64", "reader_version_base64", "device_read_base64",
                "read_hex_base64", "writer_version_base64"):
        try:
            decoded = base64.b64decode(record[key], validate=True)
        except (TypeError, ValueError) as exc:
            raise EvidenceError("program reservation has invalid %s" % key) from exc
        digest_key = key.replace("_base64", "_sha256")
        if not decoded or sha256_bytes(decoded) != record[digest_key]:
            raise EvidenceError("program reservation %s does not match its digest" % key)
        decoded_fields[key] = decoded
    device_id, revision = parse_device_report(
        decoded_fields["device_read_base64"], "reserved device read transcript")
    trim = extract_trim_bytes(decoded_fields["read_hex_base64"], "reserved read HEX")
    if record["device_id"] != device_id or record["device_revision"] != revision:
        raise EvidenceError("reserved device fields do not match its transcript")
    for key, value in trim.items():
        if record[key] != value:
            raise EvidenceError("reserved %s does not match its read HEX" % key)
    parse_hex_bytes(decoded_fields["image_base64"], "reserved programming image")
    return record, raw


def validated_record_file(record, base64_key, sha256_key, label,
                          allow_none=False, allow_empty=False):
    encoded = record[base64_key]
    digest = record[sha256_key]
    if encoded is None or digest is None:
        if allow_none and encoded is None and digest is None:
            return None
        raise EvidenceError("terminal program result has incomplete %s" % label)
    if not isinstance(encoded, str) or not isinstance(digest, str) \
            or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
        raise EvidenceError("terminal program result has invalid %s metadata" % label)
    try:
        data = base64.b64decode(encoded, validate=True)
    except (TypeError, ValueError) as exc:
        raise EvidenceError("terminal program result has invalid %s data" % label) from exc
    if (not data and not allow_empty) or sha256_bytes(data) != digest:
        raise EvidenceError("terminal program result %s does not match its digest" % label)
    return data


def validate_terminal_result(path, baseline, baseline_raw,
                             reservation, reservation_raw):
    raw = read_regular_bytes(path, "terminal program result")
    try:
        record = json.loads(raw.decode("ascii"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise EvidenceError("terminal program result is not valid ASCII JSON: %s" % exc) from exc
    expected_keys = (RECOVERY_RESULT_KEYS if isinstance(record, dict)
                     and record.get("finalization_mode") == "recovery"
                     else RESULT_KEYS)
    required = {
        "schema": SCHEMA,
        "record_type": "program-result",
        "part": PART,
        "variant": reservation["variant"],
        "release_tag": reservation["release_tag"],
        "release_source_commit": reservation["release_source_commit"],
        "image_sha256": reservation["image_sha256"],
        "baseline_sha256": sha256_bytes(baseline_raw),
        "reservation_sha256": sha256_bytes(reservation_raw),
    }
    if not isinstance(record, dict) or frozenset(record) != expected_keys \
            or record.get("status") not in ("PASS", "FAIL") \
            or record.get("finalization_mode") not in ("direct", "recovery") \
            or any(record.get(key) != value for key, value in required.items()):
        raise EvidenceError("terminal program result does not match its reservation")
    failures = record["failures"]
    if not isinstance(failures, list) \
            or any(not isinstance(item, str) or not item for item in failures) \
            or (record["status"] == "PASS") != (not failures):
        raise EvidenceError("terminal program result status contradicts its failures")
    if type(record["post_read_exit"]) is not int \
            or type(record["programmed_image_bytes_verified"]) is not int \
            or record["programmed_image_bytes_verified"] < 0:
        raise EvidenceError("terminal program result has invalid numeric fields")
    if record["finalization_mode"] == "direct":
        if type(record["program_exit"]) is not int:
            raise EvidenceError("direct program result has invalid program exit status")
    elif record["program_exit"] is not None \
            or type(record["reader_version_exit"]) is not int:
        raise EvidenceError("recovery result has invalid execution status fields")

    reservation_fields = {
        "reader_path": "reader_path",
        "reader_realpath": "reader_realpath",
        "reader_sha256": "reader_sha256",
        "reader_version_base64": "reader_version_base64",
        "reader_version_sha256": "reader_version_sha256",
        "prewrite_read_base64": "device_read_base64",
        "prewrite_read_sha256": "device_read_sha256",
        "prewrite_hex_base64": "read_hex_base64",
        "prewrite_hex_sha256": "read_hex_sha256",
        "writer_kind": "writer_kind",
        "writer_path": "writer_path",
        "writer_realpath": "writer_realpath",
        "writer_sha256": "writer_sha256",
        "writer_version_base64": "writer_version_base64",
        "writer_version_sha256": "writer_version_sha256",
        "prewrite_osccal_word": "osccal_word",
        "prewrite_osccal_value": "osccal_value",
        "prewrite_config_word": "config_word",
        "prewrite_bg_bits": "bg_bits",
    }
    if any(record[result_key] != reservation[reservation_key]
           for result_key, reservation_key in reservation_fields.items()):
        raise EvidenceError("terminal program result identities differ from reservation")
    baseline_fields = (
        "osccal_word", "osccal_value", "config_word", "bg_bits",
    )
    if record["device_id"] != baseline["device_id"] \
            or record["device_revision"] != baseline["device_revision"] \
            or any(record["baseline_" + key] != baseline[key]
                   for key in baseline_fields):
        raise EvidenceError("terminal program result baseline fields are inconsistent")

    validated_record_file(
        record, "reader_version_base64", "reader_version_sha256",
        "reader version transcript")
    validated_record_file(
        record, "prewrite_read_base64", "prewrite_read_sha256",
        "pre-write transcript")
    validated_record_file(
        record, "prewrite_hex_base64", "prewrite_hex_sha256", "pre-write HEX")
    validated_record_file(
        record, "writer_version_base64", "writer_version_sha256",
        "writer version transcript")
    validated_record_file(
        record, "program_base64", "program_sha256", "program transcript",
        allow_none=True, allow_empty=True)
    post_read = validated_record_file(
        record, "post_read_base64", "post_read_sha256", "post-read transcript",
        allow_empty=True)
    post_hex = validated_record_file(
        record, "post_read_hex_base64", "post_read_hex_sha256", "post-read HEX",
        allow_none=True)
    post_trim_fields = tuple(record["post_" + key] for key in baseline_fields)
    if record["post_read_exit"] != 0:
        if post_hex is not None or record["post_device_id"] is not None \
                or record["post_device_revision"] is not None \
                or any(value is not None for value in post_trim_fields):
            raise EvidenceError("failed post-read has contradictory retained fields")
    else:
        try:
            post_device_id, post_revision = parse_device_report(
                post_read, "terminal post-read transcript")
        except EvidenceError:
            if record["status"] == "PASS" \
                    or record["post_device_id"] is not None \
                    or record["post_device_revision"] is not None:
                raise
            post_device_id = None
            post_revision = None
        if record["post_device_id"] != post_device_id \
                or record["post_device_revision"] != post_revision:
            raise EvidenceError("terminal program result post-read identity is inconsistent")
        post_trim = None
        if post_hex is not None:
            try:
                post_trim = extract_trim_memory(
                    parse_hex_bytes(post_hex, "terminal post-read HEX"),
                    "terminal post-read HEX")
            except EvidenceError:
                if record["status"] == "PASS" \
                        or any(value is not None for value in post_trim_fields):
                    raise
        if post_trim is None:
            if record["status"] == "PASS" \
                    or any(value is not None for value in post_trim_fields):
                raise EvidenceError("terminal result has inconsistent post-read trim fields")
        elif any(record["post_" + key] != post_trim[key]
                 for key in baseline_fields):
            raise EvidenceError("terminal program result post-read trim is inconsistent")

    if record["status"] == "PASS":
        if record["post_read_exit"] != 0 or post_hex is None \
                or (record["finalization_mode"] == "direct"
                    and record["program_exit"] != 0) \
                or (record["finalization_mode"] == "recovery"
                    and record["reader_version_exit"] != 0):
            raise EvidenceError("terminal PASS has unsuccessful execution status")
        image_data = base64.b64decode(reservation["image_base64"], validate=True)
        compared = verify_programmed_image_bytes(image_data, post_hex)
        if compared != record["programmed_image_bytes_verified"] \
                or record["post_device_id"] != baseline["device_id"] \
                or record["post_device_revision"] != baseline["device_revision"] \
                or record["post_osccal_word"] != baseline["osccal_word"] \
                or record["post_bg_bits"] != baseline["bg_bits"]:
            raise EvidenceError("terminal PASS does not replay its safety checks")


def seal_existing_result_directory(output_dir, result_path):
    directory = os.path.abspath(output_dir)
    parent = os.path.dirname(directory) or "."
    try:
        os.chmod(result_path, 0o400)
        fsync_file(result_path)
        os.chmod(directory, 0o500)
        fsync_directory(directory)
        fsync_directory(parent)
    except (EvidenceError, OSError) as exc:
        raise EvidenceError("could not seal existing terminal result: %s" % exc) from exc


def recovery_context(args):
    baseline, baseline_raw = load_baseline(args.baseline)
    reservation, reservation_raw = load_reservation(args.reservation)
    output_dir = os.path.abspath(args.output_dir)
    try:
        output_info = os.lstat(output_dir)
    except OSError as exc:
        raise EvidenceError("pending transaction directory is unavailable: %s" % exc) from exc
    if stat.S_ISLNK(output_info.st_mode) or not stat.S_ISDIR(output_info.st_mode):
        raise EvidenceError("pending transaction path is not a real directory: %s"
                            % args.output_dir)
    expected_reservation = os.path.join(output_dir, "reservation.json")
    if os.path.abspath(args.reservation) != expected_reservation:
        raise EvidenceError("reservation is not inside the selected transaction directory")
    result_path = os.path.join(output_dir, "result.json")
    if os.path.lexists(result_path):
        validate_terminal_result(
            result_path, baseline, baseline_raw, reservation, reservation_raw)
        seal_existing_result_directory(output_dir, result_path)
        raise EvidenceError("pending transaction already has result.json")
    retained_image = read_regular_bytes(
        os.path.join(output_dir, "image.hex"), "retained recovery image")
    try:
        reserved_image = base64.b64decode(reservation["image_base64"], validate=True)
    except (TypeError, ValueError) as exc:
        raise EvidenceError("reservation has invalid programming image data") from exc
    if retained_image != reserved_image \
            or sha256_bytes(retained_image) != reservation["image_sha256"]:
        raise EvidenceError("retained recovery image differs from reservation")
    if reservation["baseline_sha256"] != sha256_bytes(baseline_raw):
        raise EvidenceError("reservation baseline digest differs from selected baseline")
    if args.part != PART or reservation["part"] != args.part:
        raise EvidenceError("reservation part differs from selected part")
    if reservation["variant"] != args.variant:
        raise EvidenceError("reservation variant differs from selected variant")
    release_tag, release_source_commit = release_identity(
        args.release_tag, args.release_source_commit)
    if reservation["release_tag"] != release_tag \
            or reservation["release_source_commit"] != release_source_commit:
        raise EvidenceError("reservation release identity differs from selected release")
    reader_path, reader_realpath, reader_sha = executable_identity(args.reader_path)
    if reservation["reader_path"] != reader_path \
            or reservation["reader_realpath"] != reader_realpath \
            or reservation["reader_sha256"] != reader_sha:
        raise EvidenceError("reservation reader identity differs from selected reader")
    writer_path, writer_realpath, writer_sha = executable_identity(args.writer_path)
    if reservation["writer_kind"] != args.writer_kind \
            or reservation["writer_path"] != writer_path \
            or reservation["writer_realpath"] != writer_realpath \
            or reservation["writer_sha256"] != writer_sha:
        raise EvidenceError("reservation writer identity differs from selected writer")
    return {
        "baseline": baseline,
        "baseline_raw": baseline_raw,
        "reservation": reservation,
        "reservation_raw": reservation_raw,
        "reader_path": reader_path,
        "reader_realpath": reader_realpath,
        "reader_sha256": reader_sha,
        "writer_path": writer_path,
        "writer_realpath": writer_realpath,
        "writer_sha256": writer_sha,
    }


def optional_encoded_file(path, label):
    if not os.path.lexists(path):
        return None, None
    encoded, digest, _data = encoded_file(path, label, allow_empty=True)
    return encoded, digest


def current_reader(args):
    version_b64, version_sha, version_data = encoded_file(
        args.version_log, "reader version transcript")
    if b"PK2CMD" not in version_data.upper():
        raise EvidenceError("reader version transcript does not identify pk2cmd")
    read_b64, read_sha, read_data = encoded_file(args.read_log, "device read transcript")
    read_hex_b64, read_hex_sha, _read_hex_data = encoded_file(
        args.read_hex, "device read HEX")
    invoked, resolved, executable_sha = executable_identity(args.reader_path)
    device_id, revision = parse_device_report(read_data, "device read transcript")
    trim = extract_trim(args.read_hex, "device read HEX")
    return {
        "reader_path": invoked,
        "reader_realpath": resolved,
        "reader_sha256": executable_sha,
        "reader_version_base64": version_b64,
        "reader_version_sha256": version_sha,
        "device_read_base64": read_b64,
        "device_read_sha256": read_sha,
        "read_hex_base64": read_hex_b64,
        "read_hex_sha256": read_hex_sha,
        "device_id": device_id,
        "device_revision": revision,
        **trim,
    }


def baseline_command(args):
    current = current_reader(args)
    record = {
        "schema": SCHEMA,
        "record_type": "baseline",
        "created_utc": utc_now(),
        "part": PART,
        "reader_kind": "pk2cmd",
        **current,
    }
    publish_json(args.output, record, "baseline evidence")
    print("PIC12F675_TRIM_BASELINE PASS evidence=%s" % args.output)


def verify_reader(baseline, current):
    identity_keys = (
        "reader_path", "reader_realpath", "reader_sha256",
        "reader_version_base64", "reader_version_sha256",
        "device_id", "device_revision", "read_hex_sha256", "osccal_word",
        "osccal_value", "config_word", "bg_bits",
    )
    changed = [key for key in identity_keys if baseline[key] != current[key]]
    if changed:
        raise EvidenceError("current pre-write read differs from baseline: %s"
                            % ", ".join(changed))


def inspect_command(args):
    load_baseline(args.baseline)
    print("PIC12F675_TRIM_BASELINE_VALID PASS evidence=%s" % args.baseline)


def verify_command(args):
    baseline, _raw = load_baseline(args.baseline)
    current = current_reader(args)
    verify_reader(baseline, current)
    print("PIC12F675_TRIM_PREWRITE PASS evidence=%s" % args.baseline)


def reserve_command(args):
    baseline, baseline_raw = load_baseline(args.baseline)
    current = current_reader(args)
    verify_reader(baseline, current)
    writer_version_b64, writer_version_sha, writer_version = encoded_file(
        args.writer_version_log, "writer version transcript")
    upper_version = writer_version.upper()
    if args.writer_kind == "pk2cmd" and b"PK2CMD" not in upper_version:
        raise EvidenceError("writer version transcript does not identify pk2cmd")
    if args.writer_kind == "ipecmd" \
            and b"IPECMD" not in upper_version and b"MPLAB IPE" not in upper_version:
        raise EvidenceError("writer version transcript does not identify MPLAB IPE/ipecmd")
    writer_path, writer_realpath, writer_sha = executable_identity(args.writer_path)
    image_b64, image_sha, image_data = encoded_file(
        args.image_hex, "programming image")
    parse_hex_bytes(image_data, "programming image")
    release_tag, release_source_commit = release_identity(
        args.release_tag, args.release_source_commit)
    output_dir = os.path.abspath(args.output_dir)
    parent = os.path.dirname(output_dir) or "."
    if not os.path.isdir(parent):
        raise EvidenceError("bench-result parent directory does not exist: %s" % parent)
    try:
        os.mkdir(output_dir, 0o700)
    except FileExistsError as exc:
        raise EvidenceError("bench-result path already exists: %s" % args.output_dir) from exc
    except OSError as exc:
        raise EvidenceError("could not reserve bench-result directory: %s" % exc) from exc
    record = {
        "schema": SCHEMA,
        "record_type": "program-reservation",
        "status": "PENDING",
        "created_utc": utc_now(),
        "part": PART,
        "variant": args.variant,
        "release_tag": release_tag,
        "release_source_commit": release_source_commit,
        "baseline_sha256": sha256_bytes(baseline_raw),
        "image_base64": image_b64,
        "image_sha256": image_sha,
        **current,
        "writer_kind": args.writer_kind,
        "writer_path": writer_path,
        "writer_realpath": writer_realpath,
        "writer_sha256": writer_sha,
        "writer_version_base64": writer_version_b64,
        "writer_version_sha256": writer_version_sha,
    }
    retained_image = os.path.join(output_dir, "image.hex")
    reservation_path = os.path.join(output_dir, "reservation.json")
    try:
        publish_bytes(retained_image, image_data, "retained programming image")
        publish_json(reservation_path, record, "program reservation")
        fsync_directory(parent)
    except EvidenceError:
        for path in (reservation_path, retained_image):
            try:
                os.unlink(path)
            except OSError:
                pass
        try:
            os.rmdir(output_dir)
        except OSError:
            pass
        raise
    print("PIC12F675_TRIM_RESERVATION PASS evidence-dir=%s" % args.output_dir)


def result_command(args):
    baseline, baseline_raw = load_baseline(args.baseline)
    reservation, reservation_raw = load_reservation(args.reservation)
    current = current_reader(args)
    failures = []
    try:
        verify_reader(baseline, current)
    except EvidenceError as exc:
        failures.append(str(exc))

    writer_version_b64, writer_version_sha, _writer_version = encoded_file(
        args.writer_version_log, "writer version transcript")
    writer_path, writer_realpath, writer_sha = executable_identity(args.writer_path)
    if reservation["baseline_sha256"] != sha256_bytes(baseline_raw):
        failures.append("reservation baseline digest differs from current baseline")
    reservation_reader_keys = tuple(current)
    if any(reservation[key] != current[key] for key in reservation_reader_keys):
        failures.append("reservation reader/pre-write identity changed before result")
    if reservation["writer_kind"] != args.writer_kind \
            or reservation["writer_path"] != writer_path \
            or reservation["writer_realpath"] != writer_realpath \
            or reservation["writer_sha256"] != writer_sha \
            or reservation["writer_version_base64"] != writer_version_b64 \
            or reservation["writer_version_sha256"] != writer_version_sha:
        failures.append("reserved writer identity/version changed before result")
    program_b64, program_sha, _program_data = encoded_file(
        args.program_log, "program transcript", allow_empty=True)
    post_b64 = None
    post_sha = None
    post_hex_b64 = None
    post_hex_sha = None
    post_trim = {
        "osccal_word": None, "osccal_value": None,
        "config_word": None, "bg_bits": None,
    }
    post_device_id = None
    post_revision = None
    post_b64, post_sha, post_data = encoded_file(
        args.post_read_log, "post-program read transcript", allow_empty=True)
    if args.program_exit != 0:
        failures.append("programmer exited %d" % args.program_exit)
    if args.post_read_exit != 0:
        failures.append("post-program read exited %d" % args.post_read_exit)
    else:
        try:
            post_device_id, post_revision = parse_device_report(
                post_data, "post-program read transcript")
            post_hex_b64, post_hex_sha, _post_hex_data = encoded_file(
                args.post_read_hex, "post-program read HEX")
            post_trim = extract_trim(args.post_read_hex, "post-program read HEX")
            image_data = base64.b64decode(reservation["image_base64"], validate=True)
            compared_image_bytes = verify_programmed_image(image_data, args.post_read_hex)
            if post_device_id != baseline["device_id"]:
                failures.append("post-program Device ID differs from baseline")
            if post_revision != baseline["device_revision"]:
                failures.append("post-program Device Revision differs from baseline")
            if post_trim["osccal_word"] != baseline["osccal_word"]:
                failures.append("post-program OSCCAL word differs from baseline")
            if post_trim["bg_bits"] != baseline["bg_bits"]:
                failures.append("post-program BG<1:0> differs from baseline")
        except EvidenceError as exc:
            failures.append(str(exc))
            compared_image_bytes = 0

    if args.post_read_exit != 0:
        compared_image_bytes = 0

    record = {
        "schema": SCHEMA,
        "record_type": "program-result",
        "finalization_mode": "direct",
        "created_utc": utc_now(),
        "status": "FAIL" if failures else "PASS",
        "failures": failures,
        "part": PART,
        "variant": reservation["variant"],
        "release_tag": reservation["release_tag"],
        "release_source_commit": reservation["release_source_commit"],
        "image_sha256": reservation["image_sha256"],
        "programmed_image_bytes_verified": compared_image_bytes,
        "baseline_sha256": sha256_bytes(baseline_raw),
        "reservation_sha256": sha256_bytes(reservation_raw),
        "baseline_osccal_word": baseline["osccal_word"],
        "baseline_osccal_value": baseline["osccal_value"],
        "baseline_config_word": baseline["config_word"],
        "baseline_bg_bits": baseline["bg_bits"],
        "prewrite_osccal_word": current["osccal_word"],
        "prewrite_osccal_value": current["osccal_value"],
        "prewrite_config_word": current["config_word"],
        "prewrite_bg_bits": current["bg_bits"],
        "post_osccal_word": post_trim["osccal_word"],
        "post_osccal_value": post_trim["osccal_value"],
        "post_config_word": post_trim["config_word"],
        "post_bg_bits": post_trim["bg_bits"],
        "device_id": baseline["device_id"],
        "device_revision": baseline["device_revision"],
        "post_device_id": post_device_id,
        "post_device_revision": post_revision,
        "reader_path": current["reader_path"],
        "reader_realpath": current["reader_realpath"],
        "reader_sha256": current["reader_sha256"],
        "reader_version_base64": current["reader_version_base64"],
        "reader_version_sha256": current["reader_version_sha256"],
        "prewrite_read_base64": current["device_read_base64"],
        "prewrite_read_sha256": current["device_read_sha256"],
        "prewrite_hex_base64": current["read_hex_base64"],
        "prewrite_hex_sha256": current["read_hex_sha256"],
        "writer_kind": args.writer_kind,
        "writer_path": writer_path,
        "writer_realpath": writer_realpath,
        "writer_sha256": writer_sha,
        "writer_version_base64": writer_version_b64,
        "writer_version_sha256": writer_version_sha,
        "program_exit": args.program_exit,
        "program_base64": program_b64,
        "program_sha256": program_sha,
        "post_read_exit": args.post_read_exit,
        "post_read_base64": post_b64,
        "post_read_sha256": post_sha,
        "post_read_hex_base64": post_hex_b64,
        "post_read_hex_sha256": post_hex_sha,
    }
    for name in ("image.hex", "program.log", "postread.log", "postread.hex"):
        path = os.path.join(args.output_dir, name)
        if os.path.isfile(path):
            os.chmod(path, 0o400)
            fsync_file(path)
    fsync_directory(args.output_dir)
    output = os.path.join(args.output_dir, "result.json")
    publish_json(output, record, "program result evidence")
    seal_result_directory(args.output_dir, output)
    status = record["status"]
    print("PIC12F675_TRIM_RESULT %s evidence=%s" % (status, output))
    if failures:
        for failure in failures:
            print("FAIL: %s" % failure, file=sys.stderr)
        return 1
    return 0


def recovery_check_command(args):
    recovery_context(args)
    print("PIC12F675_TRIM_RECOVERY_READY PASS evidence-dir=%s" % args.output_dir)


def recovery_version_check_command(args):
    context = recovery_context(args)
    version_b64, version_sha, version_data = encoded_file(
        args.version_log, "recovery reader version transcript", allow_empty=True)
    if args.version_exit != 0:
        raise EvidenceError(
            "recovery reader version query exited %d" % args.version_exit)
    if b"PK2CMD" not in version_data.upper():
        raise EvidenceError(
            "recovery reader version transcript does not identify pk2cmd")
    reservation = context["reservation"]
    if reservation["reader_version_base64"] != version_b64 \
            or reservation["reader_version_sha256"] != version_sha:
        raise EvidenceError("recovery reader version differs from reservation")
    print("PIC12F675_TRIM_RECOVERY_READER PASS evidence-dir=%s" % args.output_dir)


def recovery_result_command(args):
    context = recovery_context(args)
    baseline = context["baseline"]
    baseline_raw = context["baseline_raw"]
    reservation = context["reservation"]
    reservation_raw = context["reservation_raw"]
    failures = []

    version_b64, version_sha, version_data = encoded_file(
        args.version_log, "recovery reader version transcript", allow_empty=True)
    if args.version_exit != 0:
        failures.append("recovery reader version query exited %d" % args.version_exit)
    elif b"PK2CMD" not in version_data.upper():
        failures.append("recovery reader version transcript does not identify pk2cmd")
    if reservation["reader_version_base64"] != version_b64 \
            or reservation["reader_version_sha256"] != version_sha:
        failures.append("recovery reader version differs from reservation")

    post_b64, post_sha, post_data = encoded_file(
        args.read_log, "recovery device read transcript", allow_empty=True)
    post_hex_b64 = None
    post_hex_sha = None
    post_trim = {
        "osccal_word": None, "osccal_value": None,
        "config_word": None, "bg_bits": None,
    }
    post_device_id = None
    post_revision = None
    compared_image_bytes = 0
    if args.read_exit != 0:
        failures.append("recovery device read exited %d" % args.read_exit)
    else:
        try:
            post_device_id, post_revision = parse_device_report(
                post_data, "recovery device read transcript")
            post_hex_b64, post_hex_sha, _post_hex_data = encoded_file(
                args.read_hex, "recovery device read HEX")
            post_trim = extract_trim(args.read_hex, "recovery device read HEX")
            image_data = base64.b64decode(reservation["image_base64"], validate=True)
            compared_image_bytes = verify_programmed_image(image_data, args.read_hex)
            if post_device_id != baseline["device_id"]:
                failures.append("recovery Device ID differs from baseline")
            if post_revision != baseline["device_revision"]:
                failures.append("recovery Device Revision differs from baseline")
            if post_trim["osccal_word"] != baseline["osccal_word"]:
                failures.append("recovery OSCCAL word differs from baseline")
            if post_trim["bg_bits"] != baseline["bg_bits"]:
                failures.append("recovery BG<1:0> differs from baseline")
        except EvidenceError as exc:
            failures.append(str(exc))
            compared_image_bytes = 0

    program_b64, program_sha = optional_encoded_file(
        args.program_log, "retained program transcript")
    record = {
        "schema": SCHEMA,
        "record_type": "program-result",
        "finalization_mode": "recovery",
        "created_utc": utc_now(),
        "status": "FAIL" if failures else "PASS",
        "failures": failures,
        "part": PART,
        "variant": reservation["variant"],
        "release_tag": reservation["release_tag"],
        "release_source_commit": reservation["release_source_commit"],
        "image_sha256": reservation["image_sha256"],
        "programmed_image_bytes_verified": compared_image_bytes,
        "baseline_sha256": sha256_bytes(baseline_raw),
        "reservation_sha256": sha256_bytes(reservation_raw),
        "baseline_osccal_word": baseline["osccal_word"],
        "baseline_osccal_value": baseline["osccal_value"],
        "baseline_config_word": baseline["config_word"],
        "baseline_bg_bits": baseline["bg_bits"],
        "prewrite_osccal_word": reservation["osccal_word"],
        "prewrite_osccal_value": reservation["osccal_value"],
        "prewrite_config_word": reservation["config_word"],
        "prewrite_bg_bits": reservation["bg_bits"],
        "post_osccal_word": post_trim["osccal_word"],
        "post_osccal_value": post_trim["osccal_value"],
        "post_config_word": post_trim["config_word"],
        "post_bg_bits": post_trim["bg_bits"],
        "device_id": baseline["device_id"],
        "device_revision": baseline["device_revision"],
        "post_device_id": post_device_id,
        "post_device_revision": post_revision,
        "reader_path": context["reader_path"],
        "reader_realpath": context["reader_realpath"],
        "reader_sha256": context["reader_sha256"],
        "reader_version_base64": version_b64,
        "reader_version_sha256": version_sha,
        "reader_version_exit": args.version_exit,
        "prewrite_read_base64": reservation["device_read_base64"],
        "prewrite_read_sha256": reservation["device_read_sha256"],
        "prewrite_hex_base64": reservation["read_hex_base64"],
        "prewrite_hex_sha256": reservation["read_hex_sha256"],
        "writer_kind": reservation["writer_kind"],
        "writer_path": context["writer_path"],
        "writer_realpath": context["writer_realpath"],
        "writer_sha256": context["writer_sha256"],
        "writer_version_base64": reservation["writer_version_base64"],
        "writer_version_sha256": reservation["writer_version_sha256"],
        "program_exit": None,
        "program_base64": program_b64,
        "program_sha256": program_sha,
        "post_read_exit": args.read_exit,
        "post_read_base64": post_b64,
        "post_read_sha256": post_sha,
        "post_read_hex_base64": post_hex_b64,
        "post_read_hex_sha256": post_hex_sha,
    }
    attempt_dir = os.path.abspath(args.attempt_dir)
    output_dir = os.path.abspath(args.output_dir)
    if os.path.dirname(attempt_dir) != output_dir \
            or not os.path.basename(attempt_dir).startswith(".recovery-"):
        raise EvidenceError("recovery attempt directory is outside the transaction")
    try:
        attempt_info = os.lstat(attempt_dir)
    except OSError as exc:
        raise EvidenceError("recovery attempt directory is unavailable: %s" % exc) from exc
    if stat.S_ISLNK(attempt_info.st_mode) or not stat.S_ISDIR(attempt_info.st_mode):
        raise EvidenceError("recovery attempt path is not a real directory")
    for path in (args.version_log, args.read_log, args.read_hex):
        if os.path.dirname(os.path.abspath(path)) != attempt_dir:
            raise EvidenceError("recovery transcript path escaped its private attempt")
    try:
        shutil.rmtree(attempt_dir)
    except OSError as exc:
        raise EvidenceError("could not remove private recovery attempt: %s" % exc) from exc
    for name in ("image.hex", "program.log", "reservation.json"):
        path = os.path.join(args.output_dir, name)
        if os.path.isfile(path):
            os.chmod(path, 0o400)
            fsync_file(path)
    fsync_directory(args.output_dir)
    output = os.path.join(args.output_dir, "result.json")
    publish_json(output, record, "recovered program result evidence")
    seal_result_directory(args.output_dir, output)
    status = record["status"]
    print("PIC12F675_TRIM_RECOVERY_RESULT %s evidence=%s" % (status, output))
    if failures:
        for failure in failures:
            print("FAIL: %s" % failure, file=sys.stderr)
        return 1
    return 0


def add_reader_arguments(parser):
    parser.add_argument("--reader-path", required=True)
    parser.add_argument("--version-log", required=True)
    parser.add_argument("--read-log", required=True)
    parser.add_argument("--read-hex", required=True)


def add_recovery_identity_arguments(parser):
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--reservation", required=True)
    parser.add_argument("--part", required=True)
    parser.add_argument("--variant", required=True)
    parser.add_argument("--reader-path", required=True)
    parser.add_argument("--writer-kind", choices=("pk2cmd", "ipecmd"), required=True)
    parser.add_argument("--writer-path", required=True)
    parser.add_argument("--release-tag", default="")
    parser.add_argument("--release-source-commit", default="")
    parser.add_argument("--output-dir", required=True)


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    # The host-only fake-programmer regression also runs on older developer
    # hosts; required= arrived in Python 3.7.
    subparsers = parser.add_subparsers(dest="command")

    baseline = subparsers.add_parser("baseline")
    add_reader_arguments(baseline)
    baseline.add_argument("--output", required=True)

    inspect = subparsers.add_parser("inspect")
    inspect.add_argument("--baseline", required=True)

    verify = subparsers.add_parser("verify")
    verify.add_argument("--baseline", required=True)
    add_reader_arguments(verify)

    reserve = subparsers.add_parser("reserve")
    reserve.add_argument("--baseline", required=True)
    add_reader_arguments(reserve)
    reserve.add_argument("--writer-kind", choices=("pk2cmd", "ipecmd"), required=True)
    reserve.add_argument("--writer-path", required=True)
    reserve.add_argument("--writer-version-log", required=True)
    reserve.add_argument("--image-hex", required=True)
    reserve.add_argument("--variant", required=True)
    reserve.add_argument("--release-tag", default="")
    reserve.add_argument("--release-source-commit", default="")
    reserve.add_argument("--output-dir", required=True)

    result = subparsers.add_parser("result")
    result.add_argument("--baseline", required=True)
    result.add_argument("--reservation", required=True)
    add_reader_arguments(result)
    result.add_argument("--writer-kind", choices=("pk2cmd", "ipecmd"), required=True)
    result.add_argument("--writer-path", required=True)
    result.add_argument("--writer-version-log", required=True)
    result.add_argument("--program-log", required=True)
    result.add_argument("--program-exit", type=int, required=True)
    result.add_argument("--post-read-log", required=True)
    result.add_argument("--post-read-hex", required=True)
    result.add_argument("--post-read-exit", type=int, required=True)
    result.add_argument("--output-dir", required=True)

    recovery_check = subparsers.add_parser("recovery-check")
    add_recovery_identity_arguments(recovery_check)

    recovery_version_check = subparsers.add_parser("recovery-version-check")
    add_recovery_identity_arguments(recovery_version_check)
    recovery_version_check.add_argument("--version-log", required=True)
    recovery_version_check.add_argument("--version-exit", type=int, required=True)

    recovery_result = subparsers.add_parser("recovery-result")
    add_recovery_identity_arguments(recovery_result)
    recovery_result.add_argument("--version-log", required=True)
    recovery_result.add_argument("--version-exit", type=int, required=True)
    recovery_result.add_argument("--read-log", required=True)
    recovery_result.add_argument("--read-hex", required=True)
    recovery_result.add_argument("--read-exit", type=int, required=True)
    recovery_result.add_argument("--program-log", required=True)
    recovery_result.add_argument("--attempt-dir", required=True)
    args = parser.parse_args(argv)
    if args.command is None:
        parser.error("a command is required")
    return args


def main(argv=None):
    args = parse_args(argv)
    try:
        if args.command == "baseline":
            baseline_command(args)
        elif args.command == "inspect":
            inspect_command(args)
        elif args.command == "verify":
            verify_command(args)
        elif args.command == "reserve":
            reserve_command(args)
        elif args.command == "result":
            return result_command(args)
        elif args.command == "recovery-check":
            recovery_check_command(args)
        elif args.command == "recovery-version-check":
            recovery_version_check_command(args)
        else:
            return recovery_result_command(args)
    except EvidenceError as exc:
        print("FAIL: %s" % exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
