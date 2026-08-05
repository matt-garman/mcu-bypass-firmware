# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project stays on the `0.9.x` pre-1.0 series while the firmware and its
validation suite settle. The criterion for leaving it is explicit: **`1.x.y`
begins once these designs are validated on real hardware.** Everything shipped
so far is validated by simulation, formal proof and static analysis — thorough,
and not the same claim as "it has run on the part". Until that changes, new
work lands as `0.9.x` however large it is; the merge of a whole additional MCU
target in `0.9.6` rather than `0.10.0` is that rule applied, not an
oversight.

Per-release provenance (source commit, pinned toolchain, image hashes, flash
usage, and validation evidence) lives in `release/<version>/MANIFEST.md`; this
file is the human-readable summary of *what changed*.

> **On the PIC10F320's version history.** The PIC10F320 target was developed in a
> separate repository and merged into this one in `v0.9.6` below. That
> project ran its own `v0.9.0`–`v0.9.5` series with **different content and
> different dates** from the identically numbered releases in this file — its
> `0.9.5` is dated 2026-07-10, this project's 2026-07-18. Those entries are
> therefore **not** back-filled here: doing so would collide two unrelated
> numbering lines and misreport each project's history as the other's. The child
> timeline remains reachable in full through the imported commit graph and the
> namespaced signed tags `pic10f320/v0.9.0` … `pic10f320/v0.9.5`. From the first
> unified release onward there is one timeline, with PIC10F320 changes recorded
> as a sub-lane inside each entry.

## [0.9.8] — unreleased

### Added
- **Release step 0 is now independently runnable and regression-tested.**
  `make release-preflight` runs every release capability check and executable
  version probe, then exits before `make clean`, any build goal, or staging.
  It needs no version and is deliberately usable from a dirty working branch;
  `VERSION=vX.Y.Z` is optional when the maintainer also wants local/remote tag
  and output-state warnings. `--preflight` and `--dry-run` are distinct and
  mutually exclusive: the former finishes in seconds and writes no release,
  while the latter rehearses the complete pipeline.

  New gate `test-release-preflight` supplies every selected release input from a
  synthetic toolchain while retaining the real base host utilities and real
  `print-<VAR>` interface. It proves section 0 reaches its final Python version
  probe, records 74 variable queries and zero clean/build invocations, leaves
  tracked/nonignored worktree content and the prospective output unchanged on
  every tested path, and covers the negative paths below rather than merely
  asserting the early exit exists.

  The audit that motivated the mode found several live precondition defects,
  all fixed with it. An absolute `YASIMAVR_VENV` is preserved through mutation,
  target tests and generated soak wrappers instead of becoming
  `<repo>/<absolute path>`;
  preflight checks the independently selected `PIC_SOAK_CXX` and
  `PIC10F320_SOAK_CXX` commands rather than literal `c++`; and a yasimavr
  interpreter must be executable before step 0 can pass. PATH-selected XC8
  commands and executable XC8 paths are both accepted, matching the build. The
  selected `objdump`, `readelf`, file-valued IHEX validator, AWK, analysis
  command, AVR symbol resolver, mutation Make and PIC10F320 host compiler;
  `timeout`, `tar` and `pkg-config`; both XC8/DFP analysis include pairs and
  device-geometry INIs; the complete simavr/gpsim header sets; and all four
  fetched ATtiny202 DFP files are checked before success. Required files must be
  regular and nonempty. Live probes additionally exercise avr-libc preprocessing,
  simavr/libelf and both gpsim C++ link paths, complete yasimavr target-module
  imports, PyYAML and the selected AWK. Selected repository-relative paths are
  normalized before preflight, builds and mutation consume them.

  Make no longer interpolates `VERSION` or `RELEASE_ARGS` into release recipe
  shell syntax. GNU Make exports those values and the release script validates or
  splits them without `eval`, so malformed values cannot execute before semantic
  version validation. Git status, local-tag, origin-configuration and remote-tag
  failures are distinguished from clean/absent state, and the preflight gate's
  fake Git rejects every modifying operation.

- **`DESIGN_DOCUMENTATION.adoc` traces its load-bearing decisions to vendor
  documentation.** A new **Datasheet References** section: each decision against
  its DS40001585 / ATtiny13A reference *and* against the place in the repository
  where the as-built value is enforced. That third column is what keeps the
  table from rotting into prose — every row is checked by something that fails a
  build or a test if the value drifts (a `static_assert`, the runtime
  configuration sanity check, or the CONFIG word read back out of the built HEX
  by `make pic10f322-test-config`).

  Eight rows, all from sources already confirmed in-tree rather than re-derived:
  WDT time base (**OS09**, LFINTOSC 31 kHz ±25%), WDT period tolerance (**param
  31**, −37%/+69%), WDT period (`WDTCON`, **Register 5-1**), oscillator
  (`OSCCON`, `IRCF` = `0b100` → 2 MHz), the 1 ms Timer2 tick, brown-out
  (`BORV`), quiescent current (**D017–D019**), and the ATtiny13A sleep wake-up
  ordering (**§7.3**).

  The AVR Classic and AVR-XT *electrical* parameters — BOD fuse levels, the
  ~16 ms post-reset watchdog window, `WDTON`, the internal-RC ±10% tolerance and
  the Timer0 CTC divisor — are **not** cited, because no citation for them exists
  anywhere in this repository and a guessed section number in a reference-grade
  document is worse than an absent one. All five are as-built and enforced by the
  fuse-injection contract and the timing gates, so this is a traceability gap
  rather than a correctness one; the section says so explicitly so the table
  cannot be over-trusted, and the remainder is tracked in `TODO.md`.

  Settled while writing it: the two in-tree descriptions of the `IRCF` field
  disagreed on notation (`IRCF<2:0>` in `docs/phase2_pic_shell.md` §2,
  `IRCF<6:4>` in `src/bypass_mcu_pic10f322.c`). The DFP header is authoritative —
  `_OSCCON_IRCF_POSN` = 0x4, `_SIZE` = 3, `_MASK` = 0x70 — so it is a 3-bit field
  at register bits 6:4 and both spellings are correct in their own notation. The
  table records that rather than silently picking one.

- **`make test` now fails if the Makefile sets environment for a child process
  that no longer reads it.** Axis E of the name-contract family, and the only
  one of the five with a defect already behind it rather than a review: the
  PIC10F320 gpsim lanes simulated a PIC10F322 for an entire release because a
  shared wrapper's `PIC_GPSIM_PROC` read was re-spelled for one part while all
  four Makefile writers kept the old name. The assignment stayed legal, silent
  and inert, and the child fell back to its own default. 98 channels over 154
  write sites, every one verified to reach a reader; 44 checks total, 2.3 s.

  Checked per **link**, not per name — every `NAME=value <child>` site must
  reach a file that reads `NAME`. Per-name is measurably too weak:
  `ATTINY202_FUSE_WDTCFG` is written at five sites, and the one pointing at the
  fuse reader's own unit test (which names it literally) covers the four real
  consumers being severed at once. Verified — the per-name form passes that
  mutation, the per-link form fails it.

  The reader search is **transitive**, which is required rather than a
  refinement: a direct-read check reports two *correct* channels as severed,
  because `AWK` is written for a wrapper whose read lives in the gate it runs
  and `BYPASS_MODEL_FFI` for a Python driver whose read lives in a module it
  imports. A child inherits the environment, so the reader is anywhere
  downstream.

  Two shapes the obvious implementation misses, both live in this tree. A
  channel can hide behind a make variable — `$(XT_FUSE_ENV)` expands to seven
  `ATTINY202_FUSE_*` assignments that appear nowhere in the recipe text. And a
  reader can *build* the name rather than write it: `attiny202_fuses.py`
  computes `"ATTINY202_FUSE_" + name` over a table, so no literal spelling of
  any of the seven exists in the file that reads them. Both are resolved, and
  the computed reads are counted separately rather than blessed.

  Separating a channel from a shell local turned out to need a real recipe
  tokenizer, not a word split: `NAME=$(MAKEVAR)` — the shape of every channel
  here, including the severed one — reads as a command substitution to a naive
  splitter and vanishes from the harvest, while `rc=$$?` and `out=$$(…)` read as
  channels. The distinction is structural, not conventional: a prefix is an
  assignment *followed by a command*; a local is the whole statement. On this
  Makefile that rule alone separates them perfectly — 98 channels, none
  lowercase, and every lowercase name among the 40-odd locals it drops.

  A channel whose consumer cannot be resolved **fails** rather than being
  skipped, since a skipped check reporting as a pass is this gate's own defect
  class. The two genuine external consumers (`PYTHONPATH`, `PYTHONWARNINGS`,
  both read by CPython at startup) are listed with their reasons and expire like
  every other exemption. The reverse direction — a script reading a name nothing
  sets — is deliberately not bundled: a script legitimately reads names an
  operator sets by hand.

  Verified against seven mutations, including a re-creation of the original
  defect: renaming the sourced wrapper's read while leaving the Makefile writes
  reports `PIC_GPSIM_PROC` severed with the write line and the child named.

- **`make test` now fails if any `NAME=value` handed to make names a variable
  the Makefile does not know.** A make override naming no existing variable is
  legal and silent — the value is ignored and the default applies — which is how
  a renamed `SOAK_*` left one mutant asking for 2 s of simulated soak and
  getting the 24 h default for an entire release. New gate
  `test-makefile-name-contract` (`test/test_makefile_name_contract.py`), axis C
  of the four-axis name-contract item in `TODO.md`; 74 overrides verified.

  The Makefile gains an `origin-%` rule beside `print-%`, plus a bulk
  `make origins NAMES="…"` form that resolves a whole harvest in one invocation.
  `$(origin)` is the oracle because non-emptiness cannot work here:
  `XT_SOAK_COMBINATION_NAME` and `AVR_STACK_BUILD_DIR` are defined-but-empty by
  design. The contract is *defined **or** consumed*: `$(origin)` alone reports
  a command-line-only input such as `VERSION` as `undefined`, so the Makefile's
  own `make release VERSION=v1.0.0` usage line would otherwise read as severed.

  The gate is verified by reproducing the defect it exists to prevent: reverting
  the mutation row to its pre-rename spellings makes it name all four severed
  overrides and fail. That check matters because the specification this gate was
  built from would **not** have caught that defect — it called for harvesting
  "lines invoking make", and the row in question is a data row in a mutation
  table with no `make` token on it at all. The mutation tables are enumerated as
  their own source, and the gate asserts it found overrides there.

  Harvesting only what follows the make word — assignments *before* it are
  environment for make's children, not claims about the Makefile — cut the
  expected allowlist from seven-plus names to one (`MUTATION_ALLOW_SKIP`), and
  every exemption must still be reached by the harvest, so exemptions expire
  rather than accumulate.

  **Documents are in scope too**, which they were not when this axis was first
  built. The original harvest read `test/`, `scripts/`, `.github/` and the
  Makefile — where the *machine-facing* overrides live — and that scope left the
  human-facing half of the same defect unchecked by any of the four axes.
  `MISRA_COMPLIANCE.md` tells a maintainer to run `make analyze-misra
  VARIANTS="…" STRICT_TOOLS=1`; `README.md` documents `make attiny202-program
  VARIANT=<v>`. Axis D reads doc prose, but only for names inside the project's
  variable *prefixes*, and `VARIANTS`, `VARIANT`, `STRICT_TOOLS`, `VERSION` and
  `PIC10F322_PROG` are all unprefixed — so nine names in six live documents were
  reachable by no axis at all. Anchoring on the make word, which this axis
  already did, is what let the scope widen without needing a vocabulary list to
  keep the false-positive rate survivable: two lines needed an exemption marker,
  both of them in `TODO.md`'s specification of this very item. The gate now
  fails if it stops finding overrides in documents, for the same reason it fails
  if it stops finding them in the mutation tables.

  This is the fifth widening, and — like the four before it — it was found by
  looking rather than by a gate, in the place the *previous* scope did not
  reach.

- **The same gate now also fails if any `make print-<VAR>` query asks for a
  variable the Makefile does not define.** `print-%` is a pattern rule, so it
  matches *any* name: ask it for a variable that no longer exists and it prints
  an empty line and exits 0. The `v0.9.8` rename left three such reads in
  `scripts/make-release.sh` pointed at removed names, and nothing failed — the
  effect would have surfaced only in the published artifact, at the end of a
  24-hour release run, as a `MANIFEST.md` with empty ATtiny13a and tinyx5 fuse
  bytes and one image path composed as `bypass--<stage>.hex`. Axis A of the
  same four-axis item; 65 queries verified.

  Both spellings are harvested — direct `print-<VAR>`, and the `mkv` wrapper in
  `scripts/make-release.sh`, which passes the name as a bare word — and it
  fails if either stops producing hits, because the historical defect was in
  the wrapper form only. Computed names (`mkv part_"$n"`) are expanded over the Makefile
  variable supplying their keys and checked; a computed name the gate cannot
  expand is a failure rather than a skip.

  A read is held to a **stricter** contract than an override: it must be
  *defined*, not merely defined-or-consumed. A command-line-only input such as
  `VERSION` is legitimate to set but useless to ask for, since the query returns
  an empty line.

  Historical documents are exempt by **self-declaration** rather than by a
  hardcoded list: nine markdown files already open with a banner calling
  themselves historical records, and that banner is what the gate keys on — so a
  new historical document is exempt the day it is written, and deleting the
  banner puts the document back under the contract. Only `CHANGELOG.md` is
  exempt by name, because naming a variable that no longer exists is a changelog
  working correctly. Verified by restoring the `v0.9.7` spellings in
  `scripts/make-release.sh`: the gate names all five severed reads with their
  line numbers and fails.

- **The same gate now also fails if any documented `make <goal>` names a goal
  that does not exist, or if any prose or diagnostic names a variable that does
  not.** Axes B and D, closing the four-axis name-contract item. 36 checks in
  total, 0.6 s: 66 variable queries, 356 documented commands, 74 overrides and
  68 variable mentions. Each new axis found a live defect on its first clean
  run — `.gitignore` named `make pic-test-soak`, a goal the `v0.9.8` rename
  removed, in the comment explaining which goal produces the file it ignores;
  and a `Makefile` comment described the PIC soak's knobs as a family no
  variable belongs to.

  Axis B is the only one of the four whose failure is loud — `No rule to make
  target` — which is exactly why it has to be caught before a reader is the one
  who finds it. The `v0.9.8` rename left 15 dead goals in
  `docs/pic10f320_validation.md` alone, a document framed as *current*
  qualification evidence, including its entire "Reproducing any of this"
  section, where four of six commands failed.

  Goals resolve against `make -rRn --print-data-base`, parsed once. Reading
  make's own inventory rather than grepping rule heads is what makes the
  generated families resolvable at all: `attiny85-program` and
  `test-sim-cd4053_simple-attiny13a` exist only after `$(eval $(call ...))`
  expansion. Goal *schemas* are expanded rather than skipped — `make
  test-sim-<variant>` is resolved over `$(VARIANTS)` and every expansion must
  exist, which is the check that catches the sharpest `v0.9.8` casualty, a
  documented goal identified by the *omission* of its MCU field.

  Precision was the whole problem on axis B and is worth recording: English
  follows the word "make" constantly, so a harvest reading every line containing
  it reported **881** distinct tokens ("sure", "the", "a") against about a dozen
  real ones. Three rules take that to zero — read only command contexts, require
  the make word to *open* its fragment (`apt-get install -y make util-linux`
  installs a package), and take only the first goal word.

  Axis D reads prose only, never executable lines: this tree has over 150 shell
  locals, C macros and CI keys sharing the project's variable prefixes, so a
  prefix alone cannot identify a Makefile variable. Family references are
  checked as prefixes — `PIC320_*` asks whether any known variable begins with
  `PIC320_` — because testing the stem as a name reports correct references like
  `AVR_SOAK_*` as severed.

  Live documents legitimately name retired names: redirect tables, recipes
  pinned to an older tag, quoted transcripts, and sentences whose point is that
  a name is gone. Those carry a per-line or per-block `name-contract: exempt`
  marker with a reason; published release artifacts under `release/v*/` are
  exempt by path, since they are immutable records nobody should edit. Every one
  of the 21 markers must still suppress something or the gate fails, so
  exemptions expire rather than accumulate.

