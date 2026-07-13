# PIC10F320 merge plan

Fold the standalone `pic10f320-bypass-firmware` child repository into
this parent as a first-class-but-explicitly-constrained build target,
eliminating the duplicated validation ecosystem and the hand-vendored
copy of the verified pure core.

This is a working plan, not a spec. It is written to be executed in
phases, each of which leaves the tree green. Firmware source edits are
the user's to make; the phases below call out which steps touch
firmware vs. test/Makefile/docs.

---

## 1. Goal and non-goals

**Goal.** One repository that builds and validates all targets — AVR
Classic (tiny13a / tinyx5), AVR-XT (ATtiny202), PIC10F322, and
PIC10F320 — sharing a single copy of every asset that is genuinely
common, while preserving the parent's "textbook-grade reference"
identity and honestly marking PIC10F320 as the budget-constrained
exception.

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

---

## 2. Guiding principles

1. **Parent stays green at every phase boundary.** `make test` must
   pass before and after each phase. New PIC10F320 targets are added
   dark (built but not yet in the default `test` aggregate) until they
   pass, then wired in.
2. **Single source of truth for shared assets.** After the merge there
   is exactly one `bypass_pure.c`, one set of formal proofs, one
   `misra_rules.txt`. The PIC10F320 equivalence/lockstep tests consume
   `src/bypass_pure.c` **directly** — no vendored copy.
3. **Special-case status is structural and loud, stated once.** One
   authoritative section owns the "PIC10F320 is constrained and
   recovers assurance differently" story; everything else links to it
   rather than re-explaining (or worse, implying parity).
4. **Fail-closed everywhere the parent already is.** Release-image
   verification, coverage gates, and mutation testing must *include*
   PIC10F320 explicitly; a missing PIC10F320 artifact is a failure, not
   a silent skip.

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
    gpsim/        # .stc + test_{config,fault,io,lockstep,soak}_pic for 10F320
    fw_coverage/  # firmware coverage gate for the inline build

docs/
  pic10f320_feasibility.md       # existing
  pic10f320_merge_plan.md        # this file
  pic10f320_special_case.md      # NEW: the single authoritative caveat (see §8)
