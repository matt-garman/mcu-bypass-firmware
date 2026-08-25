# Pre-v0.9.10 fixes

> **Branch-only working document.** This file records the final review of
> `v0.9.9-polish` and the work required before merging it to `main` and cutting
> `v0.9.10`. Delete this file, remove all references to it, and verify that the
> deletion is machine-enforced before the merge.

## Purpose

The branch is a material reliability and assurance improvement over `v0.9.9`,
but it is not yet ready to merge or release. The review found three release
blockers, one firmware fault-policy decision that needs explicit resolution,
two weaknesses in the normal host validation loop, and several documentation
consistency issues.

This document is the work-detail, planning, and TODO record for closing those
items. Check an item only after its implementation, focused regression tests,
and relevant aggregate validation have passed.

A second-pass review of HEAD `dd26fdf` on 2026-08-24 found additional work.
Most of the first-pass items below are complete, but two fault-escalation paths
do not yet deliver the physical coil-de-energization guarantee that F1 claims;
the static PIC12F675 flashing guide contradicts the guarded programming policy;
and the AVR convenience programming goals can touch hardware before proving the
selected image builds. The second-pass items are recorded after G1. They reopen
the final candidate gate even though the earlier `fe8ecc8` gate run remains
valuable historical evidence.

## Review scope and baseline

- Compared branch head `694d918` with `main`/the signed `v0.9.9` source commit
  `16584d8`.
- Reviewed all 84 changed files: approximately 8,715 insertions and 748
  deletions across firmware, tests, formal checks, Make/release tooling,
  workflows, and documentation.
- Reviewed the firmware changes for C-language behavior, MCU register
  semantics, interrupt/reset behavior, watchdog handling, fail-safe behavior,
  and resource constraints.
- Reviewed release staging, qualification evidence, provenance, publication,
  toolchain pinning, and PIC12F675 programming/recovery paths.
- Reviewed test sensitivity, aggregate routing, retained evidence claims,
  hardware-validation language, and current-release metadata.

## Current assessment

`v0.9.10` will be a material improvement over `v0.9.9` after the work below is
complete. Important improvements already present on the branch include:

- complemented XOR-fold detection of in-range single-bit persisted-context
  faults on AVR Classic, AVR-XT, PIC10F322, and PIC12F675;
- transactional validation, computation, and publication of persisted debounce
  context, including interrupt-atomic AVR main-loop use;
- compile-time watchdog-margin checks on every modular shell;
- one-operation relay-coil clearing, including one shadow update and one
  whole-port write on PIC12F675;
- explicit post-watchdog-reset liveness checks in the PIC fault lanes;
- stronger mutation, target-result, release-image, workflow, and
  supply-chain tests;
- signed-release binding and interrupted-transaction finalization for guarded
  PIC12F675 programming; and
- a frozen, inventoried, revalidated publication bundle plus restored-cache
  integrity checking.

These are real firmware-reliability and release-integrity changes, not merely
editorial polish. They do not add controlled hardware qualification, so the
project's `0.9.x` qualification boundary remains appropriate.

## Required work

### R1 - Bind PIC12F675 release qualification to one retained matrix

**Priority:** Release blocker

**Problem**

The local release script runs `pic12f675-test` and
`pic12f675-test-target-variants` as separate Make processes at
`scripts/make-release.sh:1183-1194`. The public release workflow repeats that
split at `.github/workflows/release.yml:426-436`.

Both public targets depend on the phony `_pic12f675-qualify-matrix` target
(`Makefile:6367-6369`, `Makefile:6453-6455`, and `Makefile:6544`). Separate Make
processes therefore build and qualify separate retained matrices. This violates
the documented contract at `README.md:216-223`, which correctly says that only
one Make invocation can combine the aggregates into one evidence set.

The retained-evidence verifier checks the canonical evidence file set and file
properties at `scripts/verify-release-qualification.sh:183-194`, but it validates
machine-readable records only for soak logs. It does not prove that both
PIC12F675 aggregate logs name one matrix, or that the named matrix is the one
hashed and staged after qualification.

**Recommended change**

- Run both PIC12F675 aggregate goals in one Make invocation in
  `scripts/make-release.sh` and in one release-workflow step.
- Prefer one combined retained qualification log unless there is a concrete
  reason to preserve two filenames. Update the canonical evidence inventory and
  its tests if the filename changes.
- Preserve or add a machine-readable matrix identity containing the complete
  shipping, simcal, assembly, and symbol-sidecar identity.
- Make `verify-release-qualification.sh` require the expected aggregate PASS
  records, require one common matrix identity, and bind that identity to the
  final retained PIC12F675 shipping-image hashes.
- Test the negative cases: different matrix identities, a missing identity,
  duplicate/conflicting identities, one missing aggregate PASS, and a matrix
  identity that does not match the retained images.

**Acceptance criteria**

- [x] One release Make graph qualifies the matrix exactly once and runs both
  PIC12F675 aggregates against it.
- [x] Local release staging retains evidence that identifies that one matrix.
- [x] The clean-runner release workflow uses the same one-graph contract.
- [x] Qualification verification fails closed on split, missing, duplicate,
  conflicting, stale, or image-unbound matrix evidence.
- [x] `README.md`, `release/README.md`, workflow comments, and test
  documentation describe the implemented evidence contract accurately.
- [x] Focused Make, release-qualification, workflow-syntax, release-history,
  and release-provenance tests pass.

### R2 - Make image-defining compiler pins exact

**Priority:** Release blocker

**Problem**

`scripts/make-release.sh:896-906` uses shell substring patterns for the three
image-defining compiler checks. As written, an AVR banner containing `17.3.0`
passes the `7.3.0` check, and an XC8 banner containing `V3.100` passes the
`V3.10` check. That is weaker than the exact preflight enforcement promised by
`TOOLCHAIN.adoc:496-499` and the release workflow header.

The current happy-path fakes at `test/test_release_preflight.sh:123-171` cover
the intended banners but not prefix, suffix, or malformed-token collisions.

**Recommended change**

- Parse a delimited compiler version token from each tool's version output and
  compare it for exact equality with `7.3.0` or `3.10` as appropriate.
- Keep the checks on the actual commands selected by `CC`, `PIC_CC`, and
  `PIC10F320_CC`; do not replace path-aware checks with checks of a default
  executable.
- Fail if the expected token is absent, duplicated ambiguously, malformed, or
  accompanied by an unaccepted suffix.
- Add positive tests for the real accepted banner forms and negative tests for
  `17.3.0`, `7.3.0.1`, `V3.100`, `V13.10`, malformed output, and empty output.

**Acceptance criteria**

- [x] Exactly avr-gcc `7.3.0` is accepted; prefix/suffix collisions fail.
- [x] Exactly XC8 `V3.10` is accepted independently for PIC10F322/PIC12F675 and
  PIC10F320; prefix/suffix collisions fail.
- [x] Diagnostics name the selected tool, observed banner, expected version,
  and corrective action.
- [x] Preflight rejects drift before scratch creation, builds, or soaks.
- [x] `test-release-preflight`, `test-workflow-syntax`, and documentation
  contract tests pass.

**Implementation note**

The comparison lives in `release_pinned_version_matches()`
(`scripts/release-provenance.sh`). It removes parenthesised segments -- GCC's
distributor blob, `avr-gcc (Ubuntu 7.3.0-16ubuntu3) 7.3.0`, which is not the
compiler version and must not be mistaken for it or make the line ambiguous --
then splits on whitespace alone, so a version token keeps whatever was attached
to it and is compared whole. `7.3.0.1` is one token rather than a `7.3.0`
prefix, and `V3.100` is one token rather than `V3.10` plus a digit. A banner
must yield exactly one version-shaped token: none (prose-only or malformed) and
several (ambiguous) both fail, so the check cannot pick a version out of a
banner form it does not recognize.

Of the four drifted versions this item names, the substring patterns accepted
three. `V13.10` was already rejected, because `*V3.10*` does not match it; it is
covered anyway so the reverse collision is pinned on both XC8 selectors.

Coverage is split by cost. `test_release_provenance.sh` enumerates 21 banner
forms directly against the helper, where each case is free, and additionally
requires each of the three pins to name its own selected tool and to run before
the preflight exit and the clean build. `test_release_preflight.sh` proves the
wiring end to end -- one drifted banner per selector, a compiler that reports no
version at all, and a distributor-blob banner that must still pass -- at the
cost of a whole preflight each.

While building this, two gate runs failed with exit 1 and no output at all. The
cause was in the harness, not the change: most cases run the release as
`run_preflight >"$output" 2>&1`, so a `fail()` raised INSIDE `run_preflight` --
the worktree-mutation and forbidden-invocation guards -- was written into a
scratch log that `cleanup()` then deleted. `fail()` now writes to the shell's
original stderr, so those guards report themselves. (What actually tripped them
was editing a tracked file while the suite ran.)

### R3 - Repair signed-release PIC12F675 recovery instructions

**Priority:** Release blocker

**Problem**

The `pic12f675-finalize` examples at `README.md:172-177` and
`release/README.md:382-387` omit `PIC12F675_RELEASE_TAG="$release_tag"`. A
transaction reserved by `pic12f675-release-program` carries the release identity,
and finalization passes the caller-selected identity to the recovery oracle at
`Makefile:6782-6829`. Following either static example therefore rejects a valid
PENDING signed-release transaction rather than finalizing it.

The generated per-release documentation already includes the release-tag
argument. `Makefile:7846` also incorrectly describes `PIC12F675_RELEASE_TAG` as
release-program-only even though read-only finalization consumes it.

**Recommended change**

- Add `PIC12F675_RELEASE_TAG="$release_tag"` to both static finalization examples.
- Correct `make help` to include release-bound finalization.
- Add a documentation/source contract that checks all published
  signed-release finalization commands, including generated release
  documentation, for the same required identity arguments.
- Add or retain negative coverage proving that omitting or changing the tag
  rejects a release-bound reservation before any device read.

**Acceptance criteria**

- [x] Both static examples can finalize a transaction created by the preceding
  signed-release programming example.
- [x] Generated and static instructions carry the same release identity.
- [x] `make help` describes the variable's complete supported scope.
- [x] Documentation contracts detect a future omission or drift.
- [x] PIC12F675 trim-evidence, release-program-image, release-preflight, and
  static documentation tests pass.

**Implementation note**

`release_validate_pic12f675_finalization` in `scripts/release-documentation.sh`
scans every PUBLISHED finalization command -- a `make` invocation inside a fenced
block, continuations joined, parsed into words -- and anchors each one to the
nearest programming command published before it in the same document. The rule
is therefore not "always pass the release tag" but "pass the identity of the goal
that reserved the transaction": required after `pic12f675-release-program`,
refused after `pic12f675-program`, whose reservation records no release identity.
Every other reserved argument must repeat the preceding command's VALUE, not just
its name -- a recovery pointing at a different variant or result directory fails
the same way an omitted one does. The release tag is the one exception, checked
for presence only: the generated recovery block deliberately embeds the resolved
tag so recovery does not depend on a shell variable surviving from the
programming block, while both static examples carry `"$release_tag"` twice.
It runs in `--preflight`, on the live tree, so a drifted example fails on a
polish branch rather than after a builder has already lost a PENDING transaction.

`README.md` and `release/README.md` are always scanned, so deleting the example
fails; any other current markdown that publishes the command is discovered rather
than enumerated. Shipped `release/<version>/` directories are excluded --
`release/v0.9.9/MANIFEST.md` legitimately publishes the older unsigned
`pic12f675-program` transaction and must not be rewritten to satisfy a contract
introduced after it shipped. Prose that merely names a goal is not a command;
`test/README.md` names all three that way, including one line that begins with
`make`, so a line-level match would have failed the live tree.

`make help` is pinned separately, since it is the other place the variable's
scope is published: the retired "(pic12f675-release-program only)" claim must be
gone, and the `pic12f675-finalize` entry must name the variable it needs.

Negative controls, since a documentation contract is easy to write vacuously.
Restoring `README.md` to its defective form makes the real
`scripts/make-release.sh --preflight v0.9.10` exit 1 by name. Weakening the
recovery oracle to compare only `release_source_commit` lets the substituted-tag
recovery reach `PIC12F675_TRIM_RECOVERY_READY PASS` and fails the new
`test_pic_build.sh` case -- which the pre-existing omitted-identity case does not
catch, because omission also drops the commit. Reverting each half of the help
text independently fires its own guard.

The new PIC12F675 case is folded into the existing check slot rather than
incrementing the count: `expected_checks=126` is mirrored in a `Makefile`
comment, and both assertions test one contract (the recovery identity must match
the reservation) in the same block.

### F1 - Resolve the silent relay-state desynchronization risk

**Priority:** Firmware safety/correctness decision before release

**Problem**

`src/bypass_output_tq2_l2_5v_relay.c:77-79` silently clears unexpectedly
energized relay coils. Every modular shell calls this operation before its
output sanity gate. The intended pulse is bounded to roughly one tick at the
tested settled seams, and `docs/relay_coil_fault_correction.md:42-58` correctly
notes that this is below the relay's specified 4 ms minimum pulse for guaranteed
actuation but is not proven mechanically harmless.

If the short pulse does move the latching relay, silent clearing leaves the
physical audio route inconsistent with the firmware's effect state and LED. The
old reset path eventually initialized the relay to a known BYPASS state. The new
policy minimizes disruption when the short pulse does not actuate, but it gives
up guaranteed eventual resynchronization if the pulse does actuate.

This is an intentional and documented tradeoff, not undefined C behavior or an
MCU-register implementation defect. It nevertheless affects the firmware's core
physical-state contract and needs an explicit disposition before release.

**Recommended disposition**

Prefer fail-safe resynchronization:

- detect unexpected writable coil state before clearing it;
- clear both coils immediately so the fault cannot remain energized;
- report the correction to the shell; and
- force watchdog recovery, or otherwise issue a complete state-restoring pulse,
  so logical state, LED state, and physical relay state converge again.

A watchdog recovery to the known BYPASS initialization state is the simpler
fail-safe model, but implementation cost must be measured on PIC10F322 and the
256-word PIC10F320 special case. A direct state-restoring pulse is an alternative
only if its watchdog margin, fault behavior, and logical-state assumptions are
proved.

If silent correction is retained instead, the release should explicitly accept
possible persistent logical/physical desynchronization and should add hardware
characterization across representative relays, voltage, temperature, and pulse
phase. Testing samples cannot turn a below-minimum pulse into a datasheet
guarantee, so this is the less conservative choice.

