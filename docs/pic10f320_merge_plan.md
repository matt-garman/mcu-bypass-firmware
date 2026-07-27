# PIC10F320 merge plan

Fold the standalone `pic10f320-bypass-firmware` child repository into
this parent as a first-class-but-explicitly-constrained build target,
eliminating the duplicated validation ecosystem and the hand-vendored
copy of the verified pure core.

This is a working plan, not a spec. It is written to be executed in
phases, each of which leaves the tree green. Firmware source edits are
the user's to make; the phases below call out which steps touch
firmware vs. test/Makefile/docs.

**Decision.** Consolidation is the right direction. The repositories have
the same maintainer, product domain, toolchain family, behaviour contract,
and output stages; the child intentionally derives from the parent and
manually vendors its core. Keeping them separate now creates more drift risk
than useful isolation. The architecture below is approved in principle, but
the pre-merge correctness and release checkpoints are blockers: this plan is
not permission to activate the merged lane and repair known false-pass paths
later.

**Plan currency.** Reviewed and refreshed **2026-07-25** against parent
`21012ae` (v0.9.5, 2026-07-18) and child `f58d2d5` (`v0.9.5-13-gf58d2d5`,
2026-07-15). The original draft (2026-07-13 .. 2026-07-15) predated both tips.
Several of its blockers have since been resolved on one side or the other
(§6.3, §6.4, §6.5, §6.8, §6.10), one new blocker appeared (§6.11, firmware
defensive-layer divergence), and one integration surface was missing entirely
(§6.12, parent-only gate infrastructure). Claims below carry the tip they were
verified against; re-verify before executing if either repository has moved
again.

Re-audited **2026-07-26** against parent `4e481f0` and child `f58d2d5`. The
child has not moved; the parent advanced only by two documentation commits
(`c508e51`, `4e481f0`), so no 2026-07-25 claim expired. That audit did correct
six assertions that inspection contradicted (the §4 ignore-file row, §5.1's
`program-pic320`, §6.2's host-shim hazard, and all three of §6.12's
flash-budget / release-provenance / strict-tools rows), and added four things
that were missing entirely: the image byte-identity gate (§6.13), verified
toolchain-pin equality (§6.14), the child's already-existing manual-sync
contract (§4, §14.3), and the child's non-git GitHub assets (§6.15). It also
records a minimum-coherent-merge cut (§7) as the concrete mitigation for
§14.11.

A **second 2026-07-26 pass**, against parent `ed6ddab` and the same child tip,
found that the plan was strong on process but thin on the mechanical merge
surface. It added two collision classes that were missing entirely — the
Makefile *variable* namespace (§5.6, 56 colliding names) and shared artifact
directories (§5.7, `coverage/`) — a permanence decision for the byte-identity
baseline (§6.13), the release-image naming asymmetry (§5.3, §10), the moved
firmware's own comment sweep (§4), and two stale parent-side references (§4).
It also identified the *bias* that produced three of those misses and wrote it
up as Principle 8: the plan's default disposition demotes child assets that are
chip-agnostic into PIC10F320-only sections.

A **third 2026-07-26 pass**, against parent `5180881` and the same child tip,
re-verified the plan's factual claims against both trees and found them sound
with one exception: §4's `LICENSE` row asserted a non-SPDX header on the moved
firmware and scheduled a normalization edit for a file that is already SPDX —
withdrawn there. It added one missing collision class, §5.8 (global Make
directives; the child's bare `.NOTPARALLEL` would fail the parent's
`test-make-safe-parallel-probe` outright), noted that §5.7's destructive-recipe
review runs in the parent's direction too, and closed Phase 0 by recording §15:
the decisions, the green baselines and image hashes, and the tool inventory.

---

## 1. Goal and non-goals

**Goal.** One repository that builds and validates all targets — AVR
Classic (tiny13a / tinyx5), AVR-XT (ATtiny202), PIC10F322, and
PIC10F320 — sharing a single copy of every asset that is genuinely
common, while preserving the parent's "textbook-grade reference"
identity and honestly marking PIC10F320 as the budget-constrained
exception.

PIC10F320 has exactly three current build/release variants:
`cd4053-simple`, `cd4053-mute`, and `tq2-relay`. The historical
`tmux4053-*` images were removed because the corresponding `cd4053-*`
images now serve both CD4053 and TMUX4053 boards; they must not reappear in
future release expectations.

**Non-goals.**
- *Not* re-architecting the PIC10F320 firmware. It stays single-file,
  logic-inlined-into-`main()`. Its unusual shape is the whole reason it
  exists; the merge preserves it verbatim.
- *Not* deduplicating the genuinely-forked harnesses (lockstep,
  mutation, fault, host-logic-for-inline). Those differ *because* they
  test different firmware. The merge co-locates them; it does not
  collapse them.
- *Not* retroactively unifying the two projects' past `release/vX`
  histories (both currently number v0.9.x independently). Unification
  starts at the next tag.
- *Not* changing the parent's fast default `all` goal to build every MCU.
  PIC10F320 remains an explicit `make pic320` target; a separately named
  full-matrix aggregate may be added if useful.
- *Not* claiming that PIC10F320 eliminates the inlining trust seam. Its
  assurance strategy mitigates that seam with equivalence, lockstep,
  actuation, and fault tests; it is not structurally identical to compiling
  the verified core into the shipping image.

---

## 2. Guiding principles

1. **Every phase has a meaningful green boundary.** The parent's existing
   `make test` must pass before and after each phase, but that alone is not
   evidence for dark PIC10F320 files. Once relocated, each applicable
   PIC10F320 host or full-tool lane must also pass before its source child
   counterpart is deleted or the lane is made authoritative.
2. **Single source of truth for shared assets.** After the merge there
   is exactly one `bypass_pure.c`, one set of formal proofs, one
   `misra_rules.txt`. The PIC10F320 equivalence/lockstep tests consume
   `src/bypass_pure.c` **directly** — no vendored copy. Folding still
   preserves distinct assurance roles: an independent oracle and a test of
   the real pure-core implementation are not duplicates merely because they
   assert similar properties.
3. **Special-case status is structural and loud, stated once.** One
   authoritative section owns the "PIC10F320 is constrained and
   recovers assurance differently" story; everything else links to it
   rather than re-explaining (or worse, implying parity).
4. **Fail-closed everywhere the parent already is.** Release-image
   verification, coverage gates, and mutation testing must *include*
   PIC10F320 explicitly; a missing PIC10F320 artifact is a failure, not
   a silent skip.
5. **Keep host and real-tool aggregate semantics honest.** The parent's
   default `test` aggregate intentionally does not require XC8, gpsim, or
   libgpsim. PIC10F320 host-only checks may join it; real-tool checks belong
   in a strict PIC10F320 lane and, if desired, a new `test-all-targets`
   aggregate. Do not make only PIC10F320 change the meaning of `make test`.
6. **One release-product source of truth.** Makefile variables define the
   complete expected release image set. Release creation, checksum
   generation, local reproduction, and tag CI all consume and independently
   enforce that set; equality among three accidentally incomplete sets is not
   sufficient.
7. **Known false-pass defects are blockers.** A green child baseline is
   useful, but not conclusive where a harness can discard tool status, skip
   all variants, execute zero soak iterations, or accept incomplete simulator
   progress. Those paths are hardened before the merged lane becomes a gate.
8. **Ask of every child-only asset: 320-*specific*, or merely 320-*discovered*?**
   *(Added by the second 2026-07-26 pass.)* This plan's default disposition is
   "parent wins; surviving child content becomes a PIC10F320 section." That default
   is right for genuinely chip-specific material and wrong for work the child
   happened to do first. The first pass caught one instance
   (`verify_corrupt_state_faults()`, §4) and missed two: the child's only-in-the-
   project line-coverage gate over the real pure core (§4, `test_logic_host.c`
   row) and its explicitly cross-chip gpsim "Known gaps" documentation (§4,
   `test/README.md` row). Both would have been quietly demoted to `pic320-`
   lanes or 320 sections, *reducing* parent assurance through a merge whose
   entire premise is that it increases shared coverage. Phase 0 and Phase 3 must
   ask this question per asset and record the answer, not assume the default.

---

## 3. Target end-state layout

```
src/
  bypass_pure.{c,h}              # THE verified core — sole copy
  bypass_types.h
  bypass_config.h
  ...                            # existing shared headers
  bypass_mcu_avr_classic.c
  bypass_mcu_avr_xt.c
  bypass_mcu_pic10f322.c
  bypass_mcu_pic10f320.c         # NEW: moved from child repo root, verbatim
                                 #   (single self-contained file; no companion
                                 #    pins/output .c — inlined by design)

test/
  host/         formal/          # SHARED, single copy — test the one pure core
  misra*.{json,txt}              # rules shared; suppressions unified w/ per-file scope
  run_mutation_tests.sh          # parent's; child variant folded in per-target
  avr/                           # unchanged
  pic/                           # PIC10F322 gpsim harnesses (unchanged location)
  pic10f320/                     # NEW: PIC10F320-only layers
    equiv/        # firmware<->core equivalence (was child test/equiv)
    actuation/    # settled control-pin sequence (was child test/actuation)
    fault/        # firmware defensive-layer fault injection (was child test/fault)
    gpsim/        # only genuinely chip-specific .stc / target harnesses

build_pic10f320/                 # NEW: all PIC10F320 XC8/test artifacts

release/
  README.md                      # shared release trust/reproduction contract

docs/
  pic10f320_feasibility.md       # existing
  pic10f320_merge_plan.md        # this file
  pic10f320_special_case.md      # NEW: the single authoritative caveat (see §8)
  pic10f320_validation.md        # NEW or equivalent test/README section: technical layers
```

There is no current child `test/fw_coverage/` directory. Firmware coverage is
implemented by the fault harness and `check_fw_coverage.sh`; keep those
together unless a deliberate restructuring is separately justified.

Note: `test/pic10f320/` deliberately sits beside `test/pic/` rather than
reshuffling the existing, already-validated 10F322 tree. A cleaner
"`test/pic/{pic10f322,pic10f320}/`" split is possible but churns known-
good files for aesthetics; deferred unless the two PIC chips start
sharing more harness code than they do today.

`build_pic10f320/` is deliberately separate from `build_pic/`. XC8 writes
generic intermediates into its working directory, and the child also reuses
common test output names. Sharing the directory risks cross-chip, cross-
variant, and concurrent-invocation contamination.

`build_pic10f320/` is **not the only** artifact directory the merge has to
separate, and the layout above understated the problem *(corrected by the second
2026-07-26 pass)*: coverage output also collides, and the imported clean recipes
are destructive. See §5.7 — either a sibling `coverage_pic10f320/` or a
`build_pic10f320/coverage/` subtree, decided in Phase 0 along with the rest of
the naming.

---

## 4. File-by-file disposition

Legend: **FOLD** = collapse to one shared copy (parent's wins) · **DROP**
= delete, superseded · **RELOCATE** = move, content essentially intact ·
**FORK** = keep as a distinct PIC10F320-specific file.

| Child file | Disposition | Destination / note |
| --- | --- | --- |
| `bypass_mcu_pic10f320.c` | RELOCATE | `src/bypass_mcu_pic10f320.c`, verbatim. Firmware — **user moves**. Carries its own comment sweep, enumerated below the table *(found by the second 2026-07-26 pass)*. |
| `test/model/bypass_pure.{c,h}`, `bypass_types.h` | DROP after verification | Behaviour-identical to the parent at the audited child tip; current differences are license headers. Superseded by `src/`, but record the comparison before deletion. |
| `test/model/bypass_config.h` | DROP/REPLACE | Not a clone: it is an intentional minimal host threshold shim. Replace its consumers with `src/bypass_config.h` plus the parent's host configuration shim, and verify identical effective thresholds. |
| `test/model/README.md` | MERGE | Put assurance-seam/provenance content in `docs/pic10f320_special_case.md`; put technical model/test instructions in the validation documentation. |
| `test/host/test_logic_host.c` | FOLD w/ care — **and promote a gate** | The parent test is an independent implementation oracle; the child drives the real pure functions. Preserve both assurance roles, either through two backends/property runners or an explicit, reviewed argument that existing shared-core tests make the direct run redundant. Do not discard the difference as noise. **Second 2026-07-26 pass — the row was materially incomplete:** the child's copy is also the *driver* for the only line-coverage gate over the real core that either repository has. Parent `COVERAGE_SRC = test/host/test_logic_host.c` (`Makefile:2655`) and that file states at `:4` that it does **not** include the firmware — it re-implements the model — so the parent's 90% floor measures the **oracle**, and no parent target measures `src/bypass_pure.c` at all. The child's `coverage-check` measures `bypass_pure.c` itself (host + formal drivers, floor **95%**, `Makefile:193`, `:592-613`). Folding the child copy away therefore deletes a gate rather than deduplicating one. Promote it as a shared `coverage-check-core` over `src/bypass_pure.c` with its own floor variable — which is also how the `COVERAGE_MIN` collision of §5.6 resolves, since two subjects need two floors. This is Principle 8's first case. |
| `test/formal/test_cbmc.c`, `test_symbolic.c` | FOLD w/ care | Diff-audit assertions and preserve the child's correct two-object KLEE flow: compile driver and `src/bypass_pure.c` to bitcode, `llvm-link`, then run KLEE. Fix the parent's current KLEE wiring before calling the child copy redundant. |
| `test/formal/test_model_check.c` | FOLD w/ care | Migrate the child's concrete `verify_corrupt_state_faults()` property before deletion. It is target-agnostic and is also used as a mutation/coverage oracle. Audit the remaining drift. |
| `test/misra_rules.txt` | DROP | 0 diff — identical to parent's. |
| `test/misra_suppressions.txt` | DROP/REGENERATE | The audited child file contains comments only and claims zero deviations; there are no current entries to merge. Fresh merged-tree analysis decides whether any new PIC10F320 suppressions are needed. Any such entries must be documented and file-scoped. |
| `test/misra.json` | FOLD | Identical at the audited tips; keep one copy. |
| `test/equiv/` (`test_equiv.c`, `fw_harness.c`, `xc.h`) | RELOCATE/ADAPT | Move to `test/pic10f320/equiv/`. Repoint both declarations and implementation/link dependencies to `src/bypass_pure.{c,h}`, `src/bypass_types.h`, `src/bypass_config.h`, and `test/bypass_config_host.h`; update the harness's relative firmware include to `src/bypass_mcu_pic10f320.c`. |
| `test/actuation/test_actuation.c` | RELOCATE/ADAPT | Move to `test/pic10f320/actuation/`. Preserve its dependency on the equivalence firmware harness and give each variant private outputs so concurrent invocations cannot collide. |
| `test/fault/` (`test_fault.c`, `fw_fault_harness.{c,h}`, `check_fw_coverage.sh`) | RELOCATE/ADAPT | Move to `test/pic10f320/fault/`. Update the relative firmware include and explicit dependency on the equivalence `xc.h`. Keep firmware coverage here unless a separate restructuring is justified. Distinguish this host fault layer from libgpsim target fault injection in target names. |
| `test/pic/test_config_pic.c` | FOLD/PARAMETERIZE | PIC10F320 and PIC10F322 share CONFIG address/layout and expected word `0x389E`. Use one checker with device-accurate labels and run it against every built HEX for both chips. |
| `test/pic/test_soak_pic.cc` | FOLD/PARAMETERIZE | Prefer the parent's stronger parameterized soak driver and shared timing contract. Add PIC10F320-specific processor, firmware path, cycle timing, and per-variant actuation duration. |
| `test/pic/power_on_pressed.stc` | FOLD/PARAMETERIZE | Executable stimulus is equivalent; share it if device naming can remain clear. Keep `footswitch_toggle.stc` chip-specific because instruction cadence/checkpoint timing differs. |
| `test/pic/test_{fault,io,lockstep}_pic.cc`, chip-specific `*.stc` | RELOCATE/HARDEN | Move genuinely different files to `test/pic10f320/gpsim/`. Port the parent's deterministic lockstep phase, simulator-progress propagation, expected fault-check count, and related fail-closed fixes before activation. |
| `test/pic/run_gpsim*.sh` | FOLD/PARAMETERIZE | Reuse or adapt the parent's hardened wrappers so timeout/nonzero status is never discarded. Extend fake-gpsim regressions for PIC10F320 paths. |
| `test/model_step.h` | FOLD | The parent copy is the shared bridge and already targets the real core. Update all PIC10F320 compile/link/include dependencies to use it. |
| `test/soak_timing_config.h` | FOLD | Parent is ahead: it carries `SOAK_LIVENESS_DUE()` and the "liveness deadline must fire at equality" static assert that the child lacks. Keep the parent copy; repoint PIC10F320 soak consumers to it. |
| `test/test_pic_build.sh` | FOLD/PARAMETERIZE **or** FORK — decide | 271 diff lines (parent 219 L, child 144 L). Shared-name/shared-target hazard — see the note below the table. |
| `test/test_make_serialization.sh` | FOLD | 227 diff lines (parent 202 L, child 84 L). Reconcile into the single merged lock covering both chips' XC8 invocations (§6.4). |
| `test/test_gpsim_wrappers.sh` | FOLD/PARAMETERIZE | 119 diff lines. Must cover fake-gpsim regressions for both chips' wrappers. |
| `test/test_release_images.sh` | FOLD | 103 diff lines. Consumes the canonical Makefile-owned product set (§10, Principle 6). |
| `test/test_soak_timing.sh` | FOLD | 64 diff lines. Pairs with `soak_timing_config.h` above. |
| `test/test_target_matrix.sh` | FOLD/PARAMETERIZE | 61 diff lines. Must enforce the exactly-three PIC10F320 matrix (§6.5). |
| `test/test_lockstep_progress.sh` | DROP | **0 diff — byte-identical to the parent** at the pinned tips. |
| `scripts/validate-ihex.sh` | DROP | **0 diff — byte-identical to the parent** at the pinned tips. |
| `scripts/verify-release-images.sh` | FOLD/EXTEND | 17 diff lines. The parent's is glob-based (`images=("$dir"/*.hex)`), which is exactly the three-identically-incomplete-sets failure of §14.8. Replace with the canonical expected set per §10. |
| `test/run_mutation_tests.sh` | MERGE with explicit topology | Add PIC10F320 firmware mutants to the parent driver or use a clearly integrated sibling driver. Retarget only nonduplicate model mutants to `src/bypass_pure.c`; recursively copy the nested PIC10F320 tree into sandboxes; use private outputs; add target-I/O/fault/lockstep and WDT-soak mutants; baseline every distinct kill target. |
| `Makefile` | MERGE | Import PIC10F320 targets under a `pic320-` prefix (§5). Child Makefile then deleted. |
| `scripts/ci-local.sh` | FOLD | Assert both PIC headers and run the host/full-tool PIC10F320 lanes. Define whether `--skip-pic` skips both chips; avoid a later `STRICT_TOOLS=1` failure through an aggregate it was meant to skip. |
| `scripts/make-release.sh` | FOLD/EXTEND | Add PIC10F320 variables, DFP/header checks, build, validation, mutation, three soaks, evidence, image metadata, programmer commands, reproduction commands, verifier inputs, constrained-target wording, and generated commit text. Do not merely append filenames. |
| `.github/workflows/ci.yml` | FOLD/EXTEND | Add a strict full-tool PIC10F320 job or a two-chip matrix, assert `proc/pic10f320.h`, preserve every unique test layer, upload `build_pic10f320/*.hex` separately, and update downstream `needs`. Run PIC mutation fail-closed in a full-tool hosted job. |
| `.github/workflows/release.yml` | FOLD/EXTEND | Rebuild PIC10F320 into a private directory, enforce the canonical set, rerun strict target/mutation gates, and pass the extra directory to reproduction verification before publication. |
| `TOOLCHAIN.adoc`, `MISRA_COMPLIANCE.md` | MERGE | Add the PIC10F320 device/header, `p10f320`, 256-word gate, CONFIG word, build directory, commands, analyzer configuration, and zero-unwaived-finding policy. Keep detailed technical facts here, linked to the caveat. Three specifics for `MISRA_COMPLIANCE.md` *(added by the second 2026-07-26 pass)*: (a) its "Status: zero deviations" section argues by comparison — "cleaner than the parent project (`mcu-bypass-firmware`), whose AVR shells require documented deviations" — which becomes self-referential the moment it lands *in* that project; rewrite it as a per-target statement, exactly like the `## Provenance` case below. (b) The claim is only meaningful under strict tools: the child's `analyze-misra` exits 0 when cppcheck/python3 or the XC8/DFP headers are absent (`Makefile:348`, `:351`), which is precisely the §6.12 strict-tools hole — re-establish it in the merged tree with `STRICT_TOOLS=1` before repeating it. (c) Its `## Notes on specific constructs` records (`UINT8_MAX` is signed so `DEBOUNCE_COUNTER_MAX` is a plain literal; XC8 places `const` locals in program ROM) are **cited from the firmware** at `bypass_mcu_pic10f320.c:107`, so they must survive the merge with working anchors or the moved source acquires a dangling reference. |
| `AGENTS.md`, `CLAUDE.md`, `LICENSE` | FOLD | Parent copies remain authoritative — but `LICENSE` is *not* identical: parent reads `Copyright (c) 2026 matt-garman`, child reads `Copyright (c) 2026 Matthew Garman`. Folding silently reverts the attribution string; confirm the intended holder rather than defaulting. Useful tiebreaker *(third 2026-07-26 pass)*: every source file on **both** sides already carries `// Copyright (c) Matthew Garman`, so it is the parent's `LICENSE` file that disagrees with its own sources, not the child's. **Correction — the second half of this row was false and is withdrawn.** It claimed the verbatim-moved firmware "carries the child's non-SPDX three-line header into `src/`" and scheduled a normalization edit. `bypass_mcu_pic10f320.c:1-2` is already `// SPDX-License-Identifier: MIT` / `// Copyright (c) Matthew Garman`, byte-identical in form to `src/bypass_pure.c:1-2`, `src/bypass_mcu_pic10f322.c:1-2` and `src/bypass_config.h:1-2`. The three-line "All rights reserved" form exists only in `test/model/{bypass_pure.c,bypass_pure.h,bypass_types.h}` — the DROP rows above — so it dies with the vendored copy. There is no header to normalize and no firmware edit to budget for. |
| `.gitignore` | MERGE | Ignore the dedicated build directory and all generated nested test/coverage artifacts, extending the parent's `test/.gitignore` to cover the new nested PIC10F320 test tree. Do not import ignored local child artifacts such as `coverage/`, root `.gcda`/`.gcno`, backup files, or the current `build_pic/`. Corrected 2026-07-26: the child has **no** `test/.gitignore`; that file is parent-only, so this row has one contributing child file, not two. |
| `README.md`, `CHANGELOG.md` | MERGE | Add the constrained target and reconstruct child v0.9.4/v0.9.5 history under the correct historical releases rather than putting it under the first unified release. Two child README sections need *opposite* treatment and are easy to lose inside a bare "MERGE" (found 2026-07-26): `## Manual-sync contract` (`:137-156`) is **promoted, not folded away** — it is the §14.3 cross-target checklist, already written and maintained; `## Provenance` (`:110-136`) is **rewritten, not merged** — every claim in it ("frozen one-off", "pinned to `bf6a6c1`", "not automatically kept in sync", "correctness inherited by derivation, not independently re-proven in this repository") becomes false the moment the vendored copy dies in Phase 3. |
| `test/README.md` | MERGE — **but do not scope the gaps to the 320** | Preserve the child file's technical validation semantics, mutation rationale, and commands in a dedicated PIC10F320 section/document. The caveat document is not a substitute for test documentation. **Corrected by the second 2026-07-26 pass:** the earlier instruction to file the "known simulator gaps" in that 320 section is wrong. The child's section is titled `## Known gaps (hardware-bench only — shared with the parent's PIC build)` (`:313`) and says so in its body: gpsim's TMR2 prescaler-*select* clamp (`T2CKPS=0b11` modelled as 1:16 instead of the datasheet's 1:64), the absent WDT-calibration and analog-BOR models, and bench-only real-silicon pulse timing are properties of the **gpsim environment both PIC chips share**. The parent never back-ported any of it, so the merge is the moment it becomes shared PIC test documentation covering 322 and 320 alike. Principle 8's second case. |
| `release/README.md` | MERGE | Preserve PIC10F320 flashing, trust, and reproduction details in the parent's shared release documentation. |
| `release/v0.9.*` | DELETE FROM MERGED TIP / PRESERVE IN HISTORY | Do **not** place colliding historical release directories in the merged current tree. Preserve them through the imported graph and namespaced original tag objects. Include the child top-level `release/README.md` in the merge above. |

