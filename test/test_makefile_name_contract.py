#!/usr/bin/env python3
"""The Makefile name contract: every name another file hands to, or asks of, the
Makefile must be a name the Makefile actually knows.

THE DEFECT CLASS is silent severance. A rename moves a name; the files and
documents still speaking the old one keep running, quietly, wrongly. Make
reports nothing in any of the four directions this checks:

  Axis A -- `make print-VAR`     a file READS a variable
  Axis B -- `make <goal>`        a document names a GOAL to a reader
  Axis C -- `make VAR=value`     a file SETS a variable
  Axis D -- "set PIC320_TAG"     a document names a VARIABLE to a reader
  Axis E -- `NAME=v ./child.sh`  the Makefile sets a child's ENVIRONMENT

A, C and E are machine-facing and fail silently; B and D are human-facing, and
their consumer is a person following instructions. B is the only one of the five
whose failure is loud when it happens -- `No rule to make target` -- which is
precisely why it must be caught before the reader is the one who finds it.

THE ORACLES. For variables, `make origins NAMES="..."` reports $(origin) per
name in one invocation. Non-emptiness is NOT usable:
XT_SOAK_COMBINATION_NAME and AVR_STACK_BUILD_DIR are defined-but-empty by
design, so only $(origin) separates "never defined" (undefined) from
"deliberately empty" (file).

================================ AXIS C ================================

A make override that names no existing variable is legal and silent.
`make test-soak SOAK_DURATION_MS=2000` defines a make variable called
SOAK_DURATION_MS; if the recipe reads $(AVR_SOAK_DURATION_MS), the override is
inert and the default applies, with no error and no diagnostic. In v0.9.8 that
left the classic-AVR WDT mutant asking for 2 s of simulated soak and silently
getting the 24 h default -- 43,200x. A local run sat in that one mutant for over
ten hours before it was killed by hand; both CI jobs reaching the row declared no
timeout and would have been cancelled at GitHub's six-hour limit having reported
nothing. Four separate guards missed it, each for a different reason.

WHERE OVERRIDES LIVE -- four sources, and the last two are the ones that matter.

  1. Lines invoking make, in EVERY file in the tree -- tracked, plus untracked
     and not ignored (see repo_files) -- shell, YAML, and documents.
     Backslash continuations are joined FIRST. This is not optional: in
     test/test_avr_build_rebuild.sh the `make` sits on one line and its
     overrides five continued lines below, and there are ZERO physical lines in
     this repo containing both `make` and `MCU=`. A physical-line harvest -- the
     first version of this sweep -- reported those three inert overrides as
     clean.

  2. The Makefile's own comments, because a comment recommending a dead override
     is how a person is told to do the thing that silently does nothing. Until
     v0.9.8 the soak override block recommended exactly the spelling that had
     just broken the harness.

  3. THE MUTATION TABLES in test/run_mutation_tests.sh, whose third
     tab-separated field is a make command line stored as DATA. These rows
     contain no `make` token at all, so sources 1 and 2 cannot see them -- and
     the v0.9.8 defect above was in one of these rows. A gate scoped to
     "lines invoking make" would not have caught the defect it exists to
     prevent. That is the whole reason this source is enumerated separately.

  4. DOCUMENTS, folded into source 1 on 2026-08-03. This axis originally
     harvested test/, scripts/, .github/ and the Makefile -- the scope where the
     machine-facing overrides live -- which left the human-facing half of the
     same defect unchecked by any of the four axes. MISRA_COMPLIANCE.md tells a
     maintainer to run `make analyze-misra VARIANTS="..." STRICT_TOOLS=1`;
     README.md documents `make attiny202-program VARIANT=<v>`. Axis D reads doc
     prose but only for names inside the project's variable PREFIXES, and
     VARIANTS, VARIANT, STRICT_TOOLS, VERSION and PIC10F322_PROG are all
     unprefixed, so nine names were reachable by no axis at all. Anchoring on
     the make word -- which this axis already did -- is what let the scope widen
     without needing a vocabulary list to keep the false-positive rate down.

SCOPE, stated so the next reader does not over-trust it: axis C checks names
passed to make. It does not check a variable a document merely MENTIONS without
handing it to make (that is axis D, and only within its prefix vocabulary), and
it cannot know that a name reaching make is meant for make rather than for a
script reading the environment -- hence ENV_ALLOWLIST below, which must stay
short and justified.

================================ AXIS A ================================

`print-%` is a pattern rule (`print-%: ; @echo '$($*)'`), so it matches ANY
name. Ask it for a variable that no longer exists and it prints an empty line
and exits 0 -- there is no such thing as an unknown variable to ask about.

That is not hypothetical. The v0.9.8 rename left three reads in
scripts/make-release.sh pointed at removed names (MCU, LFUSE_X5, HFUSE_X5).
Nothing failed anywhere in the suite. The effect would have surfaced only in the
published artifact, at the END of a 24-hour release run: a MANIFEST.md with
empty ATtiny13a and tinyx5 fuse bytes, and one image path composed as
`bypass--<stage>.hex`. `make test` cannot catch that by running, because it
never executes the release script's variable preamble -- so the check has to be
textual, which is what this is.

TWO SPELLINGS, and a harvest that knows only the first is worth little here,
because the defect above was in the second:

  1. `make -s print-NAME`, direct.
  2. `mkv NAME`, scripts/make-release.sh's one-line wrapper
     (`mkv() { make -s --no-print-directory print-"$1"; }`). The name arrives
     as a bare word, so nothing about it looks like a Makefile query.

DELIBERATELY NOT ANCHORED ON THE MAKE WORD, unlike axis C. `print-` with the
lookbehind below is already unambiguous in this tree -- every non-query form
(`--no-print-directory`, `-print-file-name`, `--print-data-base`,
`--print-targets`) has a hyphen immediately before `print`. Requiring `make` on
the same line would instead LOSE real reads: test_workload_rebuild.sh:255 goes
through a `run_make` wrapper (no bare `make` token), and ci-local.sh:368 spreads
eight queries across a backslash continuation. A harvest that silently stops
seeing real sites is the exact failure this item exists to catch.

STRICTER CONTRACT THAN AXIS C: a read must be DEFINED, not merely "defined or
consumed". A command-line-only input such as VERSION is legitimate to SET but
useless to ASK FOR -- `make -s print-VERSION` prints an empty line, which is
precisely the severance symptom. The two axes want different oracles and get
them.

================================ AXIS B ================================

A document naming a goal that no longer exists sends a reader to `No rule to
make target`. The v0.9.8 prefix rename left 15 of these in
docs/pic10f320_validation.md alone -- a document framed as CURRENT qualification
evidence -- including its entire "Reproducing any of this" section, where four
of six commands failed.

THE ORACLE is `make -rRn --print-data-base`, parsed once. Reading make's own
inventory rather than grepping rule heads is what makes the generated families
resolvable: `attiny85-program` and `test-sim-cd4053_simple-attiny13a` exist only
after `$(eval $(call ...))` expansion, so a textual harvest would report every
correct use of them as missing.

PRECISION IS THE WHOLE PROBLEM, and it is a bigger one than any other axis
faces. English follows the word "make" constantly -- "make sure", "make the",
"make a" -- so a harvest that reads any line containing `make` reports English
words as missing goals. Measured on this tree: 881 distinct tokens, of which
about a dozen were real. Three rules bring that to zero false positives:

  1. Only COMMAND contexts are read (see code_fragments): fenced blocks and
     backtick spans in documentation, command lines in code, backtick spans in
     comments. A sentence is not a command.
  2. The make word must OPEN its fragment. `sudo apt-get install -y make ...`
     installs a package; it does not invoke one.
  3. Only the FIRST goal word is taken, because what follows a documented goal
     is very often prose -- an aligned `# what this builds` comment, or a
     sentence continuing past a closing backtick.

Rule 3 is a real ceiling and is stated rather than hidden: `make clean test`
checks only `clean`. So is the harvest's blindness to a goal named in running
prose without the word `make` in front of it.

GOAL SCHEMAS are resolved, not skipped. `make test-sim-<variant>` expands over
$(VARIANTS) and every expansion must exist. That is the check that catches the
sharpest v0.9.8 casualty: test/README.md named exactly that form, which has no
rule at all -- the goal carries an MCU field, `test-sim-<variant>-attiny13a`,
and the missing field is the very defect the rename existed to kill. A
placeholder with no mapping FAILS; skipping it silently is how that one survived
in a live document.

================================ AXIS D ================================

The variable-side twin of axis B, and the one with no machine consequence at
all: make accepts an assignment to a name it does not know and ignores it, so a
reader who follows a stale instruction gets no error whatsoever. Ten such
surfaces survived v0.9.8, two of them telling a reader to type a removed name.
The worst was the `test-flash-budget` guard's own failure message, which told a
user who had already tripped it to pass `MCU=attiny13a` while the guard read
$(ATTINY13A_MCU) -- advice that changes nothing, delivered at the moment someone
is confused and trusts it completely.

SCOPE: prose only -- documentation, and comments in code. A variable name in
executable code is not a claim about the Makefile; it is a shell local or a C
macro, and this tree has hundreds sharing the project's prefixes (SOAK_PIDS,
MUTATION_MAKE, RELEASE_THRESH). Reading code lines reported 154 of them as
severed.

FAMILY REFERENCES ARE CHECKED AS PREFIXES. `PIC320_*` asks whether ANY known
variable begins with `PIC320_`. Testing the stem as a whole name -- which is
what the specification proposed -- reports `AVR_SOAK_*` and `XT_FUSE_*` as
severed, because no variable is literally called AVR_SOAK. The family shape is
also the one that carried the worst surface: README.md's "the PIC10F320 lane
uses PIC320_* variables".

================================ AXIS E ================================

The other end of axis C, and the only axis here with a defect already behind it.
Axis C harvests `NAME=value` only where it FOLLOWS the make word, which is
right: an assignment BEFORE a command is environment for that command's child,
not a claim about the Makefile's vocabulary. Nothing then checked the far end.
Rename the child's read, leave the parent's write, and the assignment becomes
legal, silent and inert -- the child falls back to its own in-source default.
`test/pic/gpsim_wrapper_common.sh` had its PIC_GPSIM_PROC read re-spelled for
one part while all four Makefile writers kept the old name, so
`make pic10f320-test-gpsim` ran the 256-word part's image on a p10f322 device
model and reported `RESULT: PASS` for an entire release.

THE CHECK is per LINK, not per name: every `NAME=value <child>` site must reach
a file that reads NAME. Per-name is measurably too weak -- ATTINY202_FUSE_WDTCFG
is written at five sites, and the one pointing at the fuse reader's own unit
test (which names it literally) would cover the four real consumers being
severed at once.

THE READER SEARCH IS TRANSITIVE, which is required rather than a refinement: a
direct-read check reports two CORRECT channels as severed. AWK is written for a
wrapper whose read lives in the gate it runs; BYPASS_MODEL_FFI is written for a
Python driver whose read lives in a module it imports. A child inherits the
environment, so the reader is anywhere downstream.

TWO SHAPES THE OBVIOUS IMPLEMENTATION MISSES, both live here. A channel can be
hidden behind a make variable -- `$(XT_FUSE_ENV)` expands to seven
ATTINY202_FUSE_* assignments that appear nowhere in the recipe text. And a
reader can BUILD the name instead of writing it: attiny202_fuses.py computes
`"ATTINY202_FUSE_" + name` over a table, so no literal spelling of any of the
seven exists in the file that reads them. Both are resolved; the computed reads
are counted separately rather than blessed.

SCOPE: Makefile recipe prefixes. Shell scripts write 14 prefixes between them,
dominated by shell built-ins that happen to be uppercase (IFS, colour codes), so
a second discrimination pass does not pay -- and Makefile-to-script is where the
defect was. The reverse direction (a script reading a name nothing sets) is
deliberately NOT bundled: a script legitimately reads names an operator sets by
hand. A channel whose consumer cannot be resolved FAILS rather than being
skipped, because a skipped check that reports as a pass is this gate's own
defect class; the two genuine external consumers are listed in
EXTERNAL_CONSUMERS with their reasons and expire like every other exemption.

======================== EXEMPTIONS, ALL AXES =========================

Live documents legitimately name a retired goal or variable: an old-to-new
redirect table, a recipe pinned to a tag where the name is still correct, a
quoted transcript, a sentence whose whole point is that a name is gone. None of
that is inferable from the text and none is a property of a whole FILE, so it is
written down per line or per block (`name-contract: exempt`). Four file-level
exemptions exist and each is justified where it is defined: published release
artifacts, self-declared historical documents, CHANGELOG.md, and this file.

Every exemption -- marker, allowlist entry, computed-name mapping -- must still
suppress something, or the gate fails. Exemptions expire; a marker left over
clean text silently covers the next dead name written under it.
"""