```

Note: `test/pic10f320/` deliberately sits beside `test/pic/` rather than
reshuffling the existing, already-validated 10F322 tree. A cleaner
"`test/pic/{pic10f322,pic10f320}/`" split is possible but churns known-
good files for aesthetics; deferred unless the two PIC chips start
sharing more harness code than they do today.

---

## 4. File-by-file disposition

Legend: **FOLD** = collapse to one shared copy (parent's wins) · **DROP**
= delete, superseded · **RELOCATE** = move, content essentially intact ·
**FORK** = keep as a distinct PIC10F320-specific file.

| Child file | Disposition | Destination / note |
| --- | --- | --- |
| `bypass_mcu_pic10f320.c` | RELOCATE | `src/bypass_mcu_pic10f320.c`, verbatim. Firmware — **user moves**. |
| `test/model/bypass_pure.{c,h}`, `bypass_types.h`, `bypass_config.h` | DROP | Vendored clone of parent core (5 diff-lines). Superseded by `src/`. **Reconcile the 5 lines first — §6.** |
| `test/model/README.md` | DROP | Content merges into `docs/pic10f320_special_case.md`. |
| `test/host/test_logic_host.c` | FOLD | Tested the vendored copy; parent's copy is authoritative (119 diff-lines are model-vs-core noise — audit that none encode a real 10F320-only property before dropping; if any do, migrate them into the parent host test as target-agnostic assertions). |
| `test/formal/test_cbmc.c` (19), `test_symbolic.c` (10) | FOLD | Near-identical; parent authoritative. Diff-audit for 10F320-only asserts, migrate if any. |
| `test/formal/test_model_check.c` (95) | FOLD w/ care | Larger drift; audit before folding. Keep any 10F320-only invariant as a shared, target-agnostic check. |
| `test/misra_rules.txt` | DROP | 0 diff — identical to parent's. |
| `test/misra_suppressions.txt` (75) | FORK→MERGE | Fold entries into parent's single file, each **scoped to `bypass_mcu_pic10f320.c`** so inline-only deviations don't leak to other targets. |
| `test/misra.json` | FOLD/verify | Reconcile with parent's; single copy. |
| `test/equiv/` (`test_equiv.c`, `fw_harness.c`, `xc.h`) | RELOCATE | `test/pic10f320/equiv/`. Repoint the `#include` of the model from `test/model/` to `src/bypass_pure.h` — **the marquee dedup**. |
| `test/actuation/test_actuation.c` | RELOCATE | `test/pic10f320/actuation/`. No parent analog. |
| `test/fault/` (`test_fault.c`, `fw_fault_harness.{c,h}`, `check_fw_coverage.sh`) | RELOCATE | `test/pic10f320/fault/`. Distinct from parent's gpsim `test_fault_pic.cc`. |
| `test/pic/test_*_pic.cc`, `*.stc`, `run_gpsim*.sh` | RELOCATE | `test/pic10f320/gpsim/`. These COLLIDE by name with parent's 10F322 versions but target a different chip (diffs: lockstep 254, fault 187, config 48, io 29). Keep separate. |
| `test/model_step.h` | FOLD/verify | Parent has its own; confirm equivalent, keep parent's. |
| `test/run_mutation_tests.sh` (536 diff) | FORK | Heavily forked (different firmware/mutants). Parent's script gains a PIC10F320 mode, or a sibling `run_mutation_tests_pic10f320.sh` under `test/pic10f320/`. |
| `Makefile` | MERGE | Import PIC10F320 targets under a `pic320-` prefix (§5). Child Makefile then deleted. |
| `scripts/ci-local.sh`, `make-release.sh` | FOLD | Parent's are supersets; add PIC10F320 steps. |
| `.github/workflows/{ci,release}.yml` | FOLD | Add PIC10F320 matrix legs to parent workflows; delete child's. Child CI badge in README goes away. |
| `TOOLCHAIN.adoc`, `MISRA_COMPLIANCE.md`, `AGENTS.md`, `CLAUDE.md`, `LICENSE`, `.gitignore` | FOLD | Parent's authoritative; splice any PIC10F320-specific toolchain note (XC8 `pic8-enhanced`, CONFIG `0x389E`) into parent's. |
| `README.md`, `CHANGELOG.md` | MERGE | PIC10F320 gets a clearly-marked section/lane, not a peer heading (§8, §10). |
| `release/v0.9.*` | ARCHIVE | Do **not** retro-merge (numbering collides with parent's). Preserved in imported git history; unified releases start next tag (§10). |

**Parent-side files that gain PIC10F320 awareness (no child counterpart):**
- `scripts/verify-release-images.sh` + `test/test_release_images.sh` —
  extend the exact expected-image set with the five PIC10F320 hex names
  (`bypass_mcu_{cd4053-simple,cd4053-mute,tq2-relay}_pic10f320.hex`,
  plus the two `tmux4053-*` names present in early child releases —
  confirm the current variant list before pinning).

---

## 5. Namespace collisions to resolve

1. **Makefile targets.** Child uses *bare* names (`test-equiv`,
   `test-gpsim`, `all`) because it is single-target; parent's PIC (322)
   targets are `pic-`-prefixed and its cross-cutting ones are bare
   (`test`, `test-host`). Import every PIC10F320 target under a
   distinct **`pic320-`** prefix: `pic320`, `pic320-test`,
   `pic320-test-equiv`, `pic320-test-actuation`, `pic320-test-fault`,
   `pic320-test-gpsim`, `pic320-test-lockstep`, `pic320-test-io`,
   `pic320-coverage-check-fw`, `pic320-analyze`, `program-pic320`.
   Aggregate them under `pic320-test`, then add `pic320-test` to the
   top-level `test` / `test-long` lists **only after it is green**.
2. **Test-file basename collisions.** `test_{config,fault,io,lockstep,
   soak}_pic.cc` exist for both chips. Resolved by directory
   (`test/pic/` = 322, `test/pic10f320/gpsim/` = 320). Keep the `-I`
   include paths chip-specific in the Makefile recipes.
3. **Release image names.** Already disambiguated by the `_pic10f320`
   suffix — no rename needed. Verifier must learn them (§4).
4. **Git tags.** Both repos carry `v0.9.0..`. Do not import child tags
   into the shared tag namespace (§9); rely on imported commit history.

---

## 6. Pre-merge checkpoints (do these first)

1. **Reconcile the 5-line pure-core diff.** `diff` of the child's
   `test/model/bypass_pure.{c,h}` / `bypass_types.h` against
   `src/` shows ~5 differing lines each. Confirm they are cosmetic
   (path/guard/comment). **If any line is behavioral, the child has
   been validating against a subtly different core than the parent
   ships — that is exactly the drift this merge exists to kill, and it
   must be resolved (and probably logged as a finding) before the
   vendored copy is deleted.**
2. **Diff-audit the folded formal/host tests** (cbmc 19, symbolic 10,
   model_check 95, host 119) for any assertion that encodes a
   PIC10F320-specific property. Anything real gets migrated into the
   shared test as a target-agnostic check; the rest is drift to discard.
3. **Confirm `model_step.h` / `misra.json` equivalence** between repos
   so folding to the parent copy loses nothing.
4. **Snapshot green baselines**: capture `make test` (parent) and
   child `make test` output/artifacts so post-merge parity is provable.

---

## 7. Phased execution

Each phase ends green and is independently commit-able.

**Phase 0 — Pre-flight.** §6 checkpoints. No tree changes beyond notes.

**Phase 1 — History import.** Bring the child in with authorship
preserved but inert:
```
git subtree add --prefix=_incoming_pic10f320 <child-remote> main
```
Nothing builds from `_incoming_pic10f320/` yet. Parent `make test`
unaffected. (Rationale for subtree over `--allow-unrelated-histories`
in §9.)

**Phase 2 — Fold shared assets.** Delete the vendored core and
duplicate formal/host/MISRA files from the incoming tree; confirm
parent `make test` still green (it never referenced them). Merge MISRA
suppressions with per-file scope.

**Phase 3 — Relocate firmware + PIC10F320 tests.** `git mv` the incoming
firmware to `src/bypass_mcu_pic10f320.c` (**user performs the firmware
move**) and the equiv/actuation/fault/gpsim/fw_coverage trees to
`test/pic10f320/`. Repoint equiv/lockstep includes at `src/bypass_pure.h`.
Still no Makefile wiring → parent `make test` unchanged.

**Phase 4 — Makefile + build.** Add `pic320-*` targets and the
PIC10F320 variant build rules. Verify each PIC10F320 target green in
isolation:
`make pic320`, `pic320-analyze`, `pic320-test-equiv`,
`pic320-test-actuation`, `pic320-test-fault`, `pic320-test-gpsim`,
`pic320-test-lockstep`, `pic320-test-io`, `pic320-coverage-check-fw`,
then the `pic320-test` aggregate. Parent `test` still does **not**
include them yet.

**Phase 5 — Wire into aggregates + release + CI.** Add `pic320-test`
to `test` / `test-long`; extend release manifest + verifier with the
five PIC10F320 images; add PIC10F320 legs to `ci.yml` / `release.yml`;
delete the child's now-redundant Makefile/CI/scripts from the incoming
subtree. Remove the now-empty `_incoming_pic10f320/`.

**Phase 6 — Docs + cleanup.** Land `docs/pic10f320_special_case.md`,
wire the caveat links (§8), merge CHANGELOG lanes, drop the child CI
badge, update `README`/`DESIGN_DOCUMENTATION`/`TOOLCHAIN`. Archive the
old child repo (README pointer to the merged repo; do not delete).

---

## 8. Documentation: the single caveat

Create `docs/pic10f320_special_case.md` as the **one** authoritative
statement, seeded from the child's existing "Relationship to the parent
project" prose and `test/README.md` two-layer explanation (both already
say this well). It must state, once:
- 256-word flash (half the 10F322) → the pure/result-struct
  architecture doesn't fit → logic is inlined into `main()`.
