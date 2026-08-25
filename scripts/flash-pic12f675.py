#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
"""Program a downloaded PIC12F675 release image with PICkit 3 and MPLAB X 6.20
ipecmd, preserving and verifying this device's factory OSCCAL and BG<1:0> trim.

This file ships inside every release bundle and is deliberately self-contained:
Python 3 plus the operator's existing ipecmd is the whole dependency list. It
needs no Make, Git, XC8, device pack, simulator, source checkout, or firmware
rebuild.

WHY IT EXISTS. Every other part in this project is a flash-and-forget target: a
correct HEX plus a writer is sufficient. The PIC12F675 is not. Two per-device
factory-trimmed values live in memory a programmer erases -- the OSCCAL
`RETLW k` at program word 0x3FF, which the startup code calls, and the
bandgap field BG<1:0> inside the CONFIG word, which sets the BOD/POR trip
points. Neither is in the shipping image, and destroying either leaves a device
that can look like it works while running at the wrong tick cadence, the wrong
relay/mute pulse widths, or the wrong brown-out threshold.

So this is a TRANSACTION, not a command: read-only baseline, an immediate
second read to prove the device did not move, a durable reservation, exactly one
write, and a mandatory full readback. Every precondition is checked before an
erase/program argument is reachable, and an interruption is PENDING rather than
an implicit success.

WHAT IT DOES NOT PROVE. That a real PICkit 3 / MPLAB X 6.20 erase preserves the
trim. This tool DETECTS damage after the fact; it cannot prevent a writer from
causing it. Until the controlled bench run recorded in HARDWARE_VALIDATION_LOG.md
is retained, treat a PASS as "no damage was observed on this device", not as
"the writer is known to be safe".
"""

import argparse
import base64
import datetime
import hashlib
import json
import os
import re
import stat
import subprocess
import sys


SCHEMA = "mcu-bypass-pic12f675-flash-v1"
PART = "PIC12F675"
TOOL = "PK3"
# `-TP` selects the tool family; `PK3` is the PICkit 3. MPLAB X 6.25 removed it.
TOOL_FLAG = "-TP"
IPE_VERSION = "6.20"
POWER_MODE = "external"

# Device geometry (DS41190G). Intel HEX byte address = program word address * 2,
# little-endian within the word.
FLASH_WORDS = 0x400
CAL_WORD_ADDR = 0x3FF
CONFIG_WORD_ADDR = 0x2007
BG_MASK = 0x3000
BG_ERASED = 0x3000
# The one CONFIG word every shipping PIC12F675 image in this project carries.
# BG<1:0> is left erased on purpose so the write never overwrites the factory
# bandgap trim with a value of the image's own.
EXPECTED_CONFIG_WORD = 0x31CC

IMAGE_BASENAME_RE = re.compile(
    r"^bypass-pic12f675-(cd4053_simple|cd4053_with_mute|tq2_l2_5v_relay)\.hex$")
CHECKSUM_ENTRY_RE = re.compile(
    r"^([0-9a-f]{64}) [ *]([A-Za-z0-9][A-Za-z0-9._-]*)$")
# Version tokens are harvested only from banner lines that name MPLAB, so an
# unrelated Java or JRE version in the same output cannot satisfy the pin.
IPE_BANNER_RE = re.compile(r"(?im)^.*\bMPLAB\b.*$")
IPE_VERSION_RE = re.compile(r"\bv?(\d+\.\d+)(?:\.\d+)*\b")
DEVICE_ID_RE = re.compile(r"(?im)^\s*device\s+id\s*(?:=|:)\s*(?:0x)?([0-9a-f]+)\b")
DEVICE_REVISION_RE = re.compile(
    r"(?im)^\s*(?:device\s+)?revision\s*(?:=|:)\s*(?:0x)?([0-9a-f]+)\b")

MAX_FILE_BYTES = 1024 * 1024
VERSION_PROBE_TIMEOUT_S = 300
DEVICE_TIMEOUT_S = 900
MAX_FINALIZE_ATTEMPTS = 64

RESERVATION_NAME = "reservation.json"
RESULT_NAME = "result.json"
IMAGE_SNAPSHOT_NAME = "image.hex"


class FlashError(Exception):
    """A fail-closed precondition or verification error."""


# ---------------------------------------------------------------------------
# byte-level helpers
# ---------------------------------------------------------------------------

def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def read_regular_bytes(path, label, max_bytes=MAX_FILE_BYTES):
    """Read a file that must be a plain, bounded, non-empty regular file.

    lstat first: a symlink is refused by TYPE rather than followed, so an
    operator cannot be pointed at a different image than the one named.
    """
    try:
        info = os.lstat(path)
    except OSError as exc:
        raise FlashError("%s is unavailable: %s" % (label, exc)) from exc
    if stat.S_ISLNK(info.st_mode):
        raise FlashError("%s is a symbolic link: %s" % (label, path))
    if not stat.S_ISREG(info.st_mode):
        raise FlashError("%s is not a regular file: %s" % (label, path))
    if info.st_size == 0:
        raise FlashError("%s is empty: %s" % (label, path))
    if info.st_size > max_bytes:
        raise FlashError("%s exceeds the %d-byte limit: %s"
                         % (label, max_bytes, path))
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError as exc:
        raise FlashError("%s could not be read: %s" % (label, exc)) from exc
    if len(data) != info.st_size:
        raise FlashError("%s changed size while being read: %s" % (label, path))
    return data


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------------------
# Intel HEX
# ---------------------------------------------------------------------------

