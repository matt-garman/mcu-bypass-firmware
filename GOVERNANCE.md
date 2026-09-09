# Project Governance

How this project's documentation is owned, edited, retired, and enforced.

`README.md` is the product overview and quickstart; this document is the rules
behind it. The two are separate because they have different readers: someone
flashing a chip needs neither the authority map nor the enforcement register,
and someone changing a documented claim needs both.

## Documentation authority map

Each fact in this project has exactly one live owner. A document may link to
another authority, but it does not restate that authority's mutable data —
counts, measurements, versions, or inventories. If keeping one fact true would
mean editing two documents, the fact is in the wrong place.

| Topic | Sole live authority |
|---|---|
| Product overview and target selection | `README.md` |
| Documentation authority, lifecycle, standing rules, and what the gates enforce | `GOVERNANCE.md` |
| Normative firmware and hardware design | [DESIGN_DOCUMENTATION.adoc](DESIGN_DOCUMENTATION.adoc) |
| General operator flashing safety and workflow | [FLASHING.md](FLASHING.md) |
| Exact programming commands for one release | the generated `MANIFEST.md` in that release's own directory |
| Toolchain requirements and pins | [TOOLCHAIN.adoc](TOOLCHAIN.adoc), plus the executable pin definitions the build enforces |
| MISRA scope, deviations, and maintenance | [MISRA_COMPLIANCE.md](MISRA_COMPLIANCE.md) |
| Test layers, substrates, and aggregate entry points | [test/README.md](test/README.md) |
| Test implementation detail, fixtures, and check counts | the executable tests themselves |
| Target, variant, and resource policy | the Makefile's canonical target and variant maps, which the per-variant recipes are derived from |
| Hardware field reports and controlled qualification records | [HARDWARE_VALIDATION_LOG.md](HARDWARE_VALIDATION_LOG.md) |
| Open work | [TODO.md](TODO.md) |
| User-visible change history | [CHANGELOG.md](CHANGELOG.md) |
| Current development status | the `[Unreleased]` section of [CHANGELOG.md](CHANGELOG.md) |
| Release process, trust model, errata, and reproduction | [release/README.md](release/README.md) |
| Current release contract: version, parts, images, soaks, topology | the one bounded declaration in [release/README.md](release/README.md) |
| Exact per-release source, image, resource, and qualification results | that release's own retained record under [release/](release) |
| Scoped design decisions and per-part safety records | the topic documents under [docs/](docs) |
| Historical implementation reasoning | Git history |
| Contributor and agent working rules | [AGENTS.md](AGENTS.md), which `CLAUDE.md` includes |
| Licensing terms | [LICENSE](LICENSE) |

## Document lifecycle

Every durable documentation authority named in the map above has exactly one
label below. The label decides how it is edited and when it may be deleted;
publication as a hosted asset is a distribution fact, not a second lifecycle.

<!-- document-lifecycle:start -->
| Label | How it is treated | Where it lives |
|---|---|---|
| Live specification | Edited in place as the design changes; describes only the current state | `DESIGN_DOCUMENTATION.adoc`, `TOOLCHAIN.adoc`, `test/README.md` |
| Operator guidance | Written for someone outside the project who must act safely | `README.md`, `FLASHING.md` |
| Release policy and errata | Maintains the current release process, trust boundary, reproduction guidance, and historical safety notices | `release/README.md` |
| Compliance record | A standing claim held to an external standard | `MISRA_COMPLIANCE.md` |
| Hardware validation record | Accumulates field reports and controlled qualification records without conflating the two | `HARDWARE_VALIDATION_LOG.md` |
| Change record | Adds prospective and dated release entries; existing release sections remain historical accounts | `CHANGELOG.md` |
| Open-work register | Edited as work is opened, refined, or completed; it is not an archive of finished work | `TODO.md` |
| Decision/safety record | Explicitly scoped reasoning that stays useful after the work is finished | the topic documents under `docs/*.md` |
| Contributor policy | Maintained rules for people and coding agents working in this tree | `AGENTS.md`, `CLAUDE.md`, `GOVERNANCE.md` |
| Legal terms | Preserved licensing authority for the project | `LICENSE` |
| Release result record | Source-bound provenance and observed evidence. The tag fixes the original bytes; a current-tree copy may differ only by the registered safety-amendment process in `release/README.md` | `release/<version>/QUALIFICATION`, `release/<version>/MANIFEST.md`, `release/<version>/README.md`, `release/<version>/evidence/*` |
| Release payload artifact | Firmware and required programming helpers; their signed byte identity is never corrected in place | `release/<version>/*.hex`, `release/<version>/flash-*.py` |
| Release authentication record | The checksum list and its detached signature; retained byte-for-byte | `release/<version>/SHA256SUMS`, `release/<version>/SHA256SUMS.asc` |
<!-- document-lifecycle:end -->

