# PIC12F675 Branch Merge Readiness

**Status:** Open, branch-only working document

**Reviewed branch:** `pic12f675-support`

**Reviewed tip:** `a87416e` (`feat: release-support the PIC12F675`)

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
its generated release documentation, programming claims, and several current
documents do not agree with the implemented 21-image/18-soak release contract.

## Priority Summary

| ID | Priority | Item | Status |
|---|---:|---|---|
| P12-1 | Blocker | Make generated reproduction instructions build PIC12F675 | Open |
| P12-2 | Blocker | Correct PIC12F675 flashing instructions and trim claims | Open |
| P12-3 | High | Complete generated release metadata and commit message | Open |
| P12-4 | High | Reconcile the feasibility document's support status | Open |
| P12-5 | High | Correct stale design, safety, test, and help documentation | Open |
| P12-6 | High | Remove hard-coded `/tmp` use from the programming workflow | Open |
| P12-7 | High | Add regressions for the review gaps | Open |
| P12-8 | Gate | Run the complete software qualification on the equipped host | Open |
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

- [ ] Add the PIC12F675 three-image build to the generated reproduction block.
- [ ] Ensure the command uses the selected/pinned `PIC_CC` and `PIC_DFP` contract
      consistently with the rest of the generated procedure.
- [ ] Keep the generated build list and `RELEASE_IMAGE_DIRS` in exact agreement.
- [ ] Confirm the instructions succeed from a clean checkout with no prior
      PIC12F675 artifacts.

### Acceptance

- [ ] A generated v0.9.9 dry-run `MANIFEST.md` includes the PIC12F675 build.
- [ ] Following the generated commands from a clean tree produces all 21 images.
- [ ] `scripts/verify-release-images.sh` passes over the generated build paths.

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

- [ ] Replace the abbreviated generated command with either the complete
      preflight/program sequence or an unambiguous pointer to the complete
      mandatory procedure.
- [ ] State that the guarded workflow checks, verifies, and records OSCCAL/BG
      before and after programming.
- [ ] Do not claim that an unqualified programmer command preserves trim.
- [ ] State explicitly that actual programmer preservation remains unvalidated
      until the v1.x hardware pass.
- [ ] Keep the warning that trim loss can leave a device apparently functional
      but with wrong timing or BOR/POR thresholds.
- [ ] Reconcile `README.md`, `release/README.md`, `TOOLCHAIN.adoc`, generated
      `MANIFEST.md`, Make help, and source/Makefile comments to one precise claim.

### Acceptance

- [ ] Every published PIC12F675 flashing example includes or requires preflight
      evidence and a new result directory.
- [ ] No current release-facing text says the unvalidated command "preserves"
      OSCCAL/BG.
- [ ] The software-vs-hardware boundary is stated consistently everywhere.
- [ ] The fake programmer tests still cover baseline mismatch, post-write trim
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

### Required Work

- [ ] Add PIC12F675 to generated release scope.
- [ ] Add `pic12f675-test` and `pic12f675-test-target-variants` to the generated
      validation statement.
- [ ] Change old two-PIC wording to accurately describe all three PIC targets.
- [ ] Attribute shared `PIC_CC`/`PIC_DFP` provenance to both PIC10F322 and
      PIC12F675 without pretending they are independently selected tools.
- [ ] Add PIC12F675 to generated release commit-message scope and validation.

### Acceptance

- [ ] A v0.9.9 dry-run manifest names all seven MCU parts, all required target
      gates, 21 images, 18 soak combinations, and the correct selected tools.
- [ ] The generated release commit message reports the same scope.
- [ ] Human-readable metadata agrees with `QUALIFICATION` and retained evidence.

## P12-4 - Feasibility Document Status

### Problem

`docs/pic12f675_feasibility.md:3-21` says PIC12F675 is staged, absent from release
integration, and not release-supported. The same document correctly says at
lines 1101-1113 and 1372-1389 that it is release-supported from v0.9.9 and fully
integrated.

### Required Work

- [ ] Replace the opening status with the current v0.9.9 disposition.
- [ ] Preserve the preimplementation history, but label historical/prospective
      statements so they cannot be mistaken for current status.
- [ ] Keep items 1, 2, 8, and 9 classified as v1.x hardware work.

### Acceptance

- [ ] A reader can determine current support status from the opening section.
- [ ] No current-tense section says the target is excluded from `all`, CI, or
      release integration.

## P12-5 - Current Documentation Parity

### Problem

Several current documents still encode the old six-part, two-PIC, 15-soak, or
28-evidence topology. Some are cosmetic, but the timing and BOR text is
safety-relevant.

### Required Work

- [ ] Correct `DESIGN_DOCUMENTATION.adoc:137-140` so PIC12F675's 1.024 ms tick is
      not described as nominally 1.000 ms.
- [ ] Correct `DESIGN_DOCUMENTATION.adoc:158-168` and later references from two
      polled PIC implementations to three, with PIC12F675 timing kept distinct.
- [ ] Add PIC12F675 to the primary BOR table at
      `DESIGN_DOCUMENTATION.adoc:225-246`, including its approximately 2.1 V
      threshold and inability to enforce a >4 V peripheral-safe floor.
