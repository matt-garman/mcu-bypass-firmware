#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
"""Derive a simulator-runnable PIC image by injecting the calibration word.

WHY THIS EXISTS. On the PIC12F675 the oscillator trim value lives in FLASH, at
the last program word, and it is programmed at the factory -- the device pack
declares word 0x3FF as the ".oscval" CalDataZone. XC8's startup code emits a
`CALL <calibration word>` and expects a `RETLW k` to be waiting there. A freshly
built .hex does not contain that word, because on real silicon the programmer
preserves it rather than writing it.

In a simulator there is no factory trim, so the word is simply absent: the
program counter runs off the end of flash, the part watchdog-resets, and it does
so in a LOOP -- main() is never reached and every assertion in the lane fails for
a reason that has nothing to do with the firmware. Every gpsim and libgpsim lane
for this part therefore needs the calibration word injected first.

WHAT THIS PRODUCES IS A TEST ARTIFACT, NEVER A SHIPPING IMAGE. It writes a
derived copy and refuses to touch the input. The SHA-256 baseline and the
release provenance chain continue to cover the shipping HEX alone; the injected
image exists only inside the build directory. That separation is the whole point
of deriving rather than patching in place: getting it wrong means either
shipping an image carrying a fake calibration value, or baselining an image that
cannot run in any lane.

A SECOND JOB, THE INVERSE. `--assert-preserves-calibration` injects nothing: it
requires that an image LEAVES the calibration word alone. That is the question a
device programmer has to answer, and `pic12f675-program` asks it before writing
any HEX to real silicon -- because getting a DERIVED image onto a device
overwrites the factory oscillator trim with the fabricated constant above,
irreversibly, and silently, since the part still appears to work afterwards. The
two modes share one definition of where the word is and of what "programmed"
means, so the producer and the guard against it cannot drift apart.

WHICH VALUE. Any legal value simulates equally well, so a fixed documented
constant is chosen to keep the lanes deterministic. The default is 0x80: on this
family OSCCAL implements bits 7:2 (CAL5:CAL0) and reads the low two bits as
zero, so 0x80 is the mid-scale trim. Note what this means -- the simulator runs
with a calibration the real device will not have. That is harmless here because
gpsim's clock is nominal anyway, but a lane that ever asserts on absolute
oscillator-derived timing is asserting against a fiction, and should say so.

HOW THE INJECTION ADDRESS IS ESTABLISHED. The caller passes the device's flash
size in words and the calibration word is its last word -- so the address cannot
drift away from the part the image was built for. That alone would still accept
a wrong --flash-words, so the image is also required to contain a
`CALL <calibration word>` instruction: proof that the address being injected is
the address this firmware actually fetches from. A budget that is too small is
caught by the overlap check (the word is already programmed); one that is too
large is caught by the missing CALL.
"""

import argparse
from contextlib import redirect_stdout
import io
import os
from pathlib import Path
import stat
import sys
import tempfile


MAX_IMAGE_BYTES = 1024 * 1024
DEFAULT_CAL_VALUE = 0x80
RETLW_OPCODE_BASE = 0x3400      # RETLW k, mid-range PIC14
CALL_OPCODE_BASE = 0x2000       # CALL k, 11-bit in-page target
CALL_PAGE_WORDS = 0x800         # a CALL reaches 11 bits without PCLATH help
HEX_DIGITS = frozenset("0123456789abcdefABCDEF")
REC_DATA = 0x00
REC_EOF = 0x01
REC_EXT_SEGMENT = 0x02
REC_EXT_LINEAR = 0x04


class ValidationError(Exception):
    pass


