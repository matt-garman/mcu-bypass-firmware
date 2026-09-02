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

**Status:** DONE `620234f` + `0705898`

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

Follow-up `0705898` made the branch-only lifecycle executable rather than tied
to an accumulating filename allowlist: a root-level working document is
recognized by the declaration in its opening blockquote, while the release gate
still rejects every root-level document outside the durable set. This plan is
the first live consumer of that rule.

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

**Status:** DONE `1ad315e`

**Depends on:** BR-RES-01, BR-REL-01

**What the measurement found.** The item assumed the release had no resource
view to generate. It had two, and neither was the one that was checked.

`test/test_resource_tables.py --require-all-images` already measured everything
this item asks for -- 21 image sizes, 12 AVR static-data figures, 9 Classic AVR
stack high-waters, the AVR-XT frame bound, PIC12F675 Data space, 9 PIC
return-stack witnesses -- validated each against the reviewed ceiling that
bounds it, and then **discarded every value**, retaining six counts:

```
RESOURCE_TABLES_RESULT format=1 status=pass source_commit=...
  images=21 avr_static=12 classic_stack=9 pic_data=6 pic_stack=9
```

Meanwhile `img_row` in `scripts/make-release.sh` derived its own `flash used`
column, arm by arm, from build logs and `avr-size`. Two producers of one fact,
never compared -- and the one that was published was not the one that was
checked. The published column in `v0.9.11`, ordered by how close each image sits
to its ceiling:

| image | used / ceiling | % of ceiling | published as |
|---|---|---|---|
| `bypass-pic10f322-cd4053_with_mute.hex` | 502 / 512 w | 98.0% | `n/a` |
| `bypass-pic10f322-tq2_l2_5v_relay.hex` | 493 / 512 w | 96.3% | `n/a` |
| `bypass-attiny13a-cd4053_with_mute.hex` | 878 / 921 B | 95.3% | `878 B` |
| `bypass-pic10f320-tq2_l2_5v_relay.hex` | 242 / 256 w | 94.5% | `242 / 256 words` |
| `bypass-pic10f322-cd4053_simple.hex` | 476 / 512 w | 93.0% | `n/a` |

**Every image that is actually near its limit was one whose limit the release
did not publish.** The PIC10F322 arm derived nothing and printed `n/a` (its
comment, "XC8 reports words, not bytes", was stale -- two other PIC arms print
words). The ATtiny13a ceiling is `ATTINY13A_FLASH_BUDGET`-derived at 921 B, not
the 1024 B of silicon, so `878 B` alone read as a comfortable 86% of the device
rather than 95% of the reviewed budget, 43 B from the gate that stops the build.

Three formats and one blank across seven parts. Static RAM was measured on all
twelve AVR ELFs and published nowhere. The nine Classic AVR stack observations
were worse than unpublished: they are read from `test-long.log`, which staging
does not retain, so they existed only inside a run.

**Work:**

- [x] Define the exact release resource fields and units. One `RESOURCE_*`
  record per published figure, each carrying its own `unit=` -- `bytes`,
  `words` or `levels` -- because reporting a PIC figure in an AVR's unit is the
  mistake the part table exists to prevent.
- [x] Include each canonical image exactly once. Coverage is checked in both
  directions against the Makefile's `RELEASE_IMAGES`, by the producer and again
  by the verifier; `21` is not the authority for either.
- [x] Include hard ceiling, measured usage, free margin, tool identity, and
  measurement method where appropriate. Every record carries `ceiling=`,
  `capacity=`, `free=` and `method=`; the ceiling and the margin now travel with
  the figure on the release page.
- [x] Include static data, stack, and PIC return-stack results only when the
  release evidence actually measures that quantity.
- [x] Do not imply that per-frame GCC stack data is a whole-path high-water
  measurement. The AVR-XT record is `RESOURCE_STACK_BOUND` with
  `method=gcc-stack-usage-per-frame`, states only the ceiling every frame was
  checked against, and is **rejected by the verifier if it carries `used=` or
  `peak=` at all**. The log states "all frames <= 32 B", which is the limit and
  not a measured maximum, so no maximum is published.
- [x] Generate the human table from canonical release data. `img_row` no longer
  derives flash usage; five per-arm derivations were deleted.
- [x] Make the release publication page expose the generated table.
  `MANIFEST.md` gains a `## Resources` section with five tables.

**Acceptance:**

- Released users can inspect exact resource use without checking out source --
  including the RAM and stack figures no release has ever carried.
- The release table is source-commit- and toolchain-bound: the records are
  written with the run's `source_commit`, and `evidence/resource-tables.log` is
  hashed into `QUALIFICATION`, listed in `SHA256SUMS` and recorded in
  `evidence/INDEX`.
- There is one machine authority for every displayed value.

**Three agreements this added, none of which existed before.** Publishing one
figure where two were measured requires proving the two agree, so each
aggregation is now a check:

- The two AVR static-data oracles -- allocated ELF sections, and the SRAM map
  the simulated canary gate derives from the device's own symbols -- must
  report the same statics. Nothing had ever compared them; the release could
  have published either.
- A part's three variants must agree before one static figure stands for the
  part.
- The PIC12F675 qualified build and its reproducibility rebuild must agree on
  Data space. Each was checked against the limit separately, so two builds that
  disagreed with each other both passed.

**What this does not do.**

- It does not attribute a Classic AVR stack observation to a variant. The canary
  line names only the part, so the deepest of the three observations is
  published for the part rather than an attribution the evidence does not carry.
  Adding the variant to that line is a change to `test/avr/test_sim.c` and was
  left alone.
- It does not measure PIC10F322 or PIC10F320 data space. Neither is measured by
  any gate today, so neither is published; only the PIC12F675 Data-space budget
  exists as evidence.
- It does not retain `test-long.log`. The nine Classic stack figures now survive
  as records in the resource evidence, which is the narrow fix; whether the full
  transcript should be retained is BR-REL-03's settled question, not this one's.

---
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

**Status:** DONE `3a3b661`

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

**Status:** DONE `b8b4af1`

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

- [x] Extract the normative constrained-target design into one dedicated design
  section.
- [x] Preserve one concise historical measurement statement tied to its
  toolchain/commit if needed to support the "does not fit" decision.
- [x] Ensure exact current resource numbers are handled by BR-RES-01.
- [x] Move remaining open hardware concerns to `TODO.md` or
  `HARDWARE_VALIDATION_LOG.md` as appropriate.
- [x] Update README target-selection guidance.
- [x] Update test documentation to refer to the new design anchor.
- [x] Delete `docs/pic10f320_merge_plan.md`.
- [x] Delete `docs/pic10f320_special_case.md` after references move.
- [x] Delete `docs/pic10f320_validation.md` after unique durable facts are
  accounted for.
- [x] Delete `docs/pic10f320_feasibility.md` if its concise decision evidence is
  fully retained; otherwise reduce it to a short immutable decision record with
  no current status or measurements.

**Result:**

All four documents deleted -- 4,571 lines. `pic10f320-architecture`, created by
BR-PIC-01, is now the whole normative account rather than a summary with
pointers.

What it gained:

- The "does not fit" finding as a self-contained, dated, toolchain-bound
  statement: the three variants measured 356/386/381 words against 256 on
  2026-06-26 under the pinned free-tier XC8 and device pack, with hard link
  failures rather than near misses, and the three source-level reductions that
  were priced rather than estimated -- packed enums (nothing, the optimizer
  already emitted identical code), force-inlining (nothing, the free tier
  ignores `always_inline`), a pointed-to result (twelve words), and bit-packing
  (47 words, still 53 over). The two best did not compose, which is the
  signature of a floor.
- The manual shared surface, as a seven-row table. The equivalence lane enforces
  most of it, but not the output-stage rows and not the defensive layer, and
  saying which rows the gate does not reach is the point of keeping the table.
- The hardware return stack, which had no design-level statement anywhere. Three
  facts make it a design concern: it is a return stack, not the AVR's data
  stack, so `test-stack-bound` has nothing to measure here; "inlined, so it cannot
  recurse" is wrong because the output stages are still called from `init()`;
  and the compiler cannot be the witness -- XC8 once reported 3 on a real relay
  image whose emitted stream held a verified 4-deep `fcall` chain, its overflow
  check is only a warning that still exits 0 and writes a HEX, and the core has
  no `STKPTR`, `TOSL`/`TOSH`, `STKOVF` or `STVREN` to catch it at runtime. Hence
  two independent witnesses whose disagreement is itself the finding, and a HEX
  witness that fails closed at its own modelling boundary.
- What the assurance package does not establish: the seam stays a seam, the
  expected-image gate is not universal compiler reproducibility, the general
  latch check is absent, and hardware-bench properties are simulated.
- The provenance note -- non-squashed subtree import, six predecessor signed
  tags under a `pic10f320/` namespace, and the fact that `git log --follow`
  needs `-m` to cross the import merge. Without that sentence the preserved
  history is effectively unreachable.

The bit-packing refusal went to Failsafe Mechanisms instead, because it is not a
PIC10F320 fact: the range check works only because the representation is wider
than the domain, so packing the members to their legal widths makes the check
dead code, puts all three in one byte where a flip is undetectable, and drops
the counter bound from 255 to 63. That is a property of the core at every
target. The free-tier optimizer cap went to `TOOLCHAIN.adoc` as its own section,
since it is a toolchain fact two documents depended on: `-Os` downgrades with
advisory 2051, and the passes that would help are PIC-specific back-end work
with no open substitute -- no 8-bit PIC target in upstream LLVM, whole-program
compiled-stack overlay with no hand-off point, and SDCC's `pic14` port a
separate ABI world.

Gate surfaces that had to move with the deletion, since two of the four
documents were load-bearing:

- `scripts/release-documentation.sh`: `current_documents` drops the two deleted
  paths, leaving `release/README.md` and `TODO.md`. Whether that set should be
  redesigned is BR-STATE-01/02's question, not this one's.
- `test/test_release_preflight.sh`: its fixture writer must write the same set.
- `scripts/make-release.sh`: the generated per-release "Full detail" link now
  targets `DESIGN_DOCUMENTATION.adoc#pic10f320-architecture`, still absolute and
  tag-pinned for the same reason as before.
- `test/test_release_qualification.sh`: the three pinned link properties updated
  to match, the negative case widened to reject a repo-relative form of either
  path, and one check added -- the design document must actually define the
  anchor the generated link points at, which the old assertion had no analogue
  for.
- `test/test_makefile_name_contract.py`: its axis-B negative case opened
  `docs/pic10f320_validation.md` to prove a current document is not exempt from
  the historical-banner rule. Repointed at `test/README.md`, which is current,
  reader-facing and full of Make target names -- a better subject for that axis
  than the document it replaced.

Prose references retargeted in `README.md` (2), `TOOLCHAIN.adoc` (2),
`test/README.md` (3), `MISRA_COMPLIANCE.md`, `HARDWARE_VALIDATION_LOG.md`,
`.github/workflows/ci.yml`, `Makefile` (2), `.gitignore`,
`docs/pic12f675_feasibility.md` (2) and `docs/relay_coil_fault_correction.md`.
The adopter boundary the validation record carried -- this project does not
specify the coil driver, supply, flyback network or PCB, so relay motion and the
simultaneous-driver transient are the adopter's to validate -- moved into
`docs/relay_coil_fault_correction.md`, which is the live relay policy document.

Two firmware comments still name a deleted path,
`src/bypass_mcu_pic10f320.c:178` and `src/bypass_compile_checks.h:17`. Both are
user-owned and belong to BR-PIC-05; the replacement target is
`DESIGN_DOCUMENTATION.adoc#pic10f320-architecture`.

**Acceptance:**

- PIC10F320's weaker architectural property is still stated prominently and
  honestly.
- No exact current results are maintained outside release evidence.
- No merge-process narrative is needed to understand or validate the target.
- All standing assurance gates remain.

## BR-PIC-04 - Consolidate PIC12F675 feasibility into current authorities

**Status:** DONE `f968de7`

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

- [x] Extract all still-current target design into named design anchors.
- [x] Reconcile open risks with existing TODO and hardware-log entries.
- [x] Ensure no hardware-qualification claim is strengthened during the move.
- [x] Delete `docs/pic12f675_feasibility.md` after all references are resolved.

**Acceptance:**

- PIC12F675 remains clearly release-supported in software and not hardware
  qualified.
- The OSCCAL/BG failure mode remains prominent in operator guidance.
- The design document explains the implementation without prospective tense.
- Current test results and resource figures are release-bound rather than copied
  into design prose.

**Result:**

Deleted, 1,662 lines. Section C is finished: no `docs/pic10f32*` or
`docs/pic12f675*` document remains, and every PIC part's normative account is a
named anchor in `DESIGN_DOCUMENTATION.adoc`.

Most of the design content was already moved by BR-PIC-01, which built
`pic12f675-architecture` and `pic-core-generations` out of this document. What
had not moved was the *evidence under* those statements, and that is what this
task placed:

- **A `Datasheet References` block for the part, which had none.** Six rows
  against DS41190G: the watchdog period, the brown-out trip, the oscillator
  tolerance, the factory calibration word, the GP2 readback thresholds, and
  what each is worth. The watchdog row is the one that mattered most, because
  "de-rated floor 160" sat in the pet-to-pet budget table with its derivation
  in a document nobody would think to open. Two DS41190G figures are in play
  and they are different *kinds* of number rather than a discrepancy: 18 ms is
  the prose nominal that the 288 ms row and gpsim both use, 17 ms is the
  characterized typical, and the argument rests on neither -- it rests on the
  10 ms minimum, times 16, which is the 160 ms floor the pin map compiles
  against. The row says so, and says not to "correct" the shell's comments to
  the typical.
- **The GP2 numbers, inline where the requirement is stated.** The pinout
  section asserted the Schmitt-vs-TTL asymmetry and then pointed at the
  feasibility document for the numbers. D040, D041 and D090 now sit beside it,
  including the part a reader needs to judge it: the drive side is
  characterized at exactly one point, 3.8 V against a 3.6 V threshold at 3 mA,
  and nothing at all above 3 mA.
- **The measurement that made the part modular.** 494/520/523 of 1024 words,
  dated 2026-08-05 at `0cfc72e` on the pinned toolchain, against 39 words spare
  on the PIC10F322 -- bound to its commit and marked as spike figures, not a
  current image, per BR-RES-01's rule. It is the reason this part never faced
  the question `pic10f320-architecture` had to answer.
- **The ISR answer for this part, stated as the weaker thing it is.**
  `pic-model-b` already carried the PIC10F322 conversion that would not link.
  On the PIC12F675 the spike *did* link and ran the tested gpsim trajectory, so
  the model was never ruled out by size; what was never obtained is the
  return-stack number that would decide it. Model B stands here by consistency
  and by the absence of a reason to change, not by a measurement, and the
  section now says that rather than implying a symmetric result.
- **The PIC12F629, considered and not taken.** Same die minus the ADC, same
  addresses for every register this shell touches, `ANSEL` and `ADCON0` the
  only difference. Recorded so the next reader does not re-derive it.
- **The `.stc` checkpoint rule** into `test/README.md`. A port spike once saw a
  stimulus declared `initial_state 1` read low before its first transition; the
  spike tree was not retained, so no root cause is claimed and the standing
  check replaced the explanation -- the shipping checkpoint sits 2,560 cycles
  *inside* the disputed window and asserts the pin there.
- **The GP2 bench run and the tool-support residual** into
  `HARDWARE_VALIDATION_LOG.md`, which owns what a controlled run must retain.

**The open risks needed almost no migration**, which was the useful discovery.
`TODO.md`'s `T3-pic12f675-bench` already restated items 1, 2, 8 and 9 in full.
What changed is that it stopped being a restatement: it is now the definition,
and its wording says so. The original numbers are kept as stable identifiers
because the Makefile, the CI notes and the release documentation all cite them.

**The release-qualification gate was repointed rather than dropped.** It used to
require a bounded `current-status` block inside the feasibility document,
opening at line 3, carrying six exact strings, and it ran a contradiction regex
over that block. That block was a summary of facts owned elsewhere, which is
precisely the thing that drifts. The gate now reads the two owners: `TODO.md`'s
`T3-pic12f675-bench` must still enumerate all four items and state that no
controlled record exists, and `DESIGN_DOCUMENTATION.adoc` must still state the
disposition. The same contradiction regex runs over both, so neither can
quietly promote the guarded workflow into a preservation guarantee or demote
the part. All three arms were probe-tested by spoiling each in turn.

**References retargeted:** `Makefile` (7), `test/README.md`, `README.md`,
`release/README.md`, `.github/workflows/ci.yml`, `test/pic/pic10f32x_regs.h`
(to `test/pic/pic12f675_regs.h`, which is where that map actually lives),
`docs/flashing_simplicity.md` (2), `test/test_resource_tables.py`,
`test/pic/test_soak_pic12f675.cc` (2), and `DESIGN_DOCUMENTATION.adoc` (2).
`CHANGELOG.md` keeps its historical mentions. The four firmware comments that
name the document (`src/bypass_mcu_pic12f675.c:32,54,72` and
`src/bypass_pins_pic12f675.h:65`) are BR-PIC-05's, which is now unblocked.

**Two leftovers found by widening the sweep**, both fixed here rather than
left for BR-FINAL-01:

- The first reference sweep filtered on `*.c` and `*.h` and missed `*.cc`, so
  `test/pic/test_soak_pic12f675.cc` still cited two sections of the deleted
  document. Found by re-running the sweep across every extension.
- `release/README.md`'s release sequence still described "the four bounded
  current-release declarations" and linked two of BR-PIC-03's deleted
  PIC10F320 documents as two of them. BR-PIC-03 reduced
  `release-documentation.sh`'s `current_documents` to two and did not reach
  the prose describing the same set, so the live process description named
  files the tree no longer had. It now names the two that remain and points at
  `current_documents` as the designated set, which is what step 0 actually
  validates; `scripts/make-release.sh`'s matching comment was corrected with
  it. No gate caught this, because the validator reads its own array rather
  than the prose about it.

## BR-PIC-05 - Update firmware-source documentation references

**Status:** DONE `f968de7`

**Depends on:** BR-PIC-02, BR-PIC-03, BR-PIC-04

**Files known to require user review:**

- `src/bypass_mcu_pic10f322.c`
- `src/bypass_mcu_pic12f675.c`
- `src/bypass_pins_pic12f675.h`
- Any additional `src/*.c` or `src/*.h` references found by BR-AUTH-02

**Work:**

- [x] Replace references to deleted documents with stable design anchors.
- [x] Correct any stale target naming or current-state claims found during the
  sweep.
- [x] Confirm comment-only changes preserve exact generated images where the
  compiler/toolchain is available.

**Acceptance:**

- No firmware source comment refers to a deleted path.
- User performs the source edits.
- Relevant image identity/resource/qualification gates are rerun.

**Result:**

Eight comment sites across five files, +23/-14 lines, all comment-only. The
sweep found two more files than the task listed: `src/bypass_mcu_pic10f320.c`
and `src/bypass_compile_checks.h` both named
`docs/pic10f320_special_case.md`, which BR-PIC-03 deleted.

- `bypass_mcu_pic10f322.c:13` and `bypass_mcu_pic12f675.c:15` named
  `docs/phase2_pic_shell.md`; both now cite "The shared model: polled tick,
  pure fault watchdog".
- `bypass_mcu_pic12f675.c:32` named the feasibility document's §4.4.1 for the
  1.024 ms tick; it now cites "PIC12F675: the classic mid-range shell".
- `bypass_mcu_pic12f675.c:54` and `:72` named §8 items 1 and 2; they now cite
  `TODO.md` `T3-pic12f675-bench` items 1 and 2, the BG one adding the hardware
  log for what a bench run must retain.
- `bypass_pins_pic12f675.h:65` named §4.2 and §8 item 9; it now cites the
  PIC12F675 pinout section, the part's Datasheet References rows, and
  `T3-pic12f675-bench` item 9.
- `bypass_mcu_pic10f320.c:178` and `bypass_compile_checks.h:17` named
  `docs/pic10f320_special_case.md`; both now cite "PIC10F320: the constrained
  target".

Two conventions were followed rather than invented. Citations use the quoted
section title, not the AsciiDoc anchor, because that is what the seven existing
`DESIGN_DOCUMENTATION.adoc` references in `src/` already do. And the two
`pic12f675-program` comments keep pointing at `release/README.md`, which after
BR-FLASH-01 is the home of the source-checkout transaction they are about; the
downloaded-release route is `FLASHING.md`'s and is a different procedure.

Delivered as a patch for the user to apply with `git apply`, built and verified
without writing to `src/` at all: the hunks were assembled in memory, checked
with `git apply --check`, and applied to a throwaway copy of the tree to
confirm the result before the user saw it.

**Inertness is proven, not asserted.** Two independent checks, one of which
needs no toolchain:

- Stripping every `//` line from each of the five files gives a hash identical
  to `HEAD`, so nothing outside comments moved.
- XC8 and the device pack were available, so the images were rebuilt.
  `pic10f320-test-build` matched the reviewed SHA-256 baseline on all three
  variants (`e48ed8e5`, `1cc2cbf6`, `8193aa0d`) -- the strongest available
  witness, since that lane pins exact bytes rather than a size. Return-stack
  depth stayed 3/8 on all three with the oracle's 149 selftest checks green;
  PIC10F322 rebuilt at 476/502/493 of 512 words, PIC12F675 at 548/574/585 of
  1024 with Data-space 40 of 48.

With this, no file in the repository outside `CHANGELOG.md` and the immutable
`release/vX.Y.Z/` artifacts names a document that Section C deleted.

---

# D. Programming and user guidance

## BR-FLASH-01 - Make FLASHING.md the sole live operator procedure

**Status:** DONE `a1633e0`

**Current duplication:**

- `README.md:104-115,163-296`
- `FLASHING.md:1-275`
- `release/README.md:211-272,376-541`
- Generated release guidance in release scripts

This duplication has already produced safety-relevant contradictions, recorded
in `CHANGELOG.md:42-87` and `CHANGELOG.md:166-195`.

**Work:**

- [x] Keep general operator safety, hardware prerequisites, programmer choices,
  and transaction semantics in `FLASHING.md`.
- [x] Reduce README programming content to a quickstart and prominent links.
- [x] Remove full command sequences from `release/README.md` except where it is
  explicitly describing historical releases or the release-process contract.
- [x] Keep repeated short safety warnings where omission would create physical
  risk.
- [x] Do not repeat PIC12F675 transaction steps in several files.
- [x] Clearly distinguish downloaded-release programming from development and
  release-provenance Make targets.

**Acceptance:**

- There is one maintained general procedure.
- A command change normally requires editing one source or generated
  specification, not three documents.
- PIC12F675 is never presented as a raw-write target.
- The published/software-tested/not-hardware-qualified distinction remains.

**Result:**

`FLASHING.md` was already the complete general procedure and did not change.
What changed is that the other two documents stopped restating it.

Three routes existed, and the duplication was not that three documents said the
same thing -- it is that each said a *part* of three different things:

| Route | Sole live home now |
|---|---|
| Downloaded release, any part | `FLASHING.md` |
| Exact commands for one release | its generated `MANIFEST.md` |
| Source checkout at a signed tag | `release/README.md` |

`README.md` (-82 lines) now publishes no programming command at all. The
guarded PIC12F675 transaction it carried -- the `release_tag`/`repo` preamble,
`pic12f675-preflight`, `pic12f675-release-program`, the PENDING recovery block,
and the four paragraphs restating what each step guarantees -- was a verbatim
second copy of `release/README.md`'s. In its place is one paragraph that says
what kind of thing a PIC12F675 write is and names the two homes. The
`pic12f675-preflight` baseline paragraph was reduced the same way, to the
properties a reader of the overview needs and a pointer for the rules. Its
build and test target listings stayed: those are development entry points, not
programming procedure.

`release/README.md` (-49 lines) lost the `avrdude` example, both PIC10F32x
`pk2cmd` one-liners, and the downloaded-release helper block with its
descriptor-sealing prose -- each of which the per-release `MANIFEST.md` or
`FLASHING.md` already published, generated or maintained. It keeps the guarded
source-checkout transaction, which is the release-process contract the plan
exempts: that sequence exists to bind a device write to a signed tag, and
nothing else in the tree specifies it.

Safety warnings were kept where dropping one costs hardware, and shortened to
the rule rather than the reasoning: AVR needs the design fuse bytes as well as
the flash write, the PIC10F32x parts carry CONFIG inside the HEX so there is no
fuse step, and PIC12F675 is not a raw write target on either route and needs
external power on both.

**One gate had to change, and it became stricter.**
`release_validate_pic12f675_finalization` named `README.md` and
`release/README.md` as always-scanned publishers, each required to publish a
`pic12f675-finalize` command anchored to the programming command it recovers.
That contract, as written, made "README.md stops restating the transaction"
indistinguishable from "README.md silently dropped its recovery instructions",
which is the defect it exists to catch. So discovery was widened from the
recovery half of the pair to *either* half: a document that publishes
`pic12f675-program` or `pic12f675-release-program` is now scanned exactly like
one that publishes `pic12f675-finalize`. Dropping the recovery while keeping
the command it recovers can no longer escape by no longer matching the search,
and a document that publishes neither is not a publisher at all. Only
`release/README.md` stays named. Two preflight cases were added for the new
edges (an unnamed document publishing neither half is accepted; one publishing
a transaction with no recovery is rejected) and the existing "dropped its
recovery instructions" case was repointed at the named document.