import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# This gate's own source, excluded from both harvests.
#
# It quotes severed names deliberately and has to: the docstrings name the exact
# variables v0.9.8 removed (SOAK_DURATION_MS, MCU, LFUSE_X5), they write the
# schema `make VAR=value`, and the negative-case fixtures below construct
# `make foo \ BAR=1` and `print-VAR` on purpose. Every one is an EXAMPLE of the
# defect, so a gate that checked its own prose could not document what it
# checks. This surfaced the moment the file was first committed -- until then
# `git ls-files` did not list it, and the exemption was accidental rather than
# stated. That accident is now impossible: the harvest reads the working tree
# rather than the index (see repo_files), so a file is in scope from the moment
# it exists. This exemption is the one that had to be WRITTEN, and it is.
#
# Cost, stated plainly rather than glossed: the one real override this file
# passes to make (`NAMES=`, to the `origins` rule) goes unchecked by axis C.
# That name is exercised on every single run instead -- `make origins` fails
# loudly if it stops existing -- which is a stronger guarantee than a textual
# check, so nothing is actually lost.
SELF_EXEMPT = "test/test_makefile_name_contract.py"

# Names that legitimately travel to a child process's ENVIRONMENT through a make
# command line, and are read by a script rather than by the Makefile. Nothing in
# the Makefile can infer these, so they are listed. Keep this short: every entry
# is a name this gate cannot check, so a wrong one is a permanent blind spot.
# It has exactly one member, and that is a result rather than a coincidence.
# The prototype sweep recorded in TODO.md needed at least seven, all of them
# fake-tool shim parameters (FAKE_CC_LOG, FAKE_OBJCOPY_LOG, ...) plus the env
# set handed to make-release.sh. Harvesting only what follows the make word
# retires every one of them: they are environment prefixes, so they were never
# claims about the Makefile's vocabulary in the first place. The allowlist got
# shorter by fixing the harvest rather than by growing exemptions, which is the
# direction it should always move.
#
# MUTATION_ALLOW_SKIP survives because it genuinely is passed after the make
# word (`make test-long MUTATION_ALLOW_SKIP=1`). Make exports command-line
# variables to recipe child processes, so it reaches test/mutation_policy.sh
# through the environment; the Makefile itself neither defines nor reads it
# (verified: zero occurrences). Nothing in the Makefile can infer that.
ENV_ALLOWLIST = {
    "MUTATION_ALLOW_SKIP",
}

# A make command word: bare `make`, or a $(MAKE)/$MUTATION_MAKE style reference.
# The boundaries matter more than they look. `make-release.sh` must NOT count as
# a make invocation -- it is a shell script whose name merely starts with
# "make", and treating it as one drags in every NAME= on the same line
# (RELEASE=, REPO_URL=, EXPECTED_LOCK=, LOCK_ATTEMPT=, REAL_FLOCK=). That was a
# real false-positive class in the prototype sweep.
MAKE_WORD = re.compile(
    r"(?<![-\w./])make(?![-\w./])"          # bare `make`, not make-release.sh
    r"|\$[({]?[A-Z_]*MAKE[)}]?"             # $(MAKE), $MUTATION_MAKE, ${MAKE}
)

# NAME=  -- the lookbehind rejects `-DNAME=` (a compiler macro, deliberately NOT
# renamed alongside the make variables) and `$NAME=`.
ASSIGN = re.compile(r"(?<![-\w./$])([A-Za-z_][A-Za-z0-9_]*)=")

# A mutation table row: a quoted string of >=4 tab-separated fields whose third
# field is the make command.
MUTATION_ROW = re.compile(r'^"([^"]*)"')


# An assignment whose VALUE opens a command substitution -- `X="$(cmd)"`,
# X=`cmd`. The substitution's body is a command in its own right, so a make word
# inside it belongs to THAT command and not to the line it sits on. Splitting on
# it is what separates
#
#     REAL_PROJECT_MAKE="$(command -v make)" FAKE_MODE=x "$fake_make" ... BAR=1
#
# into the two claims it actually makes: `command -v make` (a path lookup, no
# overrides at all) and a fake-make invocation carrying BAR. Without the split
# the harvest anchors on the `make` inside the lookup, and every environment
# prefix AFTER it reads as an override -- which is exactly the false-positive
# class assignments_passed_to_make() exists to avoid, arriving through the value
# position instead of the prefix position. It reported 27 fake-tool shim
# parameters (FAKE_*, MATRIX_*, LM_*, TM_*) as severed overrides the day the
# PIC12F675 matrix gates started resolving the real make binary that way.
#
# The body is HARVESTED, not discarded: `XT_N=$(make -s print-X VAR=1)` passes
# VAR to make, and a substitution is where several real invocations in this tree
# live (scripts/ci-local.sh, test/test_release_images.sh). Dropping it would
# trade a false positive for a blind spot.
#
# COST, stated rather than glossed. Those shim invocations carry real overrides
# (MAKE=, PROJECT_MAKE=, PIC12F675_BUILD_DIR=, STRICT_TOOLS=) and their command
# word is a shell variable -- `"$fake_make"` -- so once the lookup no longer
# anchors the line, nothing in it is a make word and the site contributes
# nothing to this axis. Every name involved is still harvested from ordinary
# `make ...` sites except MAKE and PROJECT_MAKE, which leave the harvest
# entirely. Widening MAKE_WORD to accept a lowercase `$..._make` command word
# recovers both, and costs four NEW false positives -- MUTATION_MAKE_LOG,
# PIC_BASELINE_STALE_HEX, PIC_GPSIM_SELFTEST_LOG and TOOL_LOG, all environment
# prefixes -- which is an allowlist of four names this gate would then never
# check again. Two names checked from one fewer place is the better trade.
SUBST_VALUE = re.compile(r"(?<![-\w./$])[A-Za-z_][A-Za-z0-9_]*=\"?(\$\(|`)")


def logical_lines(text):
    """Yield (start_line_number, joined_line), joining backslash continuations."""
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        start = i
        buf = lines[i]
        while buf.rstrip().endswith("\\") and i + 1 < len(lines):
            i += 1
            buf = buf.rstrip()[:-1] + " " + lines[i]
        yield start + 1, buf
        i += 1


def assignments_in(fragment):
    """NAME= tokens in a fragment, minus shell locals capturing command output.

    `XT_N=$(make -s print-...)`, `REAL_MAKE=$(command -v make)` and
    `MUTATION_MAKE="${MUTATION_MAKE:-make}"` are shell variables assigned FROM a
    command or a parameter expansion, not overrides passed TO one. They are
    distinguished by their value opening a substitution.
    """
    out = []
    for m in ASSIGN.finditer(fragment):
        after = fragment[m.end():m.end() + 3]
        if after.startswith(("$(", "`", '"${', "${", '"$(')):
            continue
        out.append(m.group(1))
    return out


def command_contexts(line):
    """Yield each shell command context in `line` separately.

    The first yield is the line at its own level, with the body of every
    assignment-value substitution replaced by an empty one; each such body then
    follows as a context of its own, recursively. A make word is thereby scoped
    to the command it actually belongs to.

    The emptied substitution keeps its `$(` and `)`, so assignments_in() still
    sees the assignment as one whose value opens a substitution and skips it --
    `make foo BAR=$(shell ...)` must stay unharvested, exactly as before.
    """
    kept, bodies, i = [], [], 0
    while True:
        m = SUBST_VALUE.search(line, i)
        if not m:
            kept.append(line[i:])
            break
        start = m.end()
        if m.group(1) == "`":
            end = line.find("`", start)
            if end == -1:
                end = len(line)
        else:
            depth, end = 1, start
            while end < len(line):
                if line[end] == "(":
                    depth += 1
                elif line[end] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                end += 1
        kept.append(line[i:start])
        bodies.append(line[start:end])
        i = end
    yield "".join(kept)
    for body in bodies:
        yield from command_contexts(body)


def assignments_passed_to_make(line):
    """NAME= tokens that reach make as OVERRIDES, i.e. after the make word.

    Position is what separates the two meanings, and it is not a nicety:

        FAKE_CC_LOG=x make foo BAR=1

    BAR is a make override -- make defines a variable called BAR. FAKE_CC_LOG is
    an ENVIRONMENT assignment for make's child processes, read here by a fake
    compiler shim on PATH; the Makefile neither defines nor wants it. Harvesting
    the prefix position would report every fake-tool parameter in the rebuild
    gates as a severed override and force a long allowlist of names this gate
    then could not check at all.

    So: only what follows the make word is a claim about the Makefile's
    vocabulary.

    Per COMMAND CONTEXT, not per line: a `make` inside an assignment's value is
    that value's command, and the prefixes around it belong to a different one.
    See command_contexts() above.
    """
    out = []
    for context in command_contexts(line):
        out.extend(overrides_in_command(context))
    return out


def overrides_in_command(line):
    """The override half of assignments_passed_to_make(), for ONE command
    context -- i.e. with no substitution body left to anchor on by mistake."""
    m = MAKE_WORD.search(line)
    if not m:
        return []
    tail = line[m.end():]
    # Overrides are ARGUMENTS to make, so they end where the make command does.
    # Anything past a shell separator or redirection belongs to a different
    # statement -- `make ... >/dev/null 2>&1; rc=$?` assigns a shell local, and
    # `$(MAKE) ... || { rc=1; break; }` assigns one in a failure branch. Both
    # read as overrides without this, and both are lowercase shell variables the
    # Makefile has never heard of, so they would be reported as severed forever.
    tail = re.split(r"[;|&<>]|\|\||&&", tail, maxsplit=1)[0]
    return assignments_in(tail)


