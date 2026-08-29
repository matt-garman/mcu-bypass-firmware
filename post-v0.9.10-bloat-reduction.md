# Post-v0.9.10 bloat-reduction work plan

> **Branch-scoped working document.** This file coordinates work on
> `post-v0.9.10-bloat-reduction`. It is not durable product documentation and
> must be removed before release source finalization. The release documentation
> gate intentionally rejects unapproved root-level Markdown working documents.
> Git history will retain the plan after its deletion.

> **Initial review baseline:** `a865148` on 2026-08-27, while `v0.9.10` release
> work was being completed on another system. Before implementation begins,
> reconcile this branch with the final signed `v0.9.10` source/artifact history
> as appropriate. Do not change the in-progress `v0.9.10` release contract from
> this branch.

## Purpose

Reduce maintenance cost, contradiction risk, stale-state risk, repository
surface area, and unnecessary execution without reducing the project's
correctness, robustness, reliability, traceability, reproducibility, or
validation standard.

The primary problem is not redundant firmware logic. It is that current facts
are often represented in several places at once:

- exact resource measurements in multiple mutable documents;
- release identity and topology in multiple current-status declarations;
- programming procedures in three current documents and generated release
  prose;
- current test inventories, check counts, and test mechanics repeated outside
  the executable suite;
- target/variant/resource policy repeated in Make, scripts, CI, local CI, and
  release fixtures;
- completed plans and work journals retained on the active branch beside live
  specifications;
- release metadata repeated in `QUALIFICATION`, `MANIFEST.md`, `SHA256SUMS`,
  per-release READMEs, evidence logs, and workflow inventories.

This plan treats duplication according to its role rather than its line count.

| Duplication class | Default treatment |
|---|---|
| Repeated current facts, measurements, commands, matrices, or status | Eliminate, centralize, or generate |
| Historical work journals on the active branch | Extract durable conclusions, then delete from the branch tip |
| Human views of canonical machine data | Generate and verify; do not maintain independently |
| Independent behavioral or structural oracle | Preserve |
| Immutable signed release evidence | Preserve; package or locate more efficiently only with an authenticated migration |
| Hardware-specific implementation | Preserve unless a refactor has explicit proof obligations and real benefit beyond line reduction |

## Measured starting point

The initial review found the following approximate scale at `a865148`:

| Area | Observation |
|---|---|
| `docs/` | About 13,400 lines |
| `docs/pic10f320_merge_plan.md` | 3,432 lines |
| `docs/v0.9.6_post_release_polish.md` | 3,688 lines |
| Two completed journals above | 7,120 lines, over half of `docs/` |
| `CHANGELOG.md` | 3,897 lines |
| `test/README.md` | 962 lines |
| `Makefile` | 8,612 lines |
| Tracked files | 684 |
| Files under `release/` | 455, about 66.5% of tracked paths |
| Logical bytes under `release/` | About 34% of tracked bytes |
| Release evidence | About 80% of logical `release/` bytes |
| Current `.git` pack | Only about 5.5 MiB; storage is not an emergency |

The repository is not currently large in absolute terms. The reasons to act are
maintainability, reviewability, contradiction risk, and unbounded future growth.

## Non-negotiable guardrails

- Do not lower a resource ceiling, fault-handling guarantee, test strictness,
  release-integrity guarantee, or qualification requirement merely to simplify
  implementation.
- Do not rewrite, retarget, or delete signed historical tags.
- Do not edit historical release files in place to correct current prose.
- Do not remove the only durable copy of historical evidence.
- Do not derive an independent test oracle from the production data it is meant
  to check.
- Do not make supported products discoverable by source-file globbing. Adding a
  file must not silently add a release product.
- Do not generate pin definitions and their device-pack assertions from the
  same authored input; that would turn the assertions into tautologies.
- Do not merge platform-specific static-analysis models merely because their
  currently analyzed source sets overlap.
- Do not collapse different formal/simulation engines into one opinion.
- Do not refactor firmware MCU shells or timing-sensitive output logic solely
  for line-count reduction.
- Agents may modify documentation, tests, scripts, CI, and the Makefile under
  user guidance. Actual `src/` firmware edits, including firmware comments, are
  for the user.
- The user performs Git commits and modifying Git operations manually.
- Every removal must identify where its still-relevant content now lives.
- Every consolidation must identify which independent cross-checks remain.
- Prefer the smallest correct change. Do not introduce a new framework or data
  format when an existing authoritative Make variable or release record can
  serve the role cleanly.

## Target authority map

This was the intended end state. BR-AUTH-01 finalized and published it as the
`Documentation map` section of `README.md`, which is the live authority; the
table below is retained as the plan's own record of what was decided.

| Topic | Intended sole live authority |
|---|---|
| Product overview and target selection | `README.md` |
| Normative firmware and hardware design | `DESIGN_DOCUMENTATION.adoc` |
| General operator flashing safety and workflow | `FLASHING.md` |
| Exact commands for a specific release | Generated per-release `PROGRAMMING.md` or equivalent generated release view |
| Toolchain requirements and pins | `TOOLCHAIN.adoc` plus executable pin definitions |
| MISRA scope, deviations, and maintenance | `MISRA_COMPLIANCE.md` |
| Current test layers, substrates, and aggregate entry points | A concise `test/README.md` |
| Test implementation details and negative cases | Executable tests themselves |
| Hardware field reports and controlled qualification records | `HARDWARE_VALIDATION_LOG.md` |
| Open work | A concise `TODO.md` |
| User-visible change history | `CHANGELOG.md` |
| Release process, trust model, historical errata, and reproduction | `release/README.md` or one clearly named release-policy document |
| Exact per-release source, image, resource, and qualification results | Canonical signed per-release index and retained evidence |
| Historical implementation reasoning | Git history or concise, explicitly scoped decision/safety records |
| Current development status | `[Unreleased]`; no speculative release evidence claim |

## Status vocabulary

Each task should use exactly one of these states in its `Status` field.

| State | Meaning |
|---|---|
| `TODO` | Ready or waiting on stated dependencies |
| `IN PROGRESS` | Actively owned; name the owner/agent in the status line |
| `NEEDS USER` | Requires a firmware source edit or a user policy decision |
| `BLOCKED` | Cannot proceed; record the concrete blocker |
| `DONE <commit>` | Implemented and verified; record the commit after the user creates it |
| `DECLINED` | Deliberately not doing; retain the reason |

## Execution order

The recommended order is:

1. Reconcile the final `v0.9.10` state and establish the authority/lifecycle
   rules.
2. Remove mutable resource snapshots and consolidate target documentation.
3. Simplify active README/changelog/TODO/test documentation.
4. Remove obsolete and duplicate test/build/CI machinery.
5. Introduce the new release index/evidence format prospectively.
6. Consider changing how future release commits relate to development `main`.
7. Perform optional user-owned firmware-source cleanup only after the supporting
   test/build contracts are ready.
8. Run cross-reference, safety-language, release, and full qualification audits.
9. Delete this branch-only plan before release source finalization.

Do not combine the future release-storage topology change with an unreviewed
mass deletion. The tag/provenance model deserves an independently reviewable
phase even if it ships in the same eventual release.

---

# A. Baseline, ownership, and lifecycle

## BR-BASE-01 - Reconcile the final release baseline

**Status:** DONE `756e622`

**Risk:** High if skipped. This branch was created while the release was being
completed elsewhere, so release artifacts, tag history, or final documentation
could advance independently.

**Work:**

- [x] Identify the final qualified source commit, artifact commit, and signed
  tag after the release completes.
- [x] Compare this branch with the final source and artifact history.
- [x] Bring forward the intended final release history using the user's chosen
  non-destructive Git workflow.
- [x] Confirm that historical release directories, once added, remain untouched
  by this cleanup except for prospective policy references outside the
  immutable release directories.
- [x] Record the new baseline commit in this section.
- [x] Confirm the merged tree passes the full aggregate before further
  substantive edits.

**Result:**

The release this section was written against did not complete. `v0.9.10` was
tagged and never published: its tag CI reproduced all 21 images bit-for-bit and
then failed the first gate re-run, because the release workflow exported
`ATTINY_DFP_VER` into every step and the Makefile refuses a release goal under
an unreviewed environment-origin build input. The signed tag and
`release/v0.9.10/` are retained as the record of that cut rather than
rewritten. `v0.9.11` is the completed release and is therefore the baseline
this branch reconciles against.

Reconciled by merging tag `v0.9.11` (`760f5fd`) into this branch as explicit
merge commit `756e622`. No tag, release directory, or artifact commit was
moved or rewritten: `release/v0.9.10/` and `release/v0.9.11/` are each
byte-identical to their own tag in the merged tree. Three documents conflicted
-- `CHANGELOG.md`, `release/README.md` and `test/README.md` -- and each
resolution keeps both sides; the merge commit message records them
individually.

The branch's already-completed items predate this baseline and were merged
forward rather than replayed onto it. No item on this plan now depends on an
unfinished release.

**Acceptance:**

- The branch contains the intended final release history.
- The release tag and artifact commit are not moved or rewritten.
- No cleanup task accidentally changes in-flight release bytes or evidence.

## BR-AUTH-01 - Finalize and publish the authority map

**Status:** DONE `620234f`

**Depends on:** BR-BASE-01

**Rationale:** Consolidation will fail if documents are deleted without first
deciding where future edits belong. A short ownership map is more valuable than
another long narrative.

**Work:**

- [x] Review the target authority map near the top of this plan.
- [x] Decide whether the durable map belongs in `README.md`, a short contributor
  section, or another existing durable document.
- [x] Define document lifecycle labels: live specification, operator guidance,
  compliance record, release evidence, decision/safety record, historical
  release artifact, and branch-only work plan.
- [x] State that Git history, not retained work journals on the branch tip, is
  the default archive for completed plans.
- [x] State that current measurements belong to CI output or release evidence,
  not development prose.
- [x] State that generated human views are not independently maintained sources
  of truth.

**Result:**

Published as a `## Documentation map` section in `README.md`, chosen over a new
root-level document and over an agent-facing section. README is the entry point
a contributor reaches first, a documentation index is already part of its
overview role, and the placement leaves the release gate's durable
root-document allowlist in `scripts/release-documentation.sh` untouched.

The section has three parts. A topic table names one live authority per topic
and covers every durable root-level document -- `README.md`,
`DESIGN_DOCUMENTATION.adoc`, `FLASHING.md`, `TOOLCHAIN.adoc`,
`MISRA_COMPLIANCE.md`, `HARDWARE_VALIDATION_LOG.md`, `TODO.md`, `CHANGELOG.md`
and `AGENTS.md`/`CLAUDE.md` -- plus `test/README.md`, `release/README.md`, the
retained per-release records, the topic documents under `docs/`, the Makefile's
canonical maps, the executable tests, and Git history. A lifecycle table
assigns each durable document exactly one of the seven labels and says how that
label is edited. Three standing rules close it: Git history is the archive for
completed plans, current measurements belong to CI output or retained release
evidence, and generated human views are corrected at their input rather than in
the rendered copy.

Two rows were made more precise than the target map: the exact per-release
programming commands are owned by the generated `MANIFEST.md` inside each
release directory, which is where they are actually rendered, and target,
variant and resource policy is owned by the Makefile's canonical maps, added as
a row because it is one of the duplication classes this plan names.

`README.md` does not yet satisfy its own rule: its opening paragraph and target
table restate the release-scope figures and first-released versions that
`CHANGELOG.md` and the retained release records own. That is BR-README-01's
scope, and the map is what gives that task a defined target rather than a
judgement call.

**Acceptance:**

- Every durable top-level document has one clear role.
- Every topic in the authority map has one live owner.
- Documents may link to another authority but do not restate its mutable data.
- The map is short enough to remain reviewable.

