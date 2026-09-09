# Post-v0.9.12 work plan

> **Branch-only working document.** This file coordinates work on
> `post-v0.9.12-work`. It is not durable product documentation and must be
> deleted, and de-referenced, before release source finalization. The release
> documentation gate rejects unapproved root-level Markdown working documents.
> Git history retains this plan after its deletion; durable conclusions move
> into the document that owns them before it goes.

> **Baseline:** branch `post-v0.9.12-work`, cut after `5c1d215` (v0.9.12 source
> contract finalized). The `v0.9.12` release is in progress on another system
> and is **not** cut from this branch. Nothing here may change the in-progress
> `v0.9.12` release contract. Breaking a self-check on this branch is expected
> and acceptable; the pre-merge obligation is that the branch tip is green, not
> that every intermediate commit is.

---

## Status board

| ID | Task | Workstream | Size | Status |
|---|---|---|---:|---|
| A1 | Render the mechanical release edits instead of validating them | Strictness | 4-6 h | **done** |
| A2 | Convert verbatim prose pins to marker blocks + keyword sets | Strictness | ~1 d | **done** |
| A3 | Move the pinned measurement out of the design document | Strictness | 1 h | **done** |
| A4 | Reconcile README and design doc with the gates that survive A2 | Strictness | 2 h | **done** |
| A5 | Write down the enforcement register | Strictness | 2 h | **done** |
| B1 | Restructure README for its two audiences | README | 3-4 h | **done** |
| B2 | Create the governance document | README | 2-3 h | **done** |
| B3 | Plumb the new document through the gates | README | 1 h | **done** |
| C1 | Allowlist gate for derivable release numbers | Anti-drift | ~1 d | **done** |
| C2 | Obligations for a new gate | Anti-drift | 1 h | **done** |
| C3 | Threshold restatement survey | Anti-drift | 2 h | **done** |
| D1-D9 | Noted, not scheduled | — | — | see below |

Ordering: **A1 and A2 first.** Everything else in A and B is easier once the
release ritual and the prose pins stop fighting ordinary editing. C is the
round's durable output and can proceed in parallel. D is a holding area — most
of it belongs in `TODO.md` or in **Considered and declined**, not here.

**Workstream A is complete.** A1 and A3 removed the two verbatim techniques, A2
converted the prose pins, A4 closed the reconciliation (mostly by the gates
themselves, at `c8bd782`), and A5 wrote the register describing the result. The
register now lives in `GOVERNANCE.md`, which B2 created and B3 plumbed through
the gates, so the dependency this workstream left behind is discharged.

**Workstreams B and C are complete, and with them every scheduled item.** B2
moved the governance prose out of `README.md`, B3 plumbed the new document
through the gates, and B1 folded what was left into a signpost. C1 closed the
derivable-number class, C2 wrote the obligations a new gate has to discharge,
and C3 surveyed the threshold restatements and retired the last two prose pins.
What remains is **D**, which was never scheduled: it is a holding area, and
most of it belongs in `TODO.md` or in that file's **Considered and declined**
section rather than here.

---

## Purpose

Two goals, and they are the same goal seen from two sides.

**Make the project editable by its owner.** Much of the durable prose is
LLM-authored and reads like it. Rewriting it in the maintainer's own voice is a
legitimate, wanted change, and today it is mechanically obstructed: sixteen-odd
claims are pinned as verbatim sentences, and the release ritual demands seven
hand-written lines per release that no human decided. That obstruction is not a
safety property. It is a technique choice that was made once and never revisited.

**Make the previous round's gains durable.** `post-v0.9.10-bloat-reduction`
removed documentation duplication by hand and installed a real document
lifecycle. It had no standing gate, so nothing prevents the tree from
re-accumulating exactly what was removed — and it already has, in the README.

The through-line: **the last round proved the tree can be cleaned by hand; this
round should make it stay clean by construction, and stop making the maintainer
fight the machinery to write a sentence.**

Non-goals: reducing line count for its own sake, weakening any property the
current gates protect, and touching firmware. Every conversion below keeps the
property and changes only the technique.

---

## Where the project stands

Lines by area, tracked files, excluding `release/`:

| Area | v0.9.0 | v0.9.6 | v0.9.9 | v0.9.11 | HEAD | Growth |
|---|---:|---:|---:|---:|---:|---:|
| `src/bypass_pure.c` (the algorithm) | 108 | 107 | 107 | 121 | 121 | 1.1x |
| `src/` (all firmware) | 1,504 | 2,797 | 3,540 | 4,179 | 4,223 | 2.8x |
| `Makefile` | 1,608 | 4,647 | 7,521 | 8,615 | 8,673 | 5.4x |
| `test/` | 6,016 | 24,004 | 42,938 | 58,353 | 65,963 | 11.0x |
| `scripts/` | 680 | 2,837 | 4,623 | 9,353 | 11,377 | 16.7x |

Support-to-firmware ratio: **5.5:1 at v0.9.0, 20.4:1 today.** Four new MCU
targets account for the 2.8x in `src/`. They do not account for 11x and 17x.

The 66k lines of `test/`, by subject:

| What it verifies | Lines | Share |
|---|---:|---:|
| Firmware behavior, resources, formal proofs | 32,764 | 50% |
| The Makefile and build system | 18,312 | 28% |
| The release process and the documentation | 13,878 | 21% |

With `scripts/` and the `Makefile` added, roughly **52,000 lines exist to
publish the firmware** against roughly **37,000 that establish it is correct**.

What the bloat-reduction round actually moved, `v0.9.11..HEAD`:

- **-12,657** lines of documentation deleted (ten journals)
- **+7,610** lines added to `test/`
- **+2,024** lines added to `scripts/`
- **-2,249** net

It did what it set out to do and won. In the same window the assurance
apparatus grew by ~9,600 lines, and nothing governs that growth.

### What is working and must not be traded away

- `README.md`'s authority map and document lifecycle. The principle is right and
  stated once.
- `test/test_deliberate_duplication.py` — a register of duplications that are
  *second opinions*, each naming the independent opinion a fold would destroy.
- `test/test_resource_tables.py` — the right pattern, stated outright: *"this
  gate no longer reads documentation. It measures."*
- `HARDWARE_VALIDATION_LOG.md` — separates field reports from controlled
  qualification and defines the latter as an 11-field record.
- `test/README.md`'s proof obligations for a firmware change.
- The skip-versus-strict architecture and `STRICT_TOOLS=1`.

---

## Workstream A — Release and documentation strictness

### The diagnosis, in one commit series

The entire hand edit for the v0.9.12 release, across four commits:

```
7a2d5c7  -## [Unreleased]
         +## [v0.9.12]                            <- wrong, no "v" allowed

706f40d  -## [v0.9.12]
         +## [0.9.12] - 2026-09-03                <- right format, second try

21a81c2  +## [Unreleased]                         <- the empty section must persist
         +

5c1d215  -[Unreleased]: .../compare/v0.9.11...HEAD
         +[Unreleased]: .../compare/v0.9.12...HEAD
         +[0.9.12]: .../compare/v0.9.11...v0.9.12
         -> **Current release contract:** `v0.9.11`; seven release parts; ...
         +> **Current release contract:** `v0.9.12`; seven release parts; ...
         +> **Pre-tag transition:** `release/v0.9.12/` is created by the ...
```

Seven lines. **Every one is a pure function of three inputs: the version being
cut, the previous version, and today's date.** Not one carries a decision a
human made. `scripts/release-documentation.sh:126-133` already parses the
previous version out of `CHANGELOG.md` in order to check a link it could have
written. `5c1d215` also had to edit `test/test_release_preflight.sh` by 22 lines
to get through.

That series is not carelessness. It is the only feedback channel the system
offers: a gate that says *no* rather than a tool that writes it.

### The architectural root cause

`scripts/make-release.sh` writes to exactly one place — `$OUTPUT_DIR`, i.e.
`release/<version>/` (`make-release.sh:3200`). Every `release_render_*`
function targets that directory. For durable documents the tooling has one
verb: **refuse**. There is a `release-preflight` goal and a `release` goal;
there is nothing that *prepares*.

The boundary is drawn at *"is this file inside `release/`"* when it should be
drawn at **"did a human decide this, or is it derived?"**

| Content | Who decides | Today | Should be |
|---|---|---|---|
| Which changes matter, in what words | the maintainer | hand-written | hand-written |
| `## [0.9.12] - 2026-09-03` heading | derived | hand-written, gated | generated |
| Both `compare/` link lines | derived | hand-written, gated | generated |
| `[Unreleased]` section persists | invariant | hand-written, gated | generated |
| Contract line version bump | derived from Makefile maps | hand-written, gated | generated |
| Pre-tag transition line | derived | hand-written, gated | generated |
| `QUALIFICATION` source commit | derived, then **frozen into a signed artifact** | generated | generated |

**One distinction to preserve.** For durable prose, Git is the record and the
compare links are a rendering of ordering already present in the file. For
`release/<version>/QUALIFICATION` and `MANIFEST.md`, Git is *not* the record and
must not become it: the point of a signed release artifact is that someone who
downloaded a tarball can audit it without trusting the repository they got it
from. The line to draw is **derived-and-hand-maintained** (remove) versus
**derived-and-frozen-into-a-signed-artifact** (keep exactly as is).