Actual firmware-source changes under this item are to be made by the repository
owner, consistent with project policy.

**Selected disposition (recorded by the repository owner)**

Fail-safe resynchronization, implemented as watchdog recovery to the known
BYPASS initialization state. The policy and its rationale are recorded in
`docs/relay_coil_fault_correction.md`; `DESIGN_DOCUMENTATION.adoc` and
`CHANGELOG.md` carry the same statement.

The loop-top `hw_outputs_reassert_safe()` call is removed from all four modular
shells and from PIC10F320's inline equivalent. An energized coil is now detected
by each shell's existing output-state integrity gate and escalated;
`hw_force_wdt_reset()` calls `hw_outputs_reassert_safe()` (PIC10F320:
`set_relay_coils_low()`) as its first act, so both coils are de-energized before
the spin, and the recovery re-runs `init()`, whose complete 12 ms RESET-coil
actuation restores agreement between logical state, LED, and physical relay.

Measured cost, relay variant then all variants:

| Part | Before | After |
| --- | --- | --- |
| PIC10F322 | 493 words | 493 words (476 / 502 unchanged) |
| PIC10F320 | 245 words | 248 words (220 / 241 unchanged) |
| PIC12F675 | 563 words | 563 words (546 / 572 unchanged) |
| ATtiny13A | 864 B | 868 B (+4 B each variant) |
| ATtiny202 | 994 B | 998 B (+4 B each variant) |

Only PIC10F320 pays anything: three words for the coil-only `LATA` term that
gives it parity on the coil guarantee within its 256-word budget. Its documented
general output-latch gap is unchanged, and is now pinned by a negative-control
fault case rather than only described.

**Acceptance criteria**

- [x] The repository owner records the selected policy and rationale.
- [x] Every relay-capable shell has a clearly stated correction and
  resynchronization guarantee, including the PIC10F320 exception if capacity
  prevents parity.
- [x] Tests distinguish coil de-energization from physical relay-state
  synchronization instead of treating final-low output alone as full recovery.
- [x] Fault tests cover BYPASS plus unintended SET and ENGAGED plus unintended
  RESET outcomes.
- [x] Active-pulse and instruction-phase exclusions remain explicit.
- [x] Flash, RAM, stack, timing, watchdog-margin, simulator, fault, mutation,
  coverage, and target-result gates pass for all affected variants.
- [x] Documentation states what simulation cannot prove about relay mechanics.

### T1 - Restore PIC10F322 host-coverage compiler portability

**Priority:** Pre-merge validation defect

**Problem**

`pic10f322-coverage-check-fw` fails under the repository's default `cc` on this
workstation, GCC 8.5, because strict conversion warnings become errors in the
new OR-fold expressions at `src/bypass_mcu_pic10f322.c:164-170` and
`src/bypass_mcu_pic10f322.c:221-226`.

`README.md:110-113` currently requires only a host C compiler; it does not state
a GCC 13+/Clang 18 floor. The target compiler accepts and fits the firmware, but
the host shipping-source coverage contract is not portable across the host
environment the documentation claims.

**Recommended change**

- Prefer making the expressions warning-clean under the existing strict flags
  and older supported GCC rather than narrowing the host-tool contract solely
  to accommodate integer-promotion diagnostics.
- Preserve the compact target code and verify PIC10F322 remains within its
  512-word limit, especially the current 502-word mute variant.
- If portability cannot be achieved without an unacceptable target-size cost,
  define, document, and enforce the minimum host compiler/version with an early,
  actionable diagnostic.
- Add the affected host compiler to local/CI compatibility coverage if that is
  practical without weakening the pinned image-defining toolchains.

Actual firmware-source changes under this item are to be made by the repository
owner.

**Acceptance criteria**

- [x] `pic10f322-coverage-check-fw` passes with the documented minimum host
  compiler and all strict conversion warnings enabled.
- [x] The target XC8 build remains warning-clean and within every variant's
  flash budget.
- [x] No cast suppresses a real narrowing or changes the integrity predicate.
- [x] Source coverage still measures the shipping configuration with
  `BYPASS_CTX_CHECK` enabled.
- [x] Relevant static analysis, model, target, mutation, and build tests pass.

**Implementation note**

Resolved by the item's third bullet -- a defined, documented and enforced host
compiler floor -- rather than by changing the firmware. No shipping source was
touched, so the last four criteria hold by construction: the images are
byte-identical to `9a7c479`.

*The defect, reproduced.* No GCC 8.5 exists on the implementation host, so the
Ubuntu `gcc-9` 9.5.0 packages were unpacked into a scratch prefix (not
installed). GCC 9 shares the pre-GCC-10 behaviour and reports **exactly four**
errors, all in `src/bypass_mcu_pic10f322.c` -- lines 166, 167, 170 and 232 --
matching the review's count and both ranges it cited. A full host-suite sweep
under GCC 9 found no other diagnostic anywhere in the repository; the PIC12F675
lane is clean, as the review also reported.

*Why those four.* The casts are already present. GCC 9 and older fold an
explicit `(uint8_t)` cast away whenever the operand provably fits in eight bits
-- a narrow bitfield read (`OSCCONbits.IRCF`, `WDTCONbits.WDTPS`,
`OPTION_REGbits.nWPUEN`) or a read masked with a small constant (`ANSELA &
BYPASS_OUTPUT_DDR_MASK`) -- leaving an `int`-typed tree, and then report the
compound assignment that narrows it back. Lines 168, 169 and 231 survive
because their outermost cast is not foldable. GCC 10 stopped reporting it;
measured on identical sources, GCC 9.5.0 gives four errors and GCC 10.5.0 gives
none, which is what fixes the floor at 10 rather than 9.

*Why not the source change.* Making the writeback explicit
(`diff = (uint8_t)(diff | X)`) costs exactly one PIC10F322 word per converted
site: `IORWF f,F` becomes `IORWF f,W` plus `MOVWF f`. Five candidates were
built and measured against the 512-word budget (all GCC 9 clean, all passing
`make pic10f322-test`):

| candidate | simple | mute | relay |
| --- | --- | --- | --- |
| unchanged | 476 | 502 | 493 |
| all ten folds explicit | 486 | **overflows** | 503 |
| the four hoisted into `uint8_t` locals | 485 | 511 | 502 |
| uniform: first term initializes, folds explicit | 480 | 506 | 497 |
| minimal: only the four diagnosed sites | 476 | 502 | 493 |

The uniform rewrite is the only readable one that fits, and it spends four of
the ten words `cd4053_with_mute` has left to satisfy a compiler that has been
superseded for five years. The minimal rewrite is free but leaves two lines in
a block differing from their neighbours for a reason no reader can see, and
re-breaks on any edit that makes another term's cast foldable.

*What is enforced.* `test/host_compiler_version.sh`, the C counterpart of
`test/python_version.py`, and the `host-compiler-valid` gate that runs it. It
**probes the construct** rather than parsing a version banner, so a compiler is
judged by what it accepts and a hypothetical backport would be accepted
correctly; `MINIMUM_GCC` exists to make the diagnostic actionable and to be the
number the documentation publishes. The gate is second in `TEST_GATES_EARLY`
(right after `python-version-valid`, whose comment explains the position), a
prerequisite of `pic10f322-`, `pic12f675-` and `pic10f320-coverage-check-fw`
for direct invocation, and part of `assert_host_toolchain` so a local CI
reproduction says so in PREFLIGHT instead of twelve minutes into the PIC job.
Verified end to end: on GCC 9 all three entry points stop with the diagnostic
naming the compiler, its version, its own error text and the corrective action;
on GCC 10.5.0 `pic10f322-coverage-check-fw` runs green.

*Drift.* Five contract checks in `test/test_release_preflight.sh` (85 total,
was 80). Each was confirmed to bite by reverting the thing it guards: dropping
the gate from the aggregate, dropping the prerequisite from a coverage target,
bumping `MINIMUM_GCC` without republishing it, making the gate accept every
compiler, and removing the corrective action from the diagnostic. The published
floor is matched against the document with its line wrapping collapsed, so
reflowing the paragraph that carries it is not a failure.

### T2 - Put both modular PIC shipping-source coverage gates in `make test`

**Priority:** Pre-merge validation-routing defect

**Problem**

The shared `TEST_GATES` inventory at `Makefile:2798-2824` omits
`pic10f322-coverage-check-fw` and `pic12f675-coverage-check-fw`. Neither gate
needs XC8, a DFP, gpsim, or libgpsim, but both currently sit behind standalone
PIC aggregates whose other lanes do need those tools.

`TODO.md:408-460` records the concrete consequence: relay-correction and context
integrity changes, a stale host fault oracle, a non-shipping compile
configuration, and a broken coverage anchor coexisted with a green default suite
on this branch. The same class of regression can recur until these host-only
gates join the normal edit loop.

Implement this after T1 so `make test` does not intentionally become red on a
documented/default host compiler.

**Recommended change**

- Add both coverage checks to the one shared `TEST_GATES` inventory so `test`
  and `test-long` remain aligned.
- Ensure the targets run without XC8/DFP/gpsim and cannot skip merely because a
  target matrix was not built.
- Add aggregate-routing tests proving each target appears exactly once in both
  fast and long graphs.
- Update timing and tool-contract documentation; current measured cost is about
  19 seconds on the review host.
- Remove `TODO.md` item `T25-fw-coverage-in-test` when its acceptance criteria
  are satisfied.

**Acceptance criteria**

- [x] `make test` on a host without PIC target tools executes both shipping-
  source coverage gates and reports their exact check/coverage results.
- [x] `make test-long` executes the same gates exactly once.
- [x] A mutation removing relay correction or context-check integration turns
  the default aggregate red through the relevant host oracle.
- [x] Standalone PIC aggregates still execute and verify the gates.
- [x] Aggregate routing, workload, rebuild, and clean-contract tests pass.

**Implementation note**

Resolved as recommended: both gates were added to the one shared `TEST_GATES`
inventory, closing `TEST_GATES_EARLY` immediately after the PIC10F320 host
lanes. No firmware source was touched. `test` and `test-long` both pick them up
from the same variable, which is the property the shared inventory exists to
provide, so no second prerequisite line was written.

*Why the tool contract permits it.* `test/pic/fw_coverage/run_fw_coverage.sh`
needs a host C compiler, `gcov` and Bash, all already required by `make test`,
and reads no HEX. It has no skip path at all -- it runs under `set -euo
pipefail`, so a missing tool is a failure, not a silent pass. Principle 5 is
therefore satisfied rather than bent, exactly as it was for
`pic10f320-test-host-variants`. Measured cost on this host: 8.5 s for the
PIC10F322 gate and 11.9 s for the PIC12F675 gate, against the ~19 s the item
predicted.

*Criterion 1, run literally.* `make test PIC_CC=/nonexistent/xc8-cc
PIC_DFP=/nonexistent/dfp GPSIM=/nonexistent/gpsim` exits 0 with both gates
reporting their exact results -- 53 / 53 / 67 harness checks and the full gcov
line table for the PIC10F322, 86 / 86 / 105 plus the coverage-oracle negative
probe for the PIC12F675. No gate in the aggregate so much as tried to reach the
missing tools, which is the property being claimed: `run_fw_coverage.sh` names
XC8, the DFP and gpsim nowhere, and calls only `$CC`, `$GCOV` and its own
harness.

*What the PIC12F675 case actually was.* Worse than "standalone". The
`pic12f675-test` aggregate skips **as a whole** when XC8 has qualified no matrix
("no qualified PIC12F675 matrix (XC8 absent?)"), which is correct for every
other lane -- each reads a real HEX -- but meant the one lane needing nothing
XC8 provides did not run on precisely the hosts where it was the only PIC
evidence obtainable. Direct membership fixes that; the aggregate still lists the
lane, so nothing was moved out of it.

*Routing assertions.* Folded into `test/test_workload_rebuild.sh` (23 -> 28
checks) rather than given a new gate, because that file already owns the
"ask Make for the aggregate's ACTUAL prerequisite set" idea and states why a
textual check of the two lists would miss the failure. Three properties, all
compared against Make's own resolved variables:

1. `test` and `test-long` resolve to the same gate set apart from
   `test-mutation`, in **both** directions -- a gate added to one aggregate only,
   or dropped from one only, fails naming itself.
2. Neither aggregate names any gate twice. A duplicate is not a double
   execution (Make runs a phony prerequisite once); it is the fingerprint of a
   hand edit against a list that already had the entry, and the next hand edit
   removes only one copy.
3. Both coverage gates appear exactly once, named explicitly because they are
   the two that were mis-routed.

Property 1 is new coverage: nothing previously checked that the two aggregates
agree. Negative controls, each run in a scratch tree: adding `test-soak` to
`TEST_LONG_GATES` alone fails with `test and test-long do not run the same
gates: > test-soak`; listing `pic10f322-coverage-check-fw` twice fails with
`TEST_GATES lists a gate more than once`; dropping it fails with `appears 0
times in the shared gate inventory, expected exactly 1`.

*The oracle demonstration, and what the control actually showed.* In a scratch
tree with `hw_outputs_reassert_safe()` removed from the PIC12F675 shell's fault
path, `make test` now exits nonzero at `pic12f675-coverage-check-fw` with
`PIC shipping-source coverage harness: 105 checks, 4 failures`, naming the four
coil-escalation cases (`GP1`/`GP2` shadow faults and both physical coil
divergences) that no longer see the coils de-energized before the reset spin.

The same mutation was then run against a `git archive HEAD` tree, and the
control is worth recording precisely because it is not the simple "was green,
now red" it was expected to be. That tree ran the **whole of
`TEST_GATES_EARLY` green** -- no gate in the fast half saw the defect -- and the
only failure in a 3,869-line log came far into the LATE half, at
`test-mutation-sandbox`, as `PIC12F675 mutation 1 did not change
src/bypass_mcu_pic12f675.c`. That is not detection: it is the sandbox selftest
noticing that a hand-mutated working tree collides with a catalogued mutant, and
it names nothing about relay behaviour.

The collision is the finding. `PIC12F675_MUTATIONS[1]` is literally
`s@hw_outputs_reassert_safe();@@`, so this defect was already catalogued -- but
its kill target is `PIC12F675_TARGET_VARIANT=tq2_l2_5v_relay
pic12f675-test-target`, which needs XC8, gpsim and libgpsim and runs only under
`test-mutation`, i.e. only in `test-long` and only on a fully equipped host. On
the AVR-only host this item is about, the defect's sole oracle was unavailable
and would be reported skipped. After this change a pure host oracle inside
`make test` covers it, which is the whole point of the item.