- **Every static-analysis target now rejects an unrecognised `VARIANTS=`
  instead of quietly analyzing less.** `analyze-tidy`, `analyze-cppcheck`,
  `analyze-deep`, `analyze-misra` and `analyze-misra-report` all analyze
  `$(FW_SOURCES)`, which maps `$(VARIANTS)` through `src_<variant>` — and an
  unrecognised name maps to *nothing*. A typo therefore did not fail: it shrank
  the subject and the analyzer honestly reported the smaller set clean. All five
  now carry `classic-variant-request-valid`, the same guard the build targets
  (`attiny13a`, `attiny85`, …) already had. Recognised **subsets** remain valid —
  analyzing one driver is a normal development request.

  This is the class behind the `MISRA_COMPLIANCE.md` defect under *Fixed*
  below, where the documented compliance command analyzed zero of the three
  output drivers and exited 0. Fixing the document removed the instance; the
  guard removes the class, which matters most for exactly these targets: an
  analyzer is believed, so an analyzer reporting on a set nobody chose is worse
  than one that does not run.

  New gate `test-analyze-variant-guard`
  (`test/test_analyze_variant_guard.sh`, in `make test`), 19 checks in 0.3 s,
  built in two halves because either alone leaves the hole open. The
  behavioural half proves all five reject the empty, unknown and duplicate
  requests, and reject *before* analyzing — a partial analysis that stops early
  still prints findings a reader could mistake for a verdict. The contract half
  walks the Makefile's rules and requires the guard on **every** target that
  consumes `$(FW_SOURCES)`, including ones added later; a guard that needs a
  human to remember to extend it has the same failure mode as the thing it
  guards.

  One subtlety the gate had to be built around, since it is what made the first
  version of it measure nothing: the serialization wrapper re-execs make under
  `flock` and hands the inner invocation its request's verdict through the
  *environment*, because it also sanitises `VARIANTS` on the way down. Correct
  for its own recursion — by then the bad names are gone and only the inherited
  flags still remember they were typed — but wrong for an independent nested
  make started by a test, which inherits `make test`'s verdict ("clean") and
  applies it to a request make never saw. Left set, every rejection became an
  acceptance. The gate clears those flags by *harvesting* their names from the
  Makefile, pins the lock-held condition so a standalone run and a `make test`
  run exercise the same thing, and carries a control proving the clearing is
  load-bearing rather than decorative.

  Verified by reproducing the original defect: with the guard removed,
  `make analyze-misra VARIANTS="cd4053 mute relay"` checks 2 files, reports
  `MISRA-C:2012: clean` and exits 0. With it, nothing is analyzed and it exits
  2.

- **Every lane that selects *one* output stage now rejects an unrecognised
  selector instead of skipping.** `VARIANTS` is a list and has been guarded for
  releases. The sixteen variables that pick a single stage or chip for a single
  lane — `PIC10F322_SOAK_VARIANT`, `PIC10F320_IO_VARIANT`, `AVR_SOAK_VARIANT`,
  `AVR_SOAK_CHIP`, `VARIANT` and the rest — had no guard at all, and an
  unrecognised value there composes a path to a file nothing builds, which the
  lane reports as a *missing toolchain*:

  ```
  $ make pic10f322-test-soak PIC10F322_SOAK_VARIANT=relay
  no build_pic10f322/bypass-pic10f322-relay.hex (XC8 absent?); skipping ...
  $ echo $?
  0
  ```

  XC8 was installed; the request was a typo carrying the pre-`v0.9.8` stage
  vocabulary. `STRICT_TOOLS=1` (CI, release) turns that skip into a failure with
  the same wrong diagnosis, so it moved the cost rather than removing it. Same
  class as the analyzers above — and the same shape as the PIC10F322 soak driver
  under *Fixed*, which "degraded to a skip, not a failure" for a whole release.
  A skip is the dangerous outcome precisely because it is indistinguishable from
  an honest one.

  New `variant-selectors-valid` guard, wired as the **first** prerequisite of
  all 30 consuming rules (order-only for the one file target, so a phony
  prerequisite cannot make it look perpetually out of date). It validates every
  selector on every invocation, not just the one the requested goal reads: an
  override naming a value no lane supports is inert wherever it lands, and inert
  overrides are the defect class. `XT_SIM_VARIANT` stays out of the table —
  empty means "every supported variant" there, so it is list-or-empty and
  already validates itself in each of its four recipes.

  New gate `test-variant-selector-guard`
  (`test/test_variant_selector_guard.py`, in `make test`), 14 checks in 1.5 s,
  in the same two halves as its analyzer sibling: the behavioural half proves
  all three malformed shapes are rejected (unknown, empty, more-than-one) and
  that the real lane above now fails naming the selector and never prints the
  skip; the contract half proves the guard is still attached to every rule that
  consumes a selector.

  The contract half needs a **transitive closure**, and that is the whole
  difficulty: almost no rule mentions a selector directly. `pic10f322-test-soak`
  reads `$(PIC10F322_SOAK_HEX)`, composed from the selector three definitions
  away. A harvest keyed on the selector names alone finds 17 of the 31 rules
  that actually depend on one — and the fourteen it misses include every
  PIC10F320 lane. It also has to join backslash continuations before parsing
  rule heads, which the first draft did not: `test-soak-reset-witness` carries
  its prerequisites on a continued line and was classified as consuming no
  selector at all, the same physical-line mistake axis C of the name contract
  made.

  It found a live one on its first clean run:
  `test/test_target_lane_markers.sh` defaulted `LM_VARIANT` to `mute`, a
  pre-`v0.9.8` stage token passed to the *real* make, inert only because nothing
  had ever checked it.

  Adding a second guard to `analyze-misra` also broke the analyzer gate's
  negative fixture, which pinned the guard to the *first* prerequisite position
  by exact text — it reported the spelling change as a missing guard, correctly
  and unhelpfully. That fixture is now position-independent, so the next guard
  added to that rule does not fail it.

- **The firmware's compile-time guards are now proven to actually fire.** Every
  build checks the `static_assert`s in the config headers and MCU shells, but
  only in the sense that they stay silent — and a guard still enforcing its
  invariant is indistinguishable from one that has been defused, because both
  are silent and both build green. Reorder a header so the constants arrive
  after the check, drop an `#include`, weaken `>` to `>=`, comment one out
  during a debugging session: nothing notices. New gate
  `test-static-assert-guards` (`test/test_static_assert_guards.sh`, in `make
  test`), 27 checks in 0.3 s — 24 guards counted, 9 mutations proven to trip
  one. The firmware itself is never modified; mutations are applied to a
  throwaway copy of `src/`.

  The guards' **inputs** are broken, never the guards: a mutation editing a
  `static_assert` line would prove only that the compiler implements
  `static_assert`. Breaking a threshold, a pin ordinal, the Timer0 constant or a
  build flag is what a real regression looks like. One mutation is not a source
  edit at all — dropping `-fshort-enums` is how the enum-width guards actually
  get defeated, and no edit to `src/` can express it.

  Mutations alone cannot catch a **deleted** guard, and the first version of
  this gate demonstrated that by missing one: guards come in families sharing a
  diagnostic (three enum-size asserts all say `use -fshort-enums`, seven pin
  asserts all fail the same build), so deleting one leaves a sibling to trip the
  mutation. A per-file guard census closes it — a deletion fails, and so does an
  addition, which forces a decision about whether the new guard needs a
  mutation.

  Three preconditions are checked rather than assumed, since without them the
  whole exercise measures nothing: the unmutated tree must compile, each
  mutation must actually change its file (`TIMER0_OCR0A_1MS` is defined with
  leading whitespace inside an `#if`, and the first draft's pattern silently
  matched nothing), and the failure must carry the guard's own message.

- **A mechanically stuck footswitch is now an enforced guarantee rather than a
  documented intention.** `DESIGN_DOCUMENTATION.adoc` states under Caveats and
  Limitations that "by design, no recovery is currently provided for a
  mechanically stuck switch" — a promise in both directions, since it also means
  no spontaneous *second* toggle while the fault persists. Only the first half
  was ever framed as intentional, and the second half is the one a player would
  notice. `test_stuck_switch_no_recovery()` drives the input low for six
  simulated hours in each of the two ways a switch sticks closed — after a
  normal press (one toggle, parked `ENGAGED`) and already stuck at power-on (no
  toggle at all, parked `BYPASS`) — then asserts recovery once the fault clears.

  Recorded because the obvious reading is wrong: the duration is *not* where the
  strength comes from. The model is finite-state with a counter bounded at
  `RELEASE_THRESH`, so a held-low input reaches its fixed point within
  `RELEASE_THRESH` ticks. Deleting the integrator's saturation — the counter
  wrap this looks like it exists to catch — is already caught by sixteen other
  assertions in the file. What is new is the shape: the power-on-stuck case is
  driven over time at all (`test_power_on_pressed` checked the instant after
  `init()` and nothing after), invariants are checked every tick rather than at
  the end, the counter is pinned to its saturated value, and recovery is
  asserted so "no recovery" cannot decay into "left corrupt". The six hours cost
  0.2 s and buy a standing guard against a future unbounded accumulator, the one
  defect class a long run sees and a short one cannot.

  Subject is the golden model — the *oracle*, not the firmware. The shipping
  integrator is covered more strongly than any run can manage: `test_cbmc.c`
  (C1) proves `debounce_integrate()` saturates for every admitted input. The gap
  was that the simavr tests judge the firmware by comparing it against this
  model, so a model that drifted would make a firmware that drifted look right.

- **The fuse checker can no longer pass without reading the Makefile.**
  `test/avr/test_fuses.c` decodes the exact fuse bytes this Makefile burns and
  is the only thing standing between a fat-fingered fuse edit and a bench
  session. It declared itself the single source of truth for those bytes and
  then defined `#ifndef` fallbacks for all eleven — **ten of them exactly the
  current values**. Compiling with the real `-D` set minus `-DT85_LFUSE`, which
  is what renaming a macro on either side produces, printed `fuse checks: 46
  checks, 0 failures` and exited 0. Only `T13_LFUSE` failed, and only because
  its fallback had gone stale (`0x6a` against a current `0x4a`); nothing
  designed that.

  `-D<MACRO>=$(VAR)` is a name contract the four axes above deliberately do not
  cover — the C macro names are the tests' own interface and were not renamed
  with the Make variables in this release — so nothing joined its two halves.
  The eleven fallbacks are now `#error`s, each naming the Makefile variable its
  byte comes from, which is the fail-closed rule the ATtiny202 half of the same
  gate already followed (`attiny202_fuses.py` raises rather than defaulting on a
  missing `ATTINY202_FUSE_*`).

  New gate `test-fuse-injection-contract`
  (`test/test_fuse_injection_contract.py`, 14 checks) follows each byte the
  whole way: the variables the avrdude recipes burn to silicon must be exactly
  the variables the checker is compiled with; the compile line and the C file
  must name the same macros, with each `#error` naming the variable the Makefile
  really pairs it with and no macro carrying a default; every injected byte must
  reach the program's output, one for one; and each printed byte must equal
  `make -s print-<VAR>`.

  Two of those links exist for reasons worth recording. *Burned == injected*
  because proving the checker reads the Makefile is not the same as proving it
  reads the byte anyone flashes — a checker verifying a byte no flash target
  burns is decoration and looks identical from the inside. *Printed == the
  Makefile's value* because it is the only link that catches a value drift as
  well as a name one, and it is not redundant with the checker's own assertions:
  `T13_LFUSE` bit 6 is EESAVE, which no assertion in the file reads, so an lfuse
  that disagrees with the Makefile in that bit alone passes all 46 checks. The
  gate builds exactly that binary and requires the round trip to catch it.

- **The release's headline claim is now checked, and the check is retained.**
  This changelog states in three places that the eighteen renamed images are
  bit-identical to their `v0.9.7` counterparts — "only the filenames moved" is
  the entire premise of the release — and nothing in the tree recorded that
  anyone had confirmed it. Every other claim under `release/` is backed by a
  retained artifact.

  `scripts/verify-rename-identity.sh` first verifies that the pinned release key
  signed the exact `release/v0.9.7/SHA256SUMS` bytes, then hashes every image this
  release builds against the entry for its old name through the published
  old-to-new table in `release/README.md`, and emits the per-image table as the
  evidence document. Missing, empty, symlinked, malformed, wrong-key, or stale
  signatures all fail before any baseline hash is parsed.
  `scripts/make-release.sh` runs it in step 1 — before the 24-hour soak, so a
  changed byte costs seconds rather than a day — and stages the result as
  `release/v0.9.8/RENAME_IDENTITY.md`. Result on the current tree: **18
  identical, 0 differ, 0 missing**.

  Tag CI does not trust that retained report on sight. After rebuilding all
  release images from the tagged source, it regenerates the report from those
  exact clean-build paths and requires a byte-for-byte match with the committed
  `RENAME_IDENTITY.md`. Missing, empty, non-regular, stale or altered evidence
  fails publication; once the rename table no longer applies, the same check
  requires no report and rejects a stale one.

  The verifier retains its exact regenerated bytes directly in the frozen
  publication directory and reports their SHA-256 through the workflow's step
  outputs. Immediately before `gh release create`, CI rechecks that digest and
  conditionally adds `RENAME_IDENTITY.md` to the asset array. Later releases
  route an explicit inapplicable state and continue to publish without it.

  Three decisions are what keep this from becoming a liability later. It is
  **not a standing gate**: pinning current images to a *previous* release's
  hashes is correct for exactly one release, and turns into a false alarm the
  first time a release legitimately changes a byte (the standing form of the
  check is per-release and already exists). It **holds no version of its own**,
  reading both from the rename table's own header, so it reports "not
  applicable" and does nothing for any other release and needs no maintenance to
  retire. And it **restates no part of the mapping**, parsing the table users
  actually follow, so the rows that were verified cannot drift from the rows a
  reader is given.

  It is also deliberately not retained under `evidence/`, whose contents are
  pinned exactly by `RELEASE_EVIDENCE_FILES` for *every* release: a file only
  one release produces would fail the next release's qualification verifier.

- **Three more places still spelled a name this release moved.** The published
  `MANIFEST.md` took the ATtiny85/45 programmer name from a literal (`t85` /
  `t45`) while `make-release.sh` read `part_85` / `part_45` from the Makefile
  into an array nobody used — the `mkv` preamble validating a value it then
  discarded. The array is now wired into the manifest arm, indexed by the part
  number the arm already computes.

  `test/run_mutation_tests.sh` composed the PIC10F322 image path from three
  restated defaults (`FW_BASE`, `PIC10F322_TAG`, `PIC10F322_BUILD_DIR`); it now
  resolves the path once from `PIC10F322_BUILD_DIR` +
  `PIC10F322_RELEASE_IMAGES`, so an output stage that no longer exists fails at
  startup by name rather than as a missing file per mutant — which is the
  dangerous shape, since a missing image makes each PIC mutant return the
  infrastructure-error status and the lane degrade to a skip.

  And `make clean` now removes a pre-rename `build_pic/`, which `.gitignore` no
  longer covered either: XC8's `.p1`/`.d`/`.sdb`/`.sym`/`.cmf` intermediates
  match none of its global patterns, so a worktree upgraded from `v0.9.7` would
  offer them to `git add -A` forever.

### Changed
- **A `-D` macro a test harness must be told is now a build error when it is not
  told, instead of a plausible default.** The C-side twin of the name-contract
  axes: the Makefile injects 56 macros, 26 of which had `#ifndef` fallbacks that
  a severed injection would reach silently. Every such fallback was a correct
  value for *some* combination, which is exactly what made them dangerous —
  `test/avr/test_soak.c` would have answered a severed `-DSOAK_DURATION_MS` with
  24 h, the same 43,200× overrun this release already fixed on the make side,
  and a severed `-DFW_PATH` with a real ELF that is simply not the one the run
  reported soaking.

  Now 15, each in a category with a stated reason. Hardened to `#error`, every
  one naming the Makefile variable its value comes from: `FW_PATH` (6 sites),
  `F_CPU_HZ` (4), `MCU_NAME` (2), `PROC_NAME` in the shared PIC soak,
  `PIC_DEVICE_NAME`, and all four soak knobs. The `PIC_*_DEFAULT_FW_PATH`
  adapter macros went with them — an image path is an output-stage fact the
  Makefile selects, not a part fact the adapter owns, and defaulting it looked
  like the second only because it sat next to `PROC_NAME`, which genuinely is.

  **Two more instances of the shared-source shape** that produced the
  `PIC_GPSIM_PROC` defect above turned up here and are the reason this landed in
  the same release: `test_soak_pic.cc` is compiled for BOTH PIC parts and
  defaulted `PROC_NAME` to `p10f322`, so a severed injection would have soaked a
  PIC10F320 image on a p10f322 model for 24 hours; `test_config_pic.c` serves
  both lanes and defaulted its device label to `PIC10F322`. The per-part
  harnesses keep their adapter default for `PROC_NAME` precisely because they
  have one adapter per part — one source with two callers must have no fallback,
  one source per part may.

  **`test_sim.c`'s ATtiny13a lane was the last place a part was identified by
  the omission of a field.** The tinyx5 rules injected `MCU_NAME` and
  `F_CPU_HZ`; the ATtiny13a rules injected neither and let the file's own
  defaults answer — and that `MCU_NAME` default was `attiny13`, a spelling the
  rest of the tree retired, which simavr happens to accept. Both ATtiny13a rules
  now pass `ATTINY13A_MCU` and `ATTINY13A_F_CPU`; check counts are unchanged.

  **Two groups deliberately keep their fallbacks, and now say why.** The 13
  `SIM_*` / `MODEL_FUZZ_*` workload knobs are load-bearing: `FULL_SIM_DEFS` and
  `FULL_HOST_DEFS` are empty, so `make test-long` reaches the exhaustive
  workload by *not* overriding them, and an `#error` would have failed the
  release gate. And `PB0`/`PB1`/`PB2`/`F_CPU` turned out not to be severable
  injections at all — `CBMC_DEFS` is their only injector, so the hazard is the
  reverse one: the pin map exists in two or three copies and nothing compared
  them, which would let cbmc go on proving the firmware against a map the shim
  no longer holds and report it as a pass. Closed in C rather than with a new
  gate — the canonical value is named once and `_Static_assert`ed against
  whatever was injected. Verified by drifting `CBMC_DEFS` `PB1` from 1 to 3:
  `test-cbmc` fails by name.