### The five techniques already in the tree

Documentation claims are enforced five different ways, differing enormously in
what they cost the author's voice:

| Technique | Example | Voice cost |
|---|---|---|
| Marker block + structural check | `HARDWARE_VALIDATION_LOG.md`'s `<!-- controlled-qualification:start -->` plus required `- **Field**` bullets (`release-documentation.sh:536,589`) | none |
| Keyword set | `for required in ATtiny13a PIC10F320 'own image' fuse CONFIG` (`:634`) — requires the concepts, not a sentence | none |
| Form-family regex, banning | the unscoped-ipecmd denial and the retired idiom, with code-span and quoted-span stripping so *naming* a retired claim is not *making* it (`:645-658`) | none |
| Verbatim sentence, requiring | ~~`bounded_claims` (7), the programming claim (2 documents), the helper status (3 documents), the frozen PIC10F320 measurement~~ — **retired by A2 and A3**; nothing in the tree pins a sentence any more | total |
| Verbatim line, requiring | ~~the CHANGELOG compare links, the contract line~~ — **retired by A1**; those lines are machine-written now | total |

`_release_flowed_text` collapses whitespace, so **rewrapping survives and
rewording does not** — precisely the operation this branch exists to perform.

The project already reached the right conclusion once, at
`release-documentation.sh:1269-1272`:

> *the same false claim survives an editor's rewrap and an adjective swap; what
> it deliberately does NOT ban is a claim SCOPED to a route*

A2 applied it to the rest, and A3 took the last one. The two bottom rows are
now empty, and the mechanism that emptied them -- a named fence plus a set of
required terms, in `_release_check_claim_block` -- is the first two rows fused:
the marker block bounds the claim, and the keyword set holds it. Three
techniques remain, and none of them costs the author a word.

That analysis was applied to one check and not to the sixteen others. **This is
not a philosophy change. It is finishing a conversion that was started and left
uneven.**

---

### A1 — Render the mechanical release edits instead of validating them

Add a release-preparation goal that writes the seven derived lines: dates the
release heading, re-opens `## [Unreleased]`, writes both `compare/` links, bumps
the bounded contract line from the Makefile's canonical maps, and adds the
pre-tag transition line.

<!-- name-contract: exempt-begin (proposed goal: this plan is the proposal to
     create it, so it correctly does not exist in the tree yet) -->
```
make release-prepare VERSION=vX.Y.Z
```
<!-- name-contract: exempt-end -->

Then **delete the corresponding checks**. A gate that a tool's own output must
satisfy is theatre. What survives from `release_validate_current_documentation`
is the one check with content — `release-documentation.sh:110-115`, that a
non-empty `[X.Y.Z]` section exists with at least one category and one entry,
i.e. *the maintainer wrote something about this release*.

Acceptance: cutting a release requires no hand edit to `CHANGELOG.md` beyond
prose; re-running the goal is idempotent; a release whose section is empty or
missing still fails, naming the section. Roughly 60 lines of validator retire
with it.

Do not let the goal invent prose. It writes structure and derived strings only.

Size: 4-6 h.

**Landed.** `scripts/release-prepare.sh`, `make release-prepare VERSION=vX.Y.Z`,
and `make test-release-prepare`.

- The four `release_render_*` functions plus `_release_transition_line` in
  `scripts/release-documentation.sh` are now the single format authority. The
  preparer writes through them; the validator compares against them. Neither
  states a format the other does not.
- The validator kept every property. `release_validate_development_state` runs
  the same checks continuously on the live tree, so deleting them outright --
  as this section originally proposed -- would have left a stale declaration
  unnoticed between releases. Render-and-compare removes the hand authoring
  without removing the check; the diagnostics now end in "re-run release-prepare
  for <version>" instead of describing a string to type.
- `RELEASE_CONFIG_GOALS` names the release-configuration goals once; four
  parse-time guards select on it. `release-prepare` is in that set because it
  writes the canonical counts into the declaration, so an identity-changing
  override is refused before anything is read. It is deliberately **not** in
  `_MAKE_RELEASE_DIRECT` (that flag asserts the script takes the worktree lock
  itself, which this one does not) and not in the unsupported-override rule
  (whose own serialization wrapper would trip it). Both exclusions are commented
  where they are made.
- Refusals are total. The first draft installed each document as it was
  rendered, so a fault found while rendering the second left the first already
  written -- a tree that is half-prepared and reads as prepared. Both candidates
  are now built and checked before either is installed. The regression test
  found this, and asserts it for every refusal path.

**The acceptance evidence is a replay, not a fixture.** `test-release-prepare`
reconstructs the tree at `7a2d5c7^`, runs the preparer once, and requires the
result to be **byte-identical** to `5c1d215` -- what the four hand commits
produced. 35 checks, 0 failures. `test-release-preflight` passes at 246 checks
against a tree with A4's README restored, which is how the A1 change was
separated from the breakage A4 still owns.

Follow-ups, neither blocking: the topology words (`seven release parts`, `six
modular targets`, `four shell source files`) are renderer constants rather than
derived from the Makefile -- C1 will want them derived; and `release-prepare`
does not take the worktree lock, which is right for a text edit but means it
should not be run concurrently with a release.

### A2 — Convert verbatim prose pins to marker blocks and keyword sets

Roughly seventeen places byte-pin the maintainer's own prose: `README.md` (3+),
`release/README.md` (4), `DESIGN_DOCUMENTATION.adoc` (4), `FLASHING.md` (2),
`CHANGELOG.md` (3+), and `test/test_reference_contract.py:91`'s literal
`"### Document lifecycle"` — which is why capitalizing one letter produced five
failures.

Convert each to the marker-block-plus-keyword-set form the tree already
demonstrates. The shape:

```markdown
<!-- qualification-status:start -->
No part has completed controlled hardware qualification — a bench run against
a written procedure whose source/image identity, configuration bytes,
instrument readings and acceptance result are retained.
<!-- qualification-status:end -->
```

Gate: the block exists, is non-empty, and carries the keywords `controlled`,
`qualification`, `procedure`, `retained`; the existing form-family ban on any
*attributive* "hardware-qualified firmware" claim outside it stays unchanged.
Reword freely inside the fence; the claim cannot quietly evaporate.

**Every property here is worth keeping, and none is being dropped:**

- The README must not lose the *no controlled hardware qualification* denial.
  That is the project's central honesty commitment, and softening it was a real
  regression independent of any gate — see A4.
- The PIC12F675 documents must not lose the *helper, not a raw writer*
  instruction. That is a hardware hazard, not bookkeeping.

**The risk to weigh, deliberately.** These gates were each written in response
to a real defect; `test/test_release_preflight.sh:2149` records that the README
bounded claim exists because *"the root README is where a reader arrives, and
its denial was the one the log's sentinel did not cover."* Loosening technique
while keeping the property is safe. Loosening technique **and** dropping the
property because it is currently in the way is how a claim disappears two
releases later. The fence is what makes the two distinguishable in review: a
deleted marker block is visible in a diff; a reworded sentence is not.

Acceptance: each converted claim has a named marker block, a keyword-set check
and a retained negative test proving deletion of the block fails; the prose
inside every block can be rewritten without touching a gate.

Size: ~1 d, mechanical, one claim at a time.

**Landed.** The claim gates now hold *terms*, not sentences.

One mechanism, in `scripts/release-documentation.sh`, built by generalizing what
the tree already had rather than inventing a second convention:

- `_release_marker_block` — was `_release_hardware_block`, which already fenced
  `HARDWARE_VALIDATION_LOG.md` by marker name. It now accepts both spellings the
  project writes, `<!-- name:start -->` in Markdown and `// name:start` in
  AsciiDoc, and ignores indentation so a claim living inside a list item can be
  fenced without the marker breaking the list. An absent fence and a malformed
  one fail identically, so neither reads as "nothing to check".
- `_release_claim_terms_text` — flows a block and drops the markup an author is
  free to change. Underscores are deliberately **not** dropped: `_` is already a
  word boundary for the matcher, so `_emphasis_` matches anyway, while removing
  it would mangle every `SNAKE_CASE` filename a block names. A link contributes
  both its label and its target, which is what lets a block be required to
  *point at* the record that owns a fact without dictating the sentence around
  the link.
- `_release_claim_has_term` — one required-term group: an ERE alternation,
  matched case-insensitively and bounded to whole words. A single word is just a
  keyword, so keyword sets and form families need only one implementation.
- `_release_check_claim_block` — the editorial contract, defined once. Both
  validators drive it from a table.

Nine fenced claims replaced seventeen-odd pinned sentences:

| Marker | Document(s) | Was |
|---|---|---|
| `qualification-status` | `README.md` | verbatim sentence |
| `pic10f320-recorded-omission` | `DESIGN_DOCUMENTATION.adoc` | verbatim sentence |
| `pic10f320-assurance-seam` | `DESIGN_DOCUMENTATION.adoc` | two verbatim sentences |
| `image-attestation` | `release/README.md` | verbatim sentence |
| `historical-images` | `release/README.md` | verbatim sentence |
| `pic12f675-helper-required` | `README.md`, `FLASHING.md` | verbatim sentence |
| `pic12f675-helper-status` | `README.md`, `FLASHING.md`, `release/README.md` | verbatim sentence |
| `pic12f675-disposition` | `DESIGN_DOCUMENTATION.adoc` | first-line prose anchor |
| `document-lifecycle` | `README.md` | verbatim heading |

Two conversions did **not** become keyword sets, because a keyword set would
have been the wrong tool:

- The **helper status** is a conjunction — published, *and* software-tested,
  *and* not hardware-qualified. Three independent keywords are satisfied by a
  block that keeps two parts and drops the third, which is the exact half-a-claim
  defect the sentence was written to close. It is one ordered pattern instead,
  so the connective prose is free and all three parts must still appear together.
- The **fourteen design-contract sentences** in `test/test_release_qualification.sh`
  are safety-relevant *numbers* wrapped in pinned scaffolding. Each is now an
  ordered pattern that keeps every figure and every part association and lets the
  prose between them move. Their negative coverage is generated from the table
  itself: delete the span a rule matches, and that rule must stop matching — a
  pattern that survives deletion of its own match was anchored on connective
  prose, not on the fact it names.

The CHANGELOG pins this section counted are already gone: A1 made those lines
machine-written, so they are no longer anybody's to maintain.

**Deliberately not converted, and recorded rather than silently skipped.**
`test/test_release_qualification.sh` also pins six strings out of `TODO.md`'s
`T3-pic12f675-bench` section, including their `**bold**` markup — for example
``**1 - bandgap calibration bits (`BG<1:0>`) preserved on program.**``. These
were left alone for now because the *numbering* really is an interface: the
Makefile, the CI notes and the release documentation all cite those residual
risks by their original numbers, so unlike the claims above, part of what is
pinned is genuinely an API rather than prose. What is **not** API is the bold
markup and the exact phrasing around each number, and that half should still be
loosened. It is small, it is the same mechanism, and it belongs in A5's
enforcement register as a known remaining pin rather than in an unrecorded
backlog.

**Evidence that the technique change worked.**

- `release_validate_claim_boundaries` now **passes on the maintainer's own
  rewritten README, with no prose change at all.** The whole document diff for
  this task is ten added marker lines and zero altered words.
- `test_reference_contract`: 21 checks, 0 failures. It was 5 failures, all
  cascading from `### Document Lifecycle` versus the pinned `### Document
  lifecycle` — one capital letter, which also broke four self-tests that use the
  checked-in table as their control fixture. The heading is prose again; the
  marker is the contract — and one of the three added checks is a control case
  asserting that renaming that heading is still accepted.
- `test_release_qualification`: 231 checks, 0 failures, up from 217. The extra
  fourteen are the generated negative cases for the design-contract rules.
- `test_release_preflight`: 264 checks, 0 failures, up from 246. The extra
  eighteen are the fenced claims' negatives and, more importantly, their accept
  cases. Run against a sandbox carrying restored content for the four A4 items
  below, so what it measures is A2's machinery rather than A4's absence.
- A design-contract rule had been broken by changing one `.` to a `;` in
  "...sample cadence. PIC12F675 uses 1.024ms" — an edit that altered no claim, no
  number and no part. It passes now.
- Every claim carries a retained negative test: fence deleted, fence emptied,
  fence left unclosed, claim inverted, and definition gutted while the denial
  survives. Each also carries an **accept** case — the same commitment in another
  voice — which is the case that fails if a future edit quietly re-pins prose.

**A2 found no way to soften a property, and softened none.** What changed is
which of the five techniques each claim uses, not what any claim asserts.

**Handed to A4.** Three of these blocks have no prose to fence, because the
voice rewrite removed the content rather than rewording it. These are content
losses, not gate strictness, and two of them are safety facts:

1. `README.md` / `pic12f675-helper-required` — that the part needs Python 3 and
   the release helper *because its per-device factory calibration must be
   preserved and verified*. A hardware hazard; the README now states only that a
   script is needed, not why a raw programmer write is unsafe.
2. `README.md` / `pic12f675-helper-status` — published, software-tested, not
   hardware-qualified.
3. `DESIGN_DOCUMENTATION.adoc` / `pic12f675-disposition` — release-supported from
   `v0.9.9`, not hardware-qualified, deferred to TODO `T3-pic12f675-bench`.
   Removed whole by `4d85ad7`.

Each fails with a diagnostic naming the marker and what the block must own, so
A4 is a writing task with a checklist rather than a hunt. The gates were
validated against a sandbox carrying restored content for all three.

### A3 — Move the pinned measurement out of the design document

`DESIGN_DOCUMENTATION.adoc:1808` is pinned verbatim as a bounded claim:

> Measured 2026-06-26 at source commit `0b44c0d` with free-tier XC8 V3.10 and
> PIC10-12Fxxx DFP V1.9.189, the modular firmware for this part built at 356,
> 386 and 381 words...

`README.md`'s own standing rule says: *"Current measurements belong to CI output
or retained release evidence, not to development prose. A number that changes
when the code changes has no stable owner in a hand-edited document."*

The date and the commit ID are there because a measurement was placed in a
design document and pinning its provenance was the mitigation. The rule's own
remedy is to move the measurement to the release record — exactly what
`test-resource-tables` already did for the flash and RAM tables. The design
document keeps the architectural claim (*the modular architecture does not fit
in 256 words, by roughly 100*), which is stable under ordinary code changes, and
drops the three word counts, the date and the SHA.

That clears 2 of the 3 dates and 1 of the 3 commit IDs in that file. Check the
remaining two while there. Note for calibration: `README.md`, `FLASHING.md`,
`HARDWARE_VALIDATION_LOG.md` and `test/README.md` carry **zero** dates and
**zero** commit IDs today — the previous round got that right. The pain is
concentrated in the CHANGELOG ritual and the verbatim pins, not in scattered
dates.

Firmware is untouched; this is a documentation and gate edit.

Size: 1 h.

**Landed.** The last exact-sentence pin in the project is gone, and
`DESIGN_DOCUMENTATION.adoc` now carries **no date and no commit ID at all** —
three dates and two commit IDs, against the 2-of-3 and 1-of-3 this section
predicted.

**What the pin actually was.** `git blame` settles it: the date `2026-06-26`
was the maintainer's, but the clause that pinned it — *"at source commit
`0b44c0d` with free-tier XC8 V3.10 and PIC10-12Fxxx DFP V1.9.189"* — was
inserted by `e16517d9`, the very commit that established the current-fact rule.
That commit deleted the measured simavr tables and wrote the remedy in the
document itself:

> *The exact Classic-AVR intervals are results of the source, compiler and
> simavr run, so the harness emits them and any durable result belongs in
> release evidence rather than this design document maintaining a second
> current table.*

It then made one exception, for this passage, and mitigated the exception by
binding it to a revision. A3 removes the exception rather than the rule.

**Where the measurement went, given that it cannot go to the release record.**
The measured thing — a *modular* build of the PIC10F320 — is not a shipped
image and never was, so `test-resource-tables` has nowhere to put it. But this
document had already solved that case twice, for the PIC10F322 ISR spike and
the PIC12F675 modular spike, and in both places the remedy is the same phrase:
*"not a measurement of any current image; what carries forward is the
conclusion"*. The PIC10F320 passage is the one that never got it. It has it
now, in the document's own words:

> Those are historical figures for builds that were never shipped, not a
> measurement of any current image; what carries forward is the conclusion,
> which is that this part has no room for the modular architecture.

**Which numbers left and which stayed, and why they differ.** The three variant
counts (356, 386, 381) were a restatement of *"roughly 100 words over 256 in
every case"*, which the same sentence already said — a redundant current-ish
measurement, so they went. The PIC12F675 spike's counts (494, 520, 523 of 1024)
stayed, because they carry a comparison the passage explicitly draws against
39 words spare on the PIC10F322, and nothing else states it. The priced
reductions (12, 47, 53 words) stayed for the same reason: they are the prices of
options that were **refused**, which is history by construction, and the new
framing sentence now covers them.

**The gate that replaced it.** One fenced claim and one ban:

| Rule | Kind | Holds |
|---|---|---|
| `pic10f320-flash-overrun` | fenced claim | `modular`, `256`, `words`, a *does-not-fit* form family (does/did/would/can not fit·link·build·compile, cannot, never fits, too big·large, over·beyond 256, overrun, exceed, no room, out of flash·room·space, link failures, failed to link), and an empiricism group (measured, priced, built, observed, compiled) |
| no dates, no revisions | ban, `current_fact_rules` | `DESIGN_DOCUMENTATION.adoc` may not contain an ISO date, an `at\|on [source ]commit <sha>`, or a `main\|HEAD at <sha>` |

The ban is the half that keeps A3 from being undone. The provenance pin existed
*because* a measurement sat in durable prose; removing the measurement without
closing that door just invites the next author to reach for the same mitigation.
The rule states the principle instead: git already records when a thing was
written and against what.