def harvest():
    """Return ({name: [locations]}, used_markers, all_markers) for every NAME=
    handed to make.

    SCOPED TO EVERY TRACKED FILE, like axes A, B and D, and NOT to test/,
    scripts/, .github/ and the Makefile as it was when axis C was first built.
    That original scope was inherited from where the *machine-facing* overrides
    live, and it left a real hole: a document telling a reader to run

        make analyze-misra VARIANTS="cd4053_simple ..." STRICT_TOOLS=1

    makes exactly the same claim about the Makefile's vocabulary that a script
    does, and the reader who follows it gets an inert override and no error --
    the human-facing half of the same defect. Axis D covers doc prose but only
    for names inside the project's variable PREFIXES, so `VARIANTS`,
    `STRICT_TOOLS`, `VERSION` and every other unprefixed name were checked by
    nothing at all. Anchoring on the make word, as this axis already does, keeps
    the precision that lets the scope widen without a vocabulary list.
    """
    found = {}
    used_markers, all_markers = set(), {}

    def record(name, where):
        found.setdefault(name, []).append(where)

    for rel, text in harvestable_files():
        exempt, markers = exemptions(text)
        for line in markers:
            all_markers[(rel, line)] = markers[line]

        # Sources 1 and 2: anything invoking make, comments included.
        #
        # The Makefile is harvested by PHYSICAL line rather than joined. A
        # recipe is a multi-line shell script, so joining its continuations
        # turns the whole body into one "line invoking make" and every shell
        # local in it (rc=, marker=, target=) reads as an override. Shell and
        # YAML files are joined, because there a continued line genuinely is one
        # command -- which is the case that hid three inert overrides in v0.9.8.
        is_makefile = rel == "Makefile"
        is_doc = rel.endswith((".md", ".adoc"))
        lines = ([(i, l) for i, l in enumerate(text.split("\n"), 1)]
                 if is_makefile else logical_lines(text))
        for lineno, line in lines:
            # Comments are harvested in the MAKEFILE only. That is where an
            # override is documented to a reader -- `# Override: make
            # test-flash-budget ATTINY13A_FLASH_BUDGET=80` -- so a stale one
            # there actively misinstructs, which is the axis-D failure that hit
            # the SOAK_* block in v0.9.8. A shell or YAML comment is ordinary
            # prose: run_mutation_tests.sh documents its dispatch as "make
            # target (kind=make)", where `kind=` is a description of a variable
            # in that script, not an override anyone is being told to pass.
            # Harvesting those trades a real check for recurring false
            # positives on generic words.
            # ...and in documents, where every line is prose addressed to a
            # reader and a leading `#` is a heading rather than a comment.
            if not is_makefile and not is_doc and line.lstrip().startswith("#"):
                continue
            for name in assignments_passed_to_make(line):
                if lineno in exempt:
                    used_markers.add((rel, exempt[lineno]))
                    continue
                record(name, f"{rel}:{lineno}")

        # Source 3: mutation table rows, whose 3rd field is a make command.
        if rel == "test/run_mutation_tests.sh":
            for lineno, line in enumerate(text.split("\n"), 1):
                m = MUTATION_ROW.match(line)
                if not m:
                    continue
                fields = m.group(1).split("\t")
                if len(fields) < 4:
                    continue
                for name in assignments_in(fields[2]):
                    record(name, f"{rel}:{lineno} (mutation row)")

    return found, used_markers, all_markers


def dereferenced_names():
    """Names the Makefile READS, i.e. $(NAME) or ${NAME} anywhere in it.

    $(origin) reports a command-line-only input as `undefined`, because it is
    genuinely never defined in the file -- it is *consumed*. `make release
    VERSION=v1.0.0` is the documented interface and Makefile:4898 reads
    $(VERSION), but querying origin without supplying it says undefined. Judged
    on origin alone, the Makefile's own usage line would be reported as severed.

    So the contract is: a name must be DEFINED or CONSUMED. A name that is
    neither is what severance actually looks like -- nothing sets it, nothing
    reads it, and the override does nothing at all.
    """
    with open(os.path.join(ROOT, "Makefile"), encoding="utf-8") as fh:
        text = fh.read()
    return set(re.findall(r"\$[({]([A-Za-z_][A-Za-z0-9_]*)[)}]", text))


def env_channel_names():
    """Names the Makefile hands a CHILD PROCESS as environment.

    A `NAME=value` prefix on a recipe line defines no make variable, so
    $(origin) and the data base both report it as nothing at all. It is still
    the Makefile SPEAKING that name: it is the channel a shared script reads its
    per-lane configuration through, and the Makefile documents four of them by
    name beside the PIC variables ("the env-var names the shared wrapper scripts
    read ... each lane passes its own part's value through them").

    Axis D needs them, or its only accepted spellings are make-variable names --
    which is pressure toward exactly the rename that broke pic10f320-test-gpsim
    in v0.9.8, where a SHARED wrapper's selector was re-spelled for ONE part.
    Correcting that fix's own prose would have been the alternative, and the
    prose was right.

    Only the PREFIX position, walked word by word and stopped at the first word
    that is not an assignment -- which is what the shell itself does, and what
    keeps `make foo BAR=1` (an override, axis C's subject) and `cc -DBAR=1` (a
    macro, the fuse-injection contract's) out of this set.

    EVERY statement in the recipe, not just its first. A recipe is one logical
    line once continuations are joined, and the interesting prefixes sit deep
    inside a `; `-separated sequence -- the gpsim invocations are the eighth
    statement of theirs. Reading only the head of the joined line finds 44
    channels and misses the one this exists for.

    NOT a claim that the name is read anywhere -- that is axis E, which harvests
    the same recipes through env_channel_writes(). The two are deliberately
    different strengths and must stay that way. This one wants a SUPERSET: a
    name it misses becomes a false severance report on correct prose, so it errs
    toward accepting, and the shell locals it also picks up (`rc`, `fail`, `out`)
    are harmless here because axis D only judges names inside the project's
    variable prefixes. Axis E wants a PRECISE set, because a name it harvests
    wrongly becomes a demand that some file read a shell local.
    """
    names = set()
    with open(os.path.join(ROOT, "Makefile"), encoding="utf-8") as fh:
        text = fh.read()
    word = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=")
    # Words that introduce a command without being one, so an assignment after
    # them is still in prefix position.
    TRANSPARENT = {"export", "env", "then", "do", "else", "{", "("}
    for _, line in logical_lines(text):
        if not line.startswith("\t"):
            continue
        body = line.lstrip("\t").lstrip().lstrip("@-+")
        for statement in re.split(r"[;|&<>]|\|\||&&", body):
            for token in statement.split():
                if token in TRANSPARENT:
                    continue
                m = word.match(token)
                if not m:
                    break
                names.add(m.group(1))
    return names


def origins(names):
    """{name: $(origin name)} via one make invocation."""
    if not names:
        return {}
    # --no-print-directory on every Make call in this file, and -s does NOT
    # imply it: Make enables -w in a sub-make and propagates a literal w through
    # MAKEFLAGS, where it OVERRIDES -s. `make release` reaches this gate through
    # such a sub-make, and the directory banner then reads as DATA -- axis A
    # expanded `mkv part_"$n"` over a TINYX5 carrying "Entering", "directory"
    # and the repo path, and reported those as undefined Makefile variables.
    proc = subprocess.run(
        ["make", "-s", "--no-print-directory", "origins",
         "NAMES=" + " ".join(sorted(names))],
        cwd=ROOT, capture_output=True, text=True,
    )
    if proc.returncode != 0:
        sys.exit("FAIL: `make origins` failed:\n" + proc.stderr.strip())
    result = {}
    for line in proc.stdout.splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2:
            result[parts[0]] = parts[1].strip()
    return result


# ----------------------------------------------------------------- axis A ---

# A `print-<NAME>` query. The lookbehind is the whole discriminator: it rejects
# `--no-print-directory`, `$(CC) -print-file-name=avr/io.h`,
# `make --print-data-base` and `clang --print-targets`, all of which appear in
# this tree and none of which is a Makefile variable query. Every real query has
# whitespace before `print-`, because it is a make GOAL.
PRINT_QUERY = re.compile(r"(?<![-\w])print-([A-Za-z_][A-Za-z0-9_]*)")

# scripts/make-release.sh's wrapper:
# `mkv() { make -s --no-print-directory print-"$1"; }`. Harvested
# tree-wide rather than in that one file, so copying the idiom stays covered.
MKV_QUERY = re.compile(r"(?<![-\w])mkv\s+([A-Za-z_][A-Za-z0-9_]*)")

# A query whose name is built at runtime, e.g. `mkv part_"$n"`, detected by the
# harvested word running straight into a shell expansion. These must be EXPANDED
# and checked, not skipped -- a computed name is no less severable than a
# literal one, and skipping it would be invisible. Each entry maps the constant
# prefix to the Makefile variable supplying its keys; an unrecognised computed
# prefix is a hard failure rather than a silent pass.
COMPUTED_KEYS = {
    "part_": "TINYX5",     # `for n in $TINYX5; do ... $(mkv part_"$n"); done`
}
COMPUTED_TAIL = ('"', "'", "$", "{")

# Documents whose job is to record what names USED to be. A changelog naming a
# removed variable is the changelog working correctly.
#
# Everything else earns its exemption by SELF-DECLARING, so this list stays at
# one entry: a markdown file whose opening banner calls itself historical is
# skipped, which means a new historical document is covered the day it is
# written, and deleting the banner puts the document back under the contract.
# Nine files currently declare themselves this way.
HISTORICAL_FILES = {"CHANGELOG.md"}
HISTORICAL_BANNER = re.compile(r"^\s*(?:>|\*\*Status:\*\*).*\bhistorical\b", re.I)
BANNER_SCAN_LINES = 15


def self_declared_historical(text):
    """True if a markdown file's opening banner calls it a historical record."""
    return any(HISTORICAL_BANNER.search(line)
               for line in text.split("\n")[:BANNER_SCAN_LINES])


def harvest_reads():
    """Return (names, computed_prefixes, per_spelling_counts).

    `names` maps a queried variable name to where it was queried;
    `computed_prefixes` maps the constant part of a runtime-built name to the
    same; `per_spelling_counts` records how many hits each spelling produced, so
    losing one of the two spellings fails loudly.

    Scoped to every file in the tree, not just test/ and scripts/: a published
    document telling a reader to run `make print-RELEASE_IMAGE_DIRS` is making
    the same claim about the Makefile's vocabulary that a script does, and
    release/README.md does exactly that.
    """
    found = {}
    computed = {}
    per_spelling = {"print-<VAR>": 0, "mkv <VAR>": 0}

    for rel, text in harvestable_files():
        is_markdown = rel.endswith(".md")
        for lineno, line in enumerate(text.split("\n"), 1):
            # Comments are skipped in CODE only. A `#` opens a comment in shell
            # and YAML -- test_ci_local_routing.sh documents its fake make shim
            # with "a `make -s print-FOO ...` is a VARIABLE QUERY", where FOO is
            # a placeholder standing for any name, not a claim that FOO exists.
            # In markdown `#` opens a HEADING, so skipping there would blind the
            # gate to a whole class of live documentation.
            if not is_markdown and line.lstrip().startswith("#"):
                continue
            for spelling, pattern in (("print-<VAR>", PRINT_QUERY),
                                      ("mkv <VAR>", MKV_QUERY)):
                for m in pattern.finditer(line):
                    where = f"{rel}:{lineno}"
                    per_spelling[spelling] += 1
                    if line[m.end():m.end() + 1] in COMPUTED_TAIL:
                        computed.setdefault(m.group(1), []).append(where)
                    else:
                        found.setdefault(m.group(1), []).append(where)

    return found, computed, per_spelling


def print_values(name):
    """`make -s print-<name>`, split into words."""
    proc = subprocess.run(
        ["make", "-s", "--no-print-directory", "print-" + name],
        cwd=ROOT, capture_output=True, text=True,
    )
    if proc.returncode != 0:
        sys.exit(f"FAIL: `make -s print-{name}` failed:\n" + proc.stderr.strip())
    return proc.stdout.split()


def severed_reads(names):
    """Names among `names` that the Makefile does not define."""
    org = origins(names)
    return sorted(n for n in names if org.get(n, "undefined") == "undefined")


