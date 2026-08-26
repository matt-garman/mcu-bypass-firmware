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

The readback compares the WHOLE device, not just the addresses the image
supplies. A release image occupies about half this part's 1024 words, and a
writer that skipped its bulk erase would satisfy every image-address check while
leaving the other half of the old firmware in place, so each word the image does
not supply is required to read back erased.

PLATFORM. The tool, any Java runtime, the JAR and the release image are pinned
by descriptor and handed to ipecmd as /proc/self/fd/<n>, because a name that is
checked and then re-opened by a child can be pointed at something else in
between. That makes the guarded transaction a Linux procedure; elsewhere it
refuses to touch a device rather than run the check it cannot honour.

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

try:
    import fcntl
except ImportError:  # pragma: no cover - platforms without POSIX fcntl
    fcntl = None


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
# Erased flash reads as all ones in fourteen bits. Every program word the
# release image does NOT supply must equal this after the write; that is the
# only way a writer which skipped its bulk erase is visible at all, because
# every word the image DOES supply still arrives correctly. See
# verify_programmed().
ERASED_WORD = 0x3FFF
# The words compared against the image: 0x000 through 0x3FE. Word 0x3FF is
# per-device OSCCAL and is compared against the two pre-write reads instead.
PROGRAM_WORDS = FLASH_WORDS - 1
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
MAX_TOOL_BYTES = 256 * 1024 * 1024
VERSION_PROBE_TIMEOUT_S = 300
DEVICE_TIMEOUT_S = 900
MAX_FINALIZE_ATTEMPTS = 64
# A no-erase overlay can differ in hundreds of words. The result names the first
# few and counts the rest, so result.json stays a readable forensic record
# rather than a thousand-line list.
MAX_REPORTED_WORDS = 8

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
# holding an object open across the instant it is used
# ---------------------------------------------------------------------------

# Every object this helper validates -- the ipecmd executable, a Java runtime,
# the ipecmd JAR, the release image -- is ultimately consumed by a CHILD
# process, which resolves a pathname of its own. Hashing a name and then handing
# that same name to the child reopens, one instruction later, the exact race the
# hash was meant to close: in between, the name can be pointed at a different
# file. So the child is handed /proc/self/fd/<n> instead. The kernel resolves
# that through the descriptor this process is already holding, to the inode this
# helper validated, whatever the original name refers to by then.
DESCRIPTOR_DIR = "/proc/self/fd"


def descriptor_path(fd):
    """The pathname form of one held descriptor, for a child to open or exec."""
    return "%s/%d" % (DESCRIPTOR_DIR, fd)


def descriptor_paths_available():
    """Does this platform resolve DESCRIPTOR_DIR/<n> to our own descriptors?"""
    try:
        probe = os.open(os.devnull, os.O_RDONLY)
    except OSError:
        return False
    try:
        return os.path.samestat(os.stat(descriptor_path(probe)),
                                os.fstat(probe))
    except OSError:
        return False
    finally:
        os.close(probe)


def require_descriptor_paths():
    """Refuse to drive a programmer on a platform that cannot pin its inputs.

    This is a deliberately narrow platform contract rather than a best effort.
    Without descriptor-addressed pathnames the pinned ipecmd and the retained
    image would have to be re-opened BY NAME at the instant they are used, and a
    process running as this user can replace either one inside that window --
    before the physical erase, where every image guard this helper runs would be
    bypassed and the post-write comparison could only report the damage after it
    happened.
    """
    if descriptor_paths_available():
        return
    raise FlashError(
        "this platform does not resolve %s/<n> to the descriptors this process "
        "holds, so the pinned ipecmd and the retained image would have to be "
        "re-opened by name at the instant they are used. That reopening is the "
        "race this transaction exists to close, so no device command was "
        "issued. The guarded transaction is supported on Linux." % DESCRIPTOR_DIR)


# ---------------------------------------------------------------------------
# Intel HEX
# ---------------------------------------------------------------------------