## BR-AUTH-02 - Build a reference and contract inventory before deletion

**Status:** DONE `bc267a8`

**Depends on:** BR-AUTH-01

**Rationale:** Many document paths and section numbers are hard-coded in source
comments, scripts, tests, CI comments, and generated release prose. Deleting a
document first would create dangling references and could silently weaken a
contract test.

**Known references requiring attention:**

- `src/bypass_mcu_pic10f322.c:13`
- `src/bypass_mcu_pic12f675.c:15,32,54,72`
- `src/bypass_pins_pic12f675.h:65`
- `Makefile:3124,3494,6059,6317,7000,7019,7981,8008`
- `.github/workflows/ci.yml:128-139`
- `scripts/release-documentation.sh:40-41`
- `scripts/make-release.sh:2158-2166`
- `test/test_release_preflight.sh:885-886`
- `test/test_release_qualification.sh:7`
- `test/test_resource_tables.py`
- `test/test_resource_tables_contract.py`
- `test/test_makefile_name_contract.py`
- `test/README.md`
- `TOOLCHAIN.adoc`
- `MISRA_COMPLIANCE.md`
- `HARDWARE_VALIDATION_LOG.md`

**Work:**

- [x] Enumerate every live reference to each deletion candidate.
- [x] Classify each reference as normative, historical, generated, test
  contract, source comment, or stale.
- [x] Replace section-number and line-number references with stable named
  anchors where a durable cross-reference remains necessary.
- [x] Identify all tests that enforce the old document topology or exact prose.
- [x] Mark firmware-source comment changes as `NEEDS USER` rather than editing
  them through an agent.

**Result:**

The inventory is keyed to searchable content, not to line numbers, because the
line numbers this section itself listed have already drifted. Of the eight
`Makefile` lines named above, none still holds a document reference; the live
ones are 938, 3128, 3458, 5842, 6730, 6749, 7713 and 7740. `make-release.sh`
2158-2166 and `test_release_preflight.sh` 885-886 no longer reference a
document either. Only `release-documentation.sh` 40-41 and
`test_release_qualification.sh` 7 are still correct. Every entry below is
stated as a name a grep can find.

**Load-bearing documents.** A gate reads these files; deleting one fails a
target rather than dangling a link.

| Document | Bound by | Effect of deletion |
|---|---|---|
| `docs/pic10f320_validation.md` | `test-resource-tables` prerequisite; `release_validate_current_documentation`; `test_makefile_name_contract.py`; `test_resource_tables_contract.py` | Make cannot build the target; preflight loses a bounded current-release declaration; the name-contract negative case loses its input |
| `docs/pic12f675_feasibility.md` | `test-resource-tables` prerequisite; `test_release_qualification.sh`; `test_resource_tables.py` | Make cannot build the target; release qualification fails; the program-word triple check loses its input |
| `docs/context_seu_detection.md` | `test-resource-tables` prerequisite; `test_resource_tables.py`; `test_resource_tables_contract.py` | Make cannot build the target; the five-part resource restatement loses a copy |
| `docs/pic10f320_special_case.md` | `release_validate_current_documentation`; `make-release.sh` generated per-release prose; `test_release_preflight.sh` | Preflight fails, and generated release documents link to a deleted path |
| `docs/flashing_simplicity.md` | `release_validate_flashing_simplicity_status` | The gate fails closed on the missing file. It is also the one document allowed to record retired flashing wording in the past tense, which the raw-writer sweep depends on |

`DESIGN_DOCUMENTATION.adoc` and `CHANGELOG.md` are prerequisites of
`test-resource-tables` on the same terms.

**Free-standing documents.** Referenced only by prose and comments; deletion
dangles references but breaks no gate.

| Document | Live non-document references | Class |
|---|---|---|
| `docs/relay_coil_fault_correction.md` | `src/bypass_hw_iface.h`, ten test files, `run_mutation_tests.sh` | Decision/safety record cited as rationale by the tests that enforce the policy |
| `docs/phase2_pic_shell.md` | `src/bypass_mcu_pic10f322.c`, `src/bypass_mcu_pic12f675.c`, `DESIGN_DOCUMENTATION.adoc` | Normative cross-reference plus source comments |
| `docs/pic10f320_merge_plan.md` | `.gitignore`, `Makefile` | Historical, but both references are live and neither is prose |
| `docs/pic10f320_feasibility.md` | none outside `docs/` and `CHANGELOG.md` | Historical |

**Fragile anchors.** Section and line numbers into a document that is about to
be consolidated. Two are already wrong, which is the finding this task exists
to produce:

- `docs/flashing_simplicity.md` cites `docs/pic12f675_feasibility.md:700` as
  section 4.5; line 700 is inside section 4.4.1.
- `docs/flashing_simplicity.md` cites `docs/pic12f675_feasibility.md:1094` as
  section 8; line 1094 is inside section 7.

The remaining section-number references are `DESIGN_DOCUMENTATION.adoc` (five,
into `phase2_pic_shell.md` and `pic12f675_feasibility.md`), the `Makefile`
(five, into `pic12f675_feasibility.md`), `.gitignore` (one, into
`pic10f320_merge_plan.md`), and the cross-references among the `docs/`
documents themselves. Each must become a named anchor -- a quoted heading or a
searchable phrase -- before its target is renumbered.

**Firmware source comments -- NEEDS USER.** Nine, three more than this section
listed. Five name a document only and survive any renumbering:
`src/bypass_compile_checks.h`, `src/bypass_hw_iface.h`,
`src/bypass_mcu_pic10f320.c`, `src/bypass_mcu_pic10f322.c` and
`src/bypass_mcu_pic12f675.c` line 15. Four carry section numbers into
`docs/pic12f675_feasibility.md` and break on renumbering:
`src/bypass_mcu_pic12f675.c` at sections 4.4.1, 8 item 1 and 8 item 2, and
`src/bypass_pins_pic12f675.h` at section 4.2 and section 8 item 9. No agent
edits any of them.

**Tests enforcing document topology or prose.** `test_resource_tables.py` and
`test_resource_tables_contract.py` require the same measurements in four
documents; that duplication is BR-RES-01's subject and the synchronization
check is BR-RES-02's. `release_validate_current_documentation` requires bounded
current-release declarations in four documents.
`release_validate_flashing_simplicity_status` requires a status banner and
per-version update markers in one. The PIC12F675 flashing contract binds
`README.md`, `FLASHING.md` and `release/README.md` to one story. None of these
may be deleted merely because its input document is consolidated: each
underlying invariant is either moved to the document that inherits the role or
retired deliberately, and the retirement recorded.

**Acceptance:**

- Every deleted path has zero unintended live references.
- Historical release directories are excluded from current-reference rewrites.
- No source comment is modified by an agent.
- No test disappears merely because its old document input disappeared; its
  underlying invariant is either retained elsewhere or deliberately retired.

---

# B. Resource information and release-bound measurements

## BR-RES-01 - Remove mutable current resource tables from development docs

**Status:** DONE `e7c4f68`

**Depends on:** BR-AUTH-01, BR-BASE-01

**Current duplication:**

- `DESIGN_DOCUMENTATION.adoc:1155-1347`
- `docs/context_seu_detection.md:242-276`
- `docs/pic12f675_feasibility.md:20-25`
- resource statements in `CHANGELOG.md`
- `test/test_resource_tables.py`
- `test/test_resource_tables_contract.py`

`CHANGELOG.md:20-22` already states the intended model: exact source, toolchain,
image hashes, flash usage, and validation evidence belong to the release record.

**Keep in live source documentation:**

- Physical flash/RAM/stack capacities.
- Reviewed hard ceilings and reserved margins.
- Which build gates enforce each ceiling.
- Measurement units and methods: bytes versus PIC program words, static data
  versus stack frame versus whole-path high-water mark.
- Architectural consequences, such as why PIC10F320 cannot use the modular
  implementation and why PIC10F322 flash remains binding.
- Qualitative statements that are stable under ordinary code changes.

**Move out of live development documentation:**

- Exact per-image candidate usage.
- Current percentages and free-space totals.
- The current largest image.
- Current stack maxima and current static-data totals.
- Statements such as "leaves N words free today."

**Work:**

- [x] Replace the design document's candidate resource tables with capacities,
  ceilings, measurement definitions, and architectural consequences.
- [x] Point readers to the latest signed release record for exact measurements.
- [x] Document the Make/CI commands that produce ephemeral candidate reports.
- [x] Ensure every build still fails at the reviewed ceiling.
- [x] Remove current resource copies from feature/feasibility documents.
- [x] Keep historical measurements only when they establish a past design
  decision, and bind them to a specific commit/tag/toolchain rather than calling
  them current.

**Result:**

Done together with BR-RES-02, because they are one atomic change: every
expectation the gate held came from `parse_design()` reading
`DESIGN_DOCUMENTATION.adoc`, including the `--require-all-images` mode that
emits the release's `RESOURCE_TABLES_RESULT`. Deleting the tables first would
have left `make test` red and the release evidence path unable to run, so the
plan's arrow from BR-RES-02 to BR-RES-01 is inverted for the part that matters.
The user chose the fused commit over a two-step landing.

Five live copies are now zero. `DESIGN_DOCUMENTATION.adoc`'s "Resource
Utilization" section (197 lines, now 187) opens with a capacity-and-ceiling
table naming the Makefile variable that declares each ceiling and the goal that
enforces it, then a new "Units and methods" subsection separating the three RAM
quantities this project measures -- static data, per-function stack frame, and
whole-path high-water mark -- because the old text let a frame bound be read as
a maximum. The per-family subsections keep the architectural consequences and
lose the figures: the PIC10F322 is still the binding constraint and says so
without quoting a margin, and the PIC10F320's margins are still the whole story
of that target but are now told through the decisions they forced rather than
through this week's word counts. The ephemeral candidate reports are named by
command: `make attiny13a-size` plus each PIC and AVR-XT build goal, which print
per-variant usage against the ceiling as they gate it.

`docs/context_seu_detection.md` keeps its F2-landing measurement, which
establishes a design decision, and drops the current matrix it also carried;
its "Resource qualification" table now lists budgets and the goal that
enforces each.
`docs/pic12f675_feasibility.md`'s bounded current-status block keeps the gates
and the composition of persistent state and drops the occupancy. `CHANGELOG.md`
kept its PIC10F322 sentence -- it sits inside the historical `[0.9.10]` section
and records why the fold had to be spelled compactly -- but no longer calls
those images current.

Two references outside the plan's list also pointed at the tables as the owner
of current figures and were retargeted: `TOOLCHAIN.adoc` and
`docs/relay_coil_fault_correction.md`. The latter's `242`-word PIC10F320 figure
is now bound to `v0.9.10`. `Makefile`'s PIC12F675 budget comment justified the
part choice with "the tightest variant lands at 55.9%, against the 322's
98.0%";
55.9% had already drifted from the design document's own 57.1%, which is this
task's thesis appearing in the one file the tables never checked.

`docs/pic10f320_validation.md` needed no edit. Its measurements were already
bound to the tag that produced them, which is the form BR-RES-01 asks for.

**Acceptance:**

- A firmware size change requires no documentation edit before release.
- Development builds still enforce all resource ceilings.
- Release creation still requires complete resource evidence for every image.
- The latest signed release page or bundle contains exact measurements.
- No live document calls unreleased measurements final evidence.

## BR-RES-02 - Retire cross-document resource synchronization tests

**Status:** DONE `e7c4f68`

**Depends on:** BR-RES-01

**Rationale:** `test/test_resource_tables.py` is valuable evidence that the
current copies have drifted before, but keeping all copies synchronized treats
the symptom by making prose duplication a tested interface.

**Work:**

