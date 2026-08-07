#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
#
# test_attiny202_delay_oracle.py -- verify the ABSOLUTE width of the ATtiny202
# coil-pulse blocking delays directly from the COMPILED IMAGE.
#
# WHY THIS EXISTS (and how it divides work with the yasimavr harness)
# ------------------------------------------------------------------
# The relay SET/RESET pulse (12 ms) and the muted-x4053 mute window (5 ms) are
# avr-libc _delay_ms() busy loops (src/bypass_blocking_delay.h). Their duration
# is therefore a pure function of the CPU CYCLE COUNT baked into the image at
# compile time -- expected_ms * F_CPU cycles.
#
# Reading that count out of the image is the tightest and most direct check
# available: it is simulator-independent, it needs no running device, and it
# resolves the width to a few loop iterations (+/-0.10 ms below). That is why
# this oracle owns the ABSOLUTE DESIGN WIDTH even though a simulator can measure
# a width too.
#
# The yasimavr harness (test_sim_attiny202.check_pulse_width) measures something
# related but distinct: the DELIVERED width, the span the pin actually held,
# taken from exact traced transition cycles. Expect it slightly ABOVE the
# compiled width, because the 1 ms TCB0 tick ISR preempts the busy loop at ~110
# cycles a tick -- about 5.5% of elapsed time whatever the pulse length, so the
# 12 ms pulse occupies ~12.67 ms of pin-high time and the 5 ms mute ~5.28 ms.
# (The relay's startup pulse runs before sei() and so measures ~12.01 ms.) The
# compiled loop count this oracle reads is the delay proper, which is what the
# design specifies; neither check subsumes the other.
#
# A NOTE ON THE PINNED SIMULATOR (corrected 2026-08-02, superseded 2026-08-07)
# ---------------------------------------------------------------------------
# Earlier revisions of this header said the harness could not check width at all,
# first because yasimavr 0.1.6 "charges a flat ~1 cycle per instruction" (WRONG:
# its AVR-XT core does model multi-cycle instruction timing), then because of the
# real defect -- SimLoop.run() forces the cycle counter to first_cycle + nbcycles
# on return, REWINDING it whenever the last instruction overshoots, so a caller
# advancing in tiny budgets loses up to one instruction's worth of cycles per
# call and at run(1) bills every instruction exactly 1 cycle.
#
# That defect is real, is reported upstream and confirmed with a fix pending
# release, but it no longer reaches this project: the output tracer no longer
# steps cycle by cycle. It free-runs in millisecond budgets and timestamps pin
# edges from a signal hook, which measures the true widths on the pinned 0.1.6.
# TCB0-tick timing was never affected either way -- the tick period is counted by
# the peripheral, not by summing instruction cycles.
#
# WHAT IT CHECKS
#   For each built variant image it disassembles the flash (avr-objdump -d),
#   finds every avr-libc _delay_ms busy loop, recovers its 16-bit iteration
#   count, converts that to milliseconds at F_CPU, and asserts the per-variant
#   expected set of pulse widths (and the relay's 4 ms datasheet minimum). Every
#   recognized loop must have a decodable 16-bit seed; none may be discarded:
#       cd4053_simple    (simple x4053): no coil pulse -> zero delay loops
#       cd4053_with_mute (muted x4053) : two 5 ms mute windows (engage+bypass)
#       tq2_l2_5v_relay  (TQ2-L2-5V)   : two 12 ms coil pulses (engage+bypass)
#
# MODES
#   test_attiny202_delay_oracle.py <elf> [<elf> ...]   verify real built images
#   test_attiny202_delay_oracle.py --selftest          host-only parser
#                                                       regression (no ELF/DFP;
#                                                       runs in `make test`)
#
# Exit: 0 = PASS, 1 = a check failed, 2 = bad invocation / tool missing.

import os
import re
import shutil
import subprocess
import sys

# --- device / timing constants (match the shell + the yasimavr harness) ------
F_CPU_HZ = 2_000_000          # 16 MHz OSC / PDIV 8 (see sim_attiny202.F_CPU_HZ)
DELAY_LOOP_CYCLES = 4         # avr-libc _delay_ms body: SBIW(2) + taken BRNE(2)
RELAY_MIN_MS = 4              # TQ2-L2-5V coil-set datasheet minimum