def parse_ihex(raw, label, strict=True):
    """Parse Intel HEX into {byte address: value}.

    strict=True is for the RELEASE IMAGE: only record types 00/01/04 are
    accepted, an extended linear address must select segment 0, every address
    must be written at most once, and the file must end at its single EOF
    record. A device EXPORT is parsed with strict=False, which tolerates a
    repeated address (some readers emit overlapping runs) only while both
    records agree about its value; an export that contradicts itself is
    refused rather than folded last-one-wins.
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
                if address in memory:
                    if strict:
                        raise FlashError(
                            "%s writes byte address 0x%04X twice (line %d)"
                            % (label, address, lineno))
                    if memory[address] != value:
                        # A reader that cannot agree with itself about what is
                        # on the device cannot establish a trim baseline. Two
                        # different values for one address is that; folding
                        # last-one-wins would hide it.
                        raise FlashError(
                            "%s reports byte address 0x%04X as both 0x%02X and "
                            "0x%02X (line %d); this export contradicts itself"
                            % (label, address, memory[address], value, lineno))
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


def image_words(memory, label, verb="writes"):
    """Fold parsed Intel HEX into whole 14-bit words, refusing half words."""
    words = {}
    for address in sorted(memory):
        if address % 2 != 0:
            if address - 1 not in memory:
                raise FlashError("%s %s the high byte of word 0x%04X "
                                 "without its low byte"
                                 % (label, verb, address // 2))
            continue
        if address + 1 not in memory:
            raise FlashError("%s %s the low byte of word 0x%04X without "
                             "its high byte" % (label, verb, address // 2))
        word = memory[address] | (memory[address + 1] << 8)
        if word & ~0x3FFF:
            raise FlashError("%s word 0x%04X is not a 14-bit value: 0x%04X"
                             % (label, address // 2, word))
        words[address // 2] = word
    return words


def export_coverage(memory, label):
    """Say how much of this part a full-device export actually returned.

    Structural refusal first: a word whose two bytes did not both arrive is a
    truncated read, and every trim comparison downstream would be reading a
    fabricated value.
    """
    words = image_words(memory, label, verb="reports")
    missing = [address for address in range(FLASH_WORDS) if address not in words]
    return {
        "program_words_read": FLASH_WORDS - len(missing),
        "missing_program_words": len(missing),
        "first_missing_word": ("0x%04X" % missing[0]) if missing else None,
        "config_present": CONFIG_WORD_ADDR in words,
    }


def require_complete_export(coverage, label):
    """A pre-write export must cover the whole device, or no write happens.

    The retained baseline is the operator's only copy of what this device held.
    An export that omits program words leaves that copy incomplete for memory
    the very next command erases, and the omission would be invisible: the
    post-write comparison only revisits addresses the image supplies.
    """
    if coverage["missing_program_words"]:
        raise FlashError(
            "%s is not a complete full-device read: it returns %d of %d program "
            "words and omits %d, first at word %s. The retained trim baseline "
            "would be incomplete for memory this transaction is about to erase, "
            "so no write was attempted. That the export command returns complete "
            "program, CONFIG, Device ID, revision, OSCCAL and BG data in the form "
            "this helper parses is the first property the controlled bench run in "
            "HARDWARE_VALIDATION_LOG.md has to establish."
            % (label, coverage["program_words_read"], FLASH_WORDS,
               coverage["missing_program_words"], coverage["first_missing_word"]))
    if not coverage["config_present"]:
        raise FlashError("%s returns no CONFIG word at 0x2007" % label)


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
    its presence is required so the instruction is actionable. The helper's own
    bytes are bound the same way, so the tool and the image it writes are
    covered by one signature.
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

    # The RUNNING helper is held to the same signature as the image it is about
    # to write, wherever it happens to live. Location is not the property that
    # matters -- a copy outside the bundle is fine if it is byte-for-byte the
    # published tool, and a copy inside one is not fine if it is not. Binding on
    # location instead let an edited off-bundle helper program a signed image.
    helper_data = read_regular_bytes(helper_path, "flashing helper")
    helper_sha256 = sha256_bytes(helper_data)
    helper_name = os.path.basename(helper_path)
    recorded = entries.get(helper_name)
    if recorded is None:
        renamed = sorted(name for name, digest in entries.items()
                         if digest == helper_sha256)
        if renamed:
            raise FlashError(
                "this helper is running as %s, but the release publishes these "
                "exact bytes as %s; run it under its released name so the "
                "retained evidence names the artifact the signature covers"
                % (helper_name, ", ".join(renamed)))
        raise FlashError(
            "the running helper is not an artifact of this release: SHA256SUMS "
            "lists no %s. Program a downloaded image with the flash-pic12f675.py "
            "published beside it." % helper_name)
    if helper_sha256 != recorded:
        raise FlashError(
            "flashing helper does not match its signed checksum: %s has %s, "
            "SHA256SUMS records %s" % (helper_name, helper_sha256, recorded))

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
        "helper_checksum_bound": True,
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


def sha256_fd(fd, label, max_bytes):
    """Digest a file through a descriptor already held open."""
    digest = hashlib.sha256()
    total = 0
    try:
        os.lseek(fd, 0, os.SEEK_SET)
        while True:
            chunk = os.read(fd, 1 << 20)
            if not chunk:
                break
            total += len(chunk)
            if total > max_bytes:
                raise FlashError("%s exceeds the %d-byte limit" % (label, max_bytes))
            digest.update(chunk)
    except OSError as exc:
        raise FlashError("%s could not be read: %s" % (label, exc)) from exc
    if total == 0:
        raise FlashError("%s is empty" % label)
    return digest.hexdigest()


def open_identity(path, label, max_bytes):
    """Pin a file that will later be run or read by a child, and keep its handle.

    Hashing a path and then handing that same path to a child leaves a window:
    between the two, the name can be pointed at a different file, or the file
    can be rewritten underneath it. The descriptor closes both halves. The
    recorded digest is read THROUGH it; the child is handed descriptor_path() of
    this same descriptor rather than the name, so what it runs or reads is this
    inode and not whatever the name has become; and before every invocation the
    pathname is re-stat'd and these bytes are re-hashed through the descriptor,
    so a tool swapped in behind the name, or edited in place, is diagnosed and
    refused rather than silently ignored.
    """
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        raise FlashError("%s is unavailable: %s" % (label, exc)) from exc
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise FlashError("%s is not a regular file: %s" % (label, path))
        digest = sha256_fd(fd, label, max_bytes)
    except BaseException:
        os.close(fd)
        raise
    return {
        "fd": fd,
        "path": path,
        "label": label,
        "sha256": digest,
        "ident": (info.st_dev, info.st_ino),
        "max_bytes": max_bytes,
    }


def programmer_identity(path, java):
    """Resolve the one supported ipecmd form and pin the exact bytes used.

    Both supported forms are pinned the same way: the direct executable, and the
    `java -jar ipecmd.jar` form, whose Java runtime is as much a part of what
    runs as the jar is.
    """
    invoked = os.path.abspath(path)
    resolved = os.path.realpath(invoked)
    handle = open_identity(resolved, "ipecmd", MAX_TOOL_BYTES)
    java_handle = None
    try:
        if resolved.endswith(".jar"):
            kind = "jar"
            java_path = which(java)
            if java_path is None:
                raise FlashError(
                    "a .jar ipecmd needs a Java runtime; '%s' is not an "
                    "executable on PATH" % java)
            java_path = os.path.realpath(java_path)
            java_handle = open_identity(java_path, "java runtime", MAX_TOOL_BYTES)
            if not os.access(java_path, os.X_OK):
                raise FlashError("java runtime is not executable: %s" % java_path)
            # argv[0] stays the real name so the child, its own logs and the
            # retained transcript all say what ran; only the two things a child
            # would otherwise RESOLVE -- the runtime it execs and the jar it
            # opens -- are addressed by descriptor.
            prefix = [java_path, "-jar", descriptor_path(handle["fd"])]
            exec_path = descriptor_path(java_handle["fd"])
        else:
            kind = "executable"
            if not os.access(resolved, os.X_OK):
                raise FlashError("ipecmd is not executable: %s" % path)
            java_path = None
            prefix = [resolved]
            exec_path = descriptor_path(handle["fd"])
    except BaseException:
        os.close(handle["fd"])
        if java_handle is not None:
            os.close(java_handle["fd"])
        raise
    handles = [h for h in (handle, java_handle) if h is not None]
    return {
        "kind": kind,
        "path": invoked,
        "realpath": resolved,
        "sha256": handle["sha256"],
        "java": java_path,
        "java_sha256": None if java_handle is None else java_handle["sha256"],
        "prefix": prefix,
        "exec_path": exec_path,
        "pass_fds": tuple(h["fd"] for h in handles),
        "handles": handles,
    }


def programmer_unchanged(programmer):
    """Re-prove the pinned identity immediately before an invocation.

    The bytes about to run are the ones behind these descriptors whatever this
    finds, because that is what the child is handed. What this adds is the
    DIAGNOSIS: a tool whose name now points somewhere else, or whose inode was
    edited underneath it, means the operator's installation moved mid-
    transaction, and continuing to drive a device from it is not something to do
    quietly.
    """
    for handle in programmer["handles"]:
        try:
            info = os.stat(handle["path"])
        except OSError as exc:
            raise FlashError(
                "the %s at %s became unavailable between its identity check and "
                "its use; no command was issued: %s"
                % (handle["label"], handle["path"], exc)) from exc
        if (info.st_dev, info.st_ino) != handle["ident"]:
            raise FlashError(
                "the %s at %s was replaced between its identity check and its "
                "use; no command was issued" % (handle["label"], handle["path"]))
        if sha256_fd(handle["fd"], handle["label"], handle["max_bytes"]) \
                != handle["sha256"]:
            raise FlashError(
                "the %s at %s changed on disk between its identity check and "
                "its use; no command was issued"
                % (handle["label"], handle["path"]))


def run_tool(argv, timeout, label, executable=None, pass_fds=()):
    """Start one child on the PINNED objects.

    `executable` is descriptor_path() of the held tool, so the kernel execs the
    inode this helper hashed rather than re-walking the name in argv[0].
    `pass_fds` keeps exactly those descriptors open across the exec -- without
    it subprocess closes them before exec and every /proc/self/fd/<n> in the
    argv, including the one being exec'd, would resolve to nothing.
    """
    try:
        completed = subprocess.run(
            argv, executable=executable, pass_fds=pass_fds,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, timeout=timeout, shell=False, check=False)
    except subprocess.TimeoutExpired as exc:
        raise FlashError("%s did not finish within %ds" % (label, timeout)) from exc
    except OSError as exc:
        raise FlashError("%s could not be started: %s" % (label, exc)) from exc
    return completed.returncode, completed.stdout


def invoke(programmer, argv, timeout, label, pass_fds=()):
    """The only way a tool is started: identity re-proved, then run.

    `pass_fds` carries whatever else this particular command has to READ by
    descriptor -- for the single write, the pinned release image.
    """
    programmer_unchanged(programmer)
    return run_tool(argv, timeout, label, executable=programmer["exec_path"],
                    pass_fds=tuple(programmer["pass_fds"]) + tuple(pass_fds))


def probe_version(programmer):
    """Pin the writer to MPLAB X 6.20 before any device access.

    MPLAB X 6.25 dropped PICkit 3 support, and the argument spellings this tool
    constructs are validated against 6.20 only. The probe is help output: it
    names no part, no tool and no file, so it cannot reach the device.
    """
    argv = programmer["prefix"] + ["-?"]
    exit_code, output = invoke(programmer, argv, VERSION_PROBE_TIMEOUT_S,
                               "ipecmd version probe")
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
    deliberately absent: the supported arrangement is an externally powered
    board, and no programmer-powered voltage/interface setup has been retained
    as hardware evidence. Nothing here is caller-supplied: `image_path` is
    descriptor_path() of the pinned image, which is the one argument of this
    command that a replaced file could otherwise turn into a different write.
    """
    return programmer["prefix"] + [
        TOOL_FLAG + TOOL, "-P" + PART, "-F" + image_path, "-M", "-Y", "-OL",
    ]