- [ ] Reconcile the six-target/three-generation introduction near
      `DESIGN_DOCUMENTATION.adoc:1094-1104` with the seventh target and fourth
      core generation.
- [ ] Correct `test/README.md:455` so the PIC12F675 return-stack gate is included.
- [ ] Correct `test/README.md:461` from 28 evidence files/15 soaks to the current
      34/18 contract.
- [ ] Scope the PIC hardware-gap section at `test/README.md:786-824` to the
      PIC10F32x pair, then add or point to the distinct PIC12F675 hardware gaps.
- [ ] Update `test/pic/gpsim_bootstrap.h:4-6` from two PIC parts to all three.
- [ ] Update stale release comments/help at `Makefile:6959-6961`,
      `Makefile:7004`, and `Makefile:7356-7358`.
- [ ] Add PIC12F675 to the top-level README's built-image validation summary.
- [ ] Correct `release/README.md:49`, which calls the six v0.9.6-v0.9.8 targets
      the "first four parts".

### Acceptance

- [ ] Current documents consistently state seven parts, three PIC targets, 21
      images, 18 soak combinations, and 34 retained evidence files where counts
      are relevant.
- [ ] Timing text distinguishes the 1.024 ms PIC12F675 tick from 1.000 ms targets.
- [ ] Primary safety guidance includes the PIC12F675 BOR limitation.

## P12-6 - Private Temporary Data

### Problem

The new programming workflow hard-codes shared, disk-backed `/tmp` for full
device readback and programming snapshots at `Makefile:6573`, `Makefile:6727`,
and `Makefile:6731`. This ignores caller-selected temporary storage and violates
the development environment's rule that no files may be created under `/tmp`.

### Required Work

- [ ] Move baseline, program snapshot, and transient bench data to an explicitly
      controlled private location.
- [ ] Honor a caller-selected safe temporary root where practical.
- [ ] Do not fall back to `/tmp` in this environment.
- [ ] Preserve mode-0700 directories, exclusive result creation, traps, digest
      checks, and interruption evidence.
- [ ] Ensure diagnostics do not print sensitive full-device contents.

### Acceptance

- [ ] `pic12f675-preflight` and `pic12f675-program` create no `/tmp` content.
- [ ] Success, failure, and signal-interruption paths remove transient data while
      retaining only the explicitly requested evidence/result paths.
- [ ] Existing programming transaction tests pass with a temporary root that
      contains spaces.

## P12-7 - Regression Coverage for Meta-Review Gaps

### Required Work

- [ ] Extend release tests to prove the generated reproduction block builds every
      directory represented by `RELEASE_IMAGE_DIRS`.
- [ ] Assert generated manifest scope includes PIC12F675.
- [ ] Assert generated validation prose names both PIC12F675 aggregates.
- [ ] Assert generated compiler/DFP attribution includes PIC12F675.
- [ ] Assert generated `commit_msg.txt` includes PIC12F675 scope and validation.
- [ ] Assert generated flashing guidance does not claim unvalidated trim
      preservation and cannot omit required preflight/result inputs.
- [ ] Add a temporary-root regression proving the PIC12F675 bench workflow does
      not hard-code `/tmp`.
- [ ] Add narrow semantic documentation checks only where the safety/release
      contract justifies maintaining them; avoid pinning incidental prose.

### Acceptance

- [ ] Each newly added test fails against `a87416e` for its intended reason.
- [ ] Each test passes only after the corresponding production/documentation fix.
- [ ] The tests exercise generated output, not merely source-string presence,
      wherever practical.

## P12-8 - Full Software Qualification

Run this only after the fixes above are committed, from the fully equipped host
with the repository's pinned toolchain. Use the actual selected XC8/DFP paths if
they differ from Makefile defaults.

- [ ] `git diff --check main...HEAD`
- [ ] `make clean`
- [ ] `make test-long STRICT_TOOLS=1 MUTATION_ALLOW_SKIP=0`
- [ ] `make pic12f675-test pic12f675-test-target-variants STRICT_TOOLS=1`
- [ ] `make release-preflight VERSION=v0.9.9`
- [ ] `make release VERSION=v0.9.9 RELEASE_ARGS='--dry-run'`
- [ ] Confirm the PIC12F675 aggregates share one qualified immutable matrix when
      requested in one Make invocation.
- [ ] Confirm all three PIC12F675 variants pass build, CONFIG, stack, analysis,
      source coverage, calibration, gpsim, fault, lock-step, target-I/O, mutation,
      and shortened dry-run soak gates with no skips.
- [ ] Inspect generated `MANIFEST.md`, `QUALIFICATION`, evidence inventory,
      image table, flashing section, reproduction section, and `commit_msg.txt`.
- [ ] Confirm the dry run stages exactly 21 canonical images, 18 soak logs, and
      34 retained evidence files.

A production 24-hour release run is not required merely to merge the support
branch, but the complete dry-run orchestration must pass. The production v0.9.9
run should be performed from the final release source after merge according to
the normal release process.

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
