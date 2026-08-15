# PIC12F675 Branch Merge Readiness

**Status:** Open, branch-only working document

**Reviewed branch:** `pic12f675-support`

**Reviewed tip:** `fc59dbd` (`docs: align PIC12F675 release inventories`)

**Last updated:** 2026-08-14

This is the living checklist for finishing PIC12F675 release support and making
`pic12f675-support` ready to merge into `main`. It is intentionally temporary:
update it as work lands, then remove it in the final branch-preparation commit so
it does not merge into `main`.

## Release Standard

For this project, `v0.9.x` means maximally validated in software. Hardware and
silicon validation begins the `v1.x.y` line. PIC12F675 is ready for a v0.9.x
release when its software assurance, build/release integration, documentation,
and provenance are at target-appropriate parity with the existing release MCUs.

Real-programmer and board measurements remain important, but they are not
v0.9.x blockers when they are accurately identified as hardware-only residual
risk and no release documentation claims that they have already passed.

## Current Assessment

The PIC12F675 implementation is substantially at software-validation parity:

- Three production images are in the 21-image canonical release set.
- Three PIC12F675 combinations are in the 18-combination release soak set.
- Six PIC12F675 build/aggregate records are in the 34-file retained-evidence
  inventory.
- Build, flash budget, CONFIG, hardware return stack, cppcheck/MISRA,
  shipping-source coverage, gpsim CLI, target I/O, fault injection, lock-step,
  soak, mutation, CI, release reproduction, and calibration-image isolation
  are integrated.
- No nominal-path PIC12F675 firmware defect was found in the meta-review.

The branch is not yet merge-ready as a completed release-support change because
the complete equipped-host software qualification and final branch hygiene
remain pending.

## Priority Summary

| ID | Priority | Item | Status |
|---|---:|---|---|
| P12-1 | Blocker | Make generated reproduction instructions build PIC12F675 | Implemented |
| P12-2 | Blocker | Correct PIC12F675 flashing instructions and trim claims | Implemented |
| P12-3 | High | Complete generated release metadata and commit message | Implemented |
| P12-4 | High | Reconcile the feasibility document's support status | Implemented |
| P12-5 | High | Correct stale design, safety, test, and help documentation | Implemented |
| P12-6 | High | Remove hard-coded `/tmp` use from the programming workflow | Implemented |
| P12-7 | High | Add regressions for the review gaps | Implemented |
| P12-8 | Gate | Run the complete software qualification on the equipped host | Complete (dry-run) |
| P12-9 | Gate | Perform final branch and merge hygiene | Open |

## P12-1 - Generated Reproduction Instructions

### Problem

The generated `MANIFEST.md` reproduction block in
`scripts/make-release.sh:1735-1737` builds the previous 18-image set and omits
`make pic12f675`. It then passes `RELEASE_IMAGE_DIRS`, which includes
`PIC12F675_BUILD_DIR`, to `scripts/verify-release-images.sh`. On a clean checkout,
the documented procedure therefore cannot reproduce the 21-image release.

The tag workflow already has the correct build at
`.github/workflows/release.yml:235-238`; the generated public instructions need
to match it.

### Required Work

- [x] Add the PIC12F675 three-image build to the generated reproduction block.
- [x] Ensure the command uses the selected/pinned `PIC_CC` and `PIC_DFP` contract
      consistently with the rest of the generated procedure.
- [x] Keep the generated build list and `RELEASE_IMAGE_DIRS` in exact agreement.
- [x] Confirm the instructions succeed from a clean checkout with no prior
      PIC12F675 artifacts.

### Acceptance

- [x] A generated v0.9.9 dry-run `MANIFEST.md` includes the PIC12F675 build.
- [x] Following the generated commands from a clean tree produces all 21 images.
- [x] `scripts/verify-release-images.sh` passes over the generated build paths.

## P12-2 - Flashing Instructions and Trim Claims

### Problem

The generated per-image flashing command at `scripts/make-release.sh:1570-1574`
reduces the workflow to `make pic12f675-program VARIANT=<v>` and says it
"preserves factory OSCCAL/BG". The actual target requires:

- A baseline created by `pic12f675-preflight`.
- `PIC12F675_TRIM_EVIDENCE` naming that baseline.
- `PIC12F675_BENCH_RESULT` naming a new retained result directory.
- A live pre-write comparison and a post-write readback.

The target rejects an image that explicitly writes flash word `0x3FF`, but the
writer invocations at `Makefile:6871-6875` do not themselves establish that the
programmer preserves OSCCAL/BG during erase/program. `Makefile:6878-6904` detects
a loss afterward, when the device may already have been damaged. The fake-tool
regression correctly models that behavior; the release wording is the defect.

### Required Work

- [x] Replace the abbreviated generated command with either the complete
      preflight/program sequence or an unambiguous pointer to the complete
      mandatory procedure.
- [x] State that the guarded workflow checks, verifies, and records OSCCAL/BG
      before and after programming.
- [x] Do not claim that an unqualified programmer command preserves trim.
- [x] State explicitly that actual programmer preservation remains unvalidated
      until the v1.x hardware pass.
- [x] Keep the warning that trim loss can leave a device apparently functional
      but with wrong timing or BOR/POR thresholds.
- [x] Reconcile `README.md`, `release/README.md`, `TOOLCHAIN.adoc`, generated
      `MANIFEST.md`, Make help, and source/Makefile comments to one precise claim.

### Acceptance

- [x] Every published PIC12F675 flashing example includes or requires preflight
      evidence and a new result directory.
- [x] No current release-facing text says the unvalidated command "preserves"
      OSCCAL/BG.
- [x] The software-vs-hardware boundary is stated consistently everywhere.
- [x] The fake programmer tests still cover baseline mismatch, post-write trim
      change, no-op/failed write, readback failure, and retained PASS/FAIL data.

## P12-3 - Generated Release Metadata

### Problem

The release producer runs both PIC12F675 qualification gates, but generated
human-readable artifacts still describe the pre-PIC12F675 release:

- `scripts/make-release.sh:1645-1646` omits PIC12F675 from release scope.
- `scripts/make-release.sh:1681` omits both PIC12F675 gates and says "both PIC
  parts".
- `scripts/make-release.sh:1694-1697` labels the shared compiler/DFP only as
  PIC10F322.
- `scripts/make-release.sh:1781-1788` omits PIC12F675 from generated
  `commit_msg.txt` scope and validation.
