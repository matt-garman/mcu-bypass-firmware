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

- [ ] Exactly avr-gcc `7.3.0` is accepted; prefix/suffix collisions fail.
- [ ] Exactly XC8 `V3.10` is accepted independently for PIC10F322/PIC12F675 and
  PIC10F320; prefix/suffix collisions fail.
- [ ] Diagnostics name the selected tool, observed banner, expected version,
  and corrective action.
- [ ] Preflight rejects drift before scratch creation, builds, or soaks.
- [ ] `test-release-preflight`, `test-workflow-syntax`, and documentation
  contract tests pass.

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

- [ ] Both static examples can finalize a transaction created by the preceding
  signed-release programming example.
- [ ] Generated and static instructions carry the same release identity.
- [ ] `make help` describes the variable's complete supported scope.
- [ ] Documentation contracts detect a future omission or drift.
- [ ] PIC12F675 trim-evidence, release-program-image, release-preflight, and
  static documentation tests pass.

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

**Acceptance criteria**

- [ ] The repository owner records the selected policy and rationale.
- [ ] Every relay-capable shell has a clearly stated correction and
  resynchronization guarantee, including the PIC10F320 exception if capacity
  prevents parity.
- [ ] Tests distinguish coil de-energization from physical relay-state
  synchronization instead of treating final-low output alone as full recovery.
- [ ] Fault tests cover BYPASS plus unintended SET and ENGAGED plus unintended
  RESET outcomes.
- [ ] Active-pulse and instruction-phase exclusions remain explicit.
- [ ] Flash, RAM, stack, timing, watchdog-margin, simulator, fault, mutation,
  coverage, and target-result gates pass for all affected variants.
- [ ] Documentation states what simulation cannot prove about relay mechanics.

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

- [ ] `pic10f322-coverage-check-fw` passes with the documented minimum host
  compiler and all strict conversion warnings enabled.
- [ ] The target XC8 build remains warning-clean and within every variant's
  flash budget.
- [ ] No cast suppresses a real narrowing or changes the integrity predicate.
- [ ] Source coverage still measures the shipping configuration with
  `BYPASS_CTX_CHECK` enabled.
- [ ] Relevant static analysis, model, target, mutation, and build tests pass.

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

- [ ] `make test` on a host without PIC target tools executes both shipping-
  source coverage gates and reports their exact check/coverage results.
- [ ] `make test-long` executes the same gates exactly once.
- [ ] A mutation removing relay correction or context-check integration turns
  the default aggregate red through the relevant host oracle.
- [ ] Standalone PIC aggregates still execute and verify the gates.
- [ ] Aggregate routing, workload, rebuild, and clean-contract tests pass.

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

- [ ] Every hardware claim is classified as field report or controlled
  qualification.
- [ ] No project document contradicts the hardware log.
- [ ] Controlled records require reproducible source/image and procedure data.
- [ ] Pin-compatible parts are not described as firmware/programming-
  interchangeable without qualification.
- [ ] Documentation and source-contract tests pass.

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

- [ ] Qualification state is consistent within each design/evidence record.
- [ ] Simulator evidence is never described as a physical-hardware observation.
- [ ] Current tracer mechanics are described consistently.
- [ ] Workflow headers match the actual gates and pinning model.
- [ ] Workflow-syntax and documentation contract tests pass.

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

- [ ] The release sequence has no ambiguous source or artifact identity.
- [ ] A failed or postponed release cannot leave `main` indefinitely claiming
  nonexistent retained evidence.
- [ ] The tagged release contains accurate final wording and the claimed
  evidence inventory.
- [ ] Versioned release-preflight and release-history tests cover the selected
  transition.

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

- [ ] The release-staging path fails when this document exists.
- [ ] The release-staging path fails when a tracked file still references its
  basename after deletion.
- [ ] The branch-safe capability preflight remains usable while the document
  exists.
- [ ] Negative and positive branch-document contract tests pass.
- [ ] This document and all references are absent from the merge candidate.

## Final validation and release gate

Complete these only after R1-R3, the F1 disposition, T1-T2, and D1-D3 are done.

- [ ] `git diff --check main...HEAD` passes.
- [ ] `make test` passes on a host meeting the documented host-tool contract.
- [ ] `make test-long STRICT_TOOLS=1 MUTATION_ALLOW_SKIP=0` passes on the fully
  provisioned release host with no skipped target rows.
- [ ] AVR Classic, AVR-XT, PIC10F322, PIC10F320, and PIC12F675 builds pass all
  flash, RAM, stack, fuse/CONFIG, timing, static-analysis, simulator, fault,
  lock-step, target-I/O, source-coverage, and mutation gates.
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
| R1 | IMPLEMENTED | pending | `make CC=: test-pic-build`; `test/test_release_qualification.sh`; `test/test_workflow_syntax.sh` |
| R2 | OPEN | | |
| R3 | OPEN | | |
| F1 | OPEN | | |
| T1 | OPEN | | |
| T2 | OPEN | | |
| D1 | OPEN | | |
| D2 | OPEN | | |
| D3 | OPEN | | |
| G1 | OPEN | | |
| Final validation | OPEN | | |

## Merge decision

Do not merge `v0.9.9-polish` or begin production `v0.9.10` qualification while
R1, R2, or R3 is open. Resolve F1 explicitly before describing the relay fault
posture as reference-grade. Complete T1 and T2 before relying on a green default
suite for the final candidate. Reconcile the documentation items, delete this
file and all references, run the final validation gate, and only then merge and
cut `v0.9.10`.