def check_axis_a():
    """Axis A: every `print-<VAR>` / `mkv <VAR>` query names a defined variable."""
    checks = 0
    found, computed, per_spelling = harvest_reads()

    if not found:
        sys.exit("FAIL: axis A harvested no Makefile variable queries at all "
                 "-- the regex has stopped matching")
    checks += 1

    # Both spellings must still be reached. The v0.9.8 defect was in the `mkv`
    # form exclusively, so a harvest that quietly lost that spelling would pass
    # while blind to the only occurrence of the bug it exists to prevent.
    empty = sorted(s for s, n in per_spelling.items() if n == 0)
    if empty:
        sys.exit("FAIL: axis A harvested nothing in the "
                 + ", ".join(f"`{s}`" for s in empty)
                 + " spelling. Fix the pattern rather than dropping the source.")
    checks += 1

    if len(found) < 40:
        sys.exit(f"FAIL: axis A harvested only {len(found)} queries; expected >= 40")
    checks += 1

    # Computed names: expand the known ones, refuse the unknown ones.
    unknown = sorted(set(computed) - set(COMPUTED_KEYS))
    if unknown:
        lines = ["FAIL: axis A found computed variable queries it cannot expand:"]
        for prefix in unknown:
            lines.append(f"  {prefix}<computed>   {computed[prefix][0]}")
        lines.append("")
        lines.append("Add the prefix to COMPUTED_KEYS with the Makefile variable")
        lines.append("supplying its keys. Skipping it would leave a name unchecked.")
        sys.exit("\n".join(lines))
    checks += 1

    stale_keys = sorted(set(COMPUTED_KEYS) - set(computed))
    if stale_keys:
        sys.exit("FAIL: COMPUTED_KEYS expands prefix(es) the harvest no longer "
                 "finds: " + ", ".join(stale_keys) + "\nRemove them; an entry "
                 "nothing reaches is dead configuration.")
    checks += 1

    for prefix, key_var in COMPUTED_KEYS.items():
        keys = print_values(key_var)
        if not keys:
            sys.exit(f"FAIL: axis A cannot expand `{prefix}` -- "
                     f"$({key_var}) is empty")
        for key in keys:
            found.setdefault(prefix + key, []).extend(computed[prefix])
    checks += 1

    for rel in sorted(HISTORICAL_FILES):
        if not os.path.isfile(os.path.join(ROOT, rel)):
            sys.exit(f"FAIL: HISTORICAL_FILES exempts '{rel}', which does not "
                     "exist. Remove the entry; a stale path is a silent exemption.")
    checks += 1

    # The contract.
    severed = severed_reads(set(found))
    if severed:
        lines = ["FAIL: Makefile variable(s) queried by name that the Makefile "
                 "does not define:"]
        for name in severed:
            lines.append(f"  {name}")
            for loc in sorted(set(found[name]))[:4]:
                lines.append(f"      {loc}")
        lines.append("")
        lines.append("`print-%` matches any name, so a query for a removed variable")
        lines.append("prints an empty line and exits 0. The caller gets '' and")
        lines.append("carries on -- which is how a release manifest ends up with")
        lines.append("empty fuse bytes after a 24-hour run.")
        sys.exit("\n".join(lines))
    checks += 1

    # NEGATIVE CASES.
    #
    # (a) THE ORIGINAL DEFECT. These are the three names the v0.9.8 rename left
    # in scripts/make-release.sh's mkv calls. If the contract check above cannot
    # still reject them, it has stopped testing anything.
    historical_defect = ["MCU", "LFUSE_X5", "HFUSE_X5"]
    missed = sorted(set(historical_defect) - set(severed_reads(set(historical_defect))))
    if missed:
        sys.exit("FAIL: negative case -- the v0.9.8 axis-A defect no longer "
                 "reproduces; these removed names read as defined: "
                 + ", ".join(missed))
    checks += 1

    # (b) make and compiler FLAGS containing "print-" must not harvest as
    # queries. All four of these appear in the tree.
    for flag in ("make --no-print-directory -C x",
                 "$(CC) -print-file-name=avr/io.h",
                 "make -rRn --print-data-base",
                 "clang --print-targets"):
        if PRINT_QUERY.search(flag):
            sys.exit(f"FAIL: negative case -- `{flag}` harvests as a variable query")
    checks += 1

    # (c) the historical-document exemption must be driven by the banner, in
    # both directions: present means exempt, absent means checked. Otherwise a
    # document could keep an exemption it no longer declares.
    banner = "> **Historical work record — retained intentionally.**"
    if not self_declared_historical("# Doc\n\n" + banner + "\n"):
        sys.exit("FAIL: negative case -- a historical banner is no longer recognised")
    if self_declared_historical("# Doc\n\nOrdinary current documentation.\n"):
        sys.exit("FAIL: negative case -- a document with no banner reads as historical")
    with open(os.path.join(ROOT, "docs/pic10f320_validation.md"), encoding="utf-8") as fh:
        if self_declared_historical(fh.read()):
            sys.exit("FAIL: negative case -- docs/pic10f320_validation.md is "
                     "current qualification evidence and must not be exempt")
    checks += 1

    # (d) a computed query must be detected as computed rather than harvested as
    # the literal prefix, which is how `part_` would silently become a check for
    # a variable named "part_".
    if PRINT_QUERY.search('make -s print-"$1"'):
        sys.exit("FAIL: negative case -- a fully computed print- query harvests "
                 "as a literal name")
    line = 'AVRDUDE_PART_X5[$n]=$(mkv part_"$n")'
    m = MKV_QUERY.search(line)
    if not m or line[m.end():m.end() + 1] not in COMPUTED_TAIL:
        sys.exit("FAIL: negative case -- `mkv part_\"$n\"` is not detected as a "
                 "computed name")
    checks += 1

    return checks, len(found)


# ------------------------------------------------------------- axes B and D ---

# Published release artifacts. These are immutable records of what a past
# release said, so they name that release's goals and variables correctly and
# must never be edited to match the current tree. A path rule rather than a
# marker, precisely because nobody should be opening these files to add one.
PUBLISHED = re.compile(r"^release/v[\d.]+/")

# The one document whose subject matter IS retired names. TODO.md holds this
# item's own specification, which quotes every dead spelling this gate exists to
# catch, so a variable this file's prose NAMES is the intended content rather
# than a defect. The exemption is scoped to the single axis whose signal is
# exactly that: axes A, B and C still read TODO.md, and each catches a severed
# name in it on its own -- probed with a print- query, a `make <goal>` command
# and an override, all three failing from TODO.md alone.
#
# CHANGELOG.md is NOT a second member, though the shape of the problem looks
# identical and this comment used to say it was. HISTORICAL_FILES above drops a
# changelog from the harvest that feeds EVERY axis, so naming it here would
# understate its exemption rather than describe it: a `make <goal>` that does
# not exist passes from CHANGELOG.md today, which is that file working as
# intended and not something this line governs.
PROSE_EXEMPT_AXIS_D = {"TODO.md"}

# Per-line and per-block exemption markers. Live documents legitimately name a
# retired goal or variable in three situations, all of which exist here: a
# deliberate old-to-new redirect table, a recipe pinned to an older tag where
# the goal correctly does not exist in the current tree, and a quoted transcript
# or a sentence whose whole point is that a name is gone. None of those can be
# inferred from the text, and none is a property of the whole FILE -- so the
# exemption is per-line or per-block, and it has to be written down.
EXEMPT_BEGIN = re.compile(r"name-contract:\s*exempt-begin\b")
EXEMPT_END = re.compile(r"name-contract:\s*exempt-end\b")
EXEMPT_LINE = re.compile(r"name-contract:\s*exempt(?!-)\b")


# Whatever can precede a marker on a line that carries nothing else: comment
# leaders in every syntax this tree uses, and the surrounding punctuation of an
# HTML comment.
MARKER_LEAD = re.compile(r"[\s#/<!*|-]*\Z")


def exemptions(text):
    """Return ({exempted line -> the marker line responsible}, {marker -> kind}).

    A marker exempts the line it sits on. If it is the ONLY thing on its line --
    no prose before it, just a comment leader -- it also exempts the next
    non-blank line, because that is the only way to annotate a line that cannot
    carry a trailing comment: a C `#error` whose trailing text would become part
    of the message, or a sentence wrapped across a comment block. A trailing
    marker deliberately does NOT reach forward, so annotating one row of a table
    cannot silently exempt the row beneath it.

    A marker line is itself exempt, so a marker whose reason string quotes the
    dead name it is explaining does not fail the gate it just opened.
    """
    exempt = {}
    markers = {}
    lines = text.split("\n")
    block_start = None

    def forward_from(index):
        for j in range(index, len(lines)):
            if lines[j].strip():
                return j + 1
        return None

    for lineno, line in enumerate(lines, 1):
        m = (EXEMPT_BEGIN.search(line) or EXEMPT_END.search(line)
             or EXEMPT_LINE.search(line))
        if m is None:
            if block_start is not None:
                exempt[lineno] = block_start
            continue
        exempt[lineno] = lineno
        if EXEMPT_BEGIN.search(line):
            markers[lineno] = "block"
            block_start = lineno
            continue
        if EXEMPT_END.search(line):
            if block_start is not None:
                for k in range(block_start, lineno + 1):
                    exempt.setdefault(k, block_start)
                block_start = None
            continue
        markers[lineno] = "line"
        if MARKER_LEAD.match(line[:m.start()]):
            nxt = forward_from(lineno)
            if nxt is not None:
                exempt.setdefault(nxt, lineno)
    return exempt, markers


def repo_files(root, env=None):
    """Every path git considers part of the tree: tracked, plus untracked and
    not ignored.

    The second query is what lets this gate see a file the run BEFORE it is
    committed. `git ls-files` alone made every NEW file exempt until it was
    added, so `make test` passed on the commit that introduced a violation and
    failed on the next run -- reporting it to whoever ran the suite next rather
    than to the person who had just written it.
    test/test_fuse_injection_contract.py did exactly that, and this file's own
    self-exemption below was accidental for the same reason until the day it was
    first committed. Neither can happen now.

    Both directions matter and check_harvest_scope() asserts both: without
    `--others` the gate silently narrows back to committed files only; without
    `--exclude-standard` it silently widens to every generated artifact in
    build_avr_classic/ and third_party/, none of which anybody wrote.

    `-z` rather than splitting on whitespace, because the untracked half is the
    one that can contain a name a person typed by hand. A space in it would
    split into two nonexistent paths, both dropped by the `isfile` test below --
    that is, the file would be skipped SILENTLY, which is the defect class this
    whole gate exists to prevent.

    Scope caveat, stated because it cannot be enforced: the untracked half
    honours the developer's core.excludesFile as well as the repo's .gitignore,
    so it can see slightly less on one machine than another. The tracked half is
    identical everywhere, so CI stays the floor and this half can only ever
    catch MORE, earlier.
    """
    seen = set()
    for query in (["git", "ls-files", "-z"],
                  ["git", "ls-files", "-z", "--others", "--exclude-standard"]):
        out = subprocess.run(
            query, cwd=root, env=env, capture_output=True, text=True, check=True,
        ).stdout
        seen.update(rel for rel in out.split("\0") if rel)
    return sorted(seen)


def harvestable_files():
    """Readable files in the tree that are not published release artifacts."""
    for rel in repo_files(ROOT):
        if rel == SELF_EXEMPT or PUBLISHED.match(rel):
            continue
        path = os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            continue
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except (OSError, UnicodeDecodeError):
            continue
        if rel.endswith(".md") and (rel in HISTORICAL_FILES
                                    or self_declared_historical(text)):
            continue
        yield rel, text


# Path lookups axis E resolves child commands through. Built from the same
# harvest the other axes read, so a file this gate cannot see is also a file it
# will not resolve a command to -- rather than resolving it to something stale.
_UNIVERSE = set()
_BY_BASENAME = {}


def index_repo_files():
    """Populate the path lookups, once."""
    if _UNIVERSE:
        return
    for rel in repo_files(ROOT):
        _UNIVERSE.add(rel)
        _BY_BASENAME.setdefault(os.path.basename(rel), []).append(rel)


# ----------------------------------------------------------------- axis B ---

# A goal token: lowercase, as every goal in this Makefile is. Uppercase forms
# are handled before this test, because `print-VARIANTS` is a legitimate goal
# through the print-% pattern rule.
GOAL_TOKEN = re.compile(r"[a-z0-9_][a-z0-9_.+-]*\Z")

# `make -C dir`, `make -f file`, ... consume the following word.
FLAG_TAKES_ARG = {"-C", "-f", "-j", "-l", "-o", "-W",
                  "--directory", "--file", "--jobs"}