def read_image_text(path, label):
    """Read one Intel HEX file as text, without following a symbolic link."""
    try:
        info = os.lstat(path)
    except OSError as exc:
        raise ValidationError("%s is unavailable: %s" % (label, exc)) from exc
    if stat.S_ISLNK(info.st_mode):
        raise ValidationError("%s is a symbolic link: %s" % (label, path))
    if not stat.S_ISREG(info.st_mode):
        raise ValidationError("%s is not a regular file: %s" % (label, path))
    if info.st_size == 0:
        raise ValidationError("%s is empty: %s" % (label, path))
    if info.st_size > MAX_IMAGE_BYTES:
        raise ValidationError("%s exceeds the %d-byte limit: %s"
                              % (label, MAX_IMAGE_BYTES, path))
    try:
        with open(path, "r", encoding="ascii") as handle:
            return handle.read()
    except (OSError, UnicodeDecodeError) as exc:
        raise ValidationError("%s could not be read as ASCII: %s"
                              % (label, exc)) from exc


def parse_records(text, label):
    """Decode every Intel HEX record, rejecting anything malformed."""
    records = []
    saw_eof = False
    data_lines = {}
    for lineno, raw_line in enumerate(text.splitlines(), 1):
        line = raw_line.strip()
        if not line:
            continue
        if saw_eof:
            raise ValidationError("%s line %d: record follows the EOF record"
                                  % (label, lineno))
        if not line.startswith(":"):
            raise ValidationError("%s line %d: not an Intel HEX record"
                                  % (label, lineno))
        body = line[1:]
        if len(body) < 10 or len(body) % 2:
            raise ValidationError("%s line %d: truncated or odd-length record"
                                  % (label, lineno))
        # bytes.fromhex() tolerates embedded ASCII whitespace; the repository's
        # Intel HEX validator does not, so neither does this.
        if any(character not in HEX_DIGITS for character in body):
            raise ValidationError("%s line %d: not hexadecimal" % (label, lineno))
        try:
            raw = bytes.fromhex(body)
        except ValueError as exc:
            raise ValidationError("%s line %d: not hexadecimal: %s"
                                  % (label, lineno, exc)) from exc
        count, addr, rtype, data = raw[0], (raw[1] << 8) | raw[2], raw[3], raw[4:-1]
        if count != len(data):
            raise ValidationError(
                "%s line %d: byte count %d does not match %d data bytes"
                % (label, lineno, count, len(data)))
        if sum(raw) & 0xFF:
            raise ValidationError("%s line %d: bad checksum" % (label, lineno))
        if rtype in (REC_EXT_SEGMENT, REC_EXT_LINEAR):
            raise ValidationError(
                "%s line %d: extended-address record; this injector assumes "
                "flat 16-bit addressing" % (label, lineno))
        if rtype == REC_DATA and count == 0:
            raise ValidationError("%s line %d: empty data record"
                                  % (label, lineno))
        if rtype == REC_DATA and addr + count > 0x10000:
            raise ValidationError(
                "%s line %d: data record crosses the 16-bit address boundary"
                % (label, lineno))
        if rtype == REC_EOF:
            if line.upper() != ":00000001FF":
                raise ValidationError("%s line %d: malformed EOF record"
                                      % (label, lineno))
            saw_eof = True
        elif rtype != REC_DATA:
            raise ValidationError("%s line %d: unsupported record type 0x%02X"
                                  % (label, lineno, rtype))
        if rtype == REC_DATA:
            for offset in range(count):
                byte_addr = addr + offset
                if byte_addr in data_lines:
                    raise ValidationError(
                        "%s line %d: data byte address 0x%04X overlaps its "
                        "definition on line %d"
                        % (label, lineno, byte_addr, data_lines[byte_addr]))
                data_lines[byte_addr] = lineno
        records.append((line, count, addr, rtype, data))
    if not records:
        raise ValidationError("%s contains no records" % label)
    if not saw_eof:
        raise ValidationError("%s has no EOF record" % label)
    return records


def program_words(records, limit_words):
    """Assemble the little-endian program words below `limit_words`."""
    memory = {}
    for _line, _count, addr, rtype, data in records:
        if rtype != REC_DATA:
            continue
        for offset, value in enumerate(data):
            memory[addr + offset] = value
    words = {}
    for byte_addr, low in memory.items():
        if byte_addr % 2 or (byte_addr + 1) not in memory:
            continue
        word_addr = byte_addr // 2
        if word_addr < limit_words:
            words[word_addr] = low | (memory[byte_addr + 1] << 8)
    return words