One fixture fragility surfaced and was fixed in the document rather than the
test: `test_release_preflight.sh` spoils the helper-status sentence with a
per-line `awk` substitution on `route is published and software-tested`, so
that phrase has to survive on one physical line. A rewrap had split it, the
spoiled fixture still passed, and the test correctly reported that its own
negative case had stopped biting.

**Deliberately not touched.** `TOOLCHAIN.adoc`'s PIC12F675 programmer block
restates a third copy of the Make route's transaction semantics. It is outside
this task's named duplication set, it is scoped as a toolchain fact (which
readback dialect is pinned, what the tools must provide), and reducing it is a
judgement about `TOOLCHAIN.adoc`'s boundary rather than about the operator
procedure. BR-FINAL-01 should decide it.

## BR-FLASH-02 - Generate exact per-release programming guidance

**Status:** DONE `23eac73`

**Depends on:** BR-FLASH-01, BR-REL-01

`docs/flashing_simplicity.md:272-334` already outlines a generated
`PROGRAMMING.md` concept. Preserve the useful proposal without retaining the
entire branch-era discussion.

**What the measurement found.** The release was not missing generated
programming guidance. It had generated guidance -- eighteen per-image commands
in `MANIFEST.md` -- and nothing had ever checked it. Extracting the block from
`release/v0.9.11/MANIFEST.md` and running each line through `bash -n`:

| images | published command | state |
|---|---|---|
| attiny202 x3 | `avrdude ... -U flash:w:<img>:i   (or: make attiny202-program VARIANT=<v> XT_UPDI_PORT=<port>)` | not valid shell |
| pic10f322 x3 | `pk2cmd ... -M -Y -R   (or: make pic10f322-program VARIANT=<v>)` | not valid shell |
| attiny13a/45/85 x9 | `avrdude -c <prog> -p t13 ...` | parses; `<prog>` is a REDIRECTION, so `-c` leaves the argv |
| pic10f320 x3 | `pk2cmd -PPIC10F320 -F<img> -M -Y -R` | pasteable |
| pic12f675 x3 | none, deliberately | guarded transaction, ~30 pinned checks |

Three of twenty-one were runnable. Behind that:

- The `(or: make ...)` forms name a Makefile no downloaded release contains --
  the published assets are the images, `flash-pic12f675.py`, `QUALIFICATION`,
  `MANIFEST.md` and `README.md`. `VARIANT=<v>` asked the reader for a value the
  basename beside it already fixed.
- `XT_PROGRAMMER` is a `?=` default read straight into the published command, so
  a release host that exported a programmer preference published different
  instructions from the same source tag.
- Nothing bound the commands to `RELEASE_IMAGES`, to the fuse bytes their own
  Images row publishes three lines above them, or to being valid shell.
  `release_render_flashing` checked two things: that rows were non-empty, and
  that no PIC12F675 row existed.

**Work:**

- [x] Define one machine programming specification or derive commands from
  existing authoritative release/build data. Rows are `image<TAB>profile<TAB>command`
  over four profiles; every token comes from Makefile truth (`AVR_PROGRAMMER`,
  `XT_PROGRAMMER`, `XT_UPDI_PORT`, `part_<n>`, the fuse variables, the tags).
- [x] Generate exact image names, fuse/CONFIG values, tool requirements, and
  command templates for the release. No placeholders remain: all 18 commands are
  complete and pasteable, and a programmer-profile table carries the substitutions
  and the power assumption.
- [x] Include the generated guide in the signed release asset/index contract.
  It is in `MANIFEST.md`, which `RELEASE_PROVENANCE_FILES` puts inside
  `SHA256SUMS`, which `SHA256SUMS.asc` signs. (v0.9.11 and earlier did not carry
  the provenance files in `SHA256SUMS`; that was already repaired by BR-REL-01.)
- [x] Test behavior and safety invariants, not only rendered sentence spelling.
  The verifier runs `bash -n` over the published block, requires each command to
  name its own image, both-direction coverage against `RELEASE_IMAGES`, every
  fuse in the Images row present as `-U name:w:value:m`, no `-V` on avrdude, and
  `-M -Y` on pk2cmd.
- [x] Keep user-selected facts such as port, programmer, and power arrangement
  explicit rather than pretending they can be generated. They are published as
  defaults inside complete commands and named as the only substitutions in the
  profile table; the PIC rows state that the target is externally powered.
- [x] Ensure PIC12F675 guidance invokes the release helper and never a raw
  writer. Unchanged, and now enforced from two more directions: the producer
  refuses to emit a row for that part, and the verifier fails a manifest that
  publishes one.

**Acceptance:**

- A downloaded release is self-contained for programming guidance -- every
  command runs from the directory holding the download, with no checkout.
- Exact commands are tied to the exact released assets: a command that does not
  name the image it is filed under fails the release.
- Generated guidance and release index cannot disagree silently: coverage is
  checked in both directions against `RELEASE_IMAGES`, and the fuse bytes in the
  command are checked against the cell the same page shows the reader.

**Three properties this added:**

1. The published block is checked through the interpreter a reader pastes it
   into, not by grepping for words.
2. The fuse bytes are rendered twice -- once as a table cell, once inside a
   command -- and the two are now required to agree.
3. The release query environment no longer leaks the host's programmer
   preferences into published instructions.

**What this does not do:**

- No separate `PROGRAMMING.md` landing page, ZIP bundle, or GitHub release body.
  The guidance stays in `MANIFEST.md`, which is already signed and already
  published. BR-FLASH-03 carried both forward as `TODO.md`
  `T3-programming-guide` and `T3-release-bundle`.
- No `ipecmd` command line. BR-FLASH-04 kept it that way, and changed the
  reason: the form now verifies, so what the release says is that it
  publishes the commands it pins to the Makefile's default.

## BR-FLASH-03 - Retire the flashing-simplicity work journal

**Status:** DONE `fc11171`

**Depends on:** BR-FLASH-01, BR-FLASH-02 or explicit deferral of BR-FLASH-02

**Source:** `docs/flashing_simplicity.md`, 678 lines

**What the document was.** A design discussion argued on `v0.9.9-polish` and
preserved in that branch's present tense, with italic update paragraphs added
where a later release built what a section proposed. Its own banner told the
reader how to read it: *"Read an un-updated section as a proposal, not as a
description of the tree."* Five of its sections carried an update; the other
thirty did not, and each of those was a claim about a tree two releases old.
Nothing linked to it. No live document, Makefile goal, or CI job named it --
only the gate that existed to keep its banner honest.

**Work:**

- [x] Preserve shipped decisions in their live authorities. Both are already
  stated where they are enforced rather than where they were argued: the AVR
  build-before-hardware repair by `test/test_avr_program_order.sh`, whose header
  states the defect class more precisely than the journal did, and the
  PIC12F675 no-compiler path by `scripts/flash-pic12f675.py`, `FLASHING.md` and
  `release_validate_pic12f675_flashing_helper`. The refusal to publish a raw
  PIC12F675 writer command is enforced by the raw-writer sweep. Nothing had to
  be moved.
- [x] Preserve any still-open generated-guidance work as concise TODO tasks.
  Three open items -- `T3-programming-guide` (§4.3, §7.4, G1, G2),
  `T3-release-bundle` (§4.4, §7.5, G5) and `T25-program-argv` (§4.2, §4.5, and
  §7.2's residual choice of AVR operation shape) -- and two declined entries,
  the static README command block (§4.6) and the general-purpose interactive
  helper (§4.6, §8). `T3-pic320-program` already carried §7.6; BR-FLASH-04
  built the goal it described and retired the entry.
- [x] Remove branch-era current-state/proposal interleaving. It leaves with the
  file; the 10 unresolvable `§N` citations counted under BR-FINAL-01 leave with
  it too.
- [x] Delete `docs/flashing_simplicity.md`.
- [x] Remove release preflight tests that exist only to keep its status banner
  synchronized with implementation updates.
  `release_validate_flashing_simplicity_status` (96 lines), its two call sites
  in `scripts/make-release.sh`, its two renderer pins, and its eight preflight
  cases are gone. The comment in the raw-writer sweep that cited this document
  as the reason for exact-sentence matching now states the reason without
  naming it, because the reason is general.

**One repair this required.** `test_release_preflight.sh`'s worktree tripwire
snapshots every tracked and untracked-nonignored path, and `git ls-files -c`
lists what the index holds rather than what the disk does -- so a tracked file
deleted but not yet staged made `stat` fail and the whole gate report "could not
snapshot the working tree". Any commit that deletes a tracked file hits this
before it can be staged. The snapshot now records an absent tracked path as an
explicit entry instead of failing, which leaves the comparison exactly as
strong: the entry still appears on both sides, so a file the preflight run
itself deletes is still caught.

**Acceptance:**

- No current safety procedure depends on reading a partly implemented proposal.
- Remaining work is visible in TODO without preserving the entire discussion.

**What this does not do:**

- It does not decide any of the work it filed. `T3-programming-guide` and
  `T3-release-bundle` change what a downloaded release contains, and
  `T25-program-argv` may change the canonical AVR programming shape; all three
  are open items, not deferred implementations.

## BR-FLASH-04 - Close the two PIC10F32x programming-authority gaps

**Status:** DONE `c9aa9ae`

**Depends on:** BR-FLASH-02

Both were found while binding the published programming commands to the
Makefile, and both were left to the user, because they change what a programmer
is told to do to hardware. The user decided all three questions below; what
follows the work items is what those decisions built.

- **The PIC10F320 has no programming authority.** There is no
  `pic10f320-program` target and no `PIC10F320_PROG*` variables, so its three
  published commands are the only ones of the eighteen with nothing to be
  checked against. The PIC10F322 command is now pinned to `PIC10F322_PROG_CMD`
  byte for byte, with the one path substitution a download requires; its
  PIC10F320 twin is pinned to nothing. Deriving one from the other is exactly
  what `scripts/make-release.sh` refuses to do for these two parts, and for a
  stated reason: the separate variable pairs exist so one part can be re-pinned
  without silently moving the other.
- **The `ipecmd` invocation performs no verify pass.** `PIC10F322_PROG_CMD`
  under `PIC10F322_PROG=ipecmd` is `ipecmd -TPPK4 -PPIC10F322 -M -F<hex>`: no
  `-Y`, where the `pk2cmd` form has `-M -Y -R`. That is why BR-FLASH-02
  publishes no `ipecmd` command line -- doing so would hand PICkit 3/4/5 users a
  write with no readback. `FLASHING.md` carries a third spelling
  (`-TPPK3 ... -M -Y -OL`) and says its flags are unconfirmed on hardware.

**Work:**

- [x] Decide whether the PIC10F320 gains its own `PIC10F320_PROG*` variables and
  a `pic10f320-program` target, or whether the release says plainly that its
  PIC10F320 command is unpinned. **Decision: the target.**
- [x] Decide whether the Makefile's `ipecmd` form gains `-Y`, and whether
  `PIC10F322_PROG_TOOL` should default to `PK3` or `PK4` given that `FLASHING.md`
  leads with the PICkit 3 and MPLAB X 6.25 dropped support for it. **Decision:
  `-M -Y -OL` and `PK3`,** which is the spelling `FLASHING.md` and
  `scripts/flash-pic12f675.py` already agree on.
- [x] If the `ipecmd` form gains a verify pass, publish it beside the `pk2cmd`
  command. **Decision: do not.** The gate reasoning still holds -- publishing it
  means teaching `check_flash_commands` and the qualification verifier a dialect
  they both fail closed on -- and the release's stated reason for withholding it
  had to change anyway, because that reason was "it performs no verify pass".

**Acceptance:**

- Every published programming command is checkable against one declared
  authority, or is published as explicitly unpinned.
- No published command writes a device without reading it back.

**What the first decision built.** `PIC10F320_PART`, `PIC10F320_PROG`,
`PIC10F320_PROG_TOOL`, `PIC10F320_PROG_HEX` and `PIC10F320_PROG_CMD`, plus a
`pic10f320-program` goal that builds the selected image and its budget and
return-stack gates before it writes anything. `scripts/make-release.sh` reads
the new `PROG_CMD` and `PROG_HEX` through `mkv`, scrubs the four new names out
of the release query environment, and pins the published PIC10F320 command to
`PIC10F320_PROG_CMD` byte for byte -- the check the 322 already had.

One difference from `pic10f322-program`, and it is the point rather than a
detail. The PIC10F320 lane selects its output stage with `PIC10F320_VARIANT`,
not `VARIANT`; that is what `pic10f320` and every PIC10F320 test, soak and
coverage goal read. So `PIC10F320_PROG_HEX` is `$(PIC10F320_HEX)` itself, the
path the build wrote, and the published source-checkout command spells
`PIC10F320_VARIANT=<v>`. Had the goal taken `VARIANT`, `make pic10f320-program
VARIANT=tq2_l2_5v_relay` would have built the default output stage and written a
different one to a pedal.

That selector split is also why two variant checks were tightened rather than
extended. Both the producer and `scripts/verify-release-qualification.sh` asked
whether the string `VARIANT=<v>` appeared anywhere in the command -- which
accepts `PIC10F320_VARIANT=<v>` by accident rather than by rule, accepts a
longer variant name that merely begins with this image's, and accepts a second,
contradicting assignment appended after a correct first one. Both now split the
command into words, require exactly one variant selector however it is spelled,
and require its value to BE the variant the image names.

**What the second decision built.** One line in each part's `ifeq`:
`-TP<tool> -P<part> -F<hex> -M -Y -OL`, and `PK3` as the default tool. The old
form wrote the whole device and returned without reading a byte back, which is
the one thing every other write path in this repository is not allowed to do --
`check_flash_commands` and the qualification verifier both reject a published
`pk2cmd` line missing `-Y`, and `scripts/flash-pic12f675.py`'s `write_argv()`
has carried `-M -Y -OL` all along. It also disagreed with `FLASHING.md`, which
publishes `-TPPK3 ... -M -Y -OL` for these very parts. Three spellings of one
transaction, one of them unsafe; there is now one.

`-OL` is a behaviour change on the bench: the part runs when the write
completes instead of staying in reset. That is what `-R` already did on the
`pk2cmd` path, so the two dialects now end in the same state rather than in two.

**What the third decision changed.** The release's published paragraph gave a
reason that this change falsifies -- "the invocation this repository defines for
that tool performs no verify pass". It now says what is true after the change:
every command published is pinned byte for byte to the Makefile's default
programming command, `ipecmd` is a non-default override of the same goals, and
its reset-release flag and part-name spelling have not been confirmed against a
part, so that procedure stays in `FLASHING.md` where the caveat travels with it.

**What is enforced, and what is not.** The new gate is a completeness rule, not
a third entry in a list: `test/test_release_qualification.sh` harvests every
`img_row` arm that emits a `pk2cmd` command and every row of the producer's
pinning table, and requires the two sets to be equal -- so a fourth PIC arm
added later fails until it is pinned. It also requires each row to pin a part
against its OWN variables, which is the failure these two parts invite: they
differ by one digit, share a pinout, a programmer and a dialect, and a row that
read `PIC10F320_TAG` and compared against `PIC10F322_PROG_CMD` would report
agreement about the wrong part and pass every other check in the file.

What is not enforced is the hardware. No PICkit has run either command against
either part under a written procedure with retained measurements;
`HARDWARE_VALIDATION_LOG.md` says that of every part here, and `T3-hw-procedure`
is the item it waits on. `TODO.md`'s `T3-pic320-program` -- which asked for
exactly this target, and warned against adding an untested hardware-programming
surface merely for symmetry -- is retired, because what it asked for exists;
its bench half was never separable from the project-wide one. Retiring it also
removed the two name-contract exemption markers it carried -- each declaring
that the entry documented an absent goal -- which the marker-expiry rule would
have failed on the moment that goal started resolving.

- Verified: `make test` green, 0 failures across 101 summaries.
  `test-release-qualification` 175 -> 179 checks (the completeness rule, and
  three source-checkout selector cases: two selectors, a namespaced selector
  naming another variant, and a namespaced selector naming its own).
  `test-release-preflight` 238 checks, 0 failures, 96 -> 98 Makefile queries --
  the two new `mkv` reads, which is the pin that caught them.
  `test-makefile-name-contract` 48 checks, axis B 521 -> 525 commands and axis D
  153 -> 166 mentions. `test-todo-index` 102 -> 99 checks, three fewer for the
  retired entry. `make print-PIC10F320_PROG_CMD` and its `ipecmd` override read
  back the two intended commands.

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

**Status:** DONE `8180569`

**Candidates:**

- `docs/context_seu_detection.md`, 334 lines
- `docs/relay_coil_fault_correction.md`, 407 lines

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

- [x] Classify each file as live safety case, concise ADR candidate, or material
  to merge into the design document.
- [x] If retained, add a short scope banner and remove duplicated current data.
- [x] If merged, delete the original after reference migration.

**Result:** Both are live safety cases, and both are retained. Neither is a
summary of the design document; each is the reviewable argument behind one of
its requirements, and the tree treats them that way. `src/bypass_hw_iface.h` and
nine test files cite the relay policy as the rationale for the contract they
enforce; the `Makefile`'s `BYPASS_CTX_CHECK_FLAG` comment, `MISRA_COMPLIANCE.md`
and four PIC fault-test files cite the F2 record the same way; and
`DESIGN_DOCUMENTATION.adoc`'s PIC10F322 resource section names that record as
the owner of the fold's measured alternative spellings. Deleting either would
leave live code pointing at nothing, and merging either would put an argument
inside a specification.

Each gained a two-part opening banner: a **Scope** paragraph naming the four
owners it does not duplicate -- "Failsafe Mechanisms" in
`DESIGN_DOCUMENTATION.adoc` for the normative design, `src/` for the shipped
code, `test/README.md` for which lane runs where, and release evidence for
per-image figures -- and a **Claim boundary** paragraph. F2's claim boundary was
already there and was condensed; F1 had none, and now states that everything in
it is simulator, host-harness and mutation evidence, and that no simulator
models an armature.

Removed from F2 as duplication of `src/`: the shipped declaration and definition
of `debounce_ctx_check_word()` together with the instruction on where to place
it, the two "essential shape" code blocks restating the shell transaction, and
the numbered per-tick step list. Removed as duplication of an owner: the
`Enablement` section, since the `Makefile` comment that owns the flag already
explains it and points here, and the five-row budget/gate table, which is a
strict subset of the design document's seven-row Flash capacity table and names
the enforcing goal where that one also names the Makefile variable. What each
family's transaction does is now cited; **why the two families place its
boundaries differently** is what the file keeps.

Removed from F1 as duplication of "Failsafe Mechanisms": the two emergency
pin-sequence step lists, the per-shell detection table, the single-masked-write
and parked-GP4 mechanism paragraphs, and the blocking-actuation-window
residual-risk paragraph, which was a near-verbatim second copy.

**Moved:** the classic-AVR simavr footswitch fidelity note, 17 lines of test
mechanics in the relay document, is now `test/README.md`'s "Simulator fidelity:
the classic-AVR footswitch" under the Classic AVR validation layers. Its
name-contract exemption marker moved with it and was rewritten to the own-line
form, which exempts the following line as well as its own. (Spelled without the
colon here on purpose: the marker's own syntax, written out in prose, is read by
the gate as a marker suppressing nothing.)

**Current figures bound or dropped.** F2's acceptance-criteria item 5 said
PIC10F322 "remains the binding capacity case at 502/512 words for the mute
variant": the claim is kept and the number is gone. Its PIC10F320 note said "the
current one is 242/256" and now says the image measured that at `v0.9.10`. F1's
three measured recovery pulses are bound to `v0.9.10` and reframed as fixing the
size of the harness's own 1 ms reset-detection artifact rather than as current
measurements; each lane's actual requirement -- clear the relay's 4 ms datasheet
minimum -- is what the paragraph now leads with, and the 13.5 ms design-pulse
figure it was contrasted against is dropped in favour of that requirement.

**Retained deliberately.** F1's residual-risk list keeps all five entries even
though two of them restate guarantee boundaries the design document also states:
an exclusions list with holes in it is not reviewable, which is the whole point
of keeping a separate safety case. Each is reduced to the claim plus what this
policy adds, and the list says which two are specified elsewhere. Also retained
in full: both Decisions tables, F2's priced alternatives and flash margin note,
F1's comparator-mode evidence table with its DS41190G Figure 6-2 and Section 6.4
citations and the two gpsim model limits that bound it, both harness/oracle
tables, and both mutation-resistance lists. These are argument and evidence, not
requirement.

**Sizes:** F2 334 -> 235, F1 407 -> 368, `test/README.md` 642 -> 661. Net -119
lines, and three fewer maintained copies of a design requirement.

**Reference disposition:** `test/test_resource_tables.py`'s docstring names F2's
"Resource qualification" table among the copies that gate once kept
synchronized. It is written in the past tense, describing why the gate no longer
reads documentation at all, so it stays accurate with the table gone and was not
edited.

**Acceptance:**

- Each retained feature document has a unique assurance purpose.
- No feature document acts as another current status/resource/test-results page.

---

# F. Active documentation simplification

## BR-README-01 - Reduce the root README to overview and entry points

**Status:** DONE `d7104c9`

**Current size:** 335 lines at plan time; 320 at implementation, now 230.

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

**Work:**

- [x] Remove the per-target test command inventories and the PIC12F675
  programming transaction.
- [x] Reduce the surviving build guidance to one lane summary plus the goals a
  reader needs to get started.
- [x] Keep every safety warning, and check that each names the document that
  owns the procedure behind it.
- [x] Confirm no live gate depends on a removed sentence.

**Result:**

- What went: the three per-target lane inventories (PIC10F322, PIC10F320,
  PIC12F675) and the ATtiny202 one, 33 and 25 lines of `make` goals with
  per-goal commentary; the PIC12F675 programming transaction (which route
  applies, the `simcal` derivation, the retained twelve-artifact matrix and its
  promotion rules, the preflight/readback requirements, the `TMPDIR` policy),
  50 lines whose live owners are `FLASHING.md` and `release/README.md`; and the
  skip-clean/fail-closed paragraphs, whose owner is `test/README.md`. The
  simulator-features bullet lost its per-lane inventory and the disassembly
  oracle's compiled cycle counts.
- What replaced them: one paragraph naming the four lanes and what each needs
  beyond the host toolchain, one four-line block of build-plus-aggregate goals,
  and a pointer to `make help` and `test/README.md`. Nothing in the README now
  restates a test's content.
- The PIC12F675 warning was *promoted*, not reduced. It was previously the
  conclusion of a 50-line procedure a reader had to finish to reach; it is now a
  blockquote that states the hazard (a bulk erase destroys per-device factory
  trim, and a part that has lost it still appears to run), forbids the two
  unsafe acts, and names the one home of each route.
- The v0.9.8 cleanup instruction stays, because a user upgrading an old checkout
  still needs it, but the renamed-variable mechanics are now a link to
  `release/README.md`'s override mapping rather than a summary of it. It also
  moved above the ATtiny13a quickstart lead-in, which it had been separating
  from its own code block.
- Retained deliberately, because live gates require this document to publish
  them: `seven release parts across four microcontroller core generations`, the
  `PIC10F322, PIC10F320, and PIC12F675 provide functional, fault-injection`
  clause, and the 21-image scope sentence (`test-release-qualification`); the
  `GCC 10 or newer` host compiler floor, which `test-release-preflight` holds in
  agreement with `MINIMUM_GCC` in `test/host_compiler_version.sh` and with
  `TOOLCHAIN.adoc` and `test/README.md`; and the flashing-helper name, the exact
  downloaded-release programming claim, and the exact
  published/software-tested/not-hardware-qualified helper status, all three
  required of `README.md` by `release_validate_pic12f675_flashing_helper`.
- The README remains a non-publisher of PIC12F675 programming commands, which is
  what `release_validate_pic12f675_finalization` expects of it: the goals it
  names now appear only as prose or as build/test commands, so it is not
  scanned as a document that must also publish a recovery.
- The document map, lifecycle table and standing rules are untouched. They are
  BR-AUTH-01's product and they are the "entry points" half of this task's
  title.
- `# Quickstart` became `## Quickstart`; the file had two top-level headings.
- Verified: `test-makefile-name-contract` (axis B 440 -> 423 commands, axis D
  149 -> 144 mentions, both far above their 200 and 40 floors),
  `test-release-preflight`, `test-release-qualification`, and `make test`.

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
  verifies the same values against real evidence: the 37-file evidence set, the
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

**Status:** DONE `6fa9a1b`

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

**Work:**

- [x] Remove the implementation design from any item whose implementation is
  already in the tree.
- [x] Remove branch-era chronology that no longer identifies anything a reader
  can act on.
- [x] Check every item's named artifacts against the current tree, so an item
  that reads as open really is.
- [x] Keep the `Considered and declined` registry, the hardware-qualification
  gaps, and the non-blocking safety obligations intact.
- [x] Keep the priority summary and the item set mechanically consistent.

**Result:** 756 -> 725 lines, and the small number is the finding. TODO.md was
already close to registry shape; the bloat was concentrated in a handful of
items, and cutting further would have cost acceptance conditions rather than
prose.

One item was carrying finished work. `T25-avr-xt-stack` opened with
"Implementation present on the F2 branch" and then specified, in thirty lines,
a lane that this tree already has: `attiny202-test-stack-bound` is defined at
`Makefile:2431` and reached from `attiny202-test` at `Makefile:2910`, with its
regression in `test/test_stack_bound.sh`. The spec is now history, so it is
gone; the heading, the summary row and the effort estimate name what is actually
left, which is a pinned-toolchain run and the number it produces.

`T3-pic12f675-bench` ended with an instruction that duplicated its own item 2
and was wrong in its tail: it said to record the measured result into
`release/README.md`'s flashing procedure "once it exists", and that procedure
has existed since BR-FLASH-01 (`release/README.md:409`). Item 2 already carries
the surviving instruction. Every string `test/test_release_qualification.sh`
pins in this section is unchanged.

Every artifact named by every remaining item was checked against the tree --
each source file, script, test, patch, Makefile variable and absent goal
resolves, so no item reads as open on the strength of a stale reference.
At the time of this audit `T3-pic320-program` still documented an absent goal,
which is what kept its exemption marker suppressing something. BR-FLASH-04 has
since built `pic10f320-program`; the entry and both of its markers are gone,
which is the same rule read from the other end -- an exemption stops being
earned the moment the name it covers resolves.

Deliberately kept at full length: the six safety obligations under
`T3-nonblocking-actuation`, which are the concise extraction BR-DOC-03 produced
from a 1,523-line analysis and are the acceptance condition for that redesign;
the four numbered PIC12F675 silicon risks, which
`test/test_release_qualification.sh` treats as the definition rather than a
summary; and the `Considered and declined` registry.

Two comments cited TODO.md as the record for measurements it no longer holds --
a prototype allowlist sweep and an "over two minutes" timing, both in
`test/test_makefile_name_contract.py`. They now state the fact without the
dangling citation. Two more remain in the Makefile and are recorded under
BR-COMMENT-01, which owns comment text.

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

**Status:** DONE `512d0c3`

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

**Work:**

- [x] State the PIC12F675 two-route story once instead of three times.
- [x] Drop the hand-maintained per-release evidence inventory.
- [x] Reduce the v0.9.8 rename machinery to the mapping a reader still needs.
- [x] Send the general flashing procedure to `FLASHING.md` and keep only what the
  release process adds.
- [x] Move the maintainer-facing qualification topology out of the front matter.
- [x] Check the published release procedure against the tree it describes.

**Result:** 629 -> 593 lines. Two of the five *Move or generate* bullets were
answered by decisions taken after this item was written, and were recorded rather
than acted on:

- *Current release contract block to canonical release data.* BR-STATE-01 went
  the other way and made `release/README.md` the single live bearer, enforced by
  `_release_reject_extra_current_blocks()`. Moving the block now would reopen the
  duplication that item closed.
- *Current exact programming commands to generated per-release guidance.* The
  `pic12f675-release-program` and `pic12f675-finalize` blocks cannot leave:
  `release_validate_pic12f675_finalization()` names `release/README.md` as the
  sole live home of the guarded transaction and fails if the recovery example is
  deleted from it. `Makefile:7760` states the same requirement as a release gate.
  The *general* per-part procedure did move to `FLASHING.md`, which is the half
  of this bullet that was still open.

The reduction itself was concentrated in one fact told three times. The head
paragraph, the PIC12F675 block under `Which image do I want?`, and `Flash a chip`
each explained that there are two guarded routes, which one needs a toolchain,
and what the helper is. `Flash a chip` is where the commands live and where the
gates anchor, so the other two now point at it.

**Found:** step 1 of `How a release is sequenced` told a maintainer to finalize
the bounded current-release declarations in "this file and `TODO.md`". TODO.md
has not carried one since BR-STATE-01 (`d799c14`) made the declaration singular,
so the published release procedure named a file a maintainer would search in
vain. It now names the one block and says step 0 rejects a second. Two nearby
plural readings ("the bounded declarations") were corrected with it.

**Kept whole and why:** the four errata and safety-warning sections, including
the 24-hour-soak wording erratum and its five manifest links, because they are
the historical record this item is explicitly told to preserve; the enumeration
of the gates a release runs, checked against `scripts/make-release.sh` and found
accurate, because "release policy remains auditable" is an acceptance condition;
and the `RENAME_IDENTITY.md` pointer, because the identity contract itself is
retained by the release directory that ran it.

## BR-COMMENT-01 - Trim migration archaeology from live Make/script comments

**Status:** DONE `b194731`

**Rationale:** Live comments should explain invariants and non-obvious failure
modes. Long histories of retired names and earlier approaches are prone to stale
numbers and duplicate changelog/Git history.

**Example:** `Makefile:459-514` spends roughly 55 lines around a two-function
image naming convention, including extensive pre-v0.9.8 archaeology.

**Found during BR-TODO-01:** two live Makefile comments cite TODO.md as the
record for content TODO.md no longer holds -- `Makefile:482` cites a
"Unified naming scheme" item and `Makefile:3133` cites a "TODO.md history,
2026-08-20". Both are inside the archaeology this item removes, and both send a
reader to a file that will not answer. The same citation class was repaired in
`test/test_makefile_name_contract.py` under BR-TODO-01; these two are Makefile
comments and belong here.

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

**Work:**

- [x] Remove retired naming histories already documented in release history.
- [x] Remove old migration sequences.
- [x] Remove mutable "today" counts.
- [x] Repair the two dangling `TODO.md` citations recorded above.
- [x] Keep invariant, safety, fail-closed and revisit rationale.

**Result:** `Makefile` 8,356 -> 8,317 lines; `scripts/make-release.sh` 2,395 ->
2,393. Ten comment blocks, no executable line touched.

The largest was the item's own example, the canonical-basename section. Its
archaeology enumerated the three retired basename conventions, the
`IMAGE_STAGE_<variant>` map that v0.9.8 added and then deleted, the 6 x 3 and
7 x 3 product matrices, and a 37-versus-38-character name-length comparison.
`CHANGELOG.md` under `0.9.8` carries all of it, in more detail and in some
places in the same words. What that paragraph uniquely held was the reason the
MCU field is mandatory -- a bare `bypass_cd4053.hex` was the ATtiny13a image by
omission, and nothing in the filename stopped it being flashed to an ATtiny85 --
so the safety statement stays and the inventory goes. The stage-field paragraph
keeps its conclusion as a revisit condition: do not reintroduce a translation
table, because a translation table is a place where two names can disagree.

The same one-fact-in-several-places shape as the release README, one axis of the
rename per site: the retired stage tokens again under *Output variants*, the
retired `_t85` part fragments in the `TINYX5_PARTS` note, the retired
`bypass_mcu` prefix where the PIC10F320 lane sets its build names, and the
deleted translation table once more in `scripts/make-release.sh`. Each now
states its own rule and nothing else.

Two more were migration records rather than naming ones. The PIC10F320 gpsim
section carried a FOLD/PARAM/FORK disposition table from the merge; it now
describes what the lane shares with the PIC10F322 and what it forks, which is
the same information as a fact about the tree. The byte-identity gate opened by
explaining that it began as a one-shot migration gate and recording its two
qualifying runs; the reviewed set has lived in
`test/pic10f320/expected_images.sha256` under `pic10f320-test-build` ever since,
and that -- with the rule that rebaselining must be an explicit reviewed change
-- is what a reader needs.

The resource-tables gate no longer opens with what it used to be. It kept the
durable half of that story as a rule: documents carry capacities, ceilings and
method, never the exact figures, because restating them makes a documentation
edit a precondition for a firmware size change.

**Kept and why:** every comment that justifies a live gate by naming the defect
it would have caught -- the clean-contract severance, the `-D<MACRO>=$(VAR)`
fuse-default hole, the analyzer's shrinking subject, the fail-closed target
aggregate, `make-release.sh`'s exact version comparison and its
read-from-the-Makefile soak path. These read as history but are the answer to
"why is this gate here", which the Keep list names first.
`AVR_TEST_BINARIES_RETIRED` keeps its full note, including the growth rule and
the 2026-08-03 addition, because it is the comment that explains why current
variant names appear in a list called retired.

**Found:** `docs/pic10f320_merge_plan.md` was deleted by BR-PIC-03 (`b8b4af1`),
and the tree still cites its section numbers -- `merge plan §5.6`, `§6.12`,
`§14.8`, and bare `§N` references that never named a document at all. Eight
went with the blocks removed here; 48 remain in live code and CI (`Makefile` 24,
`scripts/` 10, `test/` 11, `.github/workflows/` 3). A further 10 in
`docs/flashing_simplicity.md` leave with the file under BR-FLASH-03, and
`CHANGELOG.md`'s 8 are correct as historical record. (The `§` citations in
`DESIGN_DOCUMENTATION.adoc` and `src/bypass_mcu_avr_classic.c` are datasheet
sections and resolve.) The 48 sit inside comments this item keeps, so they are
a reference repair rather than a comment trim: recorded against BR-FINAL-01,
which already carries "Search for stale section-number and line-number
references".