*Documentation.* `test/README.md` now states that membership follows the tool
contract rather than the part, that all three `*-coverage-check-fw` gates are
members, and what the previous routing cost; both contract-table rows are marked
`make test` members, and the PIC10F322 row also records that the gate compiles
with `BYPASS_CTX_CHECK` because that is what ships. `make help` marks both. The
two standalone-aggregate comments in the Makefile explain why each keeps a lane
that `make test` also runs. `TODO.md` item `T25-fw-coverage-in-test` and its
index row are removed (`test-todo-index`: 93 -> 90 checks).

### D1 - Separate field-use reports from controlled hardware qualification

**Priority:** Documentation correctness before release

**Problem**

`HARDWARE_VALIDATION_LOG.md:4-10` and `HARDWARE_VALIDATION_LOG.md:21-29` describe
linked build/field reports as firmware tested on actual hardware. In contrast,
`DESIGN_DOCUMENTATION.adoc:23-28`, the changelog qualification boundary, and
`TODO.md:479-485` say that no current target has run on silicon or completed the
hardware-validation pass.

The reports are valuable evidence of real-world use, but the current table does
not retain enough information to serve as controlled qualification: exact
source/image identity, board revision, test date, programmer/fuse details,
procedure, observations, and acceptance result are absent. The unconditional
interchangeability statements at `HARDWARE_VALIDATION_LOG.md:37-38` also need to
distinguish pin compatibility from target-specific images, fuses/configuration,
and electrical limits.

The review environment is air-gapped, so linked external reports were not
opened or independently assessed.

**Recommended change**

- Split the document into community/field-use reports and controlled project
  hardware-validation records.
- Define the minimum retained fields for controlled qualification.
- Change project-wide wording from "never run on a device" to the accurate
  distinction: field use may exist, but controlled project qualification has not
  yet been completed.
- Qualify interchangeability claims and require the correct target-specific
  image and fuse/configuration procedure.
- Keep the `1.x.y` boundary tied to the controlled, reproducible hardware pass.

**Acceptance criteria**

- [x] Every hardware claim is classified as field report or controlled
  qualification.
- [x] No project document contradicts the hardware log.
- [x] Controlled records require reproducible source/image and procedure data.
- [x] Pin-compatible parts are not described as firmware/programming-
  interchangeable without qualification.
- [x] Documentation and source-contract tests pass.

**Implementation note (2026-08-23).** Resolved. The log now carries two bounded
sections; the `1.x.y` criterion is restated project-wide as *controlled hardware
qualification*; the interchangeability notes are replaced by the actual
constraint; and `release_validate_hardware_claims` enforces all of it from
`--preflight`, which runs on the live tree inside `make test`.

*What the contradiction actually was.* Both sides of it were wrong, which is why
neither could simply be deleted. `HARDWARE_VALIDATION_LOG.md:4-5` said the table
recorded "which firmware has been flashed-to and tested on actual hardware" over
three rows of forum links, which claims qualification the project never
performed. `CHANGELOG.md`, `DESIGN_DOCUMENTATION.adoc`, `TODO.md`, the
`Makefile`, `docs/pic12f675_feasibility.md` and `docs/pic10f320_merge_plan.md`
said no part had ever run on a chip, which is false: builders really have
flashed released ATtiny13a and PIC10F320 images and reported them working. A
reader could take
whichever suited them, and the repository would support either. The fix is not
to pick a side but to stop using a vocabulary in which one sentence has to cover
both — hence *field-use report* and *controlled hardware qualification* as
separate, separately-evidenced terms.

*Criterion 3, made structural.* Section 2 defines eleven fields (Date, Operator,
Source commit, Image, Part, Board, Programmer, Configuration, Procedure,
Observations, Result) and the validator requires each one to be defined there
and present in every record. So the first record anyone writes cannot be a build
report with a heading on it: an entry carrying a date and a verdict is rejected
field by field, naming each thing it does not retain. That is the substitution
this split exists to prevent, and it is the one that would otherwise happen
years from now, quietly, by someone acting in good faith.

*Ordering, stated rather than papered over.* The **Procedure** field references a
document that does not exist — `T3-hw-procedure`. So no record can currently be
complete, and both the log and that TODO item now say so. The alternative was to
weaken the field list until a record could be written today, which is the
failure mode in miniature.

*The vocabulary check, and why it is a sound proxy.* The validator forbids the
`run on silicon / run on a part` idiom in every durable `.md`, `.adoc` and the
`Makefile`, in **either polarity**. That is not prudishness about phrasing: the
idiom is precisely the claim that cannot be true and false at once here. Its
negation is falsified by the field reports; its affirmation asserts the
qualification nobody performed. Any accurate sentence in this area has to name
which kind of evidence it means, so the idiom's absence is a mechanical proxy for
the distinction being drawn. Shipped `release/vX.Y.Z/` artifacts and root-level
branch-only working documents are pruned — both legitimately quote the retired
wording, this file among them.

*Interchangeability.* `HARDWARE_VALIDATION_LOG.md:37-38` asserted that the AVR
classic trio and the PIC10F32x pair "can be used interchangeably", unqualified.
Pin compatibility is a **board** property. The AVR trio needs a different image
*and different fuse bytes* per part — ATtiny13a at 1.2 MHz (`0x4a`/`0xf9`), the
tinyx5 pair at 1.0 MHz (`0x62`/`0xcc`) — so a chip swap without both gives wrong
debounce and wrong pulse widths on a device that still appears to work, which is
the same failure signature as PIC12F675 trim loss. The PIC pair needs each
part's own image with its own CONFIG word and a matching programmer part name;
they are not even the same firmware, since the PIC10F320's 256 words force the
self-contained build. The exact retired sentence is pinned by the validator,
because that is what a revert restores.

*One historical document was corrected rather than rewritten.*
`docs/pic10f320_merge_plan.md`'s dated 2026-07-27 renumbering rationale asserted
that none of these designs had run on a part. It was already inaccurate when
written — the ATtiny13a pre-v0.9.0 build report predates it. The decision and
its reasoning are preserved; a bracketed correction records what the criterion
actually was and points at the log. Rewriting a dated maintainer rationale to
match today's vocabulary would have destroyed the record it exists to be.

*Naming a retired phrase is not using it.* The first full run caught this, and
it caught it in my own prose: the vocabulary scan failed on `CHANGELOG.md` and
`test/README.md`, both of which quote the retired idiom in the course of
describing its retirement. That is not a false positive to be waived — it is a
real distinction the contract had not drawn. Code spans and double-quoted spans
are now blanked before matching, so only surviving prose counts. A bare
assertion sharing a line with an unrelated quotation is still caught, and both
directions are pinned by cases.

*Verification.* `test-release-preflight` 85 -> 101 checks. Twelve of the sixteen
new checks are negative controls run against a fixture copy of the shipped log,
each confirmed to fail with its own diagnostic: a part row outside both sections;
a duplicated marker; a dropped field definition; a record standing under the
no-record declaration; a field report wearing a qualification heading (rejected
for all eight fields it omits); a section 2 that neither declares nor records; a
removed pin-compatibility qualification; the retired idiom in another document;
the retired interchangeability sentence; a bare assertion beside a quotation; a
missing log; and a missing argument (rc 2, not a vacuous pass). Two controls run
the other way: shipped `release/v0.9.9/MANIFEST.md` and root-level
`pre-v*-fixes.md` / `v*-polish.md` fixtures carrying the retired wording must
still be accepted, or this contract could not have been introduced at all, and
so must a document that quotes both retired forms to retire them. The last check
runs the validator against the live checked-in tree, which is what pins
`README.md`, `CHANGELOG.md`, `DESIGN_DOCUMENTATION.adoc`, `TODO.md`, the
`Makefile` and everything under `docs/`.

### D2 - Reconcile remaining evidence and simulator wording

**Priority:** Documentation polish before release

**Recommended changes**

- Reconcile `docs/context_seu_detection.md:3-6`, which says target-toolchain
  qualification is pending, with the completed provisioned run recorded at
  `docs/context_seu_detection.md:285-302`. Distinguish completed local evidence
  from not-yet-retained v0.9.10 release evidence.
- Correct `test/README.md:803-805`, which still says the AVR-XT output tracer
  calls `SimLoop.run(1)`, to match `test/README.md:357-384`: timing/output tracing
  now uses signal hooks and millisecond budgets, while only the non-timing
  transaction-seam probe deliberately single-steps.
- In `docs/pic10f320_special_case.md`, describe relay correction as appropriate
  for that variant and use "modeled `PORTA`" rather than physical-hardware
  language for simulator observations.
- Update `.github/workflows/release.yml:15-27` and `.github/workflows/ci.yml`
  header comments so they include PIC12F675 and do not call a moving hosted
  runner pinned.

**Acceptance criteria**

- [x] Qualification state is consistent within each design/evidence record.
- [x] Simulator evidence is never described as a physical-hardware observation.
- [x] Current tracer mechanics are described consistently.
- [x] Workflow headers match the actual gates and pinning model.
- [x] Workflow-syntax and documentation contract tests pass.

**Implementation note (2026-08-23).** Resolved. Two of the four bullets were
already closed by earlier items in this cycle and are recorded below as verified
rather than changed; the other two were corrected, and the sweep behind them
found three more instances of the same category error.

*Local completion is not retained release evidence.* `docs/context_seu_detection.md`
opened by calling target-toolchain qualification "still pending" while its own
evidence section recorded a fully provisioned run that passed the AVR/XC8 builds
and resource gates, the simavr/yasimavr/gpsim lanes, CBMC, static analysis and
all 132 mutants with nothing skipped. Neither statement is false about the thing
it means; the header simply used one phrase for two different claims. The
distinction now stated in both places is the same one D1 drew for hardware: the
run is *complete* and it is *local*, and what does not exist yet is *retained*
release evidence -- a signed `v0.9.10` MANIFEST binding those gates to one
published commit. The header also now points at `HARDWARE_VALIDATION_LOG.md`,
because the third claim this record does not make is a hardware one.

*The tracer description contradicted its own file.* `test/README.md:833-836` said
the ATtiny202 output tracer calls `SimLoop.run(1)` and repeated the superseded
"one cycle per instruction" account, 450 lines after the same file corrects it.
That correction is the one recorded in the `yasimavr-flat-instruction-timing`
note: the halving was an artifact of measuring by single-stepping, not a core
defect. The mutation-mapping paragraph now matches the "Known gaps" account --
millisecond budgets, edges timestamped from a signal hook, delivered width
asserted alongside ordering/polarity/exclusion/presence, and the fault driver's
non-timing transaction-seam probe as the one deliberate `run(1)` caller left.
The delay oracle's justification was stale in a second way: it was called "the
AVR-XT's only route to an absolute pulse width", which stopped being true when
the tracer gained delivered width. Its real claim is stronger and unaffected --
it recovers the *compiled* width from the disassembled image, so it is
simulator-independent and tighter than any trace.

*A register is never physical.* `docs/pic10f320_special_case.md` described its
target-I/O lane as observing "physical `PORTA`" and its output lanes as
observing "real pin state". Both run in gpsim or on the host. They now say
modeled `PORTA` and say what they are. Sweeping the same phrasing repo-wide
found three more evidence claims of the same shape and left the rest alone,
which is the part worth recording: "physical port" is *also* the correct name
for a datasheet distinction on these parts -- `GPIO` and `PORTA` read pins where
a shadow or `LATA` holds the latch -- so the phrase cannot simply be banned. The
test is what the sentence is about. Firmware behaviour and register semantics
keep it (`docs/pic12f675_feasibility.md`, `docs/relay_coil_fault_correction.md`,
`CHANGELOG.md`, `Makefile:5851`'s note that the 12F675 fault lane injects into
the port as well as the latch -- reworded to "port register" because that one
sentence is also describing a lane); claims about what a lane *observed* do not
(`Makefile`'s `pic12f675-test-io` help text and the built-image lane list in
`docs/non-blocking_output_schemes_feasibility.md`). Released `CHANGELOG.md`
sections that carry the old phrasing were left untouched: they are the record of
what was said at the time, and `test-release-history` treats them as immutable.

*No new validator, deliberately.* D1 added `release_validate_hardware_claims`
because its criterion was a classification that had to hold for every future
document. This item's criteria are not mechanically separable in the same way.
The one phrase worth banning outright -- "physical" qualifying a register name
in a code span -- appears in a shipped `[0.9.8]` changelog section, so the guard
would either fire on immutable history or need a prune rule wide enough to blind
it to the current section too. The existing gates already cover what is
checkable here: `test-workflow-syntax` holds both workflows to their real job
lists and toolchain assertions, `test-ci-local-routing` keeps `ci-local.sh` in
step with `ci.yml`, and D1's vocabulary scan already refuses the conflated
hardware idiom in every durable document. Adding a fragile prose matcher on top
of those would cost more than it caught.

*Two bullets were already closed.* The item asks for the PIC10F320 relay
correction to be described as appropriate to that variant; F1 (`a8fe23d`) did
exactly that -- `docs/pic10f320_special_case.md:162-176` now records that
`v0.9.10` replaces the `v0.9.8` correct-in-place guard with the project-wide
fail-safe policy, and why. It also asks that `release.yml`'s header include
PIC12F675 and stop calling a moving runner pinned; R1 (`7dab4db`) added the part
to both the rebuild list and the re-run list, and R2 (`53c1289`) added the
`ubuntu-24.04` MOVING-label paragraph. `ci.yml` was the twin that never got
either fix, and it had drifted further: its `make test` inventory predated the
ATtiny202 host oracles and both PIC shipping-source coverage gates (T2,
`130b22f`). Its header and the `verify` job's inventory now name the host-side
lanes of all seven parts, and its pinning paragraph matches `release.yml`'s,
naming what actually is pinned -- every third-party action by commit SHA, and
XC8 V3.10 + PIC10-12Fxxx_DFP 1.9.189, SHA-verified on install and
integrity-checked on every cache restore.

*Verification.* `make test-workflow-syntax test-ci-local-routing
test-release-preflight test-release-qualification test-release-history
test-todo-index test-makefile-name-contract`, then the full local CI run.

### D3 - Control the pre-release metadata transition

**Priority:** Release sequencing

**Problem**

The branch already identifies `v0.9.10` as released and says authoritative
evidence lives under `release/v0.9.10/`, including `TODO.md:4-9`,
`docs/pic10f320_validation.md:16-23`, and `release/README.md:17-20`. No such
directory or tag exists before production qualification.