Branch-only work plans are not durable authorities. They carry the required
opening banner, coordinate one branch, and are deleted before release source
finalization; the release gate refuses any that survives.

## Documentation standing rules

- **Git history is the archive.** A completed plan or work journal is deleted
  from the branch tip once its durable conclusions have been moved into the
  document that owns them. Retaining the journal beside the specification it
  fed produces two accounts of the same subject, one of which stops being
  true.
- **Current measurements belong to CI output or retained release evidence**,
  not to development prose. A number that changes when the code changes has no
  stable owner in a hand-edited document.
- **Generated human views are not independently maintained.** Where a document
  is rendered from canonical data — per-release programming guidance, resource
  tables, release manifests — the generator and its input are the authority.
  Correct the input, never the rendered copy.

## Enforcement register

The map above says who owns each fact. This says which of those facts are held
by a gate, how, and what defect motivated it -- because a rule whose purpose is
unrecorded is a rule the next author edits rather than satisfies.

What it takes to add a row is the last section of this document.

### How to read it

Three techniques survive A1–A3, and none costs the author a word:

| # | Technique | What it holds | Author may freely change |
|---:|---|---|---|
| 1 | **Fenced claim** — named marker pair plus required term groups | that the claim's load-bearing terms are all still present | every word, order, emphasis, wrapping |
| 2 | **Form-family ban** — one ERE over flowed text | that a *false* claim is not made in any spelling of its family | anything that is not that claim |
| 3 | **Structural / derived** — presence, ordering, agreement, or rendering | shape and single-ownership, never phrasing | all prose around it |

A term group is an alternation matched case-insensitively on whole words, over
the block's text with markup flowed away. A single word is just a keyword, so
keyword sets and form families share one implementation. The two techniques the
project used to rely on — requiring a verbatim sentence, and requiring a
verbatim line — are **retired**: A1 made the derived release lines machine-
written, A2 converted the prose pins, A3 took the last one.

**Adding a row to the ban table has a catch.** This document is durable, so
every ban below is enforced *against this document too*. A branch-only working
document may quote a defective form while describing it; this one may not. Some
bans blank quoted and code spans, so quoting is enough there — but the ipecmd
denial deliberately strips backtick *characters* rather than blanking their
span, precisely so a code span cannot smuggle the claim through. For that one,
and for any future ban built the same way, the row must **describe** the form
rather than reproduce it. This was found the way such things should be: by the
gate, on the commit that first published the register.

### 1. Fenced claims

Deleting a fence is not a shortcut around these: an absent fence and a malformed
one fail identically, and both name the marker.