---

# G. Development and release-state model

## BR-STATE-01 - Remove four-way current-release declarations from live docs

**Status:** DONE `d799c14`

**Current copies:**

- `TODO.md:3-15`
- `docs/pic10f320_special_case.md:3-10` (deleted by BR-PIC-03)
- `docs/pic10f320_validation.md:16-27` (deleted by BR-PIC-03)
- `release/README.md:27-30`

Tests currently enforce these copies, so they are controlled duplication rather
than uncontrolled drift. They still impose maintenance and put global release
topology into target-specific and TODO documents.

**Work:**

- [x] Define one human release-state authority.
- [x] Keep literal release identity in the Makefile where it serves as an
  independent fail-closed production pin.
- [x] Remove global topology declarations from TODO and target-specific docs.
- [x] Decline a generated human release-topology view: the sole live declaration
  is already checked semantically against canonical data, so another view would
  add machinery without removing an authority.
- [x] Replace occurrence/prose synchronization tests with semantic release
  identity checks.

**Acceptance:**

- Updating release topology does not require four prose edits.
- Release production still compares selected values with an independent literal
  reviewed identity.

**Result:**

- Two of the four copies were already gone: BR-PIC-03 deleted
  `docs/pic10f320_special_case.md` and `docs/pic10f320_validation.md`. The
  remaining two were `TODO.md` and `release/README.md`.
- `release/README.md` is the single live authority. It is where release policy,
  the trust model, the errata and the reproduction instructions already live, so
  a reader who needs the topology is already in that document. `TODO.md` now
  says where the contract is declared and keeps only what is its own: the dated
  open-work status.
- The declaration is now enforced as *singular*, not merely as *consistent*.
  `release_validate_current_documentation` previously read a fixed list of
  documents and held each to the same canonical counts, which is why the count
  could reach four without any gate objecting -- every copy was correct.
  `_release_reject_extra_current_blocks()` scans every current Markdown and
  AsciiDoc file and fails, by name, on a bounded block anywhere but the
  designated document. An exact copy fails exactly as an inconsistent one does,
  because an exact copy today is the one that disagrees next release. Shipped
  release directories and declared branch-only working documents are exempt:
  neither is a copy anyone maintains.
- Removing the block also removed a false claim no gate could catch. TODO.md's
  pre-tag transition line said `release/v0.9.11/` "does not contain it yet",
  and the tree has contained it since `760f5fd`. The validator skips the
  transition-line requirement once the directory exists, so the sentence was
  stale, load-bearing-looking, and unchecked.
- Work item 2 needed nothing: `RELEASE_IDENTITY_PINNED` in the Makefile is
  already the independent literal production pin, and `make-release.sh` already
  refuses a release goal whose selected identity drifts from it.
- Work item 4 (generate human release topology from canonical data) is declined.
  With one hand-maintained declaration held to canonical counts at release time,
  generation would buy correctness that is already enforced. BR-RES-03 and
  BR-FLASH-02 separately generate the resource and programming views that have
  real consumers.
- A latent defect in `test_release_preflight.sh` surfaced and was fixed.
  `declare_in_block()` read `local document=$1 line=$2 target=".../$document"`
  on one line; bash expands every word of a `local` assignment list *before*
  creating any of the names, so `$document` there resolved to whatever the
  caller had in scope -- which was the fixture loop's last value, `TODO.md`.
  The helper had been ignoring its first argument, and the case that claimed to
  test `release/README.md`'s blockquoted block was editing `TODO.md`. The two
  declarations are now separate statements, with the reason recorded. A
  repository-wide scan found no other instance of the pattern.
- `test_release_history.sh`'s D3 fixture -- an artifact commit may not restate a
  bounded declaration -- now carries its declaration in `release/README.md`,
  the document the rule is actually about.
- BR-FINAL-01's "search for duplicated current-release declarations" is now
  mechanical rather than a manual sweep.
- Verified: `test-release-preflight` (216 -> 221 checks, 0 failures),
  `test-release-history`, `test-release-qualification`,
  `test-makefile-name-contract`, and `make test`. A negative control on the live
  tree confirmed a second copy in `TODO.md` is refused by name.

## BR-STATE-02 - Treat main as development and releases as immutable snapshots

**Status:** DONE `d4675d0`

**Rationale:** Unreleased source is inherently in development. Non-developers
should consume signed release images and the corresponding tagged snapshot and
evidence, not mutable candidate measurements or speculative release status.

**Work:**

- [x] Keep ordinary `main` under `[Unreleased]`.
- [x] Decide whether version/date declarations should be made only on a release
  candidate branch or selected source-finalization commit.
- [x] Remove claims that an absent release directory already contains evidence.
- [x] Keep the source-commit versus artifact-commit distinction explicit.
- [x] Define abandonment/correction behavior for a selected release candidate.

**Acceptance:**

- Development source never implies final evidence exists before publication.
- Release consumers have one immutable snapshot and asset set to evaluate.
- Release tooling still binds evidence to the exact qualified source.

**Result:**

- Four of the five work items were already discharged in prose and needed only
  to be confirmed and recorded. `v0.9.9` defined the four-step sequence and the
  rollback rule after `v0.9.10` was declared released in a tree that contained
  no `release/v0.9.10/`; BR-STATE-01 reduced the declaration to one document.
  The decision item is settled and has been settled since `v0.9.9`: version and
  date declarations are made on a **selected source-finalization commit on
  `main`**, not on a release-candidate branch. The reason is that
  `scripts/verify-release-history.sh` requires the artifact commit's sole parent
  to be the qualified source commit, so the qualified source must already be on
  the line the artifact descends from; a candidate branch would either have to
  be merged before qualification, which reintroduces the merge as an unqualified
  parent, or produce an artifact whose parent is not on `main`. The suffixed-tag
  grammar (`vX.Y.Z-rc.1`, published as a GitHub prerelease) already covers the
  case a candidate branch would exist to serve.
- The sweep for claims that an absent release directory contains evidence comes
  back empty. Every live reference to a `release/vX.Y.Z/` path outside shipped
  release directories names one the tree contains -- `v0.9.4` and
  `v0.9.6`-`v0.9.10` in `release/README.md`, and `v0.9.9` in both
  `docs/flashing_simplicity.md` and a `scripts/release-documentation.sh`
  comment. `CHANGELOG.md`'s are historical record. The one live false claim of this class was already found
  and removed by BR-STATE-01.
- What was actually left undone was enforcement, and it was the whole of it:
  **the single authority for the release contract was checked only on release
  day.** `release_validate_current_documentation` is reachable only through
  `scripts/make-release.sh`, which supplies the version being cut and the
  canonical counts; nothing in `make test` called it against the working tree.
  Between releases the bounded block could name any version, any image and soak
  counts, and any retained record, and the suite had no opinion. Every other
  live-tree release rule -- `release_validate_hardware_claims`,
  `release_validate_pic12f675_finalization`,
  `release_validate_pic12f675_flashing_helper` and
  `release_validate_flashing_simplicity_status` -- is already asserted against
  `$ROOT` in `test_release_preflight.sh`; the declaration BR-STATE-01 made
  singular was the one that was not.
- `release_validate_development_state` closes it, in the same file and asserted
  the same way. It takes the two inputs from the two places that cannot be
  edited to agree with the declaration: the version from the declaration itself,
  the image and soak counts from the Makefile that builds them
  (`print-RELEASE_IMAGES`, `print-RELEASE_SOAK_NAMES`, both already exempt from
  parse-time toolchain discovery). Passing the declaration's own numbers back to
  it would have made the check tautological, which is the trap this shape
  avoids.
- It then reconciles the declared version with what the tree can substantiate.
  A tree declaring `vX.Y.Z` whose `release/vX.Y.Z/QUALIFICATION` is absent must
  carry the exact pre-tag transition line. Previously that disclosure was owed
  only by a block that happened to *name* the directory -- and the sole
  surviving declaration does not name it, so the rule had become unreachable on
  the live tree exactly when BR-STATE-01 removed the two blocks that did. The
  marker is `QUALIFICATION`, not the directory, because that is what
  `verify-release-history.sh` treats as "this tree already contains the
  release", so a directory an aborted cut left behind is still the pre-tag state
  and still owes the disclosure.
- The reconciliation is deliberately **one-sided**: the disclosure is required
  when it is owed and permitted when it is stale. Refusing the stale direction
  would be the stronger claim, but the artifact commit may change only
  `release/vX.Y.Z/` and so structurally cannot retract the line it makes false,
  which would leave `main` red between the artifact commit and a retraction
  commit on every release. A disclosure that understates is the safe direction,
  and the next source finalization rewrites the line for its own version. The
  trade-off is recorded at the function and in `release/README.md` so a later
  reader sees a decision rather than an omission.
- The pre-tag transition line had two spellings-in-waiting once two rules read
  it, so it is now produced by one `_release_transition_line` helper.
- `release/README.md`'s pre-tag-window section now states the rule in the
  stronger form it is actually enforced in, and says the check runs on every
  `make test` rather than on release day.
- Verified: `test-release-preflight` 221 -> 230 checks, 0 failures, and the
  full `make test`. Negative controls on a scratch copy of the live tree
  confirmed all six refusals fire with their own diagnostics: a missing
  disclosure during the window, a declared image count the build does not
  produce, a declared version with no changelog section, a block declaring no
  contract, a block declaring two, and -- now live rather than release-day --
  BR-STATE-01's second copy in `TODO.md`.

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

**Status:** DONE `cee6bab` + `0dada67`

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

**Status:** DONE `bb5ba13` + `b5704f7`

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

- [x] Decide whether to evolve `QUALIFICATION` or introduce a clearly versioned
  `release-index.json` rather than create parallel authorities. **Decided by the
  user: evolve `QUALIFICATION`.** It is already the versioned machine authority
  with a closed schema, it already extends by binding evidence digests
  (`pic12f675_matrix_sha256`, `resource_tables_sha256`), and a JSON root would
  be a second authority during transition -- the thing this item warns against.
  Offline verification also stays `sha256sum` + `gpg` with no JSON tooling.
- [x] Define canonical serialization and parser behavior. Unchanged and already
  strict: `key=value`, closed key set, unknown keys rejected, duplicates
  rejected, never sourced. `format` moves 3 -> 4.
- [x] Sign the canonical root or bind its digest in the signed tag. Done by
  bringing `QUALIFICATION`, `MANIFEST.md` and `README.md` inside `SHA256SUMS`,
  which the detached signature already covers.
- [x] Generate human manifest, release notes, programming guide, and checksums
  from canonical data where practical. Done for the one surface that had no
  authority at all: the toolchain table is now rendered from
  `evidence/toolchain.txt`, bound by `toolchain_sha256` in `QUALIFICATION`
  (`format=5`), and checked back against it in both directions. The other three
  surfaces this bullet names were measured and already satisfied it -- see the
  second-half result below -- so "where practical" is now exhausted rather than
  outstanding.
- [x] Ensure every published payload is transitively authenticated. Every file
  in a release directory is now either inside `SHA256SUMS` or inside
  `evidence/`; the evidence set is separately bound by exact digest from
  `QUALIFICATION` for the two artifacts that carry release claims.
- [x] Keep `SHA256SUMS` as a standard user verification view if useful, but do
  not maintain a conflicting independent hash table. `SHA256SUMS` remains the
  single list and simply got wider. No second table was introduced.
- [x] Reject unknown fields/versions according to an explicit compatibility
  policy; do not add speculative backward compatibility. The policy differs
  between the two verifiers because their inputs differ, and that distinction is
  the whole of it. `verify-release-qualification.sh` accepts `format=4` only: it
  runs on a directory being staged or a tag being published and never on a
  historical release, so a branch for an older format would be unreachable code
  claiming a capability nothing exercises. `verify-release-images.sh` accepts all
  three published eras -- no `QUALIFICATION` (v0.9.0-v0.9.5), `format=1`
  (v0.9.6-v0.9.9), `format=3` (v0.9.10-v0.9.11) -- because
  `verify-release-program-image.sh` runs it against a published directory on
  every PIC12F675 field programming. That is a live path over directories that
  exist, not speculative tolerance. Pre-`format=4` releases are held to the old
  contract rather than waved through: they must not list provenance either.

**Acceptance:**

- Every per-release fact has one machine authority. *Partly: the facts
  `QUALIFICATION` carries do; the toolchain table and the `Built:` /
  `Validation:` / `Release set:` lines still do not. Second half.*
- Human views cannot drift because they are generated and checked. *`MANIFEST.md`
  was already checked on 7 facts; `README.md` now is too. Generation from
  canonical data is deferred.*
- Offline integrity verification remains possible. *Improved: the same two
  commands now authenticate provenance as well as firmware.*
- Qualification, reproducibility, integrity, and hardware validation remain
  distinct claims. *Unchanged; nothing was merged.*

**Result of the first half.**

**The measurement that reframed this item.** Its "current duplication" list
names eight surfaces, implying eight authorities that disagree. The tree says
otherwise. `QUALIFICATION` is already a versioned machine authority --
`format=3`, closed key set, unknown keys rejected, duplicates rejected, never
sourced. `verify-release-qualification.sh` already binds seven `MANIFEST.md`
facts to it by exact-line match, plus the express/production banner in both
directions. Evidence logs already carry exact source-bound machine records
(`SOAK_RESULT format=1`, `TEST_LONG_RESULT format=1`,
`RESOURCE_TABLES_RESULT format=1`). The gap was never duplication. It was facts
with *no* authority, and one of them was structural.

**The structural one.** In all twelve published releases, `SHA256SUMS` covered
the 21 images and `flash-pic12f675.py` -- and not `QUALIFICATION`, not
`MANIFEST.md`, not `README.md`. A recipient who ran exactly the two commands
`release/README.md` gives them authenticated the firmware and nothing about
where it came from: not the source commit, not the qualification mode, not the
soak duration, not the PIC12F675 raw-write hazard. Those three files could be
replaced with no verification failing. `scripts/make-release.sh` asserted the
opposite in its own express-release warning -- "MANIFEST.md carries the express
banner and QUALIFICATION records release_mode=express; both are signed by the
checksum signature below" -- which was false when written and is true now.

**What changed.** `RELEASE_PROVENANCE_FILES` is declared once in the Makefile
and read by everything that needs it. `make-release.sh` appends those files to
`SHA256SUMS` after generating them, in a second pass, so images are still
checksummed the moment they are proven while provenance is checksummed once it
exists. `verify-release-images.sh` partitions `SHA256SUMS` into three
exactly-declared sets instead of two -- images, helpers, provenance -- and
snapshots the provenance files so its `sha256sum -c` leg speaks for them.
`verify-release-qualification.sh` moves to `format=4`, re-checks each provenance
digest against the file on disk, and binds the per-release `README.md` to
`QUALIFICATION` for its version heading and its banner in both directions.
`release.yml` derives the published asset set from the same declaration, because
publishing a set narrower than the checksum list would hand every downloader a
`sha256sum -c` that fails on a file GitHub never served.

**The one thing that had to be checked in the workflow, not the scripts.**
`README.md` was not previously a published release asset. Adding it to
`SHA256SUMS` without adding it to the upload set would have broken verification
for everyone who downloads assets rather than cloning -- a regression invisible
to every local gate. Both the freeze step and the publish step now read the
declaration instead of naming files.

**Historical releases are untouched, and that is not laziness.** Bringing their
provenance inside their signatures would require reissuing a published
signature. They stay as published, and `release/README.md` now says so and gives
the tag-diff command; `test-published-release-immutability` (BR-REL-07) already
pins every one of those files by digest.

**Verification.** `test-release-qualification` 89 -> 101 checks with twelve new
controls: README missing, symlinked, naming another release, express without its
banner, production carrying the express banner, production carrying the dry-run
banner, dry-run missing its warning; each provenance file removed from the
checksum list; a provenance file edited after sealing; and a manifest that gains
a paragraph contradicting nothing the other checks read, which only the sealed
digest catches. `test-release-images` 240 -> 249 with nine: provenance absent
from `SHA256SUMS`, declared but absent from the release, symlinked, edited after
sealing, an empty set, a duplicate, `SHA256SUMS` declared as its own provenance,
a provenance name shaped like an image, and a name declared as both helper and
provenance. `test-release-preflight`'s Makefile-query tripwire moves 91 -> 92 for
the one new query.