Final release wording must exist in the qualified source history, so a short
pre-release transition may be intentional. It must not become an indefinite or
failed-release state on `main`, and the claims must not be treated as evidence
until the artifact commit and tag exist.

**Recommended change**

- Decide and document the exact source-finalization, production-staging,
  artifact-commit, and tag sequence.
- Where practical, use wording that distinguishes the v0.9.10 source contract
  from evidence that exists only in the tagged artifact commit.
- If final post-release wording must be committed before staging, make the
  acceptable transition window explicit and require rollback/correction if the
  release is abandoned.
- After staging, verify every bounded current-release declaration against the
  actual `release/v0.9.10/` inventory before tagging.

**Acceptance criteria**

- [x] The release sequence has no ambiguous source or artifact identity.
- [x] A failed or postponed release cannot leave `main` indefinitely claiming
  nonexistent retained evidence.
- [x] The tagged release contains accurate final wording and the claimed
  evidence inventory.
- [x] Versioned release-preflight and release-history tests cover the selected
  transition.

**Implementation note (2026-08-23).** Resolved. The item reads as a wording
problem and is not one: source finalization and the artifact commit are
*necessarily* different commits, so the tree that declares a release provably
never contains it, and the pre-release window is a structural property of the
release model rather than an accident of drafting.

*Why the window cannot be closed.* `scripts/verify-release-history.sh` rejects a
release whose qualified source commit already contains
`release/<version>/QUALIFICATION`, and requires the artifact commit's sole parent
to be that source commit and to change nothing outside `release/<version>/`. Tag
CI runs it. So the declaration must be committed before the directory it names
can exist, and it cannot be amended afterwards without breaking the artifact
commit's shape. Wording that is true only after the tag is therefore wording
that is false in the tree that ships it -- which is exactly what
`TODO.md` and `docs/pic10f320_validation.md` carried: "`release/v0.9.10/`
retains the authoritative evidence for the released v0.9.10 source", in a tree
with no such directory and no such tag.

*The sequence, written down.* `release/README.md` gains "How a release is
sequenced": source finalization (one ordinary commit on `main` that finalizes
the changelog and the four bounded declarations -- the source contract, and the
commit qualification measures), production staging (`scripts/make-release.sh`,
which stages without committing), the artifact commit, and the signed tag. It
names which identity each step fixes, states why steps 1 and 3 cannot be
collapsed, and states the rollback rule: an abandoned or postponed release has
its source-finalization commit reverted or corrected on `main`, never left
standing. `scripts/make-release.sh` carries the same sequence in its header and
in the hand-off it prints, where the human reads it at the moment it applies.

*Declarations are now checked, not trusted.* Acceptance criterion 2 asks that a
failed release cannot leave `main` claiming nonexistent evidence
*indefinitely* -- and a check that only runs during `make release` cannot
deliver that, because an abandoned release never runs it. The rule therefore
went into the live-tree preflight validator: a bounded current-release block may
not name a release directory this tree does not contain. The one exception is
the version being released, whose directory a source commit provably cannot
carry, and naming it requires the exact pre-tag transition line recording that
the release cut creates it. That keeps the check exact rather than a prose
matcher -- a path token and a directory test, plus the same exact-line technique
the contract line already uses -- which is why this item warranted a validator
where D2 did not. The rule caught the live defect on first run before either
document was touched.

*Staged inventory closes the loop.* Before the build, the strongest available
statement is that four documents agree with what the Makefile *predicts* a
release will contain. `release_validate_staged_documentation` re-runs the same
validator after staging with counts taken from the staged directory instead:
images counted as files, soak combinations counted by the machine soak-result
record each log carries rather than by filename, since
`evidence/soak-build.log` would pad a name-based count. Its position is pinned -- after the staged-qualification verifier,
before the commit/tag hand-off -- because both ends matter: earlier and it has
nothing to read, later and the human has already committed.

*Test coverage.* `test-release-preflight` 101 -> 113: an undisclosed claim on
the not-yet-staged directory is rejected, a disclosed one accepted, another
version's absent directory rejected *even behind the transition line*, a present
one accepted, prose outside the bounds still unconstrained, the line read
through `release/README.md`'s blockquote, a matching staged inventory accepted,
one-short image and soak sets rejected by their staged counts, and empty
image/evidence stagings rejected. `test-release-history` 88 -> 89: a release
commit that also restates a bounded declaration is refused exactly as a
source-path change is, which is the history-side statement of the same rule --
the wording a tag carries is the wording that was qualified. The existing
"qualified source already contains release record" case was already the
structural fact this item rests on and needed no change.

*Verification.* `make test-release-preflight test-release-qualification
test-release-history test-todo-index test-makefile-name-contract`; full
`scripts/ci-local.sh`.

### G1 - Extend the branch-only document guard to this file

**Priority:** Merge/release hygiene

**Problem**

The current release guard rejects root-level `v*-polish.md` files. The requested
name `pre-v0.9.10-fixes.md` does not match that pattern, so the existing guard
will not detect a forgotten copy or reference.

**Recommended change**

- Extend the branch-only-document detector and its tests to reject this exact
  file, or a narrowly defined `pre-v*-fixes.md` family, on release staging.
- Keep release preflight usable while the work document legitimately exists on
  the polish branch, matching the current branch-document policy.
- Before merge, delete this file and remove every reference to it.

**Acceptance criteria**

- [x] The release-staging path fails when this document exists.
- [x] The release-staging path fails when a tracked file still references its
  basename after deletion.
- [x] The branch-safe capability preflight remains usable while the document
  exists.
- [x] Negative and positive branch-document contract tests pass.
- [ ] This document and all references are absent from the merge candidate.

**Implementation note (2026-08-23).** Implemented. The fifth criterion is the
pre-merge deletion itself and stays open until that commit.

*The defect is the mechanism, not the name.* The guard matched one glob,
`v*-polish.md`, so it saw the previous working document and nothing else. Adding
`pre-v*-fixes.md` beside it would close this instance and leave the mechanism --
one name pattern per document, written after that document already exists --
exactly as able to miss the next one. The presence half is therefore an
allowlist: the eight durable root-level Markdown documents ship, and any other
root-level Markdown document fails release staging until it is deleted or
deliberately added to the set. Both branch-only families are still matched by
name first, so the diagnostic names the kind of document it found instead of
reporting only that something unexpected is present.

*What each half can know.* The reference half cannot be an allowlist. Once a
document is deleted its name is the only thing left to search for, so that scan
stays pattern-based and now covers both families -- a durable file still naming
either one is refused, because the reference would dangle the moment the
document goes. A root-level file that is not Markdown is not governed at all,
which keeps `commit_msg.txt` and the like out of the gate's business.