- [x] Separate actual binary/resource measurement from prose parsing.
- [x] Preserve strict release-time measurement of all canonical images.
- [x] Preserve arithmetic validation, malformed-tool-output rejection, missing
  image rejection, and source-commit binding.
- [x] Delete checks whose only purpose is comparing mutable values across prose
  files that no longer carry those values.
- [x] Use arbitrary synthetic values in parser contract tests rather than
  restating the current production matrix.
- [x] Rename targets/scripts if their remaining purpose is no longer "resource
  tables."
- [x] Update `Makefile`, release scripts, CI, test inventory, and generated
  documentation contracts accordingly.

**Result:**

`test/test_resource_tables.py` is 780 lines to 544. Gone: `parse_design`,
`check_tables`, `check_design_prose`, `check_seu_table`,
`check_other_documents`, `check_nonflash_claims`, and the AsciiDoc table parser
and percentage arithmetic that served them. The gate reads no document at all
now; its prerequisites are the `Makefile` and `test/avr/test_sim.c`.

Measurement is separated from prose by giving the ceilings one owner. Fifteen
reviewed limits are parsed from the Makefile that declares them -- a missing,
duplicated or non-constant definition fails closed -- and checked for coherence
against the datasheet capacities, which are silicon and stay in the checker: no
flash ceiling may exceed its part's capacity, which is the defect the Makefile
records from its own history when one shared word budget silently gated the
half-size part. Images are then measured exactly as before and compared against
those ceilings instead of against a transcribed figure. The Classic AVR
free-SRAM floor is read from the canary gate in `test/avr/test_sim.c` that
enforces it, rather than copied.

The release evidence layer keeps every property BR-RES-02 asked be preserved --
21-of-21 images, 12 AVR static-data measurements, missing-image and
malformed-tool-output rejection, source-commit binding, and the unchanged
`RESOURCE_TABLES_RESULT` record -- and stops memorizing the current matrix.
Each
retained record is now checked against its own arithmetic: a canary observation
carries the whole SRAM map it was derived from, so static + stack + free must
close on the device size and the margin must land where the map says it does; a
return-stack witness must account for peak, reserve and spare across the whole
hardware stack. A truncated or hand-edited log fails on itself, without this
file knowing what the figures ought to be. The PIC witness is parsed from
`STACK-DEPTH PASS`, a single-printf line, rather than from the multi-line
report
whose separate writes a parallel release build can interleave.

`test/test_resource_tables_contract.py` builds its own repository fixture -- a
Makefile of arbitrary ceilings and a synthetic canary gate -- so no production
figure appears in it. Five negative cases were added to the four it had: an
image over its ceiling, a corrupted Intel HEX checksum, a ceiling wider than
the
silicon, a missing reviewed ceiling, and an internally inconsistent record of
each evidence kind.

The target was NOT renamed, and the decision is deliberate. `resource_tables`
is
the name of the retained evidence file, the machine record, the `QUALIFICATION`
key and the `MANIFEST.md` line in two published releases; renaming it would
orphan those artifacts to rename a goal whose purpose -- resource evidence --
has not actually changed. Only `test/README.md`'s description of what it proves
needed updating.

**Acceptance:**

- Release resource measurement remains fail-closed.
- Development documentation contains no current numeric table for the test to
  synchronize.
- The suite tests measurement behavior, not redundant prose formatting.

## BR-RES-03 - Publish release resource data as a generated release view

**Status:** TODO

**Depends on:** BR-RES-01, BR-REL-01

**Work:**

- [ ] Define the exact release resource fields and units.
- [ ] Include each canonical image exactly once.
- [ ] Include hard ceiling, measured usage, free margin, tool identity, and
  measurement method where appropriate.
- [ ] Include static data, stack, and PIC return-stack results only when the
  release evidence actually measures that quantity.
- [ ] Do not imply that per-frame GCC stack data is a whole-path high-water
  measurement.
- [ ] Generate the human table from canonical release data.
- [ ] Make the release publication page expose the generated table.

**Acceptance:**

- Released users can inspect exact resource use without checking out source.
- The release table is source-commit- and toolchain-bound.
- There is one machine authority for every displayed value.

---

# C. PIC documentation consolidation

## BR-PIC-01 - Create a coherent PIC architecture section in DESIGN_DOCUMENTATION

**Status:** DONE `b1b98c3`

**Depends on:** BR-AUTH-01, BR-RES-01

**Rationale:** The design document already contains cross-target architecture,
PIC pin/timing material, watchdog behavior, output-shadow behavior, and the
shared-core/per-shell model. Stable target design should live there rather than
across completed feasibility and merge documents.

**Work:**

- [x] Define a clear PIC architecture hierarchy covering common Model-B behavior
  and per-part differences.
- [x] Give PIC10F322, PIC10F320, and PIC12F675 stable named anchors.
- [x] Distinguish enhanced mid-range PIC10F32x from classic mid-range
  PIC12F675.
- [x] Keep design requirements separate from current test results.
- [x] Keep operator programming transactions in `FLASHING.md`, not in the
  design section.
- [x] Keep tool installation/version details in `TOOLCHAIN.adoc`.
- [x] Keep hardware qualification results in `HARDWARE_VALIDATION_LOG.md`.

**Result:**

`DESIGN_DOCUMENTATION.adoc` gains a `PIC Architecture` section carrying seven
anchors: `pic-architecture`, `pic-model-b`, `pic-core-generations`,
`pic-clock-and-power`, `pic10f322-architecture`, `pic10f320-architecture` and
`pic12f675-architecture`. These are the document's first explicit anchors, so
other documents can now deep-link a PIC design statement instead of naming a
section title that renumbering would break.

The hierarchy is model first, then generation, then part. `pic-model-b` states
the polled-tick/pure-fault-watchdog model once for all three PIC targets --
the loop shape, why reaching the pet is the liveness proof, the three reasons
the model was chosen, the two accepted consequences, and why `INTCON` is
absent from every PIC guard set. `pic-core-generations` carries a
nine-row table separating the enhanced mid-range PIC10F32x from the classic
mid-range PIC12F675 by facility, with a consequence column, and states the
conclusion that follows: the PIC12F675 shell is a rewrite of the PIC10F322
shell rather than a port, sharing the interface and the core and nothing
below them.

The three per-part subsections each state what that part does differently and
why. PIC10F322 is written as the reference: four I/O pins forcing the map, a
tick that is configured rather than constructed, a watchdog independent of the
tick, and the two integrity checks that are deliberately stronger than the
obvious version. PIC10F320 is written from its one number: 256 words, the
measured non-fit, the hand-inlining seam, what the equivalence lane closes and
how far, the deliberately omitted general latch match against the coil-bit
guard that was affordable, and the target-selection consequence. PIC12F675 is
written from six differences: no output latch and the read-modify-write hazard
the SRAM shadow answers, the fixed clock whose calibration word lives in
flash, the single shared prescaler that makes the tick 1.024ms, the
three-path analog hazard surface, the one register carrying three
safety-relevant fields, and the pin map that is not the PIC10F32x map renamed.

Two existing sections moved rather than being duplicated. `PIC Power /
Current Draw` became the `pic-clock-and-power` subsection with its body
verbatim; its two `Datasheet References` pointers, which said "the section
above" while pointing below, now cross-reference the anchor. The
`Multi-MCU Architecture` exception subsection keeps its place in the
cross-target argument and hands the architecture itself to
`pic10f320-architecture`, so the two accounts no longer both claim to be
normative.

Ownership was settled in the two documents that also claimed it.
`docs/pic10f320_special_case.md` said it was "the single authoritative
statement of that difference"; it now names the design anchor as normative and
scopes itself to the assurance comparison and the manual shared-surface
checklist. `docs/phase2_pic_shell.md` §1 now names `pic-model-b` as normative
and scopes itself to the dated decision record. Both files are retired by
BR-PIC-02 and BR-PIC-03; until then neither is a second owner.

One current measurement that BR-RES-01 missed was removed here, because it is
in the PIC material this task owns: `Failsafe Mechanisms` stated that "the
current images use 476/502/493 of 512 words". It now states the capacity fact
that paragraph actually needs -- 512 words is the smallest budget that still
holds the core, the defensive layer and the fold.

No measurement, toolchain version, operator transaction or qualification
result was added. `asciidoctor` renders the document without warnings and every
cross-reference resolves.

**Acceptance:**

- A reviewer can understand all three PIC architectures from the design
  document without following historical plan documents.
- Each target-specific difference has one normative explanation.

## BR-PIC-02 - Fold PIC10F322 phase notes into the design document

**Status:** DONE (commit pending)

**Depends on:** BR-PIC-01

**Source:** `docs/phase2_pic_shell.md`, 259 lines

**Content to preserve:**

- Model-B polled timer tick and watchdog decision.
- Datasheet-derived timer and clock facts.
- Pin map and electrical assumptions.
- Behavioral divergence from ISR-driven AVR shells.
- Single-threaded concurrency implications.
- Stable validation rationale at the design-property level.

**Content not to preserve as live duplication:**

- Phase/project sequencing language.
- Current target lists or exact lane inventories.
- Commands/counts already owned by `test/README.md` or Make.
- Section-number references to the soon-to-be-deleted file.

**Work:**

- [x] Merge stable material into named design anchors.
- [x] Update current references to those anchors.
- [x] Delete `docs/phase2_pic_shell.md` from the branch tip.

**Result:**

`docs/phase2_pic_shell.md` is deleted. BR-PIC-01 had already restated its §1
(Model B) and most of §4 (the two stronger integrity checks, the guarded SFR
set, the loop shape) in `pic-model-b` and `pic10f322-architecture`, so this task
carried the residue and cut the pointers.

What moved into `DESIGN_DOCUMENTATION.adoc`:

- The ISR spike is now stated where the decision is stated. `pic-model-b` had
  summarized it and delegated the numbers to §1; it now carries them -- the
  relay variant's link failure and its cause (a two-word psect against a
  one-word largest free range, so fragmentation at a full ceiling rather than a
  program two words too large), and six of eight return-stack levels consumed
  even with flash freed -- bound to their 2026-08-05 date and marked as a
  never-shipped spike build, per BR-RES-01's rule for historical measurements.
- The prescale-code caution from §2: the datasheet prose is incomplete on the
  TMR2 prescale field and the register table is authoritative, with the device
  pack header authoritative for register and CONFIG names. Datasheet References
  had asserted this fact while citing the deleted file for it; it is now stated
  in `pic10f322-architecture` and the table's evidence column carries the
  divisor arithmetic itself (FOSC/4 = 500 kHz, 1:4 to 125 kHz, `PR2` = 124).
- The watchdog period choice: ~256 ms mirroring the AVR Classic's 250 ms, and
  the earlier ~32 ms selection that gave only ~1.4x over the worst-case awake
  burst and was lengthened for that reason.
- Why checking `OSCCON.IRCF` covers the whole register: it is the only
  read/write field the part implements there.
- §7's validation split, as the closing paragraph of `pic10f322-architecture`:
  the core's suites carry the algorithm because the core is compiled unchanged,
  so what remains is shell validation, and `test/README.md` owns the lanes.
- §3's logical pin map, as a table in the existing PIC10F322 pinout section,
  with the AVR Classic bit indices beside it. The point it exists to make is
  that no logical pin shares a bit index across the two families, which is why
  pin maps are per-MCU rather than in the drivers.

Not carried, deliberately: the SFR address list (the device pack header is the
authority and the design document does not otherwise inventory addresses), the
hardware-contract operation table (a restatement of the shell, and the MISRA
8.7 rationale behind its `static` helpers is already in Multi-MCU
Architecture), the §5 behavioural-divergence argument (already in Caveats and
Limitations and Asymmetric Debounce Timing, both gated), and the XC8 `sizeof`
and `const`-SFR gotchas, which are toolchain notes rather than design record.