- **Every released firmware image is renamed to one consistent scheme.** All
  eighteen images on all six MCUs are now
  `bypass-<mcu>-<output stage>.hex` — three hyphen-separated fields, with
  underscores between words inside a field:

  ```
  bypass-attiny85-cd4053_with_mute.hex
  bypass-pic10f320-tq2_l2_5v_relay.hex
  ```

  `<mcu>` is one of `attiny13a`, `attiny45`, `attiny85`, `attiny202`,
  `pic10f320`, `pic10f322`; `<output stage>` is one of `cd4053_simple`,
  `cd4053_with_mute`, `tq2_l2_5v_relay`, matching the driver source basenames.
  The mixed delimiter is deliberate: stage tokens are multi-word, so an
  all-hyphen name could not be split back into fields without hardcoding the
  MCU vocabulary.

  This replaces three coexisting conventions — the `bypass_` vs `bypass_mcu_`
  prefix split, the `cd4053`/`mute`/`relay` vs
  `cd4053-simple`/`cd4053-mute`/`tq2-relay` stage-token split, and a part suffix
  that was `_t45`/`_t85`/`_attiny202`/`_pic10f322`/`_pic10f320` **or absent**.
  That last case is what motivated the change: a bare `bypass_cd4053.hex` *was*
  the ATtiny13a image, identified by omission, and nothing in the filename
  stopped a builder flashing the 1.2 MHz ATtiny13a build onto an ATtiny85. The
  MCU field is now mandatory on every image, so the 6 × 3 product matrix is
  visible in a plain directory listing.

  **Image contents are unchanged.** Each image is bit-identical to its `v0.9.7`
  counterpart; only the filenames moved. `release/README.md` carries the full
  old→new mapping table.

  Historical `release/vX.Y.Z/` directories are **not** renamed. Their
  `SHA256SUMS` names the files and is covered by a detached signature, so
  renaming them would invalidate published signatures.

  An existing source worktree is different: current build targets create the
  new names but do not remove differently named images from an older build.
  Builders upgrading a checkout that built `v0.9.7` or earlier are therefore
  told, in both Quickstart and the published rename section, to run `make clean`
  once before the first new build. `test-clean-contract` pins the exact four
  current default build directories plus retired `build_pic/` that cleanup
  removes; the guidance also maps paths supplied through renamed PIC
  build-directory variables onto their current cleanup variables.

  Internals: the spelling is composed in exactly one place, the Makefile's
  `$(call fw_image,<variant>,<mcu-tag>)`, backed by an `IMAGE_STAGE_*` map with
  a parse-time completeness check over both supported variant sets — a supported
  variant with no mapping is now a Makefile error rather than a release image
  that goes missing after a 24-hour soak. `PIC320_FW_BASE` (`bypass_mcu`) is
  retired; that lane shares the one `FW_BASE` and is told apart by its MCU
  field. `scripts/make-release.sh` keeps its own independent restatement of the
  scheme on purpose, because it is cross-checked against the Makefile's
  `RELEASE_IMAGES` and a derived copy could not disagree.

  The `MANIFEST.md` generator's per-image dispatch was order-dependent and ended
  in a bare `*.hex` ATtiny13a fallback, so an unrecognized name produced a row
  confidently labelling foreign firmware as an ATtiny13a with AVR fuse bytes. It
  now matches on the mandatory MCU field, making the arms mutually exclusive,
  and an unrecognized image is a hard error.

- **One output-stage vocabulary everywhere, replacing three.** The variant
  names themselves are now `cd4053_simple`, `cd4053_with_mute` and
  `tq2_l2_5v_relay` — the same strings the driver sources and the published
  image field use. Two internal vocabularies are retired: the classic-AVR and
  AVR-XT lanes' `cd4053`/`mute`/`relay`, and the PIC10F320 lane's inherited
  `cd4053-simple`/`cd4053-mute`/`tq2-relay`, which named the same three output
  stages in different words.

  This is a **breaking change to command lines and make goals**:

  | before | after (see also the prefix change below) |
  |---|---|
  | `make VARIANT=relay program` | `make VARIANT=tq2_l2_5v_relay attiny13a-program` |
  | `make PIC320_VARIANT=cd4053-mute pic320` | `make PIC10F320_VARIANT=cd4053_with_mute pic10f320` |
  | `make test-sim-mute` | `make test-sim-cd4053_with_mute-attiny13a` |
  | `SOAK_VARIANT=relay` | `AVR_SOAK_VARIANT=tq2_l2_5v_relay` |

  Release soak combination names change with it, and so therefore do the
  retained evidence filenames: `evidence/soak-avr_cd4053_t85.log` becomes
  `evidence/soak-attiny85_cd4053_simple.log`, `soak-pic320_tq2-relay.log`
  becomes `soak-pic10f320_tq2_l2_5v_relay.log`, and so on for all fifteen.
  Evidence already committed under `release/v0.9.7/` and earlier is untouched.

  The longer tokens cost more typing, once per command line. What they buy is
  that a variant name cannot be valid in one lane and meaningless in another,
  which is what `cd4053-mute` versus `mute` was.

  The `IMAGE_STAGE_*` map added earlier in this release is **deleted**: with
  the vocabularies unified it was the identity function. So are its two
  downstream copies — `stage_of()` in `scripts/make-release.sh` and `pb_image()`
  in `test/test_pic_build.sh` — and the stage-to-variant table in the ATtiny202
  delay oracle. A translation table is a place where two names can disagree;
  removing the need for one is a stronger guarantee than maintaining it
  correctly. What replaces it as the parse-time guard is a completeness check
  that every supported variant, in every lane, has a `macro_<v>` selector and a
  `src_<v>` driver. That check deliberately does *not* require the three lanes'
  supported sets to be equal — a future output stage that fits the ATtiny13a but
  not the 12-free-words PIC10F320 is a legitimate divergence.

  Image contents are again unchanged: all 18 remain bit-identical to `v0.9.7`.

- **Every make goal that acts on one part is named after that part.** The goal
  vocabulary now matches the image field exactly: `attiny13a`, `attiny45`,
  `attiny85`, `attiny202`, `pic10f322`, `pic10f320`.

  | before | after |
  |---|---|
  | `make all13` / `all85` / `all45` | `make attiny13a` / `attiny85` / `attiny45` |
  | `make size` / `size85` | `make attiny13a-size` / `attiny85-size` |
  | `make fuses` / `flash` / `program` | `make attiny13a-fuses` / `-flash` / `-program` |
  | `make readfuses` / `trace` | `make attiny13a-readfuses` / `-trace` |
  | `make program85` | `make attiny85-program` |
  | `make pic` / `pic-test` | `make pic10f322` / `pic10f322-test` |
  | `make pic-analyze` | `make pic10f322-analyze` |
  | `make program-pic` | `make pic10f322-program` |
  | `make pic320-*` | `make pic10f320-*` |
  | `make test-sim` / `test-sim-t85` | `make test-sim-attiny13a` / `test-sim-attiny85` |
  | `make test-sim-secondary` | `make test-sim-tinyx5` |

  Two defects motivated this, and they are the same defect at different ages.
  `pic-` meant PIC10F322 only because that part arrived first, so `pic-test-soak`
  and `pic320-test-soak` sat one near-name apart with nothing in either name
  saying which silicon it drove — the residual risk the PIC10F320 merge recorded
  and deferred (`docs/pic10f320_merge_plan.md` §15, D1). The classic AVR lane had
  the same shape one layer down: `flash`, `size` and `test-sim` were the
  ATtiny13a because it got there first, while every other part carried a name.

  A `pic-*` goal now means **both** PIC parts, which is what `test-pic-build`,
  `test-lockstep-progress` and `test-stack-bound-pic-regression` already did;
  they keep their names and are now accurate rather than ambiguous.
  `attiny202-*` was already part-named and did not move, and the `test-<mcu>-*`
  goals keep their word order: `attiny202-delay-oracle` runs the oracle against
  firmware while `test-attiny202-delay-oracle` runs the oracle's own selftest,
  a distinction the ordering carries.

  **`make all` now builds every part**, not just the ATtiny13a. A lane whose
  cross-toolchain is absent (XC8 for either PIC, the ATtiny_DFP for the
  ATtiny202) prints a named skip and does not fail, so a bare `make` still works
  on an AVR-only machine; `STRICT_TOOLS=1` turns each of those skips into an
  error, which is what release and CI use. Because the PIC lanes require the
  complete output-stage matrix, `make all VARIANTS=<subset>` is now rejected up
  front with the single-part command to use instead, rather than failing forty
  lines into the PIC lane's own matrix check.

  Release evidence filenames follow the goals: `build-avr.log` and
  `build-pic.log` become `build-avr-classic.log` and `build-pic10f322.log`,
  `pic-test.log` becomes `pic10f322-test.log`, and the fifteen soak combination
  names become one `<mcu>_<output stage>` pair each — `attiny85_cd4053_simple`
  rather than `avr_cd4053_simple_t85`, which had spelled the chip at both ends.

- **Chip-scoped Makefile variables carry their chip's name.** `PIC_*` names that
  held a PIC10F322 fact are now `PIC10F322_*`, and `PIC320_*` is `PIC10F320_*`.
  The cautionary case is the one the deferred TODO item named: `PIC_FLASH_WORDS`
  was 512, a 322 fact under a family name, and a variable mis-scoped that way
  produces no compile error and no failing test — it produces a *passing* one,
  because a 256-word image gated at 512 words passes.

  The rule is now stated in the Makefile and is two-tier rather than uniform: a
  `PIC_*` name with no part in it means **shared by both PIC parts**, and there
  are exactly nine of them plus four wrapper-script env parameters — one XC8
  (`PIC_CC`, `PIC_DFP`, `PIC_XC8_INCLUDE`), one C++ and gpsim header set, one
  soak driver source. Those are correct as they stand. `AVR_*` and `XT_*` are
  left alone for the same reason: they name the `avr_classic` and `avr_xt`
  families their shells are named for, and renaming `XT_*` to `ATTINY202_*`
  would break that correspondence rather than fix anything.

  The classic AVR lane had the unmarked-default problem here too, since
  `XT_SOAK_*`, `PIC10F322_SOAK_*` and `PIC10F320_SOAK_*` were all qualified
  while plain `SOAK_*` silently meant the AVR one. Renamed accordingly:
  `MCU`/`F_CPU`/`HFUSE`/`LFUSE`/`AVRDUDE_PART`/`AVRDUDE_FLAGS` →
  `ATTINY13A_*`; `F_CPU_X5`/`HFUSE_X5`/`LFUSE_X5` → `TINYX5_*`;
  `FLASH_T13_*` → `ATTINY13A_FLASH_*`; `SOAK_*` → `AVR_SOAK_*`;
  `PROGRAMMER` → `AVR_PROGRAMMER`; `STACK_SOURCES`/`STACK_MAX_FRAME`/
  `STACK_BUILD_DIR` → `AVR_STACK_*`; and `STACK_DEPTH_GATE`, which serves both
  PIC parts, → `PIC_STACK_DEPTH_GATE`. The PIC10F322 build directory moves from
  `build_pic/` to `build_pic10f322/`, matching `build_pic10f320/`.

  Names that are *not* chip facts keep their spelling — `SIM_DEFS`, `HOST_DEFS`,
  `COVERAGE_*`, `STRICT_TOOLS`, `VARIANT(S)` and the tool variables name a tool,
  a host facility or a project-wide policy, not a part.

  C-side contracts deliberately did **not** move: the compiler macros
  `-DF_CPU`, `-DSOAK_DURATION_MS`, `-DSOAK_COMBINATION_NAME` and the rest keep
  their names, because those are the firmware's and the test drivers' interface,
  not the build system's. Renaming a Make variable is nevertheless an external
  interface change — `scripts/make-release.sh` and `scripts/ci-local.sh` read
  Makefile truth through `make -s print-<VAR>` — so every `print-` consumer was
  swept with the rename and re-checked to resolve.

  Image contents are unchanged for a third time: all 18 remain bit-identical.

- **The tinyx5 soak selectors take a part name, not a chip number.**
  `AVR_SOAK_CHIP` and `AVR_SOAK_WITNESS_CHIP` were the last user-facing
  selectors that named a part by a fragment:

  | before | after |
  |---|---|
  | `make test-soak AVR_SOAK_CHIP=45` | `make test-soak AVR_SOAK_CHIP=attiny45` |
  | `make test-soak-reset-witness AVR_SOAK_WITNESS_CHIP=85` | `... AVR_SOAK_WITNESS_CHIP=attiny85` |

  The distinction the change draws is between the family's *internal* indexing
  and what a *request* may name. `TINYX5` remains `85 45`, because that is what
  indexes `mmcu_<n>`/`part_<n>` and generates the `attiny<n>`,
  `attiny<n>-size` and `attiny<n>-flash` goals. The new `TINYX5_PARTS` is that
  same family expressed as parts, derived (`$(foreach n,$(TINYX5),$(mmcu_$(n)))`)
  rather than restated, so a third sibling cannot enter one list and not the
  other — and it is what both selectors now validate against.

  A command line carrying the old spelling is told so, by the single-variant
  selector guard added earlier in this release, and the guard's own test asserts
  that message so the claim cannot quietly stop being true:

  ```
  $ make test-soak AVR_SOAK_CHIP=85
  FAIL: AVR_SOAK_CHIP=85 is not supported; expected one of: attiny85 attiny45
  ```

  Nothing published moves: the six soak binary paths, the fifteen release soak
  combination names and the retained evidence filenames are byte-for-byte what
  they were before this change. Only the request vocabulary moved.

### Fixed
- **Five active surfaces still used pre-v0.9.8 image or variant vocabulary.** The
  two gpsim wrapper usage blocks now show canonical MCU-qualified basenames; the
  PIC10F320 special-case and PIC shell notes use `cd4053_simple`; and ATtiny202 CI
  now correctly says the output-stage field is exactly the variant name while
  still deriving complete basenames from the Makefile. Historical release
  evidence, migration tables and old feasibility records remain unchanged.

- **The non-blocking feasibility headline said the PIC10F320 spike was measured
  "end to end", overstating its evidence.** The spike was compiled, linked,
  flash-budgeted and stack-gated, but no actuation, lock-step, I/O, fault, soak or
  release-qualification lane ran against it. The executive summary now states
  that exact boundary and points to the existing §6.8 scope record.

- **The PIC hardware-stack gate rejected every real image after it started
  reading `psect` directives.** Tracking "inside a function psect" ended the
  current function at *any* `psect` directive, but XC8 re-selects a function's
  own psect inside its body — once immediately after the `;psect for function`
  marker, and again to restore the psect after each inline-asm escape (`clrwdt`
  in the PIC shell). Every function body therefore parsed as being outside any
  function psect, and `pic10f322-test-stack-bound` failed all three variants
  with `call to annotated function _hw_set_bypass_state occurs outside any
  function psect`. The measurement itself was never wrong — the gate refused to
  produce one.

  Each function is now bound to the psect it was declared in; re-selecting that
  psect stays inside the body, while any other psect still ends it, and an
  operandless `psect` is a structural error rather than a silent no-op. A marker
  with no declaration of its own binds nothing instead of inheriting the
  preceding one, so it keeps the conservative behaviour.

  The synthetic fixtures missed this because they emitted a bare marker with no
  psect scaffolding, so the regression suite passed against a gate that could
  not read a single real image. The fixture builders now emit the full
  declaration / marker / re-selection sequence XC8 produces — every case
  exercises it — plus dedicated cases for the inline-asm restore, a genuine
  mid-body psect switch, a marker that would otherwise inherit the preceding
  psect, and a malformed directive.
  
- **The PIC12F675 feasibility assessment recommended an ISR model whose return
  stack had never been measured.** Its flash/RAM builds and one gpsim trajectory
  succeeded, but both PIC parts have the same 8-level hardware stack and the
  throwaway PIC12F675 ISR source and assembly were not retained. The historical
  parser diagnostic survives, but no numeric current-gate result or complete
  supporting output does.
  The document also described a historical `i1_` lexer failure as a current
  inability to represent interrupt trees, even though the gate now handles them.

  The assessment now establishes Model B as feasible and treats ISR as a
  candidate pending a reproducible three-variant stack result with the required
  reserve. Summary, verdict, resource table, gate description, risks,
  recommendation, validation lanes, sequencing and reproduction notes all make
  the same distinction: the current gate can compute the result; the inputs and
  result do not exist. Measurement provenance remains pinned to `0cfc72e`, while
  the correction records the later gate changes without implying a remeasurement.
  The non-blocking feasibility document now marks its corresponding correction
  as applied rather than correcting a live contradiction elsewhere.