# The absolute width is deterministic (compile-time), so the tolerance only has
# to absorb avr-libc's few-cycle loop-setup/remainder rounding, not simulator
# jitter. One loop iteration is 4 cycles = 2 us here, so +/-0.10 ms is ~50
# iterations of slack -- generous, yet far tighter than any traced width could
# be (a trace also carries the ~0.67 ms of tick-ISR preemption noted in the
# header) and far inside any physically meaningful margin.
WIDTH_TOLERANCE_MS = 0.10

VARIANTS = ("cd4053_simple", "cd4053_with_mute", "tq2_l2_5v_relay")

# Expected coil-pulse widths per variant, in milliseconds. Each variant drives
# the pulse on BOTH the engage and the bypass path, so a non-empty set lists the
# design width twice. cd4053_simple has no blocking pulse at all.
EXPECTED_WIDTHS_MS = {
    "cd4053_simple": [],
    "cd4053_with_mute": [5, 5],
    "tq2_l2_5v_relay": [12, 12],
}
# Variants whose pulses must also clear a datasheet minimum coil-energise time.
RELAY_MINIMUM_VARIANTS = ("tq2_l2_5v_relay",)

# avr-libc compiles _delay_ms() to a 4-cycle busy loop:
#     ldi  rL, <lo>          ; low  byte of the 16-bit iteration count
#     ldi  rH, <hi>          ; high byte
#   L: sbiw rL, 0x01         ; decrement the count word
#     brne L                 ; loop until zero  (target == the sbiw)
# The `sbiw rL, 0x01` + `brne`-to-self pair is a precise signature: the only
# other back-branches in the image (bss clear, the polled main loop) neither
# decrement a word by one nor branch straight back onto an sbiw. We match that
# pair, then read the count from the two immediately preceding `ldi`s into the
# same low/high register.
_SBIW_RE = re.compile(
    r"^\s*([0-9a-f]+):\s+[0-9a-f ]+\s+sbiw\s+r(\d+),\s*0x0*1\b", re.I)
# The branch displacement in objdump's `.-4` form is relative to the FOLLOWING
# instruction, so we do not recompute it -- we read objdump's own resolved
# absolute target from the trailing `; 0xNNN` comment, which is unambiguous.
_BRNE_RE = re.compile(
    r"^\s*([0-9a-f]+):\s+[0-9a-f ]+\s+brne\s+\.[+-]\d+\s*;\s*0x([0-9a-f]+)", re.I)
_LDI_RE = re.compile(
    r"^\s*[0-9a-f]+:\s+[0-9a-f ]+\s+ldi\s+r(\d+),\s*0x([0-9a-f]+)", re.I)


class DelayLoopDecodeError(Exception):
    """A recognized delay-loop candidate has no provable iteration seed."""


def _ldi_value(line, want_reg):
    """Return the immediate an `ldi rWANT, 0xNN` line loads, or None."""
    m = _LDI_RE.match(line)
    if not m:
        return None
    if int(m.group(1)) != want_reg:
        return None
    return int(m.group(2), 16)