# ---------------------------------------------------------------------------
# evidence
# ---------------------------------------------------------------------------

# `dir_fd` removes the pathname from every evidence operation after the
# directory is opened. Windows supports neither it nor O_DIRECTORY, so the
# pathname discipline below is the fallback there and the reservation records
# which of the two was in force.
EVIDENCE_DIR_FD = (hasattr(os, "O_DIRECTORY")
                   and os.open in os.supports_dir_fd
                   and os.stat in os.supports_dir_fd
                   and os.chmod in os.supports_dir_fd)


def durable_fsync(fd, what):
    """Flush one held descriptor to stable storage, or refuse to go on.

    Directories need this as much as files do: fsync on a file does not make the
    DIRECTORY ENTRY that names it durable, and an entry a crash can still lose
    is not a reservation.
    """
    try:
        os.fsync(fd)
    except OSError as exc:
        raise FlashError("could not flush %s to stable storage: %s"
                         % (what, exc)) from exc


def durable_write(fd, data, what):
    """Write every byte, or refuse.

    os.write may write fewer bytes than it was given. A short write that nobody
    noticed would leave a truncated evidence file, and a truncated result is
    exactly the state this transaction must never publish.
    """
    written = 0
    try:
        while written < len(data):
            written += os.write(fd, data[written:])
    except OSError as exc:
        raise FlashError("could not write %s: %s" % (what, exc)) from exc