- **The PIC hardware-stack gate could silently ignore a direct call whose target
  used an unrecognized prefix.** Its instruction lexer admitted only `_...` and
  XC8's known `iN_...` interrupt duplicates. An in-function call to `x_helper`
  therefore disappeared before target validation and could turn a real call
  chain into a reported depth of zero.

  The gate now tokenizes every direct `call`, `fcall`, `lcall` and resolved
  `pcall` inside a validated function psect, independent of target spelling, and
  requires every target to resolve to an XC8 function annotation. Each
  annotation must own exactly one matching psect marker; non-function psect
  transitions clear function context; startup/runtime calls remain permitted
  only outside function psects; and indirect or malformed calls still fail
  closed. Synthetic fixtures cover all four direct opcodes, unprefixed known and
  unknown functions, psect ownership, startup/runtime boundaries, indirect
  calls, and the existing main-plus-ISR accounting.

- **Mandatory host Python gates now have an explicit, fail-fast version
  contract.** The system `python3` minimum is 3.7, the first version providing
  the `subprocess.run(capture_output=..., text=...)` APIs those gates already
  use. A shared executable check is the first prerequisite of `make test` and
  `make test-long`, and the three directly affected gates depend on it when run
  alone, so Python 3.6 now gets an actionable version/path diagnostic instead of
  an internal `TypeError`.

  Release preflight runs the same check before probing PyYAML or starting any
  child gate. Its regression accepts the 3.7 boundary, rejects 3.6, permits
  newer host interpreters, and proves an old interpreter cannot reach the
  PyYAML probe. This system-Python contract remains separate from the patched
  yasimavr venv's narrower CPython 3.9-3.13 platform lock.

- **The retained rename-identity report now describes the final images, not an
  earlier build at the same paths.** The fail-fast comparison still runs after
  the initial 18-image build, before any expensive qualification gate. But
  `make test-long`, the target aggregates and final Classic-AVR HEX regeneration
  can all rebuild those paths. The report produced before them was therefore a
  claim about files that no longer necessarily existed by staging time.

  `scripts/make-release.sh` now runs the same comparison again after every final
  image-presence/hash check and immediately before source provenance and
  staging. That second invocation overwrites the provisional report, so the
  retained `RENAME_IDENTITY.md` is computed from the exact image paths copied
  into the release. `test-release-provenance` pins both sides of the ordering and
  reproduces the defect dynamically: all 18 images pass the early comparison,
  one is changed, and the final comparison must fail with that image marked
  `DIFFERS`.

- **The name-contract gate could not see a file until it was committed, so it
  reported a violation one run late — to the next person rather than to its
  author.** `harvestable_files()` enumerated `git ls-files`, which reads the
  *index*: a newly written file was invisible to all four axes until it was
  added. `make test` therefore passed on the commit that introduced a violation
  and failed on the run after. Filed from an observed instance, not a review —
  `test/test_fuse_injection_contract.py` did exactly this, on two docstring
  lines that reflowed such that a line began with the word `make` followed by an
  English word. The gate's own self-exemption was accidental for the same reason
  until the day the file was first committed.

  The harvest now reads the working **tree**: `git ls-files` plus
  `git ls-files --others --exclude-standard`, so a file is in scope from the
  moment it exists. Both halves of that are load-bearing in opposite directions
  and both are now asserted, against a throwaway fixture repository rather than
  against this one — a clean working directory has no untracked file to
  demonstrate the property with, which is precisely why it went unnoticed.
  Without `--others` the gate silently narrows back to committed files; without
  `--exclude-standard` it silently widens to every generated artifact under
  `build_avr_classic/` and `third_party/`. Each direction was verified to fail.

  Two consequences worth stating rather than discovering. The `PUBLISHED` path
  rule that excludes `release/v*/` is newly load-bearing: a release directory is
  untracked while `make release` is staging it, so what used to be redundant for
  an unadded file is now the only thing keeping a past release's goal names out
  of a check on the current tree — asserted alongside the harvest. And the
  untracked half honours the developer's `core.excludesFile`, so it can see
  slightly less on one machine than another; the tracked half is identical
  everywhere, so CI remains the floor and this half can only ever catch *more*,
  earlier.

  Paths are read `-z`-delimited rather than split on whitespace. The untracked
  half is the one that can hold a name a person typed by hand, and a space in it
  would have split into two nonexistent paths, both dropped by the existing
  `isfile` test — that is, skipped **silently**, which is the defect class the
  gate exists to prevent. 37 → 39 checks, still 0.7 s.

- **The PIC10F320 gpsim lanes simulated a PIC10F322, and the gate written to
  prevent exactly that stayed green.** The variable-prefix rename in this
  release renamed the shared gpsim wrapper's processor selector from
  `PIC_GPSIM_PROC` to `PIC10F322_GPSIM_PROC` in
  `test/pic/gpsim_wrapper_common.sh`, and left all four Makefile recipes
  spelling `PIC_GPSIM_PROC=`. Those assignments became inert environment for a
  name nothing reads, so both wrappers fell through to their `p10f322` fallback:
  `make pic10f320-test-gpsim` ran the 256-word part's HEX on the 512-word part's
  device model and reported `RESULT: PASS`. The PIC10F322 lane was correct only
  by coincidence — its override happens to equal that fallback.

  Introduced on this branch; `v0.9.7` spelled the name the same on both sides,
  so no published release is affected. Both PIC10F320 wrappers pass unchanged on
  the correct model, across all three output stages.

  The rename was also backwards on its own terms. `Makefile` states the rule
  beside the PIC variables — a `PIC_*` name with no part in it is the channel
  each lane passes its OWN part's value through, and names
  `PIC_GPSIM_PROC` as one of four such channels. A shared wrapper whose selector
  carries one part's name severs the other lane by construction, and silently,
  because the fallback is that same part. Fixed by restoring the read.

  **The gate is the more important half.** `test/test_gpsim_wrappers.sh` already
  carried a behavioural check for this, with a comment reading *"If this
  regresses, the PIC10F320 lanes silently simulate a PIC10F322"* — and the same
  commit rewrote that check's own probe to set the new name, so it went on
  proving that the wrapper READS the variable while the Makefile stopped WRITING
  it. A gate that supplies the input it is meant to observe cannot see its
  producer disappear. Both public lanes are now probed end-to-end through a
  `-p`-recording fake gpsim:

  - `pic10f320-test-gpsim` is run with nothing overridden and must reach gpsim
    with `p10f320` twice. Non-vacuous because the shared fallback is `p10f322`,
    which is precisely the value the severed lane produced.
  - `pic10f322-test-gpsim` cannot be checked that way at all — its correct
    processor IS the fallback, so severed and intact are indistinguishable. It
    is handed a probe value that is neither part's and must carry it through.
    Setting it on the make command line does not short-circuit the check: make
    exports command-line variables to the recipe environment, but under
    `PIC10F322_GPSIM_PROC`, which the wrapper does not read.

  Both probes read the wrapper's fallback rather than restating it, fail if that
  value cannot be extracted, and fail if the expected value has drifted to equal
  it. Verified by reintroducing the defect four ways — the 320 prefix severed,
  the 322 prefix severed, the expected value made equal to the fallback, and the
  fallback made unreadable — each reported by its own diagnostic. 44 checks.

  **The name-contract gate's axis D was pointing at this defect**, which is how
  it was found: prose naming `PIC_GPSIM_PROC` reads as severed there, because
  axis D's known-name set was make variables only. A `NAME=value` prefix on a
  recipe line defines no make variable, so the only spellings axis D accepted
  for a shared env channel were part-scoped make-variable names — the rename
  that broke this lane. `env_channel_names()` now unions those prefixes into the
  known set, walking every statement of a recipe rather than only its first
  (recipes are one logical line, and these invocations are the eighth statement
  of theirs — reading only the head finds 44 channels and misses this one). It
  takes the prefix position only, stopping at the first word that is not an
  assignment, so make overrides and `-D` macros stay with axis C and the
  fuse-injection contract respectively. A negative case fails if the harvest
  stops finding `PIC_GPSIM_PROC` or starts reading `-D` macros as environment.

  This closes a false positive, not the class. Nothing yet checks that a child
  still READS the environment its parent sets — the gap this defect came
  through. Filed as axis E in `TODO.md`, with the surface measured (121
  channels, one severed) and the two things that make a naive version wrong.

- **`make release` could not have completed: the AVR soak binary was renamed on
  one side only.** The same rename that moved `test_sim_<v>_t<n>` to
  `_attiny<n>` updated `scripts/make-release.sh`, which composed its own copy of
  the soak binary's path, to ask for `test/avr/test_soak_<v>_attiny<n>` — while
  the Makefile's `AVR_SOAK_BIN` went on saying `_t<n>`. There is no such target:
  `make -n test/avr/test_soak_cd4053_simple_attiny85` answered *"No rule to make
  target"*. A release run would have died in step 3, on the far side of `make
  test-long` and every qualification gate, an hour or more in.

  Filed as cosmetic residue — "the `_t<n>` suffix this release retired
  everywhere else still exists in two places" — and it was not. Nothing builds
  these binaries outside a real release, so no gate ran the composition that
  had severed.

  `AVR_SOAK_BIN` now spells `_attiny<n>`, matching its sibling simulation
  binaries, and `make-release.sh` READS it rather than keeping a second copy.
  The image basenames beside it stay restated on purpose: those are the script's
  independent opinion of the release set, cross-checked against
  `RELEASE_IMAGES`, so restating them is what gives the check meaning. This path
  was cross-checked against nothing and only needed to be right — the
  distinction the copy missed. The retired `_t<n>` binaries join
  `AVR_TEST_BINARIES_RETIRED` so an existing worktree does not keep them.

- **`make clean` stopped removing nine of the binaries it builds, and
  `clean-tests` stopped removing anything at all in the classic-AVR lane.** Both
  targets spell their artifacts as a hand-written list, and the image rename
  earlier in this release moved the simulation binaries from `test_sim_<v>` /
  `test_sim_<v>_t<n>` to `test_sim_<v>_attiny13a` / `_attiny<n>` without either
  list following. Every path they named had stopped existing; all nine binaries
  actually built survived both targets. Nothing failed, because an `rm -f` of a
  file that is not there is a successful `rm -f`.

  `clean-tests` is the sharper half: its stated job is to drop binaries so the
  next run rebuilds them at the currently selected workload sizing, so a
  `clean-tests` that removes nothing means a `make test-long` could run FAST
  workloads while reporting the exhaustive suite. It could not, in fact —
  every affected rule carries `FORCE` and recompiles regardless — but that is an
  accident of an unrelated design decision, not a guarantee, and it would go
  silently the day a `FORCE` came off.

  The list is now spelled **once** (`AVR_SIM_BINARIES` / `AVR_SOAK_BINARIES`)
  rather than twice, and `clean` additionally removes the retired spellings so a
  worktree predating the rename does not keep them forever — the same courtesy it
  already extended to the pre-`src/`-reorganization KLEE paths.

  New gate `test-clean-contract` (`test/test_clean_contract.sh`, in `make
  test`), 11 checks in 0.4 s. Its oracle is `make -rRn --print-data-base`: every
  explicit non-phony target under `test/` that is not a tracked source file is
  something the Makefile builds, and `make -n clean` must remove it. Reading
  Make's own inventory is the point — a second hand-written list would just be a
  third copy of the spelling to drift, and the families that matter
  (`test_sim_<variant>_attiny<n>`) exist only after `$(eval $(call ...))`
  expansion, so a textual harvest of rule heads would not see them at all.
  `clean-tests` has a deliberately narrower scope, so its gap is checked against
  declared exemptions rather than required to be empty; a new build product
  forces a decision. Verified by restoring the pre-rename spellings, which makes
  the gate name all nine binaries and fail.

- **`MISRA_COMPLIANCE.md`'s maintenance procedure told a maintainer to run the
  MISRA sweep over variant names that no longer exist**, and the command did not
  fail — it silently analyzed **zero** output drivers and exited 0.
  `make analyze-misra VARIANTS="cd4053 mute relay"` (and the
  `analyze-misra-report` line beside it) named the pre-`v0.9.8` stage
  vocabulary; `$(FW_SOURCES)` is built by
  `$(foreach v,$(VARIANTS),$(src_$(v)))`, so every unrecognised name
  contributes nothing and the set silently shrank from five files to two.
  Both lines now name the current values, and the command they name can no
  longer behave that way for anyone: the five `analyze-*` targets now validate
  their variant request (see *Added*).

  This is the *value* twin of the four name-contract axes and is not covered by
  any of them: `VARIANTS` exists, so axis C is satisfied; only its contents were
  stale. It is also the failure mode the `Makefile` warns about in its own
  words — "a mis-scoped chip variable produces no compile error and no failing
  test, it produces a PASSING one". Found by hand while building axis D, in the
  same code block whose very next line already used the current spellings.

- **The PIC10F322 soak driver had not compiled since the stage-vocabulary
  rename, silently disabling a mutant and breaking three release soak
  binaries.** `Makefile`'s `pic_soak_block_*` map kept its retired
  `cd4053`/`mute`/`relay` keys while `PIC10F322_SOAK_VARIANT` moved to
  `cd4053_simple`/`cd4053_with_mute`/`tq2_l2_5v_relay`. All three lookups
  expanded empty, so the compile line emitted `-DSOAK_ACTUATION_BLOCK_MS=u` and
  the driver failed with ``error: `u' was not declared in this scope``. The
  PIC10F320 copy of the same map had been renamed correctly, so the two lanes
  disagreed in silence for an entire release.

  It degraded to a *skip*, not a failure: `make pic10f322-test-soak` was broken
  outright, the mutation harness reported its baseline as failed and skipped the
  PIC10F322 WDT mutant, and the run still exited zero as a `PARTIAL`. The
  mutation inventory is back to **94 killed, 0 survived, 0 errored, 0 skipped**
  from 93 killed with one skip. `scripts/make-release.sh` builds the three
  PIC10F322 release soak binaries through the same rule, so this would also have
  failed the `v0.9.8` release soak.

  The parse-time completeness guard added earlier in this release covered
  `macro_<v>` and `src_<v>` only; `pic_soak_block_<v>` was a third per-variant
  map it did not know about, and `pic10f320_soak_block_<v>` a fourth. The guard
  is now a reusable `require_variant_map` contract covering all four, with each
  soak map checked against *its own lane's* supported set so the deliberate
  divergence between lanes stays legal.

  A guard that needs a human to remember to extend it has the failure mode it
  exists to prevent, so a new `test-variant-map-contract` gate (in `make test`)
  asserts every per-variant map is registered. It harvests **dereference** sites
  rather than definitions, because a definition-keyed harvest would not have
  caught this defect — `pic_soak_block_cd4053` matches no current variant name,
  so it was invisible exactly when it was broken.
- **No mutant, and no CI job, had a wall-clock bound.** Containment for the
  severed-override defect below, which is the same incident from the other end:
  that fix removed the cause, this one removes the blast radius. A single mutant
  ran for over ten hours locally before being killed by hand, and nothing in the
  harness or either workflow would have stopped it.

  Every mutant checker and every toolchain baseline probe now runs under
  `timeout` (`mutation_bounded`, default 900 s, `MUTATION_TIMEOUT_S` to
  override). The bound is deliberately loose: mutant soak windows are 2–2.5 s of
  simulated time, so 900 s is about two orders of magnitude of headroom — enough
  to catch a 43,200× severance immediately without ever becoming a flaky
  failure.

  The load-bearing half is the exit status, not the bound. A mutant is recorded
  as *killed* on any nonzero exit, so a hung mutant terminated at the deadline
  would have been counted as killed — a suite reporting a clean run it never
  finished. `timeout` exits 124 on expiry, which is now classified as an
  infrastructure error in `test/mutation_accounting.sh`, so a hang surfaces as
  `ERROR`. Both properties are covered by new selftest assertions that drive the
  wrapper itself rather than only the classifier, so deleting the bound fails the
  suite.

  All six GitHub Actions jobs gain `timeout-minutes` (previously zero across both
  workflows): `verify`, `pic`, `build-matrix` 45, `attiny202` 60, `stress` 300,
  `release` 60. The `stress` job is the one that matters — it reaches the
  mutation lane and would otherwise have been cancelled at GitHub's six-hour
  default with nothing useful reported.
- **The `v0.9.8` rename left dead variable and goal names on eleven live
  surfaces, two of them instructing a reader to type one.** The same
  silent-severance class as the entries below, found by a meta-review of the
  finished release rather than by any gate. `make -s print-MCU` and
  `make -s print-PIC320_TAG` both returned empty.

  The sharpest was `Makefile`'s `test-flash-budget` guard, which reads
  `$(ATTINY13A_MCU)` but told a user who tripped it that it `requires
  MCU=attiny13a` — advice that, followed, sets an inert override and changes
  nothing. `test/test_flash_budget.sh` asserted that exact text, so the
  regression was defending the dead name; correcting the message alone would have
  turned the gate red. Also fixed: a Makefile comment instructing readers to set
  four removed `PIC320_*_VARIANT` names on the command line, three more `PIC320_*`
  prose references, `README.md`'s claim that the PIC10F320 lane uses `PIC320_*`
  variables, three harnesses passing an inert `MCU=attiny13a`, and
  `test/README.md`'s `make test-sim-<variant>`, which has no rule — the goal
  identified by the *omission* of its MCU field, the exact defect this release's
  rename existed to remove.

  Nothing was mis-built: `ATTINY13A_MCU` is a plain `=` whose default equals the
  value the dead overrides passed. The cost was misdirection, not wrong output,
  which is why no gate would ever have noticed. `TODO.md`'s name-contract item is
  widened to a fourth axis (variables named to human readers) and records why its
  own prototype sweep missed these: it keyed on physical lines, and the overrides
  sat five backslash-continued lines away from the `make` that consumed them.