**Shared-name harness regressions — decide FOLD vs FORK deliberately.** Seven
of the rows above (`test_pic_build.sh`, `test_make_serialization.sh`,
`test_gpsim_wrappers.sh`, `test_release_images.sh`, `test_soak_timing.sh`,
`test_target_matrix.sh`, `test_lockstep_progress.sh`) collide by filename *and*
by Make target, and every one of their parent targets is **already a member of
the default `test` aggregate** (`test-pic-build`, `test-build-serialization`,
`test-gpsim-wrappers`, `test-release-images`, `test-soak-timing`,
`test-target-matrix`, `test-lockstep-progress`). Two consequences the phase
plan must respect:

- Folding a chip-parameterized version into the existing target silently
  changes what `make test` means. That is acceptable only where the folded
  check stays tool-independent (Principle 5); otherwise fork to a `pic320-`
  target and add it to the strict lane instead.
- **Sequencing hazard.** `test-release-images` folding plus the §10 canonical
  product set makes `make test` *fail* until the three PIC10F320 images exist
  and the canonical set names them. Land the canonical set, the build rules,
  and the verifier change in one Phase-6 step — not as separate "green"
  commits — or gate the new requirement behind a variable until the images
  land.

**Parent-side files that gain PIC10F320 awareness (no child counterpart):**
- `scripts/verify-release-images.sh` + `test/test_release_images.sh` — make
  the verifier consume a canonical Makefile-owned product set and require
  exactly these three PIC10F320 names in future unified releases:
  `bypass_mcu_cd4053-simple_pic10f320.hex`,
  `bypass_mcu_cd4053-mute_pic10f320.hex`, and
  `bypass_mcu_tq2-relay_pic10f320.hex`. Add a regression proving that omitting
  all three from committed, checksummed, and fresh sets still fails.
  **`scripts/make-release.sh` belongs in this bullet too** *(added 2026-07-26)*:
  it derives the checksum set by glob as well (`sha256sum ./*.hex`, `:454`), so
  fixing only the verifier leaves the glob alive in the producer that generates
  the set being verified. Both consume the canonical Makefile-owned set.
- `test/test_pic_build.sh` (or a sibling) — exercise PIC10F320 fake-XC8
  generation, Intel HEX validation, cleanup after empty/malformed/symlinked or
  over-budget output, exact 256-word gating, and matrix validation.
- `Makefile` `clean` / `clean-tests` and both ignore files — remove/ignore all
  PIC10F320 build, test, coverage, and mutation artifacts; verify a clean tree
  after `make clean`.