def durable_link(source, target, what, dir_fd=None):
    """Install a fully written file under its final name, atomically.

    link() is the whole reason the temporary file exists: it either creates the
    final name in one indivisible step or fails because that name is taken. So
    an evidence file is never observable half-written, and a valid result.json
    can never be replaced -- not by a second helper run, and not by this one.
    """
    try:
        if dir_fd is None:
            os.link(source, target)
        else:
            os.link(source, target, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
    except FileExistsError as exc:
        raise FlashError("%s already exists and is immutable" % what) from exc
    except OSError as exc:
        raise FlashError("could not publish %s: %s" % (what, exc)) from exc


def sealed_copy(data, name, label):
    """An immutable copy of already-validated bytes, addressable by descriptor.

    Holding the retained image.hex open pins it against REPLACEMENT, but not
    against being rewritten in place: mode 0400 does not stop the owner of a
    file from restoring write permission and editing the very inode the
    descriptor names. A sealed anonymous file has no name to replace and no
    writable path at all, so the bytes the writer consumes are provably the
    bytes that passed validate_release_image().

    Returns None where the platform cannot seal one; the caller then falls back
    to the retained evidence file and records which pinning was in force.
    """
    if fcntl is None or not hasattr(os, "memfd_create"):
        return None
    try:
        fd = os.memfd_create(name, os.MFD_ALLOW_SEALING | os.MFD_CLOEXEC)
    except (AttributeError, OSError):  # pragma: no cover - old kernels
        return None
    try:
        durable_write(fd, data, label)
        fcntl.fcntl(fd, fcntl.F_ADD_SEALS,
                    fcntl.F_SEAL_WRITE | fcntl.F_SEAL_SHRINK
                    | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SEAL)
    except (AttributeError, FlashError, OSError,
            ValueError):  # pragma: no cover - old kernels
        os.close(fd)
        return None
    if sha256_fd(fd, label, MAX_FILE_BYTES) != sha256_bytes(data):
        os.close(fd)
        raise FlashError("%s was not sealed as it was written" % label)
    return fd


class Evidence(object):
    """The retained evidence directory, addressed by descriptor where possible.

    A transaction that checks a directory and then writes to it BY NAME can have
    the directory replaced in between, and every later read would observe the
    replacement rather than what ipecmd produced. So the directory is opened
    once, its identity is confirmed against the name it was opened from, and
    every file inside it is thereafter created, read, and chmod'ed relative to
    that descriptor.
    """

    def __init__(self, path, fd, parent_fd=None):
        self.path = path
        self.fd = fd
        # Retained, not merely used and dropped: the entry that names this
        # directory lives in the parent, and only the parent's descriptor can
        # make that entry durable or remove it again if it cannot be.
        self.parent_fd = parent_fd

    @staticmethod
    def _open_directory(path, what):
        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) \
            | getattr(os, "O_NOFOLLOW", 0)
        try:
            return os.open(path, flags)
        except OSError as exc:
            raise FlashError("could not open %s: %s" % (what, exc)) from exc

    @staticmethod
    def _attach(path):
        if not EVIDENCE_DIR_FD:
            return None
        flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0)
        try:
            fd = os.open(path, flags)
        except OSError as exc:
            raise FlashError("could not open the evidence directory: %s"
                             % exc) from exc
        try:
            named = os.lstat(path)
            opened = os.fstat(fd)
        except OSError as exc:
            os.close(fd)
            raise FlashError("could not confirm the evidence directory: %s"
                             % exc) from exc
        if (named.st_dev, named.st_ino) != (opened.st_dev, opened.st_ino):
            os.close(fd)
            raise FlashError("the evidence directory at %s was replaced while "
                             "it was being opened" % path)
        return fd

    @classmethod
    def create(cls, path):
        """Create the evidence directory exclusively, or refuse.

        Exclusive creation is the whole point: an existing directory could
        already hold another device's transaction, and silently adding to it
        would destroy the one-directory-one-device binding every later check
        rests on.
        """
        # normpath first: `--evidence-dir ./device-001/` is an ordinary way to
        # type a directory, and a trailing separator must not read as "no final
        # component".
        path = os.path.abspath(os.path.normpath(path))
        parent = os.path.dirname(path)
        if os.path.basename(path) in ("", ".", ".."):
            raise FlashError("evidence path does not name a new directory: %s"
                             % path)
        try:
            parent_info = os.stat(parent)
        except OSError as exc:
            raise FlashError("evidence directory's parent is unavailable: %s"
                             % exc) from exc
        if not stat.S_ISDIR(parent_info.st_mode):
            raise FlashError("evidence directory's parent is not a directory: %s"
                             % parent)
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
        parent_fd = cls._open_directory(parent, "the evidence directory's parent")
        try:
            os.mkdir(path, 0o700)
        except OSError as exc:
            os.close(parent_fd)
            raise FlashError("could not create the evidence directory: %s"
                             % exc) from exc
        try:
            # The new directory ENTRY lives in the parent, and fsync on the new
            # directory itself does not flush it. Without this, a crash after
            # the reservation is announced and the write has begun can lose the
            # directory that was supposed to make that reservation durable --
            # leaving a programmed device with no record that anything reserved
            # it. It happens here, before any device is touched, so an inability
            # to make the entry durable costs nothing but the transaction.
            durable_fsync(parent_fd, "the evidence directory's parent")
        except BaseException:
            try:
                os.rmdir(path)
            except OSError:  # pragma: no cover - best effort cleanup
                pass
            os.close(parent_fd)
            raise
        try:
            return cls(path, cls._attach(path), parent_fd)
        except BaseException:
            os.close(parent_fd)
            raise

    @classmethod
    def open(cls, path):
        path = os.path.abspath(os.path.normpath(path))
        try:
            info = os.lstat(path)
        except OSError as exc:
            raise FlashError("evidence directory is unavailable: %s" % exc) from exc
        if stat.S_ISLNK(info.st_mode):
            raise FlashError("evidence directory is a symbolic link: %s" % path)
        if not stat.S_ISDIR(info.st_mode):
            raise FlashError("evidence directory is not a directory: %s" % path)
        return cls(path, cls._attach(path))

    def filename(self, name):
        """The pathname form, for an argv ipecmd must be given and for
        diagnostics. Never used to reach a file this helper reads itself."""
        return os.path.join(self.path, name)

    def _open(self, name, flags, mode=0o777):
        if self.fd is None:
            return os.open(self.filename(name), flags, mode)
        return os.open(name, flags, mode, dir_fd=self.fd)

    def _discard(self, name):
        """Remove a publication remnant. Best effort by design: a leftover
        temporary file is inert -- no reader looks for one -- and failing the
        transaction over it would turn a tidy-up into an outage."""
        try:
            if self.fd is None:
                os.unlink(self.filename(name))
            else:
                os.unlink(name, dir_fd=self.fd)
        except OSError:  # pragma: no cover - best effort cleanup
            pass

    def exists(self, name):
        try:
            if self.fd is None:
                os.lstat(self.filename(name))
            else:
                os.lstat(name, dir_fd=self.fd)
        except OSError:
            return False
        return True

    def sync(self, what):
        if self.fd is not None:
            durable_fsync(self.fd, what)
            return
        fd = self._open_directory(self.path, "the evidence directory")
        try:
            durable_fsync(fd, what)
        finally:
            os.close(fd)

    def publish(self, name, data, label, retain=False):
        """Install one evidence file under its final name, atomically.

        The bytes go to a private temporary file in this same directory, are
        written in full, are flushed to stable storage, and only THEN acquire
        the final name in one atomic no-replace link. Creating the final name
        first and writing into it afterwards -- which is what O_EXCL alone does
        -- leaves a window in which a crash, a signal, a short write or an I/O
        error publishes an empty or truncated result.json: a name that is
        neither a valid immutable result nor a PENDING transaction anything can
        recover. Here an interrupted publication leaves a temporary file that no
        reader ever looks for, and the transaction stays exactly PENDING.

        `retain` returns a read-only descriptor on the installed file, verified
        against the bytes just written, for content a child must later read
        without re-resolving its name.
        """
        temporary = "%s.%s.tmp" % (name, os.urandom(8).hex())
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        try:
            fd = self._open(temporary, flags, 0o400)
        except OSError as exc:
            raise FlashError("could not create %s: %s" % (label, exc)) from exc
        try:
            durable_write(fd, data, label)
            durable_fsync(fd, label)
        except BaseException:
            os.close(fd)
            self._discard(temporary)
            raise
        os.close(fd)
        try:
            durable_link(temporary, name, label,
                         None if self.fd is None else self.fd)
        except BaseException:
            self._discard(temporary)
            raise
        self._discard(temporary)
        self.sync("the evidence directory after %s" % label)
        if not retain:
            return None
        return self.hold(name, label, data)

    def hold(self, name, label, data):
        """Keep an installed evidence file open, and prove it is what we wrote."""
        fd = self._open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            if sha256_fd(fd, label, MAX_FILE_BYTES) != sha256_bytes(data):
                raise FlashError("%s does not hold the bytes just published: %s"
                                 % (label, self.filename(name)))
        except BaseException:
            os.close(fd)
            raise
        return fd

    def publish_json(self, name, record, label):
        data = (json.dumps(record, indent=2, sort_keys=True) + "\n").encode("ascii")
        self.publish(name, data, label)

    def read(self, name, label, max_bytes=MAX_FILE_BYTES):
        """Read a retained file that must be a plain, bounded, non-empty
        regular file, through the directory descriptor."""
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        try:
            if self.fd is None:
                fd = os.open(self.filename(name), flags)
            else:
                fd = os.open(name, flags, dir_fd=self.fd)
        except OSError as exc:
            raise FlashError("%s is unavailable: %s" % (label, exc)) from exc
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode):
                raise FlashError("%s is not a regular file: %s"
                                 % (label, self.filename(name)))
            if info.st_size == 0:
                raise FlashError("%s is empty: %s" % (label, self.filename(name)))
            if info.st_size > max_bytes:
                raise FlashError("%s exceeds the %d-byte limit: %s"
                                 % (label, max_bytes, self.filename(name)))
            data = b""
            while True:
                chunk = os.read(fd, 1 << 20)
                if not chunk:
                    break
                data += chunk
        except OSError as exc:
            raise FlashError("%s could not be read: %s" % (label, exc)) from exc
        finally:
            os.close(fd)
        if len(data) != info.st_size:
            raise FlashError("%s changed size while being read: %s"
                             % (label, self.filename(name)))
        return data

    def read_json(self, name, label):
        data = self.read(name, label, max_bytes=8 * MAX_FILE_BYTES)
        try:
            record = json.loads(data.decode("ascii"))
        except (UnicodeDecodeError, ValueError) as exc:
            raise FlashError("%s is not valid JSON: %s" % (label, exc)) from exc
        if not isinstance(record, dict):
            raise FlashError("%s is not a JSON object" % label)
        return record

    def protect(self, name):
        try:
            if self.fd is None:
                os.chmod(self.filename(name), 0o400)
            else:
                os.chmod(name, 0o400, dir_fd=self.fd)
        except OSError as exc:
            raise FlashError("could not protect %s: %s"
                             % (self.filename(name), exc)) from exc
