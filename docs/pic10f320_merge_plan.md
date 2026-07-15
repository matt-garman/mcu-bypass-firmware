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
| `test/run_mutation_tests.sh` | MERGE with explicit topology | Add PIC10F320 firmware mutants to the parent driver or use a clearly integrated sibling driver. Retarget only nonduplicate model mutants to `src/bypass_pure.c`; recursively copy the nested PIC10F320 tree into sandboxes; use private outputs; add target-I/O/fault/lockstep and WDT-soak mutants; baseline every distinct kill target. |
| `Makefile` | MERGE | Import PIC10F320 targets under a `pic320-` prefix (§5). Child Makefile then deleted. |
| `scripts/ci-local.sh` | FOLD | Assert both PIC headers and run the host/full-tool PIC10F320 lanes. Define whether `--skip-pic` skips both chips; avoid a later `STRICT_TOOLS=1` failure through an aggregate it was meant to skip. |
| `scripts/make-release.sh` | FOLD/EXTEND | Add PIC10F320 variables, DFP/header checks, build, validation, mutation, three soaks, evidence, image metadata, programmer commands, reproduction commands, verifier inputs, constrained-target wording, and generated commit text. Do not merely append filenames. |
| `.github/workflows/ci.yml` | FOLD/EXTEND | Add a strict full-tool PIC10F320 job or a two-chip matrix, assert `proc/pic10f320.h`, preserve every unique test layer, upload `build_pic10f320/*.hex` separately, and update downstream `needs`. Run PIC mutation fail-closed in a full-tool hosted job. |
| `.github/workflows/release.yml` | FOLD/EXTEND | Rebuild PIC10F320 into a private directory, enforce the canonical set, rerun strict target/mutation gates, and pass the extra directory to reproduction verification before publication. |
| `TOOLCHAIN.adoc`, `MISRA_COMPLIANCE.md` | MERGE | Add the PIC10F320 device/header, `p10f320`, 256-word gate, CONFIG word, build directory, commands, analyzer configuration, and zero-unwaived-finding policy. Keep detailed technical facts here, linked to the caveat. |
| `AGENTS.md`, `CLAUDE.md`, `LICENSE` | FOLD | Parent copies remain authoritative. |
| `.gitignore`, `test/.gitignore` | MERGE | Ignore the dedicated build directory and all generated nested test/coverage artifacts. Do not import ignored local child artifacts such as `coverage/`, root `.gcda`/`.gcno`, backup files, or the current `build_pic/`. |
| `README.md`, `CHANGELOG.md` | MERGE | Add the constrained target and reconstruct child v0.9.4/v0.9.5 history under the correct historical releases rather than putting it under the first unified release. |
| `test/README.md` | MERGE | Preserve the child file's technical validation semantics, mutation rationale, commands, and known simulator gaps in a dedicated PIC10F320 section/document. The caveat document is not a substitute for test documentation. |
| `release/README.md` | MERGE | Preserve PIC10F320 flashing, trust, and reproduction details in the parent's shared release documentation. |
| `release/v0.9.*` | DELETE FROM MERGED TIP / PRESERVE IN HISTORY | Do **not** place colliding historical release directories in the merged current tree. Preserve them through the imported graph and namespaced original tag objects. Include the child top-level `release/README.md` in the merge above. |

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
- `TODO.md`, `test/README.md`, `docs/pic10f320_feasibility.md`, README/design
  claims, and release documentation — remove or qualify every "unsupported" or
  external-child statement. The stale child-project link in
  `src/bypass_mcu_avr_xt.c` is a comment-only firmware-source edit and must be
  performed by the user under project policy; confirm non-comment firmware
  bytes remain unchanged.

---

## 5. Namespace collisions to resolve

1. **Makefile targets.** Child uses *bare* names because it is single-target;
   import them under a distinct **`pic320-`** prefix. Define the complete
   topology before implementation:

   - build/utility: `pic320`, `pic320-size`, `pic320-analyze`,
     `program-pic320`;
   - host lanes: `pic320-test-equiv`, `pic320-test-actuation`,
     `pic320-test-fault-host`, `pic320-coverage-check-model`,
     `pic320-coverage-check-fw`;
   - emitted-image/CLI lanes: `pic320-test-config`, `pic320-test-gpsim`;
   - libgpsim lanes: `pic320-test-fault-target`,
     `pic320-test-lockstep`, `pic320-test-io`, `pic320-test-soak`;
   - robustness lanes: `pic320-test-build`, `pic320-test-mutation`;
   - aggregates: `pic320-test-host`, `pic320-test` for one selected variant,
     `pic320-test-variants` for all three, `pic320-test-target`, and
     fail-closed `pic320-test-target-variants`.

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

1. **Pin the audited import.** Unless a deliberate re-audit chooses a newer
   tip, import child HEAD `915ee03b58c8ac48203b78dfdc07da645dfac20f`
   (signed `v0.9.5`). Record source tip
   `331f90f7363d2d19016445667e2fb0a458df4651`; the later commit adds release
   artifacts only. Verify all six signed tags `v0.9.0` through `v0.9.5` before
   namespaced import.