# A documented goal SCHEMA rather than a literal: `make test-sim-<variant>`.
# Each placeholder is resolved against the Makefile variable that supplies its
# values, and every expansion must exist. This is the check that catches the
# sharpest v0.9.8 casualty: test/README.md named `make test-sim-<variant>`,
# which has no rule at all -- the goal is `test-sim-<variant>-attiny13a`, and
# the missing MCU field is the exact defect the whole rename existed to kill.
# A placeholder with no mapping fails; skipping it silently is how that one
# survived in a live document.
PLACEHOLDERS = {"variant": "VARIANTS"}
PLACEHOLDER = re.compile(r"<([a-z][a-z0-9_]*)>")


_DATA_BASE = {}


def data_base():
    """(explicit targets, pattern-rule prefixes, defined variable names).

    One parse, cached, serving axis B's goal inventory and axis D's variable
    inventory. Reading the data base rather than grepping definitions is what
    makes both axes see GENERATED names -- the `$(eval $(call ...))` families
    such as `attiny85-program` and `test-sim-cd4053_simple-attiny13a` exist only
    after expansion, and a textual harvest of the Makefile would report every
    documented use of them as missing.

    Cost is 0.024 s nested inside `make test`, which is the only place this is
    gated. Standalone it also waits on the worktree flock -- `-n` still runs
    recipe lines containing $(MAKE), and the serialization wrapper's is one --
    so it blocks while a soak or test-long is running, exactly as `make -s
    print-VAR` already does. That lock wait, not parse cost, is the "over two
    minutes" recorded against this approach in TODO.md.

    Standalone the output carries two data-base blocks (the wrapper's, then the
    real one); nested it carries one. Both are parsed and unioned, so the same
    code is correct either way.
    """
    if _DATA_BASE:
        return _DATA_BASE["value"]

    proc = subprocess.run(
        ["make", "-rRn", "--no-print-directory", "--print-data-base"],
        cwd=ROOT, capture_output=True, text=True,
    )
    if proc.returncode != 0:
        sys.exit("FAIL: `make -rRn --print-data-base` failed:\n"
                 + proc.stderr.strip()[:2000])

    explicit, patterns, variables, section = set(), set(), set(), None
    for line in proc.stdout.split("\n"):
        if line.startswith("# Variables"):
            section = "vars"
        elif line.startswith("# Implicit Rules"):
            section = "pattern"
        elif line.startswith("# Files"):
            section = "explicit"
        elif line.startswith("# Finished"):
            section = None
        elif not section or not line or line[0] in "#\t ":
            continue
        elif section == "vars":
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*[:?+!]?=", line)
            if m:
                variables.add(m.group(1))
        else:
            m = re.match(r"^([^:=]+):(?!=)", line)
            if m:
                (patterns if section == "pattern" else explicit).update(
                    m.group(1).split())

    _DATA_BASE["value"] = (explicit,
                           {p[:-1] for p in patterns if p.endswith("%")},
                           variables)
    return _DATA_BASE["value"]


def variant_values():
    """Values for each goal placeholder, from the Makefile."""
    return {name: print_values(var) for name, var in PLACEHOLDERS.items()}


def code_fragments(rel, text):
    """Yield (lineno, fragment) for text that is a COMMAND rather than prose.

    This is the whole precision problem of axis B. English follows the word
    "make" constantly -- "make sure", "make the", "make a" -- so a harvest that
    reads any line containing `make` reports hundreds of English words as
    missing goals (measured: 881 distinct tokens). What separates a command from
    a sentence is the context it sits in, per file type:

      markdown/asciidoc  fenced code blocks, and inline `backtick spans`
      Makefile           recipe and directive lines; in COMMENTS, spans only
      shell/YAML/python  command lines; in comments, spans only
      anything else      spans only (a .gitignore comment documenting the goal
                         that produces the file it ignores is a real reference,
                         and one of them was stale)

    Shell and YAML are continuation-joined first, so that a `\\`-continued apt
    line reading `install -y \\ \\n make util-linux ...` is not mistaken for an
    invocation of make with the goal `util-linux`.
    """
    is_doc = rel.endswith((".md", ".adoc"))
    is_makefile = rel == "Makefile"
    is_code = rel.endswith((".sh", ".yml", ".yaml", ".py"))

    def spans(line):
        return re.findall(r"`([^`]+)`", line)

    if is_doc or is_makefile:
        source = enumerate(text.split("\n"), 1)
    else:
        source = logical_lines(text)

    fenced = False
    for lineno, line in source:
        if is_doc:
            stripped = line.strip()
            if stripped.startswith("```") or stripped in ("----", "...."):
                fenced = not fenced
                continue
            if fenced:
                yield lineno, line
            else:
                for span in spans(line):
                    yield lineno, span
        elif is_makefile or is_code:
            body = line.lstrip().lstrip("@")
            if body.startswith("#"):
                for span in spans(line):
                    yield lineno, span
            else:
                yield lineno, line
        else:
            for span in spans(line):
                yield lineno, span


def first_goal(tail):
    """The first goal word after a make command, or None.

    Only the FIRST is taken, and that is a deliberate ceiling rather than an
    oversight. Documented invocations put the goal that matters first, while the
    text after it is very often prose -- an aligned `# what this builds` comment
    in a README block, or a sentence continuing past a closing backtick. Reading
    every word instead reported `checks`, `gates`, `variants` and `for` as
    missing goals. The cost is that `make clean test` checks only `clean`; in
    practice each goal is also documented on its own somewhere.
    """
    # Redirections end the command; `<variant>` placeholders do NOT. Splitting
    # on a bare `<` truncates `test-sim-<variant>` to `test-sim-`, which turns
    # the goal schema into an unrecognisable stub and quietly disables the
    # placeholder resolution below -- the single check that catches the
    # test/README.md casualty this axis was written for.
    tail = PLACEHOLDER.sub(lambda m: "\x01" + m.group(1) + "\x02", tail)
    tail = re.split(r"\d*[<>]|[;|&]|\|\||&&", tail, maxsplit=1)[0]
    tail = tail.replace("\x01", "<").replace("\x02", ">")
    tail = re.split(r"(?:^|\s)#", tail, maxsplit=1)[0]
    tail = re.sub(r'"[^"]*"|\'[^\']*\'', "", tail)   # VARIANTS="a b c"
    words = tail.split()
    i = 0
    while i < len(words):
        word = words[i]
        if word in FLAG_TAKES_ARG:
            i += 2
            continue
        if word.startswith("-") or "=" in word:
            i += 1
            continue
        return word
    return None


def expand_goal(token, values):
    """Resolve a goal schema to concrete goals, or None if it is not literal."""
    holes = PLACEHOLDER.findall(token)
    if not holes:
        return [token] if GOAL_TOKEN.match(token) else None
    out = [token]
    for hole in holes:
        if hole not in values:
            return "unmapped:" + hole
        out = [g.replace("<" + hole + ">", v) for g in out for v in values[hole]]
    return out


def check_axis_b():
    """Axis B: every `make <goal>` in the tree names a goal that exists."""
    checks = 0
    explicit, patterns, _ = data_base()
    values = variant_values()

    if len(explicit) < 150:
        sys.exit(f"FAIL: axis B read only {len(explicit)} targets from the make "
                 "data base; the parse has stopped working")
    checks += 1

    def known(goal):
        return goal in explicit or any(goal.startswith(p) for p in patterns)

    missing, unmapped, harvested = {}, {}, 0
    used_markers, all_markers = set(), {}

    for rel, text in harvestable_files():
        exempt, markers = exemptions(text)
        for line in markers:
            all_markers[(rel, line)] = markers[line]
        for lineno, fragment in code_fragments(rel, text):
            for m in MAKE_WORD.finditer(fragment):
                if fragment[:m.start()].strip():
                    continue          # the make word must open the command
                token = first_goal(fragment[m.end():])
                if token is None or any(c in token for c in "$\\\"'`()"):
                    continue
                harvested += 1
                expansion = expand_goal(token, values)
                if expansion is None:
                    continue
                if isinstance(expansion, str):
                    if lineno in exempt:
                        used_markers.add((rel, exempt[lineno]))
                    else:
                        unmapped.setdefault(expansion[len("unmapped:"):],
                                            []).append(f"{rel}:{lineno}")
                    continue
                bad = [g for g in expansion if not known(g)]
                if not bad:
                    continue
                if lineno in exempt:
                    used_markers.add((rel, exempt[lineno]))
                    continue
                for goal in bad:
                    missing.setdefault(goal, []).append(f"{rel}:{lineno}")

    if harvested < 200:
        sys.exit(f"FAIL: axis B harvested only {harvested} make commands; "
                 "expected >= 200. The context rules have stopped matching.")
    checks += 1

    if unmapped:
        lines = ["FAIL: axis B found goal schemas with unresolvable placeholders:"]
        for hole, locs in sorted(unmapped.items()):
            lines.append(f"  <{hole}>   {locs[0]}")
        lines.append("")
        lines.append("Map the placeholder to the Makefile variable supplying its")
        lines.append("values in PLACEHOLDERS, or exempt the line. Skipping it is")
        lines.append("how `make test-sim-<variant>` survived with no rule at all.")
        sys.exit("\n".join(lines))
    checks += 1

    if missing:
        lines = ["FAIL: documented `make <goal>` command(s) naming goals that do "
                 "not exist:"]
        for goal in sorted(missing):
            lines.append(f"  {goal}")
            for loc in sorted(set(missing[goal]))[:4]:
                lines.append(f"      {loc}")
        lines.append("")
        lines.append("A reader who types one of these gets 'No rule to make target'.")
        sys.exit("\n".join(lines))
    checks += 1

    # NEGATIVE CASES.
    #
    # (a) a real goal resolves and a bogus one does not.
    if not known("test"):
        sys.exit("FAIL: negative case -- axis B does not recognise `make test`")
    if known("mcu-bypass-definitely-not-a-goal"):
        sys.exit("FAIL: negative case -- axis B accepts a goal that does not exist")
    checks += 1

    # (b) THE ORIGINAL DEFECT. test/README.md named `make test-sim-<variant>`,
    # whose real form carries an MCU field. The schema must expand and the
    # expansion must be rejected, or this axis has lost the casualty it was
    # written for.
    stub = expand_goal("test-sim-<variant>", values)
    real = expand_goal("test-sim-<variant>-attiny13a", values)
    if not isinstance(stub, list) or len(stub) < 3:
        sys.exit("FAIL: negative case -- `test-sim-<variant>` no longer expands; "
                 "placeholder resolution has regressed")
    if all(known(g) for g in stub):
        sys.exit("FAIL: negative case -- the MCU-less `test-sim-<variant>` form "
                 "reads as a valid goal")
    if not all(known(g) for g in real):
        sys.exit("FAIL: negative case -- the real `test-sim-<variant>-attiny13a` "
                 "form reads as missing")
    checks += 1

    # (c) PRECISION. English follows the word "make" constantly; a harvest that
    # reads prose reports hundreds of words as missing goals. Sentences must not
    # be treated as commands, and a package list must not either -- `apt-get
    # install -y \\ <newline> make util-linux` reads as `make util-linux` unless
    # continuations are joined first.
    for prose in ("this is here to make sure the file exists",
                  "which would make the gate fail"):
        for m in MAKE_WORD.finditer(prose):
            if not prose[:m.start()].strip():
                sys.exit(f"FAIL: negative case -- prose '{prose}' parses as a "
                         "make command")
    apt = list(logical_lines("  sudo apt-get install -y \\\n    make util-linux\n"))
    if MAKE_WORD.search(apt[0][1]) and not apt[0][1][
            :MAKE_WORD.search(apt[0][1]).start()].strip():
        sys.exit("FAIL: negative case -- a continued apt package list parses as "
                 "a make invocation")
    checks += 1

    # (d) an exemption must stop applying when its marker is removed, in both
    # the block and the standalone-line forms.
    block = "a\n<!-- name-contract: exempt-begin x -->\nb\n<!-- name-contract: exempt-end -->\nc\n"
    exempt_map, _ = exemptions(block)
    if 3 not in exempt_map or 5 in exempt_map:
        sys.exit("FAIL: negative case -- block exemption covers the wrong lines")
    unmarked = exemptions(block.replace("<!-- name-contract: exempt-begin x -->",
                                        "x"))[0]
    if 3 in unmarked:
        sys.exit("FAIL: negative case -- a block's contents stay exempt after "
                 "its opening marker is removed")
    standalone, _ = exemptions("# name-contract: exempt (why)\nprose here\nother\n")
    if 2 not in standalone or 3 in standalone:
        sys.exit("FAIL: negative case -- a standalone marker does not exempt "
                 "exactly the line it introduces")
    trailing, _ = exemptions("prose <!-- name-contract: exempt -->\nnext row\n")
    if 1 not in trailing or 2 in trailing:
        sys.exit("FAIL: negative case -- a trailing marker reaches forward and "
                 "would silently exempt the line beneath it")
    checks += 1

    return checks, harvested, used_markers, all_markers