- **The mutation suite's PIC lane had been silently disabled since the image
  rename earlier in this release.** `test/run_mutation_tests.sh` built its
  PIC10F322 baseline image path from the *old* basename scheme
  (`${FW_BASE}_cd4053_${PIC_TAG}.hex`), which stopped existing when images
  became `bypass-pic10f322-cd4053_simple.hex`. The miss degraded to a skip
  rather than a failure — the missing file left `PIC_GPSIM_OK` unset, so the
  PIC gpsim mutants reported as unavailable instead of failing loudly. Found by
  the prefix sweep, not by a gate: the mutation run is in `test-long`, not
  `make test`. The path is now composed from the canonical fields.
- **The goal rename left sixteen dead `make` commands in documents that describe
  the current tree.** Same silent-severance class as the mutation-lane miss, on
  the axis pointed at readers rather than at scripts: nothing asserts that a goal
  named in a document still exists, so `make pic320-test` and its siblings
  survived the rename as instructions that now fail with `No rule to make
  target`.

  Fifteen were in `docs/pic10f320_validation.md`, which is framed as *current*
  qualification evidence rather than history — eleven in prose describing
  standing gates, and four in its §7 "Reproducing any of this", where four of
  six commands were dead and `PIC320_SOAK_DURATION_MS` had been renamed too. The
  sixteenth was `make pic-test-config` in `docs/phase2_pic_shell.md`. All now
  carry their `v0.9.8` spellings. Two references are deliberately left in the
  old vocabulary and read correctly as history: a captured
  `make: *** [pic320-test-equiv] Error 1` transcript, and
  `release/v0.9.6/evidence/pic320-test.log`, which is a real file under that
  name.

  `release/README.md`'s reproduce recipe had a related defect that a rename table
  could not fix. Its "Unified releases (v0.9.6 or later)" section says
  `git checkout vX.Y.Z` and then builds with goals that only exist from `v0.9.8`
  on, so it was wrong for two of the three releases it claimed to cover. The
  section is now scoped to `v0.9.8` or later, and a second section carries the
  same recipe for `v0.9.6` and `v0.9.7` in that era's goal names. Checking out a
  tag moves the Makefile, `RELEASE_IMAGES`, `SHA256SUMS` and both verifier
  scripts together, so those releases remain reproducible with exactly the
  guarantees described for the current one; what does not work, and is now stated,
  is pointing the *current* image verifier at an older release directory.

  The `TODO.md` item filed earlier in this release for the `make print-<VAR>`
  contract gate is widened to cover both axes, since one gate closes both. Its
  allowlist is the hard part and is now specified from the real cases: a document
  may legitimately name a retired goal in an old→new redirect table, in a recipe
  pinned to an older tag, or in a quoted transcript — so the exemption has to be
  per-block, not per-file.
- **The variable rename left the classic-AVR WDT mutant running a 24-hour soak
  in place of a 2-second one.** A third axis of the same silent-severance class
  as the two entries above — `make VAR=value` overrides — and the first to cost
  wall-clock time. `test/run_mutation_tests.sh` still passed `SOAK_VARIANT=` /
  `SOAK_CHIP=` / `SOAK_DURATION_MS=` / `SOAK_LIVENESS_INTERVAL_MS=` to
  `make test-soak`, but those became `AVR_SOAK_*` earlier in this release. An
  override naming a variable no recipe reads is legal and silent, so the mutant
  asked for 2 s of simulated time and got `AVR_SOAK_DURATION_MS`'s 24 h default
  — 43,200×. A local `scripts/ci-local.sh` run sat in that single mutant for
  over ten hours before it was killed, and neither CI job that reaches the row
  declares `timeout-minutes`, so both would have been cancelled at GitHub's
  six-hour job limit. Now restored: the mutant is killed in 2.4 s with 127
  watchdog resets, exactly as its recorded rationale describes.

  Four guards missed it, each for a different reason, which is why this axis
  needs a gate of its own: the soak-timing contract's `static_assert` compares
  the *defaults* (`60000 <= 86400000`), so the build stays clean; the mutant is
  still correctly killed, only ~43,000× too slowly, so it presents as a hang
  rather than a wrong answer; the mutation run is in `test-long`, not
  `make test`; and no mutant is wrapped in `timeout`.

  The same rename had also left the Makefile recommending the broken spelling.
  Its soak-override block, `make help` and two header comments documented
  `SOAK_*` and `PROGRAMMER=` instead of `AVR_SOAK_*` and `AVR_PROGRAMMER`, so a
  reader following `make test-soak SOAK_DURATION_MS=3600000` got a silent
  24-hour run. All corrected, and that block now says explicitly that the bare
  `SOAK_*` spellings are the compiled-in C macros rather than make variables. A
  tree-wide sweep of every `NAME=value` passed to make confirms no other
  override is stale; the `TODO.md` gate item is widened again to cover this
  axis, and now recommends building it first, since it is the cheapest of the
  three and the only one with a demonstrated runtime cost.
- **Documentation: the recorded reason the ATtiny202 harness cannot measure
  busy-delay width was wrong, and is corrected everywhere it appeared.** Since
  `0.9.5` the delay oracle, `test_sim_attiny202.py`, `scripts/fetch_yasimavr.sh`,
  the Makefile, `test/README.md`, `TODO.md` and `DESIGN_DOCUMENTATION.adoc` all
  stated that yasimavr charges a flat ~1 cycle per instruction with no
  multi-cycle timing model. It does not; its AVR-XT core models instruction
  timing correctly.

  The real defect is in `SimLoop::run(nbcycles)`, which pins the cycle counter to
  `first_cycle + nbcycles` on return and therefore *rewinds* it whenever the last
  instruction overshoots the budget. A caller loses up to one instruction's worth
  of cycles per call, and at `run(1)` — one instruction per call — every
  instruction is billed exactly 1 cycle. The ATtiny202 output tracer samples pin
  state one cycle at a time, which is why a 12 ms coil pulse traced as ~6 ms. The
  original "flat instruction timing" conclusion was itself measured by
  single-stepping through that same bug.

  Reported upstream; the maintainer confirmed it and produced a fix. Verified
  against a local rebuild of the pinned 0.1.6 carrying that guard: `SBIW` steps
  as 2 cycles, the relay pulse measures 12.669 ms at single-cycle sampling
  instead of 6.186 ms, and `make attiny202-sim` passes unchanged. The pinned
  release does not carry the fix, so no test behaviour changes here and the
  absolute width stays with the disassembly oracle — where it belongs regardless,
  being a compile-time property. Re-pinning is filed as a `TODO.md` Tier 2.5 item.

  Nothing about the shipped firmware changes: the images were always correct for
  real 2 MHz silicon, and tick-driven timing (debounce thresholds, LED
  sequencing, lock-step) was never affected. The `0.9.5` entry adding the delay
  oracle carries this superseded rationale in its justification clause; the
  oracle itself remains correct and is unchanged.

## [0.9.7] - 2026-08-01

> **Where the detail lives.** This entry is a post-release cleanup pass whose
> 44 items were tracked individually, most of them compressed to a sentence
> below. The per-item evidence — measured figures with the commands that
> reproduce them, and the alternatives considered and rejected — is recorded in
> [docs/v0.9.6_post_release_polish.md](docs/v0.9.6_post_release_polish.md).

### Fixed
- **A non-executable Intel HEX validator passed the build's presence check.**
  `make pic`, `make attiny202` and `make pic320-size` guarded
  `IHEX_VALIDATOR` with `[ ! -x "$V" ] && ! command -v "$V"`, and for a value
  containing a slash dash's `command -v` succeeds on a file that merely
  *exists*. A validator present but not executable therefore passed the guard
  and failed later with "Permission denied" — after the compiler had already
  produced the image the validator was supposed to check. The guard now requires
  the executable bit whenever the value names a path and falls back to a `PATH`
  lookup only for a bare command name, and it is defined once
  (`IHEX_VALIDATOR_CHECK`) instead of copied into each recipe. Found by the new
  ATtiny202 regression below rather than in the field.
- **The Classic AVR soak was watching a signal simavr never raises for a
  watchdog reset.** `test/avr/test_soak.c` recorded a watchdog failure only when
  `avr_run()` returned `cpu_Crashed`, but simavr 1.6 sets that state solely from
  `avr_sadly_crashed()` (illegal opcode / stack crash); its watchdog path resets
  the core in place and leaves it `cpu_Running`. The six Classic AVR release
  soak combinations could therefore run a full 24 h and report
  `watchdog_failures=0` without ever having been able to observe one. The soak
  now installs simavr's `avr->reset` callback — the same positive witness
  `test/avr/test_sim.c` has used since `9957a00` — counts every invocation, and
  charges each reset to `watchdog_failures`. A `cpu_Crashed` remains tracked as
  its own separate anomaly. `test_watchdog_not_tripped_normally` in
  `test_sim.c` now asserts the reset count rather than the crash flag, which is
  the only one of the two that can witness the fault the test is named for.
  Both harnesses chain the MCU model's own reset callback instead of replacing
  it.
- **`attiny202-soak` could report success having soaked nothing.** It was the
  only one of the four AVR-XT harness targets missing the guards its three
  siblings share — `XT_SIM_VARIANT` validated against both the supported list
  and `VARIANTS`, an ATtiny_DFP device-file guard, a missing image treated as a
  failure, and a failure when the loop covered zero images — while its own
  header comment claimed the "same guard / skip / variant-selection as the
  others". `make attiny202-soak XT_SIM_VARIANT=bogus` exited 0 where all three
  siblings exit 2, printing "no ATtiny202 images built; nothing to soak" and
  blaming an absent DFP in a run that had just built and budget-checked all
  three images. The target is a release-qualification input —
  `RELEASE_SOAK_NAMES` carries `attiny202_relay`, and each soak log is published
  evidence — so "soaked nothing" must never read as "soak passed". The recipe
  now mirrors its siblings verbatim; nothing that passed before behaves
  differently.
- **Three layers of the ATtiny202 matrix could go green having exercised part
  of it.** Every `attiny202-*` harness target iterates `VARIANTS`, and a variant
  that is skipped rather than run still leaves the target at exit 0, so exit
  status alone never proved coverage. CI compensated by counting PASS markers
  but sized the expected count from `make -s print-VARIANTS` — the AVR Classic
  list, which is user-overridable, so a single override shrank the build and the
  expectation together: `VARIANTS=cd4053` produced one `SIM PASS`, which the job
  expected and accepted. The count now comes from `XT_VARIANTS_SUPPORTED`, which
  is the ATtiny202's own list and is declared `override`. `ci-local.sh` ran the
  same five targets with none of those assertions, despite opening with the
  promise that "a clean pass here means the CI matrix will be green"; it now
  applies all five through an `xt_gate` helper mirroring `ci.yml` step for step.
  And `attiny202-test-target` did not enforce the matrix itself, so it now
  rejects incomplete, empty, duplicate and unsupported variant requests before
  running any simulator lane, and requires exact per-variant PASS counts from
  sim, fault and lock-step plus both lock-step boot scenarios. The fault gate's
  hardcoded `n=3` is deliberately left unconverted: if all five counts read one
  variable, a wrong edit to that variable makes all five agree on the wrong
  answer at once, so one independently pinned count is a cross-check on the
  variable itself — the same reasoning that gives `RELEASE_IMAGES` its value.
- **`ci-local.sh --skip-attiny202` could not pass.** Push mode set
  `MUTATION_ALLOW_SKIP=1` for `--skip-pic` only, so skipping the ATtiny202
  toolchain removed its lane and then failed `test-long` for the very mutants
  the skip had intentionally removed. Either explicit toolchain skip now selects
  partial mutation mode; only a complete target-toolchain run receives `0`, and
  PR mode still runs the non-mutation path. The routing regression had codified
  the defect by supplying `--skip-attiny202` to every invocation while expecting
  `0`, so it no longer does.
- **Both soak families could hold a liveness verdict open across the event it
  was watching for.** The PIC soak sampled LED state only at the endpoints of a
  multi-millisecond hold, so a rapid even-numbered retrigger sequence collapsed
  into an unchanged endpoint and read as no activity at all; it now samples
  after every simulated millisecond. The AVR-XT soak checked its reset and
  terminal force-reset witnesses on a schedule that could miss the final
  round-trip before the verdict; it now checks after every liveness hold,
  including that last one.
- **The release orchestrator had four fail-open edges.** `scripts/make-release.sh`
  could stage production output outside the canonical version directory, accepted
  an unvalidated soak-concurrency value, and proceeded from a failed or empty
  executable version probe. Soak workers now run in isolated process groups and
  every exit path terminates and reaps them without stale-PID, launch-window,
  descendant or repeated-signal gaps; direct `flock` execution stays
  signal-transparent, and a failed run's evidence is preserved for diagnosis
  rather than cleaned away.
- **`scripts/fetch_yasimavr.sh` could recursively delete a caller-named
  destination.** `VENV_DIR` is documented as caller-selectable and was assigned
  straight to `VENV`, which `rm -rf "$VENV"` then consumed twice — so a typo, the
  repository root, a shared directory or any existing non-venv directory could
  take unrelated data with it. The fetcher now rejects extra and empty
  arguments, canonicalizes physical paths, and refuses filesystem and repository
  roots, destination symlinks, non-directories, missing parents and existing
  directories without a schema-valid private stamp. It builds and verifies in a
  randomized sibling, installs with a no-clobber rename, and restores the prior
  stamped venv after an install failure or a signal, retaining it as a rollback
  backup rather than recursively deleting any caller-derived path.
- **Git line-ending conversion could invalidate release bytes and signatures.**
  With no `.gitattributes`, a checkout under `core.autocrlf=true` — the setting
  Git for Windows recommends — rewrote release artifacts, so images no longer
  matched `SHA256SUMS` and the detached signature over it no longer verified.
  Firmware images, checksums, signatures, qualification records and expected
  hashes are now marked non-text. The same pass then found that the two records
  `scripts/verify-release-qualification.sh` reads by exact whole-line match were
  still convertible: it matches the `MANIFEST.md` heading with `grep -Fxq` and
  compares each soak log's `SOAK_RESULT` record for string equality, so a CRLF
  checkout made the verifier reject a correct release — fail-closed, but on the
  command `release/README.md` tells auditors to run. Both classes are now pinned
  to LF, and because an extension allowlist is what let them be missed in the
  first place, a `* text=auto eol=lf` default now backstops it so a class nobody
  has named yet cannot inherit the platform default. `make test-release-history`
  asserts the policy on a representative path per class, verifies mixed-EOL
  historical artifacts byte-for-byte under `autocrlf`, and pins the catch-all.
- **The stack high-water-mark gate overstated free SRAM by four bytes.**
  `test_stack_high_water_mark()` asserted a margin "between the deepest SP and
  BSS" but measured down to `0x60`, the first SRAM byte — below BSS, so the four
  static bytes living there were counted as free. The error ran optimistic
  inside a gate: at the 8-byte floor the stack could reach within 4 free bytes
  of BSS while the message announced 8. The floor now comes from the firmware
  ELF's `__bss_end`, read from the ELF rather than derived, so a static added
  later tightens the gate by itself; a missing symbol is a failure, not a
  fallback to the looser reference point. Margins now read 29 B (relay, mute)
  and 31 B (cd4053), matching the figures `DESIGN_DOCUMENTATION.adoc` already
  stated and which the gate's own output had contradicted by 4.
- **The default host suite failed in an extracted source archive.** The
  PIC10F320 coverage checker's mode validation inspected the file's Git index
  mode unconditionally, which no source tarball has. It now requires the checker
  to be locally executable everywhere but inspects the index mode only inside a
  worktree, keeping clone and CI validation without rejecting archives.
- **`MANIFEST.md` carried a repo-relative link that does not resolve as release
  notes.** The file is committed at `release/<version>/MANIFEST.md`, where the
  relative path to the PIC10F320 special-case document is correct, but
  `release.yml` also passes it verbatim to `gh release create --notes-file`, and
  on the release page that path 404s. The link is now absolute and pinned to the
  release tag, so it is correct in both contexts and points at the matching
  source revision rather than a moving `main`. The repository URL is a literal
  constant rather than being read from `git remote`, which varies with the
  operator's SSH-versus-HTTPS clone and would silently change published notes.