| Marker | Owning document(s) | The claim it owns | Defect that motivated it |
|---|---|---|---|
| `qualification-status` | `README.md` | controlled hardware qualification is outstanding, and what that term requires | the pre-v0.9.10 conflation of field use with controlled qualification |
| `controlled-qualification` | `HARDWARE_VALIDATION_LOG.md` | every controlled record carries all eleven required fields | a run missing any field is a field-use report however careful; without the fields a reader can neither reproduce it nor bound what it missed |
| `field-reports` | `HARDWARE_VALIDATION_LOG.md` | field use is recorded apart from qualification, and **before** it | the ordering is checked, so the two kinds of evidence cannot merge by editing |
| `pic12f675-helper-required` | `README.md`, `FLASHING.md` | the part needs the release helper because per-device factory calibration must be preserved **and verified** | a raw programmer write destroys the part's only copy of its factory trim — a hardware hazard, not bookkeeping |
| `pic12f675-helper-status` | `README.md`, `FLASHING.md`, `release/README.md` | the `ipecmd` route is published **and** software-tested **and** not hardware-qualified | `FLASHING.md` published the procedure while `README.md` and `TOOLCHAIN.adoc` denied one existed; a reader believing either was misled about the other |
| `pic12f675-disposition` | `DESIGN_DOCUMENTATION.adoc` | release-supported from `v0.9.9`, not hardware-qualified, deferred to `T3-pic12f675-bench` | the gate anchored on the opening words *"A third PIC, the PIC12F675,"*; `4d85ad7` rewrote the paragraph and silently emptied the scan |
| `pic10f320-flash-overrun` | `DESIGN_DOCUMENTATION.adoc` | the modular architecture overruns the 256-word ceiling, measured not assumed | A3 — the passage was byte-pinned, and its provenance clause was itself the mitigation for a measurement sitting in durable prose |
| `pic10f320-recorded-omission` | `DESIGN_DOCUMENTATION.adoc` | which context check was left out, and that the reason was capacity | the part ships a general defence its 256 words could not hold; without the reason the omission reads as an oversight to fix |
| `pic10f320-assurance-seam` | `DESIGN_DOCUMENTATION.adoc` | what the assurance package does **not** establish | losing it turns a hand-inlined part's behavioural argument into a byte-identity claim it never made |
| `image-attestation` | `release/README.md` | what reproducing an image publicly attests | reproduction proves bytes match tested source; it does not qualify firmware, and this block is the only thing between the two claims |
| `historical-images` | `release/README.md` | why superseded images stay published | retaining a known-unsafe image for reproducibility is not endorsing it |
| `document-lifecycle` | `GOVERNANCE.md` | the lifecycle table and its authority column | the rule was anchored on the literal heading `### Document lifecycle`; capitalizing one letter failed five tests, four of them self-tests using the live README as their control fixture |

### 2. Form-family bans

Each bans a *false* claim in every spelling of its family, over flowed text so a
rewrap or an adjective swap does not evade it.

| Ban | Scope | Defect that motivated it |
|---|---|---|
| attributive `hardware-qualified <noun>` | every durable document, **while the sentinel stands** | the predicate cannot be banned: every true sentence here *is* its negation. Adjective-plus-noun has no negated spelling, which is what makes it decidable. A floor, not a proof — and it lifts by itself when the sentinel goes |
| a blanket denial that any `ipecmd` procedure has been published — described here rather than quoted, because quoting it *is* making it | durable documents | the B6 contradiction. Deliberately still permits a claim **scoped to a route**, which is true of the Make-based goals and must stay sayable |
| three retired programming claims | durable documents | *"Needs only a programmer and its CLI"*, *"needs no toolchain at all"* — each false once the helper became required |
| raw-writer `ipecmd` commands | **command contexts only** — fenced, listing, literal, indented, inline spans | a published raw write destroys factory calibration. Prose *mentioning* a tool is not a published command, so the scan reads contexts, not sentences |
| current release topology | `DESIGN_DOCUMENTATION.adoc`, `TOOLCHAIN.adoc` | part/image/soak counts with two owners drift; the bounded declaration in `release/README.md` is the single owner |
| unbound measurements | `DESIGN_DOCUMENTATION.adoc`, `TOOLCHAIN.adoc` | results that change when the source changes have no stable owner in a hand-edited document |
| dates and source revisions | `DESIGN_DOCUMENTATION.adoc` | A3 — pinning provenance is the mitigation a misplaced measurement asks for, so removing the measurement has to close that door behind it |

### 3. Structural and derived