*Phase, unchanged.* The gate is still called only from the real release-staging
path, after the preflight capability probe exits, so `scripts/make-release.sh
--preflight v0.9.10` remains usable on this branch with the document present --
re-verified, not assumed. One consequence to expect: from this commit a full
`--dry-run` from this branch fails at step 0 until the document is deleted.
That is criterion 1 in operation, and it is the contract the final validation
gate already states ("A release dry run passes after this branch-only document
is deleted").

*Test coverage.* The branch-document contract now proves both directions for
both families and for the allowlist: the durable set is accepted alongside a
root-level non-Markdown file, a root-level `v*-polish.md` and a root-level
`pre-v*-fixes.md` are each refused with the offending name in the diagnostic, a
root-level document in neither family is refused as outside the durable set, a
durable file naming either family is refused, and the tree passes again once
every violation is gone. The retained `docs/<ver>_post_release_polish.md` still
passes, being neither root-level nor `-polish`. A failed document or reference
scan remains a policy failure rather than an empty result set. One further case
holds the LIVE repository to the same durable set, so the allowlist cannot drift
until release day is the first thing to notice.

*Verification.* `make test-release-preflight` (113 -> 118 checks);
`scripts/make-release.sh --preflight v0.9.10` still passes on this branch;
`make test-release-qualification test-release-history test-release-provenance
test-release-images test-soak-timing test-build-serialization test-todo-index
test-makefile-name-contract`; and, as part of the final validation gate, `make
test` and `make test-long STRICT_TOOLS=1 MUTATION_ALLOW_SKIP=0`. No firmware
source was touched.

## Second-pass review (2026-08-24, HEAD `dd26fdf`)

The first-pass work substantially improves the project, and the host and
release-contract suites remain strong. The findings below are nevertheless
release-significant because they expose physical-pin behavior and published
hardware procedures that the current tests do not observe. Complete every
release-blocking item before merge. Complete or explicitly disposition the
lower-priority hardening items before declaring the overall release process
finished.

### F2 - Make relay escalation safe under pin-polarity and peripheral-ownership faults

**Priority:** Firmware safety/correctness release blocker

**Problem**

F1 correctly changed an unexpectedly energized relay coil from silent
correction to watchdog recovery, and requires `hw_force_wdt_reset()` to
de-energize both coils before the watchdog spin. Two MCU-specific fault paths do
not satisfy that physical guarantee:

- AVR-XT detects nonzero `PORTA.PIN2CTRL` and `PORTA.PIN3CTRL`, including
  `INVEN`, in `hw_output_state_intact()`. Its escalation path then clears the
  corresponding `PORTA.OUT` bits. With `INVEN` set, a zero output latch drives
  the physical pad high, so the affected relay coil can remain energized for
  the watchdog interval even though `PORTA.OUT` reads low.
- PIC12F675 detects a changed `CMCON`, but its escalation path only clears the
  SRAM GPIO shadow and writes `GPIO`. A comparator mode that routes `COUT` onto
  GP2 owns the SET-coil pad; a GPIO write alone cannot force that pad low. The
  comparator can therefore hold the coil high until reset.

The current AVR-XT fault driver classifies coil-pin `INVEN` injections as
generic gate cases and observes reset entry or `PORTA.OUT`, not physical
PA2/PA3. The PIC12F675 matrix proves a `CMCON` fault is detected, but does not
prove GP2 is de-energized while comparator output owns the pad. Both tests can
pass while the physical safety claim is false.

**Recommended change**

- Add MCU-specific emergency output quiescence to the escalation path. It must
  neutralize polarity inversion, pull-up, direction, and peripheral ownership
  that can defeat a low latch before waiting for the watchdog.
- Define and review the write order against each datasheet so restoring GPIO
  ownership cannot expose a stale high latch or enable an internal pull-up.
- Preserve the output-driver abstraction for ordinary actuation; the emergency
  path may be shell-specific because these are MCU register hazards, not output
  stage policy.
- On AVR-XT, inject `INVEN` on both relay-coil pins and assert the modeled
  physical PA2/PA3 levels are inactive before reset entry, not merely that the
  `OUT` bits are zero.
- On PIC12F675, exercise every single-bit-reachable `CMCON` configuration. For
  every mode where comparator output can own GP2, exercise both comparator
  output states and require physical GP1/GP2 de-energization before the reset
  spin.
- Add negative controls that fail if the emergency path is reduced back to a
  latch-only clear.

Actual firmware-source changes under this item are to be made by the repository
owner, consistent with project policy.

**Acceptance criteria**

- [ ] AVR-XT relay escalation de-energizes physical PA2 and PA3 under coil-pin
  `INVEN`, pull-up, direction, and relevant combined register-state fixtures
  before the watchdog spin.
- [ ] PIC12F675 relay escalation de-energizes physical GP1 and GP2 when a
  detected comparator mode owns GP2, before the watchdog spin.
- [ ] Tests observe modeled physical pin state and kill latch-only-clear mutants.
- [ ] The ordinary relay fault cases still produce exactly one watchdog reset
  and one complete recovery RESET-coil pulse where the simulator models reset.
- [ ] Flash, RAM, stack, timing, watchdog, static-analysis, target-simulator,
  source-coverage, and mutation gates pass for both affected targets.
- [x] F1 documentation is updated to describe the implemented MCU-specific
  emergency quiescence and its tested fault scope without overclaiming hardware
  or relay-mechanical evidence.

**Implementation status (2026-08-24, provisioned validation pending)**

- The repository owner added shell-specific emergency quiescence. AVR-XT
  removes coil pull-ups, disconnects direction, clears inversion and stale
  `OUT`, then restores low output drive. PIC12F675 removes coil pull-ups,
  disconnects direction, disables analog/comparator ownership, clears the
  shadow/GPIO latch state, then restores low output drive. The ordinary output
  driver remains responsible only for latch intent.
- The AVR-XT relay matrix now has 32 injections. It observes physical PA2/PA3
  plus exact `OUT`, `DIR`, `PIN2CTRL`, and `PIN3CTRL` state under both coils'
  `INVEN`, pull-up, one-bit direction, combined input/stale-OUT/control, and
  settled-state OUT fixtures. Host negative controls reject an OUT-only clear.
- The PIC12F675 relay matrix now has 43 checks. It directly observes modeled
  GP1/GP2 node voltage across all three comparator modes one bit from off
  (`110`, `101`, `011`), one check each. Per DS41190G Figure 6-2 and Section
  6.4, `COUT` reaches the GP2 pad in exactly the three "with Output" modes
  (`001`, `011`, `101`), so `011` and `101` are the reachable modes that can own
  GP2 and `110` cannot; gpsim's model agrees. Modes `011` and `101` must drive
  physical GP2 High through `COUT`, reject a latch-only clear, and then complete
  the ordinary de-energization/reset/recovery contract once the firmware's
  quiesce returns the pad to GPIO. Mode `110` must leave GP2 at its settled-low
  GPIO level and take the same path. Two simulator limits bound the claims: the
  mode must be installed with `Register::put()` (a `put_value()` to `CMCON`
  never engages the peripheral, unlike the port registers, which override
  `put_value()`; worse, a `put_value()` that selects an output mode leaves
  gpsim's lazily allocated `cm_source[]` NULL and segfaults `CMCON::get()` on
  the firmware's next `MOVF CMCON,W`, which `inject_case()` now refuses), and
  gpsim's modeled `COUT` is a pure function of `CM<2:0>` and does not read the
  CIN+ pad, so no fixture asserts anything about the analog input.
- Reviewed source-order checks pin pull-up removal before input direction,
  peripheral/polarity neutralization before latch clearing, and low latch state
  before output direction is restored. F2's new latch-only mutants raised its
  then-current pinned inventory from 132 to 134; combined with F3's independent
  PIC10F320 additions, the merged inventory is 136.
- Resource coverage is now explicit. ATtiny202 requires one exact flash/static-
  RAM report, enforces 2048 B flash and 16/128 B static RAM, and compiles the
  AVR-XT shell under all three production selectors with a 32 B per-frame
  ceiling. PIC12F675 requires one consistent XC8 Data-space report per variant
  and enforces an inclusive 48/64 B limit. Both have fail-closed fake-tool
  regressions; actual values still require the provisioned compilers.
- Available host validation passes: `test-attiny202-fault-oracle` (48 checks),
  `test-stack-bound-regression` (23 checks), `test-attiny202-build` (52 checks),
  `pic12f675-coverage-check-fw`, `test-pic-target-result-records`,
  `test-target-matrix`, `test-target-lane-markers`, `test-mutation-sandbox`
  (132 checks), `test-pic-build` (36/75/156 checks),
  `test-pic-build-rebuild` (28 checks), release
  preflight/qualification/history, TODO-index, Makefile-name, and watchdog-note
  contracts; `git diff --check` is clean.
- Target evidence is not claimed on this host. Strict AVR-XT execution stops
  because `third_party/attiny_dfp` is absent; strict PIC12F675 execution stops
  because XC8/DFP/libgpsim are absent. The repository-wide `make test` also
  stops in the pre-existing host setup at missing `gnu/stubs-32.h` during
  Classic-AVR clang-tidy. Keep the first five acceptance boxes open until the
  real-image target lanes, actual resource/stack measurements, timing/static
  gates, and complete 136-mutant run pass on the provisioned validation host.

### F3 - Resolve the PIC10F320 two-write relay-coil clear

**Priority:** Firmware consistency/hardening before release

**Problem**

`set_relay_coils_low()` in the space-constrained PIC10F320 shell clears RESET
and SET through two separate `LATA` read-modify-writes. When both bits are high,
one coil remains energized for one additional write; when only SET is high, the
RESET clear delays the useful de-energization. This is an instruction-scale
exposure, not a watchdog-scale one, but it is weaker than the one-operation
clear used by the modular shells and should not be hidden by project-wide parity
language.

**Recommended change**

- Build and measure a constant-mask, one-write `LATA` clear for the relay
  variant.
- Prefer that implementation if all three images remain within the 256-word
  budget and the reviewed return-stack limit.
- If it cannot fit, record an explicit repository-owner disposition accepting
  the instruction-scale exception, qualify the parity claim, and retain tests
  that expose the intermediate state rather than treating two writes as one.

Actual firmware-source changes under this item are to be made by the repository
owner.

**Acceptance criteria**

- [x] The owner either adopts one constant-mask clear or records why the
  measured resource cost requires retaining the two-write exception.
- [x] Target-level evidence observes the write sequence and fails if the chosen
  contract regresses.
- [x] PIC10F320 flash, return-stack, image-baseline, fault, target-I/O, coverage,
  and mutation gates pass.
- [x] Documentation states the exact PIC10F320 behavior and does not imply
  stronger cross-shell parity than the implementation provides.

**Resolution.** The one-write clear was adopted, and the measurement made the
choice unambiguous rather than close: it *frees* resources. The two per-bit
helpers `hw_relay_reset_pin_set_low()` and `hw_relay_set_pin_set_low()` had no
caller besides `set_relay_coils_low()`, so folding them into a single
constant-mask `LATA &= ~((1U << RELAY_RESET_PIN) | (1U << RELAY_SET_PIN))`
deleted two functions and a call level. Under the pinned XC8 V3.10 / DFP 1.9.189
`-O2` build the relay image went **248 -> 242** of 256 program words (8 -> 14
free) and its worst-case return-stack depth **4 -> 3** of 8 (2 -> 3 spare); the
two CD4053 images are byte-identical to the shipped baseline, since these
helpers live under `#if defined(OUTPUT_TQ2_RELAY)`. The disposition branch of
this item is therefore not exercised, and no exception is recorded. The
high-side helpers stay per-bit: only one coil is ever energized at a time, so
there is no intermediate state to remove there.

The write sequence is now asserted by two independent oracles, each of which
fails on a return to the per-bit form:

- **Host** -- `test/pic10f320/fault/`. The mock `<xc.h>` already routed every
  firmware `LATA` access through the harness, so the transient is directly
  observable: `fw_relay_fault_result_t.partial_clear_coils` records a coil field
  with strictly fewer bits than the previous one but not none. Relay-variant
  checks 59 -> 62.
- **Target** -- `test/pic/test_fault_pic_core.h`. The resynchronization cases
  already stepped the real image one instruction at a time waiting for
  de-energization; they now also fail if the output latch or the modeled port
  sheds its coil bits across more than one step. This is in the shared core, so
  PIC10F322 and PIC12F675 assert it too, which is what makes the parity claim in
  `docs/relay_coil_fault_correction.md` a tested statement rather than a
  description. The shadow-latch part is unaffected by the port lagging the
  shadow, because each view is tracked separately.

Both are load-bearing only on the **both-coils-energized** injection, and that is
the whole of what is observable: with a single coil energized a per-bit clear
delays the useful de-energization by one write but passes through no distinct
state, so no oracle at the state level can see it. That limit is stated in the
harnesses and in the documentation rather than papered over. Two
mutation-inventory entries (host and target lanes) restore the per-bit clear;
both are killed. They moved F3's then-current inventory 132 -> 134; combined
with F2's independent additions, the merged inventory is 136.

Documentation: `docs/relay_coil_fault_correction.md` now states the one-write
contract per shell -- the modular four through `hw_pin_mask_set_low()`, the 320
directly -- and says where it is asserted and where it cannot be;
`docs/pic10f320_validation.md` gains run 6 with the resource table and the new
digest. The 320's relay call chain is now 3 levels, so the places that recorded
4 are corrected: that document's return-stack section (which also claimed the
two PIC chips were identical -- the 322 is still 4), its two-witness paragraph,
and `test/check_stack_depth_pic.sh`, whose documented XC8-disagreement example
was measured on the exact chain this change removes and is reframed as the
historical measurement it is.

Three further documents carried the relay's flash figure as a current fact and
were **already** stale by F1's coil-latch term before this change:
`DESIGN_DOCUMENTATION.adoc` (utilization table and headroom sentence),
`docs/context_seu_detection.md` (F2 resource table) and
`docs/non-blocking_output_schemes_feasibility.md`. All three now read 242/256.
Two of them draw conclusions *from* that margin -- F2's PIC10F320 exclusion, and
the feasibility study's §6.4 finding that range-checking a countdown state puts
the relay exactly on 256 and does not link -- so each carries a scoped note that
the baseline moved and the question needs re-pricing rather than citing the old
paragraph. Neither conclusion is reversed here: that would need its own
measurement, and `cd4053_with_mute`, untouched by this change, is the variant
both costs overflowed first. `docs/pic10f320_special_case.md`, `test/README.md`
(host-fault check count and per-variant executable-line count) and
`CHANGELOG.md` carry the same facts.

*Verification.* `test/pic10f320/expected_images.sha256` rebaselined for the
relay image only; both CD4053 digests unchanged, so exactly one hash moves.
PIC10F320 gates on the new image: flash 242/256, return stack 3/8 with witness,
`pic10f320-test-host-variants` 41 / 41 / 62 host fault checks,
`pic10f320-test-target-variants` 24 / 24 / 29 fault, 3005 lock-step and
25 / 26 / 36 target-I/O checks, `pic10f320-coverage-check-fw` 96/99 executable
lines with the same three allowlisted fault-path lines, and `pic10f320-analyze`
(cppcheck + MISRA) clean across all three variants. The shared-core change was
re-run against the unmodified PIC10F322 (29 fault checks) and PIC12F675 (41)
relay images with no false positive from the shadow/port skew. Negative controls:
with the per-bit clear restored, the host lane reports exactly 1 failure of 62
and the target lane exactly 1 of 29, both on the both-coils case and both naming
the coil left driven. All three coil pulses on the target-I/O trace are now 6010
cycles, where the per-bit clear made the SET pulse 6 cycles longer than the
RESET pulse. Firmware source changes were made by the repository owner,
consistent with project policy.

### F4 - Make watchdog-margin assertions cover wall-clock execution

**Priority:** Firmware timing hardening before release

**Problem**

The shared relay and muting drivers assert only `TICK_PERIOD_MS +
blocking_delay < WDT_MIN_PERIOD_MS`. That omits sanity/context-processing
overhead and, on interrupt-driven AVRs, ISR preemption that stretches a busy
delay in wall time. Current margins are wide and measured pulse elongation does
not approach the watchdog floor, but a future near-bound configuration could
pass the assertion while violating the real pet-to-pet bound.

**Recommended change**

- Define a conservative per-target wall-clock upper bound that includes the
  blocking delay, tick scheduling, bounded loop work, and AVR ISR elongation.
- Assert that bound against the de-rated watchdog minimum used by each target.
- Extend the static-assert mutation gate with a near-bound case, not only an
  obviously impossible watchdog floor.
- Keep measured simulator/disassembly timing as corroborating evidence; do not
  present it as a substitute for the conservative compile-time inequality.

Actual firmware-source changes under this item are to be made by the repository
owner.

**Acceptance criteria**

- [x] Every modular shell has a documented conservative pet-to-pet upper bound.
- [x] Compile-time guards fail at the true wall-clock boundary for relay and
  muting variants.
- [x] Static-assert negative controls prove the overhead/preemption term is
  load-bearing.
- [x] Existing timing, pulse-width, watchdog-liveness, and resource gates pass.

**Resolution.** Each pin map now declares `WDT_LOOP_WORK_MS` and
`WDT_ISR_STRETCH_PCT` beside its existing `TICK_PERIOD_MS` and de-rated
`WDT_MIN_PERIOD_MS`; `WDT_PET_TO_PET_MAX_MS()` in `bypass_output_common.h`
combines all four with the variant's blocking delay into one conservative
wall-clock upper bound, and each output driver asserts that bound against the
floor. The self-contained PIC10F320 carries its own copy of the constants and
the arithmetic, as it does for every other shared invariant. The simple CD4053
variant, which blocks nowhere and previously carried no watchdog assertion,
is now covered as well: the floor must clear the loop itself, not only a pulse.
The boot path is inside the bound rather than beside it -- `init()` arms the
watchdog and then performs the same blocking actuation before `main()` reaches
its first pet -- and on the non-blocking variants it is the longest window
there is, which the measurement below is what established.

Per-target bounds, in milliseconds (relay / mute / simple against the floor):
AVR Classic 17 / 9 / 2 against 100; AVR-XT 17 / 9 / 2 against 128; PIC10F322 and
PIC10F320 14 / 7 / 2 against 160; PIC12F675 16 / 9 / 4 against 160. Derivation
and the measured corroboration are in "Watchdog Pet-to-Pet Budget" in
`DESIGN_DOCUMENTATION.adoc`.

*Verification.* All 21 images across the six targets rebuild byte-identical to
the current baselines, so the change is entirely compile-time and no image
rebaseline is required. `make test-static-assert-guards` 39 -> 68 checks: eleven
near-bound fixtures pin each variant's bound to its exact millisecond and assert
FIRES or CLEAN rather than only that something failed, so a guard reverted to
the old `tick + pulse` sum fails the FIRES half and a term that is present but
unreachable fails the CLEAN half. `test/avr/test_sim.c` gained a pet-budget
check that measures the longest `wdr`-to-`wdr` interval on the real image and
requires it to fit the compile-time budget: worst measured 14.002 / 15.003 ms of
a 17 ms relay budget on ATtiny13A / ATtiny85, 6.402 / 7.004 of 9 for mute, and
1.377 / 1.464 of 2 for simple, all against a 100 ms floor. All five MISRA lanes
clean after one new D-2 Rule 2.5 entry for `bypass_output_common.h`, whose
shared macro the modular shells include but do not expand. `make test`: 84
summary lines, 0 failures. Full `scripts/ci-local.sh` green end to end (1253s),
including `make test-long MUTATION_ALLOW_SKIP=0` under `STRICT_TOOLS=1` with
mutation testing at 132 killed, 0 survived, 0 errored, 0 skipped;
`make test-release-preflight` remains 118 checks. Firmware source changes were
made by the repository owner, consistent with project policy.

### P1 - Replace the raw PIC12F675 path with a lightweight guarded helper

**Priority:** User-facing hardware safety release blocker

**Problem**

`FLASHING.md` was created for a legitimate use case: program a downloaded
release image on a machine that has the programmer but not the firmware build
toolchain or a repository checkout. Its PIC12F675 block recognizes that this
part is not an ordinary flash-and-forget target. It reads and archives the
device, asks the operator to record OSCCAL and BG, writes the common release
image, then reads the device again and asks the operator to compare both
per-device values.

Those are the right conceptual stages, but the published command sequence is
not yet a safe implementation of them. Parsing and comparison are manual; the
write is not mechanically conditional on a valid baseline; no durable PENDING
reservation exists before the hardware mutation; the recovery text covers an
erased OSCCAL word but not changed BG; and the exact PICkit 3/MPLAB X 6.20
`ipecmd` read, erase, calibration-preservation, program and export behavior has
not been validated on hardware. A post-write comparison can detect damage after
it occurs, but cannot by itself establish that the writer preserves the trim.

This also contradicts the guarded transaction required by `README.md` and
`release/README.md`, which prohibits a raw writer because bulk erase can
silently destroy per-device OSCCAL and BG trim. The generated release guidance
is contract-tested, but the static `FLASHING.md` path is not governed by the
same safety contract. The suite is therefore green while two durable
instructions disagree about whether the raw write is permitted.

The full `pic12f675-release-program` transaction is not the right end-user
answer to this use case. Its private rebuild, pinned XC8/DFP checks, Git release
identity and source-worktree requirements provide strong development and
release-provenance guarantees, but the PIC12F675 does not fundamentally require
a compiler to program a released image. The common release HEX deliberately
omits word `0x3FF` and leaves BG outside its programmed intent; safe field
programming requires that image plus the attached device's factory trim and a
validated preservation/verification transaction.

**Selected direction (recorded by the repository owner)**

Replace the raw static recipe with a standalone Python helper for PICkit 3 and
MPLAB X 6.20 `ipecmd`. Ship the helper with each release so a flashing machine
needs only Python 3, the downloaded release bundle and its existing programmer
CLI. It must not require Make, Git, XC8, the DFP, a simulator, a source checkout,
or a firmware rebuild.

The documentation claim should be precise rather than use "typically" as an
implicit escape clause:

> Programming a downloaded release does not require the firmware development
> toolchain or a repository checkout. Most targets require only the released
> HEX and programmer CLI. PIC12F675 additionally requires Python 3 and the
> release's flashing helper because its per-device factory calibration must be
> preserved and verified.

The PIC12F675 heading in `FLASHING.md` must say directly that it is not a raw
write target and that the release HEX must be passed to the helper, not directly
to `ipecmd`.

**Helper and release contract**

- Implement one self-contained standard-library Python entry point with a
  narrow command line: selected release HEX, MPLAB X 6.20 `ipecmd` executable or
  JAR, and a caller-selected new evidence path. Invoke every subprocess through
  an argv list, never a shell or caller-supplied whole-command string.
- Fix the first supported hardware identity to PIC12F675, PICkit 3, and MPLAB X
  6.20 `ipecmd`. Reject a different part, tool kind, or unrecognized version
  before a device write. Support only the direct executable and Java/JAR forms
  that are exercised by tests and the retained bench procedure.
- Make target power an explicit part of the validated procedure. Default to the
  conservative externally powered arrangement; do not expose `-W5` or another
  programmer-powered mode until that exact voltage/interface setup is included
  in retained hardware evidence.
- Stage the helper in every release bundle and bind its exact bytes into the
  signed release checksum/provenance contract. Preserve the canonical count of
  21 firmware images by making release verifiers distinguish the required
  helper artifact from the exact `*.hex` image set rather than treating every
  checksum entry as a firmware image.
- Consume a downloaded shipping HEX directly. Require its exact basename and
  digest in the release's signed `SHA256SUMS`, then validate strict Intel HEX
  structure, PIC12F675 address range, expected CONFIG intent, absence of word
  `0x3FF`, and absence of any other calibration-writing record before opening a
  write path. Snapshot and hash the accepted bytes; all later checks and the
  programmer invocation must consume that same immutable snapshot.

**Programming transaction**

- Create a new private evidence directory exclusively and refuse an existing,
  empty, symlinked or unsafe output path. Retain the image digest, helper
  identity, exact programmer executable/JAR identity and version, selected
  power mode, command transcripts, Device ID/revision, complete exported HEX,
  OSCCAL word/value, CONFIG and BG bits.
- Before any erase/write argument is reachable, perform a full-device baseline
  read and fail unless word `0x3FF` is a valid `RETLW <cal>` instruction and all
  required CONFIG/BG and device-identity fields are present. Perform an
  immediate second pre-write read and require it to match the baseline exactly.
- Write and durably publish a `reservation.json` record before invoking
  `ipecmd` with any erase/program option. It must bind the baseline, immediate
  read, image, helper, programmer, part, tool, power and command identities. An
  interruption after reservation is PENDING, never an implicit success or
  permission to issue another write.
- Construct the one validated PICkit 3 write argv internally. Do not accept an
  external image override, part override, whole-command override, extra writer
  arguments, or an option that enables calibration-memory programming.
- Attempt a full-device readback even when the writer reports failure. Verify
  the programmed addresses against the immutable release snapshot, verify the
  intended non-BG CONFIG bits, and require OSCCAL and BG to equal both pre-write
  reads. Publish exactly one immutable `result.json` with PASS or detailed FAIL;
  a FAIL is a forensic result, not permission for an automatic retry.
- Provide a read-only finalization mode for a PENDING transaction. It may
  revalidate identities and retry only the final full-device read and result
  publication; it must never construct or invoke writer arguments.
- Preserve the original complete device export independently of PASS/FAIL so an
  operator is not left without the only copy of per-device trim if the first
  hardware trial exposes destructive programmer behavior.

**Hardware-validation gate**

The helper automates the transaction but does not make untested `ipecmd`
behavior safe by assertion. Before the helper is published as a supported
release path, retain a controlled PICkit 3/MPLAB X 6.20 bench run that proves:

- the chosen read/export command returns complete program, CONFIG, Device ID,
  revision, OSCCAL and BG data in the form the helper parses;
- the exact write command and calibration-memory-disabled setting preserve both
  OSCCAL and BG on an initial program and a repeat program;
- programmed code and non-BG CONFIG bits read back exactly as expected;
- the documented external-power arrangement and release/reset behavior are
  correct; and
- an interrupted/PENDING transaction can be finalized read-only without a
  second write.

If MPLAB X 6.20 cannot enforce or report calibration-memory protection through
the supported CLI path, or the bench result shows either trim value changes,
do not publish the helper as safe and do not silently add automatic repair. A
per-device trim-aware image or explicit restoration transaction would be a new
design requiring its own review, fail-closed binding and hardware validation.

**Test and documentation changes**

- Add a stateful fake-`ipecmd` regression that proves the exact order is
  baseline read, immediate read, durable reservation, one write and final read.
  Assert zero writer invocations on every failed image, tool, baseline,
  immediate-read, identity, path, checksum or reservation precondition.
- Cover malformed/duplicate/out-of-range Intel HEX, programmed word `0x3FF`,
  wrong CONFIG intent, invalid `RETLW`, missing BG/device identity, tool/version
  drift, image or executable mutation, baseline mismatch, writer failure,
  readback failure, programmed-byte mismatch, OSCCAL/BG mismatch, existing or
  symlinked evidence, interruption at each boundary, immutable-result reuse and
  read-only PENDING finalization. Negative controls must prove each guard is
  load-bearing.
- Replace the raw PIC12F675 commands in `FLASHING.md` with the helper invocation
  and its special-case explanation. Keep the full-toolchain guarded target
  documented as the development/qualification path, not as a requirement for
  flashing downloaded release bytes.
- Extend the durable documentation/source contract to reject user-facing raw
  PIC12F675 `ipecmd`/`pk2cmd` writer commands, a missing helper requirement,
  claims that every part needs only HEX plus CLI, an unbound helper artifact, or
  disagreement among `README.md`, `FLASHING.md`, `release/README.md` and the
  generated per-release guidance.
- Add negative fixtures restoring the current raw block and each contradictory
  quickstart form; prove release preflight rejects the offending document and
  claim by name.

**Acceptance criteria**

- [x] A release-shipped, signed-checksum-bound Python helper programs the
  downloaded PIC12F675 HEX with no source checkout or firmware development
  toolchain.
- [x] The helper fails closed before writing on every image, trim, identity,
  tool/version, power-mode, path, checksum, mutation and reservation error.
- [x] A durable reservation precedes the sole write; PASS requires exact code,
  CONFIG, OSCCAL and BG readback; interrupted transactions have a read-only
  finalization path.
- [ ] Retained hardware evidence validates the exact PICkit 3/MPLAB X 6.20
  `ipecmd` read/write/export and external-power procedure on initial and repeat
  programming. **Cannot be closed from software.** The required run is written
  down as an outstanding controlled run in `HARDWARE_VALIDATION_LOG.md`, with the
  five properties it must prove and the explicit rule that a failing bench result
  does not become a supported path by assertion.
- [x] No durable current document publishes a raw PIC12F675 writer command;
  every downloaded-image path names the Python helper and the calibration
  special case explicitly.
- [x] The 21-image release identity remains exact while the required helper is
  staged, checksummed, reproduced and published as a distinct release artifact.
- [x] Fake-programmer, interruption, release-image, preflight, qualification,
  recovery, packaging and durable-documentation negative controls pass.

**Resolution**

`scripts/flash-pic12f675.py` is a self-contained standard-library entry point
with two subcommands, `program` and `finalize`. Part, tool and MPLAB X version
are constants it refuses to have moved (`--part`, `--tool` and `--power` exist so
that the refusal is testable, not so that the values are selectable), the
externally powered arrangement is the only one accepted, and `-W5` appears
nowhere. The write argv is constructed internally from the helper's own snapshot;
there is no image, part, command or extra-argument override.

The transaction is: validate the image against the bundle's signed `SHA256SUMS`
and its own strict Intel HEX/address/CONFIG policy, pin the tool through a
device-free `-?` version probe, create the evidence directory exclusively,
snapshot the accepted bytes, read the device, read it again and require an exact
match, publish `reservation.json` durably, write exactly once, then read the
whole device back -- attempted even when the writer reports failure -- and
publish one immutable `result.json`. `finalize` re-validates every reserved
identity, retries only the final read into private per-attempt files, and
constructs no writer argument at all.

Packaging: `RELEASE_HELPER_MAP` declares `<staged basename>=<tracked source>`
SEPARATELY from `RELEASE_IMAGES`, so the reviewed 21-image count cannot be moved
by shipping a tool. `make-release.sh` stages it and checksums it into the same
`SHA256SUMS`; `verify-release-images.sh` splits the checksum entries by declared
name, holds the images to the canonical set exactly as before, and proves the
staged artifact is the tracked source byte for byte -- which is the whole of the
reproduction claim for a file no compiler produces. The fresh-build leg stays
image-only. The tag workflow carries the artifact names forward from the step
that froze them rather than re-reading a mutable Makefile at publication time.

Documentation: `FLASHING.md`'s PIC12F675 section is now "not a raw write target"
and publishes the helper invocation; `README.md`, `release/README.md` and the
generated per-release guidance agree, and the `make pic12f675-release-program`
transaction is described as the development and release-provenance path rather
than a requirement for flashing downloaded bytes.
`release_validate_pic12f675_flashing_helper` runs in step 0 against the live tree
and rejects a raw writer command in ANY current document (discovered, not
enumerated), a missing helper requirement, the retired universal claim, an
unbound artifact, and disagreement among the four publishers. A read-only `-GF`
export and the helper's own `python3 ... --ipecmd <path>` invocation are
deliberately not writer commands, and both are proved to stay publishable.

**Owner decision still to make.** The helper is documented as the path for a
downloaded image while the bench row above is open. That is deliberate and
stated everywhere it appears -- a PASS means "no trim damage was observed on this
device", never "this writer preserves calibration" -- and it replaces a published
raw command that carried the same unvalidated preservation question with no
detection at all. If the preference is instead to withhold the helper from
`FLASHING.md` until the bench run exists, that is a documentation change, not a
code change.

### P2 - Build and validate AVR images before writing fuses

**Priority:** User-facing hardware safety release blocker

**Problem**

The ATtiny202, ATtiny13A, and generated tinyx5 `*-program` goals list the fuse
goal before the flash goal. The global serialization wrapper forces `-j1`, so
Make performs the fuse write first. The selected firmware image is only a
prerequisite of the later flash goal. A compile, link, size, or HEX-validation
failure can therefore leave a device with changed clock/watchdog/BOD fuses and
no matching firmware image.

This sequencing defect predates the polish branch, but the current quickstart
and flashing documentation recommend the convenience goals. Reference-quality
programming commands must establish every software precondition before the
first hardware mutation.

**Recommended change**

- Restructure every AVR `*-program` goal so the selected image is built and
  validated before either fuse or flash commands can invoke `avrdude`.
- Preserve the required hardware order after that software gate: fuses first,
  flash second, with no parallel programmer invocations.
- Add a fake-compiler/fake-`avrdude` regression proving a failed image build or
  validation invokes no programmer command.
- Add a success-path ordering check proving build/validation precedes fuse and
  fuse precedes flash for ATtiny202, ATtiny13A, ATtiny45, and ATtiny85.
- Update quickstart/flashing prose to state the transaction order.

**Acceptance criteria**

- [ ] Every AVR `*-program` goal proves the selected HEX exists and passes its
  normal validation before touching hardware.
- [ ] A failed build, size gate, or IHEX validation results in zero `avrdude`
  invocations.
- [ ] Successful programming performs exactly one ordered fuse transaction and
  one flash transaction for the selected part and variant.
- [ ] Serialization, rebuild, variant-selector, fuse-injection, flashing
  documentation, and normal build tests pass.

### D4 - Refresh v0.9.10 metadata and current measurements

**Priority:** Documentation correctness before merge

**Problem**

The changelog dates `v0.9.10` to 2026-08-21 even though candidate commits were
made later and the release has not occurred. Current resource tables still show
pre-F1 AVR and PIC10F320 values, while the F1 design record reports the later
measurements. The PIC10F320 validation document says the standing expected-image
manifest contains the run-4 relay digest, but the checked-in manifest contains
the run-5 fail-safe-resynchronization digest.

**Recommended change**

- Set the v0.9.10 changelog date to the actual source-finalization date, after
  the final code/documentation changes and before production staging.
- Regenerate and publish resource figures from the final candidate builds; do
  not copy the current intermediate values if F2-F4 change them again.
- Update the resource summary, per-family tables, free-space prose, and any
  binding-image statements together.
- Describe the PIC10F320 standing manifest as the run-5 baseline and preserve
  the earlier run transcripts as historical evidence.
- Add or extend contracts that compare current exact tables and baseline prose
  with retained build/image evidence where practical.

**Acceptance criteria**

- [ ] The changelog carries the real v0.9.10 source-finalization date.
- [ ] Every current resource figure matches a retained final-candidate build.
- [ ] PIC10F320 free-space and binding-image prose matches the final relay image.
- [ ] The expected-image manifest is described as run 5 or a later intentional
  rebaseline, never run 4.
- [ ] Changelog, release-history, current-release declaration, image-baseline,
  and documentation contract tests pass.

### D5 - Reconcile remaining simulator and toolchain wording

**Priority:** Documentation polish before merge

**Problem**

Several current statements still describe the superseded yasimavr timing model:
`DESIGN_DOCUMENTATION.adoc` says an unpatched cycle defect prevents
in-simulator width measurement, and `TODO.md` describes moving to signal hooks
as future work, while the current tracer already timestamps every edge from a
signal hook and checks delivered width. Workflow comments also call simulator
traces "physical" output timing. Separately, `TOOLCHAIN.adoc` promises a
`get-pip` fallback that the fetcher and its tests deliberately removed.

**Recommended change**

- Make all current yasimavr descriptions distinguish compiled delay-body width
  from delivered signal-hook width and state what each gate proves.
- Replace "physical" simulator claims with modeled-pin/output wording while
  preserving legitimate datasheet uses of "physical port".
- Remove the stale future-work text for the signal-hook migration.
- Make the venv/pip prerequisite match `scripts/fetch_yasimavr.sh`: pip must be
  supplied by `python3-venv`; there is no unhashed `get-pip` fallback.

**Acceptance criteria**

- [ ] No current document says delivered width cannot be measured in yasimavr.
- [ ] No simulator lane is represented as hardware or physical-relay evidence.
- [ ] The TODO describes only remaining upstream/re-pinning work.
- [ ] TOOLCHAIN prerequisites match the enforced fetch path and supply-chain
  tests.
- [ ] Workflow-syntax, fetch-yasimavr, supply-chain, TODO-index, and durable
  documentation tests pass.

### R4 - Publish suffixed tags as prereleases

**Priority:** Release automation correctness; not specific to stable v0.9.10

**Problem**

The release script accepts `vX.Y.Z-suffix`, and the release workflow triggers on
that tag shape, but `gh release create` is not passed `--prerelease`. A tag such
as `v1.0.0-rc.1` would therefore be published as an ordinary release and could
affect latest-release selection.

**Recommended change**

- Detect the already-validated suffix in the workflow and pass `--prerelease`
  exactly for suffixed versions.
- Keep stable `vX.Y.Z` publication unchanged.
- Add workflow/source-contract cases for stable, `-rc.1`, and malformed tags.

**Acceptance criteria**

- [x] Suffixed valid tags create GitHub prereleases.
- [x] Unsuffixed valid tags create ordinary releases.
- [x] Malformed tags remain rejected before build or publication.
- [x] Workflow syntax and release publication tests prove both command forms.

**Resolution**

Adopted. The publication step of `.github/workflows/release.yml` now derives the
publication kind from the tag alone, before the final verification chain and
therefore before `gh` is reached. A bare `vX.Y.Z` publishes exactly as before; a
tag matching the suffixed half of the producer grammar adds `--prerelease` to
the `gh release create` argument vector; anything else annotates
`::error::tag '<tag>' is not vX.Y.Z (optionally -suffix)` and exits. Stable
publication is byte-for-byte the command it was, because the flag is carried in
a separate array that expands to nothing for a stable tag -- `--verify-tag`,
`--title`, `--notes-file` and the asset vector are untouched.

The two classification branches are a further copy of the project's version
grammar, which is the risk this change introduces rather than removes, so they
are held to the original: `test-workflow-syntax` extracts both patterns from the
YAML and the producer's pattern from `scripts/make-release.sh`, then requires
over a table of 18 stable, prerelease and malformed shapes that the union of the
two accept exactly what the producer accepts, that they do not overlap, and that
they split that grammar stable-versus-suffixed.

The third branch is not redundant with the existing gate; it is the alarm on it.
A malformed tag is already rejected before any build, in the locate step, by the
version check inside `scripts/verify-release-qualification.sh` -- so a shape
arriving at publication means that gate was bypassed, and silently defaulting it
to either kind is the failure mode worth refusing.

*Verification.* `test-release-provenance` executes the workflow's own publication
shell -- extracted from `release.yml` and run against stub tag/signature
verifiers and a `gh` that records its argv -- once per command form: `v0.9.8`
publishes with no `--prerelease` and `--verify-tag` intact, `v0.9.8-rc.1`
publishes with `--prerelease` exactly once and under its own tag, and six
malformed shapes (`v0.9.8-`, `v0.9.8-rc..1`, `v0.9.8--rc`, `v0.9.8+1`, `v0.9`,
`0.9.8`) abort with `gh` never invoked; 86 -> 94 checks. The stable case also
requires that no *empty* argument reach `gh`, which is the one runner-shell
assumption the empty flag array carries: bash before 4.4 expands an empty array
under `set -u` to a single empty word, and `gh` would read that as an empty
asset path. `test-workflow-syntax` adds the grammar and fail-closed contracts
above; 375 -> 381 checks. Five
negative controls were run against both suites on a scratch copy of the tree:
removing the classification entirely -- the pre-R4 workflow -- fails six
workflow-syntax checks and the prerelease publication case; letting an
unrecognized shape fall through as a stable release fails the fail-closed check
and the first malformed case; widening the suffixed branch to `-.*` fails the
grammar-agreement and classification checks on exactly the four shapes the
producer rejects; inverting the two branches fails the classification check and
the stable publication case; and appending one quoted empty word to the `gh`
argument vector fails the empty-argument check. `make test-workflow-syntax
test-release-provenance test-release-history test-release-qualification
test-release-images test-release-preflight test-supply-chain
test-ci-local-routing` pass on the final tree, with preflight unchanged at 118
checks. No firmware source is involved.

### R5 - Make XC8 cache manifest generation fail closed

**Priority:** Release supply-chain hardening

**Problem**

The install and cache-verification scripts compute the readable-file manifest
with `find | sort | xargs` under `/bin/sh` and `set -eu`. POSIX shell reports the
pipeline status of `xargs`, so a failed `find` or `sort` can be hidden by a
successful final stage and yield a partial manifest. That weakens the promise
that every readable compiler/DFP input is inventoried.

**Recommended change**

- Use a shell with `pipefail`, or split the walk, ordering, and hashing into
  independently status-checked stages.
- Preserve NUL-delimited filenames and deterministic `LC_ALL=C` ordering.
- Add fixtures where `find`, `sort`, and `sha256sum` fail independently, and
  require both installation and restored-cache verification to reject each one.

**Acceptance criteria**

- [x] Failure of any manifest pipeline stage fails installation/verification.
- [x] No partial manifest is written or accepted after a scan/order/hash error.
- [x] Spaces and unusual non-NUL path bytes remain handled correctly.
- [x] Supply-chain, cache-restore, workflow-syntax, and release-preflight tests
  pass.

**Resolution**

Adopted, by splitting rather than by changing shells. Both scripts stay
`#!/bin/sh`: the walk, the ordering and the hashing are now three separately
status-checked stages, staged through NUL-delimited files in a private
`mktemp -d`, so no stage's status can be reported as the next one's. The
`|| die` on each names the stage that failed -- `could not scan/order/hash the
installed tree` in `scripts/install_pic_toolchain.sh`, the same three against
`the restored tree` in `scripts/verify_pic_toolchain_cache.sh`. `pipefail`
would also have worked, but only by moving both scripts to `bash`; the split
needs nothing that POSIX `sh` does not already promise.

The defect is not hypothetical and not subtle once instrumented. Driven with a
`find` that emits one genuine readable path and then exits non-zero -- exactly
what a real one does over a subtree it cannot read -- the previous installer
exited **0** having recorded **1 of 9** files as the frozen integrity manifest
of the tree a later job would trust.

What makes that worth a fix rather than a note is which way it fails. A
partial record is usually caught at restore time, because the verifier's full
walk disagrees with it -- but the walks are over the same tree with the same
permissions, so a condition that truncates one can truncate the other
identically, and two agreeing fragments verify clean. That is the whole
failure: a cache accepted as completely inventoried when most of it was never
hashed. Two consequences follow, and both are now enforced. Neither script may
record or accept an *empty* inventory, which is the limit case of the same
thing (an empty manifest matches an empty recomputation). And the verifier
reports a scan/order/hash failure by name instead of as a cache mismatch:
before this change a broken scanner was reported as a corrupted cache, which
is a different finding with a different response, and only one of the two
means the cache is bad.

Manifest content is unchanged, so nothing already recorded is invalidated: over
the 3603 files of the real XC8 3.10 + PIC10-12Fxxx DFP 1.9.189 install on this
host, the staged form reproduces the old pipeline's output byte for byte. (The
CI cache key is `hashFiles('scripts/install_pic_toolchain.sh')` in any case, so
editing the installer rotates the key and the next run installs fresh.) One
unrelated pipeline in the installer, `sha256sum ... | cut`, was deliberately
left alone: a masked failure there yields an empty digest that cannot equal a
pinned one, so it already fails closed.