def device_read(programmer, evidence, tag, require_retlw=True):
    """One full-device read: transcript, export, and everything parsed from it."""
    log_name = tag + ".log"
    hex_name = tag + ".hex"
    if evidence.exists(hex_name):
        raise FlashError("a %s export already exists: %s"
                         % (tag, evidence.filename(hex_name)))
    argv = read_argv(programmer, evidence.filename(hex_name))
    exit_code, output = invoke(programmer, argv, DEVICE_TIMEOUT_S,
                               "ipecmd device read (%s)" % tag)
    evidence.publish(log_name, output, "%s transcript" % tag)
    record = {
        "argv": argv,
        "exit": exit_code,
        "log_sha256": sha256_bytes(output),
        "log_base64": base64.b64encode(output).decode("ascii"),
    }
    if exit_code != 0:
        raise FlashError("ipecmd %s read failed with exit %d; see %s"
                         % (tag, exit_code, evidence.filename(log_name)))
    label = "%s device export" % tag
    export = evidence.read(hex_name, label)
    evidence.protect(hex_name)
    memory = parse_ihex(export, label, strict=False)
    device_id, revision = parse_device_report(output, "%s transcript" % tag)
    record.update({
        "hex_sha256": sha256_bytes(export),
        "hex_base64": base64.b64encode(export).decode("ascii"),
        "device_id": device_id,
        "device_revision": revision,
    })
    # Trim first, so a device missing its calibration word is diagnosed as that
    # rather than as a short export.
    record.update(read_trim(memory, label, require_retlw))
    coverage = export_coverage(memory, label)
    record.update({
        "program_words_read": coverage["program_words_read"],
        "missing_program_words": coverage["missing_program_words"],
    })
    if require_retlw:
        # Only the two PRE-WRITE reads refuse here. After the write, an
        # incomplete export is the headline RESULT and has to reach result.json
        # as a named failure rather than abort the readback that found it.
        require_complete_export(coverage, label)
    return record, memory


