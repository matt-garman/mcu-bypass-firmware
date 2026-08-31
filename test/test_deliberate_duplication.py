#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman

"""The register of deliberate duplication: folding one of these fails here.

THE DEFECT CLASS is a merge that leaves every gate green. A handful of facts in
this tree are decided TWICE on purpose, by two routes that are able to disagree:
two core generations, two compilers, two execution models, two input artifacts,
two languages. Each pair is a second opinion, and the PAIR is the evidence --
not either half of it. Fold a pair into one shared definition and the survivor
still agrees with itself, every existing test still passes, and half the
evidence is gone. Nothing reports the loss, because after the merge there is
nothing left to disagree with.

That is why a duplication listed here is not untidiness to be cleaned up, and
why a smaller line count is never a reason to remove one. This file is the
review a consolidation would otherwise skip: each row names the independent
opinion that dies, and asserts a structural witness that fails when it does.
The failure message carries the reason, so whoever folds the duplication reads
it at the moment they would otherwise have merged in silence.

WHAT THIS FILE DOES NOT DO. It does not check that either opinion is correct --
the formal, simulation, oracle and hardware layers do that, and a disagreement
is what they exist to catch. It proves only that there are still two of them.
It is entirely lexical: no compiler, no device pack, no build. That is
deliberate. The loss it detects is a source edit, so a check that needed the
PIC toolchain would go quiet on exactly the hosts most likely to attempt one.

ROWS HELD ELSEWHERE ARE NOT RESTATED HERE. test_static_assert_guards.sh already
fails when the self-contained shell's copy of the watchdog conversion drifts
from the modular header's, and when a shell stops including the shared
threshold header without being recorded as carrying its own copy. Repeating
those claims here would create a third copy of them, which is the failure mode
this file exists to describe.

CHANGING A ROW IS ALLOWED, and is a deliberate act rather than a number edited
until the run goes green: say which opinion replaces the one being retired.
"""

from pathlib import Path
import os
import re
import sys

from source_contract import strip_c_comments


# Overridable ONLY so this file's own failure modes can be exercised against a
# doctored copy of the tree -- a shell given a shared header, a pin map that
# defers to another, a folded verification layer -- without editing the
# firmware to test the thing that watches the firmware. The Make target never
# sets it.
ROOT = Path(os.environ.get("DUPLICATION_ROOT") or Path(__file__).resolve().parent.parent)
SRC = ROOT / "src"
TEST = ROOT / "test"
MAKEFILE = ROOT / "Makefile"


# The four shells that reach the shared headers, each with the pin map that
# bypass_output_common.h's selection chain picks for it.
MODULAR_SHELLS = {
    "bypass_mcu_avr_classic.c": "bypass_pins_avr_classic.h",
    "bypass_mcu_avr_xt.c": "bypass_pins_avr_xt.h",
    "bypass_mcu_pic10f322.c": "bypass_pins_pic10f322.h",
    "bypass_mcu_pic12f675.c": "bypass_pins_pic12f675.h",
}
SELF_CONTAINED_SHELL = "bypass_mcu_pic10f320.c"
ALL_SHELLS = tuple(sorted(set(MODULAR_SHELLS) | {SELF_CONTAINED_SHELL}))

INTERRUPT_DRIVEN_SHELLS = ("bypass_mcu_avr_classic.c", "bypass_mcu_avr_xt.c")
POLLED_SHELLS = (
    "bypass_mcu_pic10f320.c",
    "bypass_mcu_pic10f322.c",
    "bypass_mcu_pic12f675.c",
)

# Every term of the watchdog pet-to-pet bound that is a property of the PART
# rather than of the arithmetic, plus the two pins every variant drives.
PER_PART_TERMS = (
    "TICK_PERIOD_MS",
    "WDT_MIN_PERIOD_MS",
    "WDT_LOOP_WORK_MS",
    "WDT_ISR_STRETCH_PCT",
)
PER_PART_PINS = ("FOOTSW_PIN", "LED_PIN")

# The clock each shell's timing is derived from. Supplied by the build, never
# by the firmware; see the clock row.
SHELL_CLOCK = {
    "bypass_mcu_avr_classic.c": "F_CPU",
    "bypass_mcu_avr_xt.c": "F_CPU",
    "bypass_mcu_pic10f320.c": "_XTAL_FREQ",
    "bypass_mcu_pic10f322.c": "_XTAL_FREQ",
    "bypass_mcu_pic12f675.c": "_XTAL_FREQ",
}