- `scripts/make-release.sh:32-45` (the script's own header comment) still
  describes the pre-PIC12F675 release: "PIC10F322 and PIC10F320" build scope, a
  gate list missing `pic12f675-test` and `pic12f675-test-target-variants`, and
  "= 15 combos". It is not generated output, but it misdescribes what the
  producer now does and is the same defect class as the generated body above.

### Required Work

- [x] Add PIC12F675 to generated release scope.
- [x] Add `pic12f675-test` and `pic12f675-test-target-variants` to the generated
      validation statement.
- [x] Change old two-PIC wording to accurately describe all three PIC targets.
- [x] Attribute shared `PIC_CC`/`PIC_DFP` provenance to both PIC10F322 and
      PIC12F675 without pretending they are independently selected tools.
- [x] Add PIC12F675 to generated release commit-message scope and validation.
- [x] Correct the `scripts/make-release.sh:32-45` header comment to the current
      three-PIC build scope, both PIC12F675 gates, and 18 soak combinations.

### Acceptance

- [x] A v0.9.9 dry-run manifest names all seven MCU parts, all required target
      gates, 21 images, 18 soak combinations, and the correct selected tools.
- [x] The generated release commit message reports the same scope.
- [x] Human-readable metadata agrees with `QUALIFICATION` and retained evidence.

## P12-4 - Feasibility Document Status

### Problem

`docs/pic12f675_feasibility.md:3-21` says PIC12F675 is staged, absent from release
integration, and not release-supported. The same document correctly says at
lines 1101-1113 and 1372-1389 that it is release-supported from v0.9.9 and fully
integrated.

### Required Work

- [x] Replace the opening status with the current v0.9.9 disposition.
- [x] Preserve the preimplementation history, but label historical/prospective
      statements so they cannot be mistaken for current status.
- [x] Keep items 1, 2, 8, and 9 classified as v1.x hardware work.

### Acceptance

- [x] A reader can determine current support status from the opening section.
- [x] No current-tense section says the target is excluded from `all`, CI, or
      release integration.

## P12-5 - Current Documentation Parity

### Problem

Several current documents still encode the old six-part, two-PIC, 15-soak, or
28-evidence topology. Some are cosmetic, but the timing and BOR text is
safety-relevant.

The stale "both PIC parts / BOTH chips / two PIC lanes" comments are broader than
the three Makefile spots first listed here, so this item is a *classifying pass*,
not a fixed list. Each such comment must be judged individually, because it
cannot be blanket-swept: the project deliberately keeps "both"/"32x" wording
where a fact is specific to the PIC10F320+PIC10F322 pair (the
`pic-naming-322-vs-32x` convention), and only the comments describing something
now shared by all three PIC parts are stale. The confirmed three-way-stale
locations are enumerated below; the must-keep contrast (e.g.
`Makefile:4090-4091`, scoped to the `PIC10F320_CC ?= $(PIC_CC)` default) is why a
mechanical sweep is wrong.

### Required Work

- [x] Correct `DESIGN_DOCUMENTATION.adoc:137-140` so PIC12F675's 1.024 ms tick is
      not described as nominally 1.000 ms.
- [x] Correct `DESIGN_DOCUMENTATION.adoc:158-168` and later references from two
      polled PIC implementations to three, with PIC12F675 timing kept distinct.
- [x] Add PIC12F675 to the primary BOR table at
      `DESIGN_DOCUMENTATION.adoc:225-246`, including its approximately 2.1 V
      threshold and inability to enforce a >4 V peripheral-safe floor.
- [x] Reconcile the six-target/three-generation introduction near
      `DESIGN_DOCUMENTATION.adoc:1094-1104` with the seventh target and fourth
      core generation.
- [x] Correct `test/README.md:455` so the PIC12F675 return-stack gate is included.
- [x] Correct `test/README.md:461` from 28 evidence files/15 soaks to the current
      34/18 contract.
- [x] Scope the PIC hardware-gap section at `test/README.md:786-824` to the
      PIC10F32x pair, then add or point to the distinct PIC12F675 hardware gaps.
- [x] Update `test/pic/gpsim_bootstrap.h` from two PIC parts to all three at both
      `:4-6` and `:34` ("the footswitch pin is RA3 on both supported parts").
- [x] Update stale release comments/help at `Makefile:6959-6961`,
      `Makefile:7004`, and `Makefile:7356-7358`.
- [x] Correct the genuinely three-way-stale Makefile comments the classifying
      pass has confirmed, keeping any 320+322-pair wording intact:
      - `Makefile:981-990` -- the central `PIC_*` naming rule ("SHARED BY BOTH
        PIC PARTS ... behind both chips"); PIC12F675 shares `PIC_CC`, `PIC_DFP`,
        the sampling/pin/bootstrap helpers, and other generic mechanism, while
        retaining a distinct TMR0-aware soak adapter source.
      - `Makefile:1296-1297` -- the gpsim CLI shared preflight "BOTH PIC chips";
        `pic12f675-test-gpsim` uses the same `gpsim_wrapper_preflight`.
      - `Makefile:1399` and `Makefile:1410` -- the return-stack gate "(BOTH
        chips)" / "Both parts declare STACKDEPTH=8"; `pic12f675-test-stack-bound`
        runs the same generic gate.
      - `Makefile:1508-1509` -- the gpsim bootstrap "ALL FOUR harnesses ... on
        BOTH parts"; PIC12F675 has all four harnesses.
      - `Makefile:5045` -- "Both chips' harnesses print the identical markers";
        the PIC12F675 harnesses emit them too.
- [x] Correct `test/check_stack_depth_pic.sh:11-22` ("the one resource bound on
      the PIC10F320" / "Both supported parts ... PIC10F32{0,2}") to include the
      third PIC part that now runs this gate.
- [x] Correct the `src/bypass_compile_checks.h:8-11` header comment, which still
      says the shared contract is "Included by the three modular hardware shells
      (avr_classic, avr_xt and pic10f322)"; PIC12F675 now includes it as a fourth
      shell. (Firmware source -- user edit; the matching test lives in P12-7.)
- [x] Add PIC12F675 to the top-level README's built-image validation summary.
- [x] Correct `release/README.md:49`, which calls the six v0.9.6-v0.9.8 targets
      the "first four parts".

### Acceptance

- [x] Current documents consistently state seven parts, three PIC targets, 21
      images, 18 soak combinations, and 34 retained evidence files where counts
      are relevant.
- [x] Timing text distinguishes the 1.024 ms PIC12F675 tick from 1.000 ms targets.
- [x] Primary safety guidance includes the PIC12F675 BOR limitation.
- [x] No comment describing a fact now shared by all three PIC parts still says
      "both"/"two"; every remaining target-cardinality "both"/"32x" comment is
      verified specific to the PIC10F320+PIC10F322 pair.

## P12-6 - Private Temporary Data

### Problem

The new programming workflow hard-codes shared, disk-backed `/tmp` for full
device readback and programming snapshots at `Makefile:6573`, `Makefile:6727`,
and `Makefile:6731`. This ignores caller-selected temporary storage and violates
the development environment's rule that no files may be created under `/tmp`.

### Required Work

- [x] Move baseline, program snapshot, and transient bench data to an explicitly
      controlled private location.
- [x] Honor a caller-selected safe temporary root where practical.
- [x] Do not fall back to `/tmp` in this environment.
- [x] Preserve mode-0700 directories, exclusive result creation, traps, digest
      checks, and interruption evidence.
- [x] Ensure diagnostics do not print sensitive full-device contents.

### Acceptance

- [x] `pic12f675-preflight` and `pic12f675-program` create no `/tmp` content.
- [x] Success, failure, and signal-interruption paths remove transient data while
      retaining only the explicitly requested evidence/result paths.
- [x] Existing programming transaction tests pass with a temporary root that
      contains spaces.

## P12-7 - Regression Coverage for Meta-Review Gaps

### Required Work

- [x] Extend release tests to prove the generated reproduction block builds every
      directory represented by `RELEASE_IMAGE_DIRS`.
- [x] Assert generated manifest scope includes PIC12F675.
- [x] Assert generated validation prose names both PIC12F675 aggregates.
- [x] Assert generated compiler/DFP attribution includes PIC12F675.
- [x] Assert generated `commit_msg.txt` includes PIC12F675 scope and validation.
- [x] Assert generated flashing guidance does not claim unvalidated trim
      preservation and cannot omit required preflight/result inputs.
- [x] Add a temporary-root regression proving the PIC12F675 bench workflow does
      not hard-code `/tmp`.
- [x] Close the shared-compile-check shell-census gap: `bypass_mcu_pic12f675.c`
      actively included `bypass_compile_checks.h`, but
      `test/test_static_assert_guards.sh`'s `SHARED_CHECK_SHELLS` listed only
      `avr_classic`, `avr_xt`, and `pic10f322`, so the negative-include
      meta-fixture never exercises the PIC12F675 shell. Add it, and derive the
      census from "every shell that actively includes the header" rather than a
      hand-maintained literal, so a future shell cannot silently drop out of the
      check. (The contract itself is still enforced for PIC12F675 by the dynamic
      `find_shells_missing_shared_checks` sweep; this closes the meta-coverage
      parity gap, not an enforcement hole.)
- [x] Add narrow semantic documentation checks only where the safety/release
      contract justifies maintaining them; avoid pinning incidental prose.

### Acceptance

- [x] Each newly added test fails against `a87416e` for its intended reason.
- [x] Each test passes only after the corresponding production/documentation fix.
- [x] The tests exercise generated output, not merely source-string presence,
      wherever practical.

### Completed Chunk Evidence

The release-generation and metadata chunk (P12-1, P12-3, and the first five
P12-7 regressions) passed:

- Release qualification: 38 checks.
- Release image verification: 90 checks.
- Release preflight: 30 checks and 82 Makefile queries.
- Release provenance: 78 checks.
- Makefile name contract: 48 checks.
- Bash syntax and `git diff --check`.

The focused qualification regression was also run with the release producer from
`a87416e`; it failed because that producer did not consume the corrected rendered
documentation sections. Full cross-toolchain release generation remains part of
P12-8 and is intentionally unchecked above.

### Completed Trim-Guidance Chunk Evidence

The flashing-instructions and trim-claim chunk (P12-2 and its P12-7 regression)
passed:

- Generated release qualification/documentation: 44 checks.
- Generic, PIC10F320, and PIC12F675 fake build/programming contracts: 36, 75,
  and 88 checks respectively.
- Release preflight: 30 checks and 82 Makefile queries.
- Release provenance: 78 checks.
- Makefile name contract: 48 checks.
- Bash syntax and `git diff --check`.

The generated transaction is fail-stop on repository discovery, exact tag
commit identity, clean worktree state, preflight failure, and per-image shortcut
injection. It deliberately publishes no ipecmd hardware procedure: the routing
is software-tested, but safe reader/writer attachment or handoff remains part of
the `1.x.y` hardware pass. The completed private temporary-storage implementation
and its evidence are recorded below.

### Completed Private-Temporary-Data Chunk Evidence

The programming temporary-storage chunk (P12-6 and its P12-7 regression) passed:

- Generic, PIC10F320, and PIC12F675 fake build/programming contracts: 36, 75,
  and 89 checks respectively.
- Generated release qualification/documentation: 44 checks.
- Release image verification: 90 checks.
- Release preflight: 30 checks and 82 Makefile queries.
- Release provenance: 78 checks.
- Makefile name contract: 48 checks.
- Bash syntax, independent focused review, and `git diff --check`.

Both programming targets use a current-user-private caller-selected root, reject
shared `/tmp`/`/var/tmp`, unsafe permissions/ownership ancestry, and path text
that cannot safely cross recursive Make. Transient directories are exclusively
created mode 0700 only after cleanup traps know their paths. The regression runs
the complete transaction suite under a root containing spaces, requires cleanup
after every success/failure/signal path, and exercises each unsafe-root rejection
through both preflight and programming. Only the requested baseline and result
paths remain durable.

### Completed Shared-Check Census Chunk Evidence

The shared compile-check shell-census regression (P12-7) now derives its
negative-fixture set from every `bypass_mcu_*.c` shell with an active direct
include of `bypass_compile_checks.h`; it no longer maintains a three-shell
literal. The host-independent topology section exercised the AVR-classic,
AVR-XT, PIC10F322, and PIC12F675 shells independently, and an independent review
confirmed that a temporary fifth active shell was automatically included and
tested. Bash syntax, the focused review, and `git diff --check` passed.

This host does not provide `avr-gcc`, so the same script stopped at its first
AVR compile control after all topology/census checks passed. The complete
compiler-backed guard-mutation run remains part of P12-8 on the equipped host.

### Completed Feasibility-Status Chunk Evidence

The feasibility reconciliation (P12-4 and the final P12-7 documentation
regression) now opens with the v0.9.9 software-release disposition, current
default-build/CI/release counts, and the explicit `1.x.y` boundary for hardware
items 1, 2, 8, and 9. The retained 2026-08-05 assessment, sequencing, and
documentation plan are labeled as historical rather than silently rewritten.

The release-qualification regression uses one explicit opening-status boundary,
binds all four residual items to the hardware pass, requires an explicit
statement that preservation is not guaranteed, and rejects only current release
exclusions or affirmative trim-preservation claims. Verification passed:

- Generated release qualification/documentation: 45 checks.
- Makefile name contract: 48 checks.
- Independent focused review, Bash syntax, and `git diff --check`.

### Completed Design-Safety Parity Chunk Evidence

The safety-critical portion of P12-5 now distinguishes PIC12F675's four-rollover
1.024 ms tick throughout the sample cadence, clean-input bounds, blocked-output
re-arm budgets, and architecture discussion. It also records the fixed
2.025-2.175 V BOD range, lack of `BORV`, external >4 V supervision requirement,
and the seven-target/four-generation/six-modular-target architecture.

The semantic regression pins the 0.931-1.138 ms tolerance range, 9.11 ms latency
bound, 6.52 ms single-pulse bound, first-of-four pending-`T0IF` behavior, distinct
PIC10F32x/PIC12F675 re-arm budgets, BOR limitation, and architecture census.
Verification passed:

- Generated release qualification/documentation: 46 checks.
- Makefile name contract: 48 checks.
- Independent focused review, Bash syntax, and `git diff --check`.

`asciidoctor` is not installed on this host, so rendered AsciiDoc validation was
not available.

### Completed Test/Help/Comment Parity Chunk Evidence

The remaining P12-5 pass now presents the current seven-part,
four-core-generation, three-PIC, 21-image, 18-soak, and 34-evidence topology in
the top-level, release, and test documentation and in user-facing Make help. It
adds PIC12F675 to the shared gpsim and return-stack descriptions while preserving
PIC10F32x-pair wording where the implementation or hardware gap is genuinely
pair-specific. The release instructions retain the six-target, 18-image
v0.9.6-v0.9.8 boundary and provide separate current reproduction commands.

The semantic regression pins the current reader-facing inventories and the
historical 18-image/15-soak/28-evidence boundary. Verification passed:

- Generated release qualification/documentation: 47 checks.
- Release preflight: 30 checks and 82 Makefile queries.
- Release provenance: 78 checks.
- Makefile name contract: 48 checks.
- Independent focused review, Bash syntax, stale-scope classification, and
  `git diff --check`.

The missing cross-toolchain qualification remains P12-8 rather than a P12-5
documentation blocker.

## P12-8 - Full Software Qualification

Run this only after the fixes above are committed, from the fully equipped host
with the repository's pinned toolchain. Use the actual selected XC8/DFP paths if
they differ from Makefile defaults.

- [x] `git diff --check main...HEAD`
- [x] `make clean`
- [x] `make test-long STRICT_TOOLS=1 MUTATION_ALLOW_SKIP=0`
- [x] `make pic12f675-test pic12f675-test-target-variants STRICT_TOOLS=1`
- [x] `make release-preflight VERSION=v0.9.9`
- [x] `make release VERSION=v0.9.9 RELEASE_ARGS='--dry-run'`
- [x] Confirm the PIC12F675 aggregates share one qualified immutable matrix when
      requested in one Make invocation.
- [x] Confirm all three PIC12F675 variants pass build, CONFIG, stack, analysis,
      source coverage, calibration, gpsim, fault, lock-step, target-I/O, mutation,
      and shortened dry-run soak gates with no skips.
- [x] Inspect generated `MANIFEST.md`, `QUALIFICATION`, evidence inventory,
      image table, flashing section, reproduction section, and `commit_msg.txt`.
- [x] Confirm the dry run stages exactly 21 canonical images, 18 soak logs, and
      34 retained evidence files.

A production 24-hour release run is not required merely to merge the support
branch, but the complete dry-run orchestration must pass. The production v0.9.9
run should be performed from the final release source after merge according to
the normal release process.

### Completed Full-Qualification Chunk Evidence

P12-8 ran to completion on this fully equipped host (avr-gcc 7.3.0, XC8 V3.10 at
the pinned `/opt/microchip/xc8/v3.10`, DFP 1.9.189, gpsim/libgpsim, yasimavr,
asciidoctor, cppcheck 2.13, cbmc; only `avrdude` is absent, which is v1.x
hardware-only). The Makefile `PIC_CC`/`PIC_DFP` defaults matched the installed
toolchain exactly, so no path overrides were needed. All commands ran from a
clean `fc59dbd` worktree.

- `git diff --check main...HEAD`: clean.
- `make clean`: clean tree.
- `make test-long STRICT_TOOLS=1 MUTATION_ALLOW_SKIP=0`: passed. Mutation
  summary 118 killed, 0 survived, 0 errored, 0 PIC skipped, 0 ATtiny202 skipped,
  with every toolchain probe ENABLED (the 20 PIC12F675 mutants ran). Verified
  core `src/bypass_pure.c` line coverage 100.00%, golden-model 99.39%. Embedded
  release contracts: image 90, preflight 30 (82 Makefile queries), provenance
  78, qualification 47, PIC12F675 build 89, target-variant matrix 13, target-lane
  18; strict optional-tool validation (host + all three PIC parts) 30.
- `make pic12f675-test pic12f675-test-target-variants STRICT_TOOLS=1`: passed.
  All three variants green -- fault-inject 37, lock-step 3005 (3000 iterations,
  27 toggles, 0 mismatches, 66/66 reachable model states), target-I/O 36. The
  two aggregates emitted one identical immutable `PIC12F675_MATRIX_SHA256` (a
  single unique payload across all emissions) in the one Make invocation, and its
  shipping hashes match the staged release images.
- `make release-preflight VERSION=v0.9.9`: passed ("this host can start a
  release").
- `make release VERSION=v0.9.9 RELEASE_ARGS='--dry-run'`: passed. Built 21 images
  (set matches canonical `RELEASE_IMAGES` exactly; all three PIC12F675 are
  structurally valid Intel HEX), ran `test-long` + ATtiny202 + both PIC10F32x +
  both PIC12F675 gates, and all 18 soak combos PASS (including the three
  PIC12F675 combos). Staged exactly 21 images, 18 soak result logs, and 34
  retained evidence files. Generated `QUALIFICATION` records
  `soak_combination_count=18` at `soak_duration_ms=60000`; `MANIFEST.md` and
  `commit_msg.txt` name all seven parts, both PIC12F675 gates, and 21 images; the
  flashing section requires the guarded preflight/result transaction, makes no
  trim-preservation claim, and keeps the hardware-unvalidated and
  wrong-timing/BOR warnings; the reproduction section builds PIC12F675.
- Reproduction confirmation: running the generated reproduction build commands
  from a clean tree produced 21 fresh images (9 AVR-classic + 3 AVR-XT + 3
  PIC10F322 + 3 PIC10F320 + 3 PIC12F675), and `scripts/verify-release-images.sh`
  reported "REPRODUCED: 21 committed, listed, and freshly built images match the
  canonical set exactly."

The dry-run staging area is the release script's own `mktemp` root, which is
distinct from the P12-6 programming workflow. A production 24-hour soak is a
post-merge release step, not a merge blocker; the complete dry-run orchestration
passed. Only P12-9 branch hygiene now remains before merge.

## P12-9 - Final Branch Preparation

- [ ] Re-review `main...pic12f675-support`, including shared PIC harness changes,
      rather than reviewing only the final promotion commit.
- [ ] Confirm branch and `origin/pic12f675-support` are synchronized.
- [ ] Confirm `main` has not gained changes requiring reconciliation.
- [ ] Confirm the worktree is clean and no validation artifacts are tracked.
- [ ] Confirm `CHANGELOG.md` leaves the work under `[Unreleased]` until the actual
      v0.9.9 release is cut.
- [ ] Remove this branch-only `pic12f675-fixes.md` file.
- [ ] Perform one final `git diff --check main...HEAD`.
- [ ] Merge only after all prior items are complete or explicitly reclassified
      with a documented rationale.

## Valid v1.x Deferrals

The following do not block v0.9.9 software release support:

- Real-programmer proof that OSCCAL and `BG<1:0>` survive programming.
- Actual `ipecmd` operation against PIC12F675 hardware.
- Loaded-board GP2 Schmitt-trigger readback margin.
- Real-silicon tick, watchdog, BOR/POR, output timing, and general board behavior.
- Comprehensive HIL validation shared with the other supported targets.

These remain tracked by `TODO.md` under `T3-pic12f675-bench` and the project-wide
hardware-validation items. Until they pass, release text must say that the part
is software-validated and has not run on silicon.

## Meta-Review Evidence

The meta-review used `origin/pic12f675-support` at `a87416e`. On the limited
review host, the following self-contained contracts passed from an isolated
branch export:

- PIC12F675 fake-XC8/build/programming contract: 88 checks.
- Release image contract: 90 checks.
- Release qualification contract: 30 checks.
- PIC12F675 target matrix: 13 checks.
- PIC12F675 lane/result contract: 18 checks.
- PIC target result producer and simulator-progress regressions.
- Mutation sandbox, supply-chain, strict-tool, Make name-contract, MISRA-output,
  pinout, workload-rebuild, and PIC soak-rebuild contracts.
- `git diff --check main...origin/pic12f675-support`.

The host lacked the complete AVR/PIC toolchain and simulator/analyzer stack, so
this evidence does not replace P12-8. In particular, the final XC8 images,
gpsim/libgpsim lanes, strict full suite, and release dry run must be rerun on the
equipped validation system.