def verify_programmed(image, actual, failures):
    """Compare the WHOLE device against one complete expected post-write model.

    Comparing only the addresses the image supplies proves that the requested
    words arrived and proves nothing whatever about the rest of the part. The
    current release images occupy about half of this device's 1024 words, so a
    writer that skips its bulk erase can write every requested word correctly,
    preserve the trim, satisfy every check that looks at image addresses -- and
    leave hundreds of stale instructions behind in the image's holes, still
    reachable by a computed jump or a runaway program counter. Every program
    word therefore has an expected value here: the image's where the image
    supplies one, the erased 0x3FFF everywhere else.

    Word 0x3FF is excluded deliberately -- it is per-device OSCCAL, compared
    against the two pre-write reads by evaluate() -- and CONFIG is compared
    outside BG<1:0>, the factory bandgap field, which is not the image's to
    assert either.

    The count returned is what makes PASS mean something: it is the number of
    words actually observed equal, so a comparison that stopped early cannot
    report a positive count and an empty failure list at the same time.
    """
    verified = 0
    differing = 0
    reported = 0
    for address in range(PROGRAM_WORDS):
        expected = image.get(address, ERASED_WORD)
        found = actual.get(address)
        if found == expected:
            verified += 1
            continue
        differing += 1
        if reported >= MAX_REPORTED_WORDS:
            continue
        reported += 1
        if found is None:
            failures.append("post-program export omits program word 0x%04X"
                            % address)
        elif address in image:
            failures.append(
                "post-program word 0x%04X is 0x%04X; the release image programs "
                "0x%04X there" % (address, found, expected))
        else:
            failures.append(
                "post-program word 0x%04X is 0x%04X; the release image does not "
                "program that address, so it had to be erased to 0x%04X. The "
                "writer left this word behind."
                % (address, found, expected))
    if differing > reported:
        failures.append("%d further program words differ from the device this "
                        "write was supposed to leave behind"
                        % (differing - reported))
    if verified != PROGRAM_WORDS:
        failures.append(
            "post-program verification observed %d of the %d program words this "
            "part holds below the calibration word"
            % (verified, PROGRAM_WORDS))

    config_verified = False
    found_config = actual.get(CONFIG_WORD_ADDR)
    expected_config = image.get(CONFIG_WORD_ADDR)
    if expected_config is None:
        failures.append("the reserved release image carries no CONFIG word")
    elif found_config is None:
        failures.append("post-program read omits the CONFIG word")
    elif (expected_config & ~BG_MASK) != (found_config & ~BG_MASK):
        failures.append(
            "post-program CONFIG differs outside factory BG<1:0>: image 0x%04X, "
            "device 0x%04X" % (expected_config, found_config))
    else:
        config_verified = True
    return {"program_words": verified, "config_word": config_verified}