# Test-tree files that reach a firmware pin map on purpose, because they COMPILE
# production code on the host rather than state an expectation about it. Named
# rather than inferred: a harness that starts reading the firmware's own map to
# decide what it expects to see must arrive here as a visible edit.
FIRMWARE_COMPILING_HARNESSES = (
    "test/bypass_output_host.h",
    "test/watchdog_budget_compile.c",
    "test/pic/fw_coverage/fw_coverage_harness.c",
    "test/pic/fw_coverage/test_fw_coverage.c",
)

# The independent verification substrates. Rows 2 and 3 deliberately share a
# subject -- two engines over one symbolic harness -- so distinctness is
# asserted on the target and on the artifact whose loss removes the layer, not
# on the harness itself. This row detects a layer being DELETED or unwired; a
# target quietly reduced to an alias of another is beyond a lexical check and
# stays the reviewer's job.
VERIFICATION_LAYERS = (
    ("exhaustive BFS model check", "test/formal/test_model_check.c", "test-model-check"),
    ("symbolic execution, host engine", "test/formal/test_symbolic.c", "test-symbolic"),
    ("symbolic execution, KLEE engine", "test/test_klee_build.sh", "test-symbolic-klee"),
    ("bounded model checking", "test/formal/test_cbmc.c", "test-cbmc"),
    ("mutation", "test/run_mutation_tests.sh", "test-mutation"),
    ("verified-core line coverage", "src/bypass_pure.c", "coverage-check-core"),
    ("shipping-source coverage", "test/pic/fw_coverage/run_fw_coverage.sh",
     "pic10f322-coverage-check-fw"),
    ("AVR instruction simulation", "test/avr/test_sim.c", "test-sim-attiny13a"),
    ("PIC instruction simulation", "test/pic/run_gpsim_test.sh", "pic10f322-test-gpsim"),
    ("hardware qualification", "HARDWARE_VALIDATION_LOG.md", "test-release-preflight"),
)

# The two return-stack witnesses, and the input each one trusts. The PIC14
# hardware return stack wraps silently -- no STKPTR, no overflow reset, nothing
# observable at runtime -- so the bound is only ever as good as the static
# analysis, and one analysis is a single point of failure.
STACK_WITNESSES = (
    ("compiler-generated assembly", "test/check_stack_depth_pic.sh",
     "<generated.s>", (".hex", "Intel HEX")),
    ("shipped Intel HEX image", "test/pic10f320/return_stack_oracle.py",
     "IMAGE.hex", ("generated.s",)),
)

# The production release identity, and what each pinned definition is allowed to
# read. The pin exists to be a SECOND opinion about which images a release
# contains, so its whole value is that it is spelled in literal words: the
# Makefile block says so itself ("a pin computed from FW_BASE would agree with
# the very thing it exists to check"). An empty allowance means the definition
# may reference nothing at all. `foreach` is Make's own function name rather
# than a variable, and `m`/`v` are that function's loop variables.
RELEASE_IDENTITY_PINS = (
    ("RELEASE_IDENTITY_PINNED", frozenset()),
    ("RELEASE_IDENTITY_PARTS", frozenset()),
    ("RELEASE_IDENTITY_SOAK_PARTS", frozenset()),
    ("RELEASE_IDENTITY_VARIANTS", frozenset()),
    ("RELEASE_IDENTITY_IMAGES", frozenset({
        "foreach", "m", "v",
        "RELEASE_IDENTITY_PARTS", "RELEASE_IDENTITY_VARIANTS"})),
    ("RELEASE_IDENTITY_SOAKS", frozenset({
        "foreach", "m", "v",
        "RELEASE_IDENTITY_SOAK_PARTS", "RELEASE_IDENTITY_VARIANTS"})),
)

C_FAMILY = (".c", ".cc", ".cpp", ".h", ".hpp")

INCLUDE_RE = re.compile(r'^[ \t]*#[ \t]*include[ \t]*(["<])([^">]+)[">]', re.MULTILINE)
MAIN_RE = re.compile(r"\bmain[ \t]*\([ \t]*void[ \t]*\)")
ISR_RE = re.compile(r"^[ \t]*ISR[ \t]*\([ \t]*([A-Za-z0-9_]+)[ \t]*\)", re.MULTILINE)
MAKE_REFERENCE = re.compile(r"\$[({]([A-Za-z_][A-Za-z0-9_]*)")

REGISTER = []
FAILURES = []
checks = 0
HARNESSES_SCANNED = 0