*Verification.* `test-supply-chain` fails each stage independently, in both
scripts, through a `PATH` shim over `find`, `sort` and `sha256sum`: the `find`
stub breaks only the NUL-delimited manifest walk, so the symlink scan still
runs and the manifest stage is what breaks, and it emits a real readable file
before failing so that the later stages succeed over the fragment -- the
masking condition itself. Installation must reject all four cases (scan,
order, hash, empty) and leave *neither* stamp nor manifest behind;
verification must reject the same four by name, plus an empty recorded
manifest. Eight fixture files whose names carry spaces, both quote characters,
a backslash, shell metacharacters, a leading dash, UTF-8 and an embedded
newline are installed, inventoried (all eight appear in the recorded
manifest), verified, and caught both when one is tampered with and when a
ninth escaped-name file is added -- the same eight reduce to 2 entries and an
`xargs: unmatched double quote` error under a newline-delimited pipeline.
30 -> 46 checks.

Nine negative controls were run against a scratch copy of the tree. Restoring
the pre-R5 pipeline to both scripts, or to the installer alone, fails the
install scan-stage case as *accepted*; restoring it to the verifier alone
fails all four verify cases for the wrong reason (`does not match its recorded
manifest` instead of the stage). Keeping the staging but dropping one `|| die`
fails that stage's case the same way, so the status check is load-bearing and
not merely the restructuring. Removing either empty-inventory guard fails its
case; removing the empty-recorded-manifest guard fails that one. Reverting to
newline delimiting fails the suite outright, and pruning just the
unusually-named directory from the installer's walk fails the eight-entry
inventory check exactly. `make test-supply-chain test-workflow-syntax
test-release-preflight test-todo-index` pass on the final tree, with
workflow-syntax unchanged at 381 checks and preflight unchanged at 118. The
restored-cache half of the criterion is `test-supply-chain`'s verify section:
there is no separate cache-restore target. No firmware source is involved.