Every live reference retargeted, so no current file reads the deleted path:
four in `DESIGN_DOCUMENTATION.adoc`'s Datasheet References, four in
`docs/pic12f675_feasibility.md` §4, two rows in that document's §11 (retitled
to name the correction rather than the vanished document), one in
`docs/relay_coil_fault_correction.md`'s Related list, and one dated audit note
in `docs/pic10f320_merge_plan.md` annotated with the fold rather than rewritten.
`CHANGELOG.md`'s two mentions are historical release records and stay.

Two firmware comments still name the deleted path --
`src/bypass_mcu_pic10f322.c:13` and `src/bypass_mcu_pic12f675.c:15`, both the
`Tick/WDT model "B" (see docs/phase2_pic_shell.md)` line. Those are user-owned
edits and are BR-PIC-05's, which depends on this task; the replacement target
is `DESIGN_DOCUMENTATION.adoc#pic-model-b`.

No script, test, Makefile or CI path referenced the file, so the deletion needed
no gate change.

One workflow note, since this is the branch's first content deletion under the
current gate set. `make test` cannot go green until the deletion is staged:
`test_release_preflight.sh`'s `tree_snapshot()` walks `git ls-files -co` and
`stat`s every path, so a tracked file that is gone from disk but still in the
index aborts the snapshot before the preflight body runs. Verified by isolation
-- restoring the file and running the gate alone gives 214 checks, 0 failures,
with every other edit in place. The failure text is `could not snapshot the
working tree` and does not name the path, which is worth a look on its own.

**Acceptance:**

- No current file depends on `docs/phase2_pic_shell.md`.
- Timer/WDT and polling rationale remains explicit and reviewable.

## BR-PIC-03 - Consolidate the PIC10F320 constrained-target case

**Status:** TODO

**Depends on:** BR-PIC-01, BR-RES-01

**Sources:**

- `docs/pic10f320_feasibility.md`, 304 lines
- `docs/pic10f320_special_case.md`, 262 lines
- `docs/pic10f320_validation.md`, 568 lines
- `docs/pic10f320_merge_plan.md`, 3,432 lines

**Normative content to preserve in DESIGN_DOCUMENTATION:**

- 256-word physical constraint.
- Measured conclusion that the modular architecture does not fit.
- Self-contained source architecture.
- Manual inlining seam and its trust consequence.
- Prefer-another-target guidance.
- Deliberately omitted general output-latch integrity check.
- Relay-specific mitigation and residual LED/analog-control distinction.
- Manual shared surface that must remain behaviorally aligned.
- The assurance distinction between compiling the verified core and proving a
  separate expression equivalent.

**Current user-facing content to preserve in README:**

- PIC10F320 remains release-supported.
- It is the constrained exception.
- Prefer another supported part when MCU choice is available.
- Link to the stable PIC10F320 design anchor.

**Evidence content to preserve elsewhere:**

- Exact current/release execution results belong in signed release evidence.
- Current targets, substrates, mechanics, and coverage boundaries belong in the
  concise test inventory.
- Standing expected-image digests remain in
  `test/pic10f320/expected_images.sha256`.
- Historical imported tags and Git object identity remain in Git.
- The v0.9.6 migration/release evidence remains under its signed historical tag.

**Historical material that need not remain live:**

- Child-project merge sequencing.
- Namespace collision resolution.
- Completed phase checklists.
- Branch-era status and errata blocks.
- Old target names beyond concise historical reproduction guidance.
- Exact old test counts copied into prose.
- One-shot migration transcripts already superseded by standing gates and
  signed releases.

**Work:**

- [ ] Extract the normative constrained-target design into one dedicated design
  section.
- [ ] Preserve one concise historical measurement statement tied to its
  toolchain/commit if needed to support the "does not fit" decision.
- [ ] Ensure exact current resource numbers are handled by BR-RES-01.
- [ ] Move remaining open hardware concerns to `TODO.md` or
  `HARDWARE_VALIDATION_LOG.md` as appropriate.
- [ ] Update README target-selection guidance.
- [ ] Update test documentation to refer to the new design anchor.
- [ ] Delete `docs/pic10f320_merge_plan.md`.
- [ ] Delete `docs/pic10f320_special_case.md` after references move.
- [ ] Delete `docs/pic10f320_validation.md` after unique durable facts are
  accounted for.
- [ ] Delete `docs/pic10f320_feasibility.md` if its concise decision evidence is
  fully retained; otherwise reduce it to a short immutable decision record with
  no current status or measurements.

**Acceptance:**

- PIC10F320's weaker architectural property is still stated prominently and
  honestly.
- No exact current results are maintained outside release evidence.
- No merge-process narrative is needed to understand or validate the target.
- All standing assurance gates remain.

## BR-PIC-04 - Consolidate PIC12F675 feasibility into current authorities

**Status:** TODO

**Depends on:** BR-PIC-01, BR-RES-01, BR-FLASH-01

**Source:** `docs/pic12f675_feasibility.md`, 1,659 lines

The document explicitly says at lines 36-41 that its prospective body is
historical and overridden by a current-status block. Its ownership table at
lines 1642-1650 already points stable topics to the design, toolchain, test,
release/flashing, and MISRA documents.

**Normative content to preserve in DESIGN_DOCUMENTATION:**

- Classic mid-range core distinction.
- No `LATx`; SRAM GPIO output shadow and read-modify-write hazard.
- Fixed 4 MHz internal oscillator and factory OSCCAL dependency.
- CONFIG `BG<1:0>` factory-trim significance.
- TMR0 four-rollover 1.024 ms tick.
- Shared timer/watchdog prescaler decision.
- Comparator/ADC initialization and guard surface.
- Pin map and input/output electrical consequences.
- Model-B polling behavior and blocking-actuation consequences.
- Calibration-image derivation boundary: simulator-derived images never become
  shipping/programming images.

**Content to move elsewhere:**

- Real-programmer trim preservation, ipecmd operation, and GP2 readback bench
  gaps to `HARDWARE_VALIDATION_LOG.md` and concise TODO IDs.
- Current lane inventory and mechanics to `test/README.md`.
- Operator transaction to `FLASHING.md` and generated per-release programming
  guidance.
- Tool versions and installation to `TOOLCHAIN.adoc`.
- Exact results and resource figures to signed release evidence.

**Content to retire:**

- Prospective port sequence.
- Historical repository-integration plan.
- Reproduction instructions for unretained throwaway spike sources.
- Current-status override block.
- Duplicated test lists and current counts.

**Work:**

- [ ] Extract all still-current target design into named design anchors.
- [ ] Reconcile open risks with existing TODO and hardware-log entries.
- [ ] Ensure no hardware-qualification claim is strengthened during the move.
- [ ] Delete `docs/pic12f675_feasibility.md` after all references are resolved.

**Acceptance:**

- PIC12F675 remains clearly release-supported in software and not hardware
  qualified.
- The OSCCAL/BG failure mode remains prominent in operator guidance.
- The design document explains the implementation without prospective tense.
- Current test results and resource figures are release-bound rather than copied
  into design prose.

## BR-PIC-05 - Update firmware-source documentation references

**Status:** NEEDS USER

**Depends on:** BR-PIC-02, BR-PIC-03, BR-PIC-04

**Files known to require user review:**

- `src/bypass_mcu_pic10f322.c`
- `src/bypass_mcu_pic12f675.c`
- `src/bypass_pins_pic12f675.h`
- Any additional `src/*.c` or `src/*.h` references found by BR-AUTH-02

**Work:**

- [ ] Replace references to deleted documents with stable design anchors.
- [ ] Correct any stale target naming or current-state claims found during the
  sweep.
- [ ] Confirm comment-only changes preserve exact generated images where the
  compiler/toolchain is available.

**Acceptance:**

- No firmware source comment refers to a deleted path.
- User performs the source edits.
- Relevant image identity/resource/qualification gates are rerun.

---

# D. Programming and user guidance

## BR-FLASH-01 - Make FLASHING.md the sole live operator procedure

**Status:** TODO

**Current duplication:**

- `README.md:104-115,163-296`
- `FLASHING.md:1-275`
- `release/README.md:211-272,376-541`
- Generated release guidance in release scripts

This duplication has already produced safety-relevant contradictions, recorded
in `CHANGELOG.md:42-87` and `CHANGELOG.md:166-195`.

**Work:**

- [ ] Keep general operator safety, hardware prerequisites, programmer choices,
  and transaction semantics in `FLASHING.md`.
- [ ] Reduce README programming content to a quickstart and prominent links.
- [ ] Remove full command sequences from `release/README.md` except where it is
  explicitly describing historical releases or the release-process contract.
- [ ] Keep repeated short safety warnings where omission would create physical
  risk.
- [ ] Do not repeat PIC12F675 transaction steps in several files.
- [ ] Clearly distinguish downloaded-release programming from development and
  release-provenance Make targets.

**Acceptance:**

- There is one maintained general procedure.
- A command change normally requires editing one source or generated
  specification, not three documents.
- PIC12F675 is never presented as a raw-write target.
- The published/software-tested/not-hardware-qualified distinction remains.

## BR-FLASH-02 - Generate exact per-release programming guidance

**Status:** TODO

**Depends on:** BR-FLASH-01, BR-REL-01

`docs/flashing_simplicity.md:272-334` already outlines a generated
`PROGRAMMING.md` concept. Preserve the useful proposal without retaining the
entire branch-era discussion.

**Work:**

- [ ] Define one machine programming specification or derive commands from
  existing authoritative release/build data.
- [ ] Generate exact image names, fuse/CONFIG values, tool requirements, and
  command templates for the release.
- [ ] Include the generated guide in the signed release asset/index contract.
- [ ] Test behavior and safety invariants, not only rendered sentence spelling.
- [ ] Keep user-selected facts such as port, programmer, and power arrangement
  explicit rather than pretending they can be generated.
- [ ] Ensure PIC12F675 guidance invokes the release helper and never a raw
  writer.

**Acceptance:**

- A downloaded release is self-contained for programming guidance.
- Exact commands are tied to the exact released assets.
- Generated guidance and release index cannot disagree silently.

## BR-FLASH-03 - Retire the flashing-simplicity work journal

**Status:** TODO

**Depends on:** BR-FLASH-01, BR-FLASH-02 or explicit deferral of BR-FLASH-02

**Source:** `docs/flashing_simplicity.md`, 678 lines

**Work:**

- [ ] Preserve shipped decisions in their live authorities.
- [ ] Preserve any still-open generated-guidance work as concise TODO tasks.
- [ ] Remove branch-era current-state/proposal interleaving.
- [ ] Delete `docs/flashing_simplicity.md`.
- [ ] Remove release preflight tests that exist only to keep its status banner
  synchronized with implementation updates.

**Acceptance:**

- No current safety procedure depends on reading a partly implemented proposal.
- Remaining work is visible in TODO without preserving the entire discussion.

---

# E. Historical and feature-specific documentation

## BR-DOC-01 - Delete the completed v0.9.6 polish journal

**Status:** DONE `9b6dfc3`

**Historical source:** `docs/v0.9.6_post_release_polish.md`, 3,688 lines,
retained in Git history at commit `69f8bbf`

**Rationale:** The file says all 44 items are complete and warns not to use it
for current status. Git history and the changelog retain the work. Keeping the
full agent coordination protocol and per-item execution journal in the active
tree increases search noise and stale-reference exposure.

**Work:**

- [x] Identify any still-live requirement cited only from this journal.
- [x] Move any genuinely open item to concise TODO form. The two deferred
  follow-ons are already tracked by BR-TEST-03 and BR-TEST-08.