- **Three resource tables and the BOD/BOR failsafe list had drifted from the
  build.** The AVR Classic flash table was stale on all nine rows (716/756/756
  bytes on the ATtiny13a and 742/782/782 on the ATtiny45/85, against
  684/724/732 and 710/750/758), and the PIC10F322 program-space column on all
  three (445/473/471 words at 86.9/92.4/92.0%, against 404/431/434). In both
  cases the relay and mute variants are now byte-identical or reordered, so the
  tables' implied size ordering was wrong as well. Neither drift originated in
  the build: `release/v0.9.5/MANIFEST.md` already published the correct AVR
  figures and that release's `build-pic.log` the correct PIC ones, so the
  shipped evidence has been right throughout and only the design document was
  wrong — and nothing in the Makefile, scripts, tests or CI reads these tables,
  so no gate could have caught it. Percentages now use `avr-size`'s own
  one-decimal values, making the table reproducible by the command in its
  caption. Separately, the BOD/BOR failsafe list covered two of the six release
  parts while its framing promised per-part coverage; the ATtiny202 (BODCFG
  0xE5 → BODLEVEL7 at 4.2 V, enabled in active and sleep) and PIC10F320
  (BOREN=ON, LPBOR=OFF, BORV=HI, the same ~2.4/2.7 V trip points as the
  PIC10F322) entries are added, and the shared hardware-design caveat now names
  both PIC parts instead of generalising from the 322.
- **Four resource claims survived their own measurements.** The Resource
  Utilization section opened by claiming large headroom on every supported part,
  which the document's own PIC10F320 table contradicts two screens later at
  95.3% of 256 words and 12 free — the entire reason that target is built
  differently. It now states the measured span, 9.1% of an ATtiny85's flash
  through 95.3% of a PIC10F320's. The paragraph under the AVR Classic table
  still claimed room for future features "without approaching any resource
  limit" while the ATtiny13a above it sits at 73.8% of a 90% ceiling; it is now
  split per resource, the SRAM half naming the gate that enforces it
  (`test_stack_high_water_mark()`, which fails `make test-sim` below an 8-byte
  floor — never a build failure, as the old text implied). The PIC10F322 prose
  claim of "comfortable headroom" is replaced with the real 39-of-512-word
  margin, and corrected again in `docs/pic10f320_feasibility.md`, which asserted
  it as still true. Both Makefile resource-gate comments were stale in the same
  way: the ATtiny13a flash comment said ~46% where the firmware is at 73.8%, and
  the `STACK_MAX_FRAME` comment claimed a ~10 B full-path high-water mark where
  it is 29–31 B, while conflating per-frame and total-depth bounds. Neither
  ceiling moved; both comments now name the target that reproduces their
  figures, and a documented `STACK_MAX_FRAME=16` override example that exits 2
  against the 19 B timer ISR frame is corrected to 24.
- **The ATtiny202 shell shipped an unresolved `CONFIRM` note on its BOD fuse.**
  A bring-up instruction to the reader — confirm the BODCFG level encoding and
  that the level is characterised rather than reserved — was published on a
  release-supported part, on the fuse that establishes the peripheral-safe
  voltage floor. It is answered in place from the pinned device pack so the
  evidence travels with the code, and the note pins down the trap that makes the
  question worth asking: the pack carries two BOD level enums, one for `BOD.CTRLB`
  at bit 0 and one for the fuse at bit 5, and decoding a BODCFG byte with the
  register enum yields a confident wrong answer. The PIC10F320 shell carried the
  same ten CONFIG bits as the PIC10F322 with no explanation, so a maintainer
  reading only the 320 got the safety-relevant configuration without the
  reasoning; it now points at the 322's rationale block rather than copying it.
  Both are comment-only: all six images are byte-identical, and no `CONFIRM`,
  `TODO` or `FIXME` marker remains under `src/`.
- **The debounce documentation confused eight samples with eight milliseconds.**
  `PRESSED_THRESH` was described as a fixed 8 ms duration when it counts eight
  sample instants; clean press latency and isolated-pulse rejection are now
  derived from those instants, arbitrary edge phase and the stated oscillator
  tolerance. The timing example is redrawn to show the seven intervals between
  eight low samples and 24 intervals between 25 high samples.
- **The live PIC10F320 documentation contradicted itself.** Its expected-image
  check is now described as the standing SHA-256 gate it is, with its
  compiler-reproducibility limitation retained; blocking actuation timing is
  scoped to both polled PIC implementations and both ISR-driven AVR generations
  rather than one part; the target topology is stated as five shared-core
  targets through three shell files plus one self-contained target; and direct
  core comparisons are separated from the other PIC10F320 evidence lanes.
- **The MISRA compliance record's scope and its deviations disagreed.** Genuine
  AVR register-access deviations were not distinguished from
  cross-translation-unit artifacts or PIC10F320 analyzer accommodations. The
  record now documents the eight-source/fourteen-header analysis boundary, each
  target's direct cppcheck inputs, the Classic-only report scope and the
  PIC10F320 variant sweep, with the suppression-file comments aligned to match.
  No waiver changed.
- **Historical release provenance overclaimed the soak matrix.** Manifests for
  `v0.9.0`–`v0.9.4` say "24.0-h parallel soak of every variant × MCU", which is
  broader than the retained evidence: the ATtiny13a images were not soaked
  directly, because simavr cannot model their watchdog reset, and were covered
  by the full suite and the core-identical tinyx5 soaks — as each manifest's own
  limitation note already said. `release/README.md` now carries a live erratum
  linking each affected release's note, and this file's claims are narrowed to
  the canonical release soak combinations. The historical snapshots are
  unchanged.
- **The toolchain record said KLEE was absent.** It now names the validated
  Linuxbrew KLEE 3.2 and matching LLVM 16.0.6 tools with their configured paths
  and measured real-core result, keeps the host enumerator fallback, and
  distinguishes that local solver run from the still-absent KLEE execution in
  CI.
- **Two firmware comments contradicted the code they describe.** The PIC10F320
  bypass and engage call sites named the physical MCU pin levels backwards, and
  an adjacent branch comment cited a pure-core state member that does not exist.
  Comment-only: pinned before-and-after builds produced all 18 images
  byte-identically.
- **Imported PIC10F320 harnesses named the standalone project's make targets.**
  Comments carried over from the pre-merge repository directed readers to
  unprefixed targets that do not exist here; they now name the integrated
  `pic320-*` targets, and the gpsim script's supported output-variant count is
  corrected from five to three.
- **Strict CI and release environments omitted prerequisites they assume.** Git,
  GnuPG and PyYAML are now installed and asserted before the strict suites and
  before release signature, qualification or history verification, with the same
  checks in `ci-local.sh`'s unconditional host preflight. The Ubuntu and Docker
  toolchain recipes are updated to match, and workflow validation now enforces
  real apt arguments, executable assertions and placement before first use
  rather than accepting whatever the runner image happens to contain.
- **Assorted live-documentation and shell defects.** The top-level simulator
  summary omitted the ATtiny202 lock-step gate; `test/README.md` omitted nine
  tracked validation scripts and AVR-XT tests, and did not call out the
  exact-pin helper shared by both PIC harness families; a release link,
  validation table, tool label, target count and several fragile source-line
  references were wrong across the live documentation; and the two `.gitignore`
  files contradicted each other about `commit_msg.txt` — both now state the same
  working-note policy, under which the root file is ignored while
  `release/<version>/commit_msg.txt` is deliberately tracked. The yasimavr
  fetcher now uses POSIX signal 0 for its cleanup trap and passes ShellCheck,
  with no change to its path or replacement-safety behaviour.

### Changed
- **`test` and `test-long` now share one gate inventory.** The two aggregates
  ran the same 46 gates in the same order, differing only in workload sizing and
  in `test-long` additionally running `test-mutation` — but each carried its own
  hand-maintained prerequisite line, so a new gate could land in only one of
  them, and the one it would miss is `test-long`, the release gate. Both are now
  built from a single `TEST_GATES_EARLY`/`TEST_GATES_LATE` inventory
  (`TEST_GATES` and `TEST_LONG_GATES`); the expansions are byte-identical to the
  lines they replace, order included. The ATtiny202 build's own 30-line Intel
  HEX parser is likewise gone, replaced by the `scripts/validate-ihex.sh` that
  the Classic AVR `.hex` rules and both PIC builds already use — with all six
  ATtiny202 images verified byte-identical across the swap.
- **The two throwaway-repository builders now share one walk.**
  `make test-mutation` builds a sandbox per mutant and `test-pic-build-rebuild`
  builds one for the PIC soak file rules; both copy the tree into a `mktemp`
  directory and run Make inside it, but they learned about a new file by
  different means — an extension-allowlist `find` walk versus a hand-enumerated
  prerequisite list. `test/pic/find_pin_exact.h`, made a prerequisite of both
  chips' soak binaries by `b4da21c`, broke each of them in turn. The mutation
  runner is where that costs most, because there the omission is silent: a
  missing file fails the baseline probe, a failed baseline is recorded as a
  *skip*, and 18 mutants went unenforced while the run reported every mutant it
  did evaluate as killed. Both harnesses now source `test/scratch_tree.sh`. The
  walk itself is unchanged — the sandbox it produces is byte-identical to the
  one the mutation runner built before — and `test_pic_rebuild.sh` keeps only
  its own step, blanking the named prerequisites, since the property under test
  is Make's staleness decision and not compilation. That list can no longer omit
  a file and stop Make short of the property; what it still does is assert those
  files *are* prerequisites, so a rename is reported in one line instead of
  quietly shrinking the fixture (9 → 14 checks).
- **The PIC10F320 documentation set now has one owner per kind of claim.** Its
  lane inventory, assurance argument and mutation mechanics were repeated across
  `docs/pic10f320_special_case.md`, `docs/pic10f320_validation.md` and
  `test/README.md`, with every change-prone count living in two places at once.
  They agreed at the time of writing, but a stale emitted-byte statement fixed
  earlier in this cycle shows what that costs. The split is now explicit and
  stated in `DESIGN_DOCUMENTATION.adoc`: `special_case` owns the architectural
  difference and the assurance argument, `validation` owns execution evidence and
  the scope of what each result does and does not establish, and `test/README.md`
  owns the current inventory — Make targets, substrates, mechanics and check
  counts. Duplicated inventories became links: the assurance table dropped its
  Make-target column, and the validation record's copies of the return-stack
  oracle's decoder rules, the rebuild regression's assertions and the mutation
  category/accounting contract were replaced by pointers, keeping the historical
  measurements and scope caveats that are its own. No count moved; the two
  mechanics details that existed only in the validation record moved to
  `test/README.md` rather than being dropped.
- **The copyright notice names one holder.** `LICENSE` read
  `Copyright (c) 2026 matt-garman` while all 55 project-authored source headers
  read `Copyright (c) Matthew Garman`, and the release signing key carried a
  third form. MIT grants *from* the named holder, so the notice is what a
  downstream license review reads to identify who could grant a relicense or be
  party to an assignment — a role a GitHub handle does not fill. `LICENSE` now
  reads `Copyright (c) 2026 Matthew Garman <matthew.garman@gmail.com>`, matching
  the source headers and adding a contact path that travels with the notice into
  every downstream copy. `2026` is confirmed as the year of first publication.
  Source headers are unchanged, and published releases are untouched: they ship
  `.hex` images and provenance records, not `LICENSE`, so no signed artifact
  contains the superseded string.
- **External supply-chain inputs are now pinned and integrity-checked.** The
  reviewed XC8 and PIC DFP hashes are verified in one shared installer before
  either download executes; every workflow action is pinned to a full commit
  SHA; checkout credential persistence is disabled and `GH_TOKEN` scoped to
  publication; the complete yasimavr build and runtime environment is
  hash-locked without build isolation or dependency resolution; and the exact
  ATtiny_DFP cache tree is re-hashed on every use rather than trusted once.
- **The PIC10F320 lane now reuses the PIC10F322 harnesses instead of duplicating
  them.** The merge left separate fault, lock-step and target-I/O
  implementations carrying over a thousand duplicated lines. Each is now an
  include-only shared core behind a thin per-part adapter, with processor and
  image defaults, output-macro vocabularies, program-space limits, fault counts
  and the PIC10F322-only LATA injections kept explicit at the adapter boundary.
  A second pass removed what that one left: all four harnesses — the soak
  included, which the first pass did not touch — now share one `gpsim_bootstrap.h`
  for the ~30-line libgpsim bring-up, and the two gpsim CLI wrappers share the
  75 byte-identical lines of tool discovery, timeout validation, `STRICT_TOOLS`
  skip-vs-fail contract, invocation, snapshot extraction and verdict. Bring-up
  is split across two functions rather than one so that every harness keeps the
  work it does between loading the processor and attaching the footswitch, and
  not one simulator operation is reordered in any of the four. Consolidating
  exposed a real defect: `footsw_set(1)` drives RA3 low — PRESSED — while the
  fault core and the soak both documented it as "1 = released", so two of the
  four described their footswitch backwards. One correct comment now lives in
  the shared header. Because a shared file the mutation sandbox does not require
  degrades the PIC10F320 lane silently, both new files are required entries in
  `validate_pic320_sandbox()`.
- **Post-release status language now reflects what shipped.** ATtiny202 and
  PIC10F320 are marked released in the unified `v0.9.6` image set, and the
  PIC10F320 is promoted to release-supported while keeping its constrained-target
  architecture and assurance caveat; the validation narrative points at the
  retained production evidence.
- **The completed PIC10F320 merge plan is marked historical.** It remains useful
  as a section-numbered decision record and is cited throughout the
  implementation, but its paths, targets, scope and status describe the merge
  rather than the tree. A banner now records the merge as complete, preserves
  the body and section anchors, and directs current architecture and validation
  questions to the maintained PIC10F320 documents.
- **The third-party yasimavr patches carry their licensing.** The two
  modified-source patches now identify the pinned yasimavr 0.1.6 source, its
  upstream copyright holder and GPL-3.0-or-later terms, alongside upstream's
  verbatim GPLv3 text, with each patch marked with its license and modification
  date. The root MIT grant is clarified to exclude third-party material carrying
  its own license.

### Added
- **Two ATtiny202 build regressions** covering an absent and a non-executable
  Intel HEX validator; the second is what exposed the guard hole fixed above.
  `test-workload-rebuild`'s "no `clean-tests` in `test-long`" check now reads
  the aggregate's real prerequisites through `make print-TEST_LONG_GATES`
  instead of grepping the recipe line, which the shared inventory would
  otherwise have made blind, plus a check that the query itself resolves so it
  cannot pass vacuously.
- **`make test-soak-reset-witness`** proves that fix stays true. It builds the
  soak driver twice against the same healthy ATtiny85 image — untouched, and
  with a compile-time fixture that disables the timer interrupt mid-run so the
  main loop stops petting the dog — and requires the first to pass with
  `watchdog_failures=0` and the second to fail with a nonzero one. The control
  half is what stops a permanently broken soak from satisfying the failing half
  on its own. Part of `make test` and `make test-long`.
- **A Classic AVR soak-lane mutant**, giving that family the coverage the
  PIC10F322, PIC10F320 and ATtiny202 families already had. It empties
  `hw_wdt_pet()` at its definition — so the call site remains and the build
  stays clean — and is killed by the soak's reset witness. This raises the
  pinned mutation inventory from **93 to 94** (24 core/AVR, was 23); the counts
  quoted in the `0.9.6` entries below are the historical figures for that
  release and are unchanged.

  The two pre-existing watchdog-handshake mutants keep their kill targets but
  had their descriptions corrected: both run on the ATtiny13a lane, where simavr
  models no WDT system reset at all, so neither was killed by the watchdog.
  Deleting the `hw_wdt_pet()` call site leaves the function unused and fails the
  build under `-Werror=unused-function`; breaking the ISR handshake stops the
  debounce state machine and fails the functional, noise-count and lock-step
  assertions.
- **`make test-supply-chain`**, pinning the integrity contract for every
  external input: offline corruption, cache reuse, workflow action pinning and
  token-scope regressions.
- **`make test-fetch-yasimavr`**, an offline regression set for the venv
  fetcher's safety properties — sentinel handling, failed builds and failed
  verification, rename and signal rollback, path aliases, and destinations that
  change late.
- **`make test-pic320-coverage-archive`**, which runs the real coverage target
  and checker against a source-archive fixture with deterministic tool
  stand-ins, and proves that local-mode or index-mode failures stop before
  compilation.
- **Fail-closed regressions for the gates the fixes above touched.** The shared
  target-matrix regression gained AVR-XT whole-matrix lane and missing-marker
  fixtures; `test-ci-local-routing` exercises all four push skip combinations
  through a complete fake AVR-XT preflight and PASS-count route, so the
  ATtiny202-only case cannot regress unnoticed; `test-release-history` gained
  the `autocrlf` artifact fixtures and the line-ending policy assertions; and
  the PIC soak liveness work added synthetic transition, reset and force-reset
  fixtures with complete rebuild dependency wiring.

## [0.9.6] - 2026-07-30

### Added
- **The GitHub workflow files are now validated locally** (`make
  test-workflow-syntax`, and a `ci-local.sh` preflight that runs it first).
  Nothing in the repo had ever parsed them: the release regressions `grep`
  `release.yml` for fixed strings, which succeeds on a file GitHub cannot load,
  and `ci-local.sh` reproduces the job order from a comment header rather than
  from `ci.yml`. An unquoted job `name:` containing `": "` therefore took the
  entire CI matrix down with "Invalid workflow file" after a full clean
  `ci-local.sh` pass. Both workflows must now parse, every job must have a
  runner and steps, every `needs:` must resolve to a declared job, every action
  must be version-pinned, and `ci.yml`'s job list must agree with
  `ci-local.sh`'s CI-JOB MAPPING in both directions -- so a job added, renamed
  or dropped can no longer silently stop being mirrored locally.