The direction is enforced as a *form family* rather than a keyword, because
`modular` + `256` + `words` + `measured` are all satisfied by a block that says
the modular firmware **fit**. That is the inversion case, and it has a negative
test.

**Evidence.** `test_release_preflight`: 268 checks, 0 failures, up from 264 --
five new cases replacing one retired pin. `test_release_qualification`: 231
checks, 0 failures, unchanged; all fourteen design-contract patterns still match
the edited document. `test_reference_contract` 21/0, `test_release_prepare`
35/0, `test-makefile-name-contract` 48/0, `test-todo-index` 99/0. `asciidoctor`
renders the document with zero warnings and the `//` markers emit nothing, so
the fenced paragraph is unbroken. The five new cases: fence deleted rejects; the claim
inverted while keeping every noun rejects; a date reintroduced rejects; a
revision binding reintroduced rejects; and one **accept** case — the same
overrun rewritten in another voice, leaning on a different member of the
does-not-fit family than the shipped prose uses — passes. `TOOLCHAIN.adoc:80`
pointed at the binding this task removed and was corrected to point at the
history instead.

### A4 — Reconcile README and design doc with the gates that survive A2

Seven assertions were red on this branch from the voice rewrite
(`b3fa0bd`..`6964a00`) — six listed here when the plan was written, and a
seventh (item 7) that only became visible once A2 unblocked the gates ahead of
it. Expected and acceptable on a branch; they must be green before merge.
Resolve them **after** A2, so the reconciliation is done against the loosened
technique rather than against the byte-pins being retired:

1. `### Document Lifecycle` vs. the literal `"### Document lifecycle"` —
   `test-reference-contract`, 5 failures including all three negative cases,
   which read the live README.
2. The dropped *no controlled hardware qualification* bounded claim —
   `test-release-preflight`, and `release`.
3. The dropped exact downloaded-release programming claim (PIC12F675 requires
   Python 3 and the helper).
4. The dropped helper status (published, software-tested, not
   hardware-qualified).
5. **`test-release-qualification`: "design documentation states no PIC12F675
   release disposition."** Found while regression-testing A1, and it comes from
   the design-document rewrite (`4d85ad7`), not the README. That gate anchors on
   a paragraph beginning `A third PIC, the PIC12F675,` in
   `DESIGN_DOCUMENTATION.adoc`, and requires the block under it to carry the
   release disposition and the four residual silicon risks. The rewrite removed
   the anchor. Confirmed pre-existing on a pristine `HEAD`, so it is A4's, not
   A1's. A2 should convert this anchor to a marker block like the rest.
6. `DESIGN_DOCUMENTATION.adoc:56` reads `different harware`, introduced by the
   same rewrite.

**A2 resolved items 1, 2 and 6; items 3, 4 and 5 are what remains, and they are
writing tasks rather than gate arguments.** A2 converted every gate here from a
pinned sentence to a fenced claim held to its terms, then re-checked each item
against the maintainer's actual text:

- **Item 1 (`### Document Lifecycle`) — closed.** The lifecycle table is bounded
  by a `document-lifecycle` marker now, so the heading is prose again.
  `test-reference-contract` is 18 checks, 0 failures.
- **Item 2 (the qualification denial) — closed, and it was never a content
  loss.** The rewritten paragraph still states the denial and still defines what
  qualification requires; only the *wording* had moved. It now passes untouched.
  The "However" reading below still deserves the maintainer's eye, but as an
  editorial judgement, not a red gate.
- **Item 6 (`harware`) — still open**, a one-character fix at
  `DESIGN_DOCUMENTATION.adoc:56`.

**Items 3, 4 and 5 are real content losses, and two of them are safety facts.**
Each now fails with a diagnostic naming the marker and what the block must own:

3. `README.md` needs a `pic12f675-helper-required` block saying the part needs
   Python 3 and the release helper **because its per-device factory calibration
   must be preserved and verified**. The README currently says a script is
   required but not that a raw programmer write destroys the part's only copy of
   its factory trim. That is the hazard, and it is the half that went missing.
4. `README.md` needs a `pic12f675-helper-status` block: the helper's `ipecmd`
   route is published and software-tested, and is **not** hardware-qualified.
   `FLASHING.md` and `release/README.md` still carry this and were fenced in
   place, unchanged.
5. `DESIGN_DOCUMENTATION.adoc` needs a `pic12f675-disposition` block:
   release-supported from `v0.9.9`, **not** hardware-qualified, deferred to TODO
   `T3-pic12f675-bench`. `4d85ad7` removed the paragraph whole.

The pre-A2 text for all three is recoverable — items 3 and 4 from `FLASHING.md`,
which still states both, and item 5 from `git show 4d85ad7^`. They should be
rewritten rather than reverted; the fences are what make that safe now.

**7. `README.md` no longer publishes the enforced host compiler floor (GCC 10).**
Found by running the preflight suite past the gates A2 unblocked — it had never
reached this check before. `b3fa0bd` ("Simplify and 'humanize' README") removed
the sentence; `main` still carries it, and `TOOLCHAIN.adoc` and `test/README.md`
both still publish it correctly, so README is the only one out of step.

This one is **not** a strictness problem and A2 deliberately did not touch the
gate. `test/test_release_preflight.sh:2919` already collapses line wrapping
before matching and already accepts two spellings, and its real property is that
the *number* cannot drift from `MINIMUM_GCC` in
`test/host_compiler_version.sh`. Nothing about it was fighting the rewrite; the
requirement simply went missing, and it is one a reader needs before they can
build anything. The removed sentence read:

> All of them need a host C compiler (GCC 10 or newer, or Clang — see
> [TOOLCHAIN](TOOLCHAIN.adoc)), matching `gcov`, Python 3.7 or newer, and Bash.

Worth noting for A5 rather than acting on now: that gate accepts exactly two
spellings, `GCC <n> or newer` and `Minimum host gcc version: <n>`. Listing the
acceptable spellings is the same antipattern A2 retired everywhere else, and
"GCC 10+" or "at least GCC 10" would fail it while publishing the identical
requirement. Since drift detection only needs *gcc near the enforced number*,
the wording could be freed without weakening anything. It belongs in the
enforcement register as a known narrow form family.

**One of these is substantive, not just a gate failure.** The rewrite now reads:

> A remaining validation step is a *controlled hardware qualification* ...
> However, the firmwares are being deployed in the field, see
> HARDWARE_VALIDATION_LOG.md.

That "However" inverts the relationship. `HARDWARE_VALIDATION_LOG.md` spends its
opening establishing that field reports **cannot** substitute for qualification
— *"a device with a destroyed factory oscillator trim, or an output sitting just
under its input buffer's threshold, plays fine and reports fine."* Restore the
separation in the maintainer's own words; it is the one claim where wording is
load-bearing for honesty rather than for a grep.

Also fix while here:

- `README.md:74` says `Panasonic TQ-L2-5v`. Everywhere else in the tree (12
  occurrences) and the image basename say **`TQ2-L2-5V`**. `TQ-L2-5v` is not a
  Panasonic ordering code, and this is operator guidance someone orders a part
  from. Pre-existing, not introduced by the rewrite.
- `README.md:138` — *"there are 21 different firmware images"* restates the image
  count that `release/README.md` is the declared sole owner of. See C1; a
  one-line fix now, and C1 is what stops it recurring.

Size: 1 h.

**Landed, and mostly not by this workstream.** Items 3, 4, 5 and 7 -- the four
real content losses, two of them safety facts -- were restored by `c8bd782`
("release: finalize v0.9.13 source contract"), which says why in its own words:

> TWO FACTS THE MERGED REWRITES DROPPED, both caught by that branch's own gates
> rather than by review

That is the mechanism working as designed, and it is worth stating plainly
because it is the whole argument for A2. Before A2 these were seven silently red
assertions on a branch. After A2 they were fenced claims, and the v0.9.13
release **could not be finalized until the prose came back**. Nobody had to
remember this checklist; the gate refused. The plan's own worry -- that a
reconciliation list left to human diligence would rot -- was answered by not
needing the list.

Note the shape of the restoration, too: the blocks were rewritten rather than
reverted, which is exactly what A2's fences were built to permit. The
`pic12f675-disposition` block now sits after the PIC Support section rather than
where `4d85ad7` deleted it from, and the GCC floor came back as a prerequisites
paragraph that also names the per-lane tools -- neither is the old sentence, and
both satisfy their claim.

**What this workstream actually had left**, and what closed it:

- **Item 6 (`different harware`)** -- fixed, `DESIGN_DOCUMENTATION.adoc:56`.
- **`README.md:74` `TQ-L2-5v`** -- fixed to `TQ2-L2-5V`. This one was a wrong
  part number rather than a style slip: twelve other places in the tree,
  including `docs/relay_coil_fault_correction.md`'s 4 ms pulse analysis and
  every row of `HARDWARE_VALIDATION_LOG.md`, spell it `TQ2-L2-5V`.
