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
| A1 | Render the mechanical release edits instead of validating them | Strictness | 4-6 h | open |
| A2 | Convert verbatim prose pins to marker blocks + keyword sets | Strictness | ~1 d | open |
| A3 | Move the pinned measurement out of the design document | Strictness | 1 h | open |
| A4 | Reconcile README with the gates that survive A2 | Strictness | 1 h | open |
| A5 | Write down the enforcement register | Strictness | 2 h | open |
| B1 | Restructure README for its two audiences | README | 3-4 h | open |
| B2 | Create the governance document | README | 2-3 h | open |
| B3 | Plumb the new document through the gates | README | 1 h | open |
| C1 | Allowlist gate for derivable release numbers | Anti-drift | ~1 d | open |
| C2 | Obligations for a new gate | Anti-drift | 1 h | open |
| C3 | Threshold restatement survey | Anti-drift | 2 h | open |
| D1-D9 | Noted, not scheduled | — | — | see below |

Ordering: **A1 and A2 first.** Everything else in A and B is easier once the
release ritual and the prose pins stop fighting ordinary editing. C is the
round's durable output and can proceed in parallel. D is a holding area — most
of it belongs in `TODO.md` or in **Considered and declined**, not here.

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
| Verbatim sentence, requiring | `bounded_claims` (7), the programming claim (2 documents), the helper status (3 documents) | total |
| Verbatim line, requiring | the CHANGELOG compare links, the contract line | total |

`_release_flowed_text` collapses whitespace, so **rewrapping survives and
rewording does not** — precisely the operation this branch exists to perform.

The project already reached the right conclusion once, at
`release-documentation.sh:1269-1272`:

> *the same false claim survives an editor's rewrap and an adjective swap; what
> it deliberately does NOT ban is a claim SCOPED to a route*

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

### A4 — Reconcile README with the gates that survive A2

Four assertions are currently red on this branch from the voice rewrite
(`b3fa0bd`..`6964a00`). Expected and acceptable on a branch; they must be green
before merge. Resolve them **after** A2, so the reconciliation is done against
the loosened technique rather than against the byte-pins being retired:

1. `### Document Lifecycle` vs. the literal `"### Document lifecycle"` —
   `test-reference-contract`, 5 failures including all three negative cases,
   which read the live README.
2. The dropped *no controlled hardware qualification* bounded claim —
   `test-release-preflight`, and `release`.
3. The dropped exact downloaded-release programming claim (PIC12F675 requires
   Python 3 and the helper).
4. The dropped helper status (published, software-tested, not
   hardware-qualified).

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

### A5 — Write down the enforcement register

Today the knowledge of *which claims are gated, by which technique, and why*
exists only in shell comments inside `scripts/release-documentation.sh`. Hitting
a gate tells you what broke but not what property it was protecting, which is
why the reflexive repair is to edit the gate.

Produce a table: claim, owning document, technique, the defect that motivated
it. It lands in the governance document (B2), not in the README.

Size: 2 h. Depends on A2 (the table describes the post-conversion state).

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

### B2 — Create the governance document

`GOVERNANCE.md` receives: the authority map's *reasoning*, the document
lifecycle table, the documentation standing rules, the branch-only working
document contract, and the enforcement register from A5.

This is also the natural home for C2.

Size: 2-3 h.

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

---

## Workstream D — Noted, not scheduled

From the meta-review. Recorded so they are not re-derived; most belong in
`TODO.md` or in its **Considered and declined** section rather than here. None
is scheduled for this branch.

- **D1 — Root-level `.adoc` documents are not scanned for the branch-only
  banner.** `release_reject_branch_only_documents` uses
  `find -maxdepth 1 -name '*.md'`, so a stray root-level `.adoc` working document
  ships silently. Small fix; candidate to fold into A2 or B3.

- **D2 — No shared test-harness library.** 32 of 51 shell tests define their own
  `fail()`, 40 roll their own `mktemp -d`, 38 maintain their own `checks=`
  counter. Self-contained tests are defensible; the inconsistent *reporting*
  discipline is the real cost, because it makes "did this run measure anything"
  hard to answer. Consider a minimal shared library, not a framework.

- **D3 — `CHANGELOG.md` depth is inconsistent across releases.** 4,043 lines, of
  which `0.9.7` and `0.9.8` are ~1,900 (47%), against ~40-100 lines for
  `0.9.10`-`0.9.12` under the concise policy. The policy explicitly does not
  compact existing sections retroactively, which is defensible; the effect is
  that a reader meets the first twelve releases at wildly varying depth. Decide
  deliberately: leave it, or add a one-line note at the policy boundary.

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

- **D5 — `release/README.md`'s errata precede its primary audience.** Titled
  *Prebuilt firmware images*, it opens with four historical errata sections
  (lines 33-100) and reaches *"Which image do I want?"* at line 331 of 702. The
  errata are correctly retained and wrongly placed. This is the same first-run
  problem `T3-programming-guide` identifies for `MANIFEST.md`; fold it into that
  item's scope in `TODO.md`.

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

- **D7 — Mutation adequacy is asymmetric.** Mutation testing covers `src/` and
  `bypass_config.h`. The ~32,000 lines of build and release meta-tests have no
  adequacy evidence. **The recommended response is not to add Makefile mutation
  testing** — that compounds the problem. It is to state deliberately, in
  `test/README.md` or `GOVERNANCE.md`, that a release-machinery defect is
  recoverable while a firmware defect is in the field, and to size the assurance
  accordingly. Related to C2.

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
