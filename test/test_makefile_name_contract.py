#!/usr/bin/env python3
"""The Makefile name contract: every name another file hands to, or asks of, the
Makefile must be a name the Makefile actually knows.

THE DEFECT CLASS is silent severance. A rename moves a variable; the files still
speaking its old name keep running, quietly, wrongly. Make reports nothing in
either direction -- an override naming no variable is legal, and a query for a
variable that does not exist prints an empty line and exits 0. TODO.md tracks
four axes of this class; two of them are implemented here:

  Axis C -- `make VAR=value`.   A file SETS a Makefile variable.
  Axis A -- `make print-VAR`.   A file READS one.

Axes B and D -- goals and variables named to human readers in prose -- remain
open, and this gate does not cover them.

THE ORACLE, shared by both axes, is `make origins NAMES="..."`, which reports
$(origin) per name in one invocation. Non-emptiness is NOT usable:
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

WHERE OVERRIDES LIVE -- three sources, and the third is the one that matters.

  1. Shell and YAML lines invoking make, across test/, scripts/ and .github/.
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

SCOPE, stated so the next reader does not over-trust it: axis C checks names
passed to make. It does not check names a document merely mentions in prose
(that is axis B/D, still open in TODO.md), and it cannot know that a name
reaching make is meant for make rather than for a script reading the
environment -- hence ENV_ALLOWLIST below, which must stay short and justified.

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
     (`mkv() { make -s print-"$1"; }`). The name arrives as a bare word, so
     nothing about it looks like a Makefile query.

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
"""

import os
import re
import subprocess
import sys

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
# stated.
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
    """
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
    """Return {name: [locations]} for every NAME= handed to make."""
    files = subprocess.run(
        ["git", "ls-files", "test/", "scripts/", ".github/", "Makefile"],
        cwd=ROOT, capture_output=True, text=True, check=True,
    ).stdout.split()

    found = {}

    def record(name, where):
        found.setdefault(name, []).append(where)

    for rel in files:
        if rel == SELF_EXEMPT:
            continue
        path = os.path.join(ROOT, rel)
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except (OSError, UnicodeDecodeError):
            continue

        # Sources 1 and 2: anything invoking make, comments included.
        #
        # The Makefile is harvested by PHYSICAL line rather than joined. A
        # recipe is a multi-line shell script, so joining its continuations
        # turns the whole body into one "line invoking make" and every shell
        # local in it (rc=, marker=, target=) reads as an override. Shell and
        # YAML files are joined, because there a continued line genuinely is one
        # command -- which is the case that hid three inert overrides in v0.9.8.
        is_makefile = rel == "Makefile"
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
            if not is_makefile and line.lstrip().startswith("#"):
                continue
            for name in assignments_passed_to_make(line):
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

    return found


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


def origins(names):
    """{name: $(origin name)} via one make invocation."""
    if not names:
        return {}
    proc = subprocess.run(
        ["make", "-s", "origins", "NAMES=" + " ".join(sorted(names))],
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

# scripts/make-release.sh's wrapper: `mkv() { make -s print-"$1"; }`. Harvested
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

    Scoped to every tracked file, not just test/ and scripts/: a published
    document telling a reader to run `make print-RELEASE_IMAGE_DIRS` is making
    the same claim about the Makefile's vocabulary that a script does, and
    release/README.md does exactly that.
    """
    files = subprocess.run(
        ["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True,
    ).stdout.split()

    found = {}
    computed = {}
    per_spelling = {"print-<VAR>": 0, "mkv <VAR>": 0}

    for rel in files:
        if rel == SELF_EXEMPT:
            continue
        path = os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            continue
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except (OSError, UnicodeDecodeError):
            continue

        is_markdown = rel.endswith(".md")
        if is_markdown and (rel in HISTORICAL_FILES
                            or self_declared_historical(text)):
            continue

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
        ["make", "-s", "print-" + name],
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


def check_axis_c():
    """Axis C: every `NAME=value` handed to make names a variable it knows."""
    checks = 0
    found = harvest()
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

    return checks, len(checked)


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


def main():
    c_checks, overrides = check_axis_c()
    a_checks, reads = check_axis_a()
    a_checks += check_self_exemption()

    print(f"Makefile name contract: {c_checks + a_checks} checks, 0 failures "
          f"(axis C: {overrides} overrides; axis A: {reads} variable queries)")


if __name__ == "__main__":
    main()