def emit_record(addr, data, rtype=REC_DATA):
    body = bytes([len(data), (addr >> 8) & 0xFF, addr & 0xFF, rtype]) + data
    return ":" + (body + bytes([(-sum(body)) & 0xFF])).hex().upper()


def calibration_word(flash_words):
    """Validate the device size and return the calibration word's address."""
    if flash_words <= 0:
        raise ValidationError("flash size must be a positive number of words")
    cal_word = flash_words - 1
    if cal_word >= CALL_PAGE_WORDS:
        raise ValidationError(
            "calibration word 0x%X is beyond the first CALL page (0x%X words); "
            "this injector only supports parts whose calibration word is "
            "directly CALL-reachable" % (cal_word, CALL_PAGE_WORDS))
    return cal_word


def require_unprogrammed(records, label, flash_words, cal_word):
    """Require that no record programs either byte of the calibration word."""
    # Interval overlap against BOTH bytes of the word, not just its low byte: a
    # record starting at cal_byte+1 programs the opcode's high half, and the
    # injected record -- emitted last -- would silently win over it in a loader.
    cal_byte = cal_word * 2
    for _line, count, addr, rtype, _data in records:
        if rtype == REC_DATA and addr < cal_byte + 2 and cal_byte < addr + count:
            raise ValidationError(
                "%s already programs the calibration word 0x%03X (byte 0x%04X); "
                "either the image is for a larger part than %d words, or it has "
                "been injected already" % (label, cal_word, cal_byte, flash_words))


def require_calibration_call(records, label, flash_words, cal_word):
    """Require the image to fetch the word it is being judged against."""
    words = program_words(records, flash_words)
    call_opcode = CALL_OPCODE_BASE | cal_word
    if not any(word == call_opcode for word in words.values()):
        raise ValidationError(
            "%s never executes CALL 0x%03X (opcode 0x%04X), so word 0x%03X is "
            "not the calibration word this image fetches; check the %d-word "
            "flash size" % (label, cal_word, call_opcode, cal_word, flash_words))


def assert_preserves_calibration(text, label, flash_words):
    """Require an image that leaves the factory calibration word ALONE.

    The inverse of inject(), and the check a device programmer wants: return
    the calibration word's address, or raise ValidationError if this image
    would write it.

    THE CALL IS CHECKED FIRST, deliberately. "Word 0x3FF is not programmed" is
    trivially true of an image built for another part, or of any image checked
    against the wrong flash size -- so proving the image actually fetches this
    word is what stops a pass from being vacuous.
    """
    cal_word = calibration_word(flash_words)
    records = parse_records(text, label)
    require_calibration_call(records, label, flash_words, cal_word)
    require_unprogrammed(records, label, flash_words, cal_word)
    return cal_word


def inject(text, label, flash_words, value):
    """Return the derived image text, or raise ValidationError."""
    cal_word = calibration_word(flash_words)
    if not 0 <= value <= 0xFF:
        raise ValidationError("calibration value 0x%X is not a byte" % value)

    cal_byte = cal_word * 2
    records = parse_records(text, label)
    require_unprogrammed(records, label, flash_words, cal_word)
    require_calibration_call(records, label, flash_words, cal_word)

    opcode = RETLW_OPCODE_BASE | value
    cal_record = emit_record(cal_byte, bytes([opcode & 0xFF, (opcode >> 8) & 0xFF]))

    out_lines = []
    for line, _count, _addr, rtype, _data in records:
        if rtype == REC_EOF:
            out_lines.append(cal_record)      # immediately before EOF
        out_lines.append(line)
    derived = "\n".join(out_lines) + "\n"

    # Re-read what was produced rather than trusting the construction above.
    check = program_words(parse_records(derived, "derived image"), flash_words)
    if check.get(cal_word) != opcode:
        raise ValidationError("derived image does not carry RETLW 0x%02X at "
                              "word 0x%03X" % (value, cal_word))
    return derived, cal_word, opcode