**A defect the full suite caught, and what it corrects.** The first attempt
applied the "no speculative backward compatibility" bullet to
`verify-release-images.sh` as well. That was wrong, and `test-pic-build` failed
on it: unlike the qualification verifier, this one is run against PUBLISHED
release directories by `verify-release-program-image.sh` every time a PIC12F675
is field-programmed. Requiring the new partition there broke programming from
every release published to date. The caller set is the thing that decides the
policy, and it has to be checked per verifier rather than inherited from the
neighbouring one. `release/` also turns out to hold three contracts, not two:
v0.9.0-v0.9.5 ship no `QUALIFICATION` at all, v0.9.6-v0.9.9 declare `format=1`,
v0.9.10-v0.9.11 declare `format=3`. All are accepted by the image verifier and
held to the old contract from both sides; only `format>=4` requires provenance
inside the signature.

**Result of the second half.** The measurement narrowed this to one thing
rather than the four the item lists. The `Images` table's `sha256` column is
already derived from `SHA256SUMS` rather than authored, and sealing
`MANIFEST.md` now protects it from post-hoc edits. The `Validation:` line is
already bound behaviourally: tag CI re-runs the exact targets it claims on a
clean runner. `Built:` is a timestamp/user/host line and is inherently
unverifiable. What is genuinely unbound is the **toolchain table** -- 13
captured `TC_*` values rendered into 15 authored rows, with no machine authority
and nothing checking them, so a wrong compiler version passes every gate. The
captures are now written once to `evidence/toolchain.txt` (tab-separated, since
a version string can contain anything but a tab), bound by `toolchain_sha256` in
`QUALIFICATION` at `format=5`, and the table is *rendered from* that record
rather than printed beside it. The verifier holds the rendered table back to the
record in both directions, because either alone is satisfiable by a wrong table:
every record must appear as a row, and the row count must leave no row the
record does not justify.

**A second defect in `bb5ba13`, found while doing this.** `make-release.sh`
still wrote `format=3` while the verifier it invokes over its own staged output
required `format=4`. A real release would have failed at the very end of a
24-hour run. No gate caught it because nothing runs the producer end to end --
`test-release-qualification` builds synthetic QUALIFICATION files, so the
producer and the verifier never met. `test-release-provenance` now greps both
numbers out of the two scripts and requires them equal, which is the only place
they meet before a real release.

**A renderer deleted rather than left standing.**
`release_render_pic_toolchain_rows` produced four of the fifteen rows and is now
redundant with the record. Its unit test called it but asserted nothing about
its output -- the assertions around it were about other renderers -- so it was
dead in production and untested in fact. It is gone, and the attribution claims
it did protect (one XC8 and one DFP serve BOTH the PIC10F322 and the PIC12F675;
no ambiguous generic `| XC8 |` row) are re-exercised through
`release_render_toolchain_table` against a synthetic record file.

**Verification.** `test-release-qualification` 101 -> 110 with nine controls:
toolchain evidence missing, symlinked, edited after recording, a recorded tool
missing from the table, a version edited in place, an unrecorded tool smuggled
into the table, a result record miscounting its own rows, evidence bound to
another commit, and a record with no version. `test-release-provenance` 63 -> 64
for the producer/verifier format agreement. The canonical evidence set moves 35
-> 36 files.

**One guard removed for being unreachable.** The first draft opened
`toolchain.txt` behind a `-f/-L/-s` check. The canonical evidence-set comparison
already establishes all three and reports them better, which is why
`resource-tables.log` beside it has no such guard -- so keeping mine would have
been exactly the unreachable defence this item's compatibility bullet warns
against.

**What the other three bullets turned out to be.** Measured rather than assumed,
and none of them needed work. The `Images` table's `sha256` column is *derived*
from `SHA256SUMS` (`make-release.sh`, `img_row`) rather than authored, so it has
one source already -- and sealing `MANIFEST.md` in the first half is what now
stops it being edited afterwards. The `Validation:` line is bound behaviourally,
which is stronger than any string check: tag CI re-runs the exact Make targets
the line claims, on a clean runner, and the aggregates fail closed on a silent
skip. `Built:` is a timestamp, user and uname string; there is nothing to bind
it to, and pretending otherwise would add ceremony rather than assurance.

**Not done, and deliberately.** Per-asset records as structured data -- role,
media type, size beside each digest -- remain unbuilt. `SHA256SUMS` already
carries the digest, the `Images` table already carries MCU, clock, flash use and
fuse identity, and both are now inside the signature. A third representation
would be the parallel authority this item opens by warning against, so the
remaining candidate fields are left to whoever has a consumer that needs them.

## BR-REL-02 - Index retained evidence and bind the logs nothing was checking

**Status:** DONE `f401507` (archive half DECLINED, see below)

**Depends on:** BR-REL-01

**Original observation:** Recent releases add roughly 35-60 tracked files and
around 400 KiB of mostly unique evidence. The v0.9.9 evidence is roughly 481 KiB
unpacked but about 63 KiB as a compressed archive. Images are tiny and heavily
deduplicated; loose evidence is the primary growth source.

**Both halves of this item were wrong, in opposite directions.** The archive
half compared the wrong two numbers, and the index half asked for something
BR-REL-07 had already built. What the measurement found instead was a
qualification gap neither half named.

### The archive half: DECLINED, because it measures worse than doing nothing

The 481 KiB -> 63 KiB comparison is unpacked worktree bytes against a compressed
archive. It omits that Git already compresses and deduplicates every blob it
stores. Measured against the object store rather than the worktree:

| | bytes |
|---|---|
| All release evidence, worktree | 2,370,942 |
| The same evidence in the Git object store | **268,663** (11.3%) |
| As 12 per-release gzip archives | 304,131 (**13% worse than today**) |
| As 12 per-release xz archives | 153,720 |

An xz archive per release saves 114,943 bytes: 0.5% of a 21 MB `.git`. Against
that, 68 of the 306 evidence files are cross-release duplicates that cost
nothing today because Git stores 238 unique blobs, and archiving would make each
one unique and incompressible across releases. `test/` is the largest category
in HEAD at 579,563 bytes, more than double all evidence.

An archive would also make evidence reachable only through a decompressor,
which the item's own acceptance criteria warn against, in exchange for a saving
that rounds to zero. Declined on the measurement, not on effort.

### The index half: already built, by BR-REL-07

`test/published_release_digests.txt` records every final published evidence file
by digest -- 306 of them -- and `test_published_release_immutability.py`
enforces, together with each release's own `SHA256SUMS`, a partition covering
every published file exactly once. Its header states the charter directly:
"Every published file a release does not sign for itself." A full-file digest
column in `evidence/INDEX` would have been a second record of the same fact with
no rule about which wins when they disagree.

So `evidence/INDEX` carries **no digest column**. The build/target terminal
record it commits now contains the one digest of the different object that
matters to qualification: the exact operation payload before that record was
appended. The index records what each retained file is for and what concluded
it; the publication registry freezes the resulting final file.

### What the measurement actually found

`published_release_digests.txt` is an immutability gate, not a qualification
one. `print_record` is "computed from the tree" -- a directory scan run by a
person after publication -- so it records whatever was staged. It cannot catch a
release staged with the wrong evidence; it freezes it.

And at staging time, **13 of the 36 retained files had no content authority of
any kind**: seven build logs (`soak-build.log` among them) and six PIC/ATtiny202
target-test logs. The verifier confirmed the name was present and the file
non-empty, and read no further. That is 137,642 bytes, **62% of the evidence
tree**. Of the 19 result-bearing logs, only 8% of their bytes sit inside a line
any gate matches.

`soak-build.log` was the one that nearly escaped this count: it matches
`soak-*.log`, but it carries no `SOAK_RESULT format=1` record and the loop
covers only the 18 named combinations.

**Work:**

- [x] Decline the archive, recording the object-store measurement as the reason.
- [x] Decline the per-member digest column, because BR-REL-07 already holds it.
- [x] Declare every retained file's role in the Makefile, never inferred from
  its name, so the index cannot be its own authority for what a member is.
- [x] Write `evidence/INDEX`: one row per member with role, size and terminal
  record, plus a source-bound header and result record.
- [x] Bind it as `evidence_index_sha256` from `QUALIFICATION` at `format=7`.
- [x] Emit an `EVIDENCE_RESULT` record into each of the 13 unbound logs, binding
  each at operation closure to the released commit, declared role, own name,
  payload line count and exact payload SHA-256.
- [x] Verify the index against the Makefile and against the files, both
  directions: no member unlisted, no row unmatched.
- [x] Retain raw logs where forensic detail is useful -- unchanged, and now the
  reason the archive was declined.
- [x] Transfer the duplicate initial/final output-only log decision to
  BR-REL-08. That task retained both operations and gave their records distinct
  phase roles because their byte-identical v0.9.11 payloads represented
  different release claims.

**Acceptance:**

- Evidence remains complete, indexed, authenticated, and offline-inspectable.
- ~~Publication handles one archive rather than dozens of loose logs.~~
  Withdrawn: the archive is declined.
- ~~Compression does not become the only undocumented way to recover
  evidence.~~ Withdrawn with it, and satisfied absolutely: there is no
  compression step.

**What this does not do.** The `EVIDENCE_RESULT` records add no verdict. Each is
written immediately after its command exits zero, before staging can bless a
stale or substituted transcript. What they add is payload identity and
attribution: a log from a different run, a same-shape substitution, a log
substituted for its neighbour, a truncation and padding all stop matching. That
is the difference between evidence that is present and evidence that is
accounted for.

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

**Status:** DONE `e04765a`

**Depends on:** BR-REL-01, BR-REL-02 (partially satisfied -- see below)

**What BR-REL-02 settled, and what it did not.** The signed-hash requirement
below is already met, by BR-REL-07 rather than by this item: every published
evidence file is recorded by digest in `test/published_release_digests.txt`, so
hashes stay in Git whatever happens to the payloads. The **offline archive**
requirement is NOT met, because BR-REL-02 declined the archive on measurement.
This item must therefore keep the evidence in Git or require a new durable
mirror before any removal; it can no longer inherit one.

**Caveat:** The initial review was performed offline and could not inspect hosted
release assets or repository tag-protection settings. Verify actual hosted state
before migration.

**Work:**

- [x] Inventory which historical evidence currently exists only in Git.
- [x] Verify exactly what each hosted release publishes, or refuse migration
  when that verification is unavailable. The latter is the selected policy.
- [x] Define asset replacement/deletion protections and operational ownership.
- [x] Retain signed hashes in Git even if payloads move to hosted assets.
- [x] Define at least one durable independent mirror or offline archive for
  evidence removed from development `main`.
- [x] Define recovery if the hosting service or release asset disappears.

**Decision:** Retain all release evidence in Git. Do not perform the hosted-asset
migration this item was written to guard.

The local inventory covers twelve annotated, signed cuts and 576 files under
`release/v*/`. Their own `SHA256SUMS` lists authenticate 215 files; the retained
digest registry accounts for the other 361. Historical tag workflows intended
to publish 258 top-level assets in total, but no locally retained signed receipt
proves what the hosting service accepted or still holds. All 306 `evidence/`
members and all twelve per-release `README.md` files were outside those workflow
asset sets, so 318 files must be treated as Git-only; `v0.9.10` is known to have
no hosted release at all. Workflow intent is not rewritten as hosted fact.

The durable policy is now `release/README.md`'s "Evidence retention and hosted
assets" section. Git remains the authority and hosted assets are dissemination
copies. The release maintainer owns byte-identical recovery from the retained
tag/tree and may not silently replace an asset with corrected bytes. If a future
proposal removes payloads from the development branch, it must reopen this
decision with an exact hosted inventory, explicit operational ownership, an
authenticated full Git mirror or offline archive under independent control, and
a demonstrated restoration. `test/published_release_digests.txt` keeps the
hashes but is explicitly not mistaken for that archive.

This disposition makes the unavailable hosted-state inspection non-blocking
without weakening either acceptance criterion: no evidence moves, and no URL or
hosting setting participates in provenance. Historical directories and tags are
unchanged.

**Acceptance:**

- No evidence is removed from Git before exact authenticated archival backfill.
- Hosted URLs are never treated as immutable provenance by themselves.

The first has a mechanical floor from BR-REL-07: every published evidence file
is now recorded by digest, so a payload that moves to a hosted asset has to be
removed from `test/published_release_digests.txt` in the same commit, by
someone who has to say so. It does not check that the backfill happened -- only
that the removal cannot be quiet.

## BR-REL-05 - Keep future releases self-contained

**Status:** DONE `a636400`

**Rationale:** Repeated firmware images are inexpensive and self-contained
releases are safer than deltas or links to prior assets.

**The policy already held. The whole published history now says so, in numbers.**
Every release from `v0.9.0` to `v0.9.11` was compared against the one before it,
using the digests each release signed for itself rather than the files on disk.
Not one of them replaced an image with a delta or a pointer at an older release.
Every release directory carries its era's complete image set as regular files --
12, then 18, then 20, then 21 -- beside its helper and its provenance.

| Release | republished unchanged | rebuilt | what moved |
| --- | --- | --- | --- |
| `v0.9.1` | 0 | 20 | every image rebuilt |
| `v0.9.2` | 15 | 5 | exactly the five PIC10F322 images, by that part's 16 MHz to 2 MHz core clock drop |
| `v0.9.3` | 12 | 0 | the TMUX4053 polarity errata withdrew the eight `_tmux` variants rather than rebuilding them |
| `v0.9.4` | 6 | 6 | the three PIC10F322 images and the three Classic AVR mute images |
| `v0.9.5` | 0 | 12 | every image rebuilt |
| `v0.9.6` | 12 | 0 | ATtiny202 and PIC10F320 joined the set; six images added |
| `v0.9.7` | 18 | 0 | a test and release-tooling release; no firmware image changed |
| `v0.9.8` | 0 | 0 | every image renamed, so no name is shared with `v0.9.7` |
| `v0.9.9` | 18 | 0 | PIC12F675 joined the set; three images added |
| `v0.9.10` | 2 | 19 | only the two PIC10F320 cd4053 images survived unchanged |
| `v0.9.11` | 21 | 0 | `v0.9.10` was tagged and never published |

**What settles each work item:**

- **Every canonical image is published in every release, unchanged bytes
  included.** This is not a habit, it is mechanically impossible to break:
  `test-release-images` compares a release's contents, its `SHA256SUMS` and a
  fresh reproduction against the canonical `RELEASE_IMAGES` set, and against the
  literal `RELEASE_IDENTITY_IMAGES` pin behind it (BR-FINAL-03). Omitting an
  image because its bytes did not change fails in both directions -- an image
  missing from all three observed sets at once is the case that gate was built
  for.
- **Helpers and verification metadata travel with the release.**
  `RELEASE_HELPER_MAP` binds the staged helper to its tracked source, and since
  `v0.9.12` `RELEASE_PROVENANCE_FILES` puts `QUALIFICATION`, `MANIFEST.md` and
  `README.md` inside the signature rather than beside it.
- **No release refers to another for content.** Searched: the only paths any
  published `README.md`, `MANIFEST.md` or `QUALIFICATION` writes into a release
  directory are into its own. The version numbers that do appear in other
  releases' text are historical statements -- `v0.9.11`'s manifest notes that
  the imported `bypass_mcu_` prefix "is gone as of `v0.9.8`" -- and not
  dependencies. Nothing under `release/` is a symbolic link either, which is the
  other way an image could become a pointer.
- **Byte identity is now identified rather than merely occurring.** This was the
  gap; see below.

**The finding: byte identity between releases is the normal case here, and
nothing said so.**

Five of the eleven releases -- `v0.9.3`, `v0.9.6`, `v0.9.7`, `v0.9.9` and
`v0.9.11` -- republished every image they inherited without a byte changing, and
two more republished most of theirs. That is the policy working as intended: a
release repeats an unchanged image instead of pointing at the older one. But it
is also what makes the failure invisible. A build that restaged its
predecessor's images rather than producing its own would publish, verify,
reproduce and pass every gate in the tree, because repeated bytes are exactly
what a correct release looks like here.

`v0.9.11` is the sharpest case. All 21 of its images are byte-identical to
`v0.9.10`'s, and that is the entire point of the release: `v0.9.10` was tagged
and never published because its own gate refused the environment CI ran it in,
after tag CI had already rebuilt all 21 images from the tagged source and
confirmed they reproduced bit for bit. A reader holding both directories cannot
tell that from the releases themselves.

**The repair: declare the relation, and recompute it from the signed lists.**

`test-published-release-immutability` already owns the published set and the
principle -- "the question is never whether a published file may be amended, it
is whether the amendment is on the record". A new row,
`image-continuity-is-declared`, extends that principle from amendment to
continuity. It reads the `SHA256SUMS` of each release and its predecessor,
counts the shared image names that carry the same digest and the ones that do
not, and requires the table above to state both numbers and a reason. The
comparison is between the two signed lists, not the files on disk, because those
digests are what each release published about itself.

The next release therefore cannot be cut without someone writing down what it
did to the images it inherited. If the answer is "all 21 unchanged, because the
firmware did not change", that is a sentence someone chose to write; if it is
unexpected, the gate says so before publication rather than after.

**Verification:** the gate goes from 2,719 checks to 2,764 over 12 releases and
11 declared continuities, and the declared table matched the computed relation
on the first run. Three negative controls against doctored copies of the
published tree via `PUBLISHED_RELEASE_ROOT`, each rejected with the intended
message: a `v0.9.10` that restages one of `v0.9.9`'s images (which fires twice,
because the doctored digest moves the following relation too), an undeclared new
release, and a declaration left behind for a release that is no longer
published. The pristine copy passes.

**What this does not do:** it does not decide whether a republication was right,
only whether it was intended and said so. It cannot see a release that rebuilt
an image and got identical bytes because the source genuinely did not change --
that is indistinguishable from restaging, and correctly so, since the two
produce the same release. And it says nothing about the images a release adds or
drops; the canonical set and the identity pin own that.

**Correction, `57bca4d`:** the row as first committed blocked every future
release, and the full suite is what found it. `test-release-history` builds a
synthetic future prerelease and runs this complete gate against it; that release
inherits images and can declare nothing, so the gate failed. The synthetic one
only stood in for the real problem: a release's continuity counts are not known
until its images are built, and the commit that publishes them may change only
`release/<version>/` plus the one canonical append to the publication registry,
so no commit existed in which a new release's declaration could land. That is
the defect class BR-RVW-01 found -- a gate no prospective release can pass --
reintroduced by the gate written to close a different hole.

The requirement is now owed one release later rather than never. The newest
release is not required to carry a declaration; a declaration it does carry is
still checked; and the requirement returns the moment the next release
supersedes it, because that release's own source commit cannot go green without
it. Three controls over the declaration table alone, with the published tree
read unmodified: removing a superseded release's entry (`v0.9.10`) is rejected
by name; removing the newest release's entry (`v0.9.11`) passes, at 2,760 checks
against 2,764 -- exactly the four the exemption costs; and giving the newest
release the wrong counts is still rejected. A green run is not silent about
the deferral either: while the newest release has not declared, the passing
summary carries `(<version> owes one)`, so the operator who just published
it is told rather than whoever cuts the next release finding out.
`test-release-history` returns 92 checks, 0 failures.

**Acceptance:**

- A release remains usable and verifiable without another release.

This is held mechanically rather than by policy: the `payload-still-verifies`
row requires each release directory to verify on its own, offline, by a
recipient who has only it and `sha256sum`.

## BR-REL-06 - Consider artifact-only tagged commits outside future main history

**Status:** DECLINED

**Depends on:** BR-REL-01, BR-REL-02, BR-REL-04

**What BR-REL-02 settled.** The "compact signed index" this proposal wants an
artifact-only commit to carry now exists: `evidence/INDEX`, bound by
`evidence_index_sha256` from a signed `QUALIFICATION`. The evidence archive
listed beside it was already hedged as "possibly", and is declined, so the third
question below is answered: there is no archive to retain in the tagged commit.

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

**Decision:** Declined in `6e0e728`. Keep dedicated artifact commits reachable
from ordinary development history.

The proposal preserves the existing source-parent/artifact-child distinction but
removes the child from the branch that supplies its durable reachability. That
trade is no longer justified after BR-REL-02 declined an evidence archive and
BR-REL-04 selected Git, not hosted assets, as the retention authority. The local
audit found no authenticated hosted receipt for any historical release, found
318 retained files outside the historical workflows' intended asset sets, and
confirmed that `v0.9.10` has no hosted release at all. An off-main tag would
therefore make tag protection, hosting retention and an as-yet-unbuilt mirror
part of recovery without removing a current storage emergency.

The current four-step sequence remains. Qualification measures a source commit;
one dedicated child carries only the new release tree and its canonical digest-
registry append; the signed tag points to that child; and the child remains
reachable from the development branch after publication. Source archives do not
need to substitute for omitted verifier/evidence files, the declined evidence
archive is not revived, release-history verification needs no alternate
topology, and ordinary Git garbage collection cannot discard the release while
the branch and tag retain it.

The durable edit also qualifies an adjacent stale sentence that still said the
artifact child changes only `release/<version>/`. Since BR-RVW-01, the one
permitted exception is the exact canonical append to
`test/published_release_digests.txt`; the sequencing section already said so and
the history gate enforces it. The two descriptions now agree.

This deliberately does not satisfy the proposal's checkout-size objective. The
measured repository is small, and BR-FINAL-06 shows that all baseline-to-tip
file-count growth is the two retained release trees. The accepted cost is visible
and bounded per release; the alternative's unauthenticated-host and reachability
risk is not. `release/README.md` now carries the durable rule so this decision
survives deletion of the branch plan.

**Acceptance:**

- Source-to-artifact provenance remains at least as strong as today.
- Signed tags remain sufficient to locate authenticated release metadata.
- Ordinary development checkouts stop accumulating future loose release trees.
- Historical tags and commits remain untouched.

The last is enforced by BR-REL-07 for the twelve releases that exist: this
proposal reorganizes the directory these gates read, so any prototype of it
fails `test-published-release-immutability` the moment it touches a published
tree rather than only the machinery that writes new ones.

## BR-REL-07 - Preserve historical releases during prospective migration

**Status:** DONE `24c2ded` + `7fe055b`

**Work:**

- [x] Do not edit existing `release/v*/` contents.
- [x] Do not rewrite early historical exceptions to match the modern policy.
- [x] Correct "keep current safety errata outside immutable historical files":
  the tree deliberately does the opposite, and is right to. See the finding
  below.
- [x] Transfer historical reproduction to `release/README.md`, which requires a
  checkout of each release's own tag and gives tag-local commands for every
  historical naming and verifier boundary. Execution remains part of an actual
  reproduction attempt, not a migration property.
- [x] If old payloads are eventually removed from the tip of `main`, do so only
  in an ordinary new commit after archive verification; do not rewrite history.
- [x] Verify old tagged objects remain reachable after any tip cleanup.

**Acceptance:**

- Every published historical release remains verifiable exactly as released.
- Prospective simplification does not retroactively change historical claims.

**Result:** these were six instructions addressed to whoever performs the
migration, in a document BR-FINAL-07 deletes, and nothing enforced any of them.
`make test-published-release-immutability` now does, over
`test/test_published_release_immutability.py` (the gate) and
`test/published_release_digests.txt` (the record). 2116 checks, in
`TEST_GATES_LATE` beside the other release gates, so it reaches `test`,
`stress` and `test-long`.

**What was actually unprotected.** Each release ships `SHA256SUMS` over its
images and programming helpers, and `test-release-images` /
`test-release-provenance` / `test-release-qualification` / `test-release-history`
are thorough -- but every one of them validates the release *machinery* against
synthetic fixtures in a scratch repository. None reads the twelve published
directories in this tree. Their signed lists cover 215 of the 576 published
files. The remaining 361 are the evidence logs, `QUALIFICATION`, `MANIFEST.md`,
`README.md` and `SHA256SUMS.asc` itself: the account of what was run, not
reproducible from source, and until now editable in complete silence.

**Finding: the third bullet was wrong, and the tree already knew.** "Keep
current safety errata outside immutable historical files" is contradicted by
`release/v0.9.0`-`v0.9.2`, whose `README.md` and `MANIFEST.md` each carry a
TMUX4053 polarity warning added after publication -- the only reason those three
directories differ from their tags at all. That was the correct call: someone who
fetches `release/v0.9.1/` and nothing else has no other channel through which the
warning can reach them, and a pointer from a file they did not download is not a
warning. The bullet as written would have required reverting it. So the gate does
not forbid amendment; it requires that an amendment be on the record. The six
amended files are registered with the reason, the markers that must survive in
them, the anchor they send the reader to, the check that the errata has not
spread to a release it does not describe, and the check that none of them is
covered by any `SHA256SUMS` -- which is *why* the amendment could not weaken a
verifier, asserted rather than assumed.

**The eight rows.** `payload-still-verifies` (each release's own list still
verifies, so offline integrity is checked rather than inferred from having held
once); `record-still-matches` (the 363 recorded digests); `every-published-file-
is-covered-once` (the two lists partition each directory exactly -- a file
covered by neither can be rewritten silently, one covered by both invites the two
to disagree -- plus the per-release header counts, which make a payload file
moved into the record detectable where no tag is reachable);
`no-image-escapes-the-signed-list`; `no-published-file-is-a-link` (every check
above reads content through the path, so an image swapped for a link to
identical bytes elsewhere satisfies all of them -- publication already refuses
symlinked assets, inventories and signatures, and this holds the published tree
to the same rule afterwards); `amendments-are-on-the-record`;
`the-tag-still-agrees`; `every-release-is-registered`.