- [x] Confirm durable safety decisions have a current authority.
- [x] Delete the file.
- [x] Update release-documentation tests that special-case this branch-only
  filename family.

**Acceptance:**

- No current behavior or release rule depends on the completed journal.
- Git history remains the detailed record.

## BR-DOC-02 - Reduce the deferred Makefile-refactor record

**Status:** DONE `5ce3f59`

**Historical source:** `docs/makefile_refactor.md`, 284 lines, retained in Git
history at commit `9b6dfc3`

**Durable conclusion:** Do not split the Makefile merely because it is long;
the real costs are consumers that assume one file and hardware-specific PIC
duplication. Revisit only under explicit triggers.

**Work:**

- [x] Preserve the decision and revisit triggers in a concise declined/revisit
  TODO entry or short decision record.
- [x] Preserve the current warning about source-text, sandbox, rebuild, and
  release-provenance consumers.
- [x] Delete the long analysis document.

**Acceptance:**

- Agents do not repeatedly propose an unqualified Makefile split.
- The active tree does not retain 284 lines to communicate "deferred."

## BR-DOC-03 - Reduce the non-blocking output feasibility analysis

**Status:** DONE `9c16f96`

**Historical source:** `docs/non-blocking_output_schemes_feasibility.md`, 1,523
lines, retained in Git history at commit `5ce3f59`

**Risk:** High if deleted without extraction. The analysis contains safety
properties and an acceptance checklist for a possible future actuation redesign.

**Work:**

- [x] Preserve the final recommendation.
- [x] Preserve the relay-coil safety properties that a non-blocking redesign
  must maintain.
- [x] Preserve immediate-abort, watchdog, tick-source, progress-observation,
  transient-state, and mutation requirements.
- [x] Preserve measured feasibility conclusions only as dated historical
  evidence, not current resource data.
- [x] Convert any actionable future redesign into a concise TODO with explicit
  proof obligations.
- [x] Delete the full spike analysis after the concise record is reviewed.

**Reference disposition:** The remaining exact path in the `v0.9.10` changelog
is an intentional historical statement about that release's source tree, where
the cited record exists; it is not a current authority.

**Acceptance:**

- A future implementer can recover the required safety/proof checklist quickly.
- The active tree does not preserve the entire exploratory derivation.

## BR-DOC-04 - Decide the fate of feature-specific design records

**Status:** TODO

**Candidates:**

- `docs/context_seu_detection.md`, 336 lines
- `docs/relay_coil_fault_correction.md`, 398 lines

These are not completed merge plans. They contain current assurance and safety
rationale, so deletion is not automatic.

**Decision criteria:**

- Keep a separate document only if it is a deliberately reviewable safety case
  or decision record with a scope distinct from the main design document.
- Otherwise move normative design to `DESIGN_DOCUMENTATION.adoc`, test mechanics
  to `test/README.md`, exact results to release evidence, and open work to TODO.
- Never maintain exact current resource figures in these records.
- Avoid repeating the same design requirements both here and in the design
  document.

**Work:**

- [ ] Classify each file as live safety case, concise ADR candidate, or material
  to merge into the design document.
- [ ] If retained, add a short scope banner and remove duplicated current data.
- [ ] If merged, delete the original after reference migration.

**Acceptance:**

- Each retained feature document has a unique assurance purpose.
- No feature document acts as another current status/resource/test-results page.

---

# F. Active documentation simplification

## BR-README-01 - Reduce the root README to overview and entry points

**Status:** TODO

**Current size:** 335 lines

**Keep:**

- Product purpose.
- Supported target table.
- Prominent PIC10F320 assurance caveat.
- Prominent PIC12F675 programming/calibration warning.
- Supported output-stage summary.
- Honest hardware-qualification status.
- Minimal source-build quickstart.
- Links to design, flashing, toolchain, tests, hardware evidence, and releases.

**Move or remove:**

- Full PIC12F675 programming transaction.
- Detailed retained-matrix mechanics.
- Per-target comprehensive test command inventories.
- Historical v0.9.8 cleanup instructions except where still needed for a user
  upgrading an old checkout; evaluate whether tag-local docs suffice.
- Exact current test claims better owned by the test inventory.

**Acceptance:**

- A new user can choose a target and find the correct next document quickly.
- README is not an alternative operator manual, test manual, or release policy.
- Safety warnings remain visible without duplicating procedures.

## BR-TESTDOC-01 - Convert test/README.md into a concise assurance map

**Status:** DONE `a64c25e`

**Current size:** 962 lines at plan time; 1,001 at implementation, now 625.

Rows around `test/README.md:523-550` restate extensive negative fixtures and
exact counts already encoded by tests. This makes documentation maintenance part
of ordinary test changes and can turn prose formatting into a tested interface.

**Keep:**

- Execution-substrate directory layout.
- Assurance layers and the property each establishes.
- Authoritative aggregate entry points.
- Required versus optional tool behavior.
- Fail-closed versus skip-clean semantics.
- Known simulator/hardware limitations.
- Important distinctions such as static frame bound versus runtime high-water
  mark, and source coverage versus real-image behavior.

**Remove or generate:**

- Exact current check counts unless they are themselves an independent reviewed
  oracle.
- Exhaustive lists of negative fixtures.
- Detailed fake-tool implementation mechanics.
- Exact current execution results.
- Repetition of design rationale owned by DESIGN_DOCUMENTATION.
- Repetition of release sequencing owned by release policy.

**Work:**

- [x] Replace giant table cells with concise property statements.
- [x] Where exact counts are independent policy, keep them in executable test
  data and optionally generate a report.
- [x] Ensure target-specific limitations remain explicit.
- [x] Update tests that parse README rows as current data.

**Acceptance:**

- Test behavior can change internally without forcing unrelated prose edits.
- A reviewer can still map every major assurance claim to its substrate and
  aggregate.
- The README no longer acts as a mirror of the test implementation.

**Result:**

- The per-file tree index became a substrate/role map. A file index that already
  omitted a dozen tracked files is not a maintainable authority; the directories
  and the role of each group are.
- Per-lane fixture inventories, fake-tool mechanics and check counts were
  removed. Their authority is the executable test; where a count is reviewed
  policy it stays in test data (`test/pic/pic12f675_target_counts.sh`, the
  script-owned build profiles, `test/run_mutation_tests.sh`).
- The PIC12F675 per-variant `fault/lock-step/I-O` triples were removed from the
  prose, and the block of `test/test_pic_target_result_records.sh` that existed
  only to keep those sentences synchronized with the count table went with them.
  The producer/table/adapter oracles are untouched.
- Exact figures retained deliberately, because `test-release-qualification`
  requires this document to publish current release scope and independently
  verifies the same values against real evidence: the 35-file evidence set, the
  18 release soak combinations, the historical 28-file/15-soak boundary, and the
  48/102/168 build-profile final-check contracts. The published host compiler
  floor is retained for the same reason (`test-release-preflight`).
- Assurance coverage was completed rather than reduced: Classic AVR lanes,
  repository/structural contracts, and release/supply-chain gates now have
  explicit rows instead of living as annotations inside the file index.
- Known simulator and hardware gaps (yasimavr stepping, gpsim TMR2/WDT, PIC
  silicon-only risks) are kept, minus their revision history.
- Reference migration: `DESIGN_DOCUMENTATION.adoc`,
  `docs/pic10f320_validation.md`, and `docs/pic12f675_feasibility.md` no longer
  say that check counts, pinned mutation totals, or soak budgets live in
  `test/README.md`; each now names the executable or document that owns them.
- Verified: `test-makefile-name-contract`, `test-release-qualification`,
  `test-release-preflight`, `test-pic-target-result-records`.

## BR-TODO-01 - Reduce TODO.md to an actionable registry

**Status:** TODO

**Current size:** 669 lines

**Keep per item:**

- Stable ID.
- Problem or proof gap.
- Acceptance condition.
- Risk if deferred.
- Dependency or required external input.
- Status.

**Reduce:**

- Long implementation designs.
- Branch-era measurements.
- Completed implementation narratives waiting only for a number to be copied
  into documentation.
- Repeated explanation already in design/test/toolchain documents.

**Preserve carefully:**

- The concise `Considered and declined` registry, because it prevents repeated
  low-value proposals.
- Hardware qualification gaps.
- Explicit quality improvements that are not release blockers.

**Acceptance:**

- Every item is open and actionable.
- Completed work is removed.
- The priority summary and item set remain mechanically consistent if that test
  still provides value.
- TODO no longer carries the current release contract.

## BR-CHANGELOG-01 - Adopt a concise prospective changelog policy

**Status:** DONE `da1d62d`

**Current observations:**

- `CHANGELOG.md` is 3,897 lines.
- The current v0.9.10 section occupies roughly 1,045 lines.
- Recent entries often include detailed implementation mechanics, test fixture
  design, review chronology, and intermediate defects.

**Keep in future entries:**

- User-visible behavior changes.
- Safety or compatibility changes.
- New targets or release artifacts.
- Important fixed defects.
- Material residual limitations.
- Migration action required from users.

**Move out of future entries:**

- Full implementation journals.
- Exhaustive negative-test inventories.
- Every intermediate review finding.
- Exact current resource data beyond a link to the release record.
- Duplicated design explanations.

**Work:**

- [x] Add or adopt a concise entry policy without rewriting signed historical
  releases.
- [x] Leave existing history intact unless a separate, explicitly reviewed
  archival compaction is chosen.
- [x] Ensure `[Unreleased]` is the normal development state.

**Acceptance:**

- Future releases do not add thousand-line changelog sections.
- Changelog remains a human summary of what changed, not current evidence.

## BR-RELEASEDOC-01 - Reduce release/README.md to release policy and navigation

**Status:** TODO

**Current size:** 641 lines

**Keep:**

- Trust and signature model.
- Release source/artifact/tag relationship.
- Historical safety warnings and errata that must remain visible.
- Image-selection conventions.
- Reproduction model and tag-local verifier guidance.
- Release sequencing for maintainers.

**Move or generate:**

- Current exact programming commands to generated per-release guidance.
- Full general flashing procedure to `FLASHING.md`.
- Current release contract block to canonical release data.
- Exact evidence counts and current topology when they can be generated.
- Retired v0.9.8 rename machinery details after BR-TEST-01, while preserving
  historical user mapping where still useful.

**Acceptance:**

- Release policy remains auditable.
- Operator commands have one authority.
- Historical errata remain visible without being mistaken for current process.

## BR-COMMENT-01 - Trim migration archaeology from live Make/script comments

**Status:** TODO

**Rationale:** Live comments should explain invariants and non-obvious failure
modes. Long histories of retired names and earlier approaches are prone to stale
numbers and duplicate changelog/Git history.

**Example:** `Makefile:459-514` spends roughly 55 lines around a two-function
image naming convention, including extensive pre-v0.9.8 archaeology.

**Keep:**

- Why a non-obvious invariant exists.
- Hardware/toolchain limitations.
- Fail-closed rationale.
- Why an apparently redundant independent oracle is independent.
- Revisit conditions.

**Remove:**

- Retired naming histories already documented in release history.
- Old migration sequences.
- Mutable "today" resource counts.
- Repetition of durable design/release documents.
- Comments describing behavior obvious from a short rule.

**Acceptance:**

- Comment removal does not obscure safety or provenance rationale.
- No comment carries a stale current measurement.
- Make/scripts become easier to scan without changing behavior.

---

# G. Development and release-state model

## BR-STATE-01 - Remove four-way current-release declarations from live docs

**Status:** TODO

**Current copies:**

- `TODO.md:3-15`
- `docs/pic10f320_special_case.md:3-10`
- `docs/pic10f320_validation.md:16-27`
- `release/README.md:27-30`