def write_new_file(path, text, label, mode=None):
    """Publish complete `text` to a path that must not already exist."""
    directory = os.path.dirname(os.path.abspath(path)) or "."
    if not os.path.isdir(directory):
        raise ValidationError("output directory does not exist: %s" % directory)
    handle = tempfile.NamedTemporaryFile(
        mode="w", encoding="ascii", dir=directory, prefix=".simcal-", delete=False)
    try:
        with handle:
            handle.write(text)
        # NamedTemporaryFile creates 0600; the derived image should be exactly as
        # reachable as the shipping image it was derived from, no more, no less.
        if mode is not None:
            os.chmod(handle.name, mode)
        # The hard link publishes the complete temporary inode atomically and,
        # unlike os.replace(), fails if any file appeared at `path` after the
        # caller began. Source and destination are in the same directory.
        os.link(handle.name, path)
        os.unlink(handle.name)
    except FileExistsError as exc:
        try:
            os.unlink(handle.name)
        except OSError:
            pass
        raise ValidationError(
            "%s already exists: %s (refusing to overwrite -- the injector never "
            "modifies an existing image)" % (label, path)) from exc
    except OSError as exc:
        try:
            os.unlink(handle.name)
        except OSError:
            pass
        raise ValidationError("could not write %s: %s" % (path, exc)) from exc


def run(source, destination, flash_words, value):
    if os.path.lexists(destination) and os.path.lexists(source) \
            and os.path.samefile(source, destination):
        raise ValidationError("input and output are the same file: %s" % source)
    text = read_image_text(source, "source image")
    derived, cal_word, opcode = inject(text, source, flash_words, value)
    write_new_file(destination, derived, "output image",
                   mode=stat.S_IMODE(os.stat(source).st_mode))
    print("calibration word: RETLW 0x%02X (opcode 0x%04X) at word 0x%03X -> %s"
          % (value, opcode, cal_word, destination))
    return 0


def run_check(source, flash_words):
    text = read_image_text(source, "image")
    cal_word = assert_preserves_calibration(text, source, flash_words)
    print("PIC12F675_CALIBRATION_CHECK PASS image=%s word=0x%03X"
          % (source, cal_word))
    return 0


# ---------------------------------------------------------------------------
# Selftest
# ---------------------------------------------------------------------------

# A minimal well-formed 1024-word image: `CALL 0x3FF` at word 1, nothing at
# word 0x3FF, and a CONFIG word above program memory (which must be ignored).
SELFTEST_CALL = emit_record(0x0000, bytes([0x00, 0x28, 0xFF, 0x23]))
SELFTEST_CONFIG = emit_record(0x400E, bytes([0xCC, 0x31]))
SELFTEST_EOF = ":00000001FF"
SELFTEST_IMAGE = "\n".join([SELFTEST_CALL, SELFTEST_CONFIG, SELFTEST_EOF]) + "\n"

# Pinned encoding of the record this tool exists to produce, for a 1024-word
# part at the default value. If this line ever changes, the change is either a
# bug or a deliberate policy change that must be documented.
SELFTEST_EXPECTED_RECORD = ":0207FE00803445"


