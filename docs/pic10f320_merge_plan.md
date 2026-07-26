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

---

## 4. File-by-file disposition

Legend: **FOLD** = collapse to one shared copy (parent's wins) · **DROP**
= delete, superseded · **RELOCATE** = move, content essentially intact ·
**FORK** = keep as a distinct PIC10F320-specific file.

| Child file | Disposition | Destination / note |
| --- | --- | --- |
| `bypass_mcu_pic10f320.c` | RELOCATE | `src/bypass_mcu_pic10f320.c`, verbatim. Firmware — **user moves**. |
| `test/model/bypass_pure.{c,h}`, `bypass_types.h` | DROP after verification | Behaviour-identical to the parent at the audited child tip; current differences are license headers. Superseded by `src/`, but record the comparison before deletion. |
| `test/model/bypass_config.h` | DROP/REPLACE | Not a clone: it is an intentional minimal host threshold shim. Replace its consumers with `src/bypass_config.h` plus the parent's host configuration shim, and verify identical effective thresholds. |
| `test/model/README.md` | MERGE | Put assurance-seam/provenance content in `docs/pic10f320_special_case.md`; put technical model/test instructions in the validation documentation. |
| `test/host/test_logic_host.c` | FOLD w/ care | The parent test is an independent implementation oracle; the child drives the real pure functions. Preserve both assurance roles, either through two backends/property runners or an explicit, reviewed argument that existing shared-core tests make the direct run redundant. Do not discard the difference as noise. |
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
| `TOOLCHAIN.adoc`, `MISRA_COMPLIANCE.md` | MERGE | Add the PIC10F320 device/header, `p10f320`, 256-word gate, CONFIG word, build directory, commands, analyzer configuration, and zero-unwaived-finding policy. Keep detailed technical facts here, linked to the caveat. |
| `AGENTS.md`, `CLAUDE.md`, `LICENSE` | FOLD | Parent copies remain authoritative — but `LICENSE` is *not* identical: parent reads `Copyright (c) 2026 matt-garman`, child reads `Copyright (c) 2026 Matthew Garman`. Folding silently reverts the attribution string; confirm the intended holder rather than defaulting. Separately, the verbatim-moved firmware carries the child's non-SPDX three-line header into `src/`, where every other file uses `SPDX-License-Identifier: MIT`; normalizing it is a comment-only, user-owned firmware edit. |
| `.gitignore`, `test/.gitignore` | MERGE | Ignore the dedicated build directory and all generated nested test/coverage artifacts. Do not import ignored local child artifacts such as `coverage/`, root `.gcda`/`.gcno`, backup files, or the current `build_pic/`. |
| `README.md`, `CHANGELOG.md` | MERGE | Add the constrained target and reconstruct child v0.9.4/v0.9.5 history under the correct historical releases rather than putting it under the first unified release. |
| `test/README.md` | MERGE | Preserve the child file's technical validation semantics, mutation rationale, commands, and known simulator gaps in a dedicated PIC10F320 section/document. The caveat document is not a substitute for test documentation. |
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
     `program-pic320`;
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

   The prefix choice must also stay consistent with the parent's existing PIC
   naming, which is `pic-` (e.g. `pic-test-config`, `pic-test-target-variants`,
   `pic-coverage-check-fw`) — so `pic-*` reads as "PIC10F322" and `pic320-*` as
   "PIC10F320". If that asymmetry is judged too subtle given §14.7, rename the
   322 lane to `pic322-` in the same phase rather than living with it.

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
4. **Build/test output names.** Use `build_pic10f320/` and variant-private
   nested outputs. Never let concurrent variants share an object, executable,
   coverage file, `gpsim.log`, or PASS-evidence path.
5. **Git tags.** Both repos carry bare `v0.9.*` names. Preserve the child's
   original signed annotated tag objects under `pic10f320/v0.9.*`; do not rely
   on commits alone and do not recreate signed tags.

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
   **Hazard:** the replacement this plan mandates, `test/bypass_config_host.h`,
   is AVR-shaped — it hardcodes `PB0`/`PB1`/`PB2` and `F_CPU 1200000UL` to
   satisfy `src/bypass_config.h`'s AVR guards. Harmless if the PIC10F320
   equivalence build consumes only the two thresholds; wrong the moment
   anything reads a pin macro from it. Confirm the 320 harnesses take pin
   numbers from the firmware rather than the shim, or add a PIC-appropriate
   shim alongside it.

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
   as blockers, not passes.
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
    | `test/check_flash_budget.sh` | `test-flash-budget`, `test-flash-budget-regression` | route the 256-word gate through this rather than inlining budget arithmetic in the Makefile |
    | `test/test_strict_tools.sh` | `test-strict-tools` | register every new `pic320-` optional-tool recipe in its inventory, or the Phase-4 `STRICT_TOOLS` requirement is unenforced |
    | `test/test_ci_local_routing.sh` | `test-ci-local-routing` | encode the two-chip `--skip-pic` semantics of §11 |
    | `scripts/release-provenance.sh` | `test-release-provenance` | **§10 omitted provenance entirely** — add PIC10F320 sources/images to it |
    | `test/test_workload_rebuild.sh`, `test/test_avr_build_rebuild.sh` | `test-workload-rebuild`, `test-avr-build-rebuild` | is there a PIC10F320 rebuild-determinism equivalent, and should there be? |
    | `test/test_stack_bound.sh` | `test-stack-bound`, `test-stack-bound-regression` | most relevant to the fully-inlined 320 `main()`; decide in or out and say why |
    | `test/pic/fw_coverage/` (harness + its own `xc.h`) | `pic-coverage-check-fw` | the merged tree ends up with two firmware-coverage mechanisms and two unrelated `xc.h` shims (parent 1146 B; child `test/equiv/xc.h` 3826 B). Converge them or document the split deliberately. |

---

## 7. Phased execution

Work on a dedicated integration branch. Each phase is independently
committable and ends with the existing parent suite plus every newly wired
lane green. Do not delete a child reference implementation merely because the
parent's unrelated tests still pass.

**Phase 0 — Decisions, audit, and baseline.** Complete §6. Resolve the
three-variant contract, documented ATtiny202 non-release status, aggregate
semantics, mutation topology, first unified version, and full file-disposition manifest.
Also resolve the two checkpoints added 2026-07-25: the §6.11 firmware
defensive-layer decision (which gates what Phase 2 is allowed to move) and the
§6.12 parent-gate-infrastructure decisions (which gate Phases 4–6). Settle the
§4 shared-name harness FOLD/FORK calls and the §5.1 `pic-`/`pic320-` prefix
question here as well — they change target names across three later phases.
Record clean parent and child evidence and the parent base SHA. No import yet.

**Phase 1 — Provenance import, inert.** Fetch and verify the pinned child
branch and original signed tags under namespaced refs, then perform a
non-squashed subtree import at `_incoming_pic10f320/` (§9). Nothing builds
from the prefix. Verify parent tests are unchanged and record the subtree merge
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

Validate `pic320-test-equiv`, `pic320-test-actuation`,
`pic320-test-fault-host`, model/firmware coverage, and the inherited parent
host/formal suites before proceeding. Compare results to the child baseline.

**Phase 3 — Fold shared model/formal/MISRA assets.** Migrate the unique
corrupt-state property, preserve both host assurance roles, repair/verify the
KLEE recipe, and then delete the vendored core and superseded formal/MISRA
copies. Re-run host, formal, coverage, and mutation baselines against the sole
`src/bypass_pure.c`. Fresh MISRA analysis must have zero unwaived findings;
only newly demonstrated, documented, file-scoped suppressions may be added.

**Phase 4 — Build and target validation.** Add hardened three-variant XC8
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
unique supported variants and all expected PASS sentinels. Verify `make clean`
removes all generated PIC10F320 files.

**Phase 5 — Normal CI and aggregate integration.** Add host-only PIC10F320
checks to `test`/`test-long` only if they preserve those aggregates' existing
tool contract. Add a strict full-tool hosted PIC10F320 job (or two-chip PIC
matrix) covering every unique child layer and fail-closed mutation. Update
artifacts, job dependencies, local CI, tool assertions, and skip semantics.
Optionally add `test-all-targets` as the explicit full-tool aggregate.

**Phase 6 — Release integration.** Implement one canonical expected-product
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
  use, and link rather than duplicating the caveat.
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

- Parent `release/<ver>/` already mixes MCU images. Exactly **three**
  PIC10F320 images join each future unified release: `cd4053-simple`,
  `cd4053-mute`, and `tq2-relay`; no historical `tmux4053-*` image returns.
- Makefile variables expose the canonical complete product basename set. The
  release script, checksum manifest, committed directory, fresh rebuild, and
  verifier must each agree with that independent expected set. Deleting every
  PIC10F320 image from all three observed sets must still fail. Confirmed
  2026-07-25 that this is genuinely unbuilt: the parent Makefile has no
  `RELEASE_IMAGES`-style variable, and `scripts/verify-release-images.sh`
  derives its set by globbing (`images=("$dir"/*.hex)`), which is exactly the
  three-identically-incomplete-sets hole of §14.8.
- **Release provenance.** `scripts/release-provenance.sh` and its
  `test-release-provenance` gate are parent-only and must learn about
  PIC10F320 sources and images alongside the existing targets (§6.12).
  Provenance is not covered by the image-verification bullet above.
- `scripts/make-release.sh` must explicitly handle PIC10F320 DFP/header
  prerequisites, three builds, structural IHEX and CONFIG validation, strict
  all-variant target/mutation evidence, three soak combinations, 256-word
  usage figures, image-to-MCU classification, programmer commands,
  reproduction instructions/directories, caveat links, and generated commit
  text. A PIC10F320 name must never fall through to generic AVR metadata.
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
  downstream `needs` relationships if PIC10F320 is a separate job.
- `release.yml` asserts the PIC10F320 header, rebuilds into a private fresh
  directory, passes that directory and the canonical set to verification, and
  reruns strict target and mutation gates before publication.
- `scripts/ci-local.sh` mirrors both PIC lanes. Document whether `--skip-pic`
  skips both and make its control flow consistent with `STRICT_TOOLS=1`.

---

## 12. Definition of done

- [ ] The imported graph is pinned to the recorded child SHA (`f58d2d5...`, not
      the superseded `915ee03...`), all six original signed tags are verifiable
      under `pic10f320/v0.9.*`, and provenance lookup instructions document
      `git log -m --follow`.
- [ ] The §6.11 PIC firmware defensive-layer divergence is resolved by an
      explicit decision: either exact-TRISA/latch-match is ported to
      PIC10F320 by the user, or its absence is documented in
      `docs/pic10f320_special_case.md` and reflected in the mutation topology.
      The reverse ANSELA question has an answer too.
- [ ] Every §6.12 parent-only gate has a recorded PIC10F320 decision: mutation
      policy, flash budget, strict-tools inventory, ci-local routing, release
      provenance, rebuild determinism, stack bound, and firmware-coverage /
      `xc.h` convergence.
- [ ] Each §4 shared-name harness regression (`test_pic_build.sh`,
      `test_make_serialization.sh`, `test_gpsim_wrappers.sh`,
      `test_release_images.sh`, `test_soak_timing.sh`, `test_target_matrix.sh`,
      `test_lockstep_progress.sh`) has a recorded FOLD-or-FORK disposition, and
      no fold silently added a tool dependency to the default `test` aggregate.
- [ ] Exactly one `src/bypass_pure.c`, formal property set,
      `test/model_step.h`, `misra.json`, and `misra_rules.txt` remains; no
      vendored model copy survives.
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
7. **Two PIC chips, near-name harnesses.** `test_*_pic.cc` for 322 vs
   320 differ enough that an edit to the wrong copy is easy. Directory
   separation + distinct `pic-`/`pic320-` target prefixes are the guard.
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