def parse_ihex(raw, label, strict=True):
    """Parse Intel HEX into {byte address: value}.

    strict=True is for the RELEASE IMAGE: only record types 00/01/04 are
    accepted, an extended linear address must select segment 0, every address
    must be written at most once, and the file must end at its single EOF
    record. A device EXPORT is parsed with strict=False, which tolerates
    repeated writes of the same address (some readers emit overlapping runs)
    but nothing else.
    """
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError as exc:
        raise FlashError("%s is not ASCII: %s" % (label, exc)) from exc
    memory = {}
    base = 0
    saw_eof = False
    saw_data = False
    lines = text.splitlines()
    if not lines:
        raise FlashError("%s contains no records" % label)
    for lineno, line in enumerate(lines, 1):
        if line == "":
            # A trailing blank line is the only empty line a writer may emit,
            # and only after EOF; anywhere else it is a truncated record.
            if saw_eof:
                continue
            raise FlashError("%s line %d is empty" % (label, lineno))
        if saw_eof:
            raise FlashError("%s has a record after its EOF record (line %d)"
                             % (label, lineno))
        if not line.startswith(":"):
            raise FlashError("%s line %d does not start with ':'" % (label, lineno))
        body = line[1:]
        if len(body) < 10 or len(body) % 2 != 0:
            raise FlashError("%s line %d has an invalid record length" % (label, lineno))
        try:
            record = bytes.fromhex(body)
        except ValueError as exc:
            raise FlashError("%s line %d is not hexadecimal: %s"
                             % (label, lineno, exc)) from exc
        count = record[0]
        if len(record) != count + 5:
            raise FlashError("%s line %d byte count does not match its payload"
                             % (label, lineno))
        if (sum(record) & 0xFF) != 0:
            raise FlashError("%s line %d has a bad checksum" % (label, lineno))
        offset = (record[1] << 8) | record[2]
        rtype = record[3]
        payload = record[4:-1]
        if rtype == 0x00:
            if count == 0:
                raise FlashError("%s line %d is an empty data record"
                                 % (label, lineno))
            saw_data = True
            for i, value in enumerate(payload):
                address = base + offset + i
                if address > 0xFFFFFFFF:
                    raise FlashError("%s line %d addresses beyond 32 bits"
                                     % (label, lineno))
                if strict and address in memory:
                    raise FlashError(
                        "%s writes byte address 0x%04X twice (line %d)"
                        % (label, address, lineno))
                memory[address] = value
        elif rtype == 0x01:
            if count != 0:
                raise FlashError("%s line %d is a malformed EOF record"
                                 % (label, lineno))
            saw_eof = True
        elif rtype == 0x04:
            if count != 2:
                raise FlashError("%s line %d is a malformed extended linear "
                                 "address record" % (label, lineno))
            segment = (payload[0] << 8) | payload[1]
            if strict and segment != 0:
                raise FlashError(
                    "%s selects extended linear address segment 0x%04X; this "
                    "part has no memory there (line %d)"
                    % (label, segment, lineno))
            base = segment << 16
        else:
            raise FlashError("%s line %d uses unsupported record type 0x%02X"
                             % (label, lineno, rtype))
    if not saw_eof:
        raise FlashError("%s has no EOF record" % label)
    if not saw_data:
        raise FlashError("%s contains no data records" % label)
    return memory


def word_at(memory, word_address, label, what):
    byte_address = word_address * 2
    low = memory.get(byte_address)
    high = memory.get(byte_address + 1)
    if low is None or high is None:
        raise FlashError("%s contains no complete %s at word 0x%04X"
                         % (label, what, word_address))
    word = low | (high << 8)
    if word & ~0x3FFF:
        raise FlashError("%s %s is not a 14-bit word: 0x%04X"
                         % (label, what, word))
    return word