# ----------------------------------------------------------------- axis D ---

# The project's own variable vocabulary. Scoping to it is what makes a textual
# sweep survivable: a generic [A-Z_]{3,} pass over prose drowns in C macros,
# register names and acronyms. The retired spellings are listed too, because a
# document still recommending one is the entire defect.
#
# A NEW PART MUST BE ADDED HERE. Its variables are spelled with the part name,
# so until the prefix is listed, prose naming one of them is out of scope and a
# severed mention passes silently -- which is what happened to PIC12F675_ while
# that part's lanes were being built.
VAR_PREFIXES = ("ATTINY13A_", "TINYX5_", "AVR_", "XT_", "PIC_",
                "PIC10F320_", "PIC10F322_", "PIC12F675_", "PIC320_", "SOAK_")
VAR_RETIRED = {"MCU", "PROGRAMMER", "LFUSE", "HFUSE"}

# `NAME` in backticks, or NAME= in a sentence or a diagnostic string.
VAR_NAMED = re.compile(r"`([A-Z][A-Z0-9_]{2,})`|\b([A-Z][A-Z0-9_]{2,})=(?!=)")
# A family reference: PIC320_* or PIC320_{FAULT,IO}. This is the shape that
# carried the worst of the v0.9.8 surfaces, README.md's "the PIC10F320 lane uses
# PIC320_* variables", so it is checked as a PREFIX: some known variable must
# begin with it. Testing the stem as a whole name instead reports every correct
# family reference (AVR_SOAK_*, XT_FUSE_*) as severed.
VAR_FAMILY = re.compile(r"\b([A-Z][A-Z0-9_]{2,}_)(?:\*|\{)")


def check_axis_d(known_names):
    """Axis D: variables named to human readers still exist."""
    checks = 0
    severed, harvested = {}, 0
    used_markers, all_markers = set(), {}

    def relevant(name):
        return name.startswith(VAR_PREFIXES) or name in VAR_RETIRED

    for rel, text in harvestable_files():
        if rel in PROSE_EXEMPT_AXIS_D:
            continue
        exempt, markers = exemptions(text)
        for line in markers:
            all_markers[(rel, line)] = markers[line]
        is_doc = rel.endswith((".md", ".adoc"))
        for lineno, line in enumerate(text.split("\n"), 1):
            body = line.lstrip().lstrip("@")
            # Prose only: documentation, and comments in code. A variable name
            # in executable code is not a claim about the Makefile -- it is a
            # shell local or a C macro, and this tree has hundreds that share
            # the project's prefixes (SOAK_PIDS, MUTATION_MAKE, RELEASE_THRESH).
            if not (is_doc or body.startswith(("#", "//", "*", "/*"))):
                continue
            hits = []
            for m in VAR_NAMED.finditer(line):
                name = next(g for g in m.groups() if g)
                if relevant(name):
                    hits.append((name, name in known_names))
            for m in VAR_FAMILY.finditer(line):
                stem = m.group(1)
                if relevant(stem):
                    hits.append((stem + "*",
                                 any(k.startswith(stem) for k in known_names)))
            for label, ok in hits:
                harvested += 1
                if ok:
                    continue
                if lineno in exempt:
                    used_markers.add((rel, exempt[lineno]))
                    continue
                severed.setdefault(label, []).append(f"{rel}:{lineno}")

    if harvested < 40:
        sys.exit(f"FAIL: axis D harvested only {harvested} variable mentions; "
                 "expected >= 40. The shape patterns have stopped matching.")
    checks += 1

    if severed:
        lines = ["FAIL: prose or diagnostics naming variables the Makefile "
                 "neither defines nor reads:"]
        for name in sorted(severed):
            lines.append(f"  {name}")
            for loc in sorted(set(severed[name]))[:4]:
                lines.append(f"      {loc}")
        lines.append("")
        lines.append("Make accepts an assignment to a name it does not know and")
        lines.append("ignores it, so a reader who follows this gets no error at all.")
        sys.exit("\n".join(lines))
    checks += 1

    # NEGATIVE CASES.
    #
    # (a) a correct family reference must pass and a retired one must not. This
    # is the distinction the specification got wrong: it proposed testing the
    # stem as a whole NAME, under which `AVR_SOAK_*` -- a perfectly good
    # reference to eleven real variables -- reads as severed, because no
    # variable is literally called AVR_SOAK.
    if not any(k.startswith("AVR_SOAK_") for k in known_names):
        sys.exit("FAIL: negative case -- axis D no longer resolves the "
                 "AVR_SOAK_* family")
    if any(k.startswith("PIC320_") for k in known_names):
        sys.exit("FAIL: negative case -- PIC320_* is the retired prefix and must "
                 "not resolve; the v0.9.8 rename removed it")
    checks += 1

    # (b) the shapes must still match, and executable code must NOT be read as
    # prose. This tree has hundreds of shell locals and C macros sharing the
    # project's prefixes (SOAK_PIDS, MUTATION_MAKE, RELEASE_THRESH); reading
    # code lines reported 154 of them as severed variables.
    if not VAR_NAMED.search("the `PIC320_TAG` variable") \
            or not VAR_FAMILY.search("uses PIC320_* variables"):
        sys.exit("FAIL: negative case -- axis D's shape patterns no longer match")
    if VAR_FAMILY.search("PIC320-star") or VAR_NAMED.search("PIC320_TAG"):
        sys.exit("FAIL: negative case -- axis D matches a bare word with no "
                 "variable shape around it")
    checks += 1

    # (c) the env-channel half of the known set must resolve, and must not have
    # swallowed either neighbouring shape. PIC_GPSIM_PROC is the motivating
    # case: a name four recipes write, no make variable defines, and whose loss
    # left the PIC10F320 lanes simulating a PIC10F322 in v0.9.8. A `-D` macro is
    # the shape most easily mistaken for it, and belongs to the fuse-injection
    # contract instead.
    channels = env_channel_names()
    if "PIC_GPSIM_PROC" not in channels:
        sys.exit("FAIL: negative case -- the env-channel harvest no longer finds "
                 "PIC_GPSIM_PROC; a recipe prefix has moved or the word walk "
                 "has stopped working")
    if channels & {"T13_LFUSE", "DT13_LFUSE", "T85_LFUSE"}:
        sys.exit("FAIL: negative case -- the env-channel harvest is reading -D "
                 "macros as environment")
    checks += 1

    return checks, harvested, used_markers, all_markers


# ----------------------------------------------------------------- axis E ---

# Channels whose consumer is not a file in this repository, with the reason.
# Same discipline as ENV_ALLOWLIST: every entry is a name this axis cannot
# check, so a wrong one is a permanent blind spot, and every entry must still be
# reached by the harvest or it fails as stale.
#
# Both members are INTERPRETER variables -- read by CPython itself and by
# cppcheck's Python addon runner, before any code in this tree gets control.
# There is no repo file that could read them, which is what makes them safe to
# list and also what makes the list unlikely to grow: a project-specific channel
# always has a consumer here.
EXTERNAL_CONSUMERS = {
    "PYTHONPATH": "read by CPython at startup, to import the yasimavr venv",
    "PYTHONWARNINGS": "read by CPython at startup, inside cppcheck's addon runner",
}

# A word that introduces a command without being one, so an assignment after it
# is still in prefix position.
PREFIX_TRANSPARENT = {"export", "env", "then", "do", "else", "{", "(", "!",
                      "time", "nice", "nohup"}

# A token that is exactly one make expansion, e.g. `$(XT_FUSE_ENV)`. Resolved
# through `make print-`, because a command or an env prefix hidden behind a make
# variable is still a command or an env prefix.
LONE_MAKEVAR = re.compile(r"\A\$[({]([A-Za-z_][A-Za-z0-9_]*)[)}]\Z")

SCRIPTISH = (".sh", ".py", ".awk", ".bash", ".cc", ".c")

# A literal prefix being concatenated to build a name at runtime:
# `"ATTINY202_FUSE_" + name` in test/avr/attiny202_fuses.py. Axis A already
# needed this shape (`mkv part_"$n"`); the environment has it too, and a reader
# that builds its names this way contains no literal spelling of any of them.
CONCATENATED = re.compile(r"[\"']([A-Z][A-Z0-9_]*_)[\"']\s*(?:\+|%|,)")

_EXPANDED = {}
_FILE_TEXT = {}


def make_expand(name):
    """`make -s print-<name>`, cached. Empty string if make fails."""
    if name not in _EXPANDED:
        done = subprocess.run(["make", "-s", "--no-print-directory",
                               "print-" + name], cwd=ROOT,
                              capture_output=True, text=True)
        _EXPANDED[name] = done.stdout.strip() if done.returncode == 0 else ""
    return _EXPANDED[name]


def file_text(rel):
    """A repo file's text, cached. Empty string if it cannot be read."""
    if rel not in _FILE_TEXT:
        try:
            with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
                _FILE_TEXT[rel] = fh.read()
        except (OSError, UnicodeDecodeError):
            _FILE_TEXT[rel] = ""
    return _FILE_TEXT[rel]


def recipe_statements(body):
    """Split a recipe body into statements, each a list of tokens.

    Quote- and expansion-aware, and it has to be. Splitting on whitespace gets
    all four of the shapes this axis meets wrong:

      hex="$(call fw_image_tail,$(1),$(MCU)).hex"   two tokens, one value
      tmp=$$(mktemp "$@.tmp.XXXXXX")                a SHELL substitution
      TM_LABEL='a b' ./test/x.sh                    a space inside a value
      awk 'prev=="x"{print $$2; exit}' "$$f"        a `;` inside a quote

    Getting them wrong is not cosmetic here. A `NAME=$(MAKEVAR)` prefix -- the
    exact shape of every real channel, including the one whose severance this
    axis exists for -- looks like a command substitution to a naive splitter and
    disappears from the harvest entirely. And the shell LOCALS that a recipe is
    full of (`rc=$$?`, `fail=1`, `out=$$(...)`) look like channels.

    That distinction is the whole discrimination, and it is structural rather
    than conventional: a prefix is an assignment FOLLOWED BY A COMMAND in the
    same statement; a local is an assignment that is the whole statement, or one
    whose value is a substitution the rest of the line sits inside. Measured on
    this Makefile, the structural rule alone separates them perfectly -- 98
    channels, of which zero are lowercase, and the 40-odd shell locals it drops
    include every lowercase name. No naming convention is relied on, so a
    channel spelled in lowercase would still be checked.
    """
    opening = {"(": ")", "{": "}"}
    out, statement, token = [], [], ""
    i, n = 0, len(body)
    while i < n:
        char = body[i]
        if char in "'\"`":                        # quoted or substituted span
            end = body.find(char, i + 1)
            end = n if end < 0 else end
            token += body[i:end + 1]
            i = end + 1
            continue
        if char == "$" and i + 1 < n:
            k = i + 1
            while k < n and body[k] == "$":       # `$$(` is the shell's own
                k += 1
            if k < n and body[k] in opening:
                close, depth, j = opening[body[k]], 0, k
                while j < n:
                    if body[j] in opening and opening[body[j]] == close:
                        depth += 1
                    elif body[j] == close:
                        depth -= 1
                        if depth == 0:
                            break
                    j += 1
                token += body[i:j + 1]
                i = j + 1
                continue
        if char.isspace():
            if token:
                statement.append(token)
                token = ""
            i += 1
            continue
        if char in ";|&<>\n":
            if token:
                statement.append(token)
                token = ""
            if statement:
                out.append(statement)
                statement = []
            i += 1
            continue
        token += char
        i += 1
    if token:
        statement.append(token)
    if statement:
        out.append(statement)
    return out