**The record is a `sha256sum -c` file on purpose.** From the repository root,
`sha256sum -c test/published_release_digests.txt` reproduces the central claim
with coreutils and no Python, so the gate is not the only way to check its own
central assertion.

**The tag is the independent witness, and it degrades honestly.** Both lists are
lists this tree keeps, and a rewrite thorough enough to update one could update
the other; the signed tag is the one witness a rewrite here cannot reach. The
decisive negative control is exactly that: a published file edited *and* its
recorded digest updated to match passes every other row and is still caught. CI
checks out shallow and untagged (no `fetch-depth: 0` in either workflow), so the
row cannot always run -- it reports `tag cross-check ran for N of 12` rather than
passing quietly, and the other seven rows are complete without it.

**Verification:** 21 negative controls against a doctored full clone, each
required to fail with the specific row that should catch it -- an evidence log
gaining a byte, an evidence log deleted, an image edited, an image deleted, an
unlisted file appearing, a file claimed by both lists, an image moved out of the
signed list into the record, a misstated per-release count, the errata stripped,
the anchor renamed, the errata spread to a fourth release, an amended file pulled
into the signed list, a release deleted, an unregistered release appearing, a
missing detached signature, the record deleted, the signing key altered, the
edit-plus-matching-digest case, an image swapped for a link to identical bytes, a
whole evidence directory swapped for a link, and a dangling link appearing. All
21 rejected with the intended row; the pristine copy passes. Also verified with
no Git repository present at all: 2695 checks, `tag cross-check ran for 0 of 12
(no release tags in this clone)`, an edited evidence log still caught, and all
three link substitutions still caught -- which is the case that matters, since
CI is exactly a clone with no tags.

**Not done here.** Signature verification: `SHA256SUMS.asc` is pinned as bytes,
but checking it against the signing key needs GnuPG and a trust decision
`scripts/verify-release-signature.sh` already owns. The record covers
`release/signing-key.asc` so the trust root cannot be swapped silently;
`release/README.md` is deliberately not pinned, being current documentation.

## BR-REL-08 - Collapse duplicate release phase logs

**Status:** DONE `df344a7`

**Depends on:** BR-REL-02

**Rationale:** `build-avr-classic.log` and `final-image-build.log` were
byte-identical in `v0.9.11`. BR-REL-02 deliberately did not collapse them,
because doing so changes what the release runs rather than only how evidence is
indexed. The deferral must have a real owner rather than pointing at an
undefined task.

**Work:**

- [x] Decide whether the initial and final build phases remain independently
  useful operations or are duplicate execution.
- [x] If both operations remain, emit phase-specific structured records that
  establish the distinct claim made by each.
- [x] If one operation is redundant, remove it and update the retained evidence
  role map, index, qualification verifier, release documentation, and fixtures
  atomically. Not applicable: both operations remain for the distinct reasons
  recorded below.
- [x] Preserve the final-candidate image identity and post-soak rebuild checks;
  do not collapse two genuinely independent image witnesses into one.

**Result:** The byte-identical historical payloads were an output coincidence,
not duplicate execution. The initial Classic AVR phase performs a clean
source-to-ELF/HEX build and catches build or inventory failure before expensive
qualification. Validation later rebuilds the ELFs and invalidates their paired
HEX files. After soak, the final phase removes only those HEX files and
materializes them from the unchanged validated ELFs; those are the bytes hashed,
remeasured and staged. The initial HEX files are therefore not an independent
witness for the final candidate.

Both operations and filenames remain. Their operation-sealed records now carry
distinct `initial-image-build` and `final-image-build` roles from the Makefile's
independent role map. The producer and qualification verifier require the exact
expanded role set, derive each terminal record with its declared role, and reject
a final-phase log carrying the initial-phase role. Release documentation states
where each claim stops. Evidence membership, index cardinality, qualification
format, historical releases, validated-ELF hashes, post-soak comparisons, final
image hashing and byte-bound staging are unchanged.

Shell syntax and `git diff --check` passed. The focused
`test-release-qualification` run did not reach a verdict within 180 seconds on
this host while repeatedly encountering the absent AVR compiler; the external
full-toolchain run remains the validation authority for that regression.

**Acceptance:**

- No two retained logs exist solely as byte-identical copies of one command.
- Every retained phase has a distinct release claim and a verifier that checks
  it.
- Final staged images remain bound to the qualified and reproduced bytes.

---

# J. Firmware and hardware-specific boundaries

## BR-SRC-01 - Preserve deliberate firmware duplication

**Status:** DONE `28f8ffe`

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

**Result:** the list above is now enforced rather than only written down, in
`test/test_deliberate_duplication.py` (`make test-deliberate-duplication`, in
`TEST_GATES_EARLY`, so it reaches `test`, `stress` and `test-long`). 335 checks
over eight rows; each row names the independent opinion a merge destroys and
asserts a structural witness that fails when it does, and the failure message
carries the reason so it is read at the moment of the merge.

The defect class this closes: folding one of these pairs leaves EVERY existing
gate green. The survivor still agrees with itself, and there is nothing left to
disagree with, so the loss is silent by construction. A review gate that lives
only in prose cannot report it -- and this plan document is scheduled for
deletion by BR-FINAL-07, which would have taken the list with it.

The eight rows and their witnesses:

- **`pic10f320-shell-shares-no-header`** -- the shell includes only `<xc.h>`,
  `<assert.h>` and `<stdint.h>`; no header this tree owns. It also still defines
  its own two pin ordinals and its own four watchdog terms, because
  self-containment is a claim about what it carries, not only about what it
  declines to include.
- **`pin-map-per-part`** -- each of the four pin maps includes no project
  header, defines all six per-part names exactly once, and defines each as a
  numeric LITERAL: `#define WDT_LOOP_WORK_MS OTHER_PART` would satisfy a
  presence check while making two parts one. The selection chain in
  `bypass_output_common.h` must still name every map and still refuse an
  unselected target.
- **`entry-point-per-shell`** -- each of the five shells defines exactly one
  `main(void)`, and no other translation unit in `src/` defines one; a shared
  loop TU is what a fold would look like.
- **`two-loop-shapes`** -- the two AVR shells define exactly one interrupt
  handler each, on DIFFERENT vector names (different peripherals on different
  core generations); the three PIC shells define none, which is what makes their
  watchdog bound legitimately computable with an ISR duty of zero.
- **`clock-only-from-the-build`** -- no file in `src/` defines `F_CPU` or
  `_XTAL_FREQ`; every shell asserts something about its own clock macro; and
  `bypass_config.h` still rejects a build that omits it. Two statements that CAN
  disagree is the point, and a firmware-side default would make them agree by
  construction.
- **`pic-harness-pin-facts-are-literal`** -- no file under `test/` includes a
  part's pin map directly, and the four harnesses that reach one through the
  selection chain are named, because they compile production code on the host
  rather than state an expectation about it. A stale exception fails too.
- **`two-pic-return-stack-witnesses`** -- both witnesses exist, each still names
  its own input (generated assembly, shipped Intel HEX), neither has started
  handling the other's, and the Makefile still runs both.
- **`verification-layers-remain-distinct`** -- ten layers, each with an artifact
  that exists, a target the Makefile defines, and a reference from the Makefile
  to the artifact; artifacts and targets are pairwise distinct.

Two rows from the list above are deliberately NOT restated here, because
`test/test_static_assert_guards.sh` already holds them: the PIC10F320's copy of
the watchdog conversion must stay textually identical to
`bypass_output_common.h`'s, and a shell may only stop including the shared
threshold header if it is recorded as carrying its own copy. Repeating those
would create a third copy of the same claim, which is the failure mode this work
exists to describe.

One finding worth recording, because it corrects an assumption the list invites:
**the AVR classic simulator harness shares the firmware's pin map on purpose.**
`test/bypass_output_host.h` says so outright -- "the sim tests pull the pin
numbers from the SAME firmware headers the firmware compiles against, so a pin
reassignment can never silently diverge". So "independent simulator output
masks" is true of the PIC harnesses, whose device identity is literal in
`test/pic/pic10f32x_regs.h` and `test/pic/pic12f675_regs.h`, and NOT of the AVR
classic sim, whose independent pin opinion is the documentation pinout that
`test-pinout-alignment` compares against. The row is scoped to what is actually
true rather than to the whole sentence.

Verification: 18 negative controls against doctored copies of the tree via
`DUPLICATION_ROOT` -- a shared header added to the self-contained shell, a pin
map deferring to another, a per-part term turned into a reference, a dropped
selection arm, a removed `#error`, a lifted main loop, a shared vector name, an
ISR added to a polled shell, a firmware-supplied clock, a deleted clock assert,
a harness reading a part map, a stale exception, a harness taking its facts from
the firmware, a stack witness reading the other's artifact, a deleted witness,
an unwired witness, a deleted layer subject, and a renamed layer target. All 18
rejected with the intended message; the pristine copy passes. `make test` green.

## BR-SRC-02 - Low-risk firmware-source cleanup candidates

**Status:** DONE `801e033`

**Candidates:**

- Make `src/bypass_output_common.h` include its own `<stdint.h>` dependency.
  Complete below.
- Remove empty `src/bypass_output_cd4053_simple.h`, or give it a real driver
  contract such as selector validation. Removal complete below.
- Add one-hot backend/output selector guards. The PIC10F320 output, modular-shell
  output and modular backend-selector slices are complete below.
- Require each modular output driver translation unit's expected selector.
  Complete below.
- Correct stale MCU-neutral comments in `src/bypass_config.h`. Complete below.
- Replace deleted-document references after PIC consolidation. Complete in
  BR-PIC-05.

**Prerequisites:**

- Build/test recipes must pass explicit selectors consistently.
- Static-analysis recipes must cover each expected selector.
- Negative compile tests must be ready to prove new guards are load-bearing.
  DONE by BR-SRC-03: `test/test_target_guard_mutations.sh` retains the original
  invalid configurations as exact assertions when their guards land. Modular
  shell output cardinality, PIC10F320's former incidental dual-scheme rejection,
  modular backend identity and foreign driver selection are complete below.
- Pinned toolchains must be available for image/resource/timing comparison.

**Acceptance:**

- User performs source edits.
- All supported MCU/output tuples build.
- Expected preprocessor-only changes produce byte-identical images where
  intended.
- Any generated-byte change is intentional, reviewed, and fully requalified.

**Completed slice -- PIC10F320 output selectors (`cdeaf00`):** The user added
one explicit file-scope guard for the three output-selector macros. More than
one selector now fails on `PIC10F320 output selectors are mutually exclusive`
before the shell's two selection idioms can disagree and produce unrelated
undeclared-pin diagnostics. Exactly one selector preprocesses the guard away,
so supported builds are expected to remain byte-identical; a changed
expected-image hash is not to be rebaselined without investigation.

The BR-SRC-03 handoff fixture was converted from `INCIDENTAL` to an exact
`ASSERT:` expectation rather than deleted, proving under XC8 that the new guard
is the reason the invalid configuration fails. The independent census moves the
PIC10F320 shell from 18 to 19 declarations and the whole firmware from 79 to 80;
the target-local group is now 53. Current comments in the mutation script and
Makefile move with those counts.

Local verification is necessarily structural because this host has no XC8,
PIC device pack or AVR compiler: shell syntax, the 19-guard file census, the
80-guard whole-source census and the exact source/fixture diagnostic agree;
`test-deliberate-duplication` passes 350 checks. The focused full-toolchain
checks are `make STRICT_TOOLS=1 test-pic-guard-mutations`, `make STRICT_TOOLS=1
test-static-assert-guards` and `make STRICT_TOOLS=1 pic10f320-test-build`; the
last must match all three pinned image hashes. This completed slice does not
claim the other optional candidates above are implemented, so BR-SRC-02 remains
`NEEDS USER`.

**Completed slice -- direct `<stdint.h>` dependency (`98d912f`):** The user
made `bypass_output_common.h` include the standard header that defines the
`uint32_t` type used by its watchdog-budget arithmetic. The header no longer
depends on whichever selected pin map it includes first to provide that type
transitively. The pin maps retain their own direct includes because they also use
fixed-width integer types independently.

This is an include-order cleanup only. Strict host compilation of a translation
unit that includes the common header passes under each of the four modular MCU
selectors. Preprocessor output before and after the edit is token-identical for
all four selectors, and `test-deliberate-duplication` passes 350 checks. The
cross-toolchain confirmation is `make STRICT_TOOLS=1 all`; no generated-byte
change is expected, and any changed release image must be investigated rather
than accepted as part of this slice. No permanent regression was added for the
presence of a single conventional dependency include. The other optional
candidates remain, so BR-SRC-02 stays `NEEDS USER`.

**Completed slice -- MCU-neutral configuration comments (`6f02ae8`):** The user
corrected five stale descriptions in `src/bypass_config.h`. The AVR-only block
now names both AVR generations instead of calling itself Classic-only, its
exclusion note names both modular PIC shells rather than only the PIC10F322, and
the Classic-arm label no longer says `AVR Class`. The shared debounce thresholds
now describe high/low footswitch-pin samples rather than the AVR Classic's `PB0`
reads, and input noise is no longer described as an interrupt on firmware whose
PIC shells poll the switch.

Every changed line is a `//` comment or the comment suffix of a preprocessor
line. Removing those suffixes from `HEAD` and the worktree gives the same
SHA-256, so the executable token stream is unchanged and no generated-image
change is expected. `test-deliberate-duplication` passes 350 checks; the
static-assert guard gate skipped cleanly because this host has no `avr-gcc`. No
permanent regression was added for prose inside firmware source. The other
optional candidates remain, so BR-SRC-02 stays `NEEDS USER`.

**Completed slice -- remove the empty simple-CD4053 header (`fe15fd2`):** The
user removed `src/bypass_output_cd4053_simple.h`, which contained only an include
guard and was not included by any firmware translation unit. The host shim no
longer performs a no-op include for the non-blocking output variant; only the
mute and relay variants include dedicated headers for their timing constants.
Makefile dependency lists and rebuild-test sandboxes no longer invent or watch
the deleted file, and the documented MISRA boundary is now the actual 14
authored headers without an explicit unparsed-header coverage limit.

The deleted header contributed no preprocessor tokens beyond its unused guard,
so firmware images are expected to remain byte-identical. The focused fake-tool
rebuild gates pass 35 Classic-AVR checks, 48 PIC10F322 checks, 102 PIC10F320
checks, 168 PIC12F675 checks, five PIC profile-request checks and 45 workload
checks. The analyzer matrix passes 22 checks over its exact 60 rows, and
`test-deliberate-duplication` passes its reduced 347-check inventory. The native
golden model also passes 988 checks after the host shim stops including the
header. The other optional candidates remain, so BR-SRC-02 stays `NEEDS USER`.

**Completed slice -- modular output-selector cardinality (`ba99202`):** The user
added one shared file-scope guard to `bypass_compile_checks.h`, which all four
modular MCU shells include. A shell now rejects both zero output selectors and
more than one of `CD4053_SIMPLE`, `CD4053_WITH_MUTE` and `TQ2_L2_5V_RELAY` with
the diagnostic `exactly one modular output selector must be defined` rather than
compiling under a missing or ambiguous output contract. The self-contained
PIC10F320 retains its separate `OUTPUT_*` guard.

The existing AVR-XT and PIC10F322 dual-selector handoff fixtures now require the
exact diagnostic instead of `UNGUARDED`, and matching zero-selector fixtures
prove the other side of exactly-one under both compiler families. The shared
header's census moves from five to six declarations and the whole firmware from
80 to 81. Exactly one selector preprocesses the guard away, so supported images
are expected to remain byte-identical. Three valid-selector preprocessing probes
are token-identical to `HEAD`; native syntax probes compile all three valid
selectors and reject zero and two selectors with the exact message. The updated
81-guard census agrees, and `test-deliberate-duplication` passes 347 checks. The
target mutation gates skipped locally because this host has neither `avr-gcc`
nor XC8; the focused full-toolchain checks are `make STRICT_TOOLS=1
test-static-assert-guards`, `make STRICT_TOOLS=1
test-attiny202-guard-mutations` and `make STRICT_TOOLS=1
test-pic-guard-mutations`. Backend identity and per-driver selector guards
remain separate optional candidates, so BR-SRC-02 stays `NEEDS USER`.

**Completed slice -- explicit modular backend identity (`e0a1bac`):** The user
added an exact-one guard for the four modular `BYPASS_MCU_*` backend selectors in
`bypass_output_common.h` and made the Classic pin-map branch depend on
`BYPASS_MCU_AVR_CLASSIC` rather than treating the compiler-family macro
`__AVR__` as a target identity. Classic production, clang, cppcheck and MISRA
flags now pass that selector explicitly, matching the existing AVR-XT,
PIC10F322 and PIC12F675 flags.

The target guard fixtures now require the project-owned backend diagnostic when
AVR-XT, PIC10F322 or PIC12F675 loses its selector; AVR-XT and PIC10F322 also
prove that two selectors are rejected. The analysis-matrix contract now treats
Classic as an explicit backend and the fake-tool rebuild gate requires both
ATtiny13a and tinyx5 compile commands to carry it. Exactly one backend
preprocesses the guard away, so supported images are expected to remain
byte-identical. All four valid backend preprocessing probes are token-identical
to `HEAD`; seven native syntax probes compile the four valid identities and
reject no selector, bare `__AVR__`, and two selectors with one authoritative
diagnostic each. The Classic rebuild gate passes 35 checks, the exact analyzer
matrix passes 22 checks over 60 rows, the workload rebuild gate passes 45, the
PIC build gate passes its 48/102/168 per-part checks plus five profile checks,
the stack-bound regression passes 23, the host golden model passes 988, and the
strengthened deliberate-duplication witness passes 348. Target mutation gates
remain unexecuted locally because this host has neither `avr-gcc` nor XC8.
At this slice's commit boundary, per-driver selector guards remained a separate
optional candidate, so BR-SRC-02 stayed `NEEDS USER`.

**Completed slice -- per-driver output-selector identity (`801e033`):** The user
added a file-local `#error` guard to each of the three shared output-driver
translation units. Each now requires its own `CD4053_SIMPLE`, `CD4053_WITH_MUTE` or
`TQ2_L2_5V_RELAY` selector before includes, so directly compiling a foreign
driver can no longer succeed merely because every MCU pin map exposes aliases
for all three variants. The shared shell guard remains the sole owner of
exact-one output cardinality; these driver guards assert only local identity.

The three retained foreign-selector handoff fixtures now require the relay
driver's exact project diagnostic under AVR-XT, PIC10F322 and PIC12F675. Two
additional AVR-XT fixtures prove the simple and mute drivers' own diagnostics,
covering every new guard without redundantly testing every driver/backend cross
product. All twelve valid driver/backend preprocessing combinations are
token-identical to `HEAD`; native syntax probes compile all three matching
selectors and reject all three foreign selectors with one error each. The host
golden model passes 988 checks, Classic rebuild 35, analyzer matrix 22 over 60
rows, workload rebuild 45, PIC rebuild 48/102/168 plus five profile checks,
stack-bound regression 23, deliberate duplication 348, and reference contract
18 across 229 files and 15 documents. The target mutation lanes and Classic
static-assert lane skipped locally because this host has neither `avr-gcc` nor
XC8. No valid preprocessor tokens or generated image bytes are expected to
change. This completes the last unresolved candidate listed above and closes
BR-SRC-02.

**Follow-up selector integration correction:** The first target-toolchain run
found that each foreign-driver fixture used the intentionally wrong selector as
its nominal control. Once the guards landed, that control correctly failed
before the fixture could mutate anything. Each row now starts from the driver's
matching production variant, proves that control compiles, and then replaces
only its selector with the foreign one. The same review found that the Classic
clang-tidy and clang-analyzer loops passed only the backend selector; they now
iterate explicit source/selector tuples, and a fake-analyzer contract checks all
five pairings. `test-analyze-variant-guard` passes 21 checks; the analyzer
matrix, Classic rebuild and workload rebuild contracts pass 22, 35 and 45.

The next full-toolchain run exposed the same stale selector assumption in the
watchdog budget-map fixture: production `CFLAGS` already selected Classic, then
the loop added AVR-XT or a PIC backend and correctly tripped the exact-one guard.
The fixture now removes only the Classic backend from its private flag set and
requires no backend to remain before each row adds the map it is measuring. All
other production compiler flags remain in force. Four native map controls pass,
as do shell syntax, `git diff --check` and the 348-check deliberate-duplication
contract; the complete lane still requires the unavailable `avr-gcc`.

## BR-SRC-03 - Expand negative compile-guard coverage before source cleanup

**Status:** DONE `781cb43`

**Observation:** Existing static-assert negative testing is strongest for
Classic AVR/shared sources and does not equivalently exercise target-local
guard families.

**Work:**

- [x] Census guards in every MCU shell.
- [x] Add narrowly mutated negative compiles under each full target toolchain.
- [x] Cover wrong MCU, conflicting backend selectors, wrong output selector,
  wrong pin, wrong clock, enum/layout assumptions, and timing-budget violations.
- [x] Require the intended diagnostic, not merely any compilation failure.
- [x] Keep target-local guards target-local.

**Acceptance:**

- Adding or deleting a required guard declaration changes the per-file census.
- Selected high-consequence predicates in each target-local risk family are
  proven load-bearing under the relevant toolchain. This does not claim that an
  arbitrary predicate rewrite in every declaration is mutation-covered.

**Result:**

The observation understated it. `test/test_static_assert_guards.sh` compiles the
classic-AVR lane only, and its guard census listed five files holding 27
guards. The firmware declares **79**. The remaining 52 sit in the four MCU
shells that need a target toolchain -- `bypass_mcu_avr_xt.c` (11),
`bypass_mcu_pic10f320.c` (18), `bypass_mcu_pic10f322.c` (8) and
`bypass_mcu_pic12f675.c` (15) -- and nothing in the tree compiled a single
mutated input against any of them. Neither half of the pair was in place: no
mutation could prove one of those guards fires, and the census did not even
count them, so deleting one outright was also invisible.

Those 52 contain guards no shared proof can stand in for. A pin assert
resolves `_PORTA_RA3_POSN` out of the Microchip device pack or `PIN7_bp` out of
`<avr/io.h>`; a clock assert reads the `-D_XTAL_FREQ` or `-DF_CPU` only that
part's build passes; a watchdog assert compares against that part's own de-rated
floor over a tick and an ISR duty that also differ by part. Compiled with
another part's toolchain each one evaluates a different expression, or does not
preprocess at all.

`test/test_target_guard_mutations.sh` closes the target-toolchain gap for the
selected risk families, in the discipline the
classic-AVR file established: copy `src/` to a throwaway tree, break one INPUT
to a guard, compile with flags read from the Makefile via `print-<VAR>`, and
require the failure to carry that guard's own message. 53 fixtures over 20
compile configurations. The firmware is never modified.

Two targets, not one, because the reasons they skip differ:
`test-attiny202-guard-mutations` needs `avr-gcc` and the vendored ATtiny device
pack, `test-pic-guard-mutations` needs XC8 and its device pack, and a machine
with one should still prove that half. Both route through the standard `$(SKIP)`
mechanism and are registered in `test/test_strict_tools.sh`, so under
`STRICT_TOOLS=1` a missing toolchain fails the run rather than quietly removing
the coverage.

**The census is deliberately NOT in either of them.** Counting needs no
compiler, so it stays in `test_static_assert_guards.sh` and now spans all nine
files and all 79 guards. Had it moved behind the optional lanes, a host without
XC8 would have had nothing at all standing between the majority of the
firmware's compile-time invariants and silent deletion.

Coverage against the checklist above, all under each part's own toolchain:

- **Wrong pin** -- pin ordinals on all four shells, including the PIC12F675's
  GP3/GP4 spare-pin family, where moving the footswitch onto GP3 must trip both
  the identity guard and the "no weak pull-up on this part" guard, and moving it
  onto GP1 must trip both identity and output-collision. Multi-message rows are
  required as families, so deleting one sibling cannot hide behind another.
- **Wrong clock** -- `_XTAL_FREQ` on all three PICs, `F_CPU` on the ATtiny202.
- **Wrong MCU** -- dropping the part selector. On the PICs this reaches
  `bypass_output_common.h`'s "no pin map selected". On the ATtiny202 it does
  not: that part also defines `__AVR__`, so a shell that loses
  `BYPASS_MCU_AVR_XT` silently takes the CLASSIC pin map and misroutes every
  pin. What actually stops it is the classic arm's `F_CPU` check, and the
  fixture pins that.
- **Enum/layout assumptions** -- dropping `-fshort-enums` must trip all three
  `sizeof` guards in the AVR-XT shell.
- **Timing-budget violations** -- each part's watchdog pet-to-pet budget pinned
  to the exact millisecond by a PAIR: the floor set equal to the budget must be
  rejected, the floor one millisecond higher must compile. The budgets differ by
  part (relay: 18 ms on the ATtiny202, 14 on the PIC10F322 and PIC10F320, 16 on
  the PIC12F675), which is the whole reason a shared proof cannot substitute.
  Twelve bounds, one per part per variant.