- `README.md`, `test/README.md`, and release documentation — remove or qualify
  every "unsupported" or external-child statement. Outstanding instances:
  `README.md:6-7` ("for PIC10F320 support, see the child project" + the GitHub
  link) and `:11` ("unless the PIC10F320 is a hard requirement");
  `test/README.md:173` ("the sibling **pic10f320-bypass-firmware** child project
  shares them"). The stale child-project link in `src/bypass_mcu_avr_xt.c:16-17`
  is a comment-only firmware-source edit and must be performed by the user under
  project policy; confirm non-comment firmware bytes remain unchanged.
  **Two more instances, found by the second 2026-07-26 pass** — neither is a
  simple deletion, so decide rather than sweep:
  - `CHANGELOG.md:233-234` quotes the child as an external repository
    ("[pic10f320-bypass-firmware](https://github.com/…) child project, which
    landed the same TMR2 / 2 MHz / `ANSELA` work after the …"). It is a
    *historical* release note and was true when written. Changelog entries are
    normally immutable, so the default is preserve-as-history — but §10's "one
    file, one timeline" then leaves a merged changelog that refers to part of
    itself as an external project. Either leave it and let the unified entry
    explain the absorption, or annotate it in place; do not silently rewrite
    history.
  - `TODO.md:279` still reads "PIC10F320: almost certainly does not fit. Check
    against its budget before promising cross-target parity, and record the
    omission if it cannot be done" — inside the shadow-state hardening item, not
    the retired viability verdict. Post-merge that is a **live cross-target
    task**, correctly stated, and it is now in scope for this repository. The
    "Already cleaned" note below therefore must not be read as "TODO.md needs no
    further work": this line needs re-framing from "the other project's problem"
    to a tracked item, and it is the same flash-headroom question §6.11 asks
    about the defensive layer. (`TODO.md:433` is already correct and needs
    nothing: three variants at 219/240/243 of 256.)
- **The moved firmware's own comments** *(new — second 2026-07-26 pass)*. The
  child source was written from outside and says so. `bypass_mcu_pic10f320.c:6-8`
  opens with "NOTE: this source code makes numerous references to the parent
  project, mcu-bypass-firmware: <URL>", and five more sites say "the parent
  project" meaning this repository: `:68` (the "DDR" macro-name convention),
  `:74` (`hw_configure_output_pins()`), `:321` ("Improved Scheme With Muting"),
  `:640` and `:657` (the inlined `debounce_integrate()` / `debounce_step()`).
  Post-merge every one of them is self-referential. §12 already carves out
  "separately reviewed user-owned source comments"; this is the enumeration that
  carve-out needs. Two sequencing notes: these are comment-only, so they
  **preserve emitted bytes** and may land after the §6.13 gate without
  rebaselining it — unlike §6.11's defensive-layer edit, which does rebaseline
  and must not be batched with them. *(The `LICENSE` row below used to add a
  license-header normalization to this same commit; that instruction rested on a
  false premise and was withdrawn by the third 2026-07-26 pass — the file's
  header is already SPDX. These six comment sites are the whole sweep.)*
- `src/bypass_blocking_delay.h:15` and `src/bypass_pins_pic10f322.h:11` say
  "PIC10F32x" *(noted second 2026-07-26 pass; low priority)*. Per the project's
  322-vs-32x convention the delay note is fine as-is — `__delay_ms()` is true of
  both parts. The pin-map header is the softer case: with both parts in one
  repository, "PIC10F32x pin map" now reads as covering a part whose pin map is
  inlined in its own firmware instead. One clarifying word, user-owned, optional.
- **Already cleaned (2026-07-26 documentation audit)** — verify rather than
  redo: `TODO.md` no longer contains the "PIC10F320 is NOT viable" verdict, the
  historical six-phase PIC plan, or the external-child-project section;
  `docs/pic10f320_feasibility.md` now scopes its finding to the *modular*
  architecture and points here instead of declaring the part unsupported;
  `docs/phase2_pic_shell.md` was rewritten as PIC10F322-only design notes and no
  longer claims the shared contract covers the 320. `docs/phase1_hw_abstraction.md`
  and `docs/phase2b_pic_shell_spec.md` were deleted (obsolete planning
  scaffolding); the multi-MCU architecture rationale they carried now lives in
  `DESIGN_DOCUMENTATION.adoc`, "Multi-MCU Architecture". Phase 7 should confirm
  these rather than re-open them.

---

## 5. Namespace collisions to resolve

1. **Makefile targets.** Child uses *bare* names because it is single-target;
   import them under a distinct **`pic320-`** prefix. Define the complete
   topology before implementation:

   - build/utility: `pic320`, `pic320-size`, `pic320-analyze`,
     `pic320-analyze-cppcheck`, `pic320-analyze-misra`, `pic320-clean`,
     `program-pic320` — corrected 2026-07-26: this last one is **new work, not
     an import**. The child Makefile has no programming target at all, so there
     is no child recipe to rename; author and document it against the parent's
     `program-pic` (`Makefile:1282`) as the model, and budget for it;
   - host lanes: `pic320-test-equiv`, `pic320-test-actuation`,
     `pic320-test-fault-host`, `pic320-coverage`, `pic320-coverage-clean`,
     `pic320-coverage-check-model`, `pic320-coverage-check-fw`;
   - emitted-image/CLI lanes: `pic320-test-config`, `pic320-test-gpsim`;
   - libgpsim lanes: `pic320-test-fault-target`,
     `pic320-test-fault-variants`, `pic320-test-lockstep`, `pic320-test-io`,
     `pic320-test-soak`, `pic320-test-target-gpsim`;
   - robustness lanes: `pic320-test-build`, `pic320-test-mutation`;
   - aggregates: `pic320-test-host`, `pic320-test` for one selected variant,
     `pic320-test-variants` for all three, `pic320-test-target`, and
     fail-closed `pic320-test-target-variants`.

   The child also carries `test-gpsim-wrappers`, `test-lockstep-progress`,
   `test-target-matrix`, `test-soak-timing`, `test-release-images`,
   `test-pic-build`, `test-build-serialization`, and `test-make-lock-probe`,
   all of which already exist as parent targets. Those are the shared-name
   harness regressions of §4 — resolve each as FOLD (chip-parameterized, keeps
   the existing target name) or FORK (`pic320-` prefix) rather than assuming a
   prefix rename. `pic320-test-formal`/`-cbmc`/`-model-check`/`-symbolic`/
   `-symbolic-klee` deliberately get **no** PIC10F320 variants: those fold into
   the single shared formal suite over `src/bypass_pure.c` (Principle 2).

   Two further child targets fall outside both lists above and need a decision
   rather than a prefix *(added 2026-07-26)*: `release` — the child's own
   release driver, superseded by the parent's `scripts/make-release.sh` per §10,
   so it is dropped rather than renamed — and `help`. The parent's `help` text
   (`Makefile:2779+`) must itself gain `pic320` lines in the same phase that
   adds the targets, or the entire new lane is undiscoverable from the command
   line.

   The prefix choice must also stay consistent with the parent's existing PIC
   naming, which is `pic-` (e.g. `pic-test-config`, `pic-test-target-variants`,
   `pic-coverage-check-fw`) — so `pic-*` reads as "PIC10F322" and `pic320-*` as
   "PIC10F320". If that asymmetry is judged too subtle given §14.7, rename the
   322 lane to `pic322-` in the same phase rather than living with it.
   **Decided (§15, D1): keep `pic-` = 322, add `pic320-`/`PIC320_*`; the 322 lane
   is not renamed.** The asymmetry is accepted and deferred to the `TODO.md`
   unified-naming item. Do not re-open it while executing.

   Host-only checks may join top-level `test` / `test-long` after they are
   green. Real-tool gates remain in strict PIC CI/release lanes, or join a new
   explicitly full-tool `test-all-targets`; they do not silently change the
   existing default aggregate contract.
2. **Test-file basename collisions.** `test_config_pic.c` and
   `test_{fault,io,lockstep,soak}_pic.cc` exist for both chips. Resolved by directory
   (`test/pic/` = 322, `test/pic10f320/gpsim/` = 320). Keep the `-I`
   include paths chip-specific in the Makefile recipes.
3. **Release image names.** Already disambiguated by the `_pic10f320`
   suffix. Keep the three public child basenames unless an explicit migration
   decision says otherwise; do not regenerate historical TMUX names.

   **The asymmetry is wider than the suffix** *(second 2026-07-26 pass)*, and
   "already disambiguated" was true only about *collisions*. The two lines differ
   in prefix **and** in output-stage vocabulary:

   | | Parent `release/v0.9.5/` | Child `release/v0.9.5/` |
   | --- | --- | --- |
   | prefix | `bypass_` (`FW_BASE = bypass`, `Makefile:102`) | `bypass_mcu_` (`FW_BASE := bypass_mcu`, `:103`) |
   | stage tokens | `cd4053`, `mute`, `relay` (`VARIANTS`, `:142`) | `cd4053-simple`, `cd4053-mute`, `tq2-relay` |
   | part suffix | `_pic10f322`, `_t45`, `_t85`, **or none** (bare = ATtiny13A) | `_pic10f320` |

   So a merged `release/v0.10.0/` carries **three** conventions at once, and
   `bypass_mute_pic10f322.hex` and `bypass_mcu_cd4053-mute_pic10f320.hex` name the
   *same output stage on two PIC chips*. `FW_BASE` is the mechanism, and it is one
   of the §5.6 colliding variables. Decide in Phase 0:

   - **Keep** the child basenames (cheapest; no published-name break). Then the
     release `README.md`/`MANIFEST.md` must state the asymmetry explicitly, and
     the image→MCU classifier in `scripts/make-release.sh` must handle both
     prefixes — a `bypass_mcu_*` name must not fall through to AVR metadata (§10).
   - **Migrate** to one scheme at `v0.10.0`. This breaks three published
     basenames, needs a redirect note in the child archival pointer (§6.15), and
     forces §6.13's comparison to key on **content, not filename**.

   Note the bare-name convention is pre-existing parent debt (`bypass_cd4053.hex`
   *is* the ATtiny13A image); unifying that is out of scope here, but a canonical
   set (§10) that encodes three conventions should say why.

   **Decided (§15, D2): keep the child basenames.** No migration at `v0.10.0`, so
   both obligations of the first option are now required work — the
   `bypass_mcu_` prefix in `scripts/make-release.sh`'s image→MCU classifier, and
   an explicit statement of the asymmetry in the release `README.md`/`MANIFEST.md`.
   Whole-tree unification is deferred to the `TODO.md` unified-naming item.
4. **Build/test output names.** Use `build_pic10f320/` and variant-private
   nested outputs. Never let concurrent variants share an object, executable,
   coverage file, `gpsim.log`, or PASS-evidence path. This item covers
   variant-vs-variant collisions only; the cross-*chip* directory collisions —
   which include a destructive imported `rm -rf` — are §5.7.
5. **Git tags.** Both repos carry bare `v0.9.*` names. Preserve the child's
   original signed annotated tag objects under `pic10f320/v0.9.*`; do not rely
   on commits alone and do not recreate signed tags.
6. **Makefile variable namespace.** *(New — second 2026-07-26 pass. This class was
   missing entirely, and it is the highest-severity gap the pass found.)* §5 listed
   targets, test basenames, image names, output names, and tags — but the merge
   also collapses two *variable* namespaces into one file. **56 names collide, 35
   of them `PIC_*`**, and many carry chip-specific values:

   | Variable | Parent | Child |
   | --- | --- | --- |
   | `PIC_CHIP` / `PIC_TAG` | `10F322` / `pic10f322` (`Makefile:609-610`) | `10F320` / `pic10f320` (`:50-51`) |
   | `PIC_FLASH_WORDS` | **512** (`:615`) | **256** (`:56`) |
   | `PIC_GPSIM_PROC` | `p10f322` (`:618`) | `p10f320` (`:125`) |
   | `FW_BASE` | `bypass` (`:102`) | `bypass_mcu` (`:103`) |
   | `COVERAGE_MIN` | 90, over the oracle (`:2654`) | 95, over the real core (`:193`) |
   | `COVERAGE_DIR` | `coverage` (`:2652`) | `coverage` (`:192`) — see §5.7 |
   | `PIC_CHIP_MACRO`, `PIC_XTAL`, `PIC_CFLAGS`, `HOST_CFLAGS`, `PIC_CPPCHECK_*`, `PIC_MISRA_CPPCHECK_FLAGS` | 322-shaped | 320-shaped |
   | `PIC_{FAULT,IO,LOCKSTEP,SOAK}_{SRC,BIN,COMPILE,CTX_DEF,DEPS}`, `PIC_LOCKSTEP_MODEL_OBJ`, `PIC_SOAK_{CXX,GPSIM_INC,DURATION_MS,LIVENESS_INTERVAL_MS,PROGRESS_INTERVAL_MS}` | 322 harnesses | 320 harnesses |

   Genuinely shared, and safe to fold to one definition: `AWK`, `CBMC`,
   `CBMC_CHECKS`, `CBMC_DEEP_UNWIND`, `CBMC_PROOFS_LOOP`, `CPPCHECK`, `GCOV`,
   `GPSIM`, `KLEE`, `KLEE_CLANG`, `KLEE_INC`, `KLEE_LLVMLINK`, `MISRA_ADDON`,
   `MISRA_RULES`, `MISRA_SUPPRESS`, `IHEX_VALIDATOR`, `PIC_CC`, `PIC_DFP`,
   `PIC_DFP_INCLUDE`, `PIC_XC8_INCLUDE` (the last four by §6.14's verified
   toolchain-pin equality).

   **Why this is a blocker, not bookkeeping.** The failure is silent and it defeats
   a release gate: a merged Makefile that keeps one `PIC_FLASH_WORDS` gates the 320
   against **512** words, so an over-budget image passes the budget check that
   §14.4 calls release-critical. `FW_BASE` mis-picks rename every image on one side
   (§5.3). One `PIC_SOAK_DURATION_MS` makes a single override apply to both chips'
   soaks, so a short-duration test run silently shortens the other chip's too.

   Requirements:
   - Chip-specific variables get an explicit prefix, chosen in Phase 0 **together
     with** the §5.1 target-prefix decision so `pic320-test-soak` and
     `PIC320_SOAK_DURATION_MS` read consistently. If §5.1 renames the 322 lane to
     `pic322-`, rename `PIC_*` → `PIC322_*` in the same commit; if it keeps `pic-`,
     `PIC_*` stays 322 and the new names are `PIC320_*`. Do not mix.
   - The shared-tool list above is an explicit allowlist, not a residue. Anything
     not on it is presumed chip-specific.
   - **This is an external interface, not an internal rename.**
     `scripts/make-release.sh:155` reads Makefile variables through
     `mkv() { make -s print-"$1"; }`, and `print-%` exists in both Makefiles. Every
     renamed variable is therefore a change to the release script, its manifest
     output, and any CI step that reads it. Grep `print-` across
     `scripts/` and `.github/workflows/` before renaming.
   - The plan's own Phase-4 command block already writes
     `PIC320_SOAK_DURATION_MS`, i.e. it assumed this rule before stating it. That
     example is now normative.
   - Two child targets are internal machinery that also collides by name with a
     different implementation on each side: `_make-serialized-invocation` and
     `_MAKE_REQUESTED_GOALS`. They appear in neither help text, so they are easy to
     miss — and they are exactly the mechanical merge point of §6.4's
     single-lock reconciliation.
   - Watch the inverse case too: a child-only *name* can still carry a colliding
     *value*. `BUILD_DIR ?= build_pic` (child `Makefile:104`) does not collide by
     name — the parent uses per-target build-directory variables — yet it points at
     the parent's PIC10F322 build directory. §3 already mandates
     `build_pic10f320/`; this is where the override actually has to change. The
     other child-only names to place under the prefix rule are `SRC`, `HEX`,
     `MODEL_SRC`, `PIC_VARIANT`, `PIC_VARIANTS_ALL`, `PIC_OUTPUT_DEF`,
     `COVERAGE_TESTS`, `FAULT_*`, and `HOST_{CC,INC}`; `MUTATION_ALLOW_SKIP` is
     deliberately shared, since §6.6 keeps one central mutation policy.
7. **Shared artifact directories, and destructive imported clean recipes.** *(New —
   second 2026-07-26 pass.)* §5.4 forbids *cross-variant* sharing of outputs; the
   real hazard here is **cross-chip**, and §3's layout addressed only the build
   directory. Both Makefiles set `COVERAGE_DIR = coverage`. The parent works inside
   subdirectories of it (`coverage/report`, and a `mktemp -d coverage/check.XXXXXX`
   per gate run), while the child writes flat into it (`model_cov.o`,
   `bypass_pure.c.gcov`, `fw_fault_cov.*`, `test_fault_cov`). Worse, two imported
   recipes are destructive at directory granularity: the child's `coverage-clean`
   (`Makefile:649`) and its `clean` (`:979`) both `rm -rf $(COVERAGE_DIR)`, so an
   imported `pic320-coverage-clean` — or `pic320-clean`, or a `make clean` that
   reaches it — deletes the parent's coverage report and any concurrent gate
   working directory.

   Give PIC10F320 coverage its own directory (`coverage_pic10f320/`, or a subtree
   under `build_pic10f320/`), and scope every imported `rm -rf` to it. The same
   check applies to the other shared root-level paths the child's recipes touch:
   `gpsim.log`, stray `*.gcov`, `*.dump` / `*.ctu-info` /
   `cppcheck-addon-ctu-file-list*`, and `commit_msg.txt`. `/.make.lock` is the one
   path that is *intentionally* shared — it is the §6.4 whole-worktree lock and
   must stay a single inode.

   The hazard runs in the parent's direction too *(third 2026-07-26 pass)*:
   `coverage-clean` (`Makefile:2722`) ends with
   `find . -name '*.gcda' -o -name '*.gcno' | xargs rm -f`, rooted at the
   repository. After Phase 1 that descends into `_incoming_pic10f320/`, and after
   Phase 2 into `test/pic10f320/`. It is harmless — those are generated files with
   no tracked counterpart — but it means "scope every destructive recipe" is a
   two-way review, not just an audit of imported recipes.
8. **Global Make directives and exported variables.** *(New — third 2026-07-26
   pass. Missing class: §5.1 covered targets and §5.6 covered variables, but the
   merge also collapses two sets of Make **special targets**, which are
   file-scoped rather than target-scoped and therefore change behaviour
   repository-wide.)*

   | Directive | Parent | Child | Consequence of a naive import |
   | --- | --- | --- | --- |
   | `.NOTPARALLEL:` | absent | **present** (`Makefile:205`, bare) | serializes the **entire** merged graph |
   | `.DELETE_ON_ERROR:` | **present** (`Makefile:445`) | absent | every imported recipe gains delete-on-failure semantics |
   | `export PROJECT_MAKE :=` | `$(MAKE_COMMAND)` (`:196`) | `$(MAKE)` (`:119`) | same exported name, different value, in every recipe's environment |

   **`.NOTPARALLEL` is the sharp one, and it is a hard test failure rather than a
   slowdown.** A bare `.NOTPARALLEL` applies to the makefile it appears in, not to
   a target, so importing the child's line disables parallelism for the whole
   merged build. The parent has a regression that exists specifically to assert
   the opposite: `test-make-safe-parallel-probe` (`Makefile:1998`) invokes
   `$(MAKE) --no-print-directory -j2` over two mutually-waiting marker targets and
   fails with `FAIL: reviewed recursive fan-out was serialized` if they do not
   overlap. The recursive sub-make re-reads the same Makefile, so `.NOTPARALLEL`
   applies there too and the probe fails — with the cause roughly 1700 lines away
   from the symptom. The parent's serialization design is deliberately *not*
   `.NOTPARALLEL`: it is the whole-worktree `/.make.lock` plus the exported
   `_MAKE_SERIAL_LOCK_HELD` marker (`Makefile:16`), which serializes complete
   invocations while leaving reviewed recursive fan-out parallel. Do not import
   the child's directive; fold its intent into the existing lock (§6.4).

   `.DELETE_ON_ERROR` is the quieter one. Imported recipes were written under a
   makefile that lacked it, so they will newly have their target deleted when a
   recipe fails. That is usually an improvement, but it interacts directly with
   §6.4's `ec6fa48` ("build: reject malformed PIC images") hardening, which does
   its own post-failure artifact cleanup — verify the two do not fight, and that
   the child's cleanup regressions still observe what they assert.

   `PROJECT_MAKE` belongs to §5.6's variable class but is easy to miss there
   because it is `export`ed rather than merely defined: it reaches every recipe
   and anything a recipe shells out to. Parent-only exports to preserve on the
   fold: `_MAKE_SERIAL_LOCK_HELD` (`:16`) and `GPSIM_TIMEOUT_SECONDS` (`:620`).

   Requirement: before merging any recipe block, diff the two Makefiles'
   *directive* lines (`.PHONY` aside) as a distinct review step —
   `grep -nE '^\.[A-Z_]+:|^export|^vpath|^include'` over both — and record a
   disposition per directive. Neither file uses `vpath`, `include`, or
   `.ONESHELL`, and both implement `print-%` identically, so the table above is
   the complete inventory at the pinned tips.

---

## 6. Pre-merge checkpoints (do these first)

1. **Pin the audited import — re-pinned 2026-07-25.** Import child HEAD
   **`f58d2d57ef5a72637fbc032a3f3676f249409b68`**, *not* the previously pinned
   `915ee03b58c8ac48203b78dfdc07da645dfac20f`. `915ee03` is signed tag `v0.9.5`
   (whose source tip is `331f90f7363d2d19016445667e2fb0a458df4651`; the tag
   commit adds release artifacts only), but the child has **13 commits after
   it**, and those commits implement most of §6.4's false-pass hardening and
   correct the footprints §6.5 used to warn about. Importing `915ee03` would
   discard that work and force a manual re-implementation.

   | Commit | Effect |
   | --- | --- |
   | `c3d4620` | release: validate soak timing inputs |
   | `1ce47b7` | test: make gpsim wrappers fail closed |
   | `4d588ba` | test: align lock-step stimulus phase |
   | `f347713` | test: make target fault execution fail closed |
   | `ec6fa48` | build: reject malformed PIC images |
   | `e6c0f57` | test: add target and soak mutations |
   | `5f5374e` | release: fix image reproduction checks |
   | `b79d942` | build: serialize Make invocations |
   | `85cbd19` | test: reject invalid target variant matrices |
   | `943adf7` | test: abort lock-step on simulator stalls |
   | `c83b70d` | docs: reconstruct v0.9.4 and v0.9.5 changelog |
   | `88b4f2d`, `f58d2d5` | docs: correct user-facing PIC10F320 footprints |

   `f58d2d5` is a clean worktree, all six signed tags remain reachable, and
   `v0.9.5` stays available under its namespaced ref. Verify all six signed
   tags `v0.9.0` through `v0.9.5` before namespaced import — all six verified
   `SIGNED-OK` on 2026-07-25. If the child moves again, re-audit and re-pin
   rather than importing a moving `main`.
2. **Reconcile the model files.** Verified 2026-07-25: `bypass_pure.h` and
   `bypass_types.h` differ from their `src/` counterparts **only** in license
   header style (child: three-line "All rights reserved" form; parent: SPDX).
   `bypass_pure.c` differs in the header **and by one trailing space** on the
   `{` of the `BYPASS == ctx.effect_state` branch — the parent stripped it in
   `06a9d37`. Behaviour is identical, but a naive scripted byte-comparison will
   report a mismatch; compare with whitespace normalization and record the
   result.

   Child `test/model/bypass_config.h` is a minimal host shim defining only
   `RELEASE_THRESH (25U)` / `PRESSED_THRESH (8U)`; `src/bypass_config.h`
   defines the same values (`:93`, `:111`), so the effective thresholds match.
   The replacement this plan mandates, `test/bypass_config_host.h`, is
   AVR-shaped — it defines `PB0`/`PB1`/`PB2` and `F_CPU 1200000UL` to satisfy
   `src/bypass_config.h`'s AVR guards. **Downgraded 2026-07-26 from hazard to
   verification step.** `src/bypass_config.h` wraps every pin and timer
   definition in `#if defined(__AVR__)` (`:19`–`:88`) and defines both
   thresholds *outside* that guard. On a host compile `__AVR__` is undefined, so
   the guarded block is skipped entirely and the shim's pin/`F_CPU` definitions
   are inert — they cannot leak an AVR pin number into a PIC10F320 harness even
   if something tried to read one. Still confirm the 320 harnesses take pin
   numbers from the firmware rather than the shim; the earlier recommendation to
   "add a PIC-appropriate shim alongside it" is withdrawn as unnecessary work.

   Note that child `test/model/README.md` records provenance as parent commit
   `bf6a6c1`, far behind parent HEAD; the diff above is the evidence that the
   staleness is immaterial, and the file's re-sync instructions die with the
   vendored copy in Phase 3.
3. **Preserve distinct host/formal assurance.** Audit all assertions; migrate
   `verify_corrupt_state_faults()` explicitly; decide how to retain the
   independent-oracle and direct-core roles. **The parent KLEE link recipe is
   already fixed** — `d848e52` ("test: link KLEE proof with the shipping core",
   2026-07-16) landed and `test-klee-build` is now a member of the default
   `test` aggregate; re-verify rather than re-implement. Equivalence status
   verified 2026-07-25: `misra_rules.txt` and `misra.json` are 0-diff; child
   `misra_suppressions.txt` is comments-only while the parent's carries the
   real D-1 hardware-register entries; `model_step.h` diverges as expected
   (parent includes `bypass_config_host.h` + `../src/bypass_pure.h`, child
   relies on `-Itest/model`) and the parent copy wins.
4. **Harden false-pass paths before promotion — largely already done.** As of
   2026-07-25 both repositories independently fixed most of this list, which is
   the main reason §6.1 re-pins to the child tip. Verify; do not re-implement:

   | Item | Child | Parent |
   | --- | --- | --- |
   | gpsim timeout/nonzero propagation | `1ce47b7` | `86affc9` |
   | deterministic first lockstep stimulus | `4d588ba` | — (verify) |
   | immediate simulator-progress failure | `943adf7` | `5f853ee` |
   | exact target-fault check counts | `f347713` | — (verify) |
   | bounded/nonzero soak duration | `c3d4620` | `8c81e1b`, `fab366f` |
   | structural IHEX/checksum/EOF + cleanup | `ec6fa48` | `0531490` |
   | exactly-three variant-matrix validation | `85cbd19` | — (320-specific) |
   | private outputs / Make serialization | `b79d942` | `8ebe025` |
   | release image reproduction isolation | `5f5374e` | `f137415` |

   `test/test_lockstep_progress.sh` and `scripts/validate-ihex.sh` are now
   **byte-identical** between the two repositories, confirming convergence.
   What remains: confirm the shared `run_ms()` propagation fix is present on
   both sides at the pinned tips; reconcile the two independently-developed
   serialization implementations into one lock covering both chips' XC8
   invocations (their regressions still diverge by ~227 diff lines); and re-run
   every hardened lane in the merged tree, because a fix verified inside the
   child's single-target Makefile is not evidence for the merged recipe.
5. **Define the three-variant contract.** Pin accepted command-line values,
   preprocessor macros, artifact basenames, sizes, and expected per-variant
   PASS counts. Reject empty, duplicate, and unknown variant lists inside every
   authoritative aggregate rather than relying on an earlier build to fail.
   The footprint discrepancy this checkpoint used to warn about **is resolved**:
   `88b4f2d`/`f58d2d5` corrected the child's user-facing figures, so
   `README.md:45-46` and `release/v0.9.5/MANIFEST.md` now agree at
   **219 / 240 / 243** words for cd4053-simple / cd4053-mute / tq2-relay, of
   256. Still re-measure in the merged tree and update if XC8 output shifts —
   the largest variant has 13 words of headroom.
6. **Define mutation topology and policy.** Identify duplicate model mutants,
   child-only firmware mutants, required sandbox files, kill targets, and new
   target/soak mutants. Preserve the parent's current event policy: its
   full-tool PIC job already invokes mutation with `MUTATION_ALLOW_SKIP=0` on
   pushes, schedules, and manual dispatches, and release validation is strict;
   pull requests intentionally omit the minutes-long mutation gate. The separate
   non-PIC stress job permits explicit PIC skips because it lacks PIC tools and
   is not authoritative PIC mutation evidence. Extend the strict full-tool lane
   to the combined PIC10F322/PIC10F320 set rather than weakening either subset.
   The policy itself lives in `test/mutation_policy.sh` — extend that central
   mechanism, do not add a parallel PIC10F320 policy path (§6.12).
7. **Record ATtiny202 release status.** It is development-only/non-release. Keep
   its normal CI lane, but intentionally omit it from release creation,
   reproduction, images, and soak evidence, and scope unified-release claims to
   release-supported targets.
8. **Repair release/changelog baselines — both halves already done; verify.**
   The parent's missing v0.9.3/v0.9.4 entries were reconstructed in `af080fd`
   (2026-07-15) and `CHANGELOG.md` now carries complete `[0.9.3]` and `[0.9.4]`
   sections; the child's were reconstructed in `c83b70d`. Verify both, then
   classify any remaining child v0.9.4/v0.9.5 work under its historical
   version. Note the parent has since released **v0.9.5** (`eec7b9f`,
   2026-07-18), so *both* lines now stop at v0.9.5 and the earlier
   "greater than the parent's v0.9.4" framing is obsolete: the first unified
   release must exceed both. `v0.10.0` remains the recommendation; never reuse
   `v0.9.5` from either line.
9. **Snapshot clean green baselines.** From clean checkouts/build directories,
   capture parent host/full-tool results and child host, all-variant, target,
   mutation, CONFIG, coverage, and soak evidence. Ignored artifacts in the
   current child worktree are not baseline evidence. Record unavailable tools
   as blockers, not passes. Also capture the three child
   `release/v0.9.5/*.hex` images and their hashes — they are the byte-identity
   baseline §6.13 gates on, and they must be recorded before any import moves
   the firmware.
10. **Preflight Git tooling.** `git subtree` **is installed** — verified
    2026-07-25 at `/usr/lib/git-core/git-subtree` under Git 2.43.0. The earlier
    "absent from the currently inspected Git installation" note was wrong and
    is retracted. Still confirm child refs are fetchable, signed tag
    verification works (all six verified), and the integration branch/base SHA
    is recorded before any modifying Git operation. The child worktree path is
    `../pic10f320-bypass-firmware` — hyphens, not underscores.
11. **Decide the PIC firmware defensive-layer divergence.** *(New 2026-07-25 —
    blocker.)* After this plan was first drafted the parent hardened the
    PIC10F322 shell twice: `b410795` ("firmware: validate settled output latch
    state") and `065fbd2` ("firmware: validate exact PIC10F322 pin
    directions"). The two PIC targets now check materially different things:

    | Check | `src/bypass_mcu_pic10f322.c` | child `bypass_mcu_pic10f320.c` |
    | --- | --- | --- |
    | required output pins still outputs | yes | yes (`:233`) |
    | **exact** TRISA across all four implemented bits | yes | **no** |
    | full output-latch match against expected mask | yes | **no** |
    | ANSELA integrity of the output pins | inside `hw_critical_sfrs_intact` (`:142`) | dedicated check (`:489`) |

    The 322 exposes `hw_output_state_intact(required_output_mask,
    expected_high_mask)`; the 320 exposes `hw_output_pins_intact(expected_mask)`
    whose whole body is `return (0U == (TRISA & expected_mask));`.

    Merging verbatim therefore ships two PIC targets with visibly unequal
    defensive layers, and the parent's exact-TRISA mutation category
    (`2214a78`) gains no PIC10F320 counterpart. At 243/256 words the 320 may
    genuinely not afford the stronger checks. Resolve **before** Phase 2, in
    this order:

    a. Measure the flash cost of porting exact-TRISA plus latch-match to each
       of the three variants.
    b. If it fits, the user makes the firmware edit and the divergence ends.
    c. If it does not fit, record the omission explicitly in
       `docs/pic10f320_special_case.md` as part of the constrained-target
       story, and state in the mutation topology (§6.6) why the exact-TRISA
       mutant has no 320 twin.

    **Measured 2026-07-26 — step (a) is done, and the answer splits the
    divergence in two.** XC8 V3.10 + DFP 1.9.189, the Makefile's exact flags
    (`-mcpu=10F320 -mdfp=… -std=c99 -O2 -D_XTAL_FREQ=2000000UL -D<OUTPUT_*>`),
    measured in a scratch copy so neither worktree was touched. Baselines
    reproduced the documented 219 / 240 / 243 of 256 words exactly. Overflowing
    configurations were re-measured on the pin-compatible 512-word 10F322, whose
    baseline is identical word-for-word, so the deltas transfer:

    | Configuration | cd4053-simple | cd4053-mute | tq2-relay | Fits 256? |
    | --- | --- | --- | --- | --- |
    | baseline (unmodified child tip) | 219 | 240 | 243 | — |
    | **exact TRISA only, no-arg helper** | **220** | **241** | **244** | **all three (+1)** |
    | exact TRISA only, helper keeps its unused mask parameter | 221 | 242 | 245 | all three (+2) |
    | exact TRISA + latch match, lean (ternary; no fail-closed `else`) | 240 | 261 | 259 | simple only (+21/+21/+16) |
    | exact TRISA + latch match, faithful 322/`bypass_output_*.c` shape | 258 | 279 | 282 | none (+39 uniformly) |

    So the two halves of the divergence have completely different prices:

    - **Exact TRISA costs one word and should be ported.** It is not merely
      affordable, it is nearly free, because exact TRISA *subsumes* the existing
      per-variant "every required pin is still an output" test: if
      `(TRISA & 0x0F) == (0x0F ^ BYPASS_OUTPUT_DDR_MASK)` then every RA0..RA2
      direction bit is already 0 and RA3 is still an input. The helper therefore
      loses its `expected_mask` parameter and all three call sites shrink, which
      is why the no-arg form is cheaper than the parameterized one. This closes
      exactly the half that the parent's exact-TRISA mutation category
      (`2214a78`) targets, so the 320 gains a twin for it.
    - **The latch match does not fit and is the recorded omission.** Even the
      lean formulation — which exploits the fact that the main-loop gate already
      range-checks `ctx_.effect_state` (`bypass_mcu_pic10f320.c:624`), so the
      third fail-closed branch is redundant — overshoots on two of three
      variants: cd4053-mute by 5 words and tq2-relay by 3. Only cd4053-simple
      fits, at 240/256.

    **Do not take the latch match on cd4053-simple alone.** A per-variant
    defensive layer inside one firmware is worse than a uniform documented
    omission: the fault harness and the mutation topology would both need
    per-variant expected check counts, and `docs/pic10f320_special_case.md`
    would have to explain a three-way split instead of one clean statement.
    Resolution is therefore (b) for exact TRISA — uniformly, on all three
    variants — and (c) for the latch match.

    Two consequences for sequencing and scope:

    - This is a firmware edit that **changes emitted bytes**, so per §6.13 and
      §15's D4 it lands *after* the Phase-2 byte-identity gate has passed, as its
      own reviewed commit carrying the rebaselined hashes — never batched with
      the comment-only sweep of §4.
    - It is **not firmware-only**, and the coupled test surface is wider than a
      grep for the changed symbol suggests: **five test files, seven edit sites.**
      Written and verified 2026-07-26 in a scratch clone (neither worktree
      touched); the accompanying test patch is the deliverable, and the exact
      diff is preserved with this measurement.

      | File | Why it moves with the firmware |
      | --- | --- |
      | `test/fault/fw_fault_harness.h:79-80` | shim declaration loses the `uint8_t mask` parameter |
      | `test/fault/fw_fault_harness.c:245` | shim body follows the signature change |
      | `test/fault/test_fault.c` (predicate probes) | four `fwp_output_pins_intact(mask)` call sites; two clean-state probes collapse into one, since the exact-TRISA predicate no longer varies by mask |
      | `test/fault/test_fault.c:148-152` (**main-loop case**) | `expect_no_reset(FWI_RA2_PIN_TO_INPUT)` **inverts to `expect_reset`** on cd4053-simple, and the `#if defined(OUTPUT_CD4053_SIMPLE)` split disappears |
      | `test/pic/test_fault_pic.cc:183-189, 507-521` | the RA2 `inject_case` flips from `expect_reset=0` to `1`, its variant `#if` collapses, and **`EXPECTED_CHECKS` goes from 23/22 to a uniform 22** |
      | `test/run_mutation_tests.sh:56` | the "FW output-pin SEU check neutered" host mutant quotes the old line verbatim |
      | `test/run_mutation_tests.sh:128` | the "TARGET output-direction guard disabled" mutant quotes the old helper **body** (`return (0U == (TRISA & expected_mask));`), so a grep for the *function name* does not find it |

      Two of those are the substance rather than mechanical follow-on, and both
      are *assurance gains* that should be called out in the commit message
      rather than buried: the spare RA2 pin on cd4053-simple becomes a guarded
      direction fault instead of a documented blind spot, so **the variant split
      in the fault expectations disappears entirely** — all three variants now
      assert identical defensive behaviour, at both host and target level.

      Rewriting the mutant is a small design decision worth recording. The old
      pattern quoted one variant's gate body, which after the port is no longer
      unique (mute and relay reduce to identical text) and no longer
      variant-covering. It is retargeted at the helper's comparison —
      `s@(uint8_t)(0x0FU ^ BYPASS_OUTPUT_DDR_MASK)@(uint8_t)(TRISA & 0x0FU)@`,
      making the exact-TRISA test a tautology — which is both unique and
      variant-independent, so one mutant now covers all three builds.

      Evidence, all from the scratch clone with the firmware port applied:
      `make test-fault-variants` → 41 checks / 0 failures on each of the three
      variants (uniform, where the counts previously differed); the child's full
      `make test` → EXIT=0; and `MUTATION_ALLOW_SKIP=0 make test-mutation` →
      **42 killed, 0 survived, 0 errored, 0 skipped**.

      **Two of the seven sites were found by *running* the suite, not by reading
      it — record this, because it is the reusable lesson.** A review-only port
      would have shipped both:

      - `test_fault.c:122` failed with `valid state [TRISA RA2 flipped to input
        (spare on simple)] must NOT force a reset (got r=1)` — an inverted
        expectation, invisible to a symbol grep because it names an enum
        (`FWI_RA2_PIN_TO_INPUT`), not the changed function.
      - `run_mutation_tests.sh:128` surfaced only on the full fail-closed
        mutation run, as `[31] ERROR mutation did not change
        bypass_mcu_pic10f320.c (stale pattern?)`. It quotes the helper *body*
        rather than its name, so it evades a `hw_output_pins_intact` grep
        entirely. It is retargeted to disable the new helper by early return,
        which keeps it textually distinct from the §6.11 host mutant's
        tautology.

      This is Principle 7 working as intended in both directions: the driver
      fails closed on the stale-pattern class (`run_mutation_tests.sh:249`
      `cmp -s`-checks every mutant), *and* the check earned its keep. One
      caution learned while validating the replacement: a mutant that fails to
      **compile** also makes `make <target>` exit nonzero and would therefore
      score as "killed" — a false kill. Confirm any new or retargeted firmware
      mutant builds (exit 0, image produced) before accepting its kill.

    Do **not** let this resolve silently by moving the file verbatim and never
    revisiting it — "verbatim" is the right provenance rule and the wrong
    assurance rule.

    Track the reverse direction too: the child's dedicated ANSELA integrity
    check is broader in scope than the 322's. Confirm whether the 322 should
    gain it (user-owned firmware edit) or whether its existing
    `hw_critical_sfrs_intact` ANSELA masking already covers the same fault.
12. **Plan PIC10F320 entry into parent-only gate infrastructure.** *(New
    2026-07-25.)* Since the split, the parent grew a gate layer the child never
    had. Each needs an explicit decision — extend it to PIC10F320, or record
    why not:

    | Parent mechanism | Target(s) | PIC10F320 question |
    | --- | --- | --- |
    | `test/mutation_policy.sh` | `test-mutation` | central policy; extend, do not fork (§6.6) |
    | `test/check_flash_budget.sh` | `test-flash-budget`, `test-flash-budget-regression` | **Row corrected 2026-07-26 — the original instruction rested on a false premise.** It read "route the 256-word gate through this rather than inlining budget arithmetic in the Makefile". But this script is invoked exactly once — `Makefile:2346`, for the ATtiny13A **ELF**, via `$(SIZE)` — and is ELF/size-command shaped. The **PIC10F322 512-word gate is already inline Makefile arithmetic** parsing XC8's own output (`Makefile:614-725`). An inline 256-word gate would therefore *match* the existing PIC pattern, not deviate from it. Decide explicitly: keep both PIC budgets inline (cheap, consistent, no 322 churn), or teach the shared script a word-parsing mode and migrate the 322 as well. The second option is a 322-affecting refactor and must be scheduled as one, not smuggled in as PIC10F320 integration. |
    | `test/test_strict_tools.sh` | `test-strict-tools` | **Scope corrected 2026-07-26 — the gap is wider than stated.** The inventory covers exactly two recipes today: `test-cbmc` and `analyze-cppcheck`. **No PIC10F322 optional-tool recipe is registered either**, so Phase 4's requirement that "every imported optional-tool recipe uses the parent's central `STRICT_TOOLS`/`$(SKIP)` mechanism" has no enforcing regression for the *existing* PIC lane, let alone a new one. Extend the inventory to both chips' XC8/gpsim/libgpsim recipes, or the Phase-4 requirement is decorative and a `pic320-` recipe with a private early exit will pass review. |
    | `test/test_ci_local_routing.sh` | `test-ci-local-routing` | encode the two-chip `--skip-pic` semantics of §11 |
    | `scripts/release-provenance.sh` | `test-release-provenance` | **Row corrected 2026-07-26 — this is verify-no-change, not work.** The script is entirely target-agnostic: a HEAD-SHA comparison plus a dirty-worktree recheck, with no per-source or per-image knowledge whatsoever. There is nothing to "add PIC10F320 sources/images" to, and the earlier bolded claim that §10 omitted provenance implied a hole that does not exist — retracted. The only real action is to confirm the gate still passes once the new PIC10F320 build steps lengthen the release run's wall-clock window. |
    | `test/test_workload_rebuild.sh`, `test/test_avr_build_rebuild.sh` | `test-workload-rebuild`, `test-avr-build-rebuild` | is there a PIC10F320 rebuild-determinism equivalent, and should there be? |
    | `test/test_stack_bound.sh` | `test-stack-bound`, `test-stack-bound-regression` | most relevant to the fully-inlined 320 `main()`; decide in or out and say why |
    | `test/pic/fw_coverage/` (harness + its own `xc.h`) | `pic-coverage-check-fw` | the merged tree ends up with two firmware-coverage mechanisms and two unrelated `xc.h` shims (parent 1146 B; child `test/equiv/xc.h` 3826 B). Converge them or document the split deliberately. |
13. **Gate the import on image byte-identity.** *(New 2026-07-26 — the cheapest
    strong evidence available, and the plan previously lacked it.)* All three
    preconditions hold: both repositories pin the *same* toolchain (§6.14), the
    child ships three signed v0.9.5 images, and the parent already implements
    fresh-build-versus-committed HEX comparison in
    `scripts/verify-release-images.sh`. So require: build all three variants in
    the merged tree and compare byte-for-byte against the child's
    `release/v0.9.5/bypass_mcu_{cd4053-simple,cd4053-mute,tq2-relay}_pic10f320.hex`.
    Any difference fails.

    This converts "moved verbatim" from a review claim into a machine-checked
    one, and it validates the entire ported Makefile/XC8 recipe in a single
    comparison: a recipe port that silently changes optimization level, `-mdfp`,
    include order, or CONFIG-word emission cannot pass it. Nothing else in the
    plan catches that class of error — the equivalence and lockstep lanes assert
    behaviour, not emitted bytes.

    **Sequencing hazard.** The gate needs working XC8 build rules, which Phase 4
    adds — but §6.11's firmware edit, which deliberately invalidates the
    baseline, is scheduled for Phase 2. As currently ordered the verbatim move
    would never be verified against anything. Resolve one of two ways and record
    which: pull a minimal build-and-compare rule forward into Phase 2 (cheap —
    the child's build recipe is already sitting in the imported tree), or hold
    §6.11's edit until after the Phase-4 gate passes. Prefer the first; it
    verifies the move at the moment the move happens.

    Either way the order is fixed: verbatim move → prove byte-identity → *then*
    the defensive-layer edit as a separately reviewed commit that deliberately
    rebaselines, recording the new expected hashes in that same commit. Do not
    run the two changes together, or neither is verifiable.

    **The gate is known-achievable** *(added by the second 2026-07-26 pass)*, so
    this is not a speculative requirement: the child's own `release.yml` already
    rebuilds every image from tagged source on a clean pinned `ubuntu-24.04`
    runner and fails the release unless the fresh build reproduces the committed
    `SHA256SUMS` byte-for-byte. XC8 output is reproducible across machines given
    §6.14's pinned compiler and DFP; what §6.13 adds is proving it across the
    *ported recipe*.

    **Decide the gate's lifetime, too.** As written, §12's checkbox ("identical to
    the child's `release/v0.9.5/*.hex`") becomes unverifiable at the merged tip,
    for two independent reasons: the baseline images live in
    `_incoming_pic10f320/release/v0.9.5/`, which **Phase 7 deletes** from the
    current tree, and §6.11's firmware edit invalidates them anyway. Pick one:

    - **One-shot gate.** Run it in Phases 2 and 4, record the compared hashes in
      the phase commit messages and in `docs/pic10f320_validation.md`, then retire
      it. Cheapest, and honest — it is a *migration* check, not a standing
      property. State plainly that it cannot be re-run at the tip once the
      baseline is gone.
    - **Standing regression.** Check in an expected-hash file (e.g.
      `test/pic10f320/expected_images.sha256`) that survives Phase 7, wire it into
      `pic320-test-build`, and require any firmware change that moves the hashes to
      rebaseline it in the same reviewed commit. This keeps §6.11-class edits
      visible forever, at the cost of one more file to maintain deliberately.

    This plan recommended the standing regression, because §14.2 records that the
    differential lanes are blind to the hardware-integrity checks and an
    expected-image hash is the one gate that notices *any* change to emitted
    bytes, including that class. **Decided (§15, D4): the one-shot gate**, under
    the merge's governing simplest-option rule. The gate's migration purpose —
    proving the ported XC8 recipe reproduces the child's shipped bytes — is fully
    served either way; what is knowingly given up is the standing watch on emitted
    bytes after Phase 4. §15 records that as the single place where "simplest"
    trades assurance, and promotion to the standing regression stays a one-file
    change if that trade is later judged wrong.
14. **Toolchain-pin equality — verified compatible; recorded so it is not
    re-derived.** *(New 2026-07-26.)* The whole merge rests on one XC8
    installation building both PIC targets, and it does: parent
    `TOOLCHAIN.adoc:43-55` and child `:37-49` name the identical **XC8 V3.10**
    at `/opt/microchip/xc8/v3.10` and the identical **PIC10-12Fxxx_DFP
    v1.9.189** at `/opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189`, with the same
    `-mdfp=.../xc8` subdirectory requirement and the same `PIC_CC=`/`PIC_DFP=`
    overrides. No toolchain conflict exists and none needs resolving.

    The only divergence is precision, not version: the parent pins gpsim
    **0.32.1**, the child writes **0.32.x**. The merged `TOOLCHAIN.adoc` takes
    the parent's exact value.

    Re-verify this checkpoint if either repository re-pins XC8 or the DFP before
    execution. It is the one assumption whose failure would invalidate §6.13 and
    a large part of Phase 4.
15. **Dispose of the child's non-git GitHub assets.** *(New 2026-07-26.)* Phase
    8 covers the README pointer and the archive flip. The following live outside
    the git graph and survive neither the subtree import nor the namespaced
    tags, so each needs a recorded decision:

    - **Open issues and pull requests.** Archiving freezes them read-only in a
      repository the merged project cannot search or reference from its own
      tracker. Migrate them, or close them with a pointer, before archival.
    - **Published GitHub Releases and their uploaded assets.** The *tags*
      migrate as `pic10f320/v0.9.*`; the release pages, their generated notes,
      and any attached binaries do not. Decide whether the six historical
      releases are recreated under the parent, linked from the caveat document,
      or intentionally left reachable only in the archived child.
    - **The release signing key.** `scripts/make-release.sh:637-638` signs with
      `gpg --armor --detach-sign`, and every child release carries a
      `SHA256SUMS.asc`. Confirm both lines were signed with the **same** key. A
      unified release signed under a different key than the archived child
      releases is a trust-continuity break that a user verifying an older image
      can actually observe; if the keys do differ, state it plainly in the first
      unified release notes rather than leaving it to be discovered.
    - **Inbound references.** Anything pinning the child URL — external build
      scripts, forks, and the parent's own stale links catalogued in §4 — needs
      the redirect at archival time.
16. **Verified clean — recorded so it is not re-derived.** *(New — second
    2026-07-26 pass, against parent `ed6ddab` / child `f58d2d5`.)* Each of these
    looked like work and is not. Re-verify only if the named file changes.

    - **Namespaced tags cannot trigger a release.** `release.yml` filters
      `v[0-9]+.[0-9]+.[0-9]+` and `v[0-9]+.[0-9]+.[0-9]+-*` (both repositories,
      identically). Pushing `pic10f320/v0.9.*` to the parent remote matches
      neither pattern, so §9's namespaced import cannot fire six bogus release
      runs. No guard needed; do not add one.
    - **Parent MISRA suppressions cannot leak onto the imported firmware.** Every
      entry in `test/misra_suppressions.txt` is file-scoped
      (`misra-c2012-11.4:src/bypass_mcu_avr_classic.c`, and 17 more in the same
      form), so folding the suppression files cannot silently waive a finding in
      `src/bypass_mcu_pic10f320.c`. The child's zero-deviation position survives
      the merge intact — subject to the strict-tools caveat in §4's
      `MISRA_COMPLIANCE.md` row.
    - **The §4 disposition table is complete.** Checked against the child's
      `git ls-files`: every tracked child path outside `release/v0.9.*` has a row.
      The child tracks no `docs/` directory, no `.claude/` (it is `.gitignore`d on
      both sides), and nothing under `.github/` beyond the two workflows.
    - **§5.1's target inventory is complete** but for `print-%` (a pattern rule
      both Makefiles already implement identically) and
      `_make-serialized-invocation` (internal, present on both sides with
      different bodies — see §5.6's closing bullet).
    - **`AGENTS.md` folds with no loss.** The child copy differs from the parent's
      by a single typo ("musicial"), so the parent copy winning is strictly
      correct. `LICENSE` remains the one genuine content difference, exactly as
      §4's row states.

---

## 7. Phased execution

Work on a dedicated integration branch. Each phase is independently
committable and ends with the existing parent suite plus every newly wired
lane green. Do not delete a child reference implementation merely because the
parent's unrelated tests still pass.

**Minimum coherent merge.** *(Added 2026-07-26 as the concrete mitigation for
§14.11.)* Every phase has a green boundary, but Phases 5–8 are what make the
merge worth doing, so the plan as written implicitly demands all nine before
there is any payoff — which is precisely the shape of work that stalls and then
needs re-auditing. Fix the stopping point in advance: **Phases 0–4 are the
minimum coherent cut.** At the end of Phase 4 the merged tree builds all three
PIC10F320 variants, proves them byte-identical to the child's last signed
release (§6.13), runs every host/target/mutation lane, and holds exactly one
copy of the verified core — while the child repository stays unarchived and
remains the release path. That is a defensible resting state that can be
committed and left indefinitely.

Phases 5–8 (CI integration, release integration, documentation, unified release
and archival) are the payoff, not the prerequisite. If the work must pause,
pause at the Phase-4 boundary and say so in `TODO.md`. Do not pause mid-phase,
and do not pause after Phase 6 — that is the one genuinely bad resting state,
because release machinery would name PIC10F320 images that no CI gate yet
produces.

**Phase 0 — Decisions, audit, and baseline.** Complete §6. Resolve the
three-variant contract, documented ATtiny202 non-release status, aggregate
semantics, mutation topology, first unified version, and full file-disposition manifest.
Also resolve the two checkpoints added 2026-07-25: the §6.11 firmware
defensive-layer decision (which gates what Phase 2 is allowed to move) and the
§6.12 parent-gate-infrastructure decisions (which gate Phases 4–6). Settle the
§4 shared-name harness FOLD/FORK calls and the §5.1 `pic-`/`pic320-` prefix
question here as well — they change target names across three later phases.

Then resolve the three checkpoints added 2026-07-26: §6.13's byte-identity
sequencing (pull a minimal build-and-compare forward into Phase 2, or defer both
it and §6.11's edit to Phase 4 — this decides what Phase 2 can prove); §6.14's
toolchain-pin equality (re-verify only if either repository re-pinned XC8 or the
DFP); and §6.15's non-git GitHub asset dispositions, whose signing-key question
should be answered now rather than discovered at Phase 8. Decide the §11 CI
job-graph shape here too, for the same reason as the prefix question: it changes
job names and `needs` edges in two later phases.

Then resolve the four decisions added by the second 2026-07-26 pass, all of which
change names or files in later phases and are cheap now and expensive later:
§5.6's Makefile **variable** prefix rule (decide it in the same breath as the
§5.1 target prefix — they must agree, and it is an interface change to every
`make print-<VAR>` consumer); §5.7's artifact-directory separation, including
which directory PIC10F320 coverage owns; §5.3's release-image naming call, keep
or migrate; and §6.13's gate **lifetime**, one-shot or standing regression, since
the standing option adds a checked-in hash file that Phase 4 must wire up. Also
run the Principle 8 sweep here: walk the child-only assets once and mark each
"320-specific" or "320-discovered", so Phase 3 folds from a decided list rather
than deciding as it goes.

Record clean parent and child evidence, the three child release image hashes
(§6.9), and the parent base SHA. No import yet.

**Phase 0 is complete. Its output is §15** — the decision record, the captured
baselines and image hashes, and the tool inventory with its one recorded blocker.
Later phases consume §15 rather than re-deciding; where §15 accepts a naming
asymmetry, the deferral is tracked by the `TODO.md` Tier 3 item "Unified naming
scheme across MCU targets and output stages", not by re-opening this plan.

**Phase 1 — Provenance import, inert.** Fetch and verify the pinned child
branch and original signed tags under namespaced refs, then perform a
non-squashed subtree import at `_incoming_pic10f320/` (§9). Nothing builds
from the prefix. **Executed 2026-07-26 — see §15.3 for the merge SHA, the
verbatim-import proof, and the exec-bit gotcha.**
Verify parent tests are unchanged and record the subtree merge
commit. Do not delete historical releases or documentation yet.

**Phase 2 — Relocate and establish host build scaffolding.** The user moves
`_incoming_pic10f320/bypass_mcu_pic10f320.c` to `src/bypass_mcu_pic10f320.c` —
verbatim, unless §6.11 concluded the defensive-layer port fits, in which case
that user-owned firmware edit lands here as a separately reviewed commit on top
of the verbatim move, never folded into it. Relocate PIC10F320-specific host harnesses to
`test/pic10f320/`, create `build_pic10f320/` handling, and wire only the
host-side build/equivalence/actuation/fault/coverage lanes. Update all explicit
dependencies and relative includes, including both firmware harness includes,
the model implementation, host config shim, actuation-to-equivalence reuse,
and fault-to-`xc.h` reuse. Use variant-private outputs.

This is also where the §5.6 variable prefixes and §5.7 directory separation land,
because they are properties of the imported recipes themselves: rename the
chip-specific variables as the recipes arrive rather than after they have been
wired into later phases' aggregates, give PIC10F320 coverage its own directory,
and scope every imported `rm -rf` to PIC10F320 paths before running any of these
lanes — the destructive `coverage-clean` is imported already armed.

Validate `pic320-test-equiv`, `pic320-test-actuation`,
`pic320-test-fault-host`, model/firmware coverage, and the inherited parent
host/formal suites before proceeding. Compare results to the child baseline.

**Phase-2 exit gate (§6.13).** Prove the moved firmware byte-identical to the
child's shipped images before anything else touches it: build the three
variants and compare against
`release/v0.9.5/bypass_mcu_*_pic10f320.hex` from the §6.9 baseline. This
requires pulling a minimal XC8 build-and-compare rule forward from Phase 4 —
do that, or explicitly defer *both* this gate and §6.11's firmware edit to
Phase 4 and record the choice. If §6.11's edit is landing, it lands only after
this gate has passed, as its own reviewed commit carrying the rebaselined
hashes.

**Phase 3 — Fold shared model/formal/MISRA assets.** Migrate the unique
corrupt-state property, preserve both host assurance roles, repair/verify the
KLEE recipe, and then delete the vendored core and superseded formal/MISRA
copies. Re-run host, formal, coverage, and mutation baselines against the sole
`src/bypass_pure.c`. Fresh MISRA analysis must have zero unwaived findings;
only newly demonstrated, documented, file-scoped suppressions may be added.

Land the Principle 8 promotions in this phase, from the Phase-0 list: the shared
line-coverage gate over `src/bypass_pure.c` (with its own floor, distinct from the
parent's oracle floor) and the cross-chip gpsim "Known gaps" documentation. Both
are folds that *add* parent coverage, so they belong with the rest of the
shared-asset work rather than in the PIC10F320 lanes — and the coverage gate must
be wired before the vendored core is deleted, or the only thing measuring the real
core disappears between two green commits.

**Phase 4 — Build and target validation.** **Executed 2026-07-26 — see §15.7**
**for the results, the FOLD/FORK dispositions and the defects it exposed.**
Add hardened three-variant XC8
rules, fake-XC8 regressions, generic CONFIG verification, CLI gpsim, and
PIC10F320-specific libgpsim fault/lockstep/I/O lanes. Reuse the parent soak
driver/timing contract. Port every false-pass fix in §6 and require strict tool
availability for authoritative aggregates. Every imported optional-tool recipe
uses the parent's central `STRICT_TOOLS`/`$(SKIP)` mechanism rather than a
private successful early exit. Validate at minimum:

```
make pic320
make pic320-test-build
make pic320-analyze STRICT_TOOLS=1
make pic320-test-variants STRICT_TOOLS=1
make pic320-test-target-variants STRICT_TOOLS=1
make pic320-test-soak PIC320_SOAK_DURATION_MS=<short-valid-test-duration>
make pic320-test-mutation MUTATION_ALLOW_SKIP=0 STRICT_TOOLS=1
```

The all-variant and target aggregates independently require exactly three
unique supported variants and all expected PASS sentinels. Re-run the §6.13
byte-identity comparison in this phase against whichever baseline is current —
the child's v0.9.5 images, or the rebaselined hashes if §6.11's firmware edit
has landed. The hardened build rules added here are exactly the class of change
that can silently alter emitted code, so the comparison is worth repeating
after them even if Phase 2 already ran it. Verify `make clean` removes all
generated PIC10F320 files.

**Phase 5 — Normal CI and aggregate integration.** Add host-only PIC10F320
checks to `test`/`test-long` only if they preserve those aggregates' existing
tool contract. Add a strict full-tool hosted PIC10F320 job (or two-chip PIC
matrix) covering every unique child layer and fail-closed mutation. Update
artifacts, job dependencies, local CI, tool assertions, and skip semantics.
Optionally add `test-all-targets` as the explicit full-tool aggregate.
**Executed 2026-07-26 — see §15.9** **for the results, the declined
`test-all-targets`, and the skip-guard defect the extended strict-tools
inventory exposed.**

**Phase 6 — Release integration.** *(Executed 2026-07-27 — see §15.10 for the
results, the real-data global-omission negative test, and the two deliberate
omissions.)* Implement one canonical expected-product
set, exactly three PIC10F320 release images, the dedicated build/reproduction
directory, all release-script metadata and validation, three per-variant
24-hour-equivalent soaks, strict target/mutation gates, generated documentation,
and tag-workflow reproduction. Add negative tests showing that global omission
of PIC10F320 from all observed image sets fails. Keep the development-only
ATtiny202 lane outside the canonical release set and scope all release claims
accordingly before this phase is green.

**Phase 7 — Documentation and incoming-tree cleanup.** Land the caveat and
validation documentation, repair historical changelogs, update every public
support/toolchain/design/release statement, and merge useful child technical
content. Use `git ls-files -- _incoming_pic10f320` as the disposition checklist.
Only after all content has been moved, merged, or intentionally discarded,
remove the residual prefix and verify no tracked `_incoming_pic10f320/` path
remains. Historical release trees remain available through imported history
and namespaced tags.

**Phase 8 — Unified release and child archival.** Cut and independently verify
the first unified release, preferably `v0.10.0`. Then update the child README
with a stable pointer to the merged project and archive the child repository.
Do not archive it before the unified release succeeds; until then it remains
the operational fallback.

---

## 8. Documentation: the single caveat

Create `docs/pic10f320_special_case.md` as the **one authoritative statement
of the architectural/assurance caveat**, seeded from the child's existing
"Relationship to the parent project" prose. It must state, once:
- 256-word flash (half the 10F322) → the pure/result-struct
  architecture doesn't fit → logic is inlined into `main()`.
- The parent targets compile the verified core into shipping firmware;
  PIC10F320 retains an inlining seam. Equivalence and real-HEX lockstep against
  that same core, host actuation-sequence tests, and host/target fault injection
  mitigate the seam but do not make the architecture identical.
- PIC10F320 is supported and release-gated, but remains the constrained
  exception rather than evidence that the reference architecture fits 256
  words.

Everywhere else links here instead of re-explaining:
- `README.md` — a short "Targets" table row for PIC10F320 with a
  one-line "constrained; see special-case doc" and a link.
- `DESIGN_DOCUMENTATION.adoc` — qualify shared-core claims, identify
  PIC10F320 as the most constrained target, include current measured resource
  use, and link rather than duplicating the caveat. Verified 2026-07-26: the
  file currently contains **zero** PIC10F320 mentions, so this is mostly
  addition rather than correction — with one exception that is a direct
  contradiction and must be rewritten. `:686-688` states "Adding a fourth target
  means adding a fourth shell plus a pin map, and reusing the core and all three
  output drivers unchanged." PIC10F320 is precisely a target that reuses
  *neither* the core nor the drivers, and it makes the arithmetic wrong too
  (five targets; four shells plus one inlined implementation). The "Multi-MCU
  Architecture" section — which per §4's audit note now carries the rationale
  inherited from the deleted phase documents — is where the structural exception
  needs its cross-link.
- `release/<ver>/README.md` + `MANIFEST.md` — mark PIC10F320 images as
  "constrained target; equivalence/lockstep validated" and use a stable
  repository URL to the caveat. GitHub release notes are generated from the
  manifest, so the label must be present there, not only in the README.
- `docs/pic10f320_feasibility.md` — retain it as historical evidence that the
  modular PIC10F322 implementation does not fit, but replace the current
  top-level "unsupported" status with a link explaining the separately
  inlined supported implementation.

The failure mode to avoid: sprinkling half-caveats across many files
where one drifts out of date. One doc, many links.

"One caveat" does **not** mean "one PIC10F320 document." Pinout, CONFIG,
clock/timer/WDT, power, resource use, test commands, simulator limitations,
flashing, and release reproduction remain in the relevant design, toolchain,
validation, and release documentation. Those documents link to the caveat for
the assurance comparison rather than restating it.

---

## 9. Git history and tags

- Use a **non-squashed subtree import** over `merge
  --allow-unrelated-histories` because the inert temporary prefix makes the
  disposition work tractable while retaining the exact child graph. The
  subtree's advantage is organization and provenance reachability, not
  transparent ordinary `--follow` behaviour.
- Pin the import instead of fetching a moving `main`. The currently audited
  child HEAD is `f58d2d57ef5a72637fbc032a3f3676f249409b68` (re-pinned
  2026-07-25; see §6.1 for why the earlier `915ee03` / `v0.9.5` pin was
  abandoned).
- Preserve all original signed annotated child tag objects under namespaced
  refs. Do not recreate them, because recreation loses the original signed
  object identity. A representative sequence, after the user confirms the
  remote/path and installs `git subtree`, is:

  ```sh
  CHILD_URL=../pic10f320-bypass-firmware
  CHILD_SHA=f58d2d57ef5a72637fbc032a3f3676f249409b68

  git subtree -h   # confirmed present: git 2.43.0, /usr/lib/git-core/git-subtree
  git fetch --no-tags "$CHILD_URL" \
    refs/heads/main:refs/remotes/pic10f320/main
  test "$(git rev-parse refs/remotes/pic10f320/main)" = "$CHILD_SHA"
  git fetch --no-tags "$CHILD_URL" \
    'refs/tags/*:refs/tags/pic10f320/*'
  git tag -v pic10f320/v0.9.5
  git subtree add --prefix=_incoming_pic10f320 \
    refs/remotes/pic10f320/main
  ```

  Verify all six tags, not only the representative command shown.
- The imported graph and normal blame retain provenance, but ordinary
  `git log --follow -- src/bypass_mcu_pic10f320.c` may stop at relocation or
  the subtree merge. Document `git log -m --follow -- <path>` and, if needed,
  a two-stage path lookup. Seamless ordinary `--follow` would require history
  rewriting and would sacrifice original commit/tag identities, so it is not
  the chosen tradeoff.
- The subtree add is a merge commit. Record its SHA for rollback and retain the
  unarchived child repository as an operational fallback until Phase 8.

---

## 10. Release and versioning

*Implemented 2026-07-27 — see §15.10. The canonical-set, image-naming,
classifier, soak and reproduction bullets have landed; the `CHANGELOG.md`
repair, the child `release/v0.9.*` disposition and the `v0.10.0` tag itself are
Phases 7 and 8.*

- Parent `release/<ver>/` already mixes MCU images. Exactly **three**
  PIC10F320 images join each future unified release: `cd4053-simple`,
  `cd4053-mute`, and `tq2-relay`; no historical `tmux4053-*` image returns.
- Makefile variables expose the canonical complete product basename set. The
  release script, checksum manifest, committed directory, fresh rebuild, and
  verifier must each agree with that independent expected set. Deleting every
  PIC10F320 image from all three observed sets must still fail. Confirmed
  2026-07-25 that this is genuinely unbuilt: the parent Makefile has no
  `RELEASE_IMAGES`-style variable, and `scripts/verify-release-images.sh`
  derives its set by globbing (`images=("$dir"/*.hex)`, `:50`), which is exactly
  the three-identically-incomplete-sets hole of §14.8. Extended 2026-07-26:
  `scripts/make-release.sh` globs too (`sha256sum ./*.hex`, `:454`), so the
  *producer* of the checksum manifest has the same hole as the verifier. Fixing
  only the verifier leaves the generating side free to emit an incomplete set
  that the verifier then dutifully confirms.

  **The delivery mechanism already exists** *(second 2026-07-26 pass)* — do not
  invent a new one. Both Makefiles implement `print-%`, and
  `scripts/make-release.sh:155` already reads Makefile truth through
  `mkv() { make -s print-"$1"; }` for the variant list, device names and build
  directories. So the canonical set is a new Makefile variable consumed by
  `make -s print-<VAR>` in `make-release.sh`,
  `scripts/verify-release-images.sh`, and `test/test_release_images.sh` alike.
  Name it under the §5.6 prefix rule, and remember that adding it to the
  `print-`-consumed surface makes it an interface: the negative test of §6 must
  assert the *verifier* fails when the variable and the directory disagree, not
  merely that the variable exists.
- **Image basenames carry three conventions** unless §5.3's migration option is
  taken *(second 2026-07-26 pass)*. Whichever way that decision goes, the
  canonical set is where it becomes concrete, and `scripts/make-release.sh`'s
  image→MCU classification must recognize the `bypass_mcu_*` prefix explicitly —
  the "never fall through to generic AVR metadata" requirement below is exactly
  this, and a prefix the classifier has never seen is the likeliest way to trip it.
- **Release provenance.** `scripts/release-provenance.sh` and its
  `test-release-provenance` gate are parent-only, but **corrected 2026-07-26**:
  they are target-agnostic — a HEAD-SHA comparison plus a dirty-worktree
  recheck — and need no PIC10F320 knowledge at all. The earlier instruction that
  they "must learn about PIC10F320 sources and images" is withdrawn; see the
  corrected §6.12 row. The only action is to confirm the gate still passes once
  the release run grows the new PIC10F320 build and soak steps.
- `scripts/make-release.sh` must explicitly handle PIC10F320 DFP/header
  prerequisites, three builds, structural IHEX and CONFIG validation, strict
  all-variant target/mutation evidence, three soak combinations, 256-word
  usage figures, image-to-MCU classification, programmer commands,
  reproduction instructions/directories, caveat links, and generated commit
  text. A PIC10F320 name must never fall through to generic AVR metadata.
  Signing-key continuity across the two release lines is a §6.15 decision, not
  an implementation detail of this script.
- Past child `release/v0.9.*` are **not** back-filled (numbering
  collision, and they predate unification). Delete them from the merged tip
  after disposition while preserving them in imported history and namespaced
  signed tags.
- The first unified tag is preferably **`v0.10.0`**. Both lines now stop at
  v0.9.5 (parent `eec7b9f`, 2026-07-18; child signed tag `915ee03`), so the
  unified tag must exceed v0.9.5, not v0.9.4. Its changelog records imported
  child HEAD `f58d2d5...`, the `v0.9.5` tag commit `915ee03...`, and source tip
  `331f90f...`.
- `CHANGELOG.md`: one file, one timeline; use a clear "PIC10F320
  (constrained target)" sub-lane within each entry rather than a
  separate changelog. First repair both existing timelines so historical
  v0.9.4/v0.9.5 work is not misreported as new unified-release work.
- ATtiny202 is development-only/non-release. Keep its normal CI coverage, omit
  its images and soak evidence from the canonical release contract, and scope
  "all targets/every MCU" language to release-supported targets.

---

## 11. CI

*Implemented 2026-07-26 — see §15.9. Everything below except the `release.yml`
bullet has landed; that bullet is Phase 6.*

- Keep the routine host `verify` job tool-independent. It may run
  `pic320-test-host`, but it must not acquire an accidental XC8/gpsim
  dependency through top-level `test`.
- Add a strict PIC10F320 full-tool job or matrix leg with XC8 3.10, DFP
  1.9.189, `proc/pic10f320.h`, gpsim, gpsim-dev/libgpsim, glib, cppcheck,
  and the required host coverage tools. Run build/budget, analysis/MISRA,
  equivalence, actuation, host fault, CONFIG, model/firmware coverage, CLI
  gpsim, and all-variant fail-closed target fault/lockstep/I/O gates.
- Extend the existing full-tool PIC mutation step to the combined relevant set
  and retain `MUTATION_ALLOW_SKIP=0` for pushes, schedules, and manual dispatches.
  Pull requests remain off the minutes-long mutation path. The separate non-PIC
  stress job may continue its explicit partial mode, but its skipped PIC mutants
  are diagnostic output, never authoritative PIC mutation evidence.
- Upload `build_pic10f320/*.hex` as a separately named artifact and update all
  downstream `needs` relationships if PIC10F320 is a separate job. **This is a
  whole-DAG decision, not a bookkeeping edit** *(clarified 2026-07-26)*: the
  parent workflow has five jobs and **four of them — `verify`, `attiny202`,
  `build-matrix`, and `stress` — all declare `needs: pic`**, so `pic` is the
  gating job for the entire repository. Adding a second PIC chip is therefore a
  choice between extending the existing `pic` job (serial; lengthens the
  critical path for all four dependents) and adding a sibling `pic320` job
  (parallel; but then decide explicitly whether those four dependents gate on it
  too, or whether a PIC10F320 failure is allowed to let the rest of CI report
  green). The child workflow has only two jobs (`verify`, `stress`), so nothing
  on the child side informs this. Settle it in Phase 0 with the runtime tradeoff
  stated. **Decided (§15, D3): extend the existing `pic` job.** No sibling job and
  no `needs` edits, so all four dependents gate on PIC10F320 automatically; the
  accepted cost is the full PIC10F320 lane on their critical path. Splitting later
  is mechanical if CI wall-clock becomes binding.
- `release.yml` asserts the PIC10F320 header, rebuilds into a private fresh
  directory, passes that directory and the canonical set to verification, and
  reruns strict target and mutation gates before publication.
- `scripts/ci-local.sh` mirrors both PIC lanes. Document whether `--skip-pic`
  skips both and make its control flow consistent with `STRICT_TOOLS=1`.

---

## 12. Definition of done

Several items below say "has a recorded decision". Those decisions are recorded —
§15 holds them, as of 2026-07-26 — so what remains for each is the
*implementation*, and the checkbox stays open until the merged tree matches the
decision. Where §15 accepted a naming asymmetry, the accompanying `TODO.md` item
is part of the record, not a substitute for it.

- [ ] Global Make directives have a per-directive disposition (§5.8): the child's
      bare `.NOTPARALLEL` is **not** imported and
      `test-make-safe-parallel-probe` still passes, imported recipes were
      re-checked under the parent's `.DELETE_ON_ERROR`, and `PROJECT_MAKE` plus
      the parent-only exports resolve to one definition each.
- [ ] The imported graph is pinned to the recorded child SHA (`f58d2d5...`, not
      the superseded `915ee03...`), all six original signed tags are verifiable
      under `pic10f320/v0.9.*`, and provenance lookup instructions document
      `git log -m --follow`.
- [ ] The §6.11 PIC firmware defensive-layer divergence is resolved as measured
      2026-07-26: **exact TRISA is ported** to all three PIC10F320 variants by
      the user (+1 word each; 220/241/244 of 256), landing after the Phase-2
      byte-identity gate as its own rebaselining commit, with
      `test/fault/fw_fault_harness.c`, `test/run_mutation_tests.sh` and
      `test/pic/test_fault_pic.cc` updated alongside; and **the output-latch
      match is documented as omitted** in `docs/pic10f320_special_case.md`
      (does not fit: cd4053-mute over by 5 words, tq2-relay by 3) and reflected
      in the mutation topology. The reverse ANSELA question has an answer too.
- [ ] Every §6.12 parent-only gate has a recorded PIC10F320 decision: mutation
      policy, flash budget, strict-tools inventory, ci-local routing, release
      provenance, rebuild determinism, stack bound, and firmware-coverage /
      `xc.h` convergence.
- [ ] The strict-tools inventory covers optional-tool recipes for **both** PIC
      chips, not only the newly added ones (§6.12), and the flash-budget
      disposition — inline for both chips, or the shared script for both — is
      recorded and implemented consistently rather than left mixed.
- [ ] The CI job-graph decision is recorded and implemented: `pic320` extends the
      existing `pic` job or is a sibling, and whether `verify`, `attiny202`,
      `build-matrix`, and `stress` gate on it (§11).
- [ ] Each §4 shared-name harness regression (`test_pic_build.sh`,
      `test_make_serialization.sh`, `test_gpsim_wrappers.sh`,
      `test_release_images.sh`, `test_soak_timing.sh`, `test_target_matrix.sh`,
      `test_lockstep_progress.sh`) has a recorded FOLD-or-FORK disposition, and
      no fold silently added a tool dependency to the default `test` aggregate.
- [ ] Every colliding Makefile **variable** has a recorded disposition (§5.6):
      chip-specific names carry the prefix chosen alongside §5.1's target prefix,
      the shared-tool allowlist is explicit, no chip inherits the other's
      `PIC_FLASH_WORDS` / `FW_BASE` / `COVERAGE_MIN` / soak durations, and every
      `make print-<VAR>` consumer in `scripts/` and `.github/workflows/` was
      updated with the rename.
- [ ] No PIC10F320 lane writes into, or `rm -rf`s, a shared artifact directory
      (§5.7). `coverage/` belongs to the parent lanes; `pic320-coverage-clean` and
      `pic320-clean` touch only PIC10F320 paths; `/.make.lock` remains a single
      shared inode.
- [ ] The release-image naming decision of §5.3 is recorded — keep the child
      basenames and document the three-convention asymmetry, or migrate at
      `v0.10.0` — and `scripts/make-release.sh`'s image→MCU classifier recognizes
      whichever prefixes survive.
- [ ] Exactly one `src/bypass_pure.c`, formal property set,
      `test/model_step.h`, `misra.json`, and `misra_rules.txt` remains; no
      vendored model copy survives.
- [ ] Principle 8 was applied per child-only asset, and the two known cases
      landed as *promotions*, not 320 sections: a shared line-coverage gate over
      `src/bypass_pure.c` with its own floor (the child's 95% over the real core,
      distinct from the parent's 90% over the independent oracle), and the
      cross-chip gpsim "Known gaps" documentation covering both PIC chips.
- [ ] Shared host/formal tests retain both independent-oracle and direct-core
      assurance where justified, include the concrete corrupt-state check, and
      the KLEE target links and executes the real pure core.
- [ ] PIC10F320 equivalence and lockstep compile/link `src/bypass_pure.c`
      directly with the parent host config shim; no stale implementation can be
      selected through include-path ordering.
- [ ] PIC10F320 firmware is the reviewed child source moved verbatim by the
      user, except for any separately reviewed user-owned source comments.
      Firmware images for every pre-existing target are byte-identical to their
      pre-merge baselines unless an independently approved change says otherwise.
- [ ] The three PIC10F320 images built in the merged tree are byte-for-byte
      identical to the child's `release/v0.9.5/*.hex` (§6.13), proven *before*
      any §6.11 firmware edit lands; if that edit landed, the rebaselined hashes
      are recorded in its own separate commit.
- [ ] §6.13's gate has a recorded **lifetime**: either retired after Phase 4 with
      the compared hashes preserved in the phase commits and
      `docs/pic10f320_validation.md`, or kept as a standing expected-image-hash
      regression that survives Phase 7's deletion of the imported baseline.
- [ ] The moved firmware's self-referential comments are swept in one reviewed,
      comment-only commit (§4: `:6-8` header note plus `:68`, `:74`, `:321`,
      `:640`, `:657`), separately from §6.11's rebaselining edit, and the images
      are confirmed byte-identical across it.
- [ ] Exactly three supported PIC10F320 variants build into
      `build_pic10f320/`, pass structural IHEX checks, fit the 256-word budget,
      and contain exact emitted CONFIG word `0x389E`.
- [ ] Empty, duplicate, incomplete, or unknown variant matrices fail every
      authoritative all-variant aggregate; each target layer requires its exact
      expected PASS markers/check counts and propagates simulator/tool failure.
- [ ] `pic320-test-host`, selected/all-variant development tests,
      `pic320-test-target-variants`, coverage, analysis, soak, build regression,
      and mutation targets pass under the documented tool policy.
- [ ] Default `test` / `test-long` remain compatible with their documented
      tool-independent semantics. Any full-tool all-target aggregate is
      explicitly named and documented.
- [ ] Push, scheduled, and manually dispatched full-tool CI plus release CI run
      the combined PIC10F322/PIC10F320 mutation set with
      `MUTATION_ALLOW_SKIP=0`; PR omission is explicit, and skipped PIC tools in
      a partial non-PIC stress run cannot produce an authoritative pass.
- [ ] Soak duration parsing rejects zero, overflow/wrap, and sub-minimum release
      values. Release creation runs one isolated 24-hour-equivalent soak for
      each of the three PIC10F320 variants and records evidence.
- [ ] One canonical expected-product set requires all three PIC10F320 images.
      Removing them from committed files, checksums, and fresh builds still
      fails a regression test.
- [ ] Local release creation and tag CI handle PIC10F320 build prerequisites,
      validation, evidence, image metadata/programmer commands, reproduction,
      checksums, caveat links, and publication without generic-AVR fallthrough.
- [ ] `make clean` and `clean-tests` remove every PIC10F320 build/test/coverage
      artifact; concurrent variant invocations use private outputs and pass.
- [ ] Fresh static analysis has zero unwaived findings across all targets. Any
      PIC10F320 deviation is justified, documented, and scoped to its file;
      existing parent documented deviations are not mislabeled as zero.
- [ ] The first unified release version is greater than both historical lines
      (preferably `v0.10.0`), and parent/child changelogs accurately classify
      all v0.9.x work before the unified entry.
- [x] ATtiny202's development-only/non-release status is explicit and
      implementation, canonical image set, soak claims, and documentation agree.
- [ ] `docs/pic10f320_special_case.md` is the sole assurance-caveat narrative;
      README, design, feasibility, validation, toolchain, MISRA, TODO, release,
      and manifest content is technically complete, links to it, and does not
      imply architectural parity.
- [ ] Every stale cross-project reference has a recorded disposition, including
      the two the first audit missed (§4): `CHANGELOG.md:233-234`
      preserve-as-history or annotated, and `TODO.md:279` re-framed from an
      external-project caveat into a tracked cross-target task.
- [ ] The child's manual-sync contract survives the merge as a promoted,
      `src/`-repointed cross-target checklist (§14.3), and the child README's
      `## Provenance` claims are rewritten rather than merged forward.
- [ ] The child's non-git GitHub assets have recorded dispositions (§6.15): open
      issues and pull requests, published release pages and their assets, the
      release signing key's continuity, and inbound URL references.
- [ ] No tracked `_incoming_pic10f320/` path or obsolete child badge/link
      remains at the merged tip; all intentionally discarded material remains
      recoverable through imported history/tags.
- [ ] A green unified release has been independently verified before the child
      repository receives its pointer and is archived.

---

## 13. Rollback

Perform the work on a dedicated integration branch from a recorded parent base.
Before publication, restarting that branch from the base may be safer than
constructing a public revert chain.

After publication, phases are dependent and must be reverted newest-to-oldest;
reverting an early relocation while later build/release commits remain can
leave dangling paths. The subtree-add commit is a merge and requires:

```sh
git revert -m 1 <phase-1-subtree-merge>
```

Conflicts are still possible, so "independently committable" does not mean any
phase can be reverted in arbitrary order. Namespaced tag refs are not removed by
commit reverts and must be retained or removed as a separate intentional
provenance decision.

The child repository remains unarchived and operational until the first green
unified release. If that release fails, fix or roll back the integration while
the child remains the release fallback; do not archive and then rely on
unarchiving as the normal rollback path.

---

## 14. Residual risks

1. **Reference-grade dilution.** The parent's value is its clean "fully
   verified" story; PIC10F320 is a documented exception. Mitigated by
   §8's single-caveat discipline — but it is an ongoing editorial
   burden, not a one-time task.
2. **Inlining-seam regression.** PIC10F320 manually instantiates behaviour that
   other targets compile from the core. Direct shared-core equivalence,
   real-image lockstep, actuation, fault, and mutation gates reduce but do not
   erase that maintenance risk. Any shared behaviour/output-stage change must
   make the PIC10F320 differential lanes fail until deliberately reconciled.

   This is already concrete rather than hypothetical: §6.11 records a live
   defensive-layer divergence that opened in the ten days between drafting this
   plan and reviewing it. Note *which* lane would have caught it — the
   equivalence and lockstep lanes compare debounce/toggle behaviour and are
   blind to SFR-integrity checks; only the per-target fault lanes touch that
   class, and those are forked per firmware by design (§1 non-goals). So for
   hardware-integrity checks specifically, the differential gates are **not** a
   safety net, and the §14.3 human checklist is the only control.
3. **Forked harness rot.** Lockstep/mutation/fault stay per-target;
   co-location makes drift *visible* but does not prevent it. A
   cross-target review checklist (touch a shared property → check both
   PIC harnesses) is the human control.

   **That checklist already exists — do not rebuild it, and do not let the merge
   delete it.** *(Found 2026-07-26.)* The child README's `## Manual-sync
   contract` (`:137-156`) is a maintained table mapping every shared surface to
   its inlined PIC10F320 counterpart: `PRESSED_THRESH`, `RELEASE_THRESH`,
   `debounce_integrate()`, `debounce_step()`, `debounce_init_context()`, all
   three output stages, and the unified analog-switch drive polarity — plus an
   explicit statement of what is deliberately *not* shared (pin map, CONFIG
   word). §4's `README.md | MERGE` row would quietly fold it away as duplicated
   prose. Instead **promote** it into `docs/pic10f320_special_case.md` (or the
   validation document) with the "Parent source" column repointed from the dead
   vendored paths to `src/`, and add the §6.11 hardware-integrity checks as a
   row — that is exactly the class §14.2 identifies as having no automated
   differential gate, so it is the class most in need of a human checklist entry.
   The merge is the moment to inherit this control, not to reinvent it later.
4. **Near-limit flash use.** The latest child release recorded up to 243/256
   words. Pinning XC8/DFP, parsing fresh size output, cleaning failed artifacts,
   and enforcing the budget on every variant remain release-critical.
5. **Tool/runtime expansion.** Full PIC10F320 assurance requires XC8, DFP,
   gpsim/libgpsim, host coverage, analysis, formal, mutation, and long soak
   lanes. Separating host and full-tool aggregates limits routine friction, but
   hosted CI capacity and pinned-tool availability remain operational risks.
6. **Makefile mass.** Parent Makefile is already ~127 KB; PIC10F320
   targets grow it. Acceptable, but a future factor-into-includes pass
   may be worth its own task.
7. **Two PIC chips, near-name harnesses — and near-name variables.** `test_*_pic.cc`
   for 322 vs 320 differ enough that an edit to the wrong copy is easy. Directory
   separation + distinct `pic-`/`pic320-` target prefixes are the guard.

   The same hazard applies to the Makefile variables of §5.6 and is permanently
   worse there, because a mis-scoped variable produces no compile error and no
   failing test — it produces a *passing* one. `PIC_FLASH_WORDS` is the sharp
   example: the wrong value makes an over-budget 256-word image pass a 512-word
   gate. Consistent prefixes and the explicit shared-tool allowlist are the
   standing control, and any future PIC-shaped variable added without a prefix
   re-opens the hazard.
8. **Release-set drift.** A generic three-way equality check can validate three
   identically incomplete sets. The independent Makefile-owned canonical set
   and global-omission regression are permanent controls, not one-time merge
   tasks.
9. **History-query complexity.** Preserving exact commits and signed tag
   objects means accepting that ordinary `git log --follow` may not cross the
   subtree merge. Documented `-m --follow`, namespaced tags, and the archived
   child repository are the provenance controls.
10. **Existing parent release scope.** ATtiny202 is explicitly development-only
    and remains in normal CI while release creation excludes it. Preserve that
    boundary so PIC10F320 integration does not reintroduce ambiguous "all
    targets" claims.
11. **Plan staleness across two moving tips.** This plan is itself an artifact
    of the split it is trying to end: while it sits unexecuted, both
    repositories keep moving and keep independently converging on the same
    fixes. The 2026-07-25 review found four resolved blockers, one new blocker,
    and two now-byte-identical files that had been listed as work. Every
    additional week of delay costs another audit. Mitigations: the "Plan
    currency" header records the tips each claim was verified against;
    §6.1's pin is a decision to re-take, not a constant; and the honest
    conclusion is that the cheapest version of this merge is the one executed
    soonest.

---

## 15. Phase-0 decision record

Settled 2026-07-26 against parent `5180881` / child `f58d2d5`. §7's Phase 0
requires these to be recorded rather than decided as execution goes; this section
is that record.

**Governing rule for this merge: take the simplest, smallest-change option
wherever the plan offered a choice.** The merge's job is to end the split, not to
fix the naming debt the split exposed. Every naming asymmetry noted below is
therefore *accepted, documented, and deferred* to the TODO item "Unified naming
scheme across MCU targets and output stages" (`TODO.md`, Tier 3), which is the
single place the cross-cutting redesign is tracked. Do not re-litigate these
individually while executing; do not quietly "improve" one of them mid-phase,
because a partial unification is worse than either endpoint.

### 15.1 Decisions

| # | Question | Decision | Consequences to implement |
| --- | --- | --- | --- |
| D1 | §5.1/§5.6 lane prefix | **Keep `pic-` = PIC10F322**; new lane is `pic320-` with `PIC320_*` variables. The 322 lane is not renamed. | No churn on known-good 322 targets and no interface break for existing `make print-PIC_*` consumers. Accepts the asymmetry §5.1 flags: `pic-` silently means "the other PIC". Because `PIC_*` stays 322, §5.6's rule reads "anything chip-specific and new gets `PIC320_`", and the shared-tool allowlist in §5.6 stays exactly as written. |
| D2 | §5.3 release image basenames | **Keep the child basenames** (`bypass_mcu_{cd4053-simple,cd4053-mute,tq2-relay}_pic10f320.hex`). No migration at `v0.10.0`. | No published-name break, and §6.13's comparison can key on filename. Two obligations follow and are not optional: (a) `scripts/make-release.sh`'s image→MCU classifier must recognize the `bypass_mcu_` prefix explicitly, or a PIC10F320 image falls through to generic AVR metadata (§10); (b) the release `README.md`/`MANIFEST.md` must state the three-convention asymmetry rather than leave it to be inferred. |
| D3 | §11 CI job graph | **Extend the existing `pic` job** to build and validate both chips serially. No sibling job, no `needs` edits. | Simplest DAG, one XC8 install/cache restore, and `verify`/`attiny202`/`build-matrix`/`stress` keep gating on PIC10F320 for free because they already declare `needs: pic`. Cost: the full PIC10F320 lane lands on the critical path of all four dependents. Revisit only if CI wall-clock becomes the binding constraint — splitting later is a mechanical change, whereas choosing the split now would force the gating question in §11 immediately. |
| D4 | §6.13 gate lifetime | **One-shot migration check.** Run the byte-identity comparison at the Phase-2 exit gate and again in Phase 4, record the compared hashes in both phase commit messages and in `docs/pic10f320_validation.md`, then retire it. No checked-in expected-hash file. | Nothing new to maintain, and the gate's *purpose* — proving the ported XC8 recipe reproduces the child's shipped bytes — is fully served. **This is the one place the simplest option costs assurance, and the cost is named in §14.2:** the equivalence and lockstep lanes are blind to the hardware-integrity checks, so after retirement nothing at the merged tip watches emitted bytes. Recorded as a deliberate, revisitable trade; promoting it to the standing regression later is one file plus one `pic320-test-build` prerequisite. |

Defaults taken without a separate question, on the same simplest-option rule.
Each is cheap to reverse and none changes a name outside PIC10F320:

- **§5.7 coverage directory** — PIC10F320 coverage lives at
  `build_pic10f320/coverage/`, a subtree of the directory §3 already mandates,
  rather than a new top-level `coverage_pic10f320/`. One `.gitignore` entry
  (`build_pic10f320/`) covers build *and* coverage artifacts, and scoping the
  imported `rm -rf` becomes trivially correct because every PIC10F320 output is
  under one root. `coverage/` stays exclusively the parent lanes'.
- **§6.12 flash budget** — the 256-word gate is **inline Makefile arithmetic**
  parsing XC8's own output, exactly mirroring the existing PIC10F322 512-word
  gate (`Makefile:614-725`). `test/check_flash_budget.sh` stays ELF/`$(SIZE)`-
  shaped and untouched, and the 322 lane is not refactored. This is the "keep
  both PIC budgets inline" branch of that row, chosen for consistency and zero
  322 churn.
- **§4 `LICENSE`** — the parent's file is kept **unchanged**
  (`Copyright (c) 2026 matt-garman`); the child's copy is dropped. Flagged rather
  than silently defaulted, per that row: every source file on both sides says
  `Copyright (c) Matthew Garman`, so the parent's `LICENSE` is the outlier
  against its own sources. Changing it is a one-line edit whenever the intended
  holder string is confirmed; it is not merge work and does not gate any phase.
- **§6.12 strict-tools inventory** — still extended to both chips' optional-tool
  recipes, as that row requires. This is not a naming choice and the simplest-
  option rule does not reach it: without it, Phase 4's `STRICT_TOOLS` requirement
  has no enforcing regression for either PIC lane.

### 15.2 Baseline evidence (§6.9)

Captured 2026-07-26T21:54Z from clean worktrees (both repositories reported zero
modified tracked paths).

```
parent base SHA : 5180881e9592ec9b1b822fd3a4334c9d41f2b34f
child HEAD      : f58d2d57ef5a72637fbc032a3f3676f249409b68   (== the §6.1 pin)
parent 'make test' : EXIT=0   ("all fast pre-hardware tests passed";
                               golden-model line coverage 99.35%, floor 90%)
child  'make test' : EXIT=0   ("all PIC10F320 validation complete",
                               variant cd4053-simple; firmware line coverage
                               80/84 executable lines, 4 allowlisted)
```

Child `release/v0.9.5` image hashes — the §6.13 byte-identity baseline. Verified
equal to the committed `SHA256SUMS` in that directory:

```
26531d3408a75297656d722699a1ffafdc47de376af6b4d2aa62b303c6713ca8  bypass_mcu_cd4053-simple_pic10f320.hex
7709a3979b9103411b1f2e0c892d2291e1c232b5033344bd645ae289ac55649f  bypass_mcu_cd4053-mute_pic10f320.hex
b77e21221b8a94788781b2d1df6a66e0487317cb215d5d540c5582db2a47c4e2  bypass_mcu_tq2-relay_pic10f320.hex
```

### 15.3 Phase 1 — executed 2026-07-26

Integration branch `pic10f320-merge`, based on parent
`5180881e9592ec9b1b822fd3a4334c9d41f2b34f`.

```
subtree merge commit : a15d7b62c8d1242439559f7a2387ee393a34580e   <- §13 rollback anchor
                       (git revert -m 1 a15d7b6)
imported child ref   : refs/remotes/pic10f320/main = f58d2d5…     (== the §6.1 pin)
namespaced tags      : refs/tags/pic10f320/v0.9.0 … v0.9.5, all six SIGNED-OK,
                       all annotated tag objects, same object IDs as in the child
```

**Import is provably verbatim.** The imported subtree's tree object equals the
child's tree at `f58d2d5` exactly — `393cbac2268f9e8510a86c571749da7c78dcf9d5`
on both sides — so nothing was rewritten in transit. The three §6.13 baseline
images came across intact and are tracked at
`_incoming_pic10f320/release/v0.9.5/*.hex`, hashes matching §15.2.

Exit condition verified: no parent Makefile, script, test or workflow file
references `_incoming_pic10f320`, so the prefix is inert; the imported
`.github/workflows/` are inert too, because GitHub Actions only reads the
repository-root path.

Green boundary confirmed — `make test` post-import is **identical** to the
§15.2 pre-import baseline: `EXIT=0`, same closing
`=== all fast pre-hardware tests passed ===`, same golden-model line coverage
99.35% against the 90% floor, and zero `FAIL`/`ERROR` lines anywhere in the
run. The import demonstrably changed nothing the parent suite can observe.

**Gotcha worth recording — imported executables lost their exec bit on
checkout.** Fifteen `.sh` files arrived mode `600` on disk while the commit
correctly recorded `100755`, so `git status` showed fifteen phantom
modifications and `git subtree add` had already committed the *right* modes.
The umask is a normal `0002`; the cause appears to be the ZFS/NFSv4 ACL layer
on this filesystem overriding POSIX mode bits during the merge checkout. The
fix is a worktree-only `chmod 711` (this project's script mode) to match the
committed tree — **not** a commit. Watch for the same effect when Phase 2
relocates these files, and check `git diff --summary` for `mode change` lines
before committing any phase; committing one would strip the exec bit from
scripts the Makefile invokes directly.

Two incidental confirmations, so they are not re-derived: the parent's existing
`!release/**/*.hex` negation already covers D2's `bypass_mcu_*` basenames, so no
`.gitignore` change is needed for future unified release images; and
`build_pic10f320/*.hex` is already ignored by the global `*.hex` rule, though
the directory still needs its own entry in Phase 2 for non-HEX artifacts.

### 15.4 Phase 2 — relocation and host lanes, 2026-07-26 (COMPLETE)

Relocated to `test/pic10f320/{equiv,actuation,fault}/` (plain `mv`, index left
for the user to stage). Includes repointed off the vendored model and onto the
shared core: `test_equiv.c` now takes `bypass_config_host.h` (the parent's shim,
`-Itest`) instead of the child's minimal `test/model/bypass_config.h`, and both
firmware harnesses now include `../../../src/bypass_mcu_pic10f320.c`. The
equivalence recipe compiles and links **`src/bypass_pure.c`** — no vendored copy
is reachable from any PIC10F320 lane any more.

New Makefile section `PIC10F320 -- the constrained target`, inserted before
INTROSPECTION, carrying `PIC320_*` variables and `pic320-*` targets per D1, with
`build_pic10f320/` and coverage as a subtree of it per §5.7. Host lanes:
`pic320-test-equiv`, `pic320-test-actuation`, `pic320-test-fault-host`, and the
tool-independent aggregate `pic320-test-host`. Plus `pic320-clean`, and
`pic320-verify-baseline-images` — the §6.13 gate pulled forward from Phase 4 as
D4's one-shot migration check, with its lifetime and its
"must run BEFORE the §6.11 edit" ordering written into the recipe's own comment
so it cannot be lost.

**Firmware move completed by the user 2026-07-26**, as a `git mv` from
`_incoming_pic10f320/bypass_mcu_pic10f320.c` to `src/bypass_mcu_pic10f320.c`
(git recorded it as a rename, preserving the path link). Confirmed byte-identical
to the child original at `f58d2d5`, so "verbatim" is a checked fact, not a review
claim. No mode change accompanied it; note that every file in `src/` is mode
`600` on this filesystem, which git ignores because only the exec bit is tracked.

Validated first in a sandbox copy with the move simulated, then **re-run in the
real tree after the move — identical results, reproduced below**:

| Lane | Result |
| --- | --- |
| `pic320-test-equiv` | 266144 sequences, **0 divergences**, 66/66 reachable model states — against the real `src/bypass_pure.c` |
| `pic320-test-actuation` ×3 | 108 / 113 / 115 checks, 0 failures |
| `pic320-test-fault-host` ×3 | 41 / 42 / 42 checks, 0 failures (the pre-port counts, confirming the sandbox ran the *verbatim* firmware) |
| `pic320-verify-baseline-images` | **PASSED 3/3 — byte-identical** to the child's signed v0.9.5 images, hashes matching §15.2 |

**§6.13 gate evidence, recorded here because the gate is one-shot (D4) and its
baseline disappears with `_incoming_pic10f320/` in Phase 7.** These are the
SHA-256 sums of the three images built from `src/bypass_mcu_pic10f320.c` by the
ported recipe in the merged tree, each `cmp`-equal to the child's signed
`release/v0.9.5/` image of the same name:

```
26531d3408a75297656d722699a1ffafdc47de376af6b4d2aa62b303c6713ca8  bypass_mcu_cd4053-simple_pic10f320.hex
7709a3979b9103411b1f2e0c892d2291e1c232b5033344bd645ae289ac55649f  bypass_mcu_cd4053-mute_pic10f320.hex
b77e21221b8a94788781b2d1df6a66e0487317cb215d5d540c5582db2a47c4e2  bypass_mcu_tq2-relay_pic10f320.hex
```

This is the moment the merge's central provenance claim becomes machine-checked:
the relocated firmware, built by a recipe rewritten under new variable names in a
different Makefile, still emits the exact bytes the child shipped and signed.
The §6.11 exact-TRISA edit deliberately invalidates these hashes and must
therefore land as its own commit *after* this point, carrying the rebaselined
values.

Guard checks: `pic320-clean` leaves the shared top-level `coverage/` intact
(§5.7 — the imported child recipe would have deleted it); the default `test`
aggregate gained no `pic320` member, so its tool contract is unchanged
(Principle 5); and no `.NOTPARALLEL` entered the Makefile (§5.8).

Green boundary confirmed. The parent suite is now identical across all three
checkpoints — pre-import (§15.2), post-import (§15.3), and post-relocation:
`EXIT=0`, same closing `=== all fast pre-hardware tests passed ===`, same
golden-model line coverage 99.35% against the 90% floor, zero `FAIL`/`ERROR`
lines. Adding a fifth target and a whole new validation lane changed nothing the
existing suite can observe, which is exactly the property Phases 1 and 2 were
supposed to preserve.

One recipe bug found and fixed while validating, worth remembering because it is
silent: `$$v_$(PIC320_TAG)` in a shell loop expands as a variable named `v_`, not
`v` followed by `_`, so the gate looked for `bypass_mcu_.hex` and reported a
missing baseline rather than a mismatch. Use `$${v}` in any recipe that
concatenates a loop variable with `_`.

### 15.5 §6.11 exact-TRISA port — landed 2026-07-26

The measured resolution of §6.11, applied after the Phase-2 byte-identity gate
passed and as its own rebaselining commit, exactly as the ordering there
requires. Firmware edit by the user; the seven test sites by the assistant.

Flash cost matched the prediction on every variant — **+1 word each**:

| Variant | before | after | free |
| --- | --- | --- | --- |
| cd4053-simple | 219 | **220** | 36 |
| cd4053-mute | 240 | **241** | 15 |
| tq2-relay | 243 | **244** | 12 |

Host lanes green on all three variants, with the fault-check count now a
**uniform 41/41/41** where it was 41/42/42. That change *is* the assurance gain:
cd4053-simple's spare RA2 pin was previously a documented blind spot — the old
per-variant mask did not cover it — and exact TRISA closes it. The variant split
in the fault expectations is gone at both host and target level.

**The gate proved it has teeth.** Re-running
`pic320-verify-baseline-images` after the edit **failed on all three variants**,
which is the intended outcome: it is the one check that notices any change to
emitted bytes (§14.2), so a clean pass here would have meant the gate was blind.
Rebaselined hashes:

```
e48ed8e50e89a7f2c2e145603d16c25099925269ea0b29b31becc9c02eb2143f  bypass_mcu_cd4053-simple_pic10f320.hex
1cc2cbf6572a876b1a0a5d19e2e3179a41c7a46bd1b7419d2b5e72aa2aec27a7  bypass_mcu_cd4053-mute_pic10f320.hex
b30783d20e1ef088b3fa612cb7c41755b48ba1060395e01cf7360ea664d1e50f  bypass_mcu_tq2-relay_pic10f320.hex
```

Consequence for the gate's remaining life: `PIC320_BASELINE_DIR` still points at
the child's v0.9.5 images, against which the answer is now permanently "differs".
Phase 4's re-run must compare against **these** hashes instead. Point the gate at
a rebaselined copy, or retire it here and record that its migration purpose was
served at the Phase-2 boundary — the plan's §6.13 sequencing anticipated exactly
this and left the choice open.

Two of the seven sites — `test/pic/test_fault_pic.cc` and
`test/run_mutation_tests.sh` — were still under `_incoming_pic10f320/` when the
edit landed and were updated in place so they arrive correct rather than stale.
Nothing builds from the prefix, so they are **not verified in position**; their
content is the text proven at 42 killed / 0 survived / 0 errored in the scratch
clone, and Phase 4 must re-run the gpsim and mutation lanes once they are wired.
This is the one piece of §6.11 evidence that is transferred rather than
reproduced in the merged tree.

### 15.6 Phase 3 — shared assets folded 2026-07-26

Verified before deleting anything, per the phase's own rule that a green parent
suite is not evidence for dark files:

- **0-diff claims all hold.** `test/misra_rules.txt`, `test/misra.json`,
  `test/test_lockstep_progress.sh` and `scripts/validate-ihex.sh` are
  byte-identical between the two projects.
- **The vendored core is code-identical** to `src/`. Comparing with comments and
  trailing whitespace normalized (§6.2's caveat), `bypass_pure.c`,
  `bypass_pure.h` and `bypass_types.h` differ only in licence-header style.
- **The child's MISRA suppression file carries no entries** — comments only, so
  there was nothing to merge, and the parent's 18 entries are all file-scoped
  (`0` non-scoped), so none can leak onto the imported firmware.

**Principle 8, case 1 — the corrupt-state property, migrated.** The parent had
**zero** occurrences of `verify_corrupt_state_faults()`; the child had it. It is
now in `test/formal/test_model_check.c` as invariant (I7), documented as the one
property that deliberately starts *outside* the reachable state space: an SEU can
leave `program_state` holding a value the machine cannot produce, and the core
must fault without toggling — a toggle on the way out would be an audible
spurious switch. Model check went 2153 → **2157 checks, 0 failures**.

**Principle 8, case 2 — the coverage gate, promoted.** Confirmed the hole was
real: `COVERAGE_SRC = test/host/test_logic_host.c` with a 90% floor measures the
independent **oracle**, which by its own header "does NOT include the firmware",
so no parent target measured `src/bypass_pure.c` at all. New
`coverage-check-core` measures the real core via the two formal drivers that link
it, floor **95%**, added to `test` and `test-long`. Result: **100.00%**.

The gate was negative-tested rather than assumed, all three failure modes:
malformed floor → fail; out-of-range floor → fail; and — the one that matters —
a reduced driver set produces **74.29%** and is correctly rejected against the
95% floor. That last case also proves the driver list is meaningful: neither
formal driver reaches the floor alone.

**Both host assurance roles are preserved, and here is the reviewed argument
§4 asks for.** All 23 test functions in the child's `test_logic_host.c` have a
parent counterpart by name; the difference is only what they run *against*
(parent = its own re-implementation, child = the real core through
`model_step.h`). Post-fold the oracle role is the parent's untouched
`test_logic_host.c`, and the direct-core role is carried by
`test_model_check` + `test_symbolic` — which link the real core, now provably at
100% line coverage — plus `pic320-test-equiv`'s 266144-sequence differential.
That is strictly stronger than 23 hand-written scenarios, so the child copy is
dropped rather than kept as a third runner.

**Correction to §4 — the "Known gaps" row rested on a stale observation.** It
states "The parent never back-ported any of it". That was true when written and
is **false at this tip**: `test/README.md:169` already carried a
`## Known gaps (PIC — hardware-bench only)` section, and on the WDT bullet it is
*more* detailed than the child's — it quotes the concrete gpsim ~1.06 s versus
silicon ~256 ms figure that the child's lacks. The real Phase-3 work was
therefore smaller and different from what the row predicted:

- the child's **"Real-silicon pulse timing remains bench-only"** bullet genuinely
  was missing, and is now added (it applies to the 322's blocking actuations
  just as much);
- the section was scoped to "properties of the **PIC10F322** build" plus a
  pointer to the sibling child project. It is rescoped to cover both PIC targets
  as properties of the shared gpsim environment, which also retires the stale
  external-child reference §4 catalogues at `test/README.md:173`.

Deleted from the prefix, in this order — gate wired first, so nothing measuring
the real core vanished between two green commits: `test/model/bypass_pure.{c,h}`,
`test/model/bypass_types.h`, `test/model/bypass_config.h`, all three
`test/formal/` drivers, `test/host/test_logic_host.c`, both MISRA rule files and
the empty suppression file, `test/model_step.h`, `test/soak_timing_config.h`,
`test/test_lockstep_progress.sh`, and `scripts/validate-ihex.sh`. The tree now
holds exactly one copy of each. `test/model/README.md` is deliberately left for
Phase 7 with the rest of the documentation disposition.

### 15.7 Phase 4 — build, analysis and target validation (COMPLETE)

**Landed and verified 2026-07-26.** All three variants unless noted.

| Lane | Result |
| --- | --- |
| `pic320` / `pic320-variants` | 220 / 241 / 244 words of 256, IHEX-validated |
| `pic320-analyze` (cppcheck + MISRA) | clean, **zero unwaived** findings |
| `pic320-test-config` | 45 checks, 0 failures — CONFIG `0x389E` on all three |
| `pic320-test-fault-target` | **22 / 22 / 22** checks, 0 failures |
| `pic320-test-io` | 25 / 26 / 36 checks, 0 failures |
| `pic320-test-lockstep` | 3005 checks each, 0 mismatches, 66/66 states |
| `pic320-test-target-variants` | **EXIT=0**, fail-closed matrix |
| `pic320-test-soak` | PASS on all three at short duration |

**The §15.5 evidence gap is closed.** §15.5 recorded that the exact-TRISA edits to
`test_fault_pic.cc` were *transferred* from a scratch clone rather than
reproduced here, because nothing built from the import prefix. The target fault
lane now reports exactly **22 checks on every variant** — the `EXPECTED_CHECKS`
that edit sets, and a uniform count that only holds once cd4053-simple's RA2
negative control becomes a positive case. Verified in position.

Lock-step deserves its own note: the real emitted image, running in a simulated
PIC10F320, tracked against **`src/bypass_pure.c`** — the shared verified core, not
a vendored copy — for 3000 iterations per variant with zero divergence. That is
the inlining seam of §8 being closed against the same code every other target
compiles into its shipping image.

**FOLD/FORK dispositions, each decided from a non-comment diff.** §4 predicted
more reconciliation than existed:

| Asset | Disposition | Actual divergence |
| --- | --- | --- |
| `power_on_pressed.stc` | FOLD | executable stimulus byte-identical |
| `run_gpsim*.sh` | FOLD | default `PROC` only — already parameterized on `PIC_GPSIM_PROC` |
| `test_soak_pic.cc` | FOLD | parent ahead (`SOAK_LIVENESS_DUE`), as §4 predicted |
| `test_config_pic.c` | PARAMETERIZE | **one printf label.** Address, layout, mask and expected word were already identical, so `PIC_DEVICE_NAME` is the whole change |
| `test_{fault,io,lockstep}_pic.cc`, `footswitch_toggle.stc` | FORK | genuinely chip-specific → `test/pic10f320/gpsim/` |

**§6.13 gate: ran twice, then retired (D4).** Phase 2 against the child's signed
v0.9.5 images — PASSED 3/3. Phase 4 against the §15.5 rebaselined hashes, using
the *hardened* build rule — PASSED 3/3, which additionally proves the budget
gate, IHEX validation and cleanup traps changed no emitted bytes. Both hash sets
are recorded in §15.4/§15.5 and the phase commits. Retired because its baseline
lives under `_incoming_pic10f320/`, which Phase 7 deletes; a gate whose reference
disappears is worse than none. The cost is stated plainly: per §14.2 nothing at
the merged tip now watches emitted bytes.

`make clean` removes all 49 PIC10F320 artifacts and leaves the shared
top-level `coverage/` intact (§5.7 verified by sentinel file, not by inspection).

**Three findings from building the analysis lane, all worth keeping:**

- **The MISRA lane was vacuous twice before it was real.** v1 grepped stdout
  instead of using cppcheck's exit status; v2 still passed an injected violation
  because it omitted `--enable=style`, and *MISRA addon findings are
  style-severity*. Any new cppcheck gate must be negative-tested with a real
  injected violation before its "clean" is believed.
- **A bare `#` line in `test/misra_suppressions.txt` breaks every lane** with
  `cppcheck: error: Failed to add suppression. No id.` — and it does not say
  which line. That file is shared by the AVR, 322 and 320 gates, so one stray
  comment line takes all three down.
- **The 320 needed two documented waivers, both from one root cause.** Its heavy
  in-function `static_assert` use costs the addon its device symbol table, giving
  `misra-config` on `PIR1bits`/`TMR2IF` and two false "unused macro" (2.5)
  reports for macros consumed only inside those asserts. Bisected by stripping
  the asserts with every other flag unchanged; the identical statement against
  the identical DFP header analyses clean in the 322. Both are **file-scoped**
  (D-4) — note the 322 lane suppresses `misra-config` *globally* via a cppcheck
  flag, so the merge narrows that waiver rather than importing it, and the 320 is
  now the stricter of the two PIC lanes.

**Mutation topology (§6.6) — merged, 74 mutants, all killed.** The child's 42
resolve to 36 PIC10F320 firmware mutants plus 6 model mutants, five of which
duplicate entries already in the parent driver. The sixth does not: it is the
oracle for `verify_corrupt_state_faults()`, the property Phase 3 migrated, and
it is retargeted from the dead vendored copy to `src/bypass_pure.c` — verified
killed before being relied on. Final tally, `MUTATION_ALLOW_SKIP=0`:
**74 killed, 0 survived, 0 errored, 0 skipped.**

Mutants are split by what they *need*, not by what they test: 27 host-lane ones
require only a C compiler and ride with the core batch unskippable; 9 require
XC8 + gpsim + libgpsim and sit behind a new PIC10F320 probe that verifies the
**unmutated** tree genuinely passes first. Without that split they would
"survive" on any host lacking the toolchain — the precise false-pass the
existing PIC probe was written to prevent. Skip accounting is wired too, so a
partial run cannot read as full PIC10F320 coverage.

`copy_tree` needed fixing for this: its single-level `test/*/` loop could not
reach `test/pic10f320/{equiv,actuation,fault,gpsim}/`, and it copied neither
`.stc` scripts nor `.sh` helpers. A PIC10F320 mutant would have built against a
sandbox missing its own harness and died for the wrong reason — an *error*
rather than a kill, but an equally misleading green.

**This also closes the last §15.5 evidence gap.** That section recorded the two
retargeted mutants in `run_mutation_tests.sh` as *transferred* rather than
reproduced, because nothing built from the import prefix. Both now ran in the
merged tree and were killed. No §6.11 evidence remains un-reproduced here.

**The three shared-name harness regressions (§4) — FOLD, not FORK.** One script
per concern now covers both chips:

| Script | Mechanism | Result |
| --- | --- | --- |
| `test_pic_build.sh` | `PB_*` knobs (target, build dir, image naming, budget, matrix) | 28 checks × 2 chips |
| `test_target_matrix.sh` | `TM_*` knobs (target, variants variable, supported set) | 5 checks × 2 chips |
| `test_gpsim_wrappers.sh` | *no folding needed* — see below | 28 checks (was 25) |

`test_gpsim_wrappers.sh` is the interesting one: it is already chip-agnostic
(it unsets `PIC_GPSIM_PROC` and drives the wrappers through a fake gpsim), and
because the PIC10F320 lane reuses those exact wrapper files rather than forking
them, every existing check already covered both chips. What was *not* covered
is the override mechanism that makes the sharing work, so it gains a check that
the wrapper hands gpsim the right `-p` processor — recorded **behaviourally**
from gpsim's argv, after a first attempt using a source `grep` proved useless
(a substring match for `PIC_GPSIM_PROC` still matches `PIC_GPSIM_PROC_RENAMED`).

Supporting these folds, `pic320-test-target-variants` was rewritten to mirror
the parent's Make-function guard exactly — empty, duplicate **and unsupported**
matrices, rejected on stderr with exit 2 — and gained
`override PIC320_VARIANTS_SUPPORTED` so a command-line matrix cannot whitelist
itself. The unsupported-name probe uses `tmux4053-simple`, the retired variant
§1 says must never reappear.

**Two defects this phase exposed in its own work**, both surfaced by *running*
the folded regressions rather than reading them:

- `pic320-variants` left a **partial image matrix** when one variant failed —
  a half-built release set, exactly the hazard §14.8 describes. It now removes
  the whole set on any failure.
- The budget comparison ported from the child was **weaker** than the parent's.
  `exit !(a > b)` conflates "awk says not over budget" with "awk failed", so a
  fake awk exiting 1 passes straight through. Replaced with the parent's
  `print (a > b ? "gt" : "le")` form, which treats any nonzero status as a
  failure, validates the printed token, and checks the percentage's format.
  Where the two projects' hardening differs, the merge should take the stronger
  side rather than the imported one by default.

A third near-miss is worth recording as method: the PIC10F320 matrix check
initially *passed for the wrong reason* — a multi-word `PIC320_VARIANT` tripped
the `$(error)` guard rather than the injected compiler failure. It was caught
only by asking why it passed. Together with the twice-vacuous MISRA lane above,
that is three gates in this phase that reported success while proving nothing.
**Assume a new gate is vacuous until a deliberately broken input makes it fail.**

**Phase-4 green boundary, against the committed tree** (`af8bb93`, worktree
clean): `make test` → `EXIT=0`, zero `FAIL`/`ERROR` lines, with every new and
folded lane present in the run —

```
state-space model check:              2157 checks, 0 failures   (was 2153)
PIC build validation:                   28 checks, 0 failures
PIC10F320 build validation:             28 checks, 0 failures
PIC target-variant matrix validation:    5 checks, 0 failures
PIC10F320 target-variant matrix:         5 checks, 0 failures
gpsim wrapper validation:               28 checks, 0 failures   (was 25)
golden-model line coverage:          99.35% (floor 90%)
verified-core line coverage:        100.00% (floor 95%)
```

**Phases 0–4 are complete: this is §7's minimum coherent merge.** The merged
tree builds and validates all three PIC10F320 variants against a single verified
core, holds exactly one copy of every shared asset, and the child repository
remains unarchived as the operational fallback. Per §7 this is a defensible
resting state that can be left indefinitely; the one bad place to stop is after
Phase 6, where release machinery would name images no CI gate produces.

**Carried into later phases.** Six files remain under `_incoming_pic10f320/`:
`test/README.md` and `test/model/README.md` (Phase 7 documentation);
`test_make_serialization.sh`, `test_release_images.sh` and `test_soak_timing.sh`
(Phase 6 release integration, still needing their FOLD/FORK calls); and
`run_mutation_tests.sh`, which is now **fully superseded** — its mutants live in
the parent driver — so it is dead weight awaiting Phase 7's disposition sweep,
not outstanding work.

### 15.8 Tool inventory, and the one recorded blocker

§6.9 requires unavailable tools to be recorded as blockers rather than passes.
Verified present on the execution host: XC8 V3.10 at the pinned
`/opt/microchip/xc8/v3.10/bin/xc8-cc`, PIC10-12Fxxx DFP 1.9.189 at the pinned
`/opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8`, `gpsim`, the `gpsim-dev`
headers (`/usr/include/gpsim/sim_context.h`), `cppcheck`, `cbmc`, `avr-gcc`,
`gcov`, `python3`, and `git-subtree` under Git 2.43.0 — confirming §6.10 and
§6.14 with no re-derivation needed.

**`klee` is absent.** Consequences, stated so Phase 3 does not discover them:
`make test` is unaffected, because its member `test-klee-build` only compiles and
links bitcode (`test/test_klee_build.sh`) and does not execute the solver. But
`test-symbolic-klee` — a target on *both* sides, and the subject of §6.2/§6.3's
"preserve the child's correct two-object KLEE flow" instruction — cannot be run
locally. Phase 3 may verify the *link* recipe here; the executed-proof evidence
must come from CI or a host with KLEE installed, and a local pass of
`test-klee-build` must not be recorded as evidence that the KLEE proof ran.

### 15.9 Phase 5 — CI and aggregate integration (COMPLETE)

**Landed and verified 2026-07-26.** Phase 5 is the phase that makes PIC10F320
failures *visible*: before it, every lane built in Phase 4 had to be invoked by
hand, so a regression could sit in `main` indefinitely without turning anything
red.

**D3 implemented as decided — the existing `pic` job extended, no sibling job,
no `needs` edits.** The DAG is unchanged and was re-verified by parsing the
workflow rather than by reading it: five jobs, and `verify`, `attiny202`,
`build-matrix` and `stress` still declare `needs: pic`, so all four now gate on
PIC10F320 for free. The `pic` job grew four steps — the two PIC10F320 aggregates,
and a second artifact upload — and its assert step now requires **both** device
headers, because one DFP ships both parts and a truncated unzip would otherwise
make an entire chip's lane skip silently.

The two chips' images are uploaded as **separately named artifacts**, never one
merged upload. Both chips emit `bypass_mcu_<variant>_<tag>.hex` into different
directories; flattening them into one artifact is the first step toward shipping
a 322 image under a 320 name, which is precisely what §10 and D2's classifier
obligation exist to prevent.

**The last child validation layer now has an equivalent here.**
`pic320-coverage-check-fw` is the exact-line firmware coverage gate over
`src/bypass_mcu_pic10f320.c` — not a percentage floor, but "every line covered
except the enumerated watchdog-reset fault path". It runs per variant, and that
is not ceremony: the three output stages give **84 / 95 / 99** executable lines,
so a single-variant run would leave real firmware logic unmeasured. All three
report 4 allowed-uncovered fault-path lines and **0 disallowed**.

It is a host lane (`cc` + `gcov`, both already inside `make test`'s tool
contract), so it joined `pic320-test-host`, and the all-variant sweep
`pic320-test-host-variants` is now a member of `test` and `test-long` — the
first PIC10F320 lane in the default aggregate. Cost: ~18 s. Principle 5 is
preserved; the tool contract did not change.

**The §6.12 firmware-coverage / `xc.h` convergence question is answered: keep
both, documented.** The merged tree deliberately retains two firmware-coverage
mechanisms and two `xc.h` shims. The 320's asserts an exact property over a
single fully-inlined translation unit; the 322's
(`test/pic/fw_coverage/run_fw_coverage.sh`) is a percentage-style harness over a
multi-file shipping set — shell, shared pure core, three output drivers.
Converging them would weaken one or the other, so the split is recorded in the
Makefile at the point of use rather than forced.

**Analysis coverage tripled without anyone asking for it.** `pic320-analyze`
compiles one output stage's `#ifdef` branch, so Phase 4's "zero unwaived MISRA
findings" was, strictly, a claim about `cd4053-simple` only — roughly a fifth of
the shipping source had never been analyzed at all. `pic320-test` sweeps
cppcheck and MISRA across all three variants. All three are clean, so the Phase-4
claim survives; it is now *earned* rather than extrapolated.

**The strict-tools inventory found a real defect on its first run — exactly the
one §6.12 predicted.** That row warned: extend the inventory to both chips'
recipes "or the Phase-4 requirement is decorative and a `pic320-` recipe with a
private early exit will pass review." The inventory grew from 2 recipes to 8
(6 → 18 checks, both chips' XC8 and cppcheck/MISRA lanes) and immediately failed:

> `FAIL: pic320 did not skip a missing tool by default` … `FAIL: did not compile for PIC10F320`

`$(SKIP)` is `exit 0` in non-strict mode, and it exits **only the shell running
it**. `pic320`'s XC8 guard sat on its own recipe line, so with XC8 absent the
recipe printed "XC8 not found … skipping" and then Make ran the *next* line and
tried to compile with the missing compiler anyway. A clean skip that isn't.
An audit of every `$(SKIP)` guard in the Makefile found exactly one other
instance — `pic320-size`, the same shape — and **no others anywhere**: all the
AVR, ATtiny202 and PIC10F322 recipes correctly continue the guard's shell with
`fi; \`. Both are fixed, both verified in all three modes (real build, missing
tool non-strict → clean skip, missing tool strict → `::error::` + exit 1), and
the joining comment now says why the line continuation is load-bearing.

The inventory's own honesty is worth recording: it does **not** cover the gpsim,
libgpsim and soak recipes, and the script says so and says why. Those sit behind
a build prerequisite, so a harness driving them would return a different verdict
depending on whether XC8 happens to be installed on the runner. A regression
whose result depends on the runner's toolchain is worse than a stated gap.

**Every new gate was negative-tested before being believed** (§15.7's rule, applied
deliberately this time rather than learned again):

| Gate | Deliberate break | Result |
| --- | --- | --- |
| `pic320-coverage-check-fw` | disabled the happy-path driver in a restored-afterwards edit | 17 DISALLOWED uncovered lines, exit 1 |
| `pic320-test-host-variants` matrix guard | neutered the unsupported-name branch | `FAIL: unsupported matrix was accepted` |
| strict-tools inventory (322 side) | replaced `pic`'s `$(SKIP)` with a private `exit 0` | `FAIL: pic accepted a missing tool under STRICT_TOOLS=1` |
| ci-local routing | deleted the `pic320-test` step from `ci-local.sh` | `FAIL: full push executed 5 Make commands, expected 6` |

The strict-tools inventory needed no synthetic break on the 320 side — it found
a genuine defect unaided, which is the stronger evidence.

**Local CI mirrors the two-chip job.** `scripts/ci-local.sh` asserts both chips
through their **own** `PIC_*` / `PIC320_*` variable pairs rather than assuming
the 320 still tracks the 322 — the whole point of the separate pair (§5.6) is
that one chip can be re-pinned, and a checker reading only `PIC_*` would then
assert the wrong installation and pass while the 320 lane skipped. `--skip-pic`
is documented as skipping **both** chips (one toolchain, one CI job), and as
*not* skipping the PIC10F320 host lanes, which need no XC8 and run inside
`make test` regardless. `test_ci_local_routing.sh` asserts the exact call
sequence — six Make commands, not four — so a silently dropped chip is a failure
rather than a shorter, greener run.

Skip semantics were also made explicit where they had been merely defaulted: the
`stress` job now passes `MUTATION_ALLOW_SKIP=1` on the command line. It installs
no XC8, so both chips' PIC mutants are unavailable there and its PIC mutation
output is diagnostic only; the authoritative fail-closed evidence comes from the
`pic` job, which asserts the toolchain first and runs `MUTATION_ALLOW_SKIP=0`
(now with `PIC320_CC`/`PIC320_DFP` threaded alongside `PIC_CC`/`PIC_DFP`).

**`test-all-targets` was declined.** §7 offers it as optional. Every full-tool
lane is already reachable through `pic-test`, `pic-test-target-variants`,
`pic320-test`, `pic320-test-target-variants` and the `attiny202-*` targets, all
of which CI and `ci-local.sh` invoke by name; a fifth alias would add a name the
`TODO.md` "Unified naming scheme" item would then have to reconcile, and would
buy nothing that is not already gated. Recorded as a decision, not an oversight.

**Phase-5 green boundary.** `make pic320-test STRICT_TOOLS=1` → EXIT=0 (26 s,
220/241/244 words, CONFIG `0x389E` ×3, cppcheck+MISRA clean ×3, gpsim PASS ×6),
and `make test` → EXIT=0, zero `FAIL`/`ERROR` lines:

```
state-space model check:                  2157 checks, 0 failures
PIC10F320 firmware line coverage:         80/84, 91/95, 95/99   (0 disallowed)
PIC build validation:                       28 checks, 0 failures
PIC10F320 build validation:                 28 checks, 0 failures
PIC target-variant matrix validation:        5 checks, 0 failures
PIC10F320 target-variant matrix:             5 checks, 0 failures
PIC10F320 host target-variant matrix:        5 checks, 0 failures   (new)
gpsim wrapper validation:                   28 checks, 0 failures
ci-local routing validation:                 4 checks, 0 failures
strict optional-tool validation:            18 checks, 0 failures   (was 6)
golden-model line coverage:              99.35% (floor 90%)
verified-core line coverage:            100.00% (floor 95%)
```

No stray `*.gcov` at the repo root, no leftover coverage working directories, and
the shared top-level `coverage/` untouched (§5.7).

**Definition-of-done boxes this closes** (§12): the CI job-graph decision is now
recorded *and implemented*; the strict-tools inventory covers optional-tool
recipes for both PIC chips; and §6.12's firmware-coverage / `xc.h` convergence
row has a recorded decision. Two §6.12 rows remain open and are neither this
phase's nor blockers for Phase 6: rebuild determinism
(`test_workload_rebuild.sh`, `test_avr_build_rebuild.sh`) and stack bound
(`test_stack_bound.sh`), the latter arguably the most relevant of all to a fully
inlined `main()`.

**Not in this phase, by design.** `release.yml` is untouched — release
integration is Phase 6, and §7's warning stands: after Phase 6 is the one bad
place to stop, because release machinery would name images no CI gate produces.
The three remaining prefix harnesses (`test_make_serialization.sh`,
`test_release_images.sh`, `test_soak_timing.sh`) still need their FOLD/FORK
calls there. One user-facing pointer is deliberately absent from `make help`
until Phase 7 creates its target: `docs/pic10f320_special_case.md`.

A narrower carry-forward worth writing down: the relocated PIC10F320 test files
still carry pre-move path references in their comments (`test/equiv/…`,
`test/fault/…`, `test/actuation/…`). Only `check_fw_coverage.sh` was corrected
here, because Phase 5 turned it into a live gate whose failure message *tells a
developer which file to edit* — and it named a path that does not exist. The
rest is a mechanical sweep and belongs with Phase 7's disposition pass.

### 15.10 Phase 6 — release integration (COMPLETE)

**Landed and verified 2026-07-27.** Phase 5 made PIC10F320 failures visible in
CI; Phase 6 makes PIC10F320 *part of the product*. The merged tree can now cut a
release that contains it, proves it contains it, and refuses to publish one that
does not.

**The canonical product set exists, and it is the point of this phase.** §10 and
§14.8 describe a hole the plan called "three identically incomplete sets": the
producer built `SHA256SUMS` by globbing `./*.hex`, the verifier listed
`"$dir"/*.hex`, and the release script enumerated images from the same variant
matrices the build commands use. All three would shrink together. Omit an entire
MCU and every check agrees on the shortened set — which is exactly the mistake
adding a second PIC part invites.

`RELEASE_IMAGES` in the Makefile is the independent fourth opinion: **15 image
basenames**, derived from the variant matrices so it cannot drift from the build
rules, but derived from nothing on disk so no build, copy or publish step can
influence it. It is consumed through `make -s print-RELEASE_IMAGES` by
`scripts/make-release.sh`, `scripts/verify-release-images.sh` and
`test/test_release_images.sh` alike — the delivery mechanism §10 said already
existed and should not be reinvented. `RELEASE_IMAGE_DIRS` accompanies it so the
generated reproduction instructions and `release.yml` cannot name a stale set of
build directories.

**Proven against real release data, not only fixtures.** A staged 15-image dry
run was stripped of all three PIC10F320 images from *every* observed set —
release directory, `SHA256SUMS` regenerated over the remaining 12, and the fresh
build directory — producing three perfectly consistent sets describing a release
with no PIC10F320 firmware in it at all. The verifier named the three missing
images and exited 1. With the anchor neutered to its previous listed-vs-observed
form, the same input **passed**. That is the §7 requirement ("negative tests
showing that global omission of PIC10F320 from all observed image sets fails")
demonstrated in both directions.

The set has three more guards, because a canonical set that is itself wrong is
just a fourth way to be confidently incomplete: `test_release_images.sh` asserts
the real Makefile variable has exactly 15 entries, 3 per PIC part and 3 per
tinyx5 part, **0** matching ATtiny202, the three PIC10F320 basenames present by
name, and no retired `tmux4053` image. Dropping the PIC10F320 line from
`RELEASE_IMAGES` fails with `canonical release set has 12 images, expected 15`.

**The env-var override fails closed.** `RELEASE_EXPECTED_IMAGES` exists so the
regression can drive synthetic fixtures, and it is tested for being *set*, not
for being non-empty — `RELEASE_EXPECTED_IMAGES=` is an error, not a quietly
disabled gate. Empty, malformed and duplicated override sets each have their own
rejection, and one check drives the verifier with no override at all and requires
the failure message to name the Makefile as the source, so a broken
`print-RELEASE_IMAGES` cannot leave the gate reading an empty set.

**The classifier hazard D2 created is closed.** `make-release.sh`'s image→MCU
`case` ends in a bare `*.hex` arm that means "ATtiny13a". A PIC10F320 basename —
which carries the `bypass_mcu_` prefix no other target uses — would not have
errored; it would have produced a manifest row confidently describing PIC
firmware as an ATtiny13a image *with AVR fuse bytes a user might then write to a
part*. The new arm is placed first and verified in the generated manifest:

```
| bypass_mcu_cd4053-simple_pic10f320.hex | PIC10F320 | 2 MHz (HFINTOSC) | 220 / 256 words | CONFIG word embedded in HEX |
| bypass_mcu_cd4053-mute_pic10f320.hex   | PIC10F320 | 2 MHz (HFINTOSC) | 241 / 256 words | CONFIG word embedded in HEX |
| bypass_mcu_tq2-relay_pic10f320.hex     | PIC10F320 | 2 MHz (HFINTOSC) | 244 / 256 words | CONFIG word embedded in HEX |
```

The word figures satisfy §10's "256-word usage figures" and are parsed from
*this run's own build log*, so they can never be a stale hand-copied number.
Every other target's `flash used` column is bytes from an ELF; XC8 reports words,
and the column says so per row rather than reading `n/a` as the 322's still does.

**Twelve release soak combos, not nine.** Three PIC10F320 combos join at the same
full duration as every other combo — not a shortened smoke. This needed the
build-only `$(PIC320_SOAK_BIN)` rule, the exact analogue of the 322's, because
the release script compiles one binary per variant under unique names and runs
them all concurrently, which the `pic320-test-soak` run target cannot do.
`test_soak_timing.sh` now asserts the liveness interval reaches all three lanes
(AVR, 322, 320) and that the 320 combos exist at all — the liveness grep alone
would pass vacuously if the loop building those combos were deleted.

**Full `--dry-run` end to end: EXIT=0.** 15 images built and matched to the
canonical set, all 3 PIC10F320 images structurally IHEX-validated, five
validation gates green (`test-long`, `pic-test`, `pic-test-target-variants`,
`pic320-test`, `pic320-test-target-variants`), 12/12 soak combos PASS, staging
directory asserted to hold exactly the canonical set, and the verifier re-run
against the staged output: `REPRODUCED: 15 committed, listed, and freshly built
images match the canonical set exactly.`

**`release.yml` closes the loop.** It asserts both device headers, builds through
`pic320-variants` (which removes the whole image set if any variant fails, so a
partial matrix cannot reach the reproducibility gate), passes
`$(make -s print-RELEASE_IMAGE_DIRS)` to the verifier rather than a hardcoded
list, and re-runs both PIC10F320 gates on the clean runner. The PIC10F320's
images are in the release set, so its evidence belongs in the public attestation
on identical terms.

**The three remaining §4 prefix harnesses, dispositioned.** All three are FOLD,
and in every case for the same reason: **the parent copy is ahead**, so folding
loses nothing.

| Script | Divergence | Action |
| --- | --- | --- |
| `test_release_images.sh` | parent adds symlink-alias, duplicate-directory, FIFO/directory and input-snapshot-mutation cases the child lacks | FOLD, then extend with the canonical-set cases above (24 → 40 checks) |
| `test_soak_timing.sh` | parent adds the ATtiny202 parser probes and the liveness-wiring assertion | FOLD, then add the PIC10F320 lane (38 → 40 checks) |
| `test_make_serialization.sh` | parent adds recursive `-j` fan-out, query/dry-run and release-lock coverage, and a path with spaces | FOLD unchanged; it exercises `make-release.sh` and still passes against the extended script |

That completes §4's shared-name harness ledger: every one of the seven now has a
recorded disposition, and no fold added a tool dependency to the default `test`
aggregate.

**Two deliberate omissions, both stated rather than discovered later.**

- **No `program-pic320` target.** The 322 has `make program-pic`; the 320 does
  not, so `release/README.md` and the generated manifest print the direct
  `pk2cmd -PPIC10F320 …` command and the README says the convenience target does
  not exist yet. Adding it is ~15 lines of untestable-here hardware-programming
  surface, and a wrong programmer invocation is worse than an honest absence.
  Recorded as a follow-up, not smuggled in unverified.
- **No link to `docs/pic10f320_special_case.md` yet.** The generated MANIFEST
  carries the caveat **inline** — 256 words of flash, the inlining seam, what is
  and is not proven — and links the document only `if [ -f ]`. A release cut
  before Phase 7 therefore states the caveat rather than dangling a link at a
  file that does not exist; a release cut after Phase 7 links it automatically.

**One published-workflow consequence, documented.** The canonical set describes
*the release you checked out*, so running the current verifier against
`release/v0.9.4/` from a newer checkout now reports a mismatch. That is correct —
the older release predates targets the current set includes — and the documented
reproduction flow already begins with `git checkout <tag>`, where both the
verifier and the Makefile are that tag's. `release/README.md` says so explicitly
rather than leaving a confusing error for someone to hit.

**Phase-6 green boundary.** `scripts/make-release.sh --dry-run v99.0.0` → EXIT=0
(15 images, 12 soaks, 5 gates); `make test` → EXIT=0, zero `FAIL`/`ERROR` lines:

```
release image verification:        40 checks, 0 failures   (was 24)
soak timing validation:            40 checks, 0 failures   (was 39)
Make serialization validation:      6 checks, 3 concurrent, 0 overlaps
strict optional-tool validation:   18 checks, 0 failures
PIC10F320 host target-variant matrix: 5 checks, 0 failures
golden-model line coverage:     99.35% (floor 90%)
verified-core line coverage:   100.00% (floor 95%)
```

**Definition-of-done boxes this closes** (§12): the canonical expected-product
set exists and every consumer agrees with it; global omission of PIC10F320 fails;
§5.3/D2's naming decision is implemented *and* `make-release.sh`'s classifier
recognizes the surviving prefixes; each §4 shared-name harness has a recorded
FOLD-or-FORK disposition; and ATtiny202 is explicitly outside the canonical
release set with the release claims scoped to match.

**Not in this phase, by design.** `CHANGELOG.md` repair, the caveat document
itself, the child-README rewrite and the `_incoming_pic10f320/` prefix removal
are all Phase 7. §7's warning about stopping here is now the operative one: the
release machinery names PIC10F320 images and CI produces them, so the dangerous
gap is closed — but the documentation still describes two projects.