| Rule | Property | Defect that motivated it |
|---|---|---|
| bounded current-release declaration | exactly one, in `release/README.md`, agreeing with the canonical inventory | a second declaration elsewhere — even one that agrees today |
| derived release lines | changelog heading, both compare links, contract and transition lines are **rendered**, not validated | A1 — seven hand-edited lines, every one a pure function of three inputs, took four commits and a 22-line test edit to get right |
| root document allowlist | any root-level `.md` outside the durable set fails the release unless it carries the branch-only banner | adding one name pattern per working document is exactly how the gate came to miss `pre-v*-fixes.md`. An allowlist fails closed |
| branch-only banner | declared working documents must be deleted and de-referenced before a release cut | a release is cut from main; none may survive there |
| GCC floor agreement | `README.md`, `TOOLCHAIN.adoc` and `test/README.md` agree with `MINIMUM_GCC` | the enforced floor and the published floor must not drift |
| design contract (14 ordered patterns) | safety-relevant numbers keep every figure and every part association | one pin broke when a `.` became a `;`. Negative coverage is generated from the table: delete the span a rule matches and it must stop matching |
| `T3-pic12f675-bench` enumeration | the four open silicon-only risks stay complete and in one place | the Makefile, CI notes and release documentation cite them by number; dropping one stops tracking a risk while every citation still reads as though it were tracked |
| lifecycle authorities | every shipped document has exactly one declared kind | a document with no owner is a document nobody has to keep true |

### 4. Known remaining pins, and why they were left

Two places still hold prose to an exact spelling. Neither is an oversight; both
are recorded here so they are decided rather than inherited.

1. **`TODO.md`'s six `T3-pic12f675-bench` strings**, including their `**bold**`
   markup — e.g. ``**1 - bandgap calibration bits (`BG<1:0>`) preserved on
   program.**``. Half of this genuinely *is* an interface: the Makefile, the CI
   notes and the release documentation cite these residual risks **by number**,
   so the enumeration must stay complete and stably numbered. What is **not**
   an interface is the bold markup and the exact phrasing around each number.
   The numbering should stay pinned; the prose around it should become a fenced
   claim per item.

2. **The GCC floor's two accepted spellings**, `GCC <n> or newer` and
   `Minimum host gcc version: <n>`. Listing acceptable spellings is the same
   antipattern A2 retired everywhere else: *"GCC 10+"* or *"at least GCC 10"*
   publishes the identical requirement and fails the gate. The real property is
   only that *gcc appears near the enforced number*, which one form family
   states directly.

Both are small, both use machinery that already exists, and neither blocks
anything. They belong in C3's survey rather than in an unrecorded backlog.

### 5. The rule this register exists to make sayable

> A gate failure names a **property**, not a preference. Before editing a gate,
> find the property in this register. If the property is wrong, change it here
> first and say why. If the property is right, the document is what changes.

That sentence is the whole point of A5. Every pin this branch retired was
retired because an author hit a gate, could not tell what it was protecting, and
had no cheaper repair available than editing the rule.

## Proof obligations for a new gate

`test/README.md` states what a change under `src/` must re-establish: the
property first, then the commands whose evidence discharges it. This is the
inverse list. A firmware change has to satisfy properties the tree already
holds; a new gate proposes to add one, and the proposal carries the burden.

Adding a gate is the easiest change in this repository to justify and the
hardest to undo. It is always defensible in isolation, because it closes
something. It is never obviously wrong later, because a gate that has never
fired looks exactly like a gate that is working. The apparatus that establishes
this firmware is now many times the size of the firmware itself, and it grew
that way one defensible gate at a time. Each obligation below is discharged in
writing, before the gate is written -- not by the gate passing.