Tests currently enforce these copies, so they are controlled duplication rather
than uncontrolled drift. They still impose maintenance and put global release
topology into target-specific and TODO documents.

**Work:**

- [ ] Define one human release-state authority.
- [ ] Keep literal release identity in the Makefile where it serves as an
  independent fail-closed production pin.
- [ ] Remove global topology declarations from TODO and target-specific docs.
- [ ] Generate human release topology where needed from canonical data.
- [ ] Replace occurrence/prose synchronization tests with semantic release
  identity checks.

**Acceptance:**

- Updating release topology does not require four prose edits.
- Release production still compares selected values with an independent literal
  reviewed identity.

## BR-STATE-02 - Treat main as development and releases as immutable snapshots

**Status:** TODO

**Rationale:** Unreleased source is inherently in development. Non-developers
should consume signed release images and the corresponding tagged snapshot and
evidence, not mutable candidate measurements or speculative release status.

**Work:**

- [ ] Keep ordinary `main` under `[Unreleased]`.
- [ ] Decide whether version/date declarations should be made only on a release
  candidate branch or selected source-finalization commit.
- [ ] Remove claims that an absent release directory already contains evidence.
- [ ] Keep the source-commit versus artifact-commit distinction explicit.
- [ ] Define abandonment/correction behavior for a selected release candidate.

**Acceptance:**

- Development source never implies final evidence exists before publication.
- Release consumers have one immutable snapshot and asset set to evaluate.
- Release tooling still binds evidence to the exact qualified source.

---

# H. Test, CI, and build cleanup

## BR-TEST-01 - Delete the retired v0.9.8 rename-identity lane

**Status:** DONE `893d647`

**Rationale:** `scripts/verify-rename-identity.sh:15-24` explicitly says the
one-shot gate should be deleted after the rename table no longer names the
current release. The current release contract is long past v0.9.8, but the lane
remains embedded in release creation, release CI, publication state, and large
synthetic fixtures.

**Remove prospectively:**

- `scripts/verify-rename-identity.sh`
- Runtime branches in `scripts/make-release.sh`
- Applicability/report/digest branches in `.github/workflows/release.yml`
- Dedicated source-shape and synthetic fixtures in release tests
- Current process text that implies every future release runs the rename proof

**Preserve:**

- `release/v0.9.8/RENAME_IDENTITY.md`
- Signed v0.9.8 checksums, tag, and release files
- Historical old-to-new user mapping if still useful
- Standing PIC10F320 expected-image hashes
- Canonical release-image reproduction checks

**Acceptance:**

- Current releases do not execute or carry state for an inapplicable v0.9.8
  migration gate.
- Historical v0.9.8 integrity remains independently verifiable.
- Release publication tests remain fail-closed for current assets.

## BR-TEST-02 - Remove duplicate mutation execution from normal CI

**Status:** DONE `b86a5a7`

**Pre-change behavior:**

- The PIC job runs authoritative fail-closed mutation testing at
  `.github/workflows/ci.yml:383-398` with every substrate provisioned.
- The stress job runs `make test-long` at `.github/workflows/ci.yml:671-718`.
- `test-long` includes `test-mutation` through `Makefile:3131-3162`.
- The stress copy permits unavailable PIC/ATtiny202 mutants to skip and is not a
  second complete witness.

**Work:**

- [x] Add or expose a long/exhaustive aggregate without mutation for hosted
  stress CI.
- [x] Keep ordinary `make test-long` unchanged for release qualification unless
  a separate release design explicitly replaces it.
- [x] Retain exactly one normal-CI fail-closed mutation run.
- [x] Update CI comments, job names, and routing tests.

**Acceptance:**

- Every required mutant still runs fail-closed once on applicable events.
- Stress CI retains exhaustive workloads without repeating mutation work.
- Release qualification still performs its required mutation gate.

## BR-TEST-03 - Route CI and ci-local through authoritative aggregates

**Status:** DONE `b9cbd36`

**Primary case:** ATtiny202 target validation

The Makefile already has an aggregate that runs functional, fault, and lock-step
lanes and validates the complete marker/count contract. Release CI uses it, while
normal CI and `scripts/ci-local.sh` restate component commands and assertions.

**Work:**

- [x] Make hosted CI invoke `make attiny202-test-target`.
- [x] Make local CI invoke the same aggregate.
- [x] Keep the short soak as a separately named operation if it is not part of
  the aggregate contract.
- [x] Retain one independent structural assertion that the required lanes remain
  members; do not duplicate the full orchestration.
- [x] Review PIC routes for the same pattern. Hosted CI, local CI, and release CI
  already share the same five-process boundary around the six PIC aggregates.

**Acceptance:**

- One Make aggregate owns operational lane orchestration.
- Hosted CI, local CI, and release CI cannot drift in command composition.
- Independent tests still detect a missing lane or incomplete matrix.

## BR-TEST-04 - Centralize resource-policy constants per independent surface

**Status:** DONE `bc5f11d`

**Current examples:**

- 16-byte AVR-XT static RAM limit.
- 32-byte stack-frame limit.
- 48-byte PIC12F675 Data-space limit.
- Repetition across Make, normal CI, release CI, local CI, and release script.
- Tests that count literal occurrences rather than validate value delivery.

**Principle:** One production value and one genuinely independent release/CI pin
may be valuable. Repeating the literal at every call site is not.

**Work:**

- [x] Identify which surfaces are meant to be independent opinions: production
  Make policy, hosted CI, local CI, local release creation, and public release
  attestation.
- [x] Define each policy once per independent surface.
- [x] Pass or import that value at consumers.
- [x] Replace occurrence-count tests with fake-consumer tests proving the value
  reaches every required gate.
- [x] Preserve deliberate mismatch detection between independently authored
  production, CI/release, and test policy.

**Acceptance:**

- A reviewed limit change has a small, explicit edit set.
- A consumer that drops the limit still fails a behavioral contract test.
- Independent pins remain independent.

## BR-TEST-05 - Replace source-spelling tests with behavioral fixtures

**Status:** DONE `7aab253`

**Candidates:**

- Exact command strings and line ordering in
  `test/test_release_qualification.sh`.
- Exact source spelling/order checks in `test/test_release_provenance.sh`.
- Workflow-text extraction where executing a stubbed workflow fragment can
  establish the same property.
- Documentation tests whose only purpose is synchronizing repeated prose.

**Keep source/prose checks when:**

- Exact operator wording is safety-relevant.
- A structural property cannot be observed through execution.
- A release security boundary depends on ordering before any side effect.
- The check is an independent literal pin rather than a formatting preference.

**Prefer behavioral assertions of:**

- Which tool ran.
- Exact argv received by a fake tool.
- Whether failure stopped staging/publication.
- Which bytes were hashed, copied, frozen, and published.
- Whether publication consumed the frozen inventory.
- Whether skipped/partial lanes withheld the terminal PASS record.

**Completed review:**

- [x] Make the existing workflow publication fixture assert the complete fake
  tag-verifier and `gh` argument vectors for stable and prerelease tags.
- [x] Move release checkout, verification, freeze, and publication topology to
  the YAML-aware workflow validator instead of repeating line-oriented workflow
  greps in release-history and qualification tests.
- [x] Replace the retired PIC12F675 evidence-path source scan with a staged
  verifier fixture that rejects the obsolete evidence file behaviorally.
- [x] Remove duplicate renderer-loading and staged-qualification source checks
  where existing preflight and renderer fixtures already prove the invariant.
- [x] Retain structural checks for final-candidate/staging order, root-owned
  freeze ordering, output-path TOCTOU guards, compiler pins, and signal cleanup.
- [x] Retain safety-language and evidence-substrate checks. Defer prose-only
  synchronization removal until the owning documentation task removes the
  duplicated prose, so existing copies do not become uncontrolled duplication.

**Acceptance:**

- Safe refactors do not require rewriting large exact-source fixtures.
- Security, ordering, and safety invariants remain at least as strong.
- Safety-language checks such as modeled-pin versus physical-hardware claims are
  retained.

## BR-TEST-06 - Move repeated Make profiles into named test profiles

**Status:** DONE `746ddcf`

**Current candidates:**

- PIC build profiles around `Makefile:3273-3330`.
- Target-matrix profiles around `Makefile:3598-3675`.
- Lane-marker profiles around `Makefile:3677-3705`.

**Work:**

- [x] Give parameterized scripts named profiles such as `pic10f320`,
  `pic10f322`, `pic12f675`, and `attiny202`.
- [x] Have Make pass profile names rather than large environment bundles.
- [x] Keep one independent test-owned literal canonical variant set beside each
  consumer rather than querying production Make declarations.
- [x] Reject unknown, empty, duplicate, and incomplete profile requests before
  creating fixture state, with load-bearing negative selftests.

**Acceptance:**

- Profile details are maintained beside the script that consumes them.
- Tests do not derive every expected value from production Make data.
- Make orchestration becomes shorter without hiding supported sets.

## BR-TEST-07 - Consolidate shared strict helpers and remove trivial wrappers

**Status:** DONE `cee6bab`

**Completed work:**

- [x] Remove five-line `test/test_fault_wdt_note_contract.sh`; invoke Python
  directly.
- [x] Extract one strict XC8 program-space transcript parser for all three build
  producers and the PIC10F320 size probe. Require one internally consistent
  record and reject missing, malformed, duplicate, mixed, zero, contradictory,
  over-capacity, and percentage-mismatched input.
- [x] Extract strict context-layout/symbol parsing used by all six PIC
  fault/lock-step consumers. Resolve one non-symlink sidecar pair once at recipe
  time, require exactly one `_ctx_: ds 3` allocation and one `_ctx_` record of
  XC8's real global symbol-table shape resolved into data memory, remove stale
  harness output first, and pass that captured address to C++.
- [x] Parameterize the twelve repeated optional libgpsim
  compiler/header/library preflights while retaining each caller's prerequisite,
  image, matrix, and lane-specific checks.
- [x] Reuse one strict hosted/local PIC toolchain assertion helper with both
  independently selectable XC8/DFP and C++/libgpsim surfaces explicit. Keep the
  release workflow's differently scoped assertion and the stronger release
  compile/link preflight separate.
- [x] Add dependency-free malformed/duplicate/ambiguous helper fixtures and
  behavioral routing coverage for every libgpsim consumer and both CI callers.

**Do not consolidate:**

- Part-specific image identity checks.
- Register, enum-layout, shadow-address, and matrix-integrity checks.
- Distinct program-space/data-space/return-stack measurements.
- Installer execution and restored-cache verification into one operation.

**Acceptance:**

- Shared helpers fail on missing, malformed, duplicate, stale, or ambiguous
  inputs.
- Part-specific checks remain explicit.
- Wrapper removal does not change target names or failure semantics unless
  intentionally reviewed.

## BR-TEST-08 - Generate variant recipe arms from existing maps

**Status:** DONE `d3ea121`

**Rationale:** The Makefile has canonical `macro_<variant>` and `src_<variant>`
maps at `Makefile:451-459`, but several PIC/AVR-XT recipes restate associations
manually. The current map guard proves values exist, not that manual recipe arms
consume the correct pair.

**Work:**

- [x] Generate modular recipe associations from existing maps where Make can do
  so clearly.
- [x] Replace PIC10F320's separate build and target-test mapping copies with one
  PIC10F320-specific map.
- [x] Add fake-compiler contract coverage for every producer.
- [x] Preserve explicit per-target supported sets where they may legitimately
  diverge.
- [x] Do not derive supported variants by globbing driver filenames.

**Acceptance:**

- Variant name, selector macro, and driver source cannot drift silently.
- Adding a driver file does not add a product.
- Independent release identity still detects an unintended matrix change.

## BR-TEST-09 - Consolidate common Make dependency declarations and parsers

**Status:** DONE `4fa470b`