def image_words(memory, label):
    """Fold a parsed image into whole 14-bit words, refusing half words."""
    words = {}
    for address in sorted(memory):
        if address % 2 != 0:
            if address - 1 not in memory:
                raise FlashError("%s writes the high byte of word 0x%04X "
                                 "without its low byte" % (label, address // 2))
            continue
        if address + 1 not in memory:
            raise FlashError("%s writes the low byte of word 0x%04X without "
                             "its high byte" % (label, address // 2))
        word = memory[address] | (memory[address + 1] << 8)
        if word & ~0x3FFF:
            raise FlashError("%s word 0x%04X is not a 14-bit value: 0x%04X"
                             % (label, address // 2, word))
        words[address // 2] = word
    return words


def validate_release_image(data, label):
    """Reject any image that could damage this device before a write is reachable.

    The four failure modes this closes, in the order they are checked:
      * a structurally invalid or overlapping HEX (parse_ihex, strict);
      * an image that programs the OSCCAL word 0x3FF -- the simulator-only
        derived images in this project carry exactly such a word;
      * an image that writes ANY other calibration-bearing or out-of-range
        address (user IDs, the device ID word, EEPROM, past end of flash); and
      * a CONFIG word that is not this project's reviewed intent, or whose
        BG<1:0> field is not left erased.
    """
    memory = parse_ihex(data, label, strict=True)
    words = image_words(memory, label)
    program_words = 0
    for address in sorted(words):
        if address < FLASH_WORDS - 1:
            program_words += 1
            continue
        if address == CAL_WORD_ADDR:
            raise FlashError(
                "%s programs the OSCCAL calibration word 0x3FF (0x%04X); a "
                "write of that word destroys this device's factory oscillator "
                "trim. Shipping release images never carry it -- the derived "
                "simulator images do." % (label, words[address]))
        if address != CONFIG_WORD_ADDR:
            raise FlashError(
                "%s writes word 0x%04X, which is outside the program memory "
                "this release programs; user IDs, the device ID word and "
                "EEPROM are not part of a release image"
                % (label, address))
    if program_words == 0:
        raise FlashError("%s contains no program memory words" % label)
    if CONFIG_WORD_ADDR not in words:
        raise FlashError("%s carries no CONFIG word at 0x2007" % label)
    config = words[CONFIG_WORD_ADDR]
    if config != EXPECTED_CONFIG_WORD:
        raise FlashError(
            "%s CONFIG word is 0x%04X, not this release's reviewed 0x%04X"
            % (label, config, EXPECTED_CONFIG_WORD))
    if (config & BG_MASK) != BG_ERASED:
        raise FlashError(
            "%s CONFIG word 0x%04X does not leave BG<1:0> erased; programming "
            "it would overwrite the factory bandgap trim" % (label, config))
    return {
        "program_words": program_words,
        "config_word": "0x%04X" % config,
        "memory": memory,
    }


def read_trim(memory, label, require_retlw=True):
    """Extract the two factory values plus CONFIG from a full-device export.

    require_retlw is the difference between the two sides of the write. BEFORE
    it, a device whose word 0x3FF is not a `RETLW k` has no factory trim to
    preserve and must not be programmed, so a missing or malformed calibration
    word is fatal. AFTER it, that same observation is the headline RESULT --
    the trim was destroyed -- and must reach result.json as a named failure
    rather than abort the readback that discovered it.
    """
    osccal = None
    try:
        osccal = word_at(memory, CAL_WORD_ADDR, label,
                         "OSCCAL calibration instruction")
    except FlashError:
        if require_retlw:
            raise
    if osccal is None:
        osccal_word = "absent"
        osccal_value = "absent"
    else:
        if require_retlw and (osccal & 0x3C00) != 0x3400:
            raise FlashError(
                "%s word 0x3FF is not RETLW k: 0x%04X. This device has no valid "
                "factory oscillator trim to preserve; do not program it."
                % (label, osccal))
        osccal_word = "0x%04X" % osccal
        osccal_value = "0x%02X" % (osccal & 0xFF)
    config = word_at(memory, CONFIG_WORD_ADDR, label, "CONFIG word")
    return {
        "osccal_word": osccal_word,
        "osccal_value": osccal_value,
        "config_word": "0x%04X" % config,
        "bg_bits": "0x%04X" % (config & BG_MASK),
    }


def parse_device_report(data, label):
    """Device identity, taken from the tool transcript rather than the export."""
    try:
        text = data.decode("ascii", "replace")
    except Exception as exc:  # pragma: no cover - decode with replace cannot raise
        raise FlashError("%s could not be decoded: %s" % (label, exc)) from exc
    if PART not in text.upper():
        raise FlashError("%s does not identify %s" % (label, PART))
    id_match = DEVICE_ID_RE.search(text)
    revision_match = DEVICE_REVISION_RE.search(text)
    if id_match is None or revision_match is None:
        raise FlashError("%s must report both Device ID and Device Revision"
                         % label)
    return ("0x" + id_match.group(1).upper(),
            "0x" + revision_match.group(1).upper())


# ---------------------------------------------------------------------------
# the release bundle
# ---------------------------------------------------------------------------

def parse_checksums(data, label):
    entries = {}
    text = data.decode("ascii", "replace")
    for lineno, line in enumerate(text.splitlines(), 1):
        if line == "":
            continue
        match = CHECKSUM_ENTRY_RE.match(line)
        if match is None:
            raise FlashError("%s line %d is not a sha256sum entry: %s"
                             % (label, lineno, line))
        digest, name = match.group(1), match.group(2)
        if name in entries:
            raise FlashError("%s lists %s twice" % (label, name))
        entries[name] = digest
    if not entries:
        raise FlashError("%s lists no files" % label)
    return entries


def bundle_identity(image_path, helper_path):
    """Bind the selected image to the release bundle it was downloaded with.

    The digest comes from the bundle's SHA256SUMS, which is what the detached
    signature covers; the operator is told to verify that signature first, and
    its presence is required so the instruction is actionable.
    """
    image_path = os.path.abspath(image_path)
    image_dir = os.path.dirname(image_path)
    image_name = os.path.basename(image_path)
    if IMAGE_BASENAME_RE.match(image_name) is None:
        raise FlashError(
            "selected image is not a released PIC12F675 image basename: %s "
            "(expected bypass-pic12f675-<output stage>.hex)" % image_name)
    checksum_path = os.path.join(image_dir, "SHA256SUMS")
    signature_path = checksum_path + ".asc"
    checksum_data = read_regular_bytes(checksum_path, "release SHA256SUMS")
    signature_data = read_regular_bytes(
        signature_path,
        "release SHA256SUMS.asc (download it beside the image and verify it "
        "with gpg before programming)")
    entries = parse_checksums(checksum_data, "release SHA256SUMS")
    if image_name not in entries:
        raise FlashError("release SHA256SUMS does not list %s" % image_name)

    image_data = read_regular_bytes(image_path, "selected release image")
    image_sha256 = sha256_bytes(image_data)
    if image_sha256 != entries[image_name]:
        raise FlashError(
            "selected release image does not match its signed checksum: "
            "%s has %s, SHA256SUMS records %s"
            % (image_name, image_sha256, entries[image_name]))

    helper_data = read_regular_bytes(helper_path, "flashing helper")
    helper_sha256 = sha256_bytes(helper_data)
    helper_name = os.path.basename(helper_path)
    helper_bound = False
    # Compare RESOLVED directories: a bundle reached through a symlinked path
    # would otherwise silently skip the helper's own checksum binding rather
    # than fail, which is the wrong direction for a check that exists to catch
    # a tampered tool.
    if os.path.dirname(os.path.realpath(image_path)) == os.path.dirname(helper_path):
        # Running from inside the bundle: the helper is a signed artifact too,
        # so hold it to the same standard as the image it is about to write.
        if helper_name not in entries:
            raise FlashError("release SHA256SUMS does not list the helper %s"
                             % helper_name)
        if helper_sha256 != entries[helper_name]:
            raise FlashError(
                "flashing helper does not match its signed checksum: %s has "
                "%s, SHA256SUMS records %s"
                % (helper_name, helper_sha256, entries[helper_name]))
        helper_bound = True

    return {
        "image_path": image_path,
        "image_name": image_name,
        "image_data": image_data,
        "image_sha256": image_sha256,
        "checksums_sha256": sha256_bytes(checksum_data),
        "checksums_signature_sha256": sha256_bytes(signature_data),
        "helper_name": helper_name,
        "helper_path": helper_path,
        "helper_sha256": helper_sha256,
        "helper_checksum_bound": helper_bound,
    }


# ---------------------------------------------------------------------------
# the programmer
# ---------------------------------------------------------------------------

def which(program):
    if os.path.dirname(program):
        return program if os.access(program, os.X_OK) else None
    for element in os.environ.get("PATH", "").split(os.pathsep):
        if not element:
            continue
        candidate = os.path.join(element, program)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def programmer_identity(path, java):
    """Resolve the one supported ipecmd form and hash the exact bytes used."""
    invoked = os.path.abspath(path)
    resolved = os.path.realpath(invoked)
    data = read_regular_bytes(resolved, "ipecmd", max_bytes=256 * 1024 * 1024)
    if resolved.endswith(".jar"):
        kind = "jar"
        java_path = which(java)
        if java_path is None:
            raise FlashError(
                "a .jar ipecmd needs a Java runtime; '%s' was not found on PATH"
                % java)
        java_path = os.path.realpath(java_path)
        prefix = [java_path, "-jar", resolved]
    else:
        kind = "executable"
        if not os.access(resolved, os.X_OK):
            raise FlashError("ipecmd is not executable: %s" % path)
        java_path = None
        prefix = [resolved]
    return {
        "kind": kind,
        "path": invoked,
        "realpath": resolved,
        "sha256": sha256_bytes(data),
        "java": java_path,
        "prefix": prefix,
    }


def run_tool(argv, timeout, label):
    try:
        completed = subprocess.run(
            argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, timeout=timeout, shell=False, check=False)
    except subprocess.TimeoutExpired as exc:
        raise FlashError("%s did not finish within %ds" % (label, timeout)) from exc
    except OSError as exc:
        raise FlashError("%s could not be started: %s" % (label, exc)) from exc
    return completed.returncode, completed.stdout


def probe_version(programmer):
    """Pin the writer to MPLAB X 6.20 before any device access.

    MPLAB X 6.25 dropped PICkit 3 support, and the argument spellings this tool
    constructs are validated against 6.20 only. The probe is help output: it
    names no part, no tool and no file, so it cannot reach the device.
    """
    argv = programmer["prefix"] + ["-?"]
    exit_code, output = run_tool(argv, VERSION_PROBE_TIMEOUT_S, "ipecmd version probe")
    text = output.decode("ascii", "replace")
    found = set()
    for line in IPE_BANNER_RE.findall(text):
        for version in IPE_VERSION_RE.findall(line):
            found.add(version)
    if not found:
        raise FlashError(
            "ipecmd printed no recognizable MPLAB X version banner; this "
            "helper supports MPLAB X %s only (probe exit %d)"
            % (IPE_VERSION, exit_code))
    if found != {IPE_VERSION}:
        raise FlashError(
            "ipecmd reports MPLAB X version(s) %s; this helper supports %s "
            "only. MPLAB X 6.25 and later dropped PICkit 3 support."
            % (", ".join(sorted(found)), IPE_VERSION))
    return {
        "version": IPE_VERSION,
        "probe_exit": exit_code,
        "probe_base64": base64.b64encode(output).decode("ascii"),
        "probe_sha256": sha256_bytes(output),
    }


def read_argv(programmer, export_path):
    """The one full-device read/export command. Contains no erase or program
    option, so this argv can never mutate the device."""
    return programmer["prefix"] + [
        TOOL_FLAG + TOOL, "-P" + PART, "-GF" + export_path,
    ]


def write_argv(programmer, image_path):
    """The one validated write command.

    -M programs the whole device, -Y verifies, -OL releases from reset. -W5 is
    deliberately absent: the qualified arrangement is an externally powered
    board, and no programmer-powered voltage/interface setup has been retained
    as hardware evidence. Nothing here is caller-supplied except the paths this
    tool itself snapshotted.
    """
    return programmer["prefix"] + [
        TOOL_FLAG + TOOL, "-P" + PART, "-F" + image_path, "-M", "-Y", "-OL",
    ]


# ---------------------------------------------------------------------------
# evidence
# ---------------------------------------------------------------------------

def create_evidence_dir(path):
    """Create the evidence directory exclusively, or refuse.

    Exclusive creation is the whole point: an existing directory could already
    hold another device's transaction, and silently adding to it would destroy
    the one-directory-one-device binding every later check rests on.
    """
    # normpath first: `--evidence-dir ./device-001/` is an ordinary way to type
    # a directory, and a trailing separator must not read as "no final
    # component".
    path = os.path.abspath(os.path.normpath(path))
    parent = os.path.dirname(path)
    if os.path.basename(path) in ("", ".", ".."):
        raise FlashError("evidence path does not name a new directory: %s" % path)
    try:
        parent_info = os.stat(parent)
    except OSError as exc:
        raise FlashError("evidence directory's parent is unavailable: %s" % exc) from exc
    if not stat.S_ISDIR(parent_info.st_mode):
        raise FlashError("evidence directory's parent is not a directory: %s" % parent)
    if (parent_info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)) \
            and not (parent_info.st_mode & stat.S_ISVTX):
        raise FlashError(
            "evidence directory's parent is group/other-writable without the "
            "sticky bit; another user could replace the retained evidence: %s"
            % parent)
    if os.path.lexists(path):
        raise FlashError(
            "evidence path already exists; choose a new one so this device's "
            "transaction cannot be confused with another: %s" % path)
    try:
        os.mkdir(path, 0o700)
    except OSError as exc:
        raise FlashError("could not create the evidence directory: %s" % exc) from exc
    return path


def open_evidence_dir(path):
    path = os.path.abspath(os.path.normpath(path))
    try:
        info = os.lstat(path)
    except OSError as exc:
        raise FlashError("evidence directory is unavailable: %s" % exc) from exc
    if stat.S_ISLNK(info.st_mode):
        raise FlashError("evidence directory is a symbolic link: %s" % path)
    if not stat.S_ISDIR(info.st_mode):
        raise FlashError("evidence directory is not a directory: %s" % path)
    return path


def fsync_dir(path):
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError as exc:
        raise FlashError("could not open the evidence directory: %s" % exc) from exc
    try:
        os.fsync(fd)
    except OSError as exc:
        raise FlashError("could not flush the evidence directory: %s" % exc) from exc
    finally:
        os.close(fd)


def publish_bytes(path, data, label):
    """Write one evidence file exclusively, then flush it and its directory.

    O_EXCL is what makes result.json immutable: a second publication attempt
    fails rather than overwriting a forensic record.
    """
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o400)
    except FileExistsError as exc:
        raise FlashError("%s already exists and is immutable: %s"
                         % (label, path)) from exc
    except OSError as exc:
        raise FlashError("could not create %s: %s" % (label, exc)) from exc
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    except OSError as exc:
        raise FlashError("could not write %s: %s" % (label, exc)) from exc
    fsync_dir(os.path.dirname(path))


def publish_json(path, record, label):
    data = (json.dumps(record, indent=2, sort_keys=True) + "\n").encode("ascii")
    publish_bytes(path, data, label)


def load_json(path, label):
    data = read_regular_bytes(path, label, max_bytes=8 * MAX_FILE_BYTES)
    try:
        record = json.loads(data.decode("ascii"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise FlashError("%s is not valid JSON: %s" % (label, exc)) from exc
    if not isinstance(record, dict):
        raise FlashError("%s is not a JSON object" % label)
    return record


def device_read(programmer, evidence_dir, tag, require_retlw=True):
    """One full-device read: transcript, export, and everything parsed from it."""
    log_path = os.path.join(evidence_dir, tag + ".log")
    hex_path = os.path.join(evidence_dir, tag + ".hex")
    if os.path.lexists(hex_path):
        raise FlashError("a %s export already exists: %s" % (tag, hex_path))
    argv = read_argv(programmer, hex_path)
    exit_code, output = run_tool(argv, DEVICE_TIMEOUT_S, "ipecmd device read (%s)" % tag)
    publish_bytes(log_path, output, "%s transcript" % tag)
    record = {
        "argv": argv,
        "exit": exit_code,
        "log_sha256": sha256_bytes(output),
        "log_base64": base64.b64encode(output).decode("ascii"),
    }
    if exit_code != 0:
        raise FlashError("ipecmd %s read failed with exit %d; see %s"
                         % (tag, exit_code, log_path))
    export = read_regular_bytes(hex_path, "%s device export" % tag)
    os.chmod(hex_path, 0o400)
    memory = parse_ihex(export, "%s device export" % tag, strict=False)
    device_id, revision = parse_device_report(output, "%s transcript" % tag)
    record.update({
        "hex_sha256": sha256_bytes(export),
        "hex_base64": base64.b64encode(export).decode("ascii"),
        "device_id": device_id,
        "device_revision": revision,
    })
    record.update(read_trim(memory, "%s device export" % tag, require_retlw))
    return record, memory


def verify_programmed(image_memory, actual, failures):
    """Every byte the image requested arrived where it was requested.

    CONFIG is compared outside BG<1:0> only: the factory bandgap field is not
    the image's to assert, and is checked separately against both pre-write
    reads.
    """
    config_byte = CONFIG_WORD_ADDR * 2
    compared = 0
    for address in sorted(image_memory):
        if address in (config_byte, config_byte + 1):
            continue
        if address not in actual:
            failures.append("post-program read omits image byte address 0x%04X"
                            % address)
            return compared
        if actual[address] != image_memory[address]:
            failures.append(
                "post-program byte differs at 0x%04X: image 0x%02X, device 0x%02X"
                % (address, image_memory[address], actual[address]))
            return compared
        compared += 1
    if config_byte not in actual or config_byte + 1 not in actual:
        failures.append("post-program read omits the CONFIG word")
        return compared
    expected_config = image_memory[config_byte] | (image_memory[config_byte + 1] << 8)
    actual_config = actual[config_byte] | (actual[config_byte + 1] << 8)
    if (expected_config & ~BG_MASK) != (actual_config & ~BG_MASK):
        failures.append(
            "post-program CONFIG differs outside factory BG<1:0>: image 0x%04X, "
            "device 0x%04X" % (expected_config, actual_config))
        return compared
    return compared + 2


def evaluate(reservation, post, post_memory, program_exit, failures):
    """Compare one post-write observation against everything reserved."""
    image_data = base64.b64decode(reservation["image_base64"], validate=True)
    if sha256_bytes(image_data) != reservation["image_sha256"]:
        raise FlashError("reservation image digest does not match its own bytes")
    image_memory = parse_ihex(image_data, "reserved release image", strict=True)

    if program_exit is not None and program_exit != 0:
        failures.append("ipecmd program/verify reported exit %d" % program_exit)
    compared = verify_programmed(image_memory, post_memory, failures)

    for field, human in (("osccal_word", "OSCCAL word"),
                         ("osccal_value", "OSCCAL value"),
                         ("bg_bits", "BG<1:0>")):
        for source in ("baseline", "prewrite"):
            expected = reservation["%s_%s" % (source, field)]
            if post[field] != expected:
                failures.append("%s changed: %s read %s, post-program read %s"
                                % (human, source, expected, post[field]))
    if post["device_id"] != reservation["baseline_device_id"] \
            or post["device_revision"] != reservation["baseline_device_revision"]:
        failures.append(
            "post-program device identity differs from baseline: %s/%s vs %s/%s"
            % (post["device_id"], post["device_revision"],
               reservation["baseline_device_id"],
               reservation["baseline_device_revision"]))
    return compared


def publish_result(evidence_dir, reservation, post, compared, failures,
                   program_exit, finalization):
    record = {
        "schema": SCHEMA,
        "record_type": "result",
        "created_utc": utc_now(),
        "status": "FAIL" if failures else "PASS",
        "failures": list(failures),
        "finalization_mode": bool(finalization),
        "part": PART,
        "tool": TOOL,
        "ipe_version": IPE_VERSION,
        "power_mode": POWER_MODE,
        "image_name": reservation["image_name"],
        "image_sha256": reservation["image_sha256"],
        "programmed_image_bytes_verified": compared,
        "reservation_sha256": reservation["_self_sha256"],
        "program_exit": program_exit,
        "baseline_osccal_word": reservation["baseline_osccal_word"],
        "baseline_osccal_value": reservation["baseline_osccal_value"],
        "baseline_config_word": reservation["baseline_config_word"],
        "baseline_bg_bits": reservation["baseline_bg_bits"],
        "prewrite_osccal_word": reservation["prewrite_osccal_word"],
        "prewrite_osccal_value": reservation["prewrite_osccal_value"],
        "prewrite_config_word": reservation["prewrite_config_word"],
        "prewrite_bg_bits": reservation["prewrite_bg_bits"],
        "post_osccal_word": post["osccal_word"],
        "post_osccal_value": post["osccal_value"],
        "post_config_word": post["config_word"],
        "post_bg_bits": post["bg_bits"],
        "post_device_id": post["device_id"],
        "post_device_revision": post["device_revision"],
        "post_read_exit": post["exit"],
        "post_read_log_sha256": post["log_sha256"],
        "post_read_hex_sha256": post.get("hex_sha256"),
        "device_id": reservation["baseline_device_id"],
        "device_revision": reservation["baseline_device_revision"],
    }
    publish_json(os.path.join(evidence_dir, RESULT_NAME), record,
                 "programming result")
    return record


def report(record, evidence_dir):
    print("PIC12F675_FLASH_RESULT status=%s evidence=%s image=%s sha256=%s "
          "failures=%d" % (record["status"], evidence_dir, record["image_name"],
                           record["image_sha256"], len(record["failures"])))
    for failure in record["failures"]:
        print("  FAILURE: %s" % failure)
    if record["status"] == "PASS":
        print("  PASS means no trim damage was OBSERVED on this device. It is "
              "not proof that this writer preserves calibration.")
    else:
        print("  FAIL is a forensic record, not permission to retry the write. "
              "Keep %s and this device together." % evidence_dir)
    return 0 if record["status"] == "PASS" else 1


# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------

def command_program(args, helper_path):
    if args.part != PART:
        raise FlashError("this helper programs %s only; --part %s is refused"
                         % (PART, args.part))
    if args.tool != TOOL:
        raise FlashError(
            "this helper drives a PICkit 3 (%s) only; --tool %s is refused"
            % (TOOL, args.tool))
    if args.power != POWER_MODE:
        raise FlashError(
            "only the externally powered arrangement (--power %s) is validated; "
            "no programmer-powered voltage/interface setup has been retained as "
            "hardware evidence, so --power %s is refused"
            % (POWER_MODE, args.power))

    bundle = bundle_identity(args.image, helper_path)
    image_facts = validate_release_image(bundle["image_data"],
                                         "selected release image")
    programmer = programmer_identity(args.ipecmd, args.java)
    version = probe_version(programmer)

    evidence_dir = create_evidence_dir(args.evidence_dir)
    # From here on the SNAPSHOT is the image: the file the operator named may
    # change or vanish, and every later comparison must be against the exact
    # bytes that were validated above.
    snapshot_path = os.path.join(evidence_dir, IMAGE_SNAPSHOT_NAME)
    publish_bytes(snapshot_path, bundle["image_data"], "retained release image")

    baseline, baseline_memory = device_read(programmer, evidence_dir, "baseline")
    prewrite, prewrite_memory = device_read(programmer, evidence_dir, "prewrite")
    if prewrite_memory != baseline_memory:
        raise FlashError(
            "the device changed between the baseline read and the immediate "
            "pre-write read; no write was attempted. Check the programmer "
            "connection and target power, then start a new transaction.")
    if baseline["device_id"] != prewrite["device_id"] \
            or baseline["device_revision"] != prewrite["device_revision"]:
        raise FlashError(
            "device identity changed between the two pre-write reads; no write "
            "was attempted")

    reservation = {
        "schema": SCHEMA,
        "record_type": "reservation",
        "status": "PENDING",
        "created_utc": utc_now(),
        "part": PART,
        "tool": TOOL,
        "ipe_version": version["version"],
        "ipe_version_probe_sha256": version["probe_sha256"],
        "ipe_version_probe_base64": version["probe_base64"],
        "power_mode": POWER_MODE,
        "image_name": bundle["image_name"],
        "image_path": bundle["image_path"],
        "image_sha256": bundle["image_sha256"],
        "image_base64": base64.b64encode(bundle["image_data"]).decode("ascii"),
        "image_program_words": image_facts["program_words"],
        "image_config_word": image_facts["config_word"],
        "release_checksums_sha256": bundle["checksums_sha256"],
        "release_checksums_signature_sha256": bundle["checksums_signature_sha256"],
        "helper_name": bundle["helper_name"],
        "helper_sha256": bundle["helper_sha256"],
        "helper_checksum_bound": bundle["helper_checksum_bound"],
        "programmer_kind": programmer["kind"],
        "programmer_path": programmer["path"],
        "programmer_realpath": programmer["realpath"],
        "programmer_sha256": programmer["sha256"],
        "programmer_java": programmer["java"],
        "read_argv": read_argv(programmer, "<export>"),
        "write_argv": write_argv(programmer, snapshot_path),
        "baseline_device_id": baseline["device_id"],
        "baseline_device_revision": baseline["device_revision"],
        "baseline_osccal_word": baseline["osccal_word"],
        "baseline_osccal_value": baseline["osccal_value"],
        "baseline_config_word": baseline["config_word"],
        "baseline_bg_bits": baseline["bg_bits"],
        "baseline_hex_sha256": baseline["hex_sha256"],
        "baseline_log_sha256": baseline["log_sha256"],
        "prewrite_osccal_word": prewrite["osccal_word"],
        "prewrite_osccal_value": prewrite["osccal_value"],
        "prewrite_config_word": prewrite["config_word"],
        "prewrite_bg_bits": prewrite["bg_bits"],
        "prewrite_hex_sha256": prewrite["hex_sha256"],
        "prewrite_log_sha256": prewrite["log_sha256"],
    }
    reservation_path = os.path.join(evidence_dir, RESERVATION_NAME)
    publish_json(reservation_path, reservation, "programming reservation")
    reservation["_self_sha256"] = sha256_bytes(
        read_regular_bytes(reservation_path, "programming reservation"))
    print("PIC12F675_FLASH_RESERVED evidence=%s image=%s" %
          (evidence_dir, bundle["image_name"]))

    # The single write. Everything above is reachable without it; nothing below
    # can undo it.
    argv = write_argv(programmer, snapshot_path)
    program_exit, program_output = run_tool(
        argv, DEVICE_TIMEOUT_S, "ipecmd program")
    publish_bytes(os.path.join(evidence_dir, "program.log"), program_output,
                  "program transcript")

    failures = []
    # Read back even when the writer reported failure: a failed write is
    # exactly when the operator most needs to know what is now on the device.
    try:
        post, post_memory = device_read(programmer, evidence_dir, "postread",
                                        require_retlw=False)
    except FlashError as exc:
        post = {
            "exit": None, "log_sha256": None, "osccal_word": None,
            "osccal_value": None, "config_word": None, "bg_bits": None,
            "device_id": None, "device_revision": None,
        }
        failures.append("post-program readback failed: %s" % exc)
        if program_exit != 0:
            failures.append("ipecmd program/verify reported exit %d" % program_exit)
        record = publish_result(evidence_dir, reservation, post, 0, failures,
                                program_exit, False)
        return report(record, evidence_dir)

    compared = evaluate(reservation, post, post_memory, program_exit, failures)
    record = publish_result(evidence_dir, reservation, post, compared, failures,
                            program_exit, False)
    return report(record, evidence_dir)


def command_finalize(args, helper_path):
    evidence_dir = open_evidence_dir(args.evidence_dir)
    reservation_path = os.path.join(evidence_dir, RESERVATION_NAME)
    result_path = os.path.join(evidence_dir, RESULT_NAME)
    if os.path.lexists(result_path):
        raise FlashError(
            "this transaction already has a published result and is immutable: "
            "%s" % result_path)
    if not os.path.lexists(reservation_path):
        raise FlashError(
            "no reservation to finalize: %s holds no %s. An evidence directory "
            "without a reservation records no write."
            % (evidence_dir, RESERVATION_NAME))
    reservation = load_json(reservation_path, "programming reservation")
    reservation["_self_sha256"] = sha256_bytes(
        read_regular_bytes(reservation_path, "programming reservation"))

    for field in ("schema", "record_type", "status", "part", "tool",
                  "ipe_version", "power_mode", "image_name", "image_sha256",
                  "image_base64", "programmer_kind", "programmer_realpath",
                  "programmer_sha256", "baseline_device_id",
                  "baseline_device_revision", "baseline_osccal_word",
                  "baseline_osccal_value", "baseline_config_word",
                  "baseline_bg_bits", "prewrite_osccal_word",
                  "prewrite_osccal_value", "prewrite_config_word",
                  "prewrite_bg_bits"):
        if field not in reservation:
            raise FlashError("reservation is missing required field: %s" % field)
    if reservation["schema"] != SCHEMA \
            or reservation["record_type"] != "reservation" \
            or reservation["status"] != "PENDING":
        raise FlashError("reservation is not a PENDING record of this schema")
    if reservation["part"] != PART or reservation["tool"] != TOOL \
            or reservation["ipe_version"] != IPE_VERSION \
            or reservation["power_mode"] != POWER_MODE:
        raise FlashError("reservation records a different part, tool, version, "
                         "or power arrangement than this helper supports")

    retained = read_regular_bytes(os.path.join(evidence_dir, IMAGE_SNAPSHOT_NAME),
                                  "retained release image")
    if sha256_bytes(retained) != reservation["image_sha256"] \
            or retained != base64.b64decode(reservation["image_base64"], validate=True):
        raise FlashError("the retained release image differs from the reservation")

    programmer = programmer_identity(args.ipecmd, args.java)
    if programmer["realpath"] != reservation["programmer_realpath"] \
            or programmer["sha256"] != reservation["programmer_sha256"] \
            or programmer["kind"] != reservation["programmer_kind"]:
        raise FlashError(
            "the supplied ipecmd is not the one this transaction reserved; "
            "finalize with the same programmer installation")
    probe_version(programmer)

    # Retry-safe: each attempt gets its own private pair of files, so a second
    # finalize after a failed read neither overwrites the first attempt nor
    # collides with it. No write argv is constructed anywhere on this path.
    attempt = 0
    while attempt < MAX_FINALIZE_ATTEMPTS:
        tag = "finalize-%02d" % attempt
        if not os.path.lexists(os.path.join(evidence_dir, tag + ".hex")) \
                and not os.path.lexists(os.path.join(evidence_dir, tag + ".log")):
            break
        attempt += 1
    else:
        raise FlashError("too many finalization attempts in %s" % evidence_dir)

    failures = []
    try:
        post, post_memory = device_read(programmer, evidence_dir, tag,
                                        require_retlw=False)
    except FlashError as exc:
        raise FlashError(
            "%s. The transaction stays PENDING; no result was published and no "
            "write was attempted." % exc) from exc

    compared = evaluate(reservation, post, post_memory, None, failures)
    record = publish_result(evidence_dir, reservation, post, compared, failures,
                            reservation.get("program_exit"), True)
    return report(record, evidence_dir)


def build_parser():
    parser = argparse.ArgumentParser(
        prog="flash-pic12f675.py",
        description=__doc__.splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    subparsers = parser.add_subparsers(dest="command")

    program = subparsers.add_parser(
        "program", help="run the full guarded programming transaction")
    program.add_argument("--image", required=True,
                         help="downloaded bypass-pic12f675-<stage>.hex, beside "
                              "the release SHA256SUMS and SHA256SUMS.asc")
    program.add_argument("--ipecmd", required=True,
                         help="MPLAB X 6.20 ipecmd executable or ipecmd.jar")
    program.add_argument("--evidence-dir", required=True,
                         help="new directory to create for this device's evidence")
    program.add_argument("--java", default="java",
                         help="Java runtime used for an ipecmd.jar (default: java)")
    program.add_argument("--part", default=PART, help=argparse.SUPPRESS)
    program.add_argument("--tool", default=TOOL, help=argparse.SUPPRESS)
    program.add_argument("--power", default=POWER_MODE,
                         help="target power arrangement; only '%s' is validated"
                              % POWER_MODE)

    finalize = subparsers.add_parser(
        "finalize", help="publish the result of an interrupted PENDING "
                         "transaction; never writes")
    finalize.add_argument("--evidence-dir", required=True,
                          help="the PENDING evidence directory")
    finalize.add_argument("--ipecmd", required=True,
                          help="the same MPLAB X 6.20 ipecmd the reservation records")
    finalize.add_argument("--java", default="java",
                          help="Java runtime used for an ipecmd.jar (default: java)")
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command is None:
        parser.print_help(sys.stderr)
        return 2
    helper_path = os.path.abspath(os.path.realpath(__file__))
    try:
        if args.command == "program":
            return command_program(args, helper_path)
        return command_finalize(args, helper_path)
    except FlashError as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