def parse_delay_loops(objdump_text):
    """Recover the iteration count of every avr-libc _delay_ms busy loop.

    Returns a list of 16-bit iteration counts, one per delay loop, in the order
    they appear in the disassembly. Pure text function so it is exercised both
    against real images and against synthetic snippets in --selftest. Raises
    DelayLoopDecodeError rather than omitting a recognized loop whose seed
    registers cannot be decoded.
    """
    lines = objdump_text.splitlines()
    counts = []
    for i, line in enumerate(lines):
        sbiw = _SBIW_RE.match(line)
        if not sbiw:
            continue
        sbiw_addr = int(sbiw.group(1), 16)
        low_reg = int(sbiw.group(2))          # sbiw addresses the low register
        high_reg = low_reg + 1

        # The next instruction must be a BRNE back onto this sbiw.
        if i + 1 >= len(lines):
            continue
        brne = _BRNE_RE.match(lines[i + 1])
        if not brne:
            continue
        if int(brne.group(2), 16) != sbiw_addr:
            continue                          # branches elsewhere: not a delay

        # The two immediately preceding instructions must seed this exact count
        # register pair. Looking farther back can borrow stale LDIs from a prior
        # loop and turn an unseeded candidate into false timing evidence.
        lo = hi = None
        for j in range(i - 1, max(-1, i - 3), -1):
            if lo is None:
                lo = _ldi_value(lines[j], low_reg)
                if lo is not None:
                    continue
            if hi is None:
                hi = _ldi_value(lines[j], high_reg)
            if lo is not None and hi is not None:
                break
        if lo is None or hi is None:
            missing = []
            if lo is None:
                missing.append("r%d" % low_reg)
            if hi is None:
                missing.append("r%d" % high_reg)
            raise DelayLoopDecodeError(
                "recognized sbiw/brne loop at 0x%X has undecodable ldi "
                "seed register(s): %s" % (sbiw_addr, ", ".join(missing)))
        counts.append((hi << 8) | lo)
    return counts


def loop_ms(count, f_cpu=F_CPU_HZ):
    """Convert a _delay_ms loop iteration count to milliseconds at f_cpu."""
    return count * DELAY_LOOP_CYCLES * 1000.0 / f_cpu


class Checker:
    def __init__(self):
        self.fails = 0
        self.checks = 0

    def check(self, ok, msg):
        self.checks += 1
        status = "OK  " if ok else "FAIL"
        stream = sys.stdout if ok else sys.stderr
        stream.write("[delay] %s  %s\n" % (status, msg))
        stream.flush()
        if not ok:
            self.fails += 1
        return ok


def _match_widths(measured_ms, expected_ms):
    """Greedily pair each expected width with a measured one within tolerance.

    Returns (matched_ok, leftover_measured). matched_ok is True only if every
    expected width found a distinct partner AND no measured pulse is left over
    (an extra, unexpected delay is a failure too).
    """
    remaining = list(measured_ms)
    for want in expected_ms:
        hit = None
        for idx, got in enumerate(remaining):
            if abs(got - want) <= WIDTH_TOLERANCE_MS:
                hit = idx
                break
        if hit is None:
            return False, remaining
        remaining.pop(hit)
    return len(remaining) == 0, remaining


def check_variant(ck, variant, counts):
    """Assert the disassembled delay loops match the variant's design timing."""
    measured = sorted(loop_ms(c) for c in counts)
    expected = EXPECTED_WIDTHS_MS[variant]

    matched, leftover = _match_widths(measured, expected)
    pretty = ", ".join("%.3f ms" % m for m in measured) or "(none)"
    ck.check(
        matched,
        "%s: coil-pulse widths [%s] == design %s (+/-%.2f ms)"
        % (variant, pretty, expected or "(none)", WIDTH_TOLERANCE_MS))

    if variant in RELAY_MINIMUM_VARIANTS:
        ck.check(
            bool(measured) and all(m >= RELAY_MIN_MS for m in measured),
            "%s: every coil pulse >= %d ms datasheet minimum (%s)"
            % (variant, RELAY_MIN_MS, pretty))


def check_disassembly(ck, variant, objdump_text):
    """Parse one image's disassembly and check its complete timing evidence."""
    try:
        counts = parse_delay_loops(objdump_text)
    except DelayLoopDecodeError as exc:
        ck.check(False, "%s: delay-loop oracle error: %s" % (variant, exc))
        return
    check_variant(ck, variant, counts)


def variant_of(elf_path):
    """Map an image path (bypass-<mcu>-<variant>.elf) to its variant.

    The basename's third field IS the variant name, so this only has to split
    and validate. Split on the field delimiter rather than searching for a
    substring: the variant names share prefixes (`cd4053_simple` /
    `cd4053_with_mute`), and a substring match would also accept a name with the
    wrong field count. An unrecognized or malformed name returns None and the
    caller fails it.
    """
    stem = os.path.basename(elf_path).rsplit(".", 1)[0]
    fields = stem.split("-")
    if len(fields) != 3 or fields[2] not in VARIANTS:
        return None
    return fields[2]