- **ATtiny202 (AVR-XT) promoted from development-only to a release-supported
  target**, bringing the release product set to six parts and 18 images. It was
  classified development-only on 2026-07-14, in the middle of the week its
  harness was being hardened; the classification recorded a scoping decision, not
  a technical blocker, and the lane has since caught up with its peers. Its three
  images are now built, qualified, staged and reproduced, and all three ATtiny202
  release soak combinations are run directly.
- ATtiny202 firmware/model **lock-step co-simulation** (`make attiny202-lockstep`),
  the AVR-XT counterpart of the classic simavr co-sim and `pic-test-lockstep`.
  After every settled 1 ms tick it reads the shell's `ctx_` out of simulated SRAM
  and requires all three bytes to equal the shipping core's state after the same
  tick, over both power-on scenarios. This closed the last structural verification
  gap: the harness previously asserted observable behaviour only, so a shell that
  reached the right LED state by the wrong internal trajectory passed.
- A ctypes bridge (`test/avr/model_step_ffi.c`/`.py`) letting the Python drivers
  call the **shipping** `src/bypass_pure.c` through `test/model_step.h`. Python
  cannot include a C header, and re-implementing the algorithm there would
  recreate exactly the drift hazard `model_step.h` exists to eliminate. Its own
  host gate (`make test-attiny202-model-ffi`) asserts independent hard-coded
  algorithm properties, since lock-step mutates model and firmware together.
- An **ATtiny202 mutation lane**: 19 mutants against the AVR-XT shell and the two
  shared coil-pulse widths, each mapped to the gate that observes what the fault
  actually perturbs. Nothing previously established that this lane's suite would
  fail on a defect in the shell it exists to test. One mutant weakens the PA7
  pin-control guard to its pre-hardening bit test rather than defeating it, which
  is what proves the fault matrix's `PIN7CTRL=0x88` injection is load-bearing:
  that value keeps `PULLUPEN` set, so only the exact comparison can reject it.
  Gated on the ATtiny_DFP and the patched yasimavr venv both resolving *and*
  every kill target passing on the unmutated tree, since each `attiny202-*`
  target exits 0 on a missing input and would otherwise report 19 survivors as a
  clean run.
- `make attiny202-test-target`, the fail-closed AVR-XT aggregate (sim + fault +
  lock-step, every variant) that release qualification and release CI run with
  `STRICT_TOOLS=1`.
- ATtiny202 documentation to match its peers: a rationale section, the SOIC-8
  pinout and pin roles, resource utilization, its place in the multi-MCU
  architecture chapter, a full target-validation-layers table, and an explicit
  "Known gaps (AVR-XT — hardware-bench only)" section covering yasimavr's flat
  instruction timing, the unobservable force-reset completion, the two vendored
  simulator patches, the missing shell stack bound, and untested UPDI programming.
- **PIC10F320 integrated as a release-supported target** — the first whose
  firmware does not compile the verified core but implements the debounce
  algorithm directly, because 256 words of flash cannot hold the shared-core
  architecture. Merged from a separate repository with its full history
  preserved. See
  [docs/pic10f320_special_case.md](docs/pic10f320_special_case.md) for what that
  difference does and does not buy, and `docs/pic10f320_merge_plan.md` for every
  decision taken.
- PIC10F320 validation lanes: firmware-to-core equivalence against
  `src/bypass_pure.c` itself (266,144 sequences, all 66 reachable model states),
  per-variant actuation-sequence checks, host fault injection, an exact-line
  firmware coverage gate, real-HEX lock-step, target fault injection, target I/O
  timing, CONFIG-word verification, cppcheck + MISRA across all three variants,
  and a libgpsim soak. The host subset needs only a C compiler and gcov, so it
  runs inside `make test` on every push.
- A dependency-free PIC10F320 final-HEX return-stack oracle now strictly parses
  Intel HEX and explores reachable classic mid-range PIC14 control flow with the
  exact abstract hardware stack. Its host fixtures are in `make test`; the
  fail-closed base `pic320` recipe checks every generated image before marking it
  complete, while `pic320-test-return-stack` rebuilds and rechecks the supported
  three-image matrix against the architectural eight-entry limit as part of
  `pic320-test`.
  Its state and return stack preserve the 9-bit architectural PC; instruction
  fetch alone aliases through the low eight bits to 256 physical words.
- The shared fake-tool PIC build regression now has a PIC10F320-only
  rebuild-trigger lane. Exact output-specific compiler logs prove identical
  `pic320` and host-test requests rebuild, and that changed/restored clock,
  output-variant and host flags reach the current invocation. Canonical target
  counts make activation fail closed; same-name target sentinels enforce
  `.PHONY`, and exact fake-binary execution counts enforce each host run recipe.
  This proves fresh triggering, not byte-for-byte XC8 reproducibility.
- A standing PIC10F320 expected-image regression now pins the complete
  three-variant HEX matrix to the reviewed XC8 V3.10 / DFP 1.9.189 SHA-256
  baseline. Its dependency-free parser and fixtures run in `make test`, while
  `pic320-test-build` performs the real comparison through CI/release
  qualification. The hash gate stays outside mutation kill targets so byte drift
  cannot mask whether each behavioural lane catches its assigned defect.
- A **canonical release product set** (`RELEASE_IMAGES` in the Makefile),
  enforced by the release script, the image verifier and its regression alike.
  Previously the committed directory, the `SHA256SUMS` entries and the fresh
  build were all derived by globbing, so three "independent" checks agreed
  perfectly on a release with an entire MCU missing. They no longer can.
- Three PIC10F320 full-duration soak combinations are required by the release
  pipeline. `v0.9.6` is the first unified release to publish those images as
  release assets; normal CI also publishes its separate development artifact.
- `make pic320-*` targets, `make help` entries for them, and a
  `docs/pic10f320_special_case.md` linked from the README, the design
  documentation, the release documentation and the generated release manifest.

### Changed
- The ATtiny202 soak now emits the same `SOAK_RESULT format=1 ...` machine record
  and `SOAK PASS: <duration> ms ...` line the AVR Classic and PIC soaks do, so all
  three substrates are interchangeable to the release orchestrator. Its schedule
  moved onto a soak clock that excludes the time a liveness round-trip itself
  consumes — the classic loop's semantics — because scheduling on raw simulated
  time lets each round-trip's ~120 ms eat the schedule: invisible over an hour,
  but enough to silently drop the last two or three checks at the release's 24 h
  and fail an otherwise perfect run. `checks` in that record means liveness
  checks, matching the peers; the finer-grained reset-witness sampling is counted
  and reported separately.
- The one fail-closed mutation run (the `pic` CI job) now provisions the ATtiny202
  toolchain too, so a single authoritative run still covers every substrate rather
  than splitting into partial per-job gates. Skip accounting counts PIC and
  ATtiny202 separately, so a partial run always names which substrate went
  unexercised.
- The final-HEX return-stack oracle no longer hardcodes the device geometry.
  `--program-words` supplies the implemented program memory from the device
  pack's `ROMSIZE`, is validated as a power of two inside the 9-bit PC space
  (both supported parts declare `PCBITS=0x9`), and an image carrying program
  data above the declared size is now **rejected outright**. Under-declaring was
  the dangerous direction — the fetch alias would fold a high PC onto a
  different instruction and could report a *lower* depth than the truth — and it
  previously surfaced only as a confusing downstream error about a computed
  `PCL` write at an aliased address. Ten selftest checks pin the alias in both
  directions; the regression is now 149 checks.
- The strict-tools inventory now covers optional-tool recipes for **both** PIC
  chips, not just the two host analyzers it started with.
- MISRA documentation is now a per-target statement rather than a comparison
  against another project, and records deviation **D-4** (the PIC10F320
  analyzer symbol-resolution waiver) that the suppressions file already cited.
- The `pic` CI job covers both PIC parts; `scripts/ci-local.sh` mirrors it and
  documents that `--skip-pic` skips both chips.
- Simulator "known gaps" documentation is now shared PIC content covering both
  parts, rather than two per-repository copies that had already drifted.

### Fixed
- Current release documentation, Make help, source comments, and generated
  manifest wording now consistently describe ATtiny202 as release-supported and
  use the 18-image, 15-soak, 28-evidence-file, 93-mutant contract. Dated
  rehearsal records retain their historical 15-image, 12-soak, and 74-mutant
  results.
- The Classic AVR `timer_isr_called_` fault injection no longer treats an
  already-dark BYPASS LED after roughly 7 ms as proof of watchdog recovery. It
  starts ENGAGED, single-steps to the ISR's handshake write, corrupts it before
  main can read it, and requires both a device-reset witness (simavr's
  `avr->reset` hook, which its watchdog reset path calls) and fail-safe dark
  output after reset. A dedicated mutant removes only that sanity term.
- The ATtiny202 fault matrix now covers `PORTA.PINnCTRL.INVEN` on the LED,
  control/relay, parked-spare, and footswitch pins. The PA7 case preserves its
  pull-up while reversing input polarity, proving the firmware's exact PA7
  control check rather than the old pull-up-only predicate. Exact zero control
  checks similarly protect the four output pins, and the per-variant matrix
  expands from 17 injections / 18 results to 22 / 23.
- Qualification documentation now distinguishes historical phase evidence, the
  clean but non-publishable `4b28210` full-tool rehearsal, and retained
  final-source production evidence. It no longer claims that corrected 74/74
  mutation execution and real-image stack gating never occurred, and the release
  guide scopes the `QUALIFICATION` soak/evidence contract to unified releases
  rather than directing `v0.9.0` through `v0.9.5` to files and targets they
  predate.
- Release publication now requires both cryptographic signatures promised by the
  trust model. CI verifies `SHA256SUMS.asc` and the exact remote annotated tag
  object against the checked-in public key and pinned full fingerprint before
  publishing; missing, empty, malformed, wrong-key, lightweight, unsigned,
  same-target-replaced, and moved tags all fail closed. Signing instructions pin
  the same key explicitly instead of relying on the operator's GPG default.
  Producer and verifier version validation now matches the workflow's optional
  hyphen-suffix trigger and rejects malformed or invalid Git tag names before a
  production qualification run.
- Mutation results now conserve an immutable 93-mutant inventory across seven
  pinned categories: dispatched plus skipped must equal 93, and killed plus
  survived plus errored must equal dispatched. Inventory records, baseline Make
  commands, worker exits, sandbox setup, atomic result pairs, exact status/output
  grammar, and unexpected artifacts all fail closed instead of allowing a
  shortened or partially published run to report "all mutants killed."
- The PIC10F322 `pic` producer now requires the complete immutable output-variant
  matrix before invoking XC8, rejecting empty, duplicate, unsupported, and
  incomplete requests. Classic AVR and PIC10F322 entries in `RELEASE_IMAGES` now
  derive from that immutable set, so a `VARIANTS` override cannot weaken the
  independent release contract along with the requested build. Both PIC matrix
  requests are sanitized before recursive Make or shell expansion, and their
  HEX/assembly/symbol cleanup inventories cannot be disabled by command-line
  overrides.
- PIC builds now invalidate XC8's generated `.s` and `.sym` sidecars together
  with each HEX before compiling and remove the same complete product set after
  failure or interruption. The hardware-stack targets skip only when no current
  HEX exists; a current image without fresh, regular, nonempty assembly now fails
  instead of allowing stale evidence or an absent-tool skip.
- Tag CI now binds retained 24-hour qualification to Git history: the tagged
  release commit must be a single-parent, artifact-only child of the exact source
  commit named by `QUALIFICATION`. A scratch-repository regression rejects wrong
  parents, merge commits, mixed source/release changes, sibling-release changes,
  checkout drift, a snapshot differing from the tagged record, and a remote tag
  that moved before publication.
- Release qualification is now machine-verifiable before publication: an
  immutable 15-combination inventory, exact retained-evidence set, strict
  `QUALIFICATION` schema, and one identity/timing/counter-bearing `SOAK_RESULT`
  per log must agree. Tag CI verifies a private snapshot before installing tools
  and publishes the qualification record; PIC images are hash-pinned across soak
  compilation, execution, and staging just like validated AVR ELFs.
- Dry-run release artifacts cannot be staged under the repository's release tree,
  and tag CI requires an explicit production-mode manifest while independently
  rejecting the dry-run banner before any release can be published. The output
  path is revalidated immediately before staging, and tag-derived values reach
  privileged workflow shells through the environment rather than source-text
  interpolation.
- `pic320-variants` now requires the complete supported build matrix, and the
  canonical release set no longer shrinks with a `PIC320_VARIANTS_ALL` override.
- Release provenance now probes both selected XC8 compilers fail-closed and
  records target-qualified compiler paths and versions instead of attributing
  both PIC image families to `PIC_CC`.
- PIC host and real-target "all variants" aggregates now reject proper subsets
  of the supported matrix instead of running one variant and reporting that all
  variants passed.
- PIC gpsim validation now shares one exact pin-name resolver across all
  libgpsim harnesses and tests RA3 against substring decoys; fake CLI gpsim also
  rejects stimuli not attached exactly once to `ra3`.
- The host lock-step progress regression now compiles and stalls both PIC
  adapters. Dropping the byte-identical child script had accidentally retained
  only the PIC10F322 source path and left PIC10F320 stall handling untested.
- The shared fake-XC8 interruption regression now requires proof that SIGTERM
  reached each PIC build recipe; `pic320` exports its recipe PID so a missing
  variable can no longer masquerade as successful cleanup validation.
- `pic320-size` now fails closed on compiler, image-validation, and summary
  failures and removes every temporary XC8 artifact after success, failure, or
  interruption instead of suppressing the probe pipeline's exit status.
- The shared gpsim wrappers and both public PIC functional targets now honor
  `STRICT_TOOLS=1`; a missing simulator cannot become a successful strict run.
- Standalone PIC10F320 target and soak selectors now rebuild the selected
  variant instead of potentially consuming a stale image while rebuilding the
  default `PIC320_VARIANT`.
- `pic320-test-gpsim` now runs the forked PIC10F320 toggle stimulus instead of
  silently using the PIC10F322 cadence checkpoints through the shared wrapper.
- PIC10F320 mutation sandboxes now include the folded gpsim wrappers and stimuli,
  and the tool probe baselines every distinct kill command. A missing harness can
  no longer make the TMR2IF cadence mutant falsely count as killed.
- The mutation sandbox now mirrors every test source at any depth instead of
  four extensions one level down, restoring 18 PIC mutants that had been silently
  skipped: `test/pic/find_pin_exact.h` never reached the sandbox, and it is a
  prerequisite of both chips' soak binaries and all three target lanes. The
  sandbox validator requires that header, and the self-test proves the copy
  reaches three levels deep. The copy stays an extension allowlist by design —
  `test/` also holds build products, and mirroring them with preserved mtimes
  could make Make skip a rebuild and score a mutant against unmutated source.
- The shared PIC gpsim preflight no longer consults the git index outside a work
  tree, where `git ls-files` reports an empty mode that the guard read as a
  failure. This made `pic320-test-gpsim` unrunnable inside the mutation sandbox;
  the PIC10F322 lane had routed around the same obstacle, so only one chip was
  affected. The local executable-bit check is unchanged and still unconditional.
- Mutation skips now report whether a lane was disabled because a tool was
  absent or because its baseline FAILED, and the closing advice no longer tells
  the reader to install a toolchain that is already complete. With both sandbox
  gaps closed, `make test-mutation MUTATION_ALLOW_SKIP=0` completes all 93
  mutants — 93 killed, 0 survived, 0 errored, 0 skipped.
- The PIC10F320 real-HEX target aggregate now requires explicit fault-injection,
  lock-step, and target-I/O completion markers, so a skipped or incomplete lane
  cannot be reported as a successful CI/release gate.
- **`pic320` and `pic320-size` printed "skipping" and then built anyway.**
  `$(SKIP)` is `exit 0` in non-strict mode and exits only its own shell, so a
  guard on its own recipe line skipped nothing. An audit found no other instance
  in the Makefile.
- **The PIC10F320 build left a partial image set** when one variant failed; it
  now removes the whole set.
- The ported flash-budget comparison was weaker than this project's own and
  conflated "not over budget" with "the comparison tool failed".
- **`pic320-test-gpsim` had no gpsim probe at all**, so `make pic320-test
  STRICT_TOOLS=1` on a host without gpsim reported "all PIC10F320 pre-hardware
  checks complete" having run none of its six scenarios — the wrappers exit 0 on
  a missing simulator by design, and nothing above them looked. The port also
  dropped the `GPSIM=` passthrough, so that override was silently ignored on this
  chip and the lane tested whatever `gpsim` was on `PATH`. Both chips' lanes now
  share one preflight definition, and both are registered in the strict-tools
  inventory (18 → 22 checks) rather than excluded from it.
- `pic320-test-config` now skips cleanly when no image was built, instead of
  handing an unexpanded glob to the CONFIG checker and failing where the
  PIC10F322 lane skipped.