**Work:**

- [x] Use one common modular-header dependency list plus each target's pin
  header.
- [x] Reuse the repository-owned XC8 program-space transcript checker completed
  by BR-TEST-07 while consolidating common Make dependencies.
- [x] Reuse the strict XC8 `_ctx_` allocation/symbol extraction helper completed
  by BR-TEST-07 rather than introducing another parser.
- [x] Verify independent soak blocking-time maps against firmware constants and
  test-owned values rather than maintaining unverified Make copies.

**Safeguards:**

- A new shared header must rebuild every relevant backend.
- Timing values must not be generated in a way that destroys independent
  mismatch detection.
- XC8 parser failures must remove incomplete outputs and fail closed.
- Keep each lane's cleanup, image matrix, data budget, hashes, and stack logic
  separate where hardware semantics differ.

**Acceptance:**

- Common mechanics have one strict implementation.
- Hardware-specific policy remains per target.
- Existing rebuild and stale-sidecar regressions remain effective.

## BR-QUALITY-01 - Use a declarative static-analysis matrix

**Status:** DONE `edd9696`

**Rationale:** This is a quality improvement enabled by consolidation, not a
line-reduction target by itself. Classic AVR analysis covers shell, pure core,
and selected drivers, while AVR-XT, PIC10F322, and PIC12F675 analysis generally
invokes cppcheck/MISRA only on the shell. Conditional relay-specific emergency
branches may not be covered under `--max-configs=1` without explicit selectors.

**Relevant Make areas:**

- Shared matrix/runners: `Makefile:852-933`
- PIC10F322 analysis: `Makefile:1369-1402,1550-1584`
- AVR-XT analysis: `Makefile:2811-2870`
- PIC10F320 analysis: `Makefile:4685-4720,4950-4980`
- PIC12F675 analysis: `Makefile:5543-5580,5709-5736`
- Classic/shared analysis: `Makefile:4187-4270`

**Work:**

- [x] Define reviewed tuples of target, translation unit, and materially
  distinct output selector.
- [x] Analyze relay versus non-relay shell branches explicitly where behavior
  differs.
- [x] Analyze shared output drivers under each materially different target
  platform/header model.
- [x] Preserve separate `avr8`, `pic8`, and `pic8-enhanced` platform runs.
- [x] Reconcile or document shipping PIC C99 mode versus analyzer C11 mode.
- [x] Keep MISRA output gating and suppression review fail-closed.

**Acceptance:**

- Every shipping authored translation unit is analyzed under every materially
  distinct supported target configuration.
- Consolidation reduces repeated recipes while increasing demonstrable branch
  coverage.
- Suppressions are not broadened to make the matrix pass.

---

# I. Release metadata and evidence model

## BR-REL-01 - Define one canonical signed release index

**Status:** TODO

**Risk:** High. This changes provenance representation and must be independently
reviewed before old mechanisms are retired.

**Current duplication:**

- `QUALIFICATION`
- `MANIFEST.md`
- `SHA256SUMS`
- `SHA256SUMS.asc`
- per-release `README.md`
- evidence log terminal summaries
- workflow publication inventory
- release page body

**Candidate canonical fields:**

- Format version.
- Release version and source commit.
- Artifact commit/tag identity.
- Qualification policy/mode and duration.
- Toolchain names, versions, and distributable/package digests where retained.
- Canonical asset name, role, media type, size, and SHA-256.
- Firmware MCU, output stage, clock, fuse/CONFIG identity, and resource results.
- Evidence archive digest and internal index digest.
- Aggregate terminal results.
- Hardware-qualification status distinct from software qualification.
- Publication provenance identifiers where durable and meaningful.

**Work:**

- [ ] Decide whether to evolve `QUALIFICATION` or introduce a clearly versioned
  `release-index.json` rather than create parallel authorities.
- [ ] Define canonical serialization and parser behavior.
- [ ] Sign the canonical root or bind its digest in the signed tag.
- [ ] Generate human manifest, release notes, programming guide, and checksums
  from canonical data where practical.
- [ ] Ensure every published payload is transitively authenticated.
- [ ] Keep `SHA256SUMS` as a standard user verification view if useful, but do
  not maintain a conflicting independent hash table.
- [ ] Reject unknown fields/versions according to an explicit compatibility
  policy; do not add speculative backward compatibility.

**Acceptance:**

- Every per-release fact has one machine authority.
- Human views cannot drift because they are generated and checked.
- Offline integrity verification remains possible.
- Qualification, reproducibility, integrity, and hardware validation remain
  distinct claims.

## BR-REL-02 - Package future release evidence as one deterministic archive

**Status:** TODO

**Depends on:** BR-REL-01

**Observation:** Recent releases add roughly 35-60 tracked files and around 400
KiB of mostly unique evidence. The v0.9.9 evidence is roughly 481 KiB unpacked
but about 63 KiB as a compressed archive. Images are tiny and heavily
deduplicated; loose evidence is the primary growth source.

**Work:**

- [ ] Define deterministic archive ordering, ownership, permissions, and archive
  timestamps.
- [ ] Include an internal index with each member's role, size, digest, and
  terminal result.
- [ ] Retain raw logs where forensic detail is useful.
- [ ] Replace duplicate initial/final output-only logs with structured phase
  records when they establish the same thing more strongly.
- [ ] Decide compression format based on long-term tool availability and
  deterministic support.
- [ ] Bind the archive digest from the canonical signed release index.
- [ ] Publish the archive as a release asset and, until the retention policy is
  proven, consider retaining it in the tag/artifact commit as well.

**Acceptance:**

- Evidence remains complete, indexed, authenticated, and offline-inspectable.
- Publication handles one archive rather than dozens of loose logs.
- Compression does not become the only undocumented way to recover evidence.

## BR-REL-03 - Clarify full test-long log retention

**Status:** DONE `463aa2f`

**Observation:** Release creation retains a summary and says the full log is
archived by release CI, but the workflow does not appear to upload that log as a
durable release asset. Ordinary hosted run-log retention is not equivalent to
immutable release evidence.

**Decision:** The full `test-long` transcript is transient diagnostic output,
not required release evidence. Retain and verify one exact source-bound terminal
record in `test-long.summary.txt`; tag CI independently reruns the gate, but its
hosted log is not a release asset or a dependency of the qualification claim.

**Work:**

- [x] Decide whether the full log is required evidence.
- [x] Resolve the compressed-archive branch as not applicable because the full
  log is not required evidence.
- [x] If not required, correct claims that it is durably archived.
- [x] Ensure the summary has enough structured terminal data to establish the
  intended release claim.

**Acceptance:**

- Documentation matches the actual retention guarantee.
- No qualification claim depends on an expiring hosted CI log.

## BR-REL-04 - Define prospective hosted-asset retention and mirroring policy

**Status:** TODO

**Depends on:** BR-REL-01, BR-REL-02

**Caveat:** The initial review was performed offline and could not inspect hosted
release assets or repository tag-protection settings. Verify actual hosted state
before migration.

**Work:**

- [ ] Inventory which historical evidence currently exists only in Git.
- [ ] Verify exactly what each hosted release publishes.
- [ ] Define asset replacement/deletion protections and operational ownership.
- [ ] Retain signed hashes in Git even if payloads move to hosted assets.
- [ ] Define at least one durable independent mirror or offline archive for
  evidence removed from development `main`.
- [ ] Define recovery if the hosting service or release asset disappears.

**Acceptance:**

- No evidence is removed from Git before exact authenticated archival backfill.
- Hosted URLs are never treated as immutable provenance by themselves.

## BR-REL-05 - Keep future releases self-contained

**Status:** TODO

**Rationale:** Repeated firmware images are inexpensive and self-contained
releases are safer than deltas or links to prior assets.

**Work:**

- [ ] Continue publishing every canonical image in every release, even when
  bytes are unchanged.
- [ ] Continue publishing all required programming helpers and verification
  metadata.
- [ ] Do not replace images with deltas or references to an older release.
- [ ] Use the signed index to identify deliberate byte identity when relevant.

**Acceptance:**

- A release remains usable and verifiable without another release.

## BR-REL-06 - Consider artifact-only tagged commits outside future main history

**Status:** TODO

**Depends on:** BR-REL-01, BR-REL-02, BR-REL-04

**Proposed end state:**

- Development `main` contains source and release machinery.
- A selected source commit is qualified.
- An artifact-only child commit contains a compact signed index and possibly the
  evidence archive.
- A protected signed tag points to that artifact child.
- Development continues from the source line rather than carrying every future
  artifact directory in the tip of `main`.
- Self-contained images/evidence are published as authenticated release assets.

**Questions to decide:**

- Whether artifact-only commits remain reachable and fetchable under hosting
  defaults when not merged into `main`.
- Whether source archives generated for the tag include every required verifier.
- Whether the evidence archive should remain in the tagged commit as well as the
  hosted assets.
- How release-history verification adapts while preserving the source-parent
  relationship.
- How local cleanup and garbage-collection guidance changes.

**Acceptance:**

- Source-to-artifact provenance remains at least as strong as today.
- Signed tags remain sufficient to locate authenticated release metadata.
- Ordinary development checkouts stop accumulating future loose release trees.
- Historical tags and commits remain untouched.

## BR-REL-07 - Preserve historical releases during prospective migration

**Status:** TODO

**Work:**

- [ ] Do not edit existing `release/v*/` contents.
- [ ] Do not rewrite early historical exceptions to match the modern policy.
- [ ] Keep current safety errata outside immutable historical files.
- [ ] Use each historical tag's own scripts and naming contract for
  reproduction.
- [ ] If old payloads are eventually removed from the tip of `main`, do so only
  in an ordinary new commit after archive verification; do not rewrite history.
- [ ] Verify old tagged objects remain reachable after any tip cleanup.

**Acceptance:**

- Every published historical release remains verifiable exactly as released.
- Prospective simplification does not retroactively change historical claims.

---

# J. Firmware and hardware-specific boundaries

## BR-SRC-01 - Preserve deliberate firmware duplication

**Status:** TODO

This is a review gate, not an instruction to edit source.

**Do not consolidate merely for line reduction:**

- PIC10F322 and PIC12F675 polled main loops.
- AVR Classic and AVR-XT ISR/main transactions.
- PIC10F320's self-contained algorithm and output stages.
- The duplicate PIC10F320 watchdog formula that is independently checked.
- Per-target pin headers and device-pack assertions.
- Clock constants duplicated between build flags and firmware guards.
- Independent simulator output masks.
- XC8 assembly return-stack analysis and final-HEX return-stack analysis.
- Formal BFS, symbolic/KLEE, CBMC, mutation, source coverage, target simulation,
  and hardware qualification layers.

**Rationale:** These implementations and oracles differ by execution model,
compiler, core generation, timing, stack behavior, or trust boundary. A shared
helper could create common-mode failure or alter generated code, timing,
resource use, MISRA attribution, coverage allowlists, and fault behavior.

**Acceptance:**

- Every proposed source consolidation explicitly states why it does not destroy
  an independent opinion.

## BR-SRC-02 - Low-risk firmware-source cleanup candidates

**Status:** NEEDS USER

**Candidates:**

- Make `src/bypass_output_common.h` include its own `<stdint.h>` dependency.
- Remove empty `src/bypass_output_cd4053_simple.h`, or give it a real driver
  contract such as selector validation.
- Add one-hot backend/output selector guards.
- Require each modular output driver translation unit's expected selector.
- Correct stale MCU-neutral comments in `src/bypass_config.h`.
- Replace deleted-document references after PIC consolidation.

**Prerequisites:**

- Build/test recipes must pass explicit selectors consistently.
- Static-analysis recipes must cover each expected selector.
- Negative compile tests must be ready to prove new guards are load-bearing.
- Pinned toolchains must be available for image/resource/timing comparison.