- **Keeping target-local guards target-local** -- the PIC10F320's branch-local
  pin guards each get their own output variant, since compiling the wrong arm
  would score a deleted guard as a pass. Its duplicated threshold invariants get
  a mutation of their own: this shell includes neither `bypass_compile_checks.h`
  nor `bypass_config.h`, so its copy is compiled by no other lane in the suite.
  The first draft of that fixture broke `bypass_config.h` and compiled clean --
  the per-configuration control caught it.
- **Conflicting backend selectors / wrong output selector** -- see below.

**Finding: three configurations the firmware accepts in silence.** The last
checklist item cannot be discharged by a passing test, because the guards it
names do not exist yet -- they are BR-SRC-02 candidates. Probed rather than
assumed:

1. A modular shell compiles clean with TWO output selectors defined
   (`-DCD4053_SIMPLE -DTQ2_L2_5V_RELAY`), on both the AVR-XT and PIC lanes.
2. An output driver translation unit compiles clean under a FOREIGN selector.
3. The self-contained `bypass_mcu_pic10f320.c` is the one shell that rejects two
   output schemes -- but only by accident. Its pin map uses an
   `#if/#elif/#else` chain (first arm wins) while two later blocks test
   `OUTPUT_TQ2_RELAY` on its own, so the two disagree and the relay code refers
   to pins the chain never defined. It fails on undeclared identifiers, not on
   anything this project wrote. Two selection idioms in one file is the actual
   defect; the rejection is a side effect of the inconsistency.

Each is recorded as a fixture with its own outcome kind (`UNGUARDED`,
`INCIDENTAL`) that **fails when the missing guard lands**, with a message saying
to convert the row to `ASSERT:<the new guard's message>`. That is what makes
BR-SRC-02's prerequisite real: without it, "the guard works" and "the guard was
never reachable" look identical on the day it is added.

**Also corrected:** `test_static_assert_guards.sh` claimed "the release server
runs semantic negative compiles for AVR-XT and PIC10F322". Nothing in the tree
did -- the phrase appears nowhere else, and neither `scripts/make-release.sh`
nor any CI path compiled a mutated target shell. The scope note now points at
the file that actually does it.

**Verified.** Ten negative controls on doctored copies of `src/` via
`TARGET_GUARD_SRC` (the suite never edits the firmware to test itself): a
deleted guard, a reworded message, a reindented `#define` that stops a mutation
matching, a `<` weakened to `<=`, a dropped term in the pet-to-pet formula, a
weakened clock guard, a deleted enum-width sibling, and both hand-off paths --
adding a one-hot selector guard fails the `UNGUARDED` row, and making the
PIC10F320's incidental rejection deliberate fails the `INCIDENTAL` row. All ten
rejected; the pristine control passes. `test-attiny202-guard-mutations`: 37
checks. `test-pic-guard-mutations`: 99 checks, 3.4 s. `test-static-assert-guards`:
111 -> 115 checks, 27 -> 79 guards counted. `test-strict-tools`: 64 -> 70 checks.

## BR-SRC-04 - Proof obligations for any user-made firmware refactor

**Status:** DONE `1b79ed5`

Any firmware refactor must explicitly discharge:

- Complete MCU/output-stage configuration matrix.
- Exact selector/driver correspondence.
- Byte identity where no code-generation change is intended.
- Flash, static data, AVR stack frames, runtime stack high-water where
  available, and PIC return-stack limits.
- Tick formulas, delay-body cycles, delivered pulse widths, ISR duty, and
  watchdog pet-to-pet bounds.
- Relay emergency de-energization and complete recovery actuation.
- Fault injection across target-specific guarded state.
- Lock-step/equivalence against `bypass_pure.c`.
- Negative compile guards and diagnostics.
- MISRA/static analysis under all materially distinct configurations.
- Preservation of independent pin/output/release identity oracles.

The last obligation has a mechanical floor from BR-SRC-01: any refactor that
folds one of the registered duplications fails `test-deliberate-duplication`
with the independent opinion it destroys. Clearing that gate is necessary, not
sufficient -- the register covers structure, not the judgement the other
obligations ask for.

**Acceptance:**

- No firmware refactor is approved based on reduced line count alone.

**Result:**

The list is now in the tree, as "Proof obligations for a firmware change" in
`test/README.md`, and it names commands rather than only properties.

Two problems, one of which the other hid. The list existed nowhere but this
file, and BR-FINAL-07 deletes this file -- the same hazard BR-SRC-01 closed for
the duplication register, with the same consequence, since a review gate that
lives only in prose cannot report anything once the prose is gone. Underneath
that, the list named eleven properties and not one way to establish any of them,
so "explicitly discharge" was a judgement with nothing attached to it. That is
not hypothetical: BR-SRC-02 is a real pending set of source edits whose own
acceptance repeats two of these obligations, and its author would have had to
reconstruct the evidence for all eleven from the suite.

`test/README.md` is the right home because it already declares itself an
assurance map -- which layers exist, what property each establishes, and where a
layer's guarantee stops. The index is that map read backwards: property first,
then the commands whose evidence discharges it. It sits directly after "Which
lanes run where: the tool contract, not the part", which is what decides how
much a green run establishes at all. Eleven rows, 90 commands spelled behind
the word `make`, over 70 distinct goals.

**Two facts a reader needs, neither visible from the obligation list.** A lane
needing XC8, a PIC device pack, gpsim/libgpsim, the ATtiny_DFP or the patched
`yasimavr` venv skips by name and the run still ends `0 failures`, so a bare-host
run discharges a proper subset and says nothing about which; `STRICT_TOOLS=1`
converts each skip into a failure and `test-strict-tools` proves it does. And
three `make test` members named for an oracle check the CHECKER rather than the
image: `test-attiny202-output-oracle`, `test-attiny202-fault-oracle` and
`test-attiny202-delay-oracle` drive synthetic input so those checkers stay
guarded on a host that cannot build the image -- the image is measured by
`attiny202-sim`, `attiny202-fault` and `attiny202-delay-oracle`, which need the
fetched inputs. Both facts are already in the Makefile's own comments; neither
was reachable from a list of properties.

**One obligation has no goal at all.** Byte identity compares two trees rather
than reading one, so it is written as a procedure -- build and keep the complete
image set, edit, rebuild, compare -- with `test-avr-build-rebuild`,
`test-pic-build-rebuild` and `test-workload-rebuild` named as what makes the
comparison mean anything: an unchanged HEX is a result only where a changed one
would have been rebuilt.

**The mechanical floor.** Axis B of `test-makefile-name-contract` resolves every
goal a document names behind the word `make` against Make's own inventory, so an
obligation pointing at a goal that was renamed or retired fails rather than
sending its reader to `No rule to make target`. The harvest went from 431 documented commands to 521
on the first run -- exactly the 90 added -- so all of them resolved. Control on
a clone of the tree: renaming one row's PIC10F322 fault command to a goal that
does not exist is reported by file and line. This paragraph cannot spell that
name behind the make word, because the gate rejected the paragraph when it did
-- which is the control a second time, from a different document.

**Why every goal in the index is spelled behind the make word.** Axis B reads
only a fragment that the make word OPENS, and states that ceiling rather than
hiding it. The same doctoring in the bare-backtick style the surrounding tables
use -- `test-deliberate-duplication` to `test-deliberate-duplication-was-renamed`
-- leaves the gate green at 521. So the goal names in the rest of `test/README.md`
are outside the harvest, and widening it is what that gate deliberately declines
to do: measured on this tree, 881 distinct tokens follow the word `make` and
about a dozen are goals. The index steps around the ceiling rather than moving
it.

**What this does not do:** it does not make the judgement mechanical. Ten of the
eleven obligations now have named evidence, but only the eleventh has a
structural witness, and that witness covers structure rather than judgement.
Nothing here reports a change whose only argument is that it is shorter; the
acceptance line above remains a rule for a reviewer.

---

# K. Final integration and verification

## BR-REVIEW-01 - Resolve the completed-item review findings

**Status:** DONE `cc2ff7a`

**Review baseline:** `23eac73` on 2026-08-31. The review covered every task
marked `DONE`, its attributed commit or commits, later fixes affecting it, and
the resulting branch tip. It judged the work against this project's
correctness, robustness, reliability and simplification goals rather than only
against whether the named positive tests passed.

**Overall result:** Not yet at the project's release-quality bar. The document
consolidation and deletion of completed journals are substantial and generally
sound, but the review found one release blocker, two high-severity
release/programming defects, eight medium-severity correctness or contract
gaps, and lower-severity documentation and bookkeeping contradictions. The
critical and high findings must close before this branch is treated as a valid
prospective release implementation.

**Findings:**

- [x] **BR-RVW-01 -- CRITICAL -- future releases cannot pass tag CI
  (BR-REL-07, `24c2ded`/`7fe055b`).** The artifact commit is restricted to
  `release/<version>/`, but every new release must also add a block to
  `test/published_release_digests.txt`. The qualified source commit cannot record
  evidence that does not exist yet, and the artifact-only child may not update
  the registry.

  **Resolved:** A parent carrying the publication registry now requires its
  single child to change only `release/<version>/` plus one exact canonical
  registry append. The history gate preserves the parent bytes and file mode,
  regenerates the suffix from the committed release, and retains the old
  release-subtree-only rule for historical parents that predate the registry.
  The handoff signs checksums before generating and verifying the block. A
  synthetic future prerelease passes history and the complete immutability gate;
  omission, prefix rewrite and noncanonical-suffix controls fail.
  `test-release-history`: 92 checks, 0 failures.
  `test-published-release-immutability`: 2,719 checks, 0 failures. A focused
  `test-release-preflight` run exceeded 300 seconds before a verdict; shell
  parsing, handoff-order inspection and `git diff --check` passed.

- [x] **BR-RVW-02 -- HIGH -- a verified PIC10F320 command can program the wrong
  image (BR-FLASH-02, `23eac73`).** Producer and verifier require the expected
  basename only somewhere in the command. The `pk2cmd` arm checks `-M` and `-Y`
  but, unlike the AVR arm, never requires the expected basename as the `-F`
  argument.

  **Resolved:** `check_flash_commands()` and the independent qualification
  verifier now accept only one plain `pk2cmd` invocation and require exactly one
  `-F` operand equal to the image named by that command's manifest row. A focused
  negative fixture gives `pk2cmd` a different image while leaving the expected
  basename in a trailing shell comment; qualification rejects it at the operand
  check. `test-release-qualification`: 164 checks, 0 failures.

- [x] **BR-RVW-03 -- HIGH -- the thirteen newly attributed logs are not
  content-bound (BR-REL-02, `f401507`).** `EVIDENCE_RESULT` is appended after
  execution and carries role, name, line count and source commit
  (`scripts/make-release.sh:2444-2468`). The signed index deliberately carries
  size and terminal record but no member digest
  (`scripts/make-release.sh:2481-2489`), and the verifier rechecks those same
  properties (`scripts/verify-release-qualification.sh:514-531`). A same-size,
  same-line-count substitution passes qualification. The eventual signed Git
  tag authenticates the committed bytes but does not establish that they are
  the original output of the named operation. Bind each retained log's content
  to the qualification root or replace it with the minimum structured result
  the release claim actually needs; do not create a second conflicting digest
  authority.

  **Resolved:** Each producing operation now closes by hashing its exact log
  payload and appending one `EVIDENCE_RESULT format=2`; staging validates and
  copies that existing record rather than regenerating it. Index format 2
  commits the record through `evidence_index_sha256` and `QUALIFICATION` format
  7, so no parallel digest list was added. The independent verifier hashes the
  byte prefix itself and rejects same-size/same-line-count substitution, a false
  digest copied into both log and index, a format downgrade, and a nonterminal
  record. `test-release-qualification`: 167 checks, 0 failures.
  `test-release-provenance`: 73 checks, 0 failures.

- [x] **BR-RVW-04 -- MEDIUM -- resource records are neither closed schemas nor
  uniquely covered outside image rows (BR-RES-03, `1ad315e`).** Both parsers
  silently overwrite duplicate keys and accept unknown fields
  (`scripts/make-release.sh:1754-1759` and
  `scripts/verify-release-qualification.sh:600-605`). Exact identity coverage
  applies to images, but duplicate `RESOURCE_DATA` or `RESOURCE_RETURN_STACK`
  part/variant records can replace another record while preserving the terminal
  count. Reject duplicate and unknown fields, and require the exact reviewed
  identity set for every record kind in producer, independent verifier and
  contract fixtures.

  **Resolved:** Both release parsers now account for every token against an
  exact per-kind schema before interpreting it, rejecting malformed, duplicate,
  unknown and missing fields. Each independently constructs the complete
  reviewed image, static-RAM, Classic stack, AVR-XT frame-bound, PIC12F675 Data
  and PIC return-stack identity topology and checks it in both directions, so a
  duplicate or substituted identity cannot preserve validity through the
  terminal count. The synthetic release fixture now assigns Data space to
  PIC12F675 and the Python producer contract pins every schema and identity
  multiset. `test-release-qualification`: 173 checks, 0 failures;
  `test-release-provenance`: 77 checks, 0 failures; resource-table contract: 133
  checks, 0 failures.

- [x] **BR-RVW-05 -- MEDIUM -- reviewed ceiling parsing can disagree with
  effective Make policy (BR-RES-02, `e7c4f68`).** `parse_policy()` counts only
  decimal assignments (`test/test_resource_tables.py:173-190`). One decimal
  assignment followed by a computed reassignment therefore looks unique to the
  checker while Make consumes the later value. Count every assignment first,
  then require the sole assignment to have the reviewed constant form; add
  duplicate-constant and constant-plus-computed negative cases.

  **Resolved:** `parse_policy()` now counts every direct GNU Make assignment to
  each reviewed ceiling, regardless of operator or value form, before accepting
  the sole assignment as a decimal constant. A duplicate decimal declaration
  and a decimal declaration followed by a computed `:=` reassignment both fail
  the isolated contract. Resource-table contract: 135 checks, 0 failures.

- [x] **BR-RVW-06 -- MEDIUM -- an empty or symlinked `QUALIFICATION` suppresses
  the pre-tag disclosure (BR-STATE-02, `d4675d0`).** Development-state
  validation checks only `-f` (`scripts/release-documentation.sh:270-278`), and
  `test/test_release_preflight.sh:1186-1193` explicitly calls an empty file a
  released tree. Use the same minimum regular, nonempty, non-symlink retained
  record boundary the release verifier relies on, with empty and symlink
  negative cases.

  **Resolved:** The development-state gate now treats `QUALIFICATION` as a
  retained release record only when it is a nonempty regular file and not a
  symlink, matching the minimum boundary enforced by qualification verification.
  Its released-tree fixture now carries a nonempty record; empty and symlinked
  placeholders each retain the pre-tag disclosure requirement. Focused shell
  syntax and diff checks passed; the full preflight regression was left to the
  external validation run because it repeatedly exercises the complete release
  preflight.

- [x] **BR-RVW-07 -- MEDIUM -- the XC8 context parser does not prove data-memory
  class (BR-TEST-07, `cee6bab`/`0dada67`).**
  `test/check_pic_context_layout.sh:59-65` rejects only literal `CODE` and
  accepts any other syntactically uppercase class. Define the reviewed XC8
  data-memory class set and reject unknown and other program-memory classes;
  exercise each boundary in `test/test_xc8_helpers.sh`.

  **Resolved:** Local XC8 history and both realistic sidecar producers establish
  `BANK0` as the one reviewed `_ctx_` SRAM class for PIC10F322, PIC10F320 and
  PIC12F675 under the pinned XC8/DFP. The resolver now uses that positive
  allowlist rather than a `CODE` blacklist. Focused controls reject `CODE`,
  `CONST`, `STRCODE`, `CONFIG`, `EEDATA`, an unreviewed `BANK1` and an invented
  uppercase class. `test-xc8-helpers`: 34 checks, 0 failures.

- [x] **BR-RVW-08 -- MEDIUM -- target guard coverage does not meet its stated
  all-guards acceptance criterion (BR-SRC-03, `781cb43`).** The census checks
  only the number of `static_assert` lines
  (`test/test_static_assert_guards.sh:244-263`), while target-toolchain mutations
  exercise selected predicates (`test/test_target_guard_mutations.sh:218-249`).
  Replacing an unmutated predicate with unconditional truth preserves the count.
  Either add a load-bearing mutation for every required guard or narrow and
  justify the acceptance claim without representing a census as semantic
  coverage.

  **Resolved:** The acceptance claim now matches the implemented evidence. The
  toolchain-backed mutations prove selected high-consequence pin, clock,
  layout, threshold and timing-budget predicates, while the independent
  79-guard census detects only changed per-file declaration counts. Test and
  changelog descriptions now state explicitly that neither the census nor the
  representative mutation roster detects arbitrary weakening of an unmutated
  predicate. No fixture behavior or firmware changed.

- [x] **BR-RVW-09 -- MEDIUM -- mutable release and test inventories remain
  mandatory prose duplication (BR-AUTH-01, BR-README-01, BR-TESTDOC-01 and
  BR-STATE-01).** The authority map forbids repeated counts and inventories
  (`README.md:99-120`), while `README.md:6-11` and
  `test/README.md:327-332` restate them, and
  `test/test_release_qualification.sh:141-175` requires the copies. Remove or
  generate mutable reader-facing counts while retaining independent executable
  set and coverage oracles.

  **Resolved:** The top-level overview now leaves exact release inventories to
  the bounded contract in `release/README.md`, and its simulator summary leaves
  target/substrate membership to the test guide. The test guide no longer
  restates per-profile check totals, current evidence/soak cardinalities or a
  historical evidence/soak boundary. `test-release-qualification` no longer
  requires those prose copies, while its release-authority checks, test-layer
  coverage assertions, canonical set/cardinality fixtures and override controls
  remain unchanged. Shell syntax and `git diff --check` passed. The focused
  qualification regression exceeded 120 seconds on this host while repeatedly
  encountering the absent AVR toolchain, so it produced no verdict and was left
  to the external full-suite run.

- [x] **BR-RVW-10 -- MEDIUM -- mutable resource figures remain in development
  prose (BR-RES-01, `e7c4f68`).** Examples are current flash percentages in
  `DESIGN_DOCUMENTATION.adoc:48-52`, static/stack/free-SRAM values in
  `TODO.md:224-227`, and current PIC10F320 margins in `TODO.md:578-580`. Replace
  them with stable consequences or bind genuinely historical measurements to an
  immutable release/commit and exact toolchain.

  **Resolved:** Current flash percentages, static-data/stack/free-SRAM results
  and PIC10F320 image margins were removed from maintained design, planning,
  Makefile and simulator prose. Stable silicon capacities and reviewed ceilings
  remain where they explain a design constraint. Current measurements now come
  only from their build/resource gates and retained per-release evidence; no
  prose-synchronization check was added. `test-reference-contract`: 10 checks,
  0 failures; `test-todo-index`: 102 checks, 0 failures.

- [x] **BR-RVW-11 -- MEDIUM -- the relay safety case overstates physical
  convergence (BR-DOC-04, `8180569`).**
  `docs/relay_coil_fault_correction.md:50-55` says recovery guarantees
  logical/physical convergence, while lines 231-235 acknowledge that even an
  above-minimum pulse may fail to move real hardware. State the electrical
  firmware guarantee separately from the physical result and name the hardware
  assumptions required for the latter.

  **Resolved:** The safety case and normative design now define the guaranteed
  firmware/electrical sequence separately from conditional armature/contact
  movement. They name the fault-model, reset, wiring, pull-down, driver, flyback,
  PCB, supply, terminal voltage/current/pulse, environmental and functional-relay
  assumptions required for physical BYPASS. Test documentation and comments now
  describe only the electrical phase each substrate observes, distinguish the
  fault lane's datasheet-minimum pulse from separate nominal-width evidence, and
  state that no simulator observes relay mechanics. `test-reference-contract`:
  10 checks, 0 failures; `test-makefile-name-contract`: 48 checks, 0 failures.

- [x] **BR-RVW-12 -- LOW -- repair three live-document contradictions.**
  `docs/context_seu_detection.md:14-20` says no published release binds F2 even
  though `v0.9.11` retains explicit F2 evidence; `release/README.md:543-544`
  says the verifier checks 24-hour soak evidence even for the supported one-hour
  express mode; and `TODO.md:504-510` sends a controlled hardware result to
  `release/README.md` instead of the authority-map owner,
  `HARDWARE_VALIDATION_LOG.md`.

  **Resolved:** The F2 safety record now recognizes the explicit evidence in the
  published `v0.9.11` qualification while preserving the distinction between
  local completion, retained qualification and publication. Release reproduction
  guidance states the verifier's mode-dependent soak floors: 24 hours for
  production and one hour for express. The PIC12F675 bench task now sends its
  controlled result to `HARDWARE_VALIDATION_LOG.md`, the sole live owner, while
  retaining the generated JSON. `test-reference-contract`: 10 checks, 0
  failures; `test-todo-index`: 102 checks, 0 failures.

- [x] **BR-RVW-13 -- LOW -- enforce the prospective concise changelog policy
  (BR-CHANGELOG-01, `da1d62d`).** The policy at `CHANGELOG.md:24-32` excludes
  implementation journals and exhaustive fixture mechanics, but `[Unreleased]`
  at lines 46-279 already carries substantial examples of both. Reduce the
  current entry to user-visible behavior, safety/compatibility changes, material
  residual limitations and migration actions before the next release.

  **Resolved:** `[Unreleased]` was reduced from 288 lines and 18 long-form
  bullets to 71 lines and 10 concise bullets. It retains release-facing resource,
  provenance, programming, safety and compatibility changes; the v0.9.11 command
  erratum and pre-v0.9.12 signature boundary; material selector and guard-coverage
  limitations; and release-maintainer actions. Implementation chronology,
  fixture inventories, check counts and mutable resource figures were removed.
  `test-reference-contract`: 10 checks, 0 failures.

**Commit/status bookkeeping found by the review:**

- [x] Record BR-FLASH-02's implementation as `23eac73` instead of
  `DONE <commit>`.
- [x] Attribute parser correction `0dada67` to BR-TEST-07 as part of its
  completed implementation.
- [x] Attribute symlink hardening `7fe055b` to BR-REL-07 as part of its
  completed implementation.
- [x] Attribute branch-only document lifecycle enforcement `0705898` to
  BR-AUTH-01.
- [x] Remove BR-STATE-01's stale duplicate unchecked `Work` block.
- [x] Give BR-REL-02's deferred duplicate-phase-log work the real BR-REL-08 task
  it referenced.

**Measured branch shape:** Against `main` at the review baseline, the branch is
16,606 insertions and 17,488 deletions, net -882 lines while this 3,929-line
branch-only plan is still present. Deleting the plan under BR-FINAL-07 would put
the net near -4,811. That is a meaningful reduction in active historical prose,
but it masks substantial growth in release and test machinery; closing this
review must prefer small semantic checks over another parallel framework.

**Validation performed:**

- `test-release-history`: 86 checks, 0 failures.
- `test-published-release-immutability`: 2,719 checks, 0 failures, all 12 local
  tags compared.
- `test-release-qualification`: 163 checks, 0 failures.
- `test-release-preflight`: 230 checks, 0 failures in a focused run. A later
  combined rerun exceeded its 600-second command timeout during preflight after
  the preceding gates passed; this was a review-run limit, not a gate verdict.
- `test-resource-tables`: 46 checks, 0 failures, with 0 of 21 images available
  to measure; its contract suite passed 120 checks.
- `test-xc8-helpers`: 28 checks, 0 failures.
- `test-deliberate-duplication`: 335 checks, 0 failures.
- `git diff --check` passed and the worktree was clean before this review was
  recorded.

**Validation limits:** `avr-gcc` and the target toolchains were unavailable, so
the full `make test`, strict target aggregates, 21-image resource run and image
rebuilds were not completed. No hardware qualification was performed. Hosted
asset state and repository protection settings remain outside this air-gapped
review.

**Acceptance:**

- Every critical, high and medium finding above is closed by a focused negative
  test and the relevant aggregate.
- Low findings are corrected or explicitly declined with a reason consistent
  with the authority map.
- A synthetic future release can satisfy source-parent history, qualification,
  immutability and tag-CI contracts together.
- The resulting implementation is simpler in maintained authorities and does
  not merely exchange documentation bloat for parallel release/test machinery.

## BR-REVIEW-02 - Resolve pre-merge readiness review findings

**Status:** TODO

**Depends on:** All implementation through `7dd4840`

**Review baseline:** `7dd4840` on 2026-09-01, with a clean worktree and no
local/remote divergence. `main` and signed tag `v0.9.11` both resolve to
`760f5fd`; that commit is the merge base, and this branch is 91 commits ahead
and zero commits behind it. The review compared `main...HEAD`, inspected every
changed path by documentation, release and build/test responsibility, and
performed the focused read-only validation recorded below.

**Conclusion:** The branch's direction materially improves the project. It
removes completed journals and duplicate current facts, gives stable PIC design
material one normative home, generates release resource and programming views,
binds substantially more retained evidence, and preserves the independent
oracles that make intentional duplication valuable. It is not yet merge-ready
or ready to execute the `v0.9.12` release. Three executable defects and several
authority/lifecycle gaps must be closed in addition to the already-planned final
qualification and plan deletion.

**Required pre-merge findings:**