| Obligation | What the proposal must establish | What discharges it |
|---|---|---|
| **The defect class, named** | A specific way this tree can be wrong that the gate makes impossible, or makes loud. Not a preference, not a style, not a class of untidiness. | A sentence fit to stand in the register's *defect that motivated it* column, written first. The strongest name the commit or the release where the defect actually happened. A proposal that can only describe a hypothetical says so plainly, and is held to a higher bar on cost. |
| **That removal was considered first** | That the fact cannot be deleted, derived, or generated instead of guarded. | The fact's owner, named from the authority map, and the reason a second copy has to exist at all. Where it does not, the change is a deletion and no gate is added. `test/test_resource_tables.py` is the worked example: documents restating measured figures were held synchronized by a gate until the figures were removed instead, and the checker now measures images rather than reading prose. Keeping copies synchronized treats the symptom. |
| **That no existing gate closes it** | Which existing rule comes closest, and the exact case it lets through. | A named row of the register above, or a named test, plus the input that passes today and should not. "Nothing covers this" is not an answer until the register has been read. |
| **A technique from the table** | Which of the three surviving techniques it uses, and that the author keeps every word. | The technique named, with its inputs: a marker pair and its term groups for a fenced claim; one expression over flowed text for a ban; the shape, ordering or agreement being held for a structural rule. A proposal that needs a verbatim sentence or a verbatim line is refused. Those two were retired deliberately, and reintroducing one spends the author's voice on a check the other three can make. |
| **A failing case, not only a passing tree** | That the gate rejects the defect, and rejects it for the stated reason rather than incidentally. | A negative case per rule, exercised against a spoiled copy of the real document or artifact rather than a fixture that has since drifted from it. This is already the practice here -- the documentation contracts run against mutated copies of the live documents, and the design contract generates its negative coverage from its own table. It is what separates a gate from a comment. |
| **Skip behaviour declared** | Whether the gate can be absent and still let a run report success, and what turns that absence into a failure. | Registration in `test/test_strict_tools.sh` whenever the gate needs a tool, device pack or virtual environment that may not be installed, so `STRICT_TOOLS=1` fails rather than quietly reducing coverage. A gate that can go silent without saying so is worse than no gate, because it reports assurance it is not providing. |
| **The cost of keeping it** | What it reads, what it needs installed, how long it runs, and who has to edit it when the tree changes for good reasons. | An explicit answer to: *what ordinary, correct change makes this fire?* A gate whose false-positive case is a normal edit will be edited until it stops firing, and that is precisely how a rule becomes something the next author satisfies by weakening it. |
| **Proportionality to where the defect lands** | That the assurance is sized to the consequence rather than to the ease of checking. | The asymmetry stated below, applied to this gate and written down. |
| **A register row, and a stated purpose in the file** | That the gate's reason survives the person who added it. | A row added to the enforcement register above in the same change, and a header in the test file itself naming the defect class it closes and what it deliberately does not check. `test/test_deliberate_duplication.py` and `test/test_resource_tables.py` are the model. Many test files already open this way; this obligation is what makes it the rule rather than the habit. |
| **A retirement condition** | What would make the gate unnecessary, and what happens when that arrives. | A stated condition, enforced where it can be. The attributive qualification ban is the worked example: it is conditional on the sentinel, so it lifts by itself on the commit that records the first controlled run, rather than depending on someone remembering to remove it. |

**Where a defect lands is not symmetric.** A defect in `src/` reaches a part
someone has already soldered into a pedal, and the repair is a reflash by a
person who may never learn there was anything to fix. A defect in the Makefile,
the release scripts or this documentation is caught by the next run or the next
reader and repaired in a commit. Both are worth catching. They are not worth
the same assurance -- and the recoverable half is far cheaper to test, which is
exactly why the apparatus grows there fastest.

The response to that asymmetry is **not** to add matching adequacy evidence for
the build and release machinery. That spends the effort on the recoverable half
and widens the gap it was meant to close. It is to size the assurance to the
consequence, and to say so plainly wherever the result is deliberately uneven.

**Clearing this list is necessary and not sufficient**, and the list itself is
held by review rather than by a gate. That is deliberate, and it is the first
obligation applied to itself: no gate has yet landed that this list would have
refused, so the defect class is unproven and the machinery is unearned. When
one does land, that is the defect -- and it goes in the register.