- Assurance the other targets get *for free* by compiling the verified
  core is **recovered** here by proving the inlined firmware
  behaviourally identical to that same core (equiv + lockstep), plus a
  host actuation-sequence test and a fault-injection layer for the
  defensive code valid stimulus can't reach.

Everywhere else links here instead of re-explaining:
- `README.md` — a short "Targets" table row for PIC10F320 with a
  one-line "constrained; see special-case doc" and a link.
- `DESIGN_DOCUMENTATION.adoc` — one paragraph + link, not a parallel
  design narrative.
- `release/<ver>/README.md` + `MANIFEST.md` — mark PIC10F320 images as
  "constrained target (equivalence-proven)" so a downstream reader
  never infers parity with the reference-grade images.

The failure mode to avoid: sprinkling half-caveats across many files
where one drifts out of date. One doc, many links.

---

## 9. Git history and tags

- **Subtree import** (`git subtree add --prefix=…`) over
  `merge --allow-unrelated-histories` because the child files relocate
  anyway; subtree keeps their history reachable and `git log --follow`
  works across the later `git mv`s, preserving blame on the firmware and
  forked harnesses.
- **Do not import child tags** into the shared namespace — `v0.9.0..`
  collide with parent tags. History commits carry the provenance; if a
  PIC10F320 historical tag must be referenceable, import it namespaced
  (`pic10f320/v0.9.5`) rather than bare.