### R6 - Pin production release identity independently of development overrides

**Priority:** Release reproducibility hardening

**Problem**

Development variables such as `FW_BASE`, the tinyx5 membership, and several MCU
tags remain command-line/environment overridable. Both the Makefile
`RELEASE_IMAGES` set and the release script's nominally independent enumeration
consume those selected values, so their cross-check can agree on an overridden
identity. Current v0.9.10 declaration/count checks reject common deviations,
but the invariant should not depend on release-specific prose or on a later tag
workflow discovering that production was staged under noncanonical names.

**Recommended change**

- Separate immutable production release identity/membership from useful
  developer build overrides.
- Make production staging reject any override that changes canonical image
  basenames, MCU tags, part membership, or variant membership before cleaning,
  building, or creating scratch state.
- Keep build-directory and tool-path overrides available where they do not
  change artifact identity.
- Add direct and indirect environment/Make command-line tests for `FW_BASE`,
  `TINYX5`, MCU tags, and supported-variant sets.

**Acceptance criteria**

- [x] Production release staging always means the reviewed seven-part,
  21-image, 18-soak v0.9.10 identity regardless of inherited Make variables.
- [x] Identity-changing overrides fail before any build, soak, or staging work.
- [x] Legitimate tool and build-directory overrides continue to work.
- [x] Release-image, preflight, documentation, name-contract, and publication
  tests cover direct and inherited override attempts.

**Resolution**

Adopted, by adding a third statement rather than by freezing the development
variables. `FW_BASE`, the tinyx5 membership and the MCU tags stay overridable:
`test/test_pic_build.sh` builds whole synthetic matrices under `FW_BASE=`,
`PIC12F675_TAG=` and `PIC10F320_TAG=`, and a name and a die are things a
development target has to be able to vary. What changed is that a *production*
release no longer consumes those selected values without checking them against
a pin.

The pin is data. `RELEASE_IDENTITY_PINNED` in the Makefile is a literal
`<variable>=<reviewed value>` table, `override` so neither the command line nor
the environment reaches it, and it is derived from nothing a build override can
move -- a pin computed from `FW_BASE` would agree with exactly the thing it
exists to check. Beside it, `RELEASE_IDENTITY_IMAGES` and
`RELEASE_IDENTITY_SOAKS` spell the reviewed 21-image and 18-soak membership out
of literal part and variant lists. `RELEASE_IDENTITY_SELECTED` reads the same
names back out of the live tree, and `RELEASE_IDENTITY_DRIFT` is the
difference.

Both enforcement points fail before anything is consumed. A `make release` or
`make release-preflight` goal fails at PARSE time, so the recipe never runs,
the worktree lock is never taken and `scripts/make-release.sh` never becomes a
process. The script repeats the comparison for its own account -- it is also
run directly, by CI and by the documented recipe -- immediately after it reads
the release inventories and before the documentation validators, the `mktemp
-d` scratch directory, and any clean, build, soak or staged byte. It reports
each drifted field with its pinned value, its selected value and the
`$(origin)` of the name, resolved only on the path where it is already refusing
to start. Preflight and dry runs are checked too: a capability probe answered
for the wrong release answers the wrong question.

The two channels are not equivalent, and the second one is the reason this is
not merely tidy. A command-line assignment reaches the script's `print-<VAR>`
queries through `MAKEOVERRIDES` and beats a plain `=` assignment. The
environment cannot move a plain `=`, but it wins every `?=` -- and all four
per-part MCU tags, all three PIC die selectors, `XT_MCU` and three of the four
clock selectors are declared `?=`. An exported `PIC12F675_TAG` therefore
changed the release identity without appearing in any command anyone typed, and
neither the Makefile's canonical set nor the script's independent enumeration
could see it, because both were composed from it.

`scripts/verify-release-images.sh` gained the same cross-check. It already
discarded `MAKEFLAGS`, `MAKEOVERRIDES` and injected makefiles before reading
`RELEASE_IMAGES`, but not the environment, so the reproduction leg -- the
tag-triggered rebuild that is the public attestation that a published binary IS
the tagged source -- could have verified an identity an export had moved.

Scope, and two deliberate extensions beyond the literal list in the recommended
change. Pinned: the fields that decide an image's NAME (`FW_BASE`, the seven
MCU tag fields, the tinyx5 membership), the DIE that name is compiled for
(`XT_MCU`, `PIC10F322_CHIP`, `PIC10F320_CHIP`, `PIC12F675_CHIP`), the CLOCK its
timing evidence was measured at, and the variant sets. The die selectors are
here because an image named `bypass-pic10f322-cd4053_simple.hex` that was
compiled for another chip is the same defect wearing a reviewed name; the clock
selectors because the MANIFEST spells the classic-AVR clocks `1.2 MHz` and `1.0
MHz` as literals rather than reading `F_CPU`, so a re-clocked classic image
would have shipped under a canonical name and an undisturbed provenance record.
Both were free: the guard is table-driven.

Not pinned, and must not be: build directories and every tool path. Those do
not change what an artifact IS, a release host legitimately relocates them, and
the release already asserts and records the tool it actually selected -- the
preflight gate itself runs entirely on relocated tool paths. Fuse and CONFIG
bytes are likewise not pinned: they are read from Makefile truth into the
signed MANIFEST, so they are disclosed rather than silently substituted, which
is the property the clock fields lacked. `VARIANT` (singular) selects a
single-target action no release uses and is left alone.