def evaluate(reservation, post, post_memory, program_exit, failures):
    """Compare one post-write observation against everything reserved."""
    image_data = base64.b64decode(reservation["image_base64"], validate=True)
    if sha256_bytes(image_data) != reservation["image_sha256"]:
        raise FlashError("reservation image digest does not match its own bytes")
    image_memory = parse_ihex(image_data, "reserved release image", strict=True)
    image = image_words(image_memory, "reserved release image")
    actual = image_words(post_memory, "post-program device export",
                         verb="reports")

    if program_exit is not None and program_exit != 0:
        failures.append("ipecmd program/verify reported exit %d" % program_exit)
    if post.get("missing_program_words"):
        failures.append(
            "post-program export is incomplete: %d of %d program words returned"
            % (post["program_words_read"], FLASH_WORDS))
    compared = verify_programmed(image, actual, failures)

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


def publish_result(evidence, reservation, post, compared, failures,
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
        # The exact, whole-device count. A PASS is only reachable when every one
        # of the PROGRAM_WORDS words below the calibration word was observed
        # equal to the expected post-write device and the CONFIG word matched
        # outside BG<1:0>; a comparison that covered less than that publishes
        # both a smaller number here and the failure that explains it.
        "verified_program_words": compared["program_words"],
        "required_program_words": PROGRAM_WORDS,
        "verified_config_word": compared["config_word"],
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
        "post_program_words_read": post.get("program_words_read"),
        "device_id": reservation["baseline_device_id"],
        "device_revision": reservation["baseline_device_revision"],
    }
    evidence.publish_json(RESULT_NAME, record, "programming result")
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
        # "supported", not "validated".  The externally powered arrangement is
        # the only one this tool constructs commands for, and it is the only one
        # the software tests cover -- but HARDWARE_VALIDATION_LOG.md lists that
        # same arrangement, and release-from-reset behaviour with it, among the
        # controlled bench checks that are still outstanding.  Telling an
        # operator their setup is "validated" at the moment they are about to
        # write a device is precisely where that overstatement costs something.
        raise FlashError(
            "the externally powered arrangement (--power %s) is the only "
            "supported one; programmer-supplied Vdd is refused, and no "
            "programmer-powered voltage/interface setup has been retained as "
            "hardware evidence, so --power %s is refused"
            % (POWER_MODE, args.power))

    require_descriptor_paths()

    bundle = bundle_identity(args.image, helper_path)
    image_facts = validate_release_image(bundle["image_data"],
                                         "selected release image")
    programmer = programmer_identity(args.ipecmd, args.java)
    version = probe_version(programmer)

    evidence = Evidence.create(args.evidence_dir)
    # From here on the SNAPSHOT is the image: the file the operator named may
    # change or vanish, and every later comparison must be against the exact
    # bytes that were validated above. image.hex is the retained EVIDENCE of
    # those bytes; the descriptor below is what the writer is actually given, so
    # that no name -- not the operator's, not this directory's, not image.hex's
    # -- is resolved again between validation and the erase.
    retained_fd = evidence.publish(IMAGE_SNAPSHOT_NAME, bundle["image_data"],
                                   "retained release image", retain=True)
    sealed_fd = sealed_copy(bundle["image_data"], IMAGE_SNAPSHOT_NAME,
                            "retained release image")
    if sealed_fd is None:
        image_fd = retained_fd
        image_pinning = "retained-descriptor"
    else:
        image_fd = sealed_fd
        image_pinning = "sealed"
    snapshot_path = descriptor_path(image_fd)

    baseline, baseline_memory = device_read(programmer, evidence, "baseline")
    prewrite, prewrite_memory = device_read(programmer, evidence, "prewrite")
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
        "evidence_dir_fd_bound": evidence.fd is not None,
        "image_name": bundle["image_name"],
        "image_path": bundle["image_path"],
        "image_snapshot_path": evidence.filename(IMAGE_SNAPSHOT_NAME),
        # Which of the two pinnings the platform allowed. "sealed" is an
        # anonymous file that cannot be rewritten by anyone, including this
        # helper; "retained-descriptor" is the retained image.hex held open,
        # which cannot be REPLACED but whose inode its owner could still edit.
        "image_pinning": image_pinning,
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
        "programmer_java_sha256": programmer["java_sha256"],
        # Both argvs are recorded exactly as issued, descriptor pathnames and
        # all. A /proc/self/fd number is meaningless once this process is gone,
        # which is precisely why the digests beside it are what identify what
        # ran and what was written.
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
        "baseline_program_words_read": baseline["program_words_read"],
        "prewrite_osccal_word": prewrite["osccal_word"],
        "prewrite_osccal_value": prewrite["osccal_value"],
        "prewrite_config_word": prewrite["config_word"],
        "prewrite_bg_bits": prewrite["bg_bits"],
        "prewrite_hex_sha256": prewrite["hex_sha256"],
        "prewrite_log_sha256": prewrite["log_sha256"],
        "prewrite_program_words_read": prewrite["program_words_read"],
    }
    evidence.publish_json(RESERVATION_NAME, reservation,
                          "programming reservation")
    reservation["_self_sha256"] = sha256_bytes(
        evidence.read(RESERVATION_NAME, "programming reservation"))
    print("PIC12F675_FLASH_RESERVED evidence=%s image=%s" %
          (evidence.path, bundle["image_name"]))

    # The single write. Everything above is reachable without it; nothing below
    # can undo it.
    if sha256_fd(image_fd, "retained release image", MAX_FILE_BYTES) \
            != bundle["image_sha256"]:
        raise FlashError(
            "the pinned release image no longer holds the bytes this "
            "transaction reserved; no write was attempted")
    argv = write_argv(programmer, snapshot_path)
    program_exit, program_output = invoke(
        programmer, argv, DEVICE_TIMEOUT_S, "ipecmd program",
        pass_fds=(image_fd,))
    evidence.publish("program.log", program_output, "program transcript")

    failures = []
    # Read back even when the writer reported failure: a failed write is
    # exactly when the operator most needs to know what is now on the device.
    try:
        post, post_memory = device_read(programmer, evidence, "postread",
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
        record = publish_result(evidence, reservation, post,
                                {"program_words": 0, "config_word": False},
                                failures, program_exit, False)
        return report(record, evidence.path)

    compared = evaluate(reservation, post, post_memory, program_exit, failures)
    record = publish_result(evidence, reservation, post, compared, failures,
                            program_exit, False)
    return report(record, evidence.path)


def command_finalize(args, helper_path):
    # Finalization issues no write, but it does drive a tool whose output
    # becomes the published result. A programmer swapped in behind its name
    # could fabricate a passing export, so the same descriptor pinning governs
    # the read-only path.
    require_descriptor_paths()

    evidence = Evidence.open(args.evidence_dir)
    if evidence.exists(RESULT_NAME):
        raise FlashError(
            "this transaction already has a published result and is immutable: "
            "%s" % evidence.filename(RESULT_NAME))
    if not evidence.exists(RESERVATION_NAME):
        raise FlashError(
            "no reservation to finalize: %s holds no %s. An evidence directory "
            "without a reservation records no write."
            % (evidence.path, RESERVATION_NAME))
    reservation = evidence.read_json(RESERVATION_NAME, "programming reservation")
    reservation["_self_sha256"] = sha256_bytes(
        evidence.read(RESERVATION_NAME, "programming reservation"))

    for field in ("schema", "record_type", "status", "part", "tool",
                  "ipe_version", "power_mode", "image_name", "image_sha256",
                  "image_base64", "programmer_kind", "programmer_realpath",
                  "programmer_sha256", "programmer_java",
                  "programmer_java_sha256", "baseline_device_id",
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

    retained = evidence.read(IMAGE_SNAPSHOT_NAME, "retained release image")
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
    # For the jar form the Java runtime is half of what actually ran, so it is
    # reserved and re-proved exactly like the jar.
    if programmer["java"] != reservation["programmer_java"] \
            or programmer["java_sha256"] != reservation["programmer_java_sha256"]:
        raise FlashError(
            "the supplied Java runtime is not the one this transaction "
            "reserved; finalize with the same programmer installation")
    probe_version(programmer)

    # Retry-safe: each attempt gets its own private pair of files, so a second
    # finalize after a failed read neither overwrites the first attempt nor
    # collides with it. No write argv is constructed anywhere on this path.
    attempt = 0
    while attempt < MAX_FINALIZE_ATTEMPTS:
        tag = "finalize-%02d" % attempt
        if not evidence.exists(tag + ".hex") and not evidence.exists(tag + ".log"):
            break
        attempt += 1
    else:
        raise FlashError("too many finalization attempts in %s" % evidence.path)

    failures = []
    try:
        post, post_memory = device_read(programmer, evidence, tag,
                                        require_retlw=False)
    except FlashError as exc:
        raise FlashError(
            "%s. The transaction stays PENDING; no result was published and no "
            "write was attempted." % exc) from exc

    compared = evaluate(reservation, post, post_memory, None, failures)
    record = publish_result(evidence, reservation, post, compared, failures,
                            reservation.get("program_exit"), True)
    return report(record, evidence.path)


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
                         help="target power arrangement; only '%s' is "
                              "supported, and it still awaits controlled "
                              "hardware validation" % POWER_MODE)

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