def split_prefix(statement, depth=0):
    """(channel names written, the command tokens that follow them).

    A lone `$(VAR)` in prefix position is expanded and walked, because
    `$(XT_FUSE_ENV) $(YASIMAVR_PY) $(XT_SIM_DRIVER)` hides seven
    ATTINY202_FUSE_* channels behind one make variable. Reading only the
    literal text of the recipe finds none of them.
    """
    names, i = [], 0
    while i < len(statement):
        token = statement[i]
        if token in PREFIX_TRANSPARENT:
            i += 1
            continue
        assigned = re.match(r"([A-Za-z_][A-Za-z0-9_]*)=", token)
        if assigned:
            names.append(assigned.group(1))
            i += 1
            continue
        lone = LONE_MAKEVAR.match(token)
        if lone and depth < 3:
            # Re-tokenize the expansion with the same statement-aware splitter
            # the recipe went through, rather than str.split(). A make variable
            # in prefix position is not always a prefix: a `define` holding a
            # whole shell fragment expands to SEVERAL statements, the first of
            # which may be a plain assignment -- `simcal_count=0; for ... done`.
            # Split naively, that reads as the channel simcal_count written for
            # the command `for`, and demands that some file in the repository
            # read a shell local through its environment. Which nothing does,
            # because `x=0; cmd` does not put x in cmd's environment at all;
            # only `x=0 cmd` does, and that is one statement.
            expanded = recipe_statements(make_expand(lone.group(1)))
            words = expanded[0] if expanded else []
            if words and re.match(r"[A-Za-z_][A-Za-z0-9_]*=", words[0]):
                # The recipe text after this token continues the FIRST statement
                # only when the expansion was one statement. Otherwise the
                # expansion ended in a `;` and what follows is its own command.
                tail = statement[i + 1:] if len(expanded) == 1 else []
                more, rest = split_prefix(words + tail, depth + 1)
                return names + more, rest
        break
    return names, statement[i:]


def env_channel_writes():
    """{channel name -> [(Makefile line, command tokens it was written for)]}.

    The PRODUCER side of axis E, and deliberately stricter than
    env_channel_names(), which serves axis D. That one wants a superset: a name
    it fails to harvest becomes a false severance report on correct prose, so it
    errs toward accepting. This one wants a *precise* set: a name it harvests
    wrongly becomes a demand that some file read a shell local.

    Scope, measured rather than assumed: Makefile recipe prefixes only. Shell
    scripts write 14 such prefixes between them, and they are dominated by
    shell built-ins and locals that happen to be uppercase -- IFS, and the
    terminal colour codes -- so the yield does not pay for a second
    discrimination pass. Makefile-to-script is also where the defect was.
    """
    writes = {}
    with open(os.path.join(ROOT, "Makefile"), encoding="utf-8") as fh:
        text = fh.read()
    for lineno, line in logical_lines(text):
        if not line.startswith("\t"):
            continue
        body = line.lstrip("\t").lstrip().lstrip("@-+")
        for statement in recipe_statements(body):
            names, command = split_prefix(statement)
            if not names or not command:
                continue
            for name in names:
                writes.setdefault(name, []).append((lineno, tuple(command)))
    return writes


def repo_path(token):
    """The repo file a token names, if any."""
    text = token.strip("\"'")
    lone = LONE_MAKEVAR.match(text)
    if lone:
        text = make_expand(lone.group(1))
    text = text.strip("\"'").lstrip("./")
    if text in _UNIVERSE:
        return text
    # Resolve by BASENAME when the path is built at runtime, which is how every
    # sourced helper in this tree is written: `. "$(dirname "$0")/common.sh"`,
    # `GATE="$ROOT/check_stack_depth_pic.sh"`. Only when the basename is unique
    # in the repository, so this can never silently pick the wrong file.
    base = os.path.basename(text)
    if text.endswith(SCRIPTISH) and len(_BY_BASENAME.get(base, ())) == 1:
        return _BY_BASENAME[base][0]
    return None


def resolve_child(command):
    """(repo files the command runs, kind). Empty set means unresolved."""
    words = []
    for token in command:
        lone = LONE_MAKEVAR.match(token.strip("\"'"))
        words.extend(make_expand(lone.group(1)).split() if lone else [token])
    for token in words:
        found = repo_path(token)
        if found:
            return {found}, "file"
    # A recursive make: the environment reaches the sub-make's own expansions,
    # so the Makefile is the reader. This is how the _MAKE_SERIAL_* test hooks
    # travel -- `flock .make.lock $(MAKE_COMMAND) ...`, read back as
    # `$(value _MAKE_SERIAL_CLASSIC_DUPLICATE)`.
    for token in words:
        if os.path.basename(token.strip("\"'")) in ("make", "gmake"):
            return {"Makefile"}, "recursive-make"
    return set(), "external:" + (words[0].strip("\"'") if words else "?")


def strip_comments(text):
    """Drop `#` comments, so a filename merely MENTIONED is not an edge."""
    return "\n".join(re.sub(r"(?<!\$)#.*", "", line) for line in text.split("\n"))


def invoked_by(rel):
    """Repo files this one runs, sources or imports."""
    text = strip_comments(file_text(rel))
    reached = set()
    for statement in recipe_statements(text):
        for token in statement:
            if token.strip("\"'").endswith(SCRIPTISH) or "/" in token:
                found = repo_path(token)
                if found and found != rel:
                    reached.add(found)
    for module in re.findall(r"^\s*(?:from|import)\s+([A-Za-z_][A-Za-z0-9_]*)",
                             text, re.M):
        reached.update(_BY_BASENAME.get(module + ".py", ()))
    return reached


def reader_closure(seeds):
    """Every repo file the environment can reach from these entry points.

    Transitive, and that is required rather than a refinement: a direct-read
    check reports two correct channels as severed. AWK is written for
    test/test_stack_depth_pic.sh, which is a WRAPPER -- the read is in
    check_stack_depth_pic.sh, which it runs as a child, and a child inherits the
    environment. BYPASS_MODEL_FFI is written for a Python driver whose read is
    in a module it imports. Both are correct code.
    """
    seen, todo = set(), list(seeds)
    while todo:
        rel = todo.pop()
        if rel in seen:
            continue
        seen.add(rel)
        todo.extend(invoked_by(rel) - seen)
    return seen


def reads_channel(rel, name):
    """(does this file read the name?, was the name COMPUTED rather than written?)"""
    text = file_text(rel)
    quoted = re.escape(name)
    for pattern in (rf"\${quoted}\b", rf"\$\{{{quoted}[}}:\-/#%\[]",
                    rf"\$\({quoted}\)", rf"\$\((?:value|origin)\s+{quoted}\)"):
        if re.search(pattern, text):
            return True, False
    # Python names its environment with STRINGS, and not always at the point of
    # access: test/avr/test_soak_attiny202.py passes
    # "ATTINY202_SOAK_DURATION_MS" to a local _env_ms() helper that calls
    # os.environ.get. Requiring `environ`/`getenv` adjacent to the literal
    # reports every such read as severed, so any quoted occurrence counts. The
    # looseness is safe in the direction that matters: after a rename severs the
    # producer, the literal in the file is the NEW spelling, so the old name
    # still appears nowhere and is still caught.
    if rel.endswith(".py") and re.search(rf"[\"']{quoted}[\"']", text):
        return True, False
    for built in CONCATENATED.finditer(text):
        prefix = built.group(1)
        if len(prefix) >= 6 and name.startswith(prefix) and name != prefix:
            return True, True
    return False, False


def check_axis_e():
    """Axis E: a child still reads the environment the Makefile sets for it."""
    checks = 0
    index_repo_files()
    writes = env_channel_writes()
    if len(writes) < 40:
        sys.exit(f"FAIL: axis E harvested only {len(writes)} env channels from "
                 "the Makefile; the recipe tokenizer or the prefix walk has "
                 "rotted, and a harvest this small cannot be checking much")
    checks += 1

    # EVERY write site is checked, not just one per name. Each
    # `NAME=value <child>` is an independent producer-consumer link, and a
    # severed one is a defect however healthy its siblings are. Measured, this
    # is not a hypothetical: ATTINY202_FUSE_WDTCFG is written at five sites,
    # four of them to drivers that read it through a computed prefix and the
    # fifth to the fuse reader's own unit test, which names it literally.
    # Satisfying the NAME rather than the LINK lets breaking the computed
    # prefix -- which severs all four real consumers -- pass on the strength of
    # the unit test. Verified: the per-name form does exactly that.
    severed, unresolved, computed, reached = {}, {}, set(), 0
    for name in sorted(writes):
        if name in EXTERNAL_CONSUMERS:
            continue
        for lineno, command in writes[name]:
            children, kind = resolve_child(list(command))
            if not children:
                unresolved[(name, lineno)] = kind
                continue
            satisfied = None
            for rel in sorted(reader_closure(children)):
                hit, was_computed = reads_channel(rel, name)
                if hit:
                    satisfied = (rel, was_computed)
                    break
            if not satisfied:
                severed[(name, lineno)] = sorted(children)
                continue
            reached += 1
            if satisfied[1]:
                computed.add(name)

    if severed:
        lines = ["FAIL: the Makefile sets environment no child reads:"]
        for (name, lineno), children in sorted(severed.items()):
            lines.append(f"  {name}")
            lines.append(f"      written  Makefile:{lineno}")
            lines.append(f"      child    {', '.join(children) or '(unresolved)'}")
        lines += [
            "",
            "The assignment is legal, silent and inert: the child falls back to",
            "its own in-source default and the lane goes on passing while",
            "measuring something else. That is what `make pic10f320-test-gpsim`",
            "did for an entire release, on a p10f322 device model.",
            "",
            "Rename the child's read to match, or -- if the consumer is not a",
            "file in this repository -- add it to EXTERNAL_CONSUMERS with the",
            "reason.",
        ]
        sys.exit("\n".join(lines))
    checks += 1

    if unresolved:
        lines = ["FAIL: axis E cannot find the consumer of these channels:"]
        for (name, lineno), kind in sorted(unresolved.items()):
            lines.append(f"  {name:34s} Makefile:{lineno}  {kind}")
        lines += [
            "",
            "An unresolved channel is a SKIPPED check, not a passing one, so it",
            "fails rather than being counted quietly. Either teach",
            "resolve_child() the shape, or record the name in",
            "EXTERNAL_CONSUMERS with the reason its consumer is not a repo file.",
        ]
        sys.exit("\n".join(lines))
    checks += 1

    # Every allowlist entry must still be a channel this axis actually meets,
    # or it is covering whatever gets written under that name next.
    stale = sorted(set(EXTERNAL_CONSUMERS) - set(writes))
    if stale:
        sys.exit("FAIL: EXTERNAL_CONSUMERS names channels the Makefile no "
                 f"longer writes: {', '.join(stale)}\nRemove them; an "
                 "exemption nothing reaches is a blind spot.")
    checks += 1

    # Negative case: the harvest must still find the channel the axis was built
    # for, reached through a SOURCED helper rather than the invoked script --
    # the one shape a direct-read check gets wrong.
    proc = "PIC_GPSIM_PROC"
    if proc not in writes:
        sys.exit(f"FAIL: negative case -- axis E no longer harvests {proc}, the "
                 "channel whose severance it exists to catch")
    wrapper = "test/pic/gpsim_wrapper_common.sh"
    if not reads_channel(wrapper, proc)[0]:
        sys.exit(f"FAIL: negative case -- {wrapper} no longer reads {proc}. If "
                 "that is deliberate, this axis has just done its job; if not, "
                 "the read-detection patterns have rotted.")
    checks += 1

    return checks, len(writes), reached, len(computed)