Four fields in the table were already unreachable from both channels because
the Makefile declares them `override`: `PIC12F675_CHIP`,
`CLASSIC_VARIANTS_SUPPORTED`, `XT_VARIANTS_SUPPORTED` and
`PIC10F320_VARIANTS_SUPPORTED`. Naming them anyway is not redundant -- the pin
is what catches a SOURCE edit, the one channel `override` does not defend
against.

*Verification.* `test-release-images` (103 -> 178 checks) holds the real
Makefile to the reviewed identity: the pin and the canonical set are computed
from disjoint inputs and must agree as sets, the pin carries exactly 21 images
and 18 soak combinations, and none of the five pinned variables moves under a
command-line assignment or an inherited export. Eighteen identity-changing
command-line overrides and eleven inherited ones are each refused by the
parse-time guard, which must name the affected variable and must not reach the
release recipe; the plain-`=` names are separately asserted INERT from the
environment, so the two channels cannot be confused for one another, and the
four `override`-declared fields are asserted immovable rather than refused.
Relocated build directories, relocated tool paths and a single-target `VARIANT`
selection still reach the recipe. Four synthetic cases drive the production
`verify-release-images.sh` against a canonical set wider than the pin, narrower
than it, an empty pin, and a reordered one that must still pass.
`test-release-preflight` (118 -> 125 checks, 84 -> 88 Makefile queries) drives
the real step 0 into five refusals -- a command-line `FW_BASE`, an inherited
`PIC12F675_TAG`, an inherited `PIC10F322_CHIP`, a reduced tinyx5 membership and
an abbreviated `VARIANTS` -- and requires each to name the field, its pinned
and selected values and its Make origin, to stop before the tool preconditions,
and to leave no scratch directory or prospective output path; a relocated build
directory must still reach the terminal success record. The name-contract gate
(axes A and C) covers the new variable names, since the script reads them
through `print-<VAR>`.

Five negative controls were run against a scratch copy of the tree, each
failing exactly where it should. Removing the parse-time guard fails the first
command-line `make -n release` case in `test-release-images` while
`test-release-preflight` stays green at 125 checks; removing the script's
comparison inverts that precisely -- `test-release-images` stays green at 178
and preflight fails on its command-line `FW_BASE` case -- so the two
enforcement points are independently load-bearing rather than one guard
reported twice. Dropping the `override` keyword from `RELEASE_IDENTITY_PARTS`
fails the immovability loop at exactly that name. Dropping `PIC10F322_CHIP`
from the pinned table leaves both its command-line case and its inherited
preflight case accepted while every name field still passes, so the die
selectors catch something no name field does. Reverting
`verify-release-images.sh` accepts a canonical set wider than the pin. No
firmware source is involved.

### Second-pass validation already performed

The review host is not the fully provisioned release host. These results locate
the findings relative to the currently passing host contracts; they do not
close any second-pass item:

- `git diff --check main...HEAD`: passed.
- Host golden model: 988 checks passed.
- Exhaustive state model: 2,160 checks passed.
- Symbolic single-step model: 1,332 checks passed.
- PIC10F320 host variant lanes and both modular PIC shipping-source coverage
  gates passed with no failures.
- Release images (103), preflight (118), provenance (86), qualification (66),
  history (89), supply-chain (30), matrix, serialization, target-result, soak,
  rebuild, name-contract, TODO-index, and watchdog-note contract tests passed.
- Workflow syntax skipped because PyYAML is absent on the review host.
- Full `make test` could not complete because `avr-gcc` is absent and the local
  clang-tidy setup lacks 32-bit glibc headers.

The green results were compatible with F2 and P1: current fault tests observe
latches/reset entry rather than the affected physical pin modes, and current
release documentation tests governed generated PIC12F675 guidance without
rejecting the contradictory static `FLASHING.md` block. P1 closed that second
half -- `release_validate_pic12f675_flashing_helper` now holds every current
document, discovered rather than enumerated, to the same rule the generated
guidance follows -- so these figures predate the counts in the completion record
below.

## Final validation and release gate

Complete these only after R1-R6, F1-F4, P1-P2, T1-T2, and D1-D5 are done or an
explicit owner disposition recorded where an item permits one. The checked
`fe8ecc8` run below is historical evidence, not final-candidate evidence; the
pre-merge rows are reopened because F2-P2 require source, test, and documentation
changes.

- [ ] `git diff --check main...HEAD` passes after every second-pass change.
- [ ] `make test` passes on a host meeting the documented host-tool contract.
- [ ] `make test-long STRICT_TOOLS=1 MUTATION_ALLOW_SKIP=0` passes on the fully
  provisioned release host with no skipped target rows.
- [ ] AVR Classic, AVR-XT, PIC10F322, PIC10F320, and PIC12F675 builds pass all
  flash, RAM, stack, fuse/CONFIG, timing, static-analysis, simulator, fault,
  lock-step, target-I/O, source-coverage, and mutation gates.
- [ ] AVR-XT `INVEN` and PIC12F675 comparator-ownership fault cases prove
  physical coil-pin de-energization before the watchdog spin.
- [ ] AVR programming negative controls prove no fuse or flash command runs
  before a successful selected-image build and validation.
- [ ] The release-shipped PIC12F675 helper passes its fake-programmer and
  packaging contracts; retained PICkit 3/MPLAB X 6.20 evidence validates its
  exact hardware path; durable documentation rejects every retired raw writer.
- [ ] PIC12F675's two authoritative aggregates visibly share one retained matrix
  identity in local and clean-runner release paths.
- [ ] `scripts/make-release.sh --preflight v0.9.10` rejects version drift and
  accepts the exact pinned release environment.
- [ ] A release dry run passes after this branch-only document is deleted.
- [ ] Current-release declarations match the staged canonical set: seven parts,
  21 images, 18 soak combinations, six modular targets, and four modular shell
  sources.
- [ ] Production qualification completes all 18 full-duration soak combinations
  and retains the exact canonical evidence set.
- [ ] The artifact-only release commit has the qualified source commit as its
  sole parent, contains only the intended `release/v0.9.10/` artifacts, and
  passes release-history verification.
- [ ] The annotated `v0.9.10` tag points to the artifact commit and the clean
  release workflow reproduces every signed image byte-for-byte before
  publication.

**Gate run (2026-08-23, HEAD `fe8ecc8`, clean tree).** `git diff --check
main...HEAD` clean. `make test`: 84 summary lines, 0 failures, "all fast
pre-hardware tests passed". `make test-long STRICT_TOOLS=1
MUTATION_ALLOW_SKIP=0`: 84 summary lines, 0 failures, "all FULL (exhaustive)
pre-hardware tests passed"; mutation summary 132 killed, 0 survived, 0 errored,
0 PIC skipped, 0 ATtiny202 skipped, with every target row reporting RAN
(PIC shell, PIC10F320, PIC12F675, ATtiny202) rather than skipped -- which is
what `STRICT_TOOLS=1 MUTATION_ALLOW_SKIP=0` exists to prove. Golden-model line
coverage 99.39% (floor 90%); verified-core `src/bypass_pure.c` 100.00% (floor
95%). `scripts/make-release.sh --preflight v0.9.10` accepted on the clean tree;
`--preflight v0.9.11` rejected at "CHANGELOG.md must contain one dated [0.9.11]
section", so version drift fails before any staging work.

The production qualification, artifact-commit, signed-tag, and clean-runner
publication rows are release-time by construction. The dry-run row waits on the
deletion of this document, which the merge decision below sequences before the
release cut: the staging path's refusal while this file exists is the G1 guard
working as specified. All other pre-merge rows must be reclosed on the actual
second-pass candidate. PIC12F675's matrix identity was proved on the earlier
local path by `test/test_pic_build.sh` and
`test/test_release_qualification.sh`; its clean-runner half remains release-time
evidence and must be exercised for real by the tag workflow.

## Review validation already performed

- `git diff --check main...HEAD`: passed.
- Formal model executable: 2,160 checks passed.
- Release workflow syntax: 344 checks passed.
- Supply-chain contracts: 30 checks passed.
- Release image contracts: 103 checks passed.
- Release qualification contracts: 48 checks passed.
- Release preflight contracts: 52 checks and 82 Make queries passed.
- Release provenance contracts: 83 checks passed.
- Release history contracts: 87 checks passed.
- PIC12F675 shipping-source coverage: passed with the expected per-variant
  harness counts and negative oracle probe.
- Mutation sandbox: 131 checks passed.
- PIC10F322 shipping-source coverage: failed to compile under GCC 8.5 because of
  the four strict-conversion diagnostics recorded in T1.
- Full `make test`/`make test-long` was not independently completed on the review
  workstation: its default Python is 3.6.8, `avr-gcc` and target tools are
  absent, and its clang-tidy setup lacks the required 32-bit glibc headers.

## Completion record

Record each completed item with its commit ID and decisive validation command.

| Item | Status | Commit | Decisive validation |
| --- | --- | --- | --- |
| R1 | IMPLEMENTED | `7dab4db` | `make CC=: test-pic-build`; `test/test_release_qualification.sh`; `test/test_workflow_syntax.sh` |
| R2 | DONE | `7b54dea` | `test/test_release_preflight.sh`; `test/test_release_provenance.sh`; `make test-workflow-syntax test-release-history` |
| R3 | DONE | `9a7c479` | `make test-pic-build test-release-preflight test-release-qualification`; `scripts/make-release.sh --preflight v0.9.10` |
| F1 | DONE | `a8fe23d`, `b14cd7a` | `make test`; relay fault + coverage lanes on all six substrates; PIC/AVR flash-budget gates |
| T1 | DONE | `fd9aa28` | `make test`; `make pic10f322-coverage-check-fw HOSTCC=gcc-10`; `test/test_release_preflight.sh` |
| T2 | DONE | `130b22f` | `make test`; `test/test_workload_rebuild.sh`; mutated-tree `make test` reaching the PIC12F675 host oracle |
| D1 | DONE | `ed5b654` | `make test-release-preflight` (85 -> 101 checks, 12 negative controls); `make test-release-qualification test-todo-index test-makefile-name-contract test-release-history` |
| D2 | DONE | `3a6c67d` | `make test-workflow-syntax test-ci-local-routing test-release-preflight test-release-qualification test-release-history test-todo-index test-makefile-name-contract`; full `scripts/ci-local.sh` |
| D3 | DONE | `cbc57be` | `make test-release-preflight` (101 -> 113 checks); `make test-release-qualification test-release-history` (88 -> 89); `make test-todo-index test-makefile-name-contract`; full `scripts/ci-local.sh` |
| G1 | DONE | `fe8ecc8` | `make test-release-preflight` (113 -> 118 checks); `scripts/make-release.sh --preflight v0.9.10` accepted with the document present; `make test-release-qualification test-release-history test-release-provenance test-release-images test-soak-timing test-build-serialization test-todo-index test-makefile-name-contract`; `make test`; `make test-long STRICT_TOOLS=1 MUTATION_ALLOW_SKIP=0` |
| F2 | IN PROGRESS | | Implementation and host contracts complete; provisioned AVR-XT/PIC12F675 target, resource, and merged 136-mutant validation pending |
| F3 | IMPLEMENTED | (pending) | One-write constant-mask `LATA` coil clear adopted; relay image 248 -> 242 words and return stack 4 -> 3, CD4053 images byte-identical; write sequence asserted by host (59 -> 62 checks) and gpsim resync oracles; 2 new PIC10F320 mutants, with the merged inventory now 136 |
| F4 | IMPLEMENTED | (pending) | All 21 images rebuild byte-identical; `make test-static-assert-guards` (39 -> 68 checks, 11 near-bound FIRES/CLEAN fixtures); the new `test/avr/test_sim.c` pet-budget check on both classic parts and all three variants; all five MISRA lanes clean |
| P1 | IMPLEMENTED | (pending) | `scripts/flash-pic12f675.py` staged, checksummed and reproduced as a required non-image release artifact (`RELEASE_HELPER_MAP`), with `RELEASE_IMAGES` still exactly 21; `make test-pic12f675-flash-helper` (172 checks) drives the real helper against a stateful fake `ipecmd`; `test-release-images` 178 -> 190, `test-release-preflight` 125 -> 144, `test-release-provenance` 94 -> 97, `test-release-qualification` 66 -> 67; raw PIC12F675 writer commands retired from every current document and rejected by contract. Retained PICkit 3/MPLAB X 6.20 bench evidence remains open by construction |
| P2 | OPEN | | Build-before-hardware AVR programming order and fake-programmer regression |
| D4 | OPEN | | Final release date, resource tables, and PIC10F320 run-5 baseline wording |
| D5 | OPEN | | Simulator timing/physical-language and pip prerequisite reconciliation |
| R4 | IMPLEMENTED | (pending) | Tag-derived publication kind in `release.yml`; `test-release-provenance` executes the publication shell for stable, `-rc.1`, and six malformed tags (86 -> 94 checks); `test-workflow-syntax` pins both branches against the `scripts/make-release.sh` grammar (375 -> 381 checks) |
| R5 | IMPLEMENTED | (pending) | XC8 cache manifest split into three separately status-checked NUL-delimited stages in both `install_pic_toolchain.sh` and `verify_pic_toolchain_cache.sh`; neither records nor accepts a partial or empty inventory, and the verifier names the failing stage instead of reporting a cache mismatch; `test-supply-chain` fails each stage independently in both scripts and inventories 8 unusually-named files (30 -> 46 checks) |
| R6 | IMPLEMENTED | (pending) | Reviewed production identity pinned as literal `override` data in the Makefile (`RELEASE_IDENTITY_PINNED` plus the 21-image/18-soak sets), enforced at parse time on the release goals and again inside `make-release.sh` before its scratch directory, and cross-checked by `verify-release-images.sh` on the reproduction leg; `test-release-images` refuses 18 command-line and 11 inherited identity overrides while build-directory and tool-path overrides still reach the recipe (103 -> 178 checks) and `test-release-preflight` drives step 0 into five refusals that leave no scratch state (118 -> 125 checks) |
| Final validation | REOPENED | | The `fe8ecc8` run remains historical evidence; rerun every pre-merge gate after F2-P2 and documentation/release changes |

## Merge decision

Do not merge `v0.9.9-polish` or begin production `v0.9.10` qualification until
F2, P1, P2, and D4 are complete. Complete or explicitly disposition F3 and F4;
finish D5 and the release hardening items appropriate to the project's claimed
release contract; then rerun every reopened pre-merge gate. Finally delete this
file and all references, run the release dry run on the actual candidate, and
only then merge and begin production qualification. Production soaks, the
artifact-only release commit, signed tag, and clean-runner byte-for-byte
reproduction remain post-merge release-time gates.