def row(identifier, opinion):
    """Register one deliberate duplication and the opinion its loss destroys."""

    def wrap(function):
        REGISTER.append((identifier, opinion, function))
        return function

    return wrap


def note(identifier, witness):
    FAILURES.append((identifier, witness))


def counted(condition, identifier, witness):
    global checks
    checks += 1
    if not condition:
        note(identifier, witness)
    return condition


def code(path):
    """File text with comments removed; line structure is preserved."""
    return strip_c_comments(path.read_text(encoding="utf-8"))


def quoted_includes(source):
    return [Path(name).name for delimiter, name in INCLUDE_RE.findall(source)
            if delimiter == '"']


def make_definition(makefile, name):
    """Return the right-hand side of `override <name> :=`, continuations joined.

    None when the Makefile does not define the name that way at all, which is
    itself a finding: a pin that stopped being an `override` is a pin a caller
    can move.
    """
    match = re.search(r"^override[ \t]+%s[ \t]*:=" % re.escape(name),
                      makefile, re.MULTILINE)
    if match is None:
        return None
    value = []
    for line in makefile[match.end():].split("\n"):
        if line.endswith("\\"):
            value.append(line[:-1])
            continue
        value.append(line)
        break
    return " ".join(part.strip() for part in value).strip()


def defines(source, name):
    pattern = re.compile(r"^[ \t]*#[ \t]*define[ \t]+%s\b[ \t]*(.*)$" % re.escape(name),
                         re.MULTILINE)
    return [match.strip() for match in pattern.findall(source)]


# ---------------------------------------------------------------------------


@row("pic10f320-shell-shares-no-header",
     "the PIC10F320 shell is a SECOND implementation of the debounce algorithm "
     "and of the output stages, compiled for a 256-word part by a different "
     "compiler from the AVR shells. It reaches no header this tree owns, so a "
     "change to the shared headers cannot reach it, and its agreement with "
     "bypass_pure.c under the equivalence and lock-step lanes is agreement "
     "between two texts rather than one text observed twice")
def pic10f320_is_self_contained():
    shell = SRC / SELF_CONTAINED_SHELL
    if not counted(shell.is_file(), "pic10f320-shell-shares-no-header",
                   "%s is gone" % SELF_CONTAINED_SHELL):
        return
    source = code(shell)

    reached = quoted_includes(source)
    counted(not reached, "pic10f320-shell-shares-no-header",
            "the shell now includes %s; it is self-contained precisely so that "
            "editing a shared header cannot silently edit it"
            % ", ".join(sorted(reached)))

    # Being self-contained is a claim about what it carries, not only about what
    # it declines to include: its own pin ordinals and its own four watchdog
    # terms. A shell that had stopped defining these would be reaching for
    # someone else's, whatever its include list said.
    for name in PER_PART_PINS + PER_PART_TERMS:
        counted(len(defines(source, name)) == 1, "pic10f320-shell-shares-no-header",
                "the shell no longer defines exactly one %s of its own" % name)


@row("pin-map-per-part",
     "each part's pin ordinals and its four watchdog terms -- tick period, "
     "de-rated floor, loop work, ISR duty -- are physics of that part, read "
     "from its own datasheet. Keeping one map per part is what makes the "
     "watchdog bound a per-part claim; a shared default would let one part's "
     "floor stand in for another's and be checked by nobody")
def pin_maps_are_per_part():
    identifier = "pin-map-per-part"
    for shell, header in sorted(MODULAR_SHELLS.items()):
        path = SRC / header
        if not counted(path.is_file(), identifier,
                       "%s, the pin map for %s, is gone" % (header, shell)):
            continue
        source = code(path)

        reached = quoted_includes(source)
        counted(not reached, identifier,
                "%s now includes %s; a pin map that defers to another file is "
                "no longer an independent statement of that part's pins"
                % (header, ", ".join(sorted(reached))))

        for name in PER_PART_PINS + PER_PART_TERMS:
            values = defines(source, name)
            if not counted(len(values) == 1, identifier,
                           "%s does not define exactly one %s" % (header, name)):
                continue
            # A literal, not a reference: `#define WDT_LOOP_WORK_MS OTHER_PART`
            # would satisfy a presence check while making the two parts one.
            literal = values[0]
            counted(re.fullmatch(r"\(\s*\d+U?L?\s*\)", literal) is not None,
                    identifier,
                    "%s defines %s as %s rather than as its own literal"
                    % (header, name, literal or "nothing"))

    # The selection chain is the other half: a map nothing selects is not in the
    # build, and a shell whose arm has been dropped falls through to another
    # part's pins instead of to the #error.
    common = SRC / "bypass_output_common.h"
    if counted(common.is_file(), identifier, "bypass_output_common.h is gone"):
        chain = code(common)
        for header in sorted(MODULAR_SHELLS.values()):
            counted(header in chain, identifier,
                    "bypass_output_common.h no longer selects %s" % header)
        counted("no pin map selected for this target" in chain, identifier,
                "bypass_output_common.h no longer refuses an unselected target; "
                "an unmatched build would take whichever map is left")