def disassemble(elf_path):
    objdump = os.environ.get("OBJDUMP", "avr-objdump")
    if shutil.which(objdump) is None:
        sys.stderr.write("ERROR: %s not found (install binutils-avr).\n" % objdump)
        sys.exit(2)
    try:
        return subprocess.check_output(
            [objdump, "-d", elf_path], text=True, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as exc:
        sys.stderr.write("ERROR: %s -d %s failed:\n%s\n"
                         % (objdump, elf_path, exc.output))
        sys.exit(2)


def verify_images(elf_paths):
    ck = Checker()
    for elf in elf_paths:
        if not os.path.isfile(elf):
            ck.check(False, "image not found: %s" % elf)
            continue
        variant = variant_of(elf)
        if variant is None:
            ck.check(False, "cannot map %s to a known variant" % elf)
            continue
        check_disassembly(ck, variant, disassemble(elf))
    if not elf_paths:
        ck.check(False, "no ATtiny202 images given to verify")
    print("[delay] %d checks, %d failures" % (ck.checks, ck.fails))
    return 1 if ck.fails else 0


# ----------------------------------------------------------------------------
# Host-only parser regression (no ELF, no DFP). Runs in `make test` so a
# codegen/parse drift or a broken width assertion is caught even where the
# ATtiny_DFP is absent and no image can be built.
# ----------------------------------------------------------------------------
def _synthetic(loops):
    """Build a minimal objdump-style snippet with the given loops.

    `loops` is a list of (low_reg, count) pairs. A None count emits a recognized
    sbiw/brne candidate without its seed LDIs. Other entries emit the exact
    avr-libc ldi/ldi/sbiw/brne shape. Decoy back-branches must NOT be parsed as
    delays (a bss-style clear and a plain conditional branch).
    """
    out = [
        "0000004a <.do_clear_bss_start>:",
        "  48:\t11 92\tst\tX+, r1",
        "  4e:\te1 f7\tbrne\t.-8      ; 0x48 <.do_clear_bss_loop>",
    ]
    addr = 0x300
    for low_reg, count in loops:
        if count is not None:
            hi, lo = (count >> 8) & 0xFF, count & 0xFF
            out.append("%4x:\t8f e6\tldi\tr%d, 0x%02X" % (addr, low_reg, lo))
            out.append("%4x:\t97 e1\tldi\tr%d, 0x%02X" % (addr + 2, low_reg + 1, hi))
        out.append("%4x:\t01 97\tsbiw\tr%d, 0x01\t; 1" % (addr + 4, low_reg))
        out.append("%4x:\tf1 f7\tbrne\t.-4      ; 0x%x" % (addr + 6, addr + 4))
        addr += 0x20
    # A decoy: a brne that does NOT target its preceding sbiw.
    out.append("%4x:\t01 97\tsbiw\tr24, 0x01\t; 1" % addr)
    out.append("%4x:\td1 f6\tbrne\t.-72     ; 0x%x" % (addr + 2, addr - 0x40))
    return "\n".join(out)


def selftest():
    ck = Checker()

    # Iteration counts for the real design widths at 2 MHz: ms * F_CPU / 1000 / 4.
    n5 = int(round(5 * F_CPU_HZ / 1000 / DELAY_LOOP_CYCLES))    # 2500
    n12 = int(round(12 * F_CPU_HZ / 1000 / DELAY_LOOP_CYCLES))  # 6000

    # Parser: recovers exactly the delay loops, ignoring the decoys.
    counts = parse_delay_loops(_synthetic([(24, n12), (24, n5)]))
    ck.check(counts == [n12, n5],
             "parser recovers delay counts, skips decoys (got %r)" % counts)

    # Conversion round-trips to the design width.
    ck.check(abs(loop_ms(n12) - 12) <= WIDTH_TOLERANCE_MS, "6000-iter loop == 12 ms")
    ck.check(abs(loop_ms(n5) - 5) <= WIDTH_TOLERANCE_MS, "2500-iter loop == 5 ms")

    # A high register other than r24 (e.g. sbiw r26) still parses.
    ck.check(parse_delay_loops(_synthetic([(26, n5)])) == [n5],
             "parser handles a non-r24 count register")

    # Per-variant acceptance: correct images pass, and the exact avr-libc count
    # actually emitted (off-by-one from rounding) is inside tolerance.
    def counts_for(widths):
        return [int(round(w * F_CPU_HZ / 1000 / DELAY_LOOP_CYCLES)) for w in widths]

    ck.check(_variant_fails("cd4053_simple", []) == 0, "cd4053 with no loops passes")
    ck.check(_variant_fails("cd4053_with_mute", counts_for([5, 5])) == 0, "mute with two 5 ms passes")
    ck.check(_variant_fails("tq2_l2_5v_relay", [5999, 5999]) == 0,
             "relay with avr-libc's real 5999-iter loops passes")

    # Fail-closed: wrong count, missing pulse, extra pulse, sub-minimum relay.
    ck.check(_variant_fails("tq2_l2_5v_relay", counts_for([12, 6])) > 0,
             "relay with a half-width pulse fails")
    ck.check(_variant_fails("tq2_l2_5v_relay", counts_for([12])) > 0,
             "relay missing a pulse fails")
    ck.check(_variant_fails("cd4053_with_mute", counts_for([5, 5, 5])) > 0,
             "mute with an extra unexpected pulse fails")
    ck.check(_variant_fails("cd4053_simple", counts_for([5])) > 0,
             "simple cd4053 with any coil pulse fails")
    # A relay pulse below the 4 ms datasheet minimum trips both width and minimum.
    ck.check(_variant_fails("tq2_l2_5v_relay", counts_for([3, 3])) >= 2,
             "sub-minimum relay pulse fails design width AND datasheet minimum")

    # A complete loop signature with an undecodable seed is an oracle error,
    # never absence of evidence.
    ck.check(_disassembly_fails("cd4053_simple", _synthetic([(30, None)])) == 1,
             "simple cd4053 with an undecodable delay candidate fails")
    ck.check(_disassembly_fails(
                 "cd4053_with_mute",
                 _synthetic([(24, n5), (24, n5), (30, None)])) == 1,
             "mute with valid loops plus an undecodable extra candidate fails")

    try:
        parse_delay_loops(_synthetic([(30, None)]))
    except DelayLoopDecodeError as exc:
        decode_error = str(exc)
    else:
        decode_error = ""
    ck.check("0x304" in decode_error and "r30, r31" in decode_error,
             "undecodable candidate reports its address and missing seed pair")

    try:
        parse_delay_loops(_synthetic([(24, n5), (24, n5), (24, None)]))
    except DelayLoopDecodeError as exc:
        stale_seed_error = str(exc)
    else:
        stale_seed_error = ""
    ck.check("0x344" in stale_seed_error and "r24, r25" in stale_seed_error,
             "unseeded loop cannot borrow the preceding loop's seed pair")

    print("[delay] selftest: %d checks, %d failures" % (ck.checks, ck.fails))
    return 1 if ck.fails else 0


def _variant_fails(variant, counts):
    """Run check_variant on a silent Checker; return the failure count."""
    import contextlib
    import io
    ck = Checker()
    with contextlib.redirect_stdout(io.StringIO()), \
            contextlib.redirect_stderr(io.StringIO()):
        check_variant(ck, variant, counts)
    return ck.fails


def _disassembly_fails(variant, objdump_text):
    """Run the production parse/check path silently; return its failure count."""
    import contextlib
    import io
    ck = Checker()
    with contextlib.redirect_stdout(io.StringIO()), \
            contextlib.redirect_stderr(io.StringIO()):
        check_disassembly(ck, variant, objdump_text)
    return ck.fails


def main(argv):
    if len(argv) >= 2 and argv[1] == "--selftest":
        return selftest()
    if len(argv) < 2:
        sys.stderr.write(
            "usage: %s <image.elf> [<image.elf> ...] | --selftest\n" % argv[0])
        return 2
    return verify_images(argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