- [x] **BR-RVW2-01 -- HIGH -- restore hosted and local aggregate toolchain
  routing.** `TEST_GATES_LATE` now puts
  `test-attiny202-guard-mutations` and `test-pic-guard-mutations` in every
  `make test` and `make stress`. Under `STRICT_TOOLS=1`, their missing DFP/XC8
  inputs are fatal. The independent hosted `verify` and `stress` runners install
  only host/Classic-AVR tools; `needs: pic` orders jobs but does not share the
  PIC runner's filesystem. The same mismatch defeats `ci-local.sh`'s
  `--skip-pic` and `--skip-attiny202` modes after strict mode is exported.
  Route each target-toolchain mutation gate through a runner that provisions
  its inputs, or provision every aggregate that owns it. Extend the workflow and
  local-routing contract tests to compare aggregate prerequisites with each
  job's actual provisioning and to exercise both skip modes. The correction
  must preserve fail-closed release qualification without making ordinary
  host-only development require every target toolchain.

  **Resolved:** Removed both real-toolchain compile-guard mutation gates from
  the shared hosted `test`/`stress`/`test-long` inventory. The ATtiny202 gate is
  now a prerequisite of `attiny202-test`, and the once-per-PIC-job gate is a
  prerequisite of `pic10f322-test`; normal CI, local CI and both release paths
  already run those aggregates only after provisioning their corresponding
  toolchains. The workflow contract follows Make's transitive prerequisite
  graph and requires each gate to have exactly one correctly provisioned job.
  The local-routing contract rejects either gate in the hosted inventories and
  exercises PIC-only, ATtiny202-only and combined skip modes under strict mode.

- [x] **BR-RVW2-02 -- HIGH -- bind every source-checkout programming command to
  its image's exact Make goal and selector name.** The producer and verifier
  currently accept any assignment word whose name ends in `VARIANT`, and the
  renderer accepts the same relation as a substring. A command such as
  `WRONGVARIANT=cd4053_with_mute` therefore passes the check while Make ignores
  it and may program the default image. The checks also do not bind the Make
  goal to the image's MCU. Keep the independent validator separate from the
  command generator and require the exact per-MCU goal/selector pair, one
  selector, and the image's exact variant. Add negative cases for a prefixed
  selector name, a correct selector on the wrong MCU goal, a foreign selector,
  and duplicate or conflicting assignments in the producer, renderer and
  retained-manifest verifier paths.

  **Resolved:** The producer, renderer and retained-manifest verifier now each
  independently map an image MCU to its exact programming goal and selector.
  Each path parses whole command words, requires one `make` goal, exactly one
  assignment whose name ends in `VARIANT`, the expected selector spelling and
  the image's complete variant; unrelated assignment words remain available for
  inputs such as `XT_UPDI_PORT`. The generic per-image path explicitly excludes
  PIC12F675, whose guarded transaction remains its only release route. Focused
  fixtures cover all six direct-program MCU mappings and reject prefixed and
  foreign selectors, another MCU's goal, duplicate assignments and conflicting
  assignments through all three validation boundaries.

- [x] **BR-RVW2-03 -- HIGH -- order prereleases before their corresponding
  final release.** `versions()` in
  `test/test_published_release_immutability.py` parses only dot-separated
  integers; a name such as `v0.9.12-rc.1` falls through to the final fallback and
  sorts after `v0.9.12`. `image_continuity_is_declared()` exempts only the last
  sorted release, so an RC followed by its final release can make the final
  artifact-only publication impossible under the policy the gate explains.
  Implement deterministic release ordering with explicit prerelease
  precedence, reject or deliberately classify malformed release directory
  names, and add a complete synthetic RC-then-final publication fixture. The
  test must prove both ordering and the continuity-declaration handoff.

  **Resolved:** Release directories now sort by numeric core and explicit
  prerelease precedence: prereleases precede their matching final, numeric
  prerelease identifiers precede textual identifiers, and the original name is
  a deterministic tiebreak for equivalent accepted spellings. Malformed `v*`
  directory names are excluded from ordering and fail a dedicated contract
  instead of receiving the newest-release exemption. The synthetic history
  fixture now publishes an RC and then its final as separate source/artifact
  pairs. It proves that the RC may owe continuity while newest, that the final's
  source supplies the RC declaration, and that removing that declaration after
  the final appears fails specifically on the RC-to-predecessor relation.

- [x] **BR-RVW2-04 -- MEDIUM -- make the release lifecycle policy agree with
  retained history.** `README.md` and `release/README.md` say retained release
  records are never edited after a tag and bundles are preserved exactly as
  published. The changelog, release policy and retained `v0.9.0` through
  `v0.9.2` trees instead record an exceptional post-publication safety
  amendment. Distinguish immutable tag/original signed payload identity from an
  explicitly registered amendment to the current-tree copy. Make the lifecycle
  table's claim that every durable document has exactly one class true: include
  the omitted durable authorities and distinguish evidence files from shipped
  artifacts instead of assigning an entire release directory to both classes.

  **Resolved:** The signed tag now explicitly owns the immutable original
  release-tree identity, and the checksum list and signature own the payload
  bytes a recipient verifies. The development-branch copy normally matches that
  tag; the six unsigned TMUX safety-warning carriers in `v0.9.0` through
  `v0.9.2` are documented as registered current-tree amendments, not original
  published bytes. Restoration uses the tag and cannot silently substitute an
  amended copy. The lifecycle table now includes release policy, hardware
  records, changelog, open work, contributor policy and licensing, and assigns
  disjoint result-record, payload and authentication paths within each release.
  `test-reference-contract` parses that table and rejects a missing authority,
  duplicate classification or whole-release-directory overlap.

- [x] **BR-RVW2-05 -- MEDIUM -- finish the current-fact boundary.** The current
  target/image/soak topology is still restated in the Multi-MCU design prose and
  the toolchain release-identity prose despite `release/README.md` being its sole
  live human authority. Mutable, source-dependent measurements also remain in
  the simavr watchdog table, the PIC loop-cycle/current argument and the XC8
  optimization comparison without a release, commit and toolchain binding.
  Keep the stable architecture, capacities, decisions and enforcing gates; send
  changing inventories to the bounded release declaration and bind any
  historically necessary measurement to the source/toolchain that produced it.
  Extend the focused current-fact audit so these classes cannot silently return.

  **Resolved:** Numeric target/image/soak topology now stays in the bounded
  declaration in `release/README.md`; the design and toolchain documents retain
  only architecture, ownership, canonical-set enforcement and links to that
  authority. The unbound Classic-AVR simavr timing table, PIC loop-cycle/current
  estimate and XC8 optimization-size comparison were removed while their
  reviewed watchdog ceilings, clock decision, tool behavior and executable gates
  remain. The historically necessary PIC10F320 modular-fit experiment is now
  bound to source commit `0b44c0d`, XC8 V3.10 and PIC10-12Fxxx DFP V1.9.189.
  The live claim-boundary validator rejects representative numeric topology
  copies and all three removed unbound measurement forms, and requires the
  historical source/toolchain binding to survive.

- [x] **BR-RVW2-06 -- MEDIUM -- give the PIC12F675 source-checkout transaction
  one maintained semantic owner.** `TOOLCHAIN.adoc` carries most of the baseline,
  immediate-read, reservation, result, temporary-storage and ipecmd limitations
  that `release/README.md` also maintains for the exact transaction. Retain in
  the toolchain document only installation, pinning and tool-behavior facts it
  owns; link to the release-policy procedure for the operator transaction. If
  any duplicated safety statement must remain at both sites, classify it as a
  deliberate independent boundary and add the witness that prevents drift.

  **Resolved:** `release/README.md` remains the sole maintained source-checkout
  procedure. The 50-line PIC12F675 programmer block in `TOOLCHAIN.adoc` was
  reduced to installation, readback-dialect pinning and tool-behavior facts,
  followed by links to the source-checkout and downloaded-release procedures.
  Baseline ownership, immediate re-read, reservation/result, temporary-storage,
  evidence and hardware-status semantics now appear only with the operator
  transaction. No safety statement needed to remain duplicated. The finalization
  contract requires the toolchain link and rejects the transaction's concrete
  goals, evidence variables, reservation files or temporary-root selector if
  they return there; focused fixtures cover both a dropped link and reintroduced
  transaction detail. Shell syntax, the 18-check reference contract and the
  finalization validator's live-tree path pass. The complete focused preflight
  target did not reach a verdict within 240 seconds on this host and was left to
  the external full-toolchain run.

- [x] **BR-RVW2-07 -- MEDIUM -- include the live release policy in the durable
  reference gate (`4f8ebb5`).** `test/test_reference_contract.py` skips every
  path under
  `release/` to avoid rewriting immutable historical bundles, but that also
  skips the actively maintained `release/README.md` authority. Exclude only the
  per-version historical directories, scan the live policy, and add a negative
  fixture proving that a broken path or anchor there fails.

  **Resolved:** The reference contract now excludes only versioned historical
  release trees and scans `release/README.md` as a durable live document. Its
  self-test pins both sides of that boundary and rejects a missing relative link
  from the live policy. The focused gate passes 13 checks across 230 files and
  15 documents; the added document and three negative checks account for the
  change from the review baseline.

- [x] **BR-RVW2-08 -- LOW -- close direct PIC harness dependency gaps
  (`328a8e7`).** The
  direct PIC10F322 and PIC12F675 fault/lock-step binary targets derive `CTX_ADDR`
  from generated assembly/symbol sidecars, but the sidecars and
  `test/check_pic_context_layout.sh` are not prerequisites. The authoritative
  phony lanes remove and rebuild the binaries, so current aggregate qualification
  avoids the stale case; direct file-target use does not. Add the actual image,
  sidecar and helper dependencies with a rebuild regression, or explicitly
  remove/decline unsupported direct build-only targets.

  **Resolved:** All four direct binary rules now name the selected image,
  assembly, symbol file and context-layout checker they consume. Selected
  artifacts route through the existing all-variant shipping and simulator-image
  producers, preserving matrix validation instead of adding a second build
  path. The host-only fake-tool regression deletes those generated inputs under
  an existing binary and requires the direct target to restore them and
  recompile; `test-pic-build-rebuild` passes 42 checks with no target toolchain.

- [x] **BR-RVW2-09 -- LOW -- reconcile plan bookkeeping before deleting the
  plan.** BR-STATE-01, BR-REL-02 and BR-REL-07 retain unchecked work inside DONE
  tasks, even where their result text says the work was deferred or moved.
  BR-REL-08 has no commit in its DONE status, contrary to the status vocabulary.
  Convert each to an explicit completed, declined or durably transferred
  disposition. BR-FINAL-06 is correctly commit-bound to `cc2ff7a`; either keep
  that endpoint explicit or refresh the final metric after later corrective
  commits rather than presenting it as an unqualified tip measurement.

  **Resolved:** BR-STATE-01 now records topology generation as declined rather
  than open; BR-REL-02 records its phase-log decision as transferred to the
  completed BR-REL-08; BR-REL-07 points its reproduction procedure to the
  durable tag-local instructions in `release/README.md`; and BR-REL-08 names its
  implementation commit, `df344a7`. BR-FINAL-06 remains explicitly scoped to
  endpoint `cc2ff7a`; it is a fixed comparison, not an unqualified tip metric.

- [x] **BR-RVW2-10 -- HIGH -- reject semantic overrides in published
  source-checkout programming commands.** Follow-up review at `9d47651` found
  that BR-RVW2-02 deliberately ignored assignments not ending in `VARIANT`.
  That let a syntactically valid command retain its expected goal and selector
  while appending `PIC10F322_PROG_HEX=foreign.hex`,
  `PIC10F322_PROG_CMD=:` or `MAKEFLAGS=-n`. GNU Make consumes those assignments,
  so the command could write another image, suppress the programmer invocation
  or change recipe semantics while all three release validators accepted it.

  **Resolved:** The producer, renderer and retained-manifest verifier now reject
  every assignment except the exact variant selector, plus the ATtiny202 route's
  one required `XT_UPDI_PORT=/dev/...` input. The port value is restricted to a
  shell-safe path lexically confined beneath `/dev/`; duplicates, omission,
  traversal and mis-cased names fail even under inherited `nocasematch`. Focused
  negatives cover image-path, programmer-command and Make-semantics overrides at
  all three validation boundaries. `test-release-qualification` passes 217
  checks; shell syntax and `git diff --check` pass.

- [x] **BR-RVW2-11 -- HIGH -- make workflow parsing fail closed.** Follow-up
  review found two malformed inputs that the local workflow contract accepted.
  PyYAML's default loader silently retained only the last duplicate mapping key,
  so a duplicate job, `run`, `uses` or permission declaration disappeared before
  structural validation. The shell tokenizer likewise caught an unmatched quote
  and continued, erasing that command from every command inventory.

  **Resolved:** Workflow YAML now uses a dedicated safe loader that rejects a
  repeated key at any mapping depth and explicitly refuses merge keys rather
  than assigning them ambiguous duplicate semantics. Its YAML 1.2 Boolean
  resolver also makes quoted and unquoted `on` the same key. Jobs and steps have
  one execution shape (`uses` or `steps`; `uses` or `run`), executable jobs are
  constrained to Ubuntu, and workflow/job run defaults are refused so they
  cannot silently replace the Bash substrate. Every `run:` body must be a string
  using Bash and passes `bash -n` in memory with workflow/job/step context.
  In-memory controls exercise duplicate and merge keys, ambiguous execution
  shapes, an unmatched quote and an unterminated compound command.
  `test-workflow-syntax` passes 668 checks; shell syntax and `git diff --check`
  pass.

- [ ] **BR-RVW2-12 -- HIGH -- reject inherited source-checkout programmer
  overrides.** The source-command validators now reject semantic assignments in
  the published command itself, but the PIC10F32x programming recipes still
  accept environment-origin `PIC10F32x_PART`, `PROG`, `PROG_TOOL` and
  `PROG_CMD` through `?=`. Thus an operator can paste the exact validated
  source-checkout command while an inherited whole-command override selects
  another writer or image. Preserve an explicit, reviewed command-line override
  path if it remains supported, but make the published command fail before
  hardware access under direct environment, `-e`, or inherited Make-flag
  semantic overrides. Add fake-programmer controls for both PIC10F32x goals.

**Measured branch shape:** At the review baseline, `main...7dd4840` changes 92
paths with 19,963 insertions and 18,636 deletions, including all 5,172 lines of
this branch-only plan. Excluding the plan gives 91 paths, 14,791 insertions and
18,636 deletions, net -3,845 lines. The maintained documentation-facing set
(durable root documents, `docs/`, `test/README.md` and `release/README.md`) is
2,555 insertions and 14,728 deletions, net -12,173. This is a material reduction
in active prose and mutable authority, but it is accompanied by substantial
release/test machinery growth. That growth is justified only where it supplies
an independent executable witness; the three high findings demonstrate why the
new machinery still requires the full final audit.

**Focused validation performed:**

- `git diff --check main...HEAD` passed; the worktree remained clean.
- Release history: 92 checks, 0 failures.
- Release images: 222 checks, 0 failures.
- Release qualification: 335 checks, 0 failures.
- Release provenance: 77 checks, 0 failures.
- Published-release immutability: 2,764 checks, 0 failures.
- Release preflight: 238 checks and 98 Make queries, 0 failures.
- Workflow syntax/structure: 470 checks, 0 failures through the installed YAML
  adapter.
- Reference contract: 10 checks across 227 files and 14 documents, 0 failures.
- Shell syntax for the changed shell surface and Python syntax for the changed
  Python surface passed.

These green results do not contradict the findings: the missing cases are
precisely transitive hosted-job provisioning, prefixed/wrong-goal source
commands, RC-followed-by-final ordering, and a live document excluded from the
reference scan.

**Validation limits:** The complete pinned target-toolchain qualification,
image/resource comparison, long suite and soak run remain BR-FINAL-05 work.
This host did not provide every target compiler/device pack, Asciidoctor or the
tag-signing public key, and the air-gapped review could not inspect hosted CI,
repository settings or published assets. Controlled hardware qualification
remains intentionally a `1.x.y` requirement rather than a `v0.9.12` blocker.

**Acceptance:**

- Every high and medium finding is closed by a focused negative test and the
  aggregate or release verifier that owns the invariant.
- Each low finding is corrected or explicitly declined with a durable reason.
- The ordinary hosted jobs, fully provisioned target jobs and documented local
  skip modes agree about which toolchains each aggregate requires.
- A synthetic source command cannot select the wrong image while passing, and a
  synthetic prerelease can be followed by its final release under the declared
  history/publication policy.
- BR-FINAL-04 and BR-FINAL-05 rerun after the corrective commits, BR-SRC-02 is
  completed or explicitly deferred, and source finalization can then update the
  `v0.9.12` release state and delete this plan under BR-FINAL-07.

## BR-FINAL-01 - Run a complete current-reference audit

**Status:** DONE `880d28b`

**Depends on:** All document deletion/consolidation tasks

**Seven of the eight searches came back clean.** Each is recorded below with
what keeps it clean, because a search result is worth only what the next commit
cannot quietly undo:

- **Deleted document paths.** Nothing in live text names one. The twelve files
  this branch deleted are mentioned only in `CHANGELOG.md`, which records what
  a past release said, and in this plan, which BR-FINAL-07 deletes. The
  `docs/notes.md`, `docs/field_notes.md` and `docs/programming.md` a path scan
  reports are synthetic fixtures written into temporary trees by the preflight
  negative controls, not references.
- **Retired target, variable and image names.** Every live occurrence is one of
  three intentional kinds: a negative control that exists to REJECT the name
  (`tmux4053` in `test_release_images.sh` and the matrix harnesses,
  `verify-rename-identity` in `test_release_provenance.sh`), a published digest
  of a historical release, or a revisit condition that states what the retired
  form was and why the current one replaced it.
- **Current resource measurements outside release evidence.**
  `DESIGN_DOCUMENTATION.adoc`'s table carries device capacities and the
  variable that owns each ceiling, not measurements.
  `docs/relay_coil_fault_correction.md`'s cost table says in its own next
  sentence that its figures are historical deltas and not current occupancy,
  and `docs/context_seu_detection.md` ties each figure to the release that
  measured it. `make test-resource-tables` measures the images themselves.
- **Duplicated current-release declarations.** Mechanically impossible rather
  than merely absent: `release_validate_development_state` requires exactly one
  bounded declaration in exactly one designated document. `README.md`'s
  authority map points at that declaration instead of restating it.
- **Multiple current programming procedures.** `FLASHING.md` is the only live
  document carrying programmer command lines; `README.md` points to it, and
  the per-release guide is generated.
- **Markdown/AsciiDoc links and named anchors.** All resolve, after the one
  repair below.
- **Immutable release directories.** Excluded from every rewrite and from the
  new gate, for the reason BR-REL-07 gives: their links were correct against
  the tree of their own tag, and `test-published-release-immutability` is what
  holds them.

**The finding: citations that outlived their document.**
`docs/pic10f320_merge_plan.md` was 3,432 lines and was deleted by BR-PIC-03
(`b8b4af1`) once its normative content reached `DESIGN_DOCUMENTATION.adoc`. It
left **43 comment lines carrying 45 section citations** across `Makefile` (22),
`scripts/make-release.sh` (6), `scripts/verify-release-images.sh` (2),
`.github/workflows/` (3), `scripts/ci-local.sh` (1) and `test/` (9). Several
were bare `§N` naming no document at all, and one of those turned out to cite
`docs/pic12f675_feasibility.md` rather than the merge plan. That document had
kept its own numbering stable "so that the cross-references to these numbers
elsewhere in the repository stay valid" -- which is the tell: a reference that
needs a whole document frozen to stay true is a reference that will outlive it.

Two more of the same shape, found by the line-number half of the same search:
`test/avr/test_sim.c` cited `bypass_mcu_avr_classic.c lines 180-182` for a
watchdog sequence that now lives in `hw_wdt_arm()`, and
`test/test_makefile_name_contract.py` cited `ci-local.sh:368` for a
`print-%` query that had moved 21 lines. Both now name the construct instead of
the line. `CHANGELOG.md` carried one live Markdown link to a deleted document,
which rendered dead on every page view; it is now a code span, matching the
sibling document already written that way in the same sentence.

**This item's own enumeration was wrong, in three particulars.** It reported 48
citations; the count is 43 lines and 45 citations. It attributed 24 to the
`Makefile`, which carries 22. And it named `test/run_mutation_tests.sh` and
`formal/test_model_check.c`, neither of which has ever carried a `§`. The
counts here were taken from the tree at BR-COMMENT-01's commit and at HEAD, and
agree.

**What each repair kept.** In every one of the 43 comment sites the sentence
already carried its content and the citation was an appended pointer, so the
repair is the pointer's removal and nothing else. Two needed a clause restated
rather than dropped -- the naming rule that "supersedes merge-plan §15 D1" now
supersedes "the earlier decision that kept the bare `pic-` prefix", and the
CI comment that closed "§8 items 1 and 2" now names the OSCCAL and bandgap
preservation evidence those items were. No executable line changed.