@row("entry-point-per-shell",
     "every shell owns its main loop. The transaction between the tick, the "
     "debounce step and the output actuation is where each core's timing "
     "argument lives, and the five arguments are made on different cores, "
     "different compilers and different tick sources. A shared loop would make "
     "one argument answer for five sets of measurements")
def each_shell_owns_its_entry_point():
    identifier = "entry-point-per-shell"
    for shell in ALL_SHELLS:
        path = SRC / shell
        if not counted(path.is_file(), identifier, "%s is gone" % shell):
            continue
        counted(len(MAIN_RE.findall(code(path))) == 1, identifier,
                "%s does not define exactly one main(void)" % shell)

    # And nothing else in src/ defines one, which is what a fold would look
    # like: a shared loop translation unit the shells call into.
    for path in sorted(SRC.iterdir()):
        if path.name in ALL_SHELLS or path.suffix not in C_FAMILY:
            continue
        counted(not MAIN_RE.search(code(path)), identifier,
                "%s defines main(void); the loop has been lifted out of the "
                "shells into shared code" % path.name)


@row("two-loop-shapes",
     "the AVR shells are interrupt-driven and the PIC shells are polled. Those "
     "are two different answers to when the debounce step runs, and they fail "
     "differently: the interrupt shells carry an ISR duty term in the watchdog "
     "bound and an atomic hand-off the polled shells have no need of. "
     "Converging them would leave one execution model to be right about both")
def the_two_loop_shapes_remain_two():
    identifier = "two-loop-shapes"
    vectors = {}
    for shell in INTERRUPT_DRIVEN_SHELLS:
        path = SRC / shell
        if not counted(path.is_file(), identifier, "%s is gone" % shell):
            continue
        found = ISR_RE.findall(code(path))
        if not counted(len(found) == 1, identifier,
                       "%s defines %d interrupt handlers, expected exactly one"
                       % (shell, len(found))):
            continue
        vectors[shell] = found[0]

    # Different vector names because they are different peripherals on different
    # core generations: the moment both shells name one vector, one of them is
    # no longer being compiled for its own part.
    counted(len(set(vectors.values())) == len(vectors), identifier,
            "the interrupt-driven shells now share a vector name (%s)"
            % ", ".join("%s=%s" % item for item in sorted(vectors.items())))

    for shell in POLLED_SHELLS:
        path = SRC / shell
        if not counted(path.is_file(), identifier, "%s is gone" % shell):
            continue
        source = code(path)
        found = ISR_RE.findall(source)
        counted(not found, identifier,
                "%s defines an interrupt handler (%s); it is a polled shell, "
                "and its watchdog bound is computed with an ISR duty of zero"
                % (shell, ", ".join(found)))
        counted("__interrupt" not in source, identifier,
                "%s declares an XC8 interrupt handler; see above" % shell)


@row("clock-only-from-the-build",
     "the clock is stated by the build flags and re-derived by a guard inside "
     "the firmware. Two statements that CAN disagree is the whole point: a "
     "build reconfigured to another frequency fails to compile instead of "
     "shipping a tick that is quietly wrong. A firmware-side default would "
     "make the pair agree by construction and prove nothing")
def the_clock_is_never_defined_by_the_firmware():
    identifier = "clock-only-from-the-build"
    for path in sorted(SRC.iterdir()):
        if path.suffix not in C_FAMILY:
            continue
        source = code(path)
        for macro in ("F_CPU", "_XTAL_FREQ"):
            counted(not defines(source, macro), identifier,
                    "%s defines %s; the firmware must only ever TEST the "
                    "build's clock, never supply one" % (path.name, macro))

    for shell, macro in sorted(SHELL_CLOCK.items()):
        path = SRC / shell
        if not path.is_file():
            continue
        source = code(path)
        guard = re.search(r"static_assert[ \t]*\([^;]*\b%s\b" % re.escape(macro),
                          source, re.DOTALL)
        counted(guard is not None, identifier,
                "%s no longer asserts anything about %s, so a build that "
                "changed the clock would compile" % (shell, macro))

    # The other end of the same pair: the build is required to state it at all.
    config = SRC / "bypass_config.h"
    if counted(config.is_file(), identifier, "bypass_config.h is gone"):
        counted("F_CPU must be defined via build flags" in code(config), identifier,
                "bypass_config.h no longer rejects a build that omits F_CPU")