**Acceptance:**

- User performs source edits.
- All supported MCU/output tuples build.
- Expected preprocessor-only changes produce byte-identical images where
  intended.
- Any generated-byte change is intentional, reviewed, and fully requalified.

## BR-SRC-03 - Expand negative compile-guard coverage before source cleanup

**Status:** TODO

**Observation:** Existing static-assert negative testing is strongest for
Classic AVR/shared sources and does not equivalently exercise every target-local
guard.

**Work:**

- [ ] Census guards in every MCU shell.
- [ ] Add narrowly mutated negative compiles under each full target toolchain.
- [ ] Cover wrong MCU, conflicting backend selectors, wrong output selector,
  wrong pin, wrong clock, enum/layout assumptions, and timing-budget violations.
- [ ] Require the intended diagnostic, not merely any compilation failure.
- [ ] Keep target-local guards target-local.

**Acceptance:**

- Deleting or bypassing any required guard is detected even when firmware bytes
  would otherwise remain valid.

## BR-SRC-04 - Proof obligations for any user-made firmware refactor

**Status:** TODO

Any firmware refactor proposed during this effort must explicitly discharge:

- [ ] Complete MCU/output-stage configuration matrix.
- [ ] Exact selector/driver correspondence.
- [ ] Byte identity where no code-generation change is intended.
- [ ] Flash, static data, AVR stack frames, runtime stack high-water where
  available, and PIC return-stack limits.
- [ ] Tick formulas, delay-body cycles, delivered pulse widths, ISR duty, and
  watchdog pet-to-pet bounds.
- [ ] Relay emergency de-energization and complete recovery actuation.
- [ ] Fault injection across target-specific guarded state.
- [ ] Lock-step/equivalence against `bypass_pure.c`.
- [ ] Negative compile guards and diagnostics.
- [ ] MISRA/static analysis under all materially distinct configurations.
- [ ] Preservation of independent pin/output/release identity oracles.

**Acceptance:**

- No firmware refactor is approved based on reduced line count alone.

---

# K. Final integration and verification

## BR-FINAL-01 - Run a complete current-reference audit

**Status:** TODO

**Depends on:** All document deletion/consolidation tasks

**Work:**

- [ ] Search all current tracked text for deleted document paths.
- [ ] Search for stale section-number and line-number references.
- [ ] Search for retired target/variable/image names outside intentional
  historical contexts.
- [ ] Search for current resource measurements outside release evidence.
- [ ] Search for duplicated current-release declarations.
- [ ] Search for multiple current programming procedures.
- [ ] Check all Markdown/AsciiDoc links and named anchors.
- [ ] Exclude immutable historical release directories from current-policy
  rewrites while still checking their links under tag-local rules where
  appropriate.

**Acceptance:**

- No dangling current references remain.
- Historical prose is clearly historical and not used as current authority.

## BR-FINAL-02 - Verify safety and claim boundaries

**Status:** TODO

**Work:**

- [ ] Confirm no part is described as hardware-qualified without a controlled
  record.
- [ ] Confirm field-use reports remain distinct from controlled qualification.
- [ ] Confirm simulator modeled-pin checks are not described as physical output
  evidence.
- [ ] Confirm PIC12F675 remains not-a-raw-write target.
- [ ] Confirm helper status remains published, software-tested, and not
  hardware-qualified.
- [ ] Confirm PIC10F320's inlining seam and omitted general latch check remain
  explicit.
- [ ] Confirm release integrity, reproducibility, qualification, and hardware
  validation are described as separate claims.

**Acceptance:**

- Simplification does not strengthen any claim beyond retained evidence.

## BR-FINAL-03 - Verify independent oracles were not centralized away

**Status:** TODO

**Work:**

- [ ] Review every removed duplicate and classify it as redundant authority or
  independent oracle.
- [ ] Confirm release identity still has an independent literal pin.
- [ ] Confirm expected pin/output facts are not generated from firmware maps.
- [ ] Confirm supported sets can legitimately diverge by target.
- [ ] Confirm both PIC stack witnesses remain where applicable.
- [ ] Confirm formal and simulation substrates remain distinct.
- [ ] Confirm build constants and firmware guards can still disagree and fail.

**Acceptance:**

- No common-mode failure was introduced under the label of deduplication.

## BR-FINAL-04 - Focused verification after each chunk

**Status:** TODO

Use focused gates after each task rather than deferring every failure to the end.
The exact target list may change as cleanup lands; preserve the underlying
coverage.

**Suggested categories:**

- [ ] Documentation/name/link contracts after document moves.
- [ ] Resource measurement and release qualification contracts after BR-RES.
- [ ] Flashing helper and release preflight contracts after BR-FLASH.
- [ ] Release image/provenance/history/publication contracts after BR-REL.
- [ ] CI routing/workflow syntax tests after BR-TEST-02/03.
- [ ] Variant map, target matrix, lane marker, rebuild, and strict-tool tests
  after Make/profile/helper consolidation.
- [ ] Static analysis/MISRA output contracts after BR-QUALITY-01.
- [ ] Pinned-toolchain image/resource/timing gates after any user source edit.

**Acceptance:**

- Each commit-sized chunk is independently green before the next broad change.

## BR-FINAL-05 - Run complete project qualification

**Status:** TODO

**Depends on:** All implementation tasks intended for the release

**Work:**

- [ ] Run the ordinary host/default suite.
- [ ] Run the long/exhaustive suite under the intended strict mutation policy.
- [ ] Run AVR-XT pre-hardware and target aggregates with required tool inputs.
- [ ] Run PIC10F322 pre-hardware and target aggregates.
- [ ] Run PIC10F320 pre-hardware, expected-image, stack, and target aggregates.
- [ ] Run PIC12F675 combined retained-matrix aggregates.
- [ ] Run release preflight, image, provenance, qualification, history,
  signature, and publication tests.
- [ ] Run soak qualification according to the eventual release policy.
- [ ] Generate and inspect the candidate release resource report without
  committing it as current development documentation.

**Acceptance:**

- The complete quality bar remains satisfied.
- Any intentionally retired test has a recorded reason and preserved invariant
  or an explicit decision that the invariant was redundant.

## BR-FINAL-06 - Measure the result

**Status:** TODO

**Work:**

- [ ] Record before/after tracked file count.
- [ ] Record before/after lines by docs, tests, scripts, Makefile, and release
  machinery.
- [ ] Record before/after normal CI commands and estimated duplicated runtime.
- [ ] Record the number of mutable current-fact copies removed.
- [ ] Record retained independent oracles and any assurance coverage added.
- [ ] Do not use line reduction as the sole success criterion.

**Success criteria:**

- Fewer maintained authorities.
- Fewer release-version edits.
- Fewer mutable measurement copies.
- Fewer duplicated orchestration paths.
- Less active historical search noise.
- Equal or better safety, test coverage, release integrity, and reproducibility.

## BR-FINAL-07 - Delete this branch-only work plan

**Status:** TODO

**Depends on:** Completion or explicit disposition of every task above

**Work:**

- [ ] Move any unfinished actionable item into concise durable TODO form.
- [ ] Ensure every completed item is represented by current code/docs/tests,
  release notes as appropriate, and Git history.
- [ ] Delete `post-v0.9.10-bloat-reduction.md` before release source
  finalization.
- [ ] Run the release documentation allowlist/preflight after deletion.

**Acceptance:**

- The active branch does not retain its completed work journal.
- Git history retains the plan for archaeology.
- Release preflight accepts the durable documentation set.

---

# Summary board

Update this board as tasks change state. Task sections remain authoritative for
dependencies and acceptance criteria.

| Task | Summary | Status |
|---|---|---|
| BR-BASE-01 | Reconcile final release baseline | DONE `756e622` |
| BR-AUTH-01 | Finalize authority map | DONE `620234f` |
| BR-AUTH-02 | Inventory references/contracts | DONE `bc267a8` |
| BR-RES-01 | Remove mutable resource tables | DONE `e7c4f68` |
| BR-RES-02 | Retire prose synchronization tests | DONE `e7c4f68` |
| BR-RES-03 | Publish generated release resource view | TODO |
| BR-PIC-01 | Create coherent PIC design section | DONE `b1b98c3` |
| BR-PIC-02 | Merge PIC10F322 phase notes | DONE (commit pending) |
| BR-PIC-03 | Consolidate PIC10F320 documents | TODO |
| BR-PIC-04 | Consolidate PIC12F675 feasibility | TODO |
| BR-PIC-05 | Update firmware document references | NEEDS USER |
| BR-FLASH-01 | Make FLASHING.md authoritative | TODO |
| BR-FLASH-02 | Generate release programming guide | TODO |
| BR-FLASH-03 | Delete flashing proposal journal | TODO |
| BR-DOC-01 | Delete completed v0.9.6 journal | DONE `9b6dfc3` |
| BR-DOC-02 | Reduce Makefile split decision | DONE `5ce3f59` |
| BR-DOC-03 | Reduce non-blocking feasibility analysis | DONE `9c16f96` |
| BR-DOC-04 | Classify feature safety records | TODO |
| BR-README-01 | Reduce root README | TODO |
| BR-TESTDOC-01 | Reduce test README | DONE `a64c25e` |
| BR-TODO-01 | Reduce TODO to registry | TODO |
| BR-CHANGELOG-01 | Adopt concise changelog policy | DONE `da1d62d` |
| BR-RELEASEDOC-01 | Reduce release README | TODO |
| BR-COMMENT-01 | Trim live historical comments | TODO |
| BR-STATE-01 | Remove repeated release declarations | TODO |
| BR-STATE-02 | Make development/release state explicit | TODO |
| BR-TEST-01 | Delete retired rename lane | DONE `893d647` |
| BR-TEST-02 | Remove duplicate CI mutation run | DONE `b86a5a7` |
| BR-TEST-03 | Route CI through aggregates | DONE `b9cbd36` |
| BR-TEST-04 | Centralize policy constants per surface | DONE `bc5f11d` |
| BR-TEST-05 | Prefer behavioral fixtures | DONE `7aab253` |
| BR-TEST-06 | Introduce named test profiles | DONE `746ddcf` |
| BR-TEST-07 | Consolidate strict helpers/wrappers | DONE `cee6bab` |
| BR-TEST-08 | Generate recipes from variant maps | DONE `d3ea121` |
| BR-TEST-09 | Consolidate dependencies/parsers | DONE `4fa470b` |
| BR-QUALITY-01 | Define complete analysis matrix | DONE `edd9696` |
| BR-REL-01 | Define canonical signed release index | TODO |
| BR-REL-02 | Package deterministic evidence archive | TODO |
| BR-REL-03 | Clarify full test-long retention | DONE `463aa2f` |
| BR-REL-04 | Define hosted retention/mirroring | TODO |
| BR-REL-05 | Keep releases self-contained | TODO |
| BR-REL-06 | Consider tag-only artifact commits | TODO |
| BR-REL-07 | Preserve historical releases | TODO |
| BR-SRC-01 | Preserve deliberate source duplication | TODO |
| BR-SRC-02 | Perform optional source cleanup | NEEDS USER |
| BR-SRC-03 | Expand negative guard tests | TODO |
| BR-SRC-04 | Enforce source-refactor proof obligations | TODO |
| BR-FINAL-01 | Audit current references | TODO |
| BR-FINAL-02 | Verify safety/claim boundaries | TODO |
| BR-FINAL-03 | Verify independent oracles remain | TODO |
| BR-FINAL-04 | Run focused gates incrementally | TODO |
| BR-FINAL-05 | Run complete qualification | TODO |
| BR-FINAL-06 | Measure outcome | TODO |
| BR-FINAL-07 | Delete this working document | TODO |