def run_selftest():
    checks = 0
    failures = 0

    def check(condition, label):
        nonlocal checks, failures
        checks += 1
        if not condition:
            failures += 1
            print("FAIL: %s" % label, file=sys.stderr)

    def rejects(text, fragment, label, flash_words=1024, value=DEFAULT_CAL_VALUE):
        nonlocal checks, failures
        checks += 1
        try:
            inject(text, "selftest image", flash_words, value)
        except ValidationError as exc:
            if fragment not in str(exc):
                failures += 1
                print("FAIL: %s -- rejected, but not for the stated reason: %s"
                      % (label, exc), file=sys.stderr)
            return
        failures += 1
        print("FAIL: %s -- accepted" % label, file=sys.stderr)

    def refuses(text, fragment, label, flash_words=1024):
        """rejects(), for the --assert-preserves-calibration side."""
        nonlocal checks, failures
        checks += 1
        try:
            assert_preserves_calibration(text, "selftest image", flash_words)
        except ValidationError as exc:
            if fragment not in str(exc):
                failures += 1
                print("FAIL: %s -- refused, but not for the stated reason: %s"
                      % (label, exc), file=sys.stderr)
            return
        failures += 1
        print("FAIL: %s -- accepted for programming" % label, file=sys.stderr)

    derived, cal_word, opcode = inject(SELFTEST_IMAGE, "selftest image", 1024,
                                       DEFAULT_CAL_VALUE)
    lines = derived.splitlines()
    check(cal_word == 0x3FF, "calibration word is the last word of flash")
    check(opcode == 0x3480, "opcode is RETLW 0x80")
    check(SELFTEST_EXPECTED_RECORD in lines,
          "emits the pinned record %s" % SELFTEST_EXPECTED_RECORD)
    check(lines == [SELFTEST_CALL, SELFTEST_CONFIG, SELFTEST_EXPECTED_RECORD,
                    SELFTEST_EOF],
          "adds exactly one record, immediately before EOF, changing nothing else")
    check(derived.endswith("\n"), "derived image ends with a newline")

    # The value reaches the emitted opcode, and every legal byte is accepted.
    for value in (0x00, 0x3C, 0xFF):
        text, _word, op = inject(SELFTEST_IMAGE, "selftest image", 1024, value)
        check(op == RETLW_OPCODE_BASE | value,
              "value 0x%02X reaches the opcode" % value)
        check(emit_record(0x07FE, bytes([op & 0xFF, (op >> 8) & 0xFF])) in
              text.splitlines(), "value 0x%02X reaches the record" % value)

    # Refusals: device parameters.
    rejects(SELFTEST_IMAGE, "not a byte", "value above a byte", value=0x100)
    rejects(SELFTEST_IMAGE, "not a byte", "negative value", value=-1)
    rejects(SELFTEST_IMAGE, "positive number of words", "zero flash size",
            flash_words=0)
    rejects(SELFTEST_IMAGE, "beyond the first CALL page",
            "calibration word out of CALL reach", flash_words=0x801)

    # Refusals: the address must be the one the firmware fetches.
    rejects(SELFTEST_IMAGE, "never executes CALL", "flash size too large",
            flash_words=2048)
    already = "\n".join([SELFTEST_CALL, emit_record(0x07FE, bytes([0x00, 0x34])),
                         SELFTEST_EOF]) + "\n"
    rejects(already, "already programs the calibration word",
            "calibration word already programmed")
    high_half = "\n".join([SELFTEST_CALL, emit_record(0x07FF, bytes([0x34])),
                            SELFTEST_EOF]) + "\n"
    rejects(high_half, "already programs the calibration word",
            "only the calibration word's high byte is programmed")
    rejects(derived, "already programs the calibration word",
            "re-injecting an already-injected image")
    small = "\n".join([emit_record(0x0000, bytes([0x00, 0x28, 0xFF, 0x21])),
                       emit_record(0x03FE, bytes([0x00, 0x34])),
                       SELFTEST_EOF]) + "\n"
    rejects(small, "already programs the calibration word",
            "flash size too small", flash_words=512)

    # The inverse check: what pic12f675-program asks before touching silicon.
    check(assert_preserves_calibration(SELFTEST_IMAGE, "selftest image", 1024)
          == 0x3FF, "accepts a shipping image and reports the word it checked")
    refuses(derived, "already programs the calibration word",
            "an injected image is refused for programming")
    refuses(already, "already programs the calibration word",
            "a hand-written calibration word is refused for programming")
    refuses(high_half, "already programs the calibration word",
            "a calibration high byte alone is refused for programming")
    # Vacuity, both ways: "word N is unprogrammed" must not be answerable about
    # a word this image never fetches. Without the CALL requirement, BOTH of
    # these would pass -- the exact failure that would wave a wrong part's
    # image through to the programmer.
    refuses(SELFTEST_IMAGE, "never executes CALL",
            "a shipping image checked against too large a flash size",
            flash_words=2048)
    refuses(SELFTEST_IMAGE, "never executes CALL",
            "a shipping image checked against too small a flash size",
            flash_words=512)
    # ...and the injected image is caught even at the wrong size, because at
    # 512 words it is the CALL that is missing rather than the word being clear.
    refuses(derived, "never executes CALL",
            "an injected image checked against too small a flash size",
            flash_words=512)

    # Refusals: malformed input.
    rejects("garbage\n", "not an Intel HEX record", "non-record line")
    rejects(":0207FE00803446\n", "bad checksum", "bad checksum")
    rejects(":0207FE0080344\n", "truncated or odd-length", "odd-length record")
    rejects(":0207FE\n", "truncated or odd-length", "truncated record")
    rejects(":0307FE00803445\n", "does not match", "byte count mismatch")
    rejects(":0207FE0080ZZ45\n", "not hexadecimal", "non-hex payload")
    # Even-length and correctly checksummed: without the strict digit check
    # bytes.fromhex() would skip the spaces and accept this outright.
    rejects(":02 07FE008034 45\n", "not hexadecimal",
            "whitespace inside a record")
    rejects("\n".join([SELFTEST_CALL, emit_record(0x0000, bytes([0x00, 0x10]),
                                                  rtype=REC_EXT_LINEAR),
                       SELFTEST_EOF]) + "\n",
            "extended-address record", "extended-address record")
    rejects(SELFTEST_CALL + "\n", "no EOF record", "missing EOF record")
    rejects("\n".join([SELFTEST_CALL, SELFTEST_EOF, SELFTEST_CONFIG]) + "\n",
            "record follows the EOF record", "record after EOF")
    rejects(":0000000000\n", "empty data record", "empty data record")
    overlap = "\n".join([SELFTEST_CALL,
                           emit_record(0x0002, bytes([0xFF, 0x23])),
                           SELFTEST_CONFIG, SELFTEST_EOF]) + "\n"
    rejects(overlap, "overlaps its definition on line 1",
            "overlapping data records")
    crossing = "\n".join([SELFTEST_CALL,
                            emit_record(0xFFFF, bytes([0x00, 0x00])),
                            SELFTEST_EOF]) + "\n"
    rejects(crossing, "crosses the 16-bit address boundary",
            "data record crossing the flat address space")
    rejects(":0400000300000005F4\n", "unsupported record type",
            "start-segment-address record")
    rejects("\n", "contains no records", "no records at all")

    # File-level refusals, on real paths.
    with tempfile.TemporaryDirectory(prefix="simcal-selftest-") as tmp:
        root = Path(tmp)
        source = root / "image.hex"
        source.write_text(SELFTEST_IMAGE, encoding="ascii")
        before = source.read_bytes()

        out = root / "image_simcal.hex"
        narration = io.StringIO()
        with redirect_stdout(narration):
            status = run(str(source), str(out), 1024, DEFAULT_CAL_VALUE)
        check(status == 0, "injects to a fresh output path")
        check("RETLW 0x80" in narration.getvalue()
              and "word 0x3FF" in narration.getvalue()
              and str(out) in narration.getvalue(),
              "narrates the value, the word and the destination")
        check(source.read_bytes() == before, "leaves the source image untouched")
        check(out.read_text(encoding="ascii") == derived,
              "the file written matches the derived text")
        source.chmod(0o640)
        moded = root / "moded_simcal.hex"
        with redirect_stdout(io.StringIO()):
            run(str(source), str(moded), 1024, DEFAULT_CAL_VALUE)
        check(stat.S_IMODE(moded.stat().st_mode) == 0o640,
              "derived image inherits the shipping image's mode")
        source.chmod(0o644)

        for label, call in (
            ("refuses an existing output path",
             lambda: run(str(source), str(out), 1024, DEFAULT_CAL_VALUE)),
            ("refuses to write over its own input",
             lambda: run(str(source), str(source), 1024, DEFAULT_CAL_VALUE)),
            ("refuses a missing source",
             lambda: run(str(root / "absent.hex"), str(root / "o.hex"), 1024,
                         DEFAULT_CAL_VALUE)),
            ("refuses an empty source",
             lambda: run(str(_touch(root / "empty.hex")), str(root / "o2.hex"),
                         1024, DEFAULT_CAL_VALUE)),
            ("refuses a directory as source",
             lambda: run(str(root), str(root / "o3.hex"), 1024,
                         DEFAULT_CAL_VALUE)),
            ("refuses a missing output directory",
             lambda: run(str(source), str(root / "absent" / "o.hex"), 1024,
                         DEFAULT_CAL_VALUE)),
        ):
            checks += 1
            try:
                with redirect_stdout(io.StringIO()):
                    call()
            except ValidationError:
                continue
            failures += 1
            print("FAIL: %s -- accepted" % label, file=sys.stderr)

        link = root / "link.hex"
        os.symlink(source.name, link)
        checks += 1
        try:
            with redirect_stdout(io.StringIO()):
                run(str(link), str(root / "o4.hex"), 1024, DEFAULT_CAL_VALUE)
            failures += 1
            print("FAIL: refuses a symlinked source -- accepted", file=sys.stderr)
        except ValidationError:
            pass

        # Reproduce the old check-then-os.replace() race: a competitor creates
        # the destination only when publication begins. The complete temporary
        # inode must lose that race without replacing the competitor's bytes.
        raced = root / "raced.hex"
        real_link = os.link

        def publish_after_racer(temporary, destination):
            raced.write_text("competitor\n", encoding="ascii")
            return real_link(temporary, destination)

        os.link = publish_after_racer
        checks += 1
        try:
            write_new_file(str(raced), derived, "raced output")
            failures += 1
            print("FAIL: refuses a destination created during publication -- "
                  "accepted", file=sys.stderr)
        except ValidationError as exc:
            if "already exists" not in str(exc) \
                    or raced.read_text(encoding="ascii") != "competitor\n":
                failures += 1
                print("FAIL: destination publication race changed the competing "
                      "file: %s" % exc, file=sys.stderr)
        finally:
            os.link = real_link

        check(sorted(p.name for p in root.iterdir()) ==
               ["empty.hex", "image.hex", "image_simcal.hex", "link.hex",
                "moded_simcal.hex", "raced.hex"],
               "leaves no temporary files behind")

    print("PIC calibration-word injection selftest: %d checks, %d failures"
          % (checks, failures))
    return 1 if failures else 0