def check_axis_c():
    """Axis C: every `NAME=value` handed to make names a variable it knows."""
    checks = 0
    found, used_markers, all_markers = harvest()
    checked = {n: locs for n, locs in found.items() if n not in ENV_ALLOWLIST}

    # The harvest must find something, and must find the sources separately. A
    # regex that quietly stops matching is the same defect class this gate
    # exists to catch, and it would otherwise pass by checking an empty set.
    if not found:
        sys.exit("FAIL: harvested no make overrides at all -- the regex has stopped matching")
    checks += 1

    from_rows = [n for n, locs in found.items() if any("mutation row" in l for l in locs)]
    if not from_rows:
        sys.exit(
            "FAIL: harvested no overrides from the mutation tables. That source "
            "carries the v0.9.8 defect this gate exists to prevent; if the table "
            "format changed, fix the parser rather than dropping the source."
        )
    checks += 1

    # Documents are a source in their own right and are checked the same way, so
    # losing them must be loud. Nine names reach this axis ONLY from prose
    # (STRICT_TOOLS, VARIANTS, VERSION, ...); before the scope widened they were
    # checked by nothing -- axis D covers doc prose but only inside the project's
    # variable prefixes, and every one of those nine is unprefixed.
    from_docs = [n for n, locs in found.items()
                 if any(re.search(r"\.(?:md|adoc):\d+$", l) for l in locs)]
    if not from_docs:
        sys.exit(
            "FAIL: harvested no overrides from any document. A documented "
            "`make <goal> NAME=value` is the same claim about the Makefile's "
            "vocabulary as a script's, aimed at a reader who gets no error at "
            "all; restore the scope rather than narrowing the contract."
        )
    checks += 1

    if len(checked) < 10:
        sys.exit(f"FAIL: harvested only {len(checked)} checkable overrides; expected >= 10")
    checks += 1

    # Every allowlist entry must still be reached by the harvest. An entry that
    # nothing produces is a name this gate has permanently stopped checking, for
    # a reason that no longer exists -- and if that name is later passed as a
    # real override, the exemption silently covers it. Exemptions must expire.
    stale_exemptions = sorted(ENV_ALLOWLIST - set(found))
    if stale_exemptions:
        sys.exit(
            "FAIL: ENV_ALLOWLIST exempts name(s) the harvest no longer finds: "
            + ", ".join(stale_exemptions)
            + "\nRemove them; an exemption nothing reaches is a permanent blind spot."
        )
    checks += 1

    # The contract: defined OR consumed.
    org = origins(checked)
    consumed = dereferenced_names()
    severed = sorted(
        n for n in checked
        if org.get(n, "undefined") == "undefined" and n not in consumed
    )
    if severed:
        lines = ["FAIL: make override(s) name variables this Makefile neither defines nor reads:"]
        for name in severed:
            lines.append(f"  {name}")
            for loc in sorted(set(checked[name]))[:4]:
                lines.append(f"      {loc}")
        lines.append("")
        lines.append("A make override naming no existing variable is legal and silent:")
        lines.append("the value is ignored and the Makefile default applies.")
        sys.exit("\n".join(lines))
    checks += 1

    # NEGATIVE CASES, per the house pattern.
    #
    # (a) a bogus name must be rejected...
    if origins({"MCU_BYPASS_DEFINITELY_NOT_A_VARIABLE"}).get(
        "MCU_BYPASS_DEFINITELY_NOT_A_VARIABLE"
    ) != "undefined":
        sys.exit("FAIL: negative case -- the origin oracle did not report a bogus name as undefined")
    checks += 1

    # (b) ...and a name that IS defined but deliberately EMPTY must be accepted,
    # because a non-emptiness test here would produce false failures.
    for name in ("XT_SOAK_COMBINATION_NAME", "AVR_STACK_BUILD_DIR"):
        if origins({name}).get(name) == "undefined":
            sys.exit(
                f"FAIL: negative case -- {name} is defined-but-empty by design and "
                "must not read as undefined; the oracle has regressed to a value test"
            )
    checks += 1

    # (c) the continuation join must work, since a physical-line harvest is what
    # let three inert overrides through in the first place.
    joined = list(logical_lines("make foo \\\n    BAR=1\n"))
    if "BAR=1" not in joined[0][1] or joined[0][0] != 1:
        sys.exit("FAIL: negative case -- backslash continuations are no longer joined")
    if assignments_passed_to_make(joined[0][1]) != ["BAR"]:
        sys.exit("FAIL: negative case -- a continued override is not harvested as one")
    checks += 1

    # (d) and make-release.sh must not read as a make invocation.
    if MAKE_WORD.search("scripts/make-release.sh --soak-duration-ms 0"):
        sys.exit("FAIL: negative case -- `make-release.sh` is being treated as a make invocation")
    checks += 1

    # (e) a make word inside an assignment's VALUE belongs to that value's
    # command, not to the line carrying it. Resolving make's path for a
    # fake-tool shim -- `REAL_PROJECT_MAKE="$(command -v make)"` -- otherwise
    # anchors the harvest at the lookup, and every environment prefix after it
    # reads as an override: 27 shim parameters (FAKE_*, MATRIX_*, LM_*, TM_*)
    # reported as severed the day the PIC12F675 matrix gates started doing that.
    prefixed = ('REAL_PROJECT_MAKE="$(command -v make)" FAKE_MODE=x '
                '"$fake_make" -C dir MAKE="$fake_make" PROJECT_MAKE=true')
    if assignments_passed_to_make(prefixed):
        sys.exit("FAIL: negative case -- a `make` inside an assignment's value "
                 "anchors the override harvest, so the environment prefixes "
                 "after it read as make overrides: "
                 + ", ".join(assignments_passed_to_make(prefixed)))
    # ...and the body of that substitution is still harvested as a command in
    # its own right, or the fix trades a false positive for a blind spot: real
    # invocations in this tree pass overrides from inside a substitution.
    if assignments_passed_to_make("XT_N=$(make -s print-X BAR=1 | wc -w)") != ["BAR"]:
        sys.exit("FAIL: negative case -- an override inside a command "
                 "substitution is no longer harvested")
    checks += 1

    return checks, len(checked), used_markers, all_markers


def check_harvest_scope():
    """The harvest must see an untracked file, and must not see an ignored one.

    A FIXTURE repo rather than an assertion about the real tree, because a clean
    working directory has no untracked file to see -- the property that matters
    here is precisely the one the repository cannot demonstrate about itself on
    the day it is checked.

    The fixture stages with `git add` and never commits, so it needs no
    user.name/user.email, and it neutralises the global and system config so
    that a developer's own core.excludesFile cannot change what is asserted.
    """
    env = dict(os.environ)
    env["GIT_CONFIG_GLOBAL"] = os.devnull
    env["GIT_CONFIG_SYSTEM"] = os.devnull

    fixture = {
        ".gitignore": "ignored.md\n",
        "committed.md": "tracked\n",
        "uncommitted.md": "written, not yet added -- must be in scope\n",
        "ignored.md": "generated -- must not be\n",
        # A release directory staged but not yet committed: exactly the state
        # `make release` leaves behind. Newly REACHABLE now that the harvest no
        # longer stops at the index, so the PUBLISHED path rule -- which used to
        # be redundant for an unadded file -- is now what keeps an immutable
        # record of a past release out of a check on the current tree.
        "release/v9.9.9/README.md": "make some-goal-that-is-long-gone\n",
    }
    with tempfile.TemporaryDirectory() as tmp:
        for rel, body in fixture.items():
            path = os.path.join(tmp, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(body)
        subprocess.run(["git", "init", "-q", tmp], env=env,
                       capture_output=True, check=True)
        subprocess.run(["git", "add", ".gitignore", "committed.md"],
                       cwd=tmp, env=env, capture_output=True, check=True)
        got = set(repo_files(tmp, env=env))

    want = set(fixture) - {"ignored.md"}
    if got != want:
        sys.exit(
            "FAIL: the file harvest does not cover what it must.\n"
            f"  missing: {sorted(want - got) or '(none)'}\n"
            f"  extra:   {sorted(got - want) or '(none)'}\n"
            "An untracked file must be in scope, or a violation is reported one\n"
            "run late -- to the next person rather than to its author. An\n"
            "ignored file must not be, or the gate harvests build artifacts."
        )
    if not PUBLISHED.match("release/v9.9.9/README.md"):
        sys.exit(
            "FAIL: PUBLISHED no longer excludes a release directory, and the\n"
            "harvest now reaches one before it is committed. A past release's\n"
            "own goal names would be checked against the current Makefile."
        )
    return 2


def check_self_exemption():
    """The self-exemption must still be load-bearing, or it is a blind spot.

    Exemptions expire here, exactly as ENV_ALLOWLIST entries do: if this file
    stops quoting severed names -- because the examples moved to a document, say
    -- then the exclusion is buying nothing and is silently hiding whatever the
    file grows next. Verifying it means verifying BOTH harvests still have
    something to say about it.
    """
    with open(os.path.join(ROOT, SELF_EXEMPT), encoding="utf-8") as fh:
        text = fh.read()
    has_overrides = any(assignments_passed_to_make(line)
                        for _, line in logical_lines(text))
    has_reads = bool(PRINT_QUERY.search(text) or MKV_QUERY.search(text))
    if not (has_overrides and has_reads):
        sys.exit(
            f"FAIL: '{SELF_EXEMPT}' is excluded from both harvests, but no "
            "longer contains the examples that justified it "
            f"(overrides={has_overrides}, queries={has_reads}).\n"
            "Drop SELF_EXEMPT; an exclusion nothing reaches is a blind spot."
        )
    return 1


def check_markers(used, declared):
    """Every exemption marker must still suppress something.

    Same discipline as ENV_ALLOWLIST and SELF_EXEMPT: a marker that stops
    matching anything is a permanent hole sitting over live text, and the next
    dead name written under it is covered silently. Exemptions expire.
    """
    stale = sorted(set(declared) - set(used))
    if stale:
        lines = ["FAIL: name-contract exemption marker(s) that no longer suppress "
                 "anything:"]
        for rel, lineno in stale:
            lines.append(f"  {rel}:{lineno}  ({declared[(rel, lineno)]})")
        lines.append("")
        lines.append("Remove them. A marker over text that is now clean will")
        lines.append("silently cover the next dead name written under it.")
        sys.exit("\n".join(lines))
    return 1


def main():
    c_checks, overrides, c_used, c_marks = check_axis_c()
    a_checks, reads = check_axis_a()
    a_checks += check_self_exemption()
    a_checks += check_harvest_scope()

    b_checks, commands, b_used, b_marks = check_axis_b()
    d_checks, mentions, d_used, d_marks = check_axis_d(
        data_base()[2] | dereferenced_names() | env_channel_names())
    e_checks, channels, reached, computed = check_axis_e()

    marks = dict(b_marks)
    marks.update(c_marks)
    marks.update(d_marks)
    shared = check_markers(b_used | c_used | d_used, marks)

    total = c_checks + a_checks + b_checks + d_checks + e_checks + shared
    print(f"Makefile name contract: {total} checks, 0 failures "
          f"(axis A: {reads} queries; axis B: {commands} commands; "
          f"axis C: {overrides} overrides; axis D: {mentions} mentions; "
          f"axis E: {channels} env channels over {reached} write sites, "
          f"every one reached [{computed} through a computed name])")


if __name__ == "__main__":
    main()