@row("pic-harness-pin-facts-are-literal",
     "the PIC simulator harnesses write their register addresses, names and "
     "expected port states as literals read from the datasheet and the "
     "schematic. They are the independent opinion the firmware's own pin map "
     "is checked against. Sourcing them from that map would move firmware and "
     "expectation together under a re-pin, and gpsim would confirm the "
     "firmware against itself")
def pic_harnesses_do_not_read_the_firmware_map():
    identifier = "pic-harness-pin-facts-are-literal"
    firmware_maps = {path.name for path in SRC.glob("bypass_pins_*.h")}
    firmware_maps.add("bypass_output_common.h")
    allowed = set(FIRMWARE_COMPILING_HARNESSES)

    parts = {name for name in firmware_maps if name.startswith("bypass_pins_")}
    seen_allowed = set()
    global HARNESSES_SCANNED
    for path in sorted(TEST.rglob("*")):
        if path.suffix not in C_FAMILY or not path.is_file():
            continue
        HARNESSES_SCANNED += 1
        relative = path.relative_to(ROOT).as_posix()
        included = set(quoted_includes(code(path)))

        # Direct inclusion of one part's map is never right anywhere in the test
        # tree, recorded exceptions included: those four reach it through the
        # selection chain, on the same -D the firmware build passes.
        direct = sorted(included & parts)
        counted(not direct, identifier,
                "%s includes %s directly, bypassing the selection chain the "
                "firmware itself is subject to" % (relative, ", ".join(direct)))

        reached = sorted(included & firmware_maps)
        if reached and relative in allowed:
            seen_allowed.add(relative)
            continue
        counted(not reached, identifier,
                "%s includes %s. If it compiles production code on the host, "
                "add it to FIRMWARE_COMPILING_HARNESSES and say so; if it "
                "states an expectation, the expectation has stopped being "
                "independent" % (relative, ", ".join(reached)))

    stale = sorted(allowed - seen_allowed)
    counted(not stale, identifier,
            "%s no longer reaches a firmware pin map; the recorded exception is "
            "stale and should be removed rather than left standing"
            % ", ".join(stale))


@row("two-pic-return-stack-witnesses",
     "the PIC14 hardware return stack wraps silently: no stack pointer, no "
     "overflow reset, nothing a running program can observe. The bound is "
     "therefore only as good as the static analysis, so it is made twice -- "
     "once over the compiler's own generated assembly, once over the shipped "
     "HEX by a decoder that trusts nothing the compiler said. Either one alone "
     "is a single point of failure on a fault that cannot be caught at runtime")
def both_stack_witnesses_remain():
    identifier = "two-pic-return-stack-witnesses"
    makefile = MAKEFILE.read_text(encoding="utf-8") if MAKEFILE.is_file() else ""
    for reads, relative, expected, forbidden in STACK_WITNESSES:
        path = ROOT / relative
        if not counted(path.is_file(), identifier,
                       "%s, the witness over %s, is gone" % (relative, reads)):
            continue
        text = path.read_text(encoding="utf-8")
        counted(expected in text, identifier,
                "%s no longer names %s as its input; it was the witness over %s"
                % (relative, expected, reads))
        for other in forbidden:
            counted(other not in text, identifier,
                    "%s now handles %s. The two witnesses are independent "
                    "because they read different artifacts; one that reads both "
                    "is one witness" % (relative, other))
        counted(relative in makefile, identifier,
                "the Makefile no longer runs %s; an unwired witness is an "
                "absent one" % relative)


@row("verification-layers-remain-distinct",
     "exhaustive BFS, two symbolic engines, bounded model checking, mutation, "
     "coverage, two instruction simulators and hardware qualification reach "
     "the same firmware over different substrates, and each is wrong in its "
     "own way. Retiring one because another 'already covers it' trades a "
     "class of escape for a shorter run")