2. **Reconcile the model files.** Confirm `bypass_pure.{c,h}` and
   `bypass_types.h` differ only in license headers. Separately document that
   child `bypass_config.h` is a minimal shim, and prove its consumers receive
   the same thresholds through the parent host configuration.
3. **Preserve distinct host/formal assurance.** Audit all assertions; migrate
   `verify_corrupt_state_faults()` explicitly; decide how to retain the
   independent-oracle and direct-core roles; fix the parent KLEE link recipe;
   confirm `model_step.h`, `misra.json`, and `misra_rules.txt` equivalence.
4. **Harden false-pass paths before promotion.** Port or implement: gpsim
   timeout/nonzero propagation; deterministic first lockstep stimulus;
   immediate simulator-progress failure; exact target-fault check counts;
   bounded/nonzero soak duration with a 24-hour release minimum; structural
   Intel HEX/checksum/EOF validation and failed-output cleanup; nonempty,
   unique, exactly-three variant-matrix validation; and private concurrent
   outputs. Fix the shared parent/child lockstep `run_ms()` propagation issue.
5. **Define the three-variant contract.** Pin accepted command-line values,
   preprocessor macros, artifact basenames, sizes, and expected per-variant
   PASS counts. Reject empty, duplicate, and unknown variant lists inside every
   authoritative aggregate rather than relying on an earlier build to fail.
   Re-measure footprints in the merged tree; do not copy the stale 217/240/241
   README figures when the child v0.9.5 manifest records 219/240/243 words.
6. **Define mutation topology and policy.** Identify duplicate model mutants,
   child-only firmware mutants, required sandbox files, kill targets, and new
   target/soak mutants. Preserve the parent's current event policy: its
   full-tool PIC job already invokes mutation with `MUTATION_ALLOW_SKIP=0` on
   pushes, schedules, and manual dispatches, and release validation is strict;
   pull requests intentionally omit the minutes-long mutation gate. The separate
   non-PIC stress job permits explicit PIC skips because it lacks PIC tools and
   is not authoritative PIC mutation evidence. Extend the strict full-tool lane
   to the combined PIC10F322/PIC10F320 set rather than weakening either subset.
7. **Record ATtiny202 release status.** It is development-only/non-release. Keep
   its normal CI lane, but intentionally omit it from release creation,
   reproduction, images, and soak evidence, and scope unified-release claims to
   release-supported targets.
8. **Repair release/changelog baselines.** Restore missing parent v0.9.3/v0.9.4
   changelog entries and classify the child's v0.9.4/v0.9.5 changes under their
   historical versions. Choose `v0.10.0` (preferred) or another version greater
   than both lines for the first unified release; never reuse child `v0.9.5`.
9. **Snapshot clean green baselines.** From clean checkouts/build directories,
   capture parent host/full-tool results and child host, all-variant, target,
   mutation, CONFIG, coverage, and soak evidence. Ignored artifacts in the
   current child worktree are not baseline evidence. Record unavailable tools
   as blockers, not passes.
10. **Preflight Git tooling.** Confirm `git subtree` is installed (it is absent
    from the currently inspected Git installation), child refs are fetchable,
    signed tag verification works, and the integration branch/base SHA is
    recorded before any modifying Git operation.

---

## 7. Phased execution

Work on a dedicated integration branch. Each phase is independently
committable and ends with the existing parent suite plus every newly wired
lane green. Do not delete a child reference implementation merely because the
parent's unrelated tests still pass.

**Phase 0 — Decisions, audit, and baseline.** Complete §6. Resolve the
three-variant contract, documented ATtiny202 non-release status, aggregate
semantics, mutation topology, first unified version, and full file-disposition manifest.
Record clean parent and child evidence and the parent base SHA. No import yet.

**Phase 1 — Provenance import, inert.** Fetch and verify the pinned child
branch and original signed tags under namespaced refs, then perform a
non-squashed subtree import at `_incoming_pic10f320/` (§9). Nothing builds
from the prefix. Verify parent tests are unchanged and record the subtree merge
commit. Do not delete historical releases or documentation yet.

**Phase 2 — Relocate and establish host build scaffolding.** The user moves
`_incoming_pic10f320/bypass_mcu_pic10f320.c` verbatim to
`src/bypass_mcu_pic10f320.c`. Relocate PIC10F320-specific host harnesses to
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
  child HEAD is `915ee03b58c8ac48203b78dfdc07da645dfac20f`.
- Preserve all original signed annotated child tag objects under namespaced
  refs. Do not recreate them, because recreation loses the original signed
  object identity. A representative sequence, after the user confirms the
  remote/path and installs `git subtree`, is:

  ```sh
  CHILD_URL=../pic10f320-bypass-firmware
  CHILD_SHA=915ee03b58c8ac48203b78dfdc07da645dfac20f

  git subtree -h
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
  PIC10F320 image from all three observed sets must still fail.
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
- The first unified tag is preferably **`v0.10.0`**, which is greater than the
  parent's v0.9.4 and the child's signed v0.9.5. Its changelog records both
  imported child HEAD `915ee03...` and source tip `331f90f...`.
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

- [ ] The imported graph is pinned to the recorded child SHA, all six original
      signed tags are verifiable under `pic10f320/v0.9.*`, and provenance lookup
      instructions document `git log -m --follow`.
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