def _touch(path):
    path.write_bytes(b"")
    return path


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--selftest", action="store_true",
                        help="run the built-in checks and exit")
    parser.add_argument("--assert-preserves-calibration", action="store_true",
                        help="do not inject: require that SOURCE leaves the "
                             "factory calibration word unprogrammed, as an "
                             "image about to be written to real silicon must")
    parser.add_argument("--flash-words", type=lambda s: int(s, 0),
                        help="device program memory size in words; the "
                             "calibration word is its last word")
    parser.add_argument("--value", type=lambda s: int(s, 0), default=None,
                        help="calibration byte to inject (default 0x%02X)"
                             % DEFAULT_CAL_VALUE)
    parser.add_argument("source", nargs="?", help="the shipping image to read")
    parser.add_argument("destination", nargs="?",
                        help="the derived image to create; must not exist")
    args = parser.parse_args(argv)

    if args.selftest:
        if args.source or args.destination or args.flash_words is not None \
                or args.value is not None or args.assert_preserves_calibration:
            parser.error("--selftest accepts no other options or paths")
        return run_selftest()
    if args.flash_words is None:
        parser.error("--flash-words is required")

    try:
        if args.assert_preserves_calibration:
            # A checking mode that quietly accepted an injection value, or a
            # destination it was never going to write, would be a trap.
            if args.value is not None:
                parser.error("--assert-preserves-calibration injects nothing, "
                             "so it takes no --value")
            if not args.source or args.destination:
                parser.error("--assert-preserves-calibration takes exactly one "
                             "image to check")
            return run_check(args.source, args.flash_words)
        if not args.source or not args.destination:
            parser.error("a source and a destination image are required")
        value = DEFAULT_CAL_VALUE if args.value is None else args.value
        return run(args.source, args.destination, args.flash_words, value)
    except ValidationError as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