- Keep the archived child repo read-only as an extra provenance anchor.

---

## 10. Release and versioning

- Parent `release/<ver>/` already mixes AVR + PIC10F322 hex per version;
  PIC10F320's five images simply join each **future** release dir.
- The exact-image-set verifier becomes the enforcement point: it must
  list PIC10F320 images explicitly and fail if absent (fail-closed).
- Past child `release/v0.9.*` are **not** back-filled (numbering
  collision, and they predate unification). First unified tag is the
  next parent version; its `CHANGELOG` entry notes "PIC10F320 target
  merged in from former child repo at <child sha>."
- `CHANGELOG.md`: one file, one timeline; use a clear "PIC10F320
  (constrained target)" sub-lane within each entry rather than a
  separate changelog.

---

## 11. CI

- Add PIC10F320 legs to the existing `ci.yml` matrix: build (XC8, 256-word
  budget), `analyze` (cppcheck `pic8-enhanced` + MISRA), and the gpsim
  layers (`libgpsim`). Reuse the parent's existing gpsim/XC8 setup steps.
- `release.yml`: emit + checksum + verify the PIC10F320 images alongside
  the rest.
- Mutation testing stays fail-closed (`MUTATION_ALLOW_SKIP` remains a
  dev-only report concession, never CI/release) — matching both repos'
  current stance.

---

## 12. Definition of done

- [ ] Exactly one `bypass_pure.c` / formal proof set / `misra_rules.txt`
      in the tree; **no** vendored core copy remains.
- [ ] PIC10F320 equivalence + lockstep tests consume `src/bypass_pure.*`
      directly.
- [ ] `make test` (default aggregate) is green and now includes
      `pic320-test`; `make test-long` likewise.
- [ ] Zero MISRA deviations across all targets; PIC10F320 suppressions
      are file-scoped.
- [ ] Release-image verifier lists and requires the PIC10F320 images
      (fail-closed); a deleted PIC10F320 hex breaks the build.
- [ ] `docs/pic10f320_special_case.md` exists and is the sole caveat;
      README / design / release docs link to it and imply no parity.
- [ ] Firmware for every other target is byte-identical to pre-merge
      (the merge touched only PIC10F320 firmware placement, not content).
- [ ] Child repo archived with a pointer; its history reachable in-tree.

---

## 13. Rollback

Every phase is a discrete commit and the parent `test` aggregate stays
green until Phase 5, so rollback is `git revert` of the offending
phase. The child repo remains archived (not deleted) until the merged
repo has cut at least one green unified release, giving a full fallback.

---

## 14. Residual risks

1. **Reference-grade dilution.** The parent's value is its clean "fully
   verified" story; PIC10F320 is a documented exception. Mitigated by
   §8's single-caveat discipline — but it is an ongoing editorial
   burden, not a one-time task.
2. **Forked harness rot.** Lockstep/mutation/fault stay per-target;
   co-location makes drift *visible* but does not prevent it. A
   cross-target review checklist (touch a shared property → check both
   PIC harnesses) is the human control.
3. **Makefile mass.** Parent Makefile is already ~127 KB; PIC10F320
   targets grow it. Acceptable, but a future factor-into-includes pass
   may be worth its own task.
4. **Two PIC chips, near-name harnesses.** `test_*_pic.cc` for 322 vs
   320 differ enough that an edit to the wrong copy is easy. Directory
   separation + distinct `pic-`/`pic320-` target prefixes are the guard.
