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
import stat
import sys
import tempfile


SCHEMA = "mcu-bypass-pic12f675-trim-evidence-v1"
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
    "baseline_sha256", "image_base64", "image_sha256",
    "reader_path", "reader_realpath", "reader_sha256",
    "reader_version_base64", "reader_version_sha256",
    "device_read_base64", "device_read_sha256", "read_hex_base64",
    "read_hex_sha256", "device_id", "device_revision", "osccal_word",
    "osccal_value", "config_word", "bg_bits", "writer_kind", "writer_path",
    "writer_realpath", "writer_sha256", "writer_version_base64",
    "writer_version_sha256",
})


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


def verify_programmed_image(image_data, post_read_path):
    expected = parse_hex_bytes(image_data, "reserved programming image")
    actual = parse_hex(post_read_path, "post-program read HEX")
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
    try:
        with handle:
            handle.write(text)
        os.chmod(handle.name, 0o400)
        fsync_file(handle.name)
        os.link(handle.name, destination)
        os.unlink(handle.name)
        fsync_directory(directory)
    except FileExistsError as exc:
        try:
            os.unlink(handle.name)
        except OSError:
            pass
        raise EvidenceError("%s appeared while it was being published: %s"
                            % (label, path)) from exc
    except EvidenceError:
        try:
            os.unlink(handle.name)
        except OSError:
            pass
        raise
    except OSError as exc:
        try:
            os.unlink(handle.name)
        except OSError:
            pass
        raise EvidenceError("could not publish %s: %s" % (label, exc)) from exc


def load_baseline(path):
    raw = read_regular_bytes(path, "baseline evidence")
    try:
        record = json.loads(raw.decode("ascii"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise EvidenceError("baseline evidence is not valid ASCII JSON: %s" % exc) from exc
    if not isinstance(record, dict) or frozenset(record) != BASELINE_KEYS:
        raise EvidenceError("baseline evidence does not have the exact v1 field set")
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
        raise EvidenceError("program reservation does not have the exact v1 field set")
    if record["schema"] != SCHEMA or record["record_type"] != "program-reservation" \
            or record["status"] != "PENDING" or record["part"] != PART:
        raise EvidenceError("program reservation has the wrong schema, type, status, or part")
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
    try:
        publish_json(os.path.join(output_dir, "reservation.json"), record,
                     "program reservation")
        fsync_directory(parent)
    except EvidenceError:
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
        "created_utc": utc_now(),
        "status": "FAIL" if failures else "PASS",
        "failures": failures,
        "part": PART,
        "variant": reservation["variant"],
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
    output = os.path.join(args.output_dir, "result.json")
    publish_json(output, record, "program result evidence")
    for name in ("program.log", "postread.log", "postread.hex"):
        path = os.path.join(args.output_dir, name)
        if os.path.isfile(path):
            os.chmod(path, 0o400)
            fsync_file(path)
    os.chmod(args.output_dir, 0o500)
    fsync_directory(args.output_dir)
    status = record["status"]
    print("PIC12F675_TRIM_RESULT %s evidence=%s" % (status, output))
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
        else:
            return result_command(args)
    except EvidenceError as exc:
        print("FAIL: %s" % exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