- **`README.md` restating the image count** -- removed. The sentence read
  *"there are 21 different firmware images, one for each combination of
  microcontroller and switching scheme"*; the clause after the comma already
  explains the number, so the count bought nothing and would have rotted the
  moment a part or a switching scheme was added. It now reads *"there is one for
  each combination of microcontroller and switching scheme."* The number keeps
  one owner, the bounded declaration in `release/README.md`. No gate change was
  made here -- README is not in `current_fact_rules`, and closing that class
  systematically is C1's job, not a one-off ban.

Item 2's "However" reading is still an editorial judgement for the maintainer
rather than a red gate, and is not tracked here.

### A5 — Write down the enforcement register

Today the knowledge of *which claims are gated, by which technique, and why*
exists only in shell comments inside `scripts/release-documentation.sh`. Hitting
a gate tells you what broke but not what property it was protecting, which is
why the reflexive repair is to edit the gate.

Produce a table: claim, owning document, technique, the defect that motivated
it. It lands in the governance document (B2), not in the README.

Size: 2 h. Depends on A2 (the table describes the post-conversion state).

**Landed, and now published.** The register was written here first because
B2 did not exist yet. B2 has since landed, so it lives in
[GOVERNANCE.md](GOVERNANCE.md#enforcement-register) and has been removed from
this plan rather than copied into both — keeping one fact true in two documents
is the thing the register's own first rule forbids.

It covers twelve fenced claims across seven documents, seven form-family bans,
eight structural or derived rules, and the two places that still hold prose to
an exact spelling (`TODO.md`'s `T3-pic12f675-bench` strings, and the GCC floor's
two accepted spellings). Every marker, document and count in it was checked
against the tree rather than written from memory.

---

## Workstream B — README and governance restructure

### The audiences

Two distinct users, and the README must serve both:

1. **Flash and go.** Wants known-good firmware on a chip, does not want the
   details. Needs: what this is, which image, where the command is.
2. **Curious or contributing.** Wants to read the code, understand the design,
   modify or contribute. Needs: where to go next, one hop per destination.

The README is part elevator pitch, part quickstart. Today ~90 lines of its 258
are the *Documentation Details* section — governance policy sitting in what
should be the pitch. Too much for user 1, in the wrong place for user 2.

### B1 — Restructure README for its two audiences

Keep the map's **skeleton** as a compact table of contents in the same register
as the existing *High-level source overview*: one line per destination, easy to
skip, and a signpost for the curious reader.

```
Design and rationale        DESIGN_DOCUMENTATION.adoc
Flashing a released image   FLASHING.md
Building from source        TOOLCHAIN.adoc
What the tests establish    test/README.md
Releases and trust model    release/README.md
Hardware evidence           HARDWARE_VALIDATION_LOG.md
Open work                   TODO.md
How this project is run     GOVERNANCE.md
```

The reasoning, the lifecycle table and the standing rules move to B2.

Size: 3-4 h. Do after A2.

**Landed.** B2 had already taken the ninety lines this item was sized against,
so what remained was the signpost and the shape of what is left. Both are
structural; **no sentence in `README.md` was rewritten**, for the same reason
B2 gave.

- *Documentation Details*, by then a three-line pointer to one document, became
  **Where to Read Next**: eight destinations, one line each, in the same
  register as the existing *High-level source overview* directly above it. The
  pointer's own description survives as the `GOVERNANCE.md` row rather than
  being compressed to "how this project is run", because it says what the
  reader will find there.
- *Quickstart* was two subsections doing unrelated jobs. **Flashing a Released
  Image** and **Building from Source and Development** are now sections of
  their own, which is the split between the two audiences: the first reader
  stops at the end of the first, the second reader starts at the second. The
  word *quickstart* is gone from the headings and stays true of the document,
  which is how `GOVERNANCE.md` already describes it.

The eight destinations are the plan's list unchanged. `MISRA_COMPLIANCE.md`,
`CHANGELOG.md` and `docs/` were considered and left out: the first two are
already linked from the sections that need them, and a signpost that lists
everything is not a signpost. The list is navigation, not authority — it
carries no count, version or measurement, so it restates nothing the map owns.

**What was deliberately not done.** The assurance section still sits ahead of
the flashing steps, where it reads as an interruption for the first audience.
It stays because its last two paragraphs are the qualification status and the
`0.9.x` versioning rule, and a reader about to write an image to a chip should
meet those before the steps, not after. Splitting the section would put the
pitch below the steps and the status above them; that is an editorial call
about the maintainer's own prose, not a structural one.

One gap is left open on purpose. Step 2 of the flashing list tells the reader
to decide which image they need and does not point back to *Targets* and
*Circuit-switching Hardware Support*, which are the two sections that answer
it. Closing that means writing a sentence, and sentences in this document are
the maintainer's.

### B2 — Create the governance document

`GOVERNANCE.md` receives: the authority map's *reasoning*, the document
lifecycle table, the documentation standing rules, the branch-only working
document contract, and the enforcement register from A5.

This is also the natural home for C2.

Size: 2-3 h.

**Landed.** `GOVERNANCE.md` holds all five: the authority map, the document
lifecycle table, the standing rules, the branch-only contract, and the
enforcement register. The prose moved **verbatim** from `README.md`'s
*Documentation Details* section — the maintainer had already written it in their
own voice, and moving a section is not an occasion to rewrite it. Only three
things changed, and all three are structural rather than editorial:

- Heading levels rose one, because these stopped being subsections of a README
  section and became sections of their own document.
- The map's row for itself split: `README.md` keeps product overview and target
  selection, `GOVERNANCE.md` takes documentation authority, lifecycle, standing
  rules, and what the gates enforce.
- `GOVERNANCE.md` gained its own lifecycle row, under **Contributor policy**
  beside `AGENTS.md` and `CLAUDE.md`. That is a judgement call: the label reads
  "maintained rules for people and coding agents working in this tree", which
  fits, and it avoids inventing a fourteenth label for one document. If the
  maintainer prefers a distinct label, it is a one-line change in the table plus
  one in `LIFECYCLE_AUTHORITIES`.

`README.md` keeps a three-line pointer under its existing *Documentation
Details* heading. Folding that into B1's compact table of contents is B1's
business, not this task's.

**Publishing the register changed what the register may say**, which nobody
predicted and the gate caught on the first full run. While it lived in this
branch-only plan it could quote the forms it documents; `_release_is_branch_only_document`
exempts working documents precisely so they can "quote the defective form while
describing the defect". `GOVERNANCE.md` is durable, so every ban now applies to
it. The unscoped-ipecmd row reproduced the banned wording and failed the
release:

> `GOVERNANCE.md` denies that any ipecmd procedure is published; the release
> helper publishes one, so scope the claim to the Make route or say that route
> is not QUALIFIED

Quoting is not the escape for that particular ban, deliberately: it strips
backtick *characters* rather than blanking their span, so a code span cannot
smuggle the claim through. The row now describes the form instead of
reproducing it, and the constraint is recorded in the register itself, where
the next person adding a row will meet it. The remaining quoted bans are safe
for narrower reasons worth knowing: the retired universal claims are swept only
over the three flashing publishers, and the attributive-qualification sweep
blanks quoted spans.

### B3 — Plumb the new document through the gates

Two mechanical dependencies, both of which fail closed if missed:

- `release_reject_branch_only_documents` (`release-documentation.sh:397-407`)
  hardcodes the eight root-level `.md` files a release may ship. `GOVERNANCE.md`
  must be added there or the release refuses it. The allowlist shape is
  deliberate — do not convert it to a pattern.
- `test/test_reference_contract.py:92-101`'s `LIFECYCLE_AUTHORITIES` map and its
  lifecycle heading constant both assume the table lives in `README.md`. Both
  need repointing, and A2 should have already made that heading a marker block
  rather than a literal string so it does not bite a third time.

Size: 1 h.

**Landed.** Both dependencies were exactly as described, and both did fail
closed when first run.

- `durable_root_docs` gained `GOVERNANCE.md`. The allowlist shape was left
  alone, as the plan required.
- `test_reference_contract.py` now names the owning document **once**, as
  `LIFECYCLE_DOCUMENT`, instead of spelling `README.md` at four call sites. A
  future move is one constant rather than a search, which is the same lesson
  A2 drew from the heading.

A2 had indeed already made the heading a marker block, and it paid for itself
here: the table moved between documents, changed heading level *and* changed
capitalization, and the gate followed it without a single edit to what it
matches.

Two defects were caught in this task's own work rather than shipped:

- The repointed docstring was written as `"..." % LIFECYCLE_DOCUMENT`, which is
  an expression rather than a string literal and silently stops being a
  docstring.
- The self-test control case still replaced `### Document Lifecycle`, the old
  README heading. In `GOVERNANCE.md` the heading is `## Document lifecycle`, so
  the replacement matched nothing: the case would have passed while proving
  nothing. That is precisely the vacuity the marker exists to prevent, hiding
  inside the test that proves the marker works. It now replaces the real
  heading, and the replacement was checked to actually change the text.

---

## Workstream C — Standing gates against re-accumulation

### C1 — Allowlist gate for derivable release numbers

The rule the project states — *each fact has exactly one live owner* — is
enforced by five hand-written denylist regexes covering two documents
(`release-documentation.sh:757-761`, `DESIGN_DOCUMENTATION.adoc` and
`TOOLCHAIN.adoc` only). `README.md` is not among them, which is why
*"there are 21 different firmware images"* sits in it unchallenged.

Replace the denylist with one allowlist gate. The release-topology numbers
(seven parts, 21 images, 18 soak combinations, six modular targets, four shell
source files) are all derivable from the Makefile's canonical maps. Scan every
durable document for those derived values; each occurrence must be either inside
the one bounded declaration block or in a named exemption register.

This is the same move `test-resource-tables` already made for measurements,
applied to topology. It would have caught the README's "21" the day it was
written, and it keeps catching.

Acceptance: the current tree passes only after A4's fix; a fresh restatement in
any durable document fails, naming the document and the number; the exemption
register is small and each entry carries a reason.

Size: ~1 d. This is the round's durable output — the thing that makes the
cleanup stick.

**Landed.** `release_validate_topology_ownership` in
`scripts/release-documentation.sh`, exercised by `test/test_release_preflight.sh`
and never by the release path. C1 is the first gate proposed since C2 landed, so
it is held to C2's list, and the two obligations that changed the shape of the
work are the two C2 added.

**Removal considered first**, and it settled most of the work. Seven
restatements sat outside the declaration, and **every one of them was better
deleted than exempted** — the count was incidental to what the sentence was
saying in all seven. `MISRA_COMPLIANCE.md` twice and
`docs/relay_coil_fault_correction.md` twice were naming how many shells consume
a symbol when the point was *which* translation units do; `docs/ci_parity.md`
was counting the images CI reproduced when the point was that it reproduced all
of them; `docs/release_proportionality.md` was counting soak logs an index
lists. So the gate's first act was to make itself have less to guard, and the
exemption register came out with **one entry**.

**A retirement condition** does not exist for this one, and that is recorded
rather than skipped: a release has a topology and a reader needs it, so the
rule confines the fact to one declaration instead of removing it. It retires
only if the declaration itself stops being hand-rendered.

**What is derived, and from where.** Nothing in the rule is typed:

- images and soak combinations, from the Makefile's canonical `RELEASE_IMAGES`
  and `RELEASE_SOAK_NAMES`, asked the same way `release-prepare.sh` asks;
- parts, from the distinct MCU tag in those same canonical image basenames, so
  it cannot disagree with the set it is counted from;
- shell source files, from the shipping shells that include the pure core;
- modular targets, from the parts minus those built from a self-contained shell.

Every step fails closed. An unreadable Makefile, an unparsable image name, or a
self-contained shell whose filename does not name a release part stops the run
rather than yielding a smaller number and a quieter gate. So does the scan
itself: a walk that reads no documents is indistinguishable from a clean tree,
which is the failure this whole rule is written against, so finding nothing is
reported rather than passed.

**The rule has two halves, and the second was the unplanned find.** The
absence half is what the task asked for. The presence half came from reading
`release_render_contract_line`, whose own comment says the three topology words
in it are constants and that deriving them "is worth doing, but it is a separate
change from removing the hand edit." Without the presence half this gate would
have banned those words everywhere **except the one place nothing checked them**.
So the declaration is now required to state every derived count. The renderer's
literals stay literals, and are held to the build. Adding a part fails here
instead of shipping a declaration that undercounts, and that cost no change to
the renderer's arity and nothing on the release path.

**Two exemptions, both structural, neither a hand-written pass.**
`release/README.md` is the owner and is not scanned: its bounded declaration is
required, a second bounded block anywhere is already refused by name, and its
errata state the topology of the past releases they name. `CHANGELOG.md` is not
scanned because the document lifecycle already classifies its release sections
as historical accounts — each states the topology of the release it describes
and is never edited to stay true. The single register entry,
`docs/release_proportionality.md`, is fenced with a marker rather than named
alone, so the exemption is visible where it applies, a restatement anywhere else
in that document still fails, and deleting the fence fails like any other
deleted fence. That last one is tested.

**Naming the form is allowed, making it is not.** The scan blanks quoted and
code spans, which is why this plan, `GOVERNANCE.md` and `test/README.md` can say
what the rule refuses. That escape is deliberate and is the opposite decision
from the unscoped-`ipecmd` denial, where publishing the form *is* the hazard.

**Verified by mutation, not only by a green run.** Two mutations were applied to
the shipped validator and the suite was re-run against each. Disabling the
absence scan fails on the README case; replacing the derived counts with the
literals this tree happens to have fails on the case that holds the same
sentence to a count this tree does not have. Both were restored.

Preflight: 294 to 318 checks, 0 failures.

### C2 — Obligations for a new gate

`test/README.md` has a rigorous, explicit gate on firmware changes: twelve proof
obligations, each with the commands that discharge it. There is **no
corresponding governance for adding a gate.** The growth curve above is what
that absence looks like.

Write the inverse section: what defect class a proposed gate closes, why an
existing gate cannot, what technique it uses (see the five-technique table), and
what it costs to keep. `test_deliberate_duplication.py` and
`test_resource_tables.py` already open with exactly this reasoning, and ~23 of
65 test files carry a `WHY THIS EXISTS` header. Make it the rule rather than the
habit.

Lands in `GOVERNANCE.md` (B2), cross-referenced from `test/README.md`.

Size: 1 h.

**Landed.** `GOVERNANCE.md` gains *Proof obligations for a new gate*, written as
the deliberate inverse of `test/README.md`'s obligations for a firmware change:
ten obligations in the same three-column shape, each discharged **in writing
before the gate is written** rather than by the gate passing.

The two that were not in the original sketch are the two that turned out to
matter most:

- **Removal considered first.** Before choosing a technique, the proposal must
  show the fact cannot be deleted, derived or generated instead of guarded.
  `test/test_resource_tables.py` is the worked example and says so in its own
  header: a gate kept restated measurements synchronized until the measurements
  were removed, and the checker now measures images rather than reading prose.
  Keeping copies synchronized treats the symptom. Several rows of the current
  register would not survive this obligation, which is the point of writing it.
- **A retirement condition.** What makes the gate unnecessary, enforced where it
  can be. The attributive qualification ban is the model: conditional on the
  sentinel, so it lifts on the commit that records the first controlled run
  instead of waiting for someone to remember it.

Also landed: the technique obligation **refuses** a proposal needing a verbatim
sentence or a verbatim line. A1-A3 retired both; without this row the next
author reintroduces one, because it is the easiest thing to write.

**D7's statement half is absorbed here** rather than left for later. The section
states the asymmetry plainly -- a firmware defect is in the field and its repair
is a reflash by someone who may never learn there was anything to fix, while a
release-machinery defect is caught by the next run and repaired in a commit --
and states the response D7 asked for: **not** matching adequacy evidence for the
build and release machinery, which spends effort on the recoverable half and
widens the gap. D7's remaining half, deciding what mutation coverage the
machinery should actually have, is untouched.

The section closes by applying its own first obligation to itself: the list is
held by review, not by a gate, because no gate has yet landed that it would have
refused. The defect class is unproven, so the machinery is unearned. If one
lands, that is the defect, and it goes in the register.

`test/README.md` carries the forward pointer at the end of its own obligations
section; the enforcement register carries the back pointer.

Gates: reference contract 21/0 over 18 documents, and the three live-tree
documentation validators clean.

### C3 — Threshold restatement survey

`PRESSED_THRESH` and `RELEASE_THRESH` are owned by `src/bypass_config.h`. Their
literal values appear in roughly fifteen other places — comments explaining a
derivation, and test harnesses that hardcode them as expectations rather than
deriving them (`test/avr/sim_attiny202.py:65-66` is the clearest).

This is a maintenance cost rather than a silent-pass risk: a changed threshold
makes those harnesses fail loudly. Survey, derive where cheap, and decide
deliberately which restatements are pedagogical (a comment explaining *why* 8
and 25) and which are drift-prone (a harness constant). Do not mass-edit
comments.

`src/bypass_mcu_pic10f320.c`'s copy is out of scope: it is a registered
deliberate duplication held by the equivalence lane.

Size: 2 h. Lower priority than C1.

**Landed**, and the survey's result changed what was worth doing.

**Every restatement used as an expectation already has an agreement gate**, and
most of them derive rather than restate. `sim_attiny202.py`'s two constants are
compared against the values the model reads from the header through the FFI;
`pic12f675_soak_timing.py` reads the header directly, so the ticks in
`test_soak_timing.sh`'s expected records are pinned expectations of a *derived*
value; `test_model_ffi.py` parses the header as a second opinion against the
compiled library; and all three mutation registries that `sed` the exact
`#define` text check the file actually changed and report a stale pattern as an
error. `test_lockstep_progress.sh`'s copy looks like a restatement and is not —
it is a synthetic stub whose `RELEASE_THRESH` is deliberately different.

So **there was no cheap derivation left**. Deriving `sim_attiny202.py`'s
constants from the header would have *removed* a second opinion rather than
added one: a typed constant checked against an FFI read is two routes to the
same fact, which is exactly what the duplication register exists to protect.

The rest are comments explaining *why* a threshold has its value. They stay, as
the task said they should. One documentation copy went: the AVR Classic program
flow restated both values in a `Define constants` block that already pointed at
the section carrying the reasoning, and that section states them again with the
argument attached. Every other appearance in the design document is
load-bearing — the worst-phase derivations are pinned by the design contract,
and the SEU argument needs both numbers to make its bit-flip point.

**Two defects the survey found on the way past.**

1. **The design contract's fourteen rules were written out twice** — once for
   the presence pass, once for the negative pass — and nothing compared the
   copies. A rule added to the first and not the second would have had no
   negative coverage while the suite stayed green and the comment above it still
   claimed the coverage was generated rather than hand-written. That claim was
   true per row and false across the pair. One table now, read by both loops,
   and it may not silently shrink. The presence pass also counts its checks,
   which it did not: fourteen real assertions were running unreported.

2. **The first version of the new residual-risk rule was vacuous, and a
   mutation found it.** It matched terms against the whole item. Replacing item
   8's headline with *"see the port assessment."* left forty lines of body still
   saying ipecmd, run, part and silicon, and the rule passed. Terms are now held
   against the item's **defining sentence**, and that vacuity is a test case.

**Both inherited pins are retired.** `TODO.md`'s residual-risk items were four
verbatim sentences plus their `**bold**` markup, and two more for the section's
standing — the last hand-typed prose pins in the tree. The numbering *is* an
interface, so it is pinned exactly and now also checks order and rejects extras;
the prose is not, so each item is held to its terms. The GCC floor's two
accepted spellings became one form family over the enforced number beside a host
`gcc` mention, excluding the cross-compiler.

The residual-risk rule carries an accept case restating all four risks in
another voice, and six reject cases: a dropped item, a renumbered one, two
reordered, an emptied one, a section that lost its standing, and the
gutted-headline vacuity. If the accept case ever fails, the gate has gone back
to pinning prose.

Gates: qualification 243 to 266 checks, preflight 318 to 323, both 0 failures.

**Nothing in the enforcement register pins prose any more.** That is now
recorded in `GOVERNANCE.md` as a property to keep rather than as a coincidence,
and the obligations for a new gate refuse a proposal that would spend it.

---

## Workstream D — Noted, not scheduled

From the meta-review. Recorded so they are not re-derived; most belong in
`TODO.md` or in its **Considered and declined** section rather than here. None
is scheduled for this branch.

- **D1 — Root-level `.adoc` documents are not scanned for the branch-only
  banner.** `release_reject_branch_only_documents` uses
  `find -maxdepth 1 -name '*.md'`, so a stray root-level `.adoc` working document
  ships silently. Small fix; candidate to fold into A2 or B3.

  **Done.** The hole was **two holes**, and only the first was the one written
  down. The gate's walk could not see a root-level AsciiDoc document, so it
  shipped — that is D1 as filed. But `_release_is_branch_only_document` also
  returned false for any non-Markdown name, and *five* of the live-tree sweeps
  have always walked `*.md` and `*.adoc` together. So the same document was
  simultaneously invisible to the gate that should refuse it and read as durable
  prose by every sweep that should exempt it, which is the opposite error: a
  working document exists in order to quote a defective form while describing
  it, and this one could not.

  The walk now takes both markups, the detector accepts both, and the banner is
  recognized in either emphasis spelling — `**bold**` is what a Markdown author
  writes, `*bold*` what an AsciiDoc author writes, and both render in either
  file. That is the rule `_release_marker_block` already applies to its own
  markers, so the file had the precedent. `DESIGN_DOCUMENTATION.adoc` and
  `TOOLCHAIN.adoc` join the durable root set; they shipped before the walk could
  see them, and naming them is what lets the walk see the working documents that
  ship beside them.

  **Not widened to every root-level file**, though the gate's own argument
  against name patterns points that way. This tree keeps a lock file and editor
  backups at its root, and a gate that failed on those would be switched off.
  The residual bound is a third markup, and it is pinned by a test rather than
  left implicit: a root-level `.txt` carrying the banner still passes.

  Four mutations, all caught: the walk restricted to Markdown, the detector
  restricted to Markdown, the banner restricted to `**` emphasis, and the two
  AsciiDoc documents dropped from the durable set. The sweep half needed its own
  probe, because `fail()` exits on the first failure and the gate cases come
  first; with the detector reverted, the topology validator refuses the AsciiDoc
  working document by name.

- **D2 — No shared test-harness library.** 32 of 51 shell tests define their own
  `fail()`, 40 roll their own `mktemp -d`, 38 maintain their own `checks=`
  counter. Self-contained tests are defensible; the inconsistent *reporting*
  discipline is the real cost, because it makes "did this run measure anything"
  hard to answer. Consider a minimal shared library, not a framework.

  **Considered and declined**, and recorded there so it is not re-proposed. The
  duplication is real and this note understated it; the cost it was proposed
  against is not real at all.

  Dividing by 51 counted the flash and stack budget checkers, the XC8 output
  parser and the mutation accounting helpers as tests. There are 43 test entry
  points. Of those, 32 define their own `fail()` -- the note's numerator, over
  the wrong denominator -- and 41 make their own `mktemp -d` and keep their own
  `checks=` counter, so the duplication is denser than 40 of 51 and 38 of 51
  suggest. But **all 43 report a check count** at the end of a run, in one
  format, and all 41 that make a temporary directory remove it in a trap. The
  inconsistent reporting discipline this item exists to fix is not there.

  **A shared test library already exists, and it sets the bar for adding
  another.** `test/scratch_tree.sh` is sourced rather than executed, and its
  header records the defect that earned it: two harnesses learned about new
  files by different means, so a missing sandbox file made the mutation runner
  report SKIP where it should have reported FAIL, and 18 mutants went unenforced
  while the summary called every mutant it did evaluate killed. That is what
  buys a shared harness here. Identical boilerplate has bought nothing
  comparable.

  What is genuinely unheld is the convention itself -- nothing requires a test
  to report a count, and nothing refuses a count of zero. That is a new gate
  over the recoverable half, and C2's proof obligations refuse it on the
  defect-class row and again on proportionality. Where the vacuity risk is
  concrete it is already closed in place: `test/test_pic_build.sh` holds its own
  check count to an expected value.

- **D3 — `CHANGELOG.md` depth is inconsistent across releases.** 4,043 lines, of
  which `0.9.7` and `0.9.8` are ~1,900 (47%), against ~40-100 lines for
  `0.9.10`-`0.9.12` under the concise policy. The policy explicitly does not
  compact existing sections retroactively, which is defensible; the effect is
  that a reader meets the first twelve releases at wildly varying depth. Decide
  deliberately: leave it, or add a one-line note at the policy boundary.

  **Done -- the note is in the file, and it is not what this item is really
  about.**

  Every figure here needed correcting first. The file is 4,663 lines. The two
  largest sections are `0.9.8` at 1,493 and `0.9.10` at 1,044; `0.9.7` is 413,
  so the ~1,900 figure is the pair's sum with the wrong half named. And
  `0.9.10`-`0.9.12` do not run 40-100 lines: `0.9.11` is 41 and `0.9.12` is 98,
  but `0.9.10` between them is the second-largest section in the file.

  **The note largely existed already.** The preamble states the policy and its
  non-retroactive carve-out. What it did not state is where the boundary falls,
  which is the reader's actual question on meeting `0.9.10` at 1,044 lines and
  `0.9.11` at 41. One sentence now names it: `0.9.11` is the first section
  written under the policy. That is checkable rather than asserted -- the
  `0.9.10` section was written a week before the policy commit and the `0.9.11`
  section the day after it.

  **The finding this item did not carry is that the policy has already stopped
  holding.** `0.9.14` runs 535 lines against 41, 98 and 83 for the three
  released sections written under it, and its content is what the policy names
  as belonging elsewhere: implementation narrative, the chronology of how each
  gate came to be wired, and design rationale restated from the documents the
  same entries cite as owning it.

  That one is fixable rather than historical, because `0.9.14` is not yet a
  historical record: there is no `v0.9.14` tag and no `release/v0.9.14/`, so the
  carve-out does not cover it and closes over it at the release cut. Filed as
  `T2-changelog-0914` with that deadline, and named in the *Start here* block as
  the one time-boxed item.

  The prose is not compacted here. Rewriting 535 lines of release notes is the
  owner's voice, on the same reasoning that kept B1 and B2 from rewriting
  sentences.

- **D4 — The PIC10F320's standing cost has no decision record.** It is the one
  part that breaks the shared-verified-core architecture: ~640 lines of the
  Makefile (7%, for one part), a dedicated 3,476-line test tree, ~2,000
  line-mentions, plus `SHELLS_WITH_OWN_COPY`, duplicated thresholds, a
  duplicated watchdog arithmetic block, its own final-HEX stack oracle and its
  own coverage archive. **Considered and declined** covers *running PIC10F320
  firmware on PIC10F322 hardware*; it does not record why the part is carried at
  all. The answer is very likely "keep it" — it ships, it is release-supported
  from `v0.9.6`, it has a field report, and dropping a released part is a
  compatibility event. Write it down anyway, with a reconsideration trigger, in
  the same form as the other declined items. ~20 min, and it stops the question
  being re-litigated every round.

  **Done.** *Drop the PIC10F320 target* is now a **Considered and declined**
  entry, beside the existing one about running its firmware on the other part.
  The costs the plan lists all check out, within the drift a few weeks buys.

  Two things changed the entry from the plan's sketch. The first is that a
  decision record already exists for the *implementation* — the design
  document's constrained-target section is the normative account of why the
  shell has to be self-contained — so the entry points at it rather than
  restating it, and confines itself to the question that account does not
  answer: whether to carry the part at all.

  The second is a claim considered and dropped. The deliberate-duplication
  register describes the shell as a second implementation whose agreement with
  the core is "agreement between two texts rather than one text observed twice",
  which reads like an argument that the part buys an independent second opinion.
  The design document refuses that framing on the same page: the seam is **the
  one trust assumption this part carries that no other target does**, mitigated
  rather than eliminated. Arguing the cost is secretly a benefit would have put
  `TODO.md` at odds with the authority that owns the question, so the entry
  argues bounded cost instead — the equivalence and lock-step lanes hold the
  shell to `src/bypass_pure.c` itself, so the sync is enforced rather than
  remembered.

  The reconsideration trigger is that enforcement failing, not the part's size.
  Size is the symptom that starts the argument every round, which is what the
  entry exists to stop.

- **D5 — `release/README.md`'s errata precede its primary audience.** Titled
  *Prebuilt firmware images*, it opens with four historical errata sections
  (lines 33-100) and reaches *"Which image do I want?"* at line 331 of 702. The
  errata are correctly retained and wrongly placed. This is the same first-run
  problem `T3-programming-guide` identifies for `MANIFEST.md`; fold it into that
  item's scope in `TODO.md`.

  **Done.** `T3-programming-guide` now carries `release/README.md` as its second
  document. One item, because it is one decision: where the reader who wants to
  flash a chip lands. The item also records the constraints on the reorder, so
  they are not rediscovered by whoever picks it up.

  **Two of the plan's figures did not survive checking.** The four opening
  sections are three errata and a *safety warning*, and that one is not
  misplaced: the images it names encode a control polarity that fails to
  ENGAGED rather than to BYPASS, and the file's opening paragraph
  forward-references it to qualify *ready-to-flash*. Demoting it below the
  trust material would be a regression rather than a fix. The errata are also
  the smaller part of the delay they are blamed for -- they run 68 lines, while
  the trust model and the release sequence between them and *Which image do I
  want?* run 267. An item that named only the errata would have sent its reader
  at the wrong target.

  The reorder is not a free move either. Headings in that file are anchors:
  `CHANGELOG.md` links one erratum's, and a gate requires `TOOLCHAIN.adoc` to
  link `#flash-a-chip`. Sections may move; they may not be retitled. The
  estimate went from 3-4 h to 4-5 h in both halves of `TODO.md`, and
  `release/README.md` itself is untouched -- this schedules the work, it does
  not do it.

- **D6 — `TODO.md` re-ranking.** 22 of 32 items are Tier 2.5, and nearly all add
  an *Nth independent witness* to a property already proven several ways
  (`T25-stack-cross` is a third stack witness; `T25-klee-path` a third
  whole-trajectory proof beside BFS and CBMC). Meanwhile **`T3-hw-procedure` —
  2-3 h — gates the entire `1.x.y` line**: `HARDWARE_VALIDATION_LOG.md` states
  that its **Procedure** field cannot be filled for *any* part until that
  document exists, so no controlled record can be complete for any part, and
  `T3-pic12f675-bench` and `T3-hil` both depend on it. It is filed in Tier 3 next
  to a 5-8 day HIL rig. Writing it needs no bench access; only executing it does.
  Promote it. Also promote `T25-cbmc-proof-count` (30-45 min, and the write-up
  already contains the correct design).

  **Done, but not by re-tiering, which would have been the wrong mechanism.**
  The prefix in each ID *is* the tier and a gate enforces the agreement, so
  moving an item between tiers means renaming it. `T3-hw-procedure` is cited in
  the Makefile, in three places in `HARDWARE_VALIDATION_LOG.md`, and in
  `CHANGELOG.md` — whose released sections are historical records that policy
  forbids editing — so a rename would leave a permanently dangling citation
  behind. The tiers are also **categories by kind of work** rather than a queue:
  Tier 3 is where silicon-facing work lives whatever it costs, and a bench
  procedure filed under Tier 2 would be misfiled rather than promoted.

  What the file actually lacked was any expression of urgency at all. The
  *Priority summary* was an index sorted by tier, despite its name. It now opens
  with a **Start here** block naming both items and why each is first, and
  saying plainly that the tiers group by kind — so the next reader is not left
  to infer a queue from a taxonomy.

  **The item's own dependency line was the real blocker, and this note
  contradicted it.** D6 says writing the procedure needs no bench access. The
  item said *"Dependencies: representative hardware and oscilloscope/logic
  analyzer"*, which is what **executing** it needs. Anyone triaging by
  dependency line would have parked a desk task behind equipment it does not
  need. The line now separates the two, which is what makes the promotion
  actionable rather than decorative.

  **Two supporting claims did not survive checking.** `T3-hil` does not depend on
  `T3-hw-procedure`; the procedure item describes itself as the no-rig
  *fallback* for the HIL rig, so they are alternatives rather than a chain. And
  the tier concentration is 22 of 33 open items, not 22 of 32. The load-bearing
  claim did hold: `HARDWARE_VALIDATION_LOG.md` states that no controlled record
  can be complete for any part until the procedure exists, and
  `T3-pic12f675-bench` names it as the reason it is blocked.

- **D7 — Mutation adequacy is asymmetric.** Mutation testing covers `src/` and
  `bypass_config.h`. The ~32,000 lines of build and release meta-tests have no
  adequacy evidence. **The recommended response is not to add Makefile mutation
  testing** — that compounds the problem. It is to state deliberately, in
  `test/README.md` or `GOVERNANCE.md`, that a release-machinery defect is
  recoverable while a firmware defect is in the field, and to size the assurance
  accordingly. Related to C2.

  **Partly done by C2.** *Proof obligations for a new gate* in `GOVERNANCE.md`
  states the asymmetry and states that the response is not to add matching
  adequacy evidence for the machinery. What remains of D7 is the sizing
  decision itself, which is unscheduled.

  **Now finished.** C2 stated the principle and left the size to be inferred
  from whatever the apparatus happened to have. `GOVERNANCE.md` now states it:
  the machinery gets contract gates over the repository, with negative cases
  drawn from spoiled copies of the live artifacts, and a replay against this
  repository's own history where a gate guards a transaction rather than a
  document. That pairing is the whole of its adequacy evidence and is meant to
  be. Two firmware techniques are withheld by name -- mutation adequacy and
  coverage instrumentation -- each with the reason it is the wrong instrument
  here rather than merely an expense.

  The size was described rather than invented: every claim in it is what the
  tree already does. The mutation runner's targets are all under `src/`, there
  is no `kcov` or `bashcov` anywhere, and `coverage` is `gcov` over
  `bypass_pure.c` and the golden-model host test.

  One claim was drafted and dropped. A third withheld technique -- checking the
  machinery by agreeing with a second implementation -- is not in fact withheld:
  the deliberate-duplication register keeps the pinned release identity spelled
  in literals precisely so it disagrees with the build variables it checks.
  Stating it would have contradicted a register row.

  `test/README.md`'s mutation section now names the scope and points at the
  decision, because that is where a reader asks why the Makefile is not mutated.
  The figure this item opened with is stale in a way worth noting: the machinery
  is not ~32,000 lines but about 64,600 across the Makefile, `scripts/` and the
  top-level gates, against 4,223 lines under `src/`.

- **D8 — `release/` growth.** 3.2 MB, 579 files, 12 releases, ~360 KB per
  release at roughly 1.5 releases per week. **Already governed** —
  `release/README.md:206-228` states *"Git is the retention authority"* and sets
  an explicit bar any pruning proposal must clear. Recorded as a watch item
  only; no action, and no reopening without meeting that bar.

- **D9 — `T25-name-contract-shim` interacts with this branch.** Five gate
  invocations pass overrides through a routing Make shim whose command word is a
  shell variable, so no axis checks them. Unchanged by this plan, but any A1 work
  that adds a new Make invocation should not add a sixth.

---

## Working rules for this branch

- **Firmware edits are the owner's.** Every task above is documentation, gates,
  Makefile or scripts. A3 and C3 touch neither `src/` nor image bytes; if any
  task starts to, stop and re-scope.
- **Keep the property, change the technique.** Any gate this branch loosens must
  name the property it protects and show where that property still fails closed.
  A gate deleted without that sentence is a regression, however green the run.
- **The branch tip is what must be green**, not each intermediate commit.
- **Delete this file before release source finalization**, moving durable
  conclusions into the documents that own them: the enforcement register and the
  new-gate obligations into `GOVERNANCE.md`, anything unscheduled from
  Workstream D into `TODO.md` or its **Considered and declined** section.