def every_verification_layer_is_still_wired():
    identifier = "verification-layers-remain-distinct"
    makefile = MAKEFILE.read_text(encoding="utf-8") if MAKEFILE.is_file() else ""
    if not counted(bool(makefile), identifier, "the Makefile is gone"):
        return

    artifacts, targets = {}, {}
    for layer, relative, target in VERIFICATION_LAYERS:
        counted((ROOT / relative).is_file(), identifier,
                "the %s layer's %s is gone" % (layer, relative))
        counted(re.search(r"^%s:" % re.escape(target), makefile, re.MULTILINE) is not None,
                identifier,
                "the Makefile no longer defines %s, the %s layer's target"
                % (target, layer))
        counted(relative in makefile, identifier,
                "the Makefile no longer references %s, so the %s layer runs "
                "against nothing" % (relative, layer))
        artifacts.setdefault(relative, []).append(layer)
        targets.setdefault(target, []).append(layer)

    for relative, sharing in sorted(artifacts.items()):
        counted(len(sharing) == 1, identifier,
                "%s is now the subject of %s; two layers sharing one subject "
                "are one layer" % (relative, " and ".join(sharing)))
    for target, sharing in sorted(targets.items()):
        counted(len(sharing) == 1, identifier,
                "%s now serves %s" % (target, " and ".join(sharing)))


@row("release-identity-pin-is-literal",
     "which images a release contains is decided twice: once by the live build "
     "variables that compose RELEASE_IMAGES, and once by a table of reviewed "
     "literals no channel can reach. The pin is a second opinion only while it "
     "stays literal. Composed instead from FW_BASE, the per-part MCU tags or "
     "the supported-variant sets, it would move with the thing it exists to "
     "check: the two sets would agree by construction, every comparison would "
     "still pass, and a release built under a moved name would stage and "
     "publish a complete, self-consistent set of images nobody had reviewed")
def the_release_identity_pin_is_still_literal():
    identifier = "release-identity-pin-is-literal"
    makefile = MAKEFILE.read_text(encoding="utf-8") if MAKEFILE.is_file() else ""
    if not counted(bool(makefile), identifier, "the Makefile is gone"):
        return

    # That no CHANNEL can move the pin is held by test_release_images.sh, which
    # re-reads each name under a command-line and an environment override. This
    # is the other way to lose it: an edit, in the file itself, that leaves
    # every one of those checks passing.
    for name, allowed in RELEASE_IDENTITY_PINS:
        definition = make_definition(makefile, name)
        if not counted(definition is not None, identifier,
                       "the Makefile no longer defines %s as an `override`; the "
                       "pin the live release identity is compared against is "
                       "gone or reachable" % name):
            continue
        borrowed = sorted(set(MAKE_REFERENCE.findall(definition)) - allowed)
        counted(not borrowed, identifier,
                "%s is now composed from %s. A pin that reads a build variable "
                "moves with it and agrees with the identity it exists to check"
                % (name, ", ".join(borrowed)))

    # The other half of the pair. The selected side must keep reading the LIVE
    # value of each pinned name; two literal tables cannot disagree, and the
    # build the comparison exists to police would go unchecked.
    selected = make_definition(makefile, "RELEASE_IDENTITY_SELECTED")
    if counted(selected is not None, identifier,
               "the Makefile no longer defines RELEASE_IDENTITY_SELECTED, the "
               "live half of the comparison"):
        counted("$($(n))" in selected, identifier,
                "RELEASE_IDENTITY_SELECTED no longer reads each pinned name out "
                "of the live Makefile, so the pin is compared against itself")


def main():
    for _, _, check in REGISTER:
        check()

    if FAILURES:
        opinions = dict((identifier, opinion) for identifier, opinion, _ in REGISTER)
        print("FAIL: deliberate duplication has been consolidated away.",
              file=sys.stderr)
        for identifier in sorted(set(name for name, _ in FAILURES)):
            print("\n  %s" % identifier, file=sys.stderr)
            print("    the independent opinion at stake: %s"
                  % opinions[identifier], file=sys.stderr)
            for name, witness in FAILURES:
                if name == identifier:
                    print("    - %s" % witness, file=sys.stderr)
        print("\nRemoving a duplication listed here is allowed, and is a "
              "deliberate act:\nsay which opinion replaces the one being "
              "retired, then edit this register.", file=sys.stderr)
        raise SystemExit(1)

    print("deliberate duplication register: %d checks, 0 failures "
          "(%d duplications, %d MCU shells, %d pin maps, %d verification layers, "
          "%d harness translation units)"
          % (checks, len(REGISTER), len(ALL_SHELLS), len(MODULAR_SHELLS),
             len(VERIFICATION_LAYERS), HARNESSES_SCANNED))


if __name__ == "__main__":
    main()