**One repair this required.** Nothing in the tree could report the class. A
dangling comment citation cannot fail to compile, and the branch-only-document
reference gate in `scripts/release-documentation.sh` says so of itself: its
reference half "necessarily stays name-pattern based", so a reference to a
document named outside the two branch families "dangles unseen once that
document is gone". `test/test_reference_contract.py` (`make
test-reference-contract`, 10 checks) closes that for durable documents with two
lexical rules and a negative control for each:

- A section citation must name an external document on the same line, or repeat
  a number the same file has already attributed to one. A section number is
  stable only where its publisher owns the numbering; inside this repository it
  is a line count in disguise, and repository documents are cited by name and
  anchor instead -- which the second rule then checks.
- Every relative link and fragment anchor in a durable `.md`/`.adoc` must
  resolve.

`CHANGELOG.md` is exempt from the first rule only: an entry recording what a
since-deleted document said is a true statement about the past, and each such
entry names the document, so a reader sees at once what is cited. Its links are
still checked. Branch-only working documents are exempt from both, by the same
banner recognizer the release gate uses.

**Work:**

- [x] Search all current tracked text for deleted document paths.
- [x] Search for stale section-number and line-number references.
- [x] Search for retired target/variable/image names outside intentional
  historical contexts.
- [x] Search for current resource measurements outside release evidence.
- [x] Search for duplicated current-release declarations.
- [x] Search for multiple current programming procedures.
- [x] Check all Markdown/AsciiDoc links and named anchors.
- [x] Exclude immutable historical release directories from current-policy
  rewrites while still checking their links under tag-local rules where
  appropriate.

**Acceptance:**

- No dangling current references remain: 43 section citations, 2 line-number
  citations and 1 dead link repaired, and `make test-reference-contract` fails
  on the next one.
- Historical prose is clearly historical and not used as current authority.

**What this does not do:**

- It does not gate the word "section". `HARDWARE_VALIDATION_LOG.md`'s sections
  1 and 2 and `scripts/make-release.sh`'s numbered phases are cited that way
  and resolve; the glyph is what became shorthand for a document that is gone.
- It does not gate line-number citations. Three existed, two were stale, and
  the two false positives a lexical rule would produce are simulated compiler
  diagnostics in fixture strings -- the class is too small to justify a rule
  that has to be taught the difference. It stays a reading of the diff.

## BR-FINAL-02 - Verify safety and claim boundaries

**Status:** DONE `de29c39`

**Work:**

- [x] Confirm no part is described as hardware-qualified without a controlled
  record.
- [x] Confirm field-use reports remain distinct from controlled qualification.
- [x] Confirm simulator modeled-pin checks are not described as physical output
  evidence.
- [x] Confirm PIC12F675 remains not-a-raw-write target.
- [x] Confirm helper status remains published, software-tested, and not
  hardware-qualified.
- [x] Confirm PIC10F320's inlining seam and omitted general latch check remain
  explicit.
- [x] Confirm release integrity, reproducibility, qualification, and hardware
  validation are described as separate claims.

**Audit baseline:** `bbeb96e` against the branch point `13be50a` -- 64
non-merge commits, 207 files, 32,077 insertions and 18,512 deletions,
including ten live design documents deleted outright, 12,657 lines between
them. A bound is the part of a sentence a consolidation drops most easily:
what survives still reads correctly and asserts more. So each of the seven
boundaries below was traced from the branch point to the tip, and then tested
rather than read -- deleted from a scratch clone to see whether anything
failed.

**All seven hold at the tip. Nothing was weakened.** Every hedge that lived in
a deleted document arrived somewhere live: PIC10F320's latch omission and
inlining seam in `DESIGN_DOCUMENTATION.adoc:1958-1984`, the PIC12F675
preservation gap in `README.md:22`, the coil-mechanics limit in
`docs/relay_coil_fault_correction.md:225-235`. The one hedge in the deleted
set with no live counterpart is
`docs/non-blocking_output_schemes_feasibility.md:1052` -- "withholding the pet
is a necessary software bound and not a proven hardware-safe bound" -- and it
bounds a scheme the firmware does not implement, so no shipped claim rests on
it.

**But three of the seven were enforced by nothing.** The confirmations divide
sharply once each is tested instead of read:

| boundary | enforced at the branch point by | verdict |
|---|---|---|
| No part hardware-qualified without a controlled record | `release_validate_hardware_claims` -- sentinel, record contract, idiom ban, negative controls in `test_release_preflight.sh` | held, in `HARDWARE_VALIDATION_LOG.md` only |
| Field use distinct from controlled qualification | same validator's structure and vocabulary properties | held and enforced |
| Simulator lanes are modeled-pin, not physical | `test_release_qualification.sh:2151-2165`, both directions, over the rendered manifest | held and enforced |
| PIC12F675 is not a raw write target | `_release_pic12f675_raw_writer_scan` plus the heading requirement, controls at `test_release_preflight.sh:2201-2378` | held and enforced |
| Helper is published, software-tested, not hardware-qualified | the exact sentence required of `README.md`, `FLASHING.md` and `release/README.md` | held and enforced |
| PIC10F320's inlining seam and omitted general latch check | nothing | held, **unenforced** |
| Integrity, reproducibility, qualification and hardware validation are separate claims | nothing | held, **unenforced** |

**The measurements.** Each doctoring below was applied to a `git clone` of
`bbeb96e` in scratch, and the gates that read the doctored file were run
against it:

- Deleting the whole **"One recorded omission"** paragraph from
  `DESIGN_DOCUMENTATION.adoc` *and* its restatement in the "what this package
  does not establish" list -- so the tree no longer says PIC10F320 omits the
  general output-latch match -- left `test-release-qualification` at 173
  checks, 0 failures, `test-reference-contract` at 10/0,
  `test-resource-tables` at 46/0, `test-pinout-alignment` at 31/0 and the
  hardware-claims contract passing. Identical counts to the undoctored clone.
- Rewriting `release/README.md` so the historical TMUX images -- the ones
  under the fail-safe-polarity safety warning -- are "retained as fully
  qualified, hardware-validated firmware", and so reproduction attests the
  binaries are qualified rather than "exactly what the tested source compiles
  to", left `test-release-qualification` at 173/0, `test-reference-contract`
  at 10/0 and the hardware-claims contract passing.
- Replacing `README.md`'s **"No part has completed controlled hardware
  qualification"** with "the release pipeline qualifies every image before
  publication" left those same three green at the same counts. The log's
  sentinel was pinned; the sentence a reader actually arrives at was not, and
  the two could contradict each other with nothing to notice.

That last one is the sharpest. This project's single most consequential claim
is that no part has been qualified on a bench, and the root README could be
made to say the opposite while `HARDWARE_VALIDATION_LOG.md` still carried the
denial.

**What was added.** `release_validate_claim_boundaries()` in
`scripts/release-documentation.sh`, beside the hardware-claims contract it
extends, called on the live tree from `test-release-preflight` and from
`make-release.sh` preflight. Two directions, because a bound can be lost by
deletion or overwritten by a stronger claim:

- **Presence.** Six sentences required verbatim of the documents that own
  them, matched against flowed text so rewrapping stays editorial: the root
  README's qualification denial; PIC10F320's latch omission and its
  restatement; the seam-is-a-seam limit that keeps a behavioural assurance
  argument from being read as byte identity; what reproducing an image proves;
  and what retaining an unsafe image means.
- **Absence.** No durable document may attribute controlled qualification or
  hardware validation *to* the firmware, an image, a part or a release while
  the sentinel says no such record exists.

**Two design decisions worth stating.** The ban is **attributive only** --
adjective plus noun, "hardware-validated firmware" and its family -- and that
is a stated ceiling, not an oversight. A predicate can be negated, and every
true sentence this project writes about qualification *is* the negation ("it
is not hardware-qualified", "has **not** completed controlled hardware
qualification"), so banning the predicate in both polarities would ban the
truth along with the claim. The adjective-plus-noun form has no negated
spelling, which is what makes it decidable. Prose can still overclaim in words
this does not enumerate.

The ban is also **conditional on the sentinel**, so it lifts by itself. When a
part does complete controlled qualification the sentinel goes, and calling
that part's image hardware-qualified becomes true and sayable in the same
commit that records the run. A ban that outlived its premise would leave the
project unable to state its own first qualification result.

**Controls**, in the idiom the file already uses for a documentation contract
-- "a checker for a documentation contract is exactly the kind of code that
can pass vacuously and never be noticed". Fifteen checks -- the shipped
documents accepted, twelve spoiled-fixture cases, an arity guard and the live
tree: each of the six bounded claims dropped and named in the diagnostic; the
banned form in a document that owns no required sentence; the banned form
split across a line break, which a line-oriented scan reads as two innocent
lines and which is why the scan flows first; the same wording in a code span
accepted, because naming it in order to retire it is what this file,
`CHANGELOG.md` and the branch working documents all have to do; a root-level
branch-only document pruned; the claim accepted once the sentinel is gone; a
missing claim-owning document; and a missing argument returning 2.

**What this does not do.** It pins six sentences and one form family. It does
not decide whether a *new* claim is supported by retained evidence -- that
judgement stays with the writer -- and it cannot see a document that
overclaims in wording it does not enumerate. What it removes is the specific
failure this branch kept producing: a boundary that is correct today,
load-bearing, and silently deletable.

**One finding left to its owner.** At the time of this audit
`docs/relay_coil_fault_correction.md:50-55` still called logical/physical
convergence "guaranteed by the recovery" while `:231-235` said whether a relay
moves is a bench question. That was BR-RVW-11, open and assigned; it was a
contradiction inside one document rather than a lost bound, and pinning either
half here would have collided with the repair. BR-RVW-11 has since closed it
in `cb30da7`, which separates the guaranteed firmware and electrical sequence
from the conditional armature outcome.

**Acceptance:**

- Simplification does not strengthen any claim beyond retained evidence.
  *Confirmed for all seven boundaries, and for three of them the confirmation
  is now mechanical rather than a reading.*

## BR-FINAL-03 - Verify independent oracles were not centralized away

**Status:** DONE `0dc5231`

**Audit baseline:** `227d824` against the branch point `13be50a` -- 55 non-merge
commits, 207 files, 31,184 insertions and 18,514 deletions.

**No gate was retired.** The set of goals the Makefile defines at the branch
point is a strict subset of the set at the tip: none was removed and eight were
added (`test-analysis-matrix`, `test-attiny202-guard-mutations`,
`test-deliberate-duplication`, `test-pic-guard-mutations`,
`test-pic-toolchain-assert`, `test-published-release-immutability`,
`test-reference-contract`, `test-xc8-helpers`). Two files left `test/` and
`scripts/`, and seven commits are net-negative across the Makefile, the scripts,
the tests and the workflows. Those, the ten deleted documents, and the
consolidation commits named in the bullets below are the corpus this item had to
classify. Each is settled by evidence read at the tip rather than by the commit
message that claimed it.

**Every removal was redundant authority, and the evidence for each:**

- **`test/test_fault_wdt_note_contract.sh`** (`cee6bab`) was five lines ending
  in `exec python3 "$ROOT/test/test_fault_wdt_note_contract.py"`. The Python
  gate survives and still owns `test-fault-wdt-note-contract`. Redundant
  indirection, never an opinion.

- **`scripts/verify-rename-identity.sh`** (`893d647`, the largest single
  removal at 972 net lines) was a one-shot that named its own successor and its
  own retirement condition in its header: "the standing form of this check is
  per-release, and already exists (`test/pic10f320/expected_images.sha256`,
  `make test-release-images`)" and "when that table stops naming the current
  release, this check is already inert; delete it then". The signed v0.9.8
  report and mapping remain published under `release/v0.9.8/`. The retirement
  also added an opinion rather than only removing one:
  `test_release_provenance.sh:473` now fails if active release production still
  carries retired rename-identity state.

- **Four line-oriented workflow checks** (`7aab253`) left
  `test_release_history.sh` and `test_release_provenance.sh`. Every fact they
  asserted is asserted at the tip, exactly once, in `test_workflow_syntax.sh`:
  `fetch-depth`, the `RELEASE_OBJECT` routing, the binding of qualification to
  tag history, the remote tag recheck, the twice-verified detached signature,
  and the ordering dominance. Two greps of one file with one method are one
  opinion spelled twice, not two oracles. What replaced them is stronger: it
  tokenizes the publication shell, pins the exact command inventory, and
  requires publication to be the very next command after the second inventory
  verification rather than merely a larger line number.

- **Four resource-figure restatements** (`e7c4f68`, 568 lines out of the
  checker) are the one case where independence measurably increased. The
  removed check compared five hand-maintained transcriptions with each other,
  three of which were already several changes stale when it was written. What
  replaced it measures the images the tree has actually built -- all 21 of them
  under `--require-all-images` -- against ceilings parsed from the Makefile, and
  cross-checks those ceilings against datasheet capacities the test itself owns.
  Documentation stopped being an input to the resource oracle.

- **Duplicate CI execution** (`b86a5a7`, `b9cbd36`, `bc5f11d`) removed repeated
  runs rather than opinions, and the arithmetic is pinned rather than asserted
  in prose. `test_workflow_syntax.sh` requires exactly one direct
  `test-mutation` invocation per hosted event and no other mutation-bearing job;
  `test_workload_rebuild.sh` requires `test-long` to be the stress inventory
  plus exactly one mutation gate, requires stress to keep the mutation-driver
  sandbox regression, and walks Make's own prerequisite graph to prove no target
  other than `test-long` reaches full mutation. The resource policy pins stayed
  per-surface: `16`, `32` and `48` are stated once each in `ci.yml`,
  `ci-local.sh`, `release.yml` and `make-release.sh`, and the Makefile keeps its
  own `?=` production defaults. Five independent statements, not one.

- **Declaration consolidation in Make** (`d3ea121`, `4fa470b`, `746ddcf`) moved
  where facts are written without moving who decides them. The tests kept
  literal test-owned canonical sets -- `TM_CANONICAL_VARIANTS` in
  `test_target_matrix.sh` carries that reason on the line above it -- and gained
  literal fake-compiler argument contracts for every producer.
  `CLASSIC_VARIANTS_SUPPORTED`, `XT_VARIANTS_SUPPORTED` and
  `PIC10F320_VARIANTS_SUPPORTED` remain three separate declarations that can
  still diverge; the PIC10F322 and PIC12F675 target sets alias the classic one
  deliberately, because those parts are classic-family.

- **Ten deleted documents** carried their evidence with them. The hardest case
  is `docs/pic10f320_validation.md`, a 570-line validation record: its
  measurement date (2026-06-26), its pinned free-tier XC8 and device pack, its
  356/386/381-word builds and the 47-word and 12-word prices of the two rejected
  reductions are in `DESIGN_DOCUMENTATION.adoc` verbatim, and each of its
  historical one-shot results -- the two return-stack gates, the rebuild-trigger
  regression, byte identity, mutation topology -- has a live standing gate that
  re-derives it on every run instead of a paragraph recording that it once
  passed.

**The finding: the release-identity pin is literal only by convention.**

The release identity is the strongest independent oracle on this branch and the
one this item names by hand. `RELEASE_IMAGES` is composed from `FW_BASE`, the
per-part MCU tags and the supported-variant sets, every one of which a command
line or an inherited environment can move. `RELEASE_IDENTITY_IMAGES` is the
`override` pin built from literal words that it is checked against, and Make
refuses at parse time if the two sets differ (`Makefile:8082`).
`test_release_images.sh` pins the count at a literal 21 and the soak set at 18,
requires the two sets to be equal in both directions, and re-reads every pinned
name under a command-line and an environment override to prove no channel
reaches it.

Nothing checked the property all of that rests on. The Makefile states it in
prose -- "a pin computed from `FW_BASE` would agree with the very thing it
exists to check ... they are both literals, so they cannot disagree at run
time" -- and no gate could tell a literal pin from a derived one. Rewriting
`RELEASE_IDENTITY_PARTS` to read the per-part tag variables is a plausible
tidying edit, it is not an override, and it survives every check listed above.

Measured rather than argued. On a doctored copy of the tree with
`RELEASE_IDENTITY_PINNED`, `RELEASE_IDENTITY_PARTS` and
`RELEASE_IDENTITY_SOAK_PARTS` reading `$(PIC12F675_TAG)` -- a `?=` variable that
an exported environment value wins -- exporting `PIC12F675_TAG=pic12f629` takes
the tree from reporting `PIC12F675_TAG=pic12f629 RELEASE_IMAGES` drift to
reporting only `RELEASE_SOAK_NAMES`. The field-by-field comparison and the
21-image comparison both fall silent, and three of the pinned image names have
been renamed inside the pin itself. Every override-channel check still passes,
because those hijack the pin's own name rather than the variable it now reads.
The one residual is an accident of asymmetry rather than a defense:
`RELEASE_SOAK_NAMES` is literal on the live side too, so it did not move with
the pin.

**The repair: a ninth row in the register that already exists for this.**

`test-deliberate-duplication` is the gate for exactly this defect class -- "fold
a pair into one shared definition and the survivor still agrees with itself,
every existing test still passes, and half the evidence is gone". The new row,
`release-identity-pin-is-literal`, reads the `override` definitions of the six
pinned names out of the Makefile and requires each to reference nothing outside
its own closure: the four reviewed lists may reference nothing at all, and the
two composed names may reference only the other pins and `foreach`'s own loop
variables. It also holds the other half of the pair, requiring
`RELEASE_IDENTITY_SELECTED` to keep reading each pinned name's live value
through `$($(n))` -- two literal tables cannot disagree either, and a pin
compared against itself polices nothing.

That no *channel* can move the pin stays where it is, in
`test_release_images.sh`. This row is the other way to lose it: an edit, in the
file itself, that leaves all of those passing.

**Verification:** the register goes from 335 checks over 8 duplications to 350
over 9, still lexical and still needing no toolchain. Five negative controls
against doctored trees via `DUPLICATION_ROOT`, each rejected with the intended
message: the parts list composed from the build's tag variables, the image names
taking `$(FW_BASE)`, the pinned field table reading a variable, a pin that lost
its `override`, and the selected side made literal so the comparison compares
the pin with itself. The pristine copy passes.

**Work:**

- [x] Review every removed duplicate and classify it as redundant authority or
  independent oracle.
- [x] Confirm release identity still has an independent literal pin.
- [x] Confirm expected pin/output facts are not generated from firmware maps.
- [x] Confirm supported sets can legitimately diverge by target.
- [x] Confirm both PIC stack witnesses remain where applicable.
- [x] Confirm formal and simulation substrates remain distinct.
- [x] Confirm build constants and firmware guards can still disagree and fail.

`make test-deliberate-duplication` (BR-SRC-01) decides six of these mechanically
on every run, one more than when this item was written: the pin/output facts the
PIC harnesses expect are literal rather than taken from the firmware map, the
supported sets diverge by part because each part states its own pin ordinals and
watchdog terms, both PIC stack witnesses remain and still read different
artifacts, the formal and simulation substrates remain distinct subjects under
distinct targets, no file in `src/` supplies the clock its guards check, and --
as of this item -- the release-identity pin is still spelled in literals. The
classification of each removed duplicate remains a reading of the diff, which is
what the record above is.

**What this does not do:** it does not check that either half of any pair is
*correct*, which is what the formal, simulation, oracle and hardware layers are
for; and it does not gate the classification itself. A future deduplication is
still a judgement, and the register only fails the nine folds someone has
already thought about.

**Acceptance:**

- No common-mode failure was introduced under the label of deduplication.

## BR-FINAL-04 - Focused verification after each chunk

**Status:** TODO

**Depends on:** BR-REVIEW-02 corrective implementation, plus each earlier
implementation chunk whose focused result must be reconciled

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

**Depends on:** All implementation tasks intended for the release, including
BR-REVIEW-02

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

**Status:** DONE `bc1fe73`

**Work:**

- [x] Record before/after tracked file count.
- [x] Record before/after lines by docs, tests, scripts, Makefile, and release
  machinery.
- [x] Record before/after normal CI commands and estimated duplicated runtime.
- [x] Record the number of mutable current-fact copies removed.
- [x] Record retained independent oracles and any assurance coverage added.
- [x] Do not use line reduction as the sole success criterion.

**Result:** Measured from the initial review baseline `a865148` to the clean
pre-measurement tip `cc2ff7a`. Paths and blobs were read directly with `git
ls-tree` and `git cat-file`; no historical tree was checked out. A line is one
LF byte, matching `wc -l`. Every blob in the scopes below was text by the
NUL-byte test, including retained HEX, signature and evidence files.
This fixed endpoint deliberately excludes later corrective commits and is not
presented as a measurement of the eventual branch tip.

| Exact path scope | Files, before -> after | Lines, before -> after | Line delta |
|---|---:|---:|---:|
| All tracked paths | 684 -> 808 | -- | -- |
| `docs/` | 12 -> 2 | 13,391 -> 640 | -12,751 |
| `test/` | 153 -> 162 | 58,163 -> 64,716 | +6,553 |
| `scripts/` | 20 -> 20 | 9,204 -> 11,204 | +2,000 |
| `Makefile` | 1 -> 1 | 8,612 -> 8,529 | -83 |
| `release/` | 455 -> 579 | 43,279 -> 56,115 | +12,836 |

The file-count increase is entirely retained release history: outside
`release/`, the tracked count is 229 at both endpoints. `v0.9.10` and
`v0.9.11` each added 62 files and 6,418 lines; together they account exactly
for the `release/` delta. That is immutable product/evidence growth brought in
by baseline reconciliation, not mutable release-machinery growth. Excluding
`release/`, the four maintained scopes in the table lose 4,281 lines. The ten
durable root documents, measured separately so they do not overlap those
scopes, grow from 8,106 to 8,976 lines as stable design and policy replace the
deleted records. This branch-only plan was 4,983 lines at the endpoint and is
excluded; BR-FINAL-07 must delete it before that reduction can be credited.

Normal hosted CI retains five logical jobs and the same six PR or seven
non-PR matrix-expanded jobs. The orchestration delta is:

| Hosted-CI measure | Before | After | Delta |
|---|---:|---:|---:|
| YAML `make` command sites, including read-only queries | 19 | 15 | -4 |
| Non-PR `make` processes, including matrix expansion and queries | 23 | 19 | -4 |
| Non-PR build/test `make` processes, excluding queries | 19 | 17 | -2 |
| Mutation-bearing aggregate paths | 2 | 1 | -1 |

The only material duplicated execution removed is the stress job's partial
second mutation sweep: non-PR CI goes from 137 fully provisioned mutant checks
plus 62 host-runnable repeats to the 137 authoritative checks, removing 62 of
199 dispatches (31.2%) and all duplicate mutation dispatches. No wall-clock
claim follows because mutant costs differ and run in parallel. The three
ATtiny202 simulation/fault/lock-step lanes still execute three times; routing
them through one aggregate removes two workflow call sites and two repeated
Make queries, not validation runtime. Named profiles likewise remove maintained
argument bundles while retaining all 13 substantive fixture paths.

Mutable-authority reductions use different units and are deliberately not
summed:

| Class | Measured reduction |
|---|---|
| Current resource prose | Five live transcription groups -> zero, plus seven later current-figure sites removed from four files |
| Current-release declaration | Four bounded document copies -> one; three version-bearing prose edits removed per release |
| Programming guidance | Two duplicate route-level procedures removed; distinct downloaded-release, generated per-release and source-checkout routes remain |
| Test inventories/counts | At least five reader-facing inventory views removed; two later prose sites carrying seven numeric facts and four pinning assertions removed |
| Resource policy | The `16`/`32`/`48` facts go from 33 literal occurrences to 15: five intentionally independent policy surfaces per fact |
| Variant policy | Five redundant manual variant-association tables removed |
| Historical search surface | Ten completed or superseded documents and 12,657 lines removed, including the two journals' 7,120 lines |

Source finalization now changes one bounded release declaration rather than
four; with the independently required changelog, that is two development
documents per release. Generated artifacts, publication registration and the
literal release-identity pin remain separate operations rather than being
miscounted as duplicate prose.

No Make gate goal was retired. The ordinary test inventory grows from 66 to 74
named gates, and the retained deliberate-duplication register protects nine
second-opinion structures, including two independent PIC return-stack witnesses
and ten distinct verification layers. Added assurance includes a guard census
expanded from 27 to 79 declarations with 53 target-toolchain mutation fixtures
over 20 configurations; eight published-release invariants over all 12 retained
releases with 21 negative controls; content binding for 13 formerly unchecked
logs; three resource-oracle agreement checks; and new reference and
claim-boundary contracts. These overlap and are not presented as one inflated
check count.

The result therefore meets the stated criteria by reducing maintained
authorities, per-release prose edits, mutable measurements, duplicate
orchestration and historical search noise while retaining every prior gate and
adding independent checks. Tests and scripts grew because some prior claims had
no executable witness; that assurance growth, the two retained release trees
and this not-yet-deleted plan explain why whole-tree line count alone is the
wrong success measure.

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
| BR-AUTH-01 | Finalize authority map | DONE `620234f` + `0705898` |
| BR-AUTH-02 | Inventory references/contracts | DONE `bc267a8` |
| BR-RES-01 | Remove mutable resource tables | DONE `e7c4f68` |
| BR-RES-02 | Retire prose synchronization tests | DONE `e7c4f68` |
| BR-RES-03 | Publish generated release resource view | DONE `1ad315e` |
| BR-PIC-01 | Create coherent PIC design section | DONE `b1b98c3` |
| BR-PIC-02 | Merge PIC10F322 phase notes | DONE `3a3b661` |
| BR-PIC-03 | Consolidate PIC10F320 documents | DONE `b8b4af1` |
| BR-PIC-04 | Consolidate PIC12F675 feasibility | DONE `f968de7` |
| BR-PIC-05 | Update firmware document references | DONE `f968de7` |
| BR-FLASH-01 | Make FLASHING.md authoritative | DONE `a1633e0` |
| BR-FLASH-02 | Generate release programming guide | DONE `23eac73` |
| BR-FLASH-03 | Delete flashing proposal journal | DONE `fc11171` |
| BR-FLASH-04 | Close PIC10F32x programming authority gaps | DONE `c9aa9ae` |
| BR-DOC-01 | Delete completed v0.9.6 journal | DONE `9b6dfc3` |
| BR-DOC-02 | Reduce Makefile split decision | DONE `5ce3f59` |
| BR-DOC-03 | Reduce non-blocking feasibility analysis | DONE `9c16f96` |
| BR-DOC-04 | Classify feature safety records | DONE `8180569` |
| BR-README-01 | Reduce root README | DONE `d7104c9` |
| BR-TESTDOC-01 | Reduce test README | DONE `a64c25e` |
| BR-TODO-01 | Reduce TODO to registry | DONE `6fa9a1b` |
| BR-CHANGELOG-01 | Adopt concise changelog policy | DONE `da1d62d` |
| BR-RELEASEDOC-01 | Reduce release README | DONE `512d0c3` |
| BR-COMMENT-01 | Trim live historical comments | DONE `b194731` |
| BR-STATE-01 | Remove repeated release declarations | DONE `d799c14` |
| BR-STATE-02 | Make development/release state explicit | DONE `d4675d0` |
| BR-TEST-01 | Delete retired rename lane | DONE `893d647` |
| BR-TEST-02 | Remove duplicate CI mutation run | DONE `b86a5a7` |
| BR-TEST-03 | Route CI through aggregates | DONE `b9cbd36` |
| BR-TEST-04 | Centralize policy constants per surface | DONE `bc5f11d` |
| BR-TEST-05 | Prefer behavioral fixtures | DONE `7aab253` |
| BR-TEST-06 | Introduce named test profiles | DONE `746ddcf` |
| BR-TEST-07 | Consolidate strict helpers/wrappers | DONE `cee6bab` + `0dada67` |
| BR-TEST-08 | Generate recipes from variant maps | DONE `d3ea121` |
| BR-TEST-09 | Consolidate dependencies/parsers | DONE `4fa470b` |
| BR-QUALITY-01 | Define complete analysis matrix | DONE `edd9696` |
| BR-REL-01 | Define canonical signed release index | DONE `bb5ba13` + `b5704f7` |
| BR-REL-02 | Index evidence; bind the 13 unchecked logs | DONE `f401507` |
| BR-REL-03 | Clarify full test-long retention | DONE `463aa2f` |
| BR-REL-04 | Define hosted retention/mirroring | DONE `e04765a` |
| BR-REL-05 | Keep releases self-contained | DONE `a636400` |
| BR-REL-06 | Consider tag-only artifact commits | DECLINED |
| BR-REL-07 | Preserve historical releases | DONE `24c2ded` + `7fe055b` |
| BR-REL-08 | Collapse duplicate release phase logs | DONE |
| BR-SRC-01 | Preserve deliberate source duplication | DONE `28f8ffe` |
| BR-SRC-02 | Perform optional source cleanup | DONE `801e033` |
| BR-SRC-03 | Expand negative guard tests | DONE `781cb43` |
| BR-SRC-04 | Enforce source-refactor proof obligations | DONE `1b79ed5` |
| BR-REVIEW-01 | Resolve completed-item review findings | DONE `cc2ff7a` |
| BR-REVIEW-02 | Resolve pre-merge readiness review findings | TODO |
| BR-FINAL-01 | Audit current references | DONE `880d28b` |
| BR-FINAL-02 | Verify safety/claim boundaries | DONE `de29c39` |
| BR-FINAL-03 | Verify independent oracles remain | DONE `0dc5231` |
| BR-FINAL-04 | Run focused gates incrementally | TODO |
| BR-FINAL-05 | Run complete qualification | TODO |
| BR-FINAL-06 | Measure outcome | DONE `bc1fe73` |
| BR-FINAL-07 | Delete this working document | TODO |