## [0.9.5] - 2026-07-18

### Added
- Fail-closed ATtiny202 production-fuse verification for `WDTCFG`, `BODCFG`,
  `OSCCFG`, `SYSCFG0/1`, `APPEND`, and `BOOTEND`, including host regressions
  proving yasimavr receives the same complete Makefile-defined fuse set.
- ATtiny202 built-image target-output coverage for exact physical PA2/PA3
  startup/engage/bypass sequences, pulse presence and ordering, relay-coil
  exclusion, and low parked outputs, backed by a host-only oracle regression
  for positive and fail-closed trace paths.
- Fail-closed ATtiny202 fault execution now requires all 17 independently pinned
  injectable guards, zero skips, exact result counts, witnessed WDT resets,
  phase-swept ISR-handshake corruption, and a long healthy negative control.
- An ATtiny202 disassembly oracle now verifies absolute 5 ms mute and 12 ms
  relay pulse widths directly from each built image, independent of yasimavr's
  non-cycle-accurate delay execution. *(Note added 2026-08-02: the oracle is
  unchanged and still correct, but that stated reason for it was not — yasimavr
  does model multi-cycle instruction timing. See the correction under `0.9.8`.)*
- Host-only regressions now exercise PIC target-matrix validation and lock-step
  simulator stalls without requiring XC8 or libgpsim.

### Changed
- Complete Make and direct release-script invocations now hold one worktree-local
  lock, preventing independent processes from replacing shared firmware, test,
  coverage, or simulator artifacts while preserving explicitly isolated
  recursive test fan-out.
- Classic AVR, AVR-XT, and PIC10F322 sanity gates now verify the complete
  settled output latch against the logical effect state, including low-driven
  spare pins and inactive relay coils.
- Classic AVR and ATtiny202 sanity gates now require the complete GPIO direction
  state configured at startup, detecting footswitch pins becoming strong outputs
  and intended low-driven spare outputs becoming inputs.
- The PIC10F322 sanity gate now requires the complete TRISA direction state
  configured at startup (exact `0x08`), closing the gap where a spare RA2
  direction upset on the simple-CD4053 variant fell outside the required-subset
  check. Fault injection, shipping-source coverage, and mutation coverage now
  exercise the exact predicate on every variant.
- Routine push, scheduled, and manually dispatched CI now runs mutation testing
  in strict mode on the full PIC-toolchain runner; pull requests retain the
  faster non-mutation path.
- ATtiny202 is now explicitly classified as development-only/non-release. Its
  normal build and yasimavr CI lane remains available, while release images,
  reproduction, and long-soak qualification remain scoped to AVR Classic and
  PIC10F322.
- The full-tool ATtiny202 CI job now runs `make attiny202-test STRICT_TOOLS=1`,
  making its cppcheck and MISRA analysis mandatory alongside fuse, build, and
  flash-budget and pulse-width validation.
- PIC shipping-source coverage is now a required gate, and mutation coverage
  explicitly rejects the wrong unified x4053 BYPASS polarity.

### Fixed
- Long release runs now recheck the recorded source `HEAD` and worktree
  cleanliness after validation and immediately before creating the staging
  directory, refusing to attach artifacts or evidence to stale provenance. The
  dirty-tree exception is now restricted to non-publishable dry runs.
- Tap-timing documentation now scopes the 33 ms minimum to the pure model,
  ISR-driven AVR shells, and simple PIC variant, and records conservative polled
  PIC mute/relay qualification budgets of 38 ms/45 ms plus the pending-timer
  nuance that can shorten the ideal path by roughly one tick.
- Symbolic-test documentation now accurately scopes host/KLEE coverage to every
  invariant-valid state/input tuple and identifies CBMC as the separate proof of
  corrupt program-state handling, released-input recovery of out-of-range
  counters, and undefined behavior obligations.
- The optional KLEE target now compiles and links the symbolic harness with the
  shipping `src/bypass_pure.c` bitcode before execution, preventing unresolved
  core calls from masquerading as a proof of the real implementation.
- `scripts/ci-local.sh --skip-pic` now permits unavailable PIC mutants to skip
  during push-mode `test-long` while retaining `STRICT_TOOLS=1` for host/AVR
  gates; full local-CI runs explicitly keep mutation fail-closed.
- Missing CBMC or cppcheck now fails `test-cbmc` and `analyze-cppcheck` under
  `STRICT_TOOLS=1` instead of silently turning required CI analysis into a skip.
- Native Classic AVR and PIC soaks now require the liveness interval to fit
  within the total run, and short release rehearsals clamp and propagate that
  interval so a passing soak includes at least one responsiveness round-trip.
- PIC flash-budget acceptance now requires a positive decimal budget, compares
  arbitrarily long usage counts without fixed-width shell arithmetic, and
  rejects failed comparisons or missing percentage results.
- Release reproduction now rejects committed-as-fresh and duplicate fresh
  directories after physical-path resolution, then verifies `SHA256SUMS`,
  committed images, and fresh images from one immutable set of private snapshots.
- Historical `v0.9.0` through `v0.9.2` release documentation now prominently
  identifies the superseded `*_tmux*` images whose direct-drive polarity maps
  the absent/undriven-MCU pull-down state to ENGAGED instead of fail-safe
  BYPASS, and directs users to the unified images from `v0.9.3` or later.
- Classic AVR, ATtiny202, and PIC image generation now fails closed on missing,
  stale, partial, malformed, over-budget, or unverifiable output. Intel HEX
  structure, stack/flash/fuse evidence, workload rebuilds, model coverage, soak
  timing, and release image sets all have isolated negative-path regressions.
- gpsim wrappers reject non-positive or malformed timeout values before invoking
  the simulator and propagate process failures or kills even after valid
  snapshots, while libgpsim targets remove stale binaries before rebuilding.
- PIC target fault injection now verifies register identity, write-back,
  simulator progress, exact per-variant completion counts, and restoration of
  negative controls before reporting PASS.
- PIC target aggregates reject empty, duplicate, or unsupported variant matrices
  before execution, and PIC lock-step stalls abort immediately during settle,
  calibration, or completion instead of looping on a frozen cycle counter.

## [0.9.4] - 2026-07-11

### Added
- `make pic-test-lockstep`: a libgpsim PIC10F322 gate that runs the XC8-built
  HEX and compares live `_ctx_` SRAM against the shared pure-model state after
  each completed main-loop iteration.
- `make pic-test-io`: a libgpsim PIC10F322 GPIO/timing gate that checks real
  TRISA/ANSELA/LATA/PORTA transitions, relay coil exclusion, and analog-switch /
  relay pulse widths from the built HEX.
- `make pic-test-target-variants`: a fail-closed aggregate for the PIC
  target-level gates (`pic-test-fault`, `pic-test-lockstep`, and `pic-test-io`)
  across every PIC variant. Component targets may still skip cleanly on a local
  host without PIC tools; this aggregate requires every PASS marker.
- PIC gpsim register-level coverage now includes a mid-debounce `PRESS1_EARLY`
  sample and full BYPASS `LATA` assertions, catching a collapsed tick gate and
  checking all settled analog-switch control bits in both directions.
- Mutation coverage for exact `WPUA`, TMR2IF cadence, ANSELA output masks,
  muted-CD4053 startup ordering, mute-window duration, and relay pulse duration.

### Changed
- CI and release now run `make pic-test-target-variants STRICT_TOOLS=1`, so
  target-level PIC fault, lock-step, and GPIO/timing validation are required.
- Release creation runs mutation testing in strict mode so PIC mutants cannot
  disappear behind skipped target tooling.

### Fixed
- **PIC10F322 weak-pull-up validation now requires the exact RA3-only state.**
  Extra enabled `WPUA` bits on output pins are treated as configuration damage
  and force watchdog recovery.
- **Muted CD4053 startup no longer traverses ENGAGED before settling BYPASS.**
  The driver asserts the bypass-side control first, waits the mute window, then
  releases the second control line.
- Lock-step stimulus is applied at a fresh loop boundary, avoiding relay phase
  lag and startup phase skew.

## [0.9.3] - 2026-07-11

### Added
- ATtiny202 development support: an AVR-XT firmware shell, avrxmega3 build and
  flash-budget gate, cppcheck/MISRA analysis, UPDI programming targets, and
  pinned ATtiny_DFP acquisition.
- A yasimavr functional, fault-injection, and soak harness for ATtiny202, plus a
  dedicated CI lane. The spare PA6 pin is actively driven low.

### Changed
- Build, coverage, mutation, and release gates now fail closed when required
  tools, outputs, percentages, or exact release image sets are missing.
- Release reproduction uses fresh build outputs and validates complete image
  sets instead of relying on committed artifacts alone.

### Fixed
- **TMUX4053 control-pin polarity was inverted on the direct-drive variants.**
  The MCU now uses one fail-safe polarity (BYPASS = pin low) for both CD4053 and
  TMUX4053 boards; the TMUX board's swapped analog throws already compensate for
  the CD4053 board's MOSFET inversion.

### Removed
- The redundant `cd4053_tmux` and `mute_tmux` variants and the
  `BYPASS_X4053_DIRECT_DRIVE` flag. The supported release matrix is now three
  variants (`cd4053`, `mute`, and `relay`) per MCU.

## [0.9.2] - 2026-07-09

### Added
- Per-tick sanity gate now checks `ANSELA` on the PIC10F322: an SEU/EMI flip
  that re-selects an output pin as analog (dark LED / dead control pin, with the
  `TRISA` direction bit unchanged) now forces a watchdog reset. `ANSELA` is
  masked to `BYPASS_OUTPUT_DDR_MASK` (`RA0|RA1|RA2`) and added as a fifth term
  to `hw_critical_sfrs_intact()`.
- Fault-injection coverage for the new `ANSELA` gate term: three inject cases
  (`ANSELA.RA0/RA1/RA2`) in `test/pic/test_fault_pic.cc`, each independently
  proven to force a reset and to fail if the guard is removed.
- `test/README.md` "Known gaps" now records the two PIC properties gpsim cannot
  faithfully assert: WDT-timing / brown-out behaviour, and the TMR2 prescaler
  *select* clamp (gpsim models `T2CKPS = 0b11` as 1:16 instead of the
  datasheet's 1:64) — both are hardware-bench guarantees.
- `CHANGELOG.md`.
- TODO items for two Tier-3 robustness explorations: a hardware-in-the-loop
  validation rig and complemented (inverted-copy) `ctx_` storage.

### Changed
- **PIC10F322 core clock reduced from 16 MHz to 2 MHz** (HFINTOSC), roughly
  halving MCU supply current (~0.85 mA → ~0.43 mA at 5 V) for no change to the
  reliability architecture — the busy-wait tick, per-tick SEU/EMI sanity gate,
  and LFINTOSC-based watchdog are untouched. The 1 ms tick is re-derived on the
  1:4 Timer2 prescaler (`T2CON = 0x05`, `PR2 = 124`) to land exactly 1 ms; the
  `__delay_ms` pulse widths (which track `_XTAL_FREQ`) and the FOSC-independent
  watchdog margin are unchanged. Low power is not a project goal — this simply
  avoids spending ~4 mW where ~2 mW does the same job, and emits less
  high-frequency switching noise into the analog audio path.
- **Renamed the PIC shell `pic10f32x` → `pic10f322`.** This project targets the
  PIC10F322 specifically, so the family "32x" naming is retired:
  `src/bypass_mcu_pic10f32x.c` → `_pic10f322.c`, `bypass_pins_pic10f32x.h` →
  `_pic10f322.h` (include guards included), and the build macro
  `BYPASS_MCU_PIC10F32X` → `BYPASS_MCU_PIC10F322`; every build/test/doc
  reference follows.
- Made PIC `ctx_` fault injection deterministic: the driver now parks the core
  at the main-loop `CLRWDT` (located by opcode, not a hardcoded address) before
  injecting, so no variant can land in the integrate-before-gate window where
  the integrator would overwrite the injected field before the sanity gate reads
  it. (At 2 MHz the previous ms-based settle produced intermittent false
  passes.)
- Normalized every `src/` license header from the "All rights reserved /
  Licensed under the MIT License" three-liner to the self-describing
  `SPDX-License-Identifier: MIT` form already used by the test sources.
- Refreshed the stale Phase-2 design docs with "as-built (2 MHz)" banners
  pointing at the shipped firmware as the source of truth, and corrected the
  Timer2/oscillator bullets (including a `T2CKPS` register description that
  listed 1/4/16 and dropped the 1:64 code).

### Fixed
- **PIC10F322 1 ms system tick ran ~4× slow (~4 ms) on real silicon.** `init()`
  programmed Timer2 with `T2CON = 0x07` (`T2CKPS = 0b11` = 1:64) while intending
  the 1:16 prescale, stretching every debounce interval 4× (press-confirm
  ~8 ms → ~32 ms, release-lockout ~25 ms → ~100 ms). Every simulation-based test
  masked it because gpsim mis-models the `0b11` code as 1:16, and the host /
  equivalence layers count ticks rather than wall-clock time; the defect was
  caught by cross-checking the programmed register against the datasheet
  (DS40001585D, Register 17-1 / Figure 17-1). Now a true 1 ms tick. The
  behaviour was still serviceable — and not a safety regression, the watchdog
  margin was unaffected — but off-spec in the v0.9.0–v0.9.1 prebuilt images.

> These PIC10F322 changes bring the shell to parity with the sibling
> [pic10f320-bypass-firmware](https://github.com/matt-garman/pic10f320-bypass-firmware)
> child project, which landed the same TMR2 / 2 MHz / `ANSELA` work after the
> fork. The pure debounce core and the output drivers are unchanged; the AVR
> targets are unaffected.
>
> *(Historical note, added at the merge: that project is no longer separate — the
> PIC10F320 target now lives in this repository. This entry is preserved as
> written because it describes the state of the world at v0.9.2.)*

## [0.9.1] - 2026-07-04

### Added
- **Per-tick configuration-SFR sanity gate on the PIC10F322 (SEU/EMI
  hardening).** Every main-loop tick now verifies the critical
  clock/watchdog/timer configuration registers (`OSCCON.IRCF`, `WDTCON.WDTPS`,
  `PR2`, `T2CON`); a corrupted value forces a watchdog reset that re-runs
  `init()`.
- `make pic-test-fault` (`test/pic/test_fault_pic.cc`): gpsim critical-SFR
  fault-injection test that corrupts each gate-guarded SFR — extended to the
  `nWPUEN` pull-up and the `ctx_` SRAM fields — and asserts recovery via a real
  watchdog reset. Wired into the release gate.

### Changed
- CI/build no longer degrades silently: a missing/misconfigured analyzer now
  fails loudly instead of skipping, and PIC fault injection is gated in CI.
- Refreshed the stale PIC TMR2 mutation pattern after the named-constant
  refactor so it kills again.
- Design-doc updates: TMUX4053 wiring and toolchain notes.

### Fixed
- Assorted documentation and comment typos.

## [0.9.0] - 2026-06-30

### Added
- Initial release: reference-quality footswitch **bypass firmware** (switch
  debounce → bypass/engage state → status LED) across three MCU families from
  one shared, formally-verified debounce core —
  - **ATtiny13a** (AVR classic, 1.2 MHz),
  - **ATtiny45 / ATtiny85** (AVR tinyx5, 1.0 MHz),
  - **PIC10F322** (16 MHz INTOSC).
- Functional-core / hardware-shell architecture: a pure, MCU-independent
  debounce core (`bypass_pure.c`) driven by thin per-MCU shells that apply the
  result to real hardware, so the same verified logic ships on every target.
- Five output variants per MCU: `cd4053`, `cd4053_tmux`, `mute`, `mute_tmux`,
  and `relay` (analog-switch, TMUX4053 direct-drive, muted, and TQ2-relay
  drives).
- Two-layer validation: a reference model plus a firmware↔model equivalence
  test that pins each shipping binary to the model tick-for-tick.
- Formal verification (bounded model check, symbolic single-step, and CBMC),
  a fault-injection harness with a firmware line-coverage gate, per-variant
  actuation-sequence checks, mutation testing, and a clean MISRA-C:2012 posture.
- Simulation soak testing: 24-hour parallel soaks of every release soak
  combination — simavr for the ATtiny45/85 combinations, gpsim / libgpsim for
  the PIC combinations — plus a PIC CONFIG-word check. The ATtiny13a images were
  covered by the full test suite and the core-identical tinyx5 soaks, but were
  not soaked directly because simavr cannot model their watchdog reset; see the
  [historical soak wording erratum](release/README.md#historical-soak-wording-erratum-v090-v094).
- Reproducible, fully-validated prebuilt-firmware release pipeline: pinned
  toolchain, SHA256-checksummed images, per-release `MANIFEST.md` provenance and
  evidence, and a tag-triggered CI job that rebuilds on a clean runner and fails
  the release on any hash mismatch.

[0.9.8]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.7...HEAD
[0.9.7]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.6...v0.9.7
[0.9.6]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.5...v0.9.6
[0.9.5]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.4...v0.9.5
[0.9.4]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.3...v0.9.4
[0.9.3]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.2...v0.9.3
[0.9.2]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/matt-garman/mcu-bypass-firmware/releases/tag/v0.9.0
