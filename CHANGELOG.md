# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project stays on the `0.9.x` pre-1.0 series while the firmware and its
validation suite settle. The criterion for leaving it is explicit: **`1.x.y`
begins once these designs complete controlled hardware qualification.**
Everything shipped so far is validated by simulation, formal proof and static
analysis — thorough, and not the same claim as "this part passed a bench run
whose procedure, configuration bytes and measurements are on file". Released
images have been flashed and reported working by builders, and those field-use
reports are recorded in
[HARDWARE_VALIDATION_LOG.md](HARDWARE_VALIDATION_LOG.md); that file also states
what a controlled record must retain, and that no part has one. Until that
changes, new work lands as `0.9.x` however large it is; the merge of a whole
additional MCU target in `0.9.6` rather than `0.10.0` is that rule applied, not
an oversight.

Per-release provenance (source commit, pinned toolchain, image hashes, flash
usage, and validation evidence) lives in `release/<version>/MANIFEST.md`; this
file is the human-readable summary of *what changed*.

Prospective entries stay concise. `[Unreleased]` is the normal development
state, and each release moves its relevant summary from there into a dated
section. Record user-visible behavior, safety or compatibility changes, new
targets or release artifacts, important fixed defects, material residual
limitations, and any migration action users must take. Keep implementation
journals, exhaustive test inventories, review chronology, current resource
measurements, and duplicated design rationale in Git history or their dedicated
design, test, and release records instead. `0.9.11` is the first section written
under this policy. Earlier sections are being brought to it one at a time, which
reverses the original decision to leave them at the depth of their time: what
the list above says to record is kept, and the implementation narrative around
it goes to Git history, reachable through each section's compare link. The
signed tag for each release is unchanged, so a tag and this file may describe
the same release at different lengths.

> **On the PIC10F320's version history.** The PIC10F320 target was developed in a
> separate repository and merged into this one in `v0.9.6` below. That
> project ran its own `v0.9.0`–`v0.9.5` series with **different content and
> different dates** from the identically numbered releases in this file — its
> `0.9.5` is dated 2026-07-10, this project's 2026-07-18. Those entries are
> therefore **not** back-filled here: doing so would collide two unrelated
> numbering lines and misreport each project's history as the other's. The child
> timeline remains reachable in full through the imported commit graph and the
> namespaced signed tags `pic10f320/v0.9.0` … `pic10f320/v0.9.5`. From the first
> unified release onward there is one timeline, with PIC10F320 changes recorded
> as a sub-lane inside each entry.

## [Unreleased]

### Added

- **`GOVERNANCE.md`**, owning how this project's documentation is authored,
  owned, retired and enforced, down to the proof obligations a proposed gate
  must discharge in writing before it is written. That material was split
  between `README.md` and comments inside the release validator, where a rule's
  purpose was not readable by the author who hit it.

### Changed

- **`README.md` addresses its two audiences separately.** Flashing a released
  image and building from source are peer sections, and the file closes with a
  signpost naming every other document and what it is for.
- **Release topology is declared once and derived rather than restated.** How
  many parts, images, soak combinations, modular targets and shell source files
  a release contains is stated only in `release/README.md`, and the gate
  protecting that ownership now derives those values from the Makefile's
  canonical sets rather than hand-written copies, so it refuses any spelling of
  a restatement rather than the ones someone thought to list.
- **Earlier `CHANGELOG.md` sections are being rewritten under the concise-entry
  policy.** `0.9.11` was the first section written under it. Rather than leave
  the sections before it at the depth of their time, each is brought to the
  policy in turn: what the policy says to record is kept, and the implementation
  narrative around it goes to Git history, reachable through each section's
  compare link. Signed tags are untouched, so a tag and this file may describe
  the same release at different lengths.

### Fixed

- **A root-level AsciiDoc working document could reach a release unseen.** The
  branch-only banner was recognized only in Markdown, so an AsciiDoc note at the
  repository root escaped the root-document allowlist while the live-tree sweeps
  still held it to the very bans a working document exists to be exempt from.
  The banner is now read in either markup and either emphasis spelling.

## [0.9.14] - 2026-09-08

### Added

- **A release now records what its soak result is valid for.** Published images
  were byte-identical across `v0.9.10`, `v0.9.11`, `v0.9.12` and `v0.9.13`, and
  no soak driver changed over that span, so three consecutive releases re-ran
  the same binaries under the same harness in the same simulators. Nothing
  recorded that, so each paid the full duration to re-derive a result it already
  had. `SOAK_KEY` is a new signed provenance file naming every input that can
  change what a soak observes: the exact artifact each of the 18 combinations
  drove -- ELF, shipped HEX, or for the PIC12F675 the derived simcal image it
  actually runs -- the soak driver sources each lane declares in the Makefile,
  and the identity of every tool that executes a soak. `QUALIFICATION` gains
  `soak_inputs_sha256` (`format=8`) and `MANIFEST.md` publishes it.

  Its payload deliberately carries no version, date or commit, because a
  release that changes only prose must produce the *same* key; the producing
  commit sits on the result line, outside the hashed payload, and the verifier
  refuses a payload that binds itself to a release identity. Equally
  deliberately, the image-producing compilers are not in the key -- the images
  are hashed directly, so naming XC8 and avr-gcc again would only invalidate
  soaks when an unrelated toolchain row moved. Nothing consumes the key yet;
  this records it. [`docs/release_proportionality.md`](docs/release_proportionality.md)
  Part 3 is the design.

- **`CI_GOALS` names the gates each CI job runs.** Parity between the local path
  and the hosted runner was an assertion in a comment: `scripts/ci-local.sh`
  reconstructed `ci.yml`'s jobs from a prose header, `release.yml` kept its own
  list and `test/README.md` a third, and nothing machine-checked that the local
  path covered the remote one. `ci-verify`, `ci-stress`, `ci-pic`, `ci-mutation`
  and `ci-attiny202` are exact wrappers of the commands those jobs run today,
  owning gate composition and fixed policy -- `STRICT_TOOLS`,
  `MUTATION_ALLOW_SKIP`, the image assertion and the soak's PASS-count check
  that were loose shell in a `run:` block no local run executed. They
  deliberately do not own the host paths or the independent CI pins, and a goal
  refuses to run when a pin it names was not supplied on the command line:
  `$(origin)` distinguishes a caller's pin from this file's default, so a
  workflow that dropped one fails instead of silently agreeing with the default
  it was meant to be checked against.

  The `verify` and `stress` jobs now invoke `ci-verify` and `ci-stress`, and
  `scripts/ci-local.sh`'s pull-request path invokes the same `ci-verify` the
  hosted job does rather than an equivalent spelling. Wiring a job is not
  separable from the gate that checks it: `test/test_workflow_syntax.sh` locates
  each job's step by its literal command and anchors seven ordering assertions
  to whatever it finds, so the goal, the detection, and the policy assertions
  the step used to satisfy all move together -- the last against the goal's
  recipe, through a new `ci_goal_recipe()`, or they would retire silently. The
  remaining jobs (the mutation gate, `attiny202`, `build-matrix`) follow the
  same pattern; [`docs/ci_parity.md`](docs/ci_parity.md) records it.

  The `pic` job followed: five steps became one `make ci-pic`, and
  `scripts/ci-local.sh` runs that same goal rather than five equivalent
  spellings of it. The five-process boundary -- each PIC aggregate in its own
  Make graph, with the PIC12F675 pair sharing the last one so its retained
  matrix is qualified once -- is now described in one place and asserted
  against the recipe, so both surfaces are held to the same description. Two
  hazards surfaced that inspection would not have: a goal *invokes* its gates
  rather than depending on them, so recipe commands are invisible to Make's
  prerequisite database and every reachability check asked through a wrapper
  passes vacuously unless the edge set is seeded with them; and an assertion
  that locates a workflow step by its `name:` goes quiet, not red, when that
  step is folded away. Both are fixed structurally and recorded in the design
  doc.

  The mutation gate followed, and those seeded edges paid for themselves. The
  rule that exactly one normal-CI path may run mutants was a match against the
  literal goal names `test-mutation` and `test-long`; it is now a reachability
  question -- which invocations can reach `test-mutation` at all -- which also
  catches a second wrapper rather than only a second literal. The fail-closed
  policy itself (`MUTATION_ALLOW_SKIP=0`, so a mutant that skips for want of a
  toolchain fails instead of passing green) moved into `ci-mutation` with the
  reasoning beside it. Both replacements were checked against deliberately
  broken trees rather than assumed: a stray second mutation path and a deleted
  `MUTATION_ALLOW_SKIP=0` are each reported by name.

  The `attiny202` job showed that one job does not always mean one goal. It has
  two out-of-apt inputs with different jobs -- the vendored ATtiny_DFP
  *compiles* the image, the patched yasimavr venv *runs* it -- and the workflow
  provisions them in that order, caching the DFP once the images are proven and
  only then paying for a simulator build. Folding its four gate steps into one
  goal would have destroyed that: a broken image would be found after the venv
  build rather than before it. It converts to two goals,
  `ci-attiny202-build` and `ci-attiny202-target`, split where the toolchain
  boundary already sat, with the gate asserting the build half runs first.

  Both assertions that job carried as loose shell -- that every declared image
  was actually built, and that the soak reported one PASS per supported variant
  -- moved into the goals and are now themselves checked; nothing had been
  watching them before. Each was verified by deletion. `scripts/ci-local.sh`
  loses its own copy of the soak count, which is the point: a local count that
  could drift from the hosted one is the failure this work exists to prevent.
  The soak transcript now lands under `build_avr_xt/`, gitignored and removed
  by `make clean`, so running the goal locally no longer dirties the tree.

  Running the goal for real found a defect that had been shipped, dormant, in
  the `CI_GOALS` commit: the soak lane used `set -o pipefail`, which is a
  bashism, and Make recipes run under `/bin/sh`. It had worked as a workflow
  `run:` block only because GitHub Actions runs those under bash. The soak is
  now redirected rather than piped, so the sub-make's own exit status governs
  and the Makefile keeps the POSIX-shell recipes it has everywhere else. This
  is the argument for executing a new goal rather than reading it: the goal
  parsed, passed every structural check, and could not have run.

  `build-matrix` completes the set, and is the first conversion that bought
  coverage rather than preserving it. Its rows selected work through workflow
  expressions (`make ${{ matrix.build }}`) that literal command parsing cannot
  resolve, so the gate pinned a reviewed list of `{mcu, build, size}` triples --
  a second hand-kept copy of what the Makefile already knew, checked against a
  third copy in the test. A row now carries only the part name;
  `ci-build-classic` derives the build and size targets from a pin it validates
  against `CI_CLASSIC_PARTS`, which is itself derived from the `TINYX5` list
  that generates those targets. So the question the gate asks is whether the
  workflow covers the parts *Make* declares. Adding a classic AVR part to the
  Makefile now fails the gate until the matrix covers it; before, the two lists
  could quietly agree to be stale. `scripts/ci-local.sh` reads the same list
  instead of naming the three parts, and its per-part size report lands under
  `build_avr_classic/` rather than the repo root.

  **The release workflow now shares CI's PIC gate outright.** `release.yml`
  runs different work from CI, not the same work differently: it rebuilds every
  image from the tagged source, re-runs `test-long` with the flashing-helper
  gate pointed at those rebuilt images rather than the previous release's
  shipped HEXes, and deliberately does not soak -- qualification soaks belong to
  `scripts/make-release.sh` and run for their full duration before the tag
  exists. So it gets `release-rebuild`, `release-test-long` and
  `release-attiny202`, declared in a new `RELEASE_GOALS`.

  The exception is the PIC gate. Release's five PIC steps were already
  byte-for-byte the same commands `ci-pic` runs -- the workflow contract proved
  it by checking both against one shared tuple. Release now invokes `ci-pic`,
  which turns "these two lists match" into "there is one list": the public
  attestation re-runs the identical gate normal CI runs, by construction rather
  than by coincidence. Eight steps became three.

  Two things the goals now hold that no check previously watched: that
  `release-rebuild` starts from `make clean` (a reproducibility claim is about a
  build from nothing -- a rebuild that skipped the clean would compare committed
  images against whatever was on disk), and that it covers the parts
  `CI_CLASSIC_PARTS` declares rather than a list of its own. Both were verified
  by deletion.

  **The local mirror now executes the inventory instead of describing it.** The
  last hand-kept copy was `scripts/ci-local.sh`'s CI-JOB MAPPING header: a prose
  block naming each `ci.yml` job, which this gate checked for set-equality with
  the workflow's job ids. That proved someone had typed each job's name into a
  comment. It never proved anything ran, and the script's actual sequence was a
  hardcoded list of steps beside it.

  The Makefile now declares `CI_LOCAL_SEQUENCE` -- the goals the script invokes,
  in the order a serial run needs them -- and the script reads it and dispatches
  each entry to a handler. A local push does not invoke every CI goal: it covers
  `verify`, `stress` and the mutation gate with one `make test-long`, since
  those three re-aggregate one shared host suite. So the sequence has a declared
  complement, `CI_LOCAL_FOLDED`, and the two must PARTITION `CI_GOALS`. Deriving
  the folded half as "whatever is left over" would have been the wrong default:
  it silently assumes a NEW goal is already covered, which is the drift being
  removed. The Makefile refuses to PARSE when the partition fails -- a refusal
  rather than a check, because the script reads both lists through
  `make print-...`, so it cannot run, or even ask, while the claim is false.

  The `make test-long` fold is no longer a comment either. Each folded goal's
  target must be *covered* by `test-long` -- not reachable from it, which it is
  not and must not be, since `test` and `test-long` are sibling aggregates over
  overlapping gate sets rather than one built on the other. The check asks
  whether everything the folded target pulls in is also pulled in by
  `test-long`; a gate `test` runs and `test-long` does not would be a gate CI
  runs and a local push silently never does.

  Both directions of the handler correspondence are load-bearing, and both were
  confirmed by deletion. Without the forward check, a sequence naming a goal
  with no handler runs every other gate first and dies an hour later on a bare
  `command not found`; without the reverse, a handler outlives the goal it
  served and nothing calls it. Both run before the toolchain preflight, for the
  same reason the preflight was hoisted ahead of the jobs: a mirror that is
  incoherent about what it will do should say so in the first second.

  Five prose-mapping checks retired. What replaced them is a chain that is
  strictly stronger: every `ci.yml` job must invoke a non-empty subset of
  `CI_GOALS` (so a job reaching a gate directly is caught), the goals `ci.yml`
  invokes must equal `CI_GOALS` exactly, that must partition into the two local
  lists, and every sequenced goal must have a handler. A job added to `ci.yml`
  can no longer exist without a local counterpart, where before it only had to
  be mentioned in a comment.

  **The artifact-commit verifier dispatches through a declared goal.** The last
  gate composition in the release path that lived in a shell script was
  `scripts/verify-release-artifact-commit.sh`'s `make $gates STRICT_TOOLS=1
  <pins>`, assembled at run time and therefore readable by nothing. It is now
  `release-artifact-gates`: which gates (`RELEASE_ARTIFACT_GATES`, by name, so
  the two cannot diverge), what policy (`STRICT_TOOLS=1`, the whole of what the
  goal owns), and a refusal to run at all on an empty inventory rather than
  proving a release publishable by running nothing.

  It is the one declared goal no workflow invokes, and none can -- the artifact
  commit does not exist until an operator has committed by hand, after
  `make-release.sh` has finished -- so it lives in a new `RELEASE_PATH_GOALS`
  rather than `RELEASE_GOALS`, which keeps meaning "what `release.yml` runs" and
  stays checkable against that file.

  Moving the composition found what reading it would not have. The script handed
  those gates `release.yml`'s three independent pins, and not one of the eight
  reads any of them -- not in its recipe, not in the script it runs. What they
  did do was arrive at the gates' own nested Makes as *environment* origin,
  which is unreviewed build input by the release guard's own definition;
  `test-release-preflight`, a member of the list, scrubs inherited build-input
  names before its first case for exactly that reason. So the goal takes no
  pins, the script no longer parses `release.yml` at all, and that emptiness is
  asserted from both ends: the goal must require no pin, and the script must
  hand none over. A pin no consumer reads is not strictness -- it is a value to
  keep in step for nothing. Its behavioural suite drops the three checks that
  guarded the pin plumbing and gains the assertion that no pin reaches the
  gates; it also stops skipping when PyYAML is absent, because the parse that
  needed PyYAML is gone.

  One harvester defect surfaced on the way. `test-makefile-name-contract` treats
  a quote directly after a `print-<VAR>` query as the start of a shell expansion
  -- correct for `mkv part_"$n"`, wrong for a Python argv list like
  `"print-CI_GOALS", override`, which it reported as a name it could not expand.
  A quote now counts only when the expansion it was supposed to introduce
  actually follows, so those two queries are checked as the literal names they
  are, and a negative case pins the distinction from both sides.

  **Nothing reaches a gate except through a declared goal.** Every check above
  asks whether the right goals run, in the right order, with the right pins;
  none asked the prior question, of both files at once: is there anything
  *else*? `release.yml` had no rule at all -- a step could have run `make test`
  beside the four declared ones and every assertion would still have passed.
  Both workflows are now read at each command POSITION rather than at the start
  of a line, so `cd x && make ...`, `out=$(make ...)` and `... | make ...` are
  visible, and every invocation must name exactly one declared goal and pass
  exactly the pins that goal declares. No step may run a suite under `test/`
  directly. Two of those are new coverage rather than preserved coverage: a
  dispatch may carry no Make flags, since `-k` or `-i` turns a failing gate into
  a passing job and `-j` changes the serialisation the gates are written for;
  and the pin set must EQUAL the goal's declared pins, because a variable no
  goal declares reaches every nested Make as command-line input nobody
  reviewed.

  **The local release pipeline must cover the public attestation.**
  `scripts/ci-local.sh` mirrors `ci.yml` before a push; the release half of that
  claim had no counterpart, and it is the expensive one -- `release.yml` runs on
  a tag, and a tag cannot be re-cut. Every gate the workflow reaches through its
  four goals must also be reached by `scripts/make-release.sh`. Coverage rather
  than an inventory comparison, for the same reason the `make test-long` fold is
  coverage: the workflow names goals while the script names each consumer
  directly and deliberately, resolving a toolchain path per command and teeing
  each gate to its own evidence log.

  That question needed the goal graph to see through a list dispatch.
  `release-rebuild` runs `$(CI_CLASSIC_PARTS)` and `release-artifact-gates` runs
  `$(RELEASE_ARTIFACT_GATES)`; an unexpanded `$(...)` is a node with no edges, so
  coverage asked through one is answered by the empty set and passes. The seeded
  edges now expand it, and a check of its own proves they did, because nothing
  else would notice.

  **A dry run now rehearses the artifact commit, not just the pipeline.**
  `scripts/make-release.sh --dry-run` proved the pipeline runs and produced a
  staging directory. It did not produce the shape that fails: no artifact
  commit, no registry append, no `HEAD` for the gates to read. That shape is
  what cost `v0.9.12` its tag -- the release was qualified, tagged, pushed, and
  reproduced bit for bit on the clean runner, and then failed re-running the
  gates on the tag's own tree, because a continuity declaration only becomes
  owed once `release/v0.9.12/` exists on disk.

  `scripts/rehearse-artifact-commit.sh` builds that tree. It clones the
  repository into a throwaway directory, checks out the commit the staged
  `QUALIFICATION` records -- not the branch tip, which may have moved -- copies
  the staging in, appends the publication registration with the same command
  the handoff prints, commits, and runs
  `scripts/verify-release-artifact-commit.sh` against it. A dry run's soak is
  minutes, and the staged SHAPE does not depend on soak duration, so the whole
  failure class is now reachable an hour into a release instead of a day. The
  repository itself is untouched: every Git write is inside the clone.

  Two things a real artifact commit has, a dry run cannot: the staging carries
  the DRY RUN banner, and `SHA256SUMS.asc` does not exist, because signing is
  the operator's own step and no release path signs on their behalf. The
  verifier's new `--allow-dry-run` relaxes exactly those two -- the clean tree,
  the absent tag, the required files, the history shape and all eight gates run
  unchanged -- and it REQUIRES the banner it permits, so it can only accept what
  the publishable mode refuses outright. It prints no tag or push command.

  Building it found which gate that leaves. `test-published-release-immutability`
  is the only artifact gate that reads the release directory on disk, and it
  requires all four files a release signs for itself, so an unsigned staging
  failed it every time -- on precisely the gate whose `IMAGE_CONTINUITY` check
  is the `v0.9.12` failure. It now exempts a banner-marked, UNTAGGED directory
  from the signature requirement alone. Both conditions carry weight: the banner
  is what makes a directory unpublishable everywhere else, and the absent tag is
  what makes the claim checkable from the repository rather than from the file's
  own say-so, so a published release still owes the signature it was published
  with however its manifest is later edited.

  `test-release-rehearsal` is the new gate over the assembly, and the exemption
  is pinned from both sides in `test-release-history`, which already builds
  synthetic published releases to exercise the immutability gate.

- **Soak transcripts are sealed by payload digest, like every other retained
  log.** The `soak` evidence role never carried one: a log was bound by its
  `evidence/INDEX` row -- terminal record and byte size -- so a substituted body
  of identical length still carrying an identical `SOAK_RESULT` satisfied every
  check. That was harmless while every log came from the run that consumed it,
  and stopped being harmless when `--reuse-soak` made a log arrive from a tree
  the current run did not produce. `soak` joins `RELEASE_EVIDENCE_RESULT_ROLES`,
  each transcript is sealed after the run has a verdict, and its index row
  carries the seal.

  Adopted transcripts are deliberately **not** resealed. The seal names the
  commit whose run produced it, so a release that re-sealed adopted logs in its
  own name would destroy the binding that makes the reuse checkable at all. Both
  the qualification verifier and the staging re-derivation therefore expect the
  attested release's commit for soak evidence, read from the record this tree
  retains for it; `release_reuse_soak_attestation` rehashes each adopted payload
  against the seal before adopting it. The controls include the defect itself --
  a same-length, same-verdict payload substitution, now refused by name.

- **The toolchain record is written before the soak, not after it.** Every
  `TC_*` capture it prints is taken in phase 0, so it never depended on a soak
  result -- yet it was written after one. That is exactly what cost `v0.9.12`
  its first attempt: the run died in staging on an unstaged `toolchain.txt`, 24
  hours after the last input to it stopped changing. A gate asserts the new
  position.

- **The required non-image artifacts are staged in the rehearsal too.** Staging
  them is now a function taking a destination, so a helper that is missing,
  unreadable, or not byte-identical to its tracked source fails in the first
  minutes rather than after the soak. With this and the command table, the
  staging phase is down from 65 refusal points to 36; what remains is either
  soak-bound by definition or bound to evidence this run produces, chiefly
  `evidence/INDEX`, which lists the 18 soak logs and so cannot be built before
  they exist.

- **The staged programming commands and image facts are rehearsed before the
  soak.** The staging phase carried 65 refusal points and almost none of them
  read a soak result: the programming-command table, the per-image facts and the
  resource rows are functions of the image set, the Makefile and evidence
  measured before the soak. Evaluating them a day later is how `v0.9.12` died in
  staging, on an unstaged `toolchain.txt`, after a full soak had been paid for.
  `flash_row`, `img_row`, `release_producer_source_command_valid` and
  `check_flash_commands` now live before the soak phase and run twice: once
  against the built images with the output discarded, and once for real at
  staging, which requires the two command tables to be byte-identical. A defect
  in this material now fails in the first minutes, with nothing spent.

  Two indirections make the double run possible and are the only behavioural
  change from the move: the command table is appended to `$FLASHCMDS` rather
  than one hardcoded path, and `img_row` reads image digests from
  `$IMAGE_SUMS_FILE` rather than from the staged checksum list, which does not
  exist at rehearsal time. Position is the contract, so a gate asserts it: the
  generators and the rehearsal must precede the soak section, and staging must
  compare against the rehearsed table.

- **`--reuse-soak` stands a release on a published soak instead of repeating
  it.** When a published release already carries this run's
  `soak_inputs_sha256`, the soak is adopted rather than executed. The
  attestation is that release itself: `SHA256SUMS` covers its `SOAK_KEY` and
  `QUALIFICATION`, and the detached signature signs `SHA256SUMS`, so reuse needs
  no separate store, no second trust root and no extra signing step. Before
  adopting, the signature, the checksum manifest, the `SOAK_KEY` payload digest
  and the evidence index are all verified, the attested duration must be at
  least what the requested mode demands, and every adopted log is re-validated
  by the same `validate_soak_result` the live path uses -- reuse skips the
  execution, never the check. `QUALIFICATION` records `soak_source`
  (`format=9`), `MANIFEST.md` discloses reuse in prose, and the verifier refuses
  a release that reuses a soak without saying so.

  Duration moved out of the `SOAK_KEY` payload onto its result line
  (`SOAK_KEY format=2`), because it is a magnitude rather than an input: a
  24-hour soak of given inputs subsumes a 1-hour one, so reuse compares it with
  `>=`. Leaving it in the payload would have meant an express release could
  never stand on a production soak. The liveness interval stays in the payload,
  since it changes what the soak checks rather than how long for. The key is
  also now computed before the soak rather than after it, which is what makes it
  able to decide whether the soak runs at all.

  One limit, stated plainly: soak logs are bound by their evidence-index row --
  terminal record and byte size -- not by a content digest, so a tampered body
  of identical length carrying an identical result line would not be caught.
  Closing that means giving the soak evidence role a payload digest, which is a
  change to the evidence contract rather than to this feature.

- **`test-release-provenance` counts thirteen fail-closed tool probes, not
  eleven.** The two host C++ compilers that build the PIC soak harnesses are
  named in the soak input key, so a release that could not identify them could
  not say what its soak result is valid for. The yasimavr build-stamp probe is
  pinned by name alongside them.

- **`evidence/toolchain.txt` records yasimavr.** It named gpsim and libsimavr
  but not yasimavr, even though three of the 21 published images are ATtiny202
  images and yasimavr is the only thing that ever executes them. A version
  string alone would not have been enough: 0.1.6 reports 0.1.6 with or without
  the vendored patches that make the ATtiny202 soak trustworthy, so the release
  records the venv build stamp `scripts/fetch_yasimavr.sh` already maintains --
  version, upstream sdist digest, patch-set digest. A venv with no stamp, an
  empty stamp, or one carrying a tab refuses the release.

- **The first execution of the shipped programming path against real silicon is
  on the record.** `HARDWARE_VALIDATION_LOG.md` carries a dated 2026-09-07 entry
  under its outstanding-runs section: the part, the programmer, the device pack,
  the image digest, the helper digest -- marked as deliberately not a released
  helper's -- and the result digest, plus what was re-derived from the retained
  exports independently of the helper's own arithmetic. 574 of 574 supplied
  words programmed exactly, 449 of 449 unsupplied words erased, 1024 of 1024
  words covered, `OSCCAL` `0x3424` unchanged and still a valid `RETLW`, and
  `CONFIG` `0x11CC` exactly `(image & ~BG) | factory BG`.

  It is recorded as field use, not as a controlled qualification, and section 2
  of that file still declares that no controlled hardware-qualification record
  exists for any part. The file's own definition is what decides that: no
  written procedure exists to execute, the helper was locally modified so its
  release checksum binding was bypassed, the part sat on a breadboard with no
  board or output stage fitted, and nothing was measured with an instrument. A
  run missing any required field is a field-use report however careful it was.

  Two entries in the outstanding list were not merely unproven but wrong, and
  are corrected in place rather than quietly dropped: the read and export return
  no numeric device ID for this part under any option, and `ipecmd` does not
  accept the image as a sealed-copy descriptor.

### Changed

- **Design prose can no longer stop a release.** Six of the rules inside the
  bounded-claim contract were not claim boundaries at all: they reject prose in
  `DESIGN_DOCUMENTATION.adoc` and `TOOLCHAIN.adoc` that restates release
  topology `release/README.md` owns, carries a measurement bound to nothing, or
  pins durable design prose to a date or a revision. Each is a real drift this
  project has had, and none of them is a defect in a release -- but they were
  enforced by refusing to cut one. They now live in
  `release_validate_current_fact_rules`, which runs on every commit and which
  `scripts/make-release.sh` does not call; a gate asserts that it does not, so
  the split cannot quietly collapse. No rule was weakened: the same six
  patterns, the same diagnostics, the same live-tree assertion, plus a control
  proving a current-fact violation no longer reaches the release path. The six
  fenced claim blocks -- what no part has completed, what the PIC10F320
  assurance package does not establish, what reproducing an image proves --
  keep their release-time enforcement, because a release must not publish a
  claim stronger than the evidence it ships.
  [`docs/release_proportionality.md`](docs/release_proportionality.md) records
  the reasoning.

- **Live-tree documentation assertions read the version the tree declares.**
  The two PIC12F675 contract checks that run against the checked-in tree passed
  hardcoded versions -- `v0.9.11`, two releases stale, and a fictional
  `v1.2.3`. Both now derive it from `release/README.md` through a new
  `release_current_contract_version`, which `release_validate_development_state`
  also uses in place of its own copy of the parse.

### Fixed

- **The PIC12F675 flashing helper works against a real MPLAB X 6.20 and a
  powered part.** `scripts/flash-pic12f675.py` ships in every release, and until
  this bench run no part of it had been executed against an installed `ipecmd`
  or real silicon. Every lane passed because both fakes were modelled on the
  helper rather than on the tool. Five defects surfaced, in the order the bench
  hit them.

  - **The version pin rejected every real `ipecmd` in existence.**
    `probe_version()` harvested version tokens only from output lines carrying
    the token `MPLAB`, which real `ipecmd -?` never prints: it identifies itself
    in a header and a usage line, and states its version exactly once, as a bare
    `Version v6.20` trailer, before exiting 50. Provenance and version are now
    two checks instead of one, so a JVM stack trace naming the
    `com.microchip.mplab.ipecmd` class cannot be read as the tool having run.

  - **A sealed `memfd` is not a pathname a JVM can open.** A JVM canonicalises
    the pathname it is handed, and a memfd canonicalises to `/memfd:<name>
    (deleted)`. Handed the jar, that broke startup: real `ipecmd.jar` is a
    manifest stub whose `Class-Path` names about two hundred sibling jars, and
    that canonical path has no directory to resolve them against. Handed the
    image, it cost a write -- the first real attempt erased nothing, programmed
    nothing, and published a correct FAIL whose entire transcript was `Hex file
    not found.` Both are now named under a real directory descriptor, the way
    the three device reads that did succeed always were.

  - **`-P` spelled the part in a form `ipecmd` rejects.** It supplies the family
    prefix itself, so the argument now spells `12F675` through a separate
    `PART_ARG`, while `PART` goes on naming the part in full for the evidence
    record and for transcript matching. `FLASHING.md` already documented the
    quirk for the PIC10F322; the PIC12F675 route had inherited the command shape
    without the note.

  - **A board that supplies no Vdd of its own could not be read at all.** The
    helper constructed no power option and refused `--power` outright, so
    `ipecmd` aborted on an undetectable target voltage before touching the part.
    `--power tool` now adds `-W`, fixed for the whole transaction and recorded
    in the reservation, so a baseline read and a write cannot happen under
    different electrical arrangements; `external` stays the default and stays
    the right answer for a populated board. `-W` cannot select a voltage: every
    VDD/VPP option `ipecmd` 6.20 exposes is marked PM3-only, and a PICkit 3
    derives that rail from USB.

  - **A transaction that succeeded completely was refused for want of a device
    ID the tool never prints.** `ipecmd` 6.20 driving a PICkit 3 prints no
    numeric device ID for this part under any option, `-I` included. The numeric
    identity now comes out of the full-device export, where `DEVID` sits at word
    `0x2006` beside the `CONFIG` word the transaction already reads from there
    -- device memory rather than tool prose, and no third spelling to guess at.
    An export that omits the word is recorded as such rather than refused.

  `--show-commands` also reported a healthy export path as `<unresolvable>`,
  because only the descriptor component of a path under a directory descriptor
  is a symlink. It is resolved on its own now and the remainder re-attached, and
  the test requires every printed descriptor to resolve rather than merely that
  an arrow appears.

  One property is given up, and named where it is given up: the image can no
  longer be made unsubstitutable between its final digest and the erase, because
  `ipecmd` has to be able to open the file. A substitution still cannot pass --
  the device is evaluated against the bytes recorded in the durable reservation,
  never against the file on disk -- so `image_pinning` now reports
  `evidence-snapshot` rather than claiming a seal the writer never sees.

- **The artifact-commit gates no longer inherit build inputs from whoever
  started them.** `release-artifact-gates` passes its gates nothing but
  `STRICT_TOOLS=1`, and that was true of the goal and false of the run: GNU Make
  re-passes every command-line variable to its sub-makes through `MAKEFLAGS`, so
  the two policy pins `make-release.sh` puts on its own `make test-long` line
  reached those gates as command-line origin from three levels up -- the origin
  that beats the Makefile's own value everywhere.
  `scripts/verify-release-artifact-commit.sh` now clears the inherited Make
  environment before it dispatches, which also drops `-j` and `-k`, neither of
  which a serially-written fail-closed gate set survives. The first real
  `--dry-run` is what found it, in the gate that exists to check exactly this.

  The fixture that missed it probed two variables by name, so an inherited value
  was indistinguishable from a passed pin and a pin nobody had thought of was
  invisible. It reports the *names* of every command-line-origin variable now,
  through `$(origin)`. `test_workflow_syntax.sh` had the same shape of hole: it
  lists `env` as a command prefix it sees through and then stopped on `env`'s own
  options, so `env -u X make ci-verify` matched no rule at all rather than
  failing one -- as `env -u X bash test/test_x.sh` would have walked past the
  check on suites reached outside a goal.

## [0.9.13] - 2026-09-06

### Added

- **`make release-prepare` writes the derived release lines instead of refusing
  them.** Cutting a release meant hand-editing seven lines across
  `CHANGELOG.md` and `release/README.md` until the validator stopped objecting,
  though each is a pure function of the version being cut, the version before it
  and the date. They are now rendered through the same functions the validator
  compares against. It writes structure and never prose, refusing when
  `[Unreleased]` says nothing about the release and refusing outright for a
  version already tagged or already holding a retained record. Verification is
  unchanged.
- **A release must now prove the commit the tag will name before the tag
  exists.** Qualification stages `release/vX.Y.Z/` without touching Git, so no
  gate had ever run against the tree a tag actually carries, the one containing
  the release directory and the publication-registry append.
  `scripts/verify-release-artifact-commit.sh` runs after the artifact commit,
  repeats the two checks tag CI makes before it builds, and runs every gate
  whose verdict that commit can change. It is now the only thing that prints the
  tag and push commands, and only on success, so a release that has not proved
  itself yields no command to paste.

### Changed

- **Documentation gates now hold claims to their terms rather than to their
  sentences.** Roughly seventeen places pinned prose byte for byte, at real
  cost: changing a period to a semicolon failed a safety gate without altering
  any claim, number or part. A rule an author cannot satisfy by writing
  correctly eventually gets satisfied by deleting it. Nine fenced claims replace
  those pinned sentences, each bound by a named marker pair and held to the
  terms it must still state, so deleting, emptying, unclosing or inverting a
  fence fails with the marker named. No property is dropped.
- **`DESIGN_DOCUMENTATION.adoc` no longer carries a date or a source revision.**
  Its last byte-pinned passage had been mitigated by pinning provenance, because
  a measurement sat in durable prose. That measurement is gone, having restated
  a conclusion its own sentence already drew, and a current-fact rule now
  refuses ISO dates and commit bindings in the document so the mitigation cannot
  return in place of moving a measurement out.

### Fixed

- **`v0.9.12` was tagged and never published: its own release-history gate
  refused it.** Tag CI rebuilt every image from the tagged source and confirmed
  all 21 reproduced bit for bit, then failed re-running `make test-long`.
  `Publish GitHub Release` never ran. The signed tag and `release/v0.9.12/` are
  retained as the record of that cut rather than rewritten, so its changelog
  section and comparison link stay resolvable.
- **The release-history suite no longer holds a release to a declaration no
  tagged tree can carry.** Its fixture appends a synthetic future prerelease to
  the real published set, which moved the image-continuity gate's newest-release
  exemption off the release being cut. Every release therefore failed from its
  own artifact commit onward, for a debt that commit cannot pay: it may change
  only `release/<version>/` and the registry append, and a declaration written
  any earlier names a version that is not yet published. The fixture now writes
  that declaration itself, in the source commit of the release it appends, using
  the gate's own release ordering and signed-list parse.

## [0.9.12] - 2026-09-03

Users of `v0.9.11` should flash from `FLASHING.md` rather than from that
release's manifest: most of its programming commands are templates rather than
pasteable shell, and the PIC12F675 has its own helper requirements.

### Added

- **`make pic10f320-program` flashes a built PIC10F320.** It mirrors
  `pic10f322-program` with its own `PIC10F320_PROG*` variables and selects the
  output stage with `PIC10F320_VARIANT`, the same name its build goal reads, so
  the image flashed is the image built. Every published PIC10F32x command is now
  pinned byte for byte to the Makefile command it names. No PIC10F32x
  programming command has been run against silicon under a written procedure.
- **Release manifests publish resource use against reviewed ceilings.** Each
  image reports its flash use, and the Resources section reports static RAM,
  stack and return-stack results with their ceilings and margins. The AVR-XT
  figure is a per-frame compiler bound, not an observed whole-path high-water
  mark.
- **Modular shells reject a missing or conflicting MCU or output selector**, and
  shared output drivers reject a foreign variant selector. Valid firmware
  behaviour is unchanged.

### Changed

- **Measurements that change now live only with the authority that produces
  them.** Design documentation keeps stable capacities, reviewed ceilings and
  the gates enforcing them; exact results come from source- and toolchain-bound
  release evidence, and reader guides no longer copy release inventories.
  Transient timing, loop-cycle, current and optimization figures are no longer
  maintained as current facts.
- **Retained evidence is bound to the operation that produced it, and
  release-state documentation fails closed between releases.** Build and
  target-test logs bind their payload, source commit, role and identity through
  the qualification index. A declared release must carry the pre-tag transition
  disclosure until a real qualification record exists.

### Removed

- **The flashing-simplicity design journal.** Shipped instructions stay in
  `FLASHING.md` and their executable checks, unresolved work in `TODO.md`.
- **The one-shot v0.9.8 rename-identity lane**, whose signed tag and report
  remain the historical authority. Current releases keep canonical image
  reproduction, expected-image identity, checksum and publication-inventory
  checks.

### Fixed

- **Beginning with `v0.9.12` the release signature covers provenance as well as
  firmware.** Signed checksums now include `QUALIFICATION`, `MANIFEST.md` and
  `README.md`. Releases through `v0.9.11` are unchanged, so their provenance
  sits outside their checksum signatures; their signed tags and the immutability
  gate are separate historical controls, not retroactive signature coverage. The
  immutability baseline records the earlier safety-errata amendment to `v0.9.0`
  through `v0.9.2` rather than claiming published files never changed.
- **The Makefile's `ipecmd` route now reads the device back.** Under
  `PIC10F322_PROG=ipecmd` and its new PIC10F320 equivalent the command
  programmed the device without verifying it and left the part in reset. It is
  now `-F<hex> -M -Y -OL`, matching both the published PICkit 3 procedure in
  `FLASHING.md` and the PIC12F675 helper's validated write, and
  `PIC10F322_PROG_TOOL` defaults to `PK3` rather than `PK4` for the same reason.
  Releases publish no `ipecmd` command line, before or after this change.
- **Manifest generation now emits validated, shell-valid, image-specific
  commands** with explicit defaults, substitutions and power assumptions. PIC
  writes require readback, and the PIC12F675 keeps its dedicated helper rather
  than a per-image command.
- **PIC context sidecars prove the guarded context is in reviewed SRAM.** The
  pinned XC8 resolver accepts `_ctx_` only in `BANK0`; program, configuration,
  EEPROM, alternate-bank and unknown classes fail closed.

## [0.9.11] - 2026-08-29

### Fixed

- **`v0.9.10` was tagged and never published: its own release gate refused the
  environment CI ran it in.** Tag CI rebuilt every image from the tagged source
  and confirmed all 21 reproduced bit-for-bit, then failed on the first gate
  re-run. `.github/workflows/release.yml` declared `ATTINY_DFP_VER` at workflow
  scope, and a workflow-level `env:` is exported into every `run` step -- so the
  variable was in the environment of `make test-long`, whose
  `test-release-preflight` gate runs a real release configuration inside its
  fixture. The Makefile refuses a release goal under any environment-origin name
  in the project's build-input vocabulary that is not a supported release input;
  `ATTINY_DFP_VER` matches `ATTINY%`, appears nowhere in the Makefile, and so
  keeps environment origin. `Publish GitHub Release` never ran.

  The guard was right -- that variable selects which ATtiny device pack
  `scripts/fetch_attiny_dfp.sh` vendors, and a release must not run under an
  unreviewed build input. What was wrong is that it was declared twice. The
  workflows no longer carry it at all: the version is pinned in
  `scripts/fetch_attiny_dfp.sh` beside its SHA-256, and the six ATtiny_DFP cache
  keys bind to `hashFiles('scripts/fetch_attiny_dfp.sh')` alone, so a bump
  invalidates them exactly as the neighbouring yasimavr venv keys already work.
  A second copy of the pin that could disagree with the script is gone with it.

- **The release-preflight gate's positive control was not hermetic.** That gate
  asserts "a clean release configuration passes", and it inherited whatever its
  caller exported -- while its callers export build inputs as a matter of
  course, because GNU Make puts every command-line variable in its recipes'
  environment and release CI runs `make test-long STRICT_TOOLS=1 ...
  PIC12F675_FLASH_IMAGES=build`. The gate cleared a hand-maintained list of
  those names, which had already drifted once when `PIC12F675_FLASH_IMAGES` was
  added to the release workflow, and drifted again on a name Make never reads.
  `test/test_release_preflight.sh` now asks the Makefile for its own
  `RELEASE_ENVIRONMENT_INPUT_PATTERNS` vocabulary and clears every inherited
  match once, before the first case runs, so the list cannot drift a third time
  and the gate's result no longer depends on the machine it runs on. Cases that
  deliberately inherit an override still set it at call time and are unaffected;
  an inherited `ATTINY_DFP_VER` is now pinned as a refusal case in its own
  right. `test-release-preflight`: 208 -> 209 checks.

## [0.9.10] - 2026-08-26

Building from source now requires GCC 10 or newer, or any Clang. Flashing a
downloaded release onto a PIC12F675 goes through `flash-pic12f675.py`, shipped in
every release bundle from this one on, rather than through a raw programmer
command.

### Added

- **`flash-pic12f675.py`, a release-shipped PIC12F675 flashing helper**, listed
  in the same signed `SHA256SUMS` as the images. This part is the one release
  target a raw programmer command cannot safely serve: a bulk erase destroys two
  per-device factory-trimmed values the image cannot supply -- the oscillator
  calibration word at `0x3FF` and the `BG<1:0>` bandgap field in CONFIG -- and a
  device that loses either **still appears to work**, running at the wrong tick
  cadence, the wrong coil-pulse widths, or the wrong brown-out threshold. The
  helper needs Python 3 and MPLAB X 6.20 `ipecmd` and nothing else, and runs the
  write as one transaction: validate the image against the signed checksum, read
  the device twice to prove its trim is stable, reserve durably, write exactly
  once, read the whole device back, publish one immutable PASS/FAIL result. An
  interruption is PENDING, never an implicit success, and a read-only
  finalization resolves it. The factory export is retained whatever happens.

  **This detects trim damage; it does not prevent it.** Whether a real PICkit 3
  preserves the trim across an erase is still a bench question, and until that
  controlled run is on file a PASS means "no damage was observed on this device",
  not "this writer is known to be safe".

- Single-bit upset detection for the debounce context, because the per-tick
  sanity gate rejected only out-of-range values: an idle counter whose bit 3 or
  bit 4 flipped stayed in range and was enough to toggle the effect with nobody
  touching the footswitch. Persisted context is now a transaction against a
  complemented XOR-fold check byte, proved by CBMC over the full byte domain.
  Automatic locals, registers, code and control flow are outside the guarantee.
  **The PIC10F320 is excluded**: even the cheapest fold overflows its 256 words,
  so its range-only gate stays. Design: `docs/context_seu_detection.md`.

- A compile-time watchdog-margin assertion on every shell, where only the
  PIC10F320 had one. The bound is wall-clock rather than the delay constant
  alone, adding the loop work between a tick and the pet after it and, on the
  interrupt-driven AVRs, the tick ISR stretching a blocking actuation past the
  delay body it compiles to. Shipped margins were always wide enough; a future
  near-bound configuration could have satisfied the old assertion and violated
  the real one. Classic-AVR simavr measures the built image against the same
  budget; AVR-XT uses compiled bounds, the pinned simulator's cycle-stepping
  defect precluding a trusted full-interval measurement.

### Changed

- **An unexpectedly energized relay coil is a fault now, not a silent
  correction.** Earlier `0.9.x` builds re-asserted both coils low at every
  serviced loop top and continued. That cleared the coil, but the stray pulse it
  permitted -- roughly one tick -- is only *below* the Panasonic TQ2-L2-5V 4 ms
  minimum for guaranteed actuation, which is not the same as proven mechanically
  harmless, so the firmware could not know whether the latching relay had moved.
  If it had, the audio route was left permanently disagreeing with the effect
  state and the LED. The coil is now caught by each shell's output-state
  integrity check and escalated: both coil outputs are commanded idle *before*
  the watchdog spin, and recovery re-runs `init()`, returning state and LED to
  BYPASS with a nominal 12 ms RESET pulse. Physical return to BYPASS still
  depends on the board, driver, supply and relay meeting the documented actuation
  assumptions, and the blocking actuation sequence stays excluded from every
  guarantee. PIC10F320 guards the two coil bits rather than the general latch
  comparison it cannot afford in 256 words. Design:
  `docs/relay_coil_fault_correction.md`.
- Host compiler floor of GCC 10, or any Clang, because GCC 9 and older report a
  false narrowing on the PIC shells' OR-folded integrity checks and every host
  gate compiles firmware with `-Werror -Wconversion`. Satisfying GCC 9 cost four
  PIC10F322 words, which the 512-word `cd4053_with_mute` variant cannot spare, so
  the floor is enforced instead of paid for.
- A release's date no longer has to equal its source commit's date; the old gate
  rejected a valid release whenever the two fell on different days.
- Suffixed tags publish as prereleases. The producer, verifiers and workflow
  trigger had accepted `vX.Y.Z-suffix` for some time but `gh release create` was
  never told, so a release candidate would have published as an ordinary release
  and could have taken latest-release selection from the newest stable version.
- Release-environment pinning is described factually: `ubuntu-24.04` is a moving
  runner label and the apt tools carry no version constraint, so the runner and
  that part of the toolchain are recorded, not pinned. What *is* enforced is
  stated instead -- every published image rebuilt and compared byte for byte
  against the signed `SHA256SUMS`, the compilers that define those bytes
  version-checked before any build, the XC8/DFP cache integrity-verified on every
  restore.

### Fixed

- **The flashing helper could publish `PASS` over half the previous firmware.**
  Its post-write comparison walked only the addresses the release image supplies,
  and the images occupy 495, 521 and 523 of this part's 1023 program words, so a
  writer that never erased could pass every check while leaving hundreds of stale
  instructions in the image's holes, still reachable by a computed jump or a
  runaway program counter. The comparison now covers one complete expected
  device, and the result records how many words were verified beside the total it
  has to equal.
- **The helper bound the tool that shipped, not the tool that ran.** It checked
  its own bytes against the release checksums only when run from inside the
  bundle directory; `ipecmd` and the retained image were hashed by pathname and
  then used by pathname with the whole transaction in between, so a process
  running as the operator could swap either after the reservation and before the
  erase; and a device export with a self-contradicting duplicate address or a
  partial read of program memory was accepted as the trim baseline. Binding is on
  bytes rather than location now, everything the child executes or reads is
  passed by descriptor, and the image is a sealed anonymous copy with no name to
  replace. That makes the guarded transaction a Linux procedure; elsewhere the
  helper refuses to touch a device rather than run a check it cannot honour.
- Neither the evidence reservation nor the published result was crash-atomic: the
  directory entry naming the reservation was never flushed, and the result file
  was created under its final immutable name and then written into, so an
  interruption could leave a transaction that was neither a valid result nor a
  recoverable PENDING.
- **Every AVR `*-program` goal builds and validates its image before it writes a
  fuse byte.** `*-program: *-fuses *-flash` made the firmware image a
  prerequisite of the *later* goal, so a compile, link, size or Intel HEX failure
  landed **after** the clock, watchdog and BOD fuses were rewritten, leaving a
  part configured for firmware that does not exist. On a fresh chip that is not
  academic: the fuse write is what moves it off its factory clock. Each goal is
  one ordered transaction now. `*-fuses` and `*-flash` keep their single-step
  meaning and stay ungated.
- A production release could be staged under a development override. Both
  independent statements of what a release contains are composed from the
  variables a caller can move, so `make release FW_BASE=other` reached the
  staging script through `MAKEOVERRIDES` and both opinions agreed on a
  never-reviewed image set; an exported MCU tag or die selector did the same
  without appearing in any typed command, those being `?=`. The reviewed identity
  is pinned as literal `override` text and a release goal fails at parse time
  against it. Build-directory and tool-path overrides stay available.
- The XC8 cache manifest could be frozen from a partial scan. Installer and
  verifier both computed it as one `find | sort | xargs sha256sum` pipeline under
  `/bin/sh`, which reports only the last stage's status, so a `find` that died
  part-way was masked by the `sha256sum` over the fragment; on a synthetic
  install the old installer exited 0 having recorded one of nine files. The
  dangerous case was never the loud one: a partial record is not caught at
  restore time if the same condition truncates both walks the same way.
- The image-defining compiler pins were substring matches, so `avr-gcc (GCC)
  17.3.0` passed the 7.3.0 check and XC8 `V3.100` passed the V3.10 check. A
  neighbouring version is what a drifting host has, and every published image
  byte is gated on the exact compiler.
- PIC10F320 de-energizes both relay coils in one write. Two separate
  read-modify-writes settle in the same place but differ in the transient: with
  *both* coil bits high, the upset the sanity gate escalates on, the per-bit
  clear left the second coil driven for the whole first write, on the one path
  whose purpose is to stop driving them. One constant-mask write is also cheaper
  -- the relay image went from 248 to **242** of 256 words and its worst-case
  return-stack depth from 4 to **3** of 8. Both CD4053 images are byte-identical
  to the previous release.
- PIC12F675 relay coil clears commit through one whole-port write, so a shadow
  upset cannot be replayed as an intermediate physical high while RESET is
  cleared first. Because that write publishes the whole shadow, the emergency
  path also canonicalizes the parked spare output GP4 in the same write;
  otherwise an upset that set only that bit, inert until something writes the
  port, would be published to the pad by the escalation itself and held there for
  the watchdog period, on a pin the board contract permits only while it is low.
  Two words on the relay image; the CD4053 images are byte-identical.
- Both published PIC12F675 recovery examples omitted `PIC12F675_RELEASE_TAG`, so
  following either rejected a valid PENDING signed-release transaction instead of
  resolving it -- after an interrupted write, holding a device whose factory trim
  is already at stake. The generated per-release documentation carried the
  argument, which is how the two drifted apart.
- The guarded PIC12F675 release path admitted a build it had not bound, and its
  CONFIG gate could consume a stale ignored executable. The target now requires a
  clean checkout at the verified tag and a digest match against the signed
  release set, and builds the CONFIG checker privately per transaction.
- `make test` now runs both PIC shipping-source coverage gates. They need only
  the host compiler, gcov and Bash, which `make test` already requires, yet were
  reachable only through standalone aggregates whose *other* lanes need XC8, the
  device pack or gpsim -- and one of those skips its whole matrix when XC8 has
  qualified nothing. That routing had already cost something: a stale host fault
  oracle, a compile configuration that was not the shipping one, and a coverage
  anchor matching zero lines coexisted with a green `make test` for the length of
  a branch.
- Two ways a lane could score a pass it had not earned. PIC fault injection
  relied on the next case's setup stalling to expose a recovery that reset and
  then wedged, so the final case, having no successor, would have passed. And a
  mutant that produced its exact three-variant failure record could be reported
  as a compile error when unrelated compiler-shaped text appeared elsewhere in
  the Make log.
- Resource figures in four documents had drifted from the images they describe,
  in the direction that matters when a reader is deciding whether a change fits.
  `make test-resource-tables` recomputes every cell from its own size and the
  datasheet capacity and measures any documented image a build directory holds.
  What is genuinely unmeasured is named: whole-program Data-space totals for
  PIC10F322 and PIC10F320 are withdrawn, their release logs not retaining the
  records those claims need, and the ATtiny202's peak stack stays unretained
  because no AVR-XT lane measures a call-chain-plus-interrupt high-water mark.
- Field-use reports and controlled hardware qualification were conflated in
  opposite directions. `HARDWARE_VALIDATION_LOG.md` presented community build
  reports as evidence that firmware had been tested on actual hardware, while
  this file, `DESIGN_DOCUMENTATION.adoc`, `TODO.md`, the Makefile and two design
  documents said no part had ever been qualified. Builders really have
  flashed released images onto ATtiny13a and PIC10F320 parts and reported them
  working, and none of those reports retains the source and image identity, board
  revision, programmer, configuration bytes, procedure, measurements or
  acceptance result a qualification record needs. The log separates the two now,
  and the `1.x.y` criterion is restated project-wide as controlled hardware
  qualification. Unqualified pin-compatibility notes are replaced by the actual
  constraint: a shared pinout is a *board* property. The AVR classic trio needs a
  different image and different fuse bytes per part or the device runs at the
  wrong clock and still appears to work; the PIC10F32x pair needs each part's own
  image, CONFIG word and programmer part name.
- A release declared evidence the tree could not contain. Source finalization and
  the artifact commit are necessarily *different* commits, because the history
  verifier rejects a release whose qualified source commit already holds its own
  `QUALIFICATION` record. `release/README.md` documents the four-step sequence,
  says which identity each step fixes, and states the rollback rule; a bounded
  current-release block may no longer name a release directory the tree lacks.
- Branch-only working documents could reach a release. The staging guard refused
  one family by name and nothing else, so a root-level pre-release fix list was
  invisible to it, as the next such document would be under any other name.
  Staging governs the whole root-level Markdown set as an allowlist now, and no
  durable file is left pointing at a document the release removed. Preflight is
  unchanged and stays usable on a live branch.
- The release workflow revalidates every frozen publication asset immediately
  before upload -- file set, types, sizes, identities, hashes, the detached
  checksum signature, then the inventory again, then `gh` with no intervening
  command. Added, removed, renamed, empty, symlinked, non-regular or
  byte-modified assets fail before upload.
- The durable documents disagreed about what the PIC12F675 route is. One
  published the helper's procedure while two others said no such procedure
  existed, and `release/README.md` contradicted itself, opening by saying this
  part admits no downloaded image and documenting the helper that does exactly
  that further down. The policy is published now, software-tested, not
  hardware-qualified, and every publisher says so; the Make-based development and
  release-provenance route keeps its own statement, because the reads it would
  need immediately before and after an IPE write have no validated
  dual-programmer handoff.
- A design document's banner still opened by saying nothing in it was implemented
  while two of its proposals had shipped, and its account of a failed build
  leaving changed AVR fuses with no matching firmware still read as an open
  hardware-safety defect after the repair. Two figures checked by eye had drifted
  the same way, an occupancy summary understating its own table's tightest image
  and a target-result row reporting a count no other record used.
- Simulator observations were described as physical-hardware ones in several
  documents, the Makefile and the workflow comments; they say modeled pin levels
  now. Where the word names the *register* semantics classic mid-range and
  PIC10F32x parts have, a port reading pins where a shadow or latch holds the
  level, it is unchanged: that is a datasheet distinction, not an evidence claim.
  The ATtiny202 harness account was stale in four documents, and the distinction
  that makes its claims compatible is drawn in all of them now -- the *compiled*
  width comes from the delay oracle reading the loop count out of the
  disassembly, simulator-independent, while the *delivered* width is what the pin
  held, timestamped from a signal hook and a few percent longer because the tick
  ISR preempts the busy loop. The pinned simulator's cycle-rewind defect reaches
  no timing assertion at all. One portability promise outlived its code the same
  way: the yasimavr fetch script's stripped-`ensurepip` recovery was deleted for
  fetching and running an unhashed script, but the prose survived it.

## [0.9.9] - 2026-08-15

The PIC12F675 joins the release as a seventh part and a fourth core generation.
Released images go from 18 to 21 and release soak combinations from 15 to 18.

### Added

- **PIC12F675 support, release-supported from `v0.9.9`.** A fourth core
  generation -- Microchip *classic* mid-range, beside AVR Classic, AVR-XT and
  the enhanced mid-range PIC10F32x -- and a fourth modular shell over the same
  compiled pure core. 1024 program words, about 51% used by the largest variant.

  It needs its own shell rather than a PIC10F32x rename, because the classic
  core lacks four things the 32x has and each absence has a design consequence:

  - **No `LATx`.** Reading `GPIO` returns physical pin levels, so the 322's
    read-modify-write idiom would be a read-modify-write *on the pins*. Every
    output write goes through an SRAM shadow instead, and the shadow guards
    itself: the per-tick integrity check compares it against both the expected
    mask and the physical port, so an upset in either direction forces a reset.
    That is strictly stronger than anything the 322 can do, where latch and port
    are two views of one register.
  - **No period register, and one prescaler shared between timer and watchdog.**
    It goes to the watchdog at 1:16, leaving TMR0 unprescaled at F_OSC/4, so
    four 256 us rollovers counted in software make a **1.024 ms** tick. The 2.4%
    stretch changes nothing in the debounce core, which counts samples, but it
    moves every physical timing figure.
  - **No `OSCCON`.** The 4 MHz oscillator is fixed by CONFIG and trimmed by a
    factory `OSCCAL` value in the last program word, so the runtime guard
    compares against a value captured at init rather than against a constant.
  - **A comparator holding GP0 and GP1 out of reset.** An analog input reads
    back 0 whatever the pin is driving, so the port-follows-shadow check would
    fail every tick, and three of the eight comparator modes additionally put
    `COUT` on GP2. All three are active output pins here, so `CMCON` and
    `ADCON0` are part of bring-up and part of the per-tick guard set.

  The footswitch sits on GP5 rather than the input-only pin the 322 uses,
  because GP3 has no internal weak pull-up and siting the switch there would
  delete the pull-up integrity check from this target.

  Simulator images are **derived**: an oscillator calibration word is injected
  into a *copy*, because an erased image never reaches `main()` in gpsim. A
  dedicated gate proves the injection leaves the shipping images byte-identical,
  which is what lets the release soak run the derived image and still bind to
  the shipped HEX.

  Like every other part here, the PIC12F675 has not completed controlled
  hardware qualification. Its release rests on simulation, formal proof and
  static analysis, and its silicon-only residual risks -- whether a programmer
  preserves the factory calibration and bandgap trim, and GP2's Schmitt-Trigger
  readback margin -- are `1.x.y` work rather than `0.9.x` release blockers. See
  `docs/pic12f675_feasibility.md` section 8.

- **`make pic12f675-program`**, so the part can be put on a device. Same shape
  as `pic10f322-program` -- one variant, the CONFIG word carried inside the HEX,
  a conservative no-Vdd default -- with one gate the 10F32x parts have no need
  of. Every simulator lane for this part runs a derived image carrying a
  fabricated calibration word, and writing one to a device would overwrite that
  device's factory trim irreversibly and silently, because the part still runs
  afterwards at the wrong clock. So the target rebuilds the matrix, derives the
  image only from a validated variant, and proves through the injector's inverse
  mode that the image leaves the calibration word unprogrammed and does fetch
  it, so the answer cannot be vacuously true of another part's HEX. External
  image and whole-command overrides are rejected, and without `python3` it
  refuses to program rather than flash unchecked.

  The programmer's erase behaviour is a fail-closed bench transaction rather
  than a warning. `pic12f675-preflight` retains a read-only baseline -- reader
  binary and version, device ID and revision, full read-HEX digest, the
  calibration word, CONFIG and the bandgap field -- and `pic12f675-program`
  requires that baseline, repeats the read immediately before writing, compares,
  and reads again afterwards. A changed trim, a failed write or a failed
  post-read retains FAIL evidence and fails the target; the evidence directory
  is reserved before programming, so even an interruption leaves a `PENDING`
  account, and evidence is never overwritten. pk2cmd is the only pinned readback
  dialect: ipecmd remains available for the write but must be paired with a
  pk2cmd reader, because the Makefile does not guess an untested read argv.
  Fake-tool coverage exercises the transaction, not trim preservation on real
  silicon, so it enables the `1.x.y` bench check without standing in for it.

- **The PIC12F675 is fully integrated into the release pipeline**, with its
  three shipped images, three soak combinations and both aggregate logs joining
  the canonical sets and the retained-evidence inventory. Because the release
  soak drives the derived image rather than the shipped HEX, the part is
  threaded like the ATtiny202, whose soak drives the ELF. The staging apparatus
  that had withheld the part is retired with the graduation, and the manifest
  generator's arms stay cross-checked against the canonical set in both
  directions, so a future part added without its manifest arm fails the release
  rather than publishing a PIC labelled as an ATtiny with AVR fuse bytes.

- **The PIC12F675's three datasheet-read risks are closed** (DS41190G, read
  2026-08-11). None of them needed silicon, only the datasheet.

  - **Watchdog period.** The risk item had *assumed* the spread was no worse
    than the PIC10F32x's -37%/+69%; measured, it is -41%/+47%, and +76% at
    extended temperature -- worse at both ends. The assumption was the defect,
    not the design: the prescaler stays at 1:16 because the argument rests on
    the **minimum**, 10 ms x 16 = 160 ms against a conservative 16 ms
    compile-time pet bound, a factor of 10.
  - **Brown-out.** The detector trips at 2.025-2.175 V with a 100 us minimum
    excursion. Against peripherals that want more than 4 V, enabling it is
    therefore **not** the protection it looks like, and this part has no field
    to raise the trip point. That is a hardware-design constraint, now recorded
    with numbers.
  - **Oscillator accuracy.** +/-1% at 3.5 V and 25 C, +/-2% over 0-85 C, but
    **+/-5%** over the industrial and extended ranges. At the -5% corner the
    relay coil pulse degrades from a 3x to a 2.85x margin over the TQ-L2's 4 ms
    minimum, and the rough physical pet estimate becomes 13.68 ms, still inside
    the 16 ms compile-time bound. Debounce is unaffected in the way that
    matters, because the core counts samples rather than milliseconds.

- **`make test-pinout-alignment`.** The ASCII package-pinout diagrams are what
  somebody wires a board from, and nothing checked them. The PIC12F675 DIP-8
  diagram had shipped with one extra leading space on its supply row, putting
  that row's package walls one column right of every other row. It rendered
  visibly stepped and survived review, because that is the class of defect a
  reader's eye completes for them. The gate derives each box's wall columns from
  its corner rows, and asserts a floor on the number of diagrams found so a
  checker that has stopped recognizing them fails rather than passing quietly. A
  sweep of the other three found no second instance.

- **`make test-todo-index`**, because `TODO.md` states an index invariant that
  nothing checked -- each row's stable ID matches exactly one open section --
  and it had drifted. The gate pins the correspondence both ways and checks each
  row's tier column, and an ID's prefix, against the section it indexes.

- **Authored-header MISRA findings now fail closed.** A suppression review
  measured that cppcheck 2.13.0 leaves `--error-exitcode` unset for some
  findings located in an included header, so such a finding was printed and then
  ignored. Which ones is rule-dependent rather than purely location-dependent,
  which is why the project parses rather than trying to know: all five recipes
  force a structured diagnostic format and pass the output through a
  repository-owned parser that fails every unwaived record in authored `src/`
  code, independently of cppcheck's status.

- **The PIC shipping-source coverage oracle no longer takes source line numbers
  as input.** It asserted five required constructs by literal line number, so an
  edit that merely moved the shell reported the guards themselves as missing:
  the main-loop refactor in this release shifted the PIC12F675 loop by thirteen
  lines and fired six violations against a shell whose behaviour was unchanged,
  and the same breakage sat latent in the PIC10F322 arm. Anchors are located by
  the source text gcov already carries now, and location is fail-closed -- an
  anchor matching zero lines, or several, is a failure -- so a guarded construct
  cannot be renamed, deleted or duplicated and quietly stop being checked.

- The PIC12F675 target fault matrix gained a case that exercises the
  output-integrity predicate one clause at a time, and its calibration fault is
  now physically realizable: the matrix formerly flipped a bit this part does not
  implement, since only the top six bits of the calibration word exist on
  silicon.

### Fixed

- Local CI mutation skips are authorized per substrate now, so skipping the PIC
  toolchain cannot hide a missing ATtiny202 lane and skipping the ATtiny202
  cannot hide missing PIC coverage. Partial runs no longer claim they are
  safe-to-push reproductions.
- PIC12F675 mutation results fail closed by reason: each row must produce a
  named simulator, fault-injection, lock-step, target-I/O or soak failure before
  receiving kill credit, while compile failures, timeouts, incomplete checker
  output and unrelated nonzero exits are errors. A broken unmutated baseline
  stays fatal even in partial mode, while genuine tool absence stays skippable.
- PIC libgpsim soaks propagate a core-advance failure through startup, liveness
  holds and the duration loop instead of discarding it and repeatedly retrying a
  wedged simulator. A wedge stops at the resume cap, reports the milliseconds it
  actually advanced, and cannot emit a full-duration result record.
- The direct PIC12F675 soak-binary target builds and validates its simulator
  image and symbol inputs before deriving the shadow address, so it works from a
  clean tree, and its tick and per-variant blocking times are derived from
  constants the firmware itself consumes rather than restated.
- The Makefile name contract walks every shell statement produced by a lone
  Make-variable expansion instead of inspecting only the first, so a shell-local
  prefix in the first statement stays local while real environment channels in
  later statements are checked against their own child commands.

## [0.9.8] - 2026-08-08

This release renames every published image, every part-scoped make goal and most
Makefile variables. Upgrading a source checkout needs one `make clean` before
the first new build; the old-to-new image mapping is in
[`release/README.md`](release/README.md).

### Added

- `make release-preflight`, which runs every release capability and tool-version
  check then exits before any clean, build or staging step, so a release that
  cannot succeed fails in seconds rather than a day in. It needs no version and
  works from a dirty branch.
- A retained `RENAME_IDENTITY.md`, proving the rename changed no image byte it
  did not declare: seventeen images bit-identical to `v0.9.7`, one intentional
  change, nothing else. Tag CI regenerates it from a clean build and requires a
  byte-for-byte match.
- A **Datasheet References** section in `DESIGN_DOCUMENTATION.adoc`, tracing each
  load-bearing PIC10F322 and ATtiny13A decision to its vendor document and
  labelling how strongly each is enforced. The AVR Classic and AVR-XT electrical
  parameters are deliberately absent, because no citation for them exists in this
  repository and a guessed section number is worse than none; tracked in
  `TODO.md`.
- An enforced guarantee that a mechanically stuck footswitch produces neither
  recovery nor a spontaneous second toggle while the fault persists, and does
  recover once it clears. Only the first half was stated before, and only as an
  intention.
- Gates for the classes this release's own rename kept exposing. Make overrides,
  `print-<VAR>` queries, documented goals, prose variable names and environment
  handed to a child must each name something that exists; compile-time guards
  must be proven to fire; analyzers and single-selector lanes must reject an
  unrecognised variant rather than silently do less; `clean` must remove what the
  Makefile builds; each injected fuse byte must be the byte avrdude burns; and
  every per-variant map must be registered.
- Wall-clock bounds on every mutant, toolchain probe and CI job, none of which
  had one. Expiry is classified as an infrastructure error rather than a kill, so
  a hung run cannot report as a clean one.

### Changed

- **Every released image is renamed** to `bypass-<mcu>-<output stage>.hex`, with
  the MCU field mandatory. A bare `bypass_cd4053.hex` was previously the
  ATtiny13a image identified by omission, and nothing in the name stopped a
  builder flashing the 1.2 MHz ATtiny13a build onto an ATtiny85. Historical
  `release/vX.Y.Z/` directories keep their names, because a detached signature
  covers their `SHA256SUMS`.
- **One output-stage vocabulary** -- `cd4053_simple`, `cd4053_with_mute`,
  `tq2_l2_5v_relay` -- replacing three that named the same three stages in
  different words. Breaking for command lines, make goals, release soak
  combination names and retained evidence filenames.
- **Every part-scoped goal is named after its part**: `all13` to `attiny13a`,
  `pic` to `pic10f322`, `pic320-*` to `pic10f320-*`. `make all` now builds every
  part rather than the ATtiny13a alone, skipping by name where a cross-toolchain
  is absent unless `STRICT_TOOLS=1`.
- **Chip-scoped Makefile variables carry their chip's name.** `PIC_FLASH_WORDS`
  was 512, a PIC10F322 fact under a family name, and a variable mis-scoped that
  way produces a passing test rather than a failing one. The C-side compiler
  macros deliberately did not move, being the firmware's interface rather than
  the build system's.
- Soak selectors take a part name rather than a chip number, so
  `AVR_SOAK_CHIP=attiny85` replaces `AVR_SOAK_CHIP=85`. Nothing published moves.

### Fixed

- **A PIC10F320 relay-coil latch upset could remain energized indefinitely**
  while healthy firmware pet the watchdog. The relay variant now reasserts both
  coil outputs low after every accepted timer event, clearing an idle-phase upset
  within about one timer period. This bounds per-channel coil and driver energy;
  it does not claim a short accidental pulse cannot mechanically switch the
  relay. It costs one word, and is the release's only intentional image change.
- The PIC10F320 gpsim lanes ran the 256-word part's image against the 512-word
  part's device model and reported a pass, because a shared processor selector
  was renamed on one side only. Introduced on this branch, so no published
  release is affected.
- The PIC mutation lane was silently disabled twice over: the PIC10F322 soak
  driver had not compiled since the vocabulary change, and the mutation runner
  composed its baseline image path from the retired naming scheme. Both degraded
  to a skip rather than a failure, and the first would also have failed the
  `v0.9.8` release soak. The inventory is back to 94 killed with none survived,
  errored or skipped.
- `make release` could not have completed, because the AVR soak binary was
  renamed on one side only and nothing builds those binaries outside a real
  release.
- The classic-AVR watchdog mutant asked for two seconds of simulated soak and got
  the 24-hour default, because its overrides named variables this release had
  renamed. One local run sat in that single mutant for over ten hours.
- `make clean` stopped removing nine of the binaries it builds, and `clean-tests`
  stopped removing anything in the classic-AVR lane, both because their
  hand-written lists did not follow the rename.
- The fuse checker could pass without reading the Makefile. Its eleven `#ifndef`
  fallbacks, ten of them the then-current bytes, meant a renamed macro produced a
  green run over stale values; they are now `#error`s naming their variable.
- `MISRA_COMPLIANCE.md`'s documented sweep named retired variant names, so it
  analyzed zero of the three output drivers and exited 0.
- The PIC hardware-stack gate rejected every real image once it began reading
  `psect` directives, and separately could ignore a call whose target used an
  unrecognized prefix. The measurement was never wrong; the gate refused to
  produce one.
- Two release-integrity holes: a stale exported `RELEASE_EXPECTED_IMAGES` could
  let an incomplete image set pass the verifier's four-way comparison, and staged
  classic-AVR HEX bytes were not bound to the ELFs qualification had exercised,
  so a change at the copy boundary would have been recorded as its own truth.
- Host Python gates now declare a 3.7 minimum and fail with an actionable
  diagnostic instead of an internal `TypeError`.
- The recorded reason the ATtiny202 harness cannot measure busy-delay width was
  wrong. yasimavr does model multi-cycle instruction timing; the loss comes from
  `SimLoop::run()` rewinding the cycle counter. Reported upstream and fixed
  there, though the pinned release does not carry the fix, so no test behaviour
  changes and absolute pulse width stays with the disassembly oracle. The shipped
  images were always correct for real 2 MHz silicon.

## [0.9.7] - 2026-08-01

> **Historical detail.** This entry is a post-release cleanup pass whose 44
> items were tracked individually. The completed work journal remains available
> from Git history at commit `69f8bbf`.

A checkout taken under `core.autocrlf=true` before this release holds corrupted
release artifacts and should be re-cloned.

### Added

- `make test-soak-reset-witness`, which builds the soak driver twice against the
  same healthy ATtiny85 image -- untouched, and with a compile-time fixture that
  stops the main loop petting the dog -- and requires the first to pass with no
  watchdog failures and the second to fail with one. The control half is what
  stops a permanently broken soak from satisfying the failing half on its own.
- A Classic AVR soak-lane mutant, giving that family the coverage the other
  three already had. It empties `hw_wdt_pet()` at its definition, so the call
  site remains and the build stays clean, and is killed by the soak's reset
  witness. The pinned mutation inventory goes from **93 to 94**.
- `make test-supply-chain`, `make test-fetch-yasimavr` and
  `make test-pic320-coverage-archive`, pinning respectively the integrity
  contract for every external input, the venv fetcher's safety properties, and
  the PIC10F320 coverage target against a source-archive fixture.

### Changed

- **PIC10F320 is release-supported**, in the unified `v0.9.6` image set, keeping
  its constrained-target architecture and its assurance caveat.
- **`LICENSE` names one copyright holder.** It read `Copyright (c) 2026
  matt-garman` while all 55 project-authored source headers read `Copyright (c)
  Matthew Garman`, and the release signing key carried a third form. MIT grants
  *from* the named holder, so the notice is what a downstream license review
  reads to identify who could grant a relicense or be party to an assignment --
  a role a GitHub handle does not fill. It now matches the source headers and
  adds a contact path that travels into every downstream copy. Published
  releases ship images and provenance records rather than `LICENSE`, so no
  signed artifact carries the superseded string.
- **The two vendored yasimavr patches carry their licensing**, naming the pinned
  yasimavr 0.1.6 source, its upstream copyright holder and GPL-3.0-or-later
  terms alongside upstream's verbatim GPLv3 text. The root MIT grant is clarified
  to exclude third-party material carrying its own license.
- External supply-chain inputs are pinned and integrity-checked: reviewed XC8 and
  PIC DFP hashes verified before either download executes, every workflow action
  pinned to a full commit SHA, checkout credential persistence disabled and the
  publication token scoped, the yasimavr environment hash-locked without
  dependency resolution, and the ATtiny_DFP cache tree re-hashed on every use
  rather than trusted once.
- `test` and `test-long` are built from one gate inventory, because each carried
  its own hand-maintained prerequisite line for the same 46 gates -- so a new
  gate could land in only one of them, and the one it would miss is `test-long`,
  the release gate. The expansions are byte-identical to the lines they replace.
- **The two throwaway-repository builders share one walk**, `test/scratch_tree.sh`.
  Both copy the tree into a temporary directory and run Make inside it, but they
  learned about a new file by different means -- an extension-allowlist walk
  versus a hand-enumerated list -- and a shared header made a prerequisite of
  both chips' soak binaries broke each in turn. In the mutation runner that
  omission is silent: a missing file fails the baseline probe, a failed baseline
  is recorded as a *skip*, and 18 mutants went unenforced while the run reported
  every mutant it did evaluate as killed.
- The PIC10F320 lane reuses the PIC10F322 harnesses rather than duplicating them,
  retiring over a thousand duplicated lines behind thin per-part adapters that
  keep processor defaults, output vocabularies, program-space limits and fault
  counts explicit. Not one simulator operation is reordered. Consolidating
  exposed a real defect: `footsw_set(1)` drives the footswitch pin low --
  PRESSED -- while two of the four harnesses documented it as released.
- The PIC10F320 documentation set has one owner per kind of claim, its lane
  inventory, assurance argument and mutation mechanics having been repeated
  across three documents with every change-prone count living in two places at
  once. No count moved.

### Fixed

- **The Classic AVR soak was watching a signal simavr never raises for a
  watchdog reset.** It recorded a failure only on `cpu_Crashed`, which simavr 1.6
  sets solely from an illegal opcode or stack crash; its watchdog path resets the
  core in place and leaves it running. The six Classic AVR release soak
  combinations could therefore run a full 24 h and report zero watchdog failures
  without ever having been able to observe one. The soak now installs simavr's
  own reset callback and charges every invocation to the failure count.
- **`attiny202-soak` could report success having soaked nothing.** It was the
  only one of four AVR-XT harness targets missing the guards its siblings share,
  while its header comment claimed it had them: a bogus variant selector exited
  0 where the siblings exit 2, blaming an absent device pack in a run that had
  just built and budget-checked all three images. The target is a
  release-qualification input and each soak log is published evidence, so
  "soaked nothing" must never read as "soak passed".
- **Three layers of the ATtiny202 matrix could go green having exercised part of
  it.** A skipped variant still leaves its target at exit 0, so exit status alone
  never proved coverage; CI compensated by counting PASS markers but sized the
  expected count from a user-overridable variable, so one override shrank the
  build and the expectation together and one PASS was accepted where three were
  due. The count comes from the part's own `override` list now, and the target
  rejects incomplete, empty, duplicate and unsupported variant requests before
  running any simulator lane. One hardcoded count is deliberately left
  unconverted, as a cross-check on the variable the other four read.
- **Both soak families could hold a liveness verdict open across the event it was
  watching for.** The PIC soak sampled LED state only at the endpoints of a
  multi-millisecond hold, so a rapid even-numbered retrigger collapsed into an
  unchanged endpoint and read as no activity; the AVR-XT soak checked its reset
  witnesses on a schedule that could miss the final round-trip before the verdict.
- **Git line-ending conversion could invalidate release bytes and signatures.**
  With no `.gitattributes`, a checkout under `core.autocrlf=true` -- the setting
  Git for Windows recommends -- rewrote release artifacts, so images no longer
  matched `SHA256SUMS` and the detached signature no longer verified. The two
  records the qualification verifier reads by exact whole-line match were
  convertible too, so a CRLF checkout made the verifier reject a correct release:
  fail-closed, but on the command `release/README.md` tells auditors to run.
  Those classes are pinned to LF, and because an extension allowlist is what let
  them be missed in the first place, a repository-wide default backstops it so a
  class nobody has named yet cannot inherit the platform default.
- **`scripts/fetch_yasimavr.sh` could recursively delete a caller-named
  destination.** The documented caller-selectable venv directory was assigned
  straight to the path `rm -rf` then consumed, so a typo, the repository root or
  any existing non-venv directory could take unrelated data with it. The fetcher
  now canonicalizes physical paths and refuses filesystem and repository roots,
  destination symlinks, non-directories, missing parents and existing
  directories without a schema-valid private stamp; it builds in a randomized
  sibling, installs with a no-clobber rename, and restores the prior venv after a
  failure or a signal rather than deleting anything caller-derived.
- **The release orchestrator had four fail-open edges**: it could stage
  production output outside the canonical version directory, accepted an
  unvalidated soak-concurrency value, and proceeded from a failed or empty
  executable version probe. Soak workers now run in isolated process groups that
  every exit path terminates and reaps, and a failed run's evidence is preserved
  for diagnosis rather than cleaned away.
- **The stack high-water-mark gate overstated free SRAM by four bytes**, because
  it asserted a margin between the deepest stack pointer and BSS but measured
  down to the first SRAM byte, below BSS, counting the four static bytes living
  there as free. The error ran optimistic inside a gate: at the 8-byte floor the
  stack could reach within 4 free bytes of BSS while the message announced 8. The
  floor comes from the firmware ELF's `__bss_end` now, so a static added later
  tightens the gate by itself.
- **Historical release provenance overclaimed the soak matrix.** Manifests for
  `v0.9.0`-`v0.9.4` claim a 24-hour parallel soak of every variant and MCU,
  broader than the retained evidence: the ATtiny13a images were not soaked
  directly, simavr not modelling their watchdog reset, and were covered by the
  full suite and the core-identical tinyx5 soaks, as each manifest's own
  limitation note already said. `release/README.md` carries a live erratum
  linking each affected release's note; the historical snapshots are unchanged.
- **The ATtiny202 shell shipped an unresolved `CONFIRM` note on its BOD fuse**, a
  bring-up instruction to the reader published on a release-supported part, on
  the fuse that establishes the peripheral-safe voltage floor. It is answered in
  place from the pinned device pack, and pins down the trap that makes the
  question worth asking: the pack carries two BOD level enums, one for the
  control register and one for the fuse, and decoding a BODCFG byte with the
  register enum yields a confident wrong answer. No `CONFIRM`, `TODO` or `FIXME`
  marker remains under `src/`.
- Resource tables and prose claims had drifted from the build in the optimistic
  direction: three tables were stale on every row, the section opened by claiming
  large headroom on every part while its own PIC10F320 table sits two screens
  later at 95.3% of 256 words, and two Makefile gate comments named ceilings the
  firmware had long passed. Neither drift originated in the build -- the shipped
  release evidence was right throughout -- and nothing in the Makefile, scripts,
  tests or CI read these tables, so no gate could have caught it. The BOD/BOR
  failsafe list covered two of the six release parts while its framing promised
  per-part coverage.
- A non-executable Intel HEX validator passed the build's presence check, because
  for a value containing a slash dash's `command -v` succeeds on a file that
  merely *exists*; it then failed with "Permission denied" after the compiler had
  produced the image it was supposed to check.
- `ci-local.sh --skip-attiny202` could not pass: push mode relaxed the mutation
  requirement for the PIC skip only, so skipping the ATtiny202 toolchain removed
  its lane and then failed `test-long` for the very mutants the skip had
  intentionally removed. The routing regression had codified the defect by
  expecting that exit status.
- `MANIFEST.md` carried a repo-relative link that 404s on the release page, where
  the same file is published verbatim as the release notes. It is absolute and
  pinned to the release tag now, correct in both contexts and pointing at the
  matching source revision rather than a moving `main`.
- The default host suite failed in an extracted source archive, the PIC10F320
  coverage checker having inspected the file's Git index mode unconditionally,
  which no source tarball has.
- Strict CI and release environments omitted prerequisites they assume. Git,
  GnuPG and PyYAML are installed and asserted before the strict suites and before
  release signature, qualification or history verification, and workflow
  validation enforces executable assertions and placement before first use rather
  than accepting whatever the runner image happens to contain.
- Comment-only corrections on shipped firmware: the PIC10F320 bypass and engage
  call sites named the pin levels backwards, and an adjacent comment cited a
  pure-core state member that does not exist. Pinned before-and-after builds
  produced all 18 images byte-identically.
- Assorted live-documentation defects: the debounce write-up read
  `PRESSED_THRESH` as eight milliseconds where it counts eight sample instants;
  the MISRA record did not separate genuine AVR register-access deviations from
  cross-translation-unit artifacts or PIC10F320 analyzer accommodations, though
  no waiver changed; the toolchain record said KLEE was absent where a validated
  local solver run exists; imported PIC10F320 harnesses named the pre-merge
  project's make targets; and the two `.gitignore` files disagreed about
  `commit_msg.txt`.

## [0.9.6] - 2026-07-30

The first unified release: the PIC10F320 is merged in from its own repository
and the ATtiny202 is promoted out of development-only, bringing the product set
to six parts and 18 images.

### Added

- **PIC10F320 integrated as a release-supported target**, the first whose
  firmware does *not* compile the verified core but implements the debounce
  algorithm directly, because 256 words of flash cannot hold the shared-core
  architecture. Merged from a separate repository with its full history
  preserved. What that difference does and does not buy is in
  `docs/pic10f320_special_case.md`, and every decision taken in
  `docs/pic10f320_merge_plan.md`.
- **The validation lanes that let a part which does not link the core still earn
  a release.** Firmware-to-core equivalence is proved against `src/bypass_pure.c`
  itself over 266,144 sequences covering all 66 reachable model states, beside
  the fault, lock-step, coverage, timing and soak lanes its peers have. The host
  subset needs only a C compiler and gcov, so it runs on every push, and three
  full-duration soak combinations are required by the release pipeline.
- **A dependency-free return-stack oracle for the final PIC10F320 image**, which
  parses Intel HEX strictly and explores reachable control flow against the
  architectural eight-entry hardware stack. Its state and return stack preserve
  the 9-bit program counter while instruction fetch alone aliases through the low
  eight bits to 256 physical words, which is the distinction it exists to get
  right.
- **ATtiny202 promoted from development-only to release-supported.** That
  classification was a scoping decision taken while its harness was being
  hardened, not a technical blocker. Its three images are now built, qualified,
  staged and reproduced, and its three release soak combinations run directly.
- **A canonical release product set**, `RELEASE_IMAGES`, enforced by the release
  script, the image verifier and its regression alike. The committed directory,
  the checksum entries and the fresh build were all previously derived by
  globbing, so three "independent" checks could agree perfectly on a release with
  an entire MCU missing.
- **The GitHub workflow files are validated locally.** Nothing had ever parsed
  them: the release regressions grep `release.yml` for fixed strings, which
  succeeds on a file GitHub cannot load, and the local CI script reproduced the
  job order from a comment header rather than from the workflow. An unquoted job
  name containing a colon-space took the entire CI matrix down after a full clean
  local pass. Both must parse now, and the workflow's job list must agree with
  the local script's mapping in both directions.
- **ATtiny202 lock-step co-simulation**, which closed the last structural
  verification gap on that part: the harness asserted observable behaviour only,
  so a shell reaching the right LED state by the wrong internal trajectory
  passed. After every settled tick it now requires the shell's context in
  simulated SRAM to equal the shipping core's state, reached through a ctypes
  bridge rather than a re-implementation that would have recreated the drift
  hazard the shared model header exists to eliminate.
- **An ATtiny202 mutation lane**, 19 mutants against the AVR-XT shell and the two
  shared coil-pulse widths, since nothing previously established that this lane's
  suite would fail on a defect in the shell it exists to test. It is gated on
  every kill target passing on the unmutated tree, because each `attiny202-*`
  target exits 0 on a missing input and would otherwise report 19 survivors as a
  clean run.
- A standing expected-image regression pinning the three-variant PIC10F320 HEX
  matrix to the reviewed XC8 V3.10 and DFP 1.9.189 baseline. It deliberately
  stays outside the mutation kill targets, so byte drift cannot mask whether each
  behavioural lane catches its assigned defect.
- ATtiny202 documentation to match its peers, including a **known gaps** section
  scoped to hardware-bench work: yasimavr's flat instruction timing, the
  unobservable force-reset completion, the two vendored simulator patches, the
  missing shell stack bound, and untested UPDI programming.

### Changed

- The ATtiny202 soak emits the same machine record and PASS line its peers do, so
  all three substrates are interchangeable to the release orchestrator, and its
  schedule moved onto a clock that excludes the time a liveness round-trip
  consumes. Scheduling on raw simulated time let each round-trip's ~120 ms eat
  the schedule: invisible over an hour, enough to silently drop the last checks
  at 24 h and fail an otherwise perfect run.
- The return-stack oracle takes the implemented program memory from the device
  pack rather than hardcoding it, and rejects an image carrying data above the
  declared size. Under-declaring was the dangerous direction: the fetch alias
  would fold a high program counter onto a different instruction and could report
  a *lower* stack depth than the truth.
- The one fail-closed mutation run provisions the ATtiny202 toolchain too, so a
  single authoritative run still covers every substrate, and skip accounting
  names which substrate went unexercised.
- The PIC CI job covers both PIC parts, the strict-tools inventory covers
  optional-tool recipes for both, and the simulator known-gaps documentation is
  one shared PIC document rather than two copies that had already drifted. MISRA
  documentation is a per-target statement rather than a comparison against
  another project.

### Fixed

- **The mutation sandbox mirrored four extensions one level down**, so a header
  that is a prerequisite of both chips' soak binaries and all three target lanes
  never reached it, and 18 PIC mutants were silently skipped. Two smaller gaps
  closed with it: the PIC10F320 sandboxes omitted the folded gpsim wrappers, so a
  cadence mutant falsely counted as killed, and the shared gpsim preflight read
  the Git index outside a work tree, where an empty mode looked like failure. The
  copy stays an extension allowlist by design, because `test/` also holds build
  products and mirroring them with preserved mtimes could make Make skip a
  rebuild and score a mutant against unmutated source. With all three closed, the
  full run completes 93 mutants: 93 killed, none survived, errored or skipped.
- **`pic320-test-gpsim` had no simulator probe at all**, so a strict run on a
  host without gpsim reported all PIC10F320 pre-hardware checks complete having
  run none of its six scenarios: the wrappers exit 0 on a missing simulator by
  design, and nothing above them looked. The port had also dropped the tool-path
  passthrough, so that override was ignored and the lane tested whatever `gpsim`
  was on `PATH`.
- **The Classic AVR interrupt-handshake fault injection accepted the wrong
  evidence**, treating an already-dark BYPASS LED after roughly 7 ms as proof of
  watchdog recovery. It starts ENGAGED now, corrupts the handshake before the
  main loop can read it, and requires both a device-reset witness and fail-safe
  dark output after the reset.
- **Mutation results conserve an immutable 93-mutant inventory** across seven
  pinned categories: dispatched plus skipped must equal 93, killed plus survived
  plus errored must equal dispatched. Inventory records, baseline commands,
  worker exits, sandbox setup, result pairs and status grammar fail closed
  rather than letting a shortened run report that all mutants were killed, and a
  skip says whether the tool was absent or the baseline failed.
- **Release publication requires both cryptographic signatures the trust model
  promises.** CI verifies the detached checksum signature and the exact remote
  annotated tag object against the checked-in public key and pinned fingerprint,
  with lightweight, unsigned, wrong-key, replaced and moved tags all failing
  closed, and the signing instructions pin the key rather than relying on the
  operator's GPG default.
- **Tag CI binds retained 24-hour qualification to Git history**: the tagged
  release commit must be a single-parent, artifact-only child of the exact source
  commit the qualification record names. Qualification is machine-verifiable
  before publication against an immutable soak inventory, an exact
  retained-evidence set, a strict schema and one identity-bearing result record
  per log.
- **Dry-run artifacts cannot be staged under the release tree**, and tag CI
  requires a production-mode manifest while independently rejecting the dry-run
  banner. The output path is revalidated immediately before staging, and
  tag-derived values reach privileged workflow shells through the environment
  rather than source-text interpolation.
- **A `VARIANTS` override could weaken the release contract along with the
  requested build.** Both PIC producers require the complete immutable
  output-variant matrix before invoking the compiler, and the canonical release
  entries derive from that immutable set rather than from the request.
- **`pic320` and `pic320-size` printed "skipping" and then built anyway**,
  because the skip helper is `exit 0` in non-strict mode and exits only its own
  shell, so a guard on its own recipe line skipped nothing. An audit found no
  other instance in the Makefile.
- Aggregates could report more than they ran: the PIC "all variants" aggregates
  accepted proper subsets of the supported matrix and reported that all passed,
  and the PIC10F320 real-HEX aggregate now requires explicit completion markers
  from each lane.
- Stale or partial build products could be consumed as evidence. PIC builds
  invalidate the generated assembly and symbol sidecars with each HEX and remove
  the complete set after failure or interruption; a current image without fresh
  assembly now fails rather than passing on stale evidence or an absent-tool
  skip; a failed PIC10F320 variant no longer leaves a partial image set; and the
  standalone selectors rebuild the variant they were asked for.
- Release provenance probes both selected XC8 compilers fail-closed and records
  target-qualified compiler paths and versions, rather than attributing both PIC
  image families to one variable.
- Assorted lane defects found while merging: the PIC10F320 gpsim lane ran the
  PIC10F322 cadence checkpoints rather than its own forked stimulus, the ported
  flash-budget comparison conflated "not over budget" with "the comparison tool
  failed", the harnesses did not share one exact pin-name resolver and so
  accepted substring decoys, the lock-step progress regression had retained only
  the PIC10F322 source path, the interruption regression could not prove the
  signal reached each build recipe, and the CONFIG lane handed an unexpanded glob
  to its checker where its peer skipped.
- Documentation and qualification records separate what was rehearsed from what
  was retained, and the release guide scopes the qualification soak and evidence
  contract to unified releases rather than directing earlier ones to files and
  targets they predate.

## [0.9.5] - 2026-07-18

### Added

- **ATtiny202 validation brought up to the level of its peers.** Production
  fuses are verified fail-closed against the complete Makefile-defined set, the
  built image is read for its exact PA2/PA3 startup, engage and bypass
  sequences with relay-coil exclusion and parked-low outputs, and fault
  injection requires every pinned guard to execute with witnessed watchdog
  resets and a healthy negative control.
- **A disassembly oracle that reads the ATtiny202 5 ms mute and 12 ms relay
  pulse widths out of the built image** rather than trusting the simulator to
  execute delays. *(The reason first given for it -- that yasimavr does not
  model instruction timing -- was wrong; see the correction under `0.9.8`. The
  oracle itself is unchanged and still correct.)*

### Changed

- **ATtiny202 is classified development-only and non-release.** Its build and
  simulator lane stay available, while release images, reproduction and
  long-soak qualification remain scoped to Classic AVR and PIC10F322.
- **Sanity gates now assert the complete settled output latch and startup GPIO
  direction state** on Classic AVR, AVR-XT, ATtiny202 and PIC10F322, rather
  than a required subset of each. The subset check had let a spare RA2
  direction upset pass on the simple-CD4053 PIC10F322 variant.
- **Make and release-script runs hold one worktree-local lock**, so concurrent
  processes can no longer replace each other's firmware, test, coverage and
  simulator artifacts.

### Fixed

- **Releases `v0.9.0` through `v0.9.2` ship a fail-dangerous polarity, and
  their documentation now says so prominently.** In the superseded `*_tmux*`
  images the direct-drive polarity maps the absent or undriven-MCU pull-down
  state to ENGAGED instead of fail-safe BYPASS. Users of those releases should
  move to the unified images from `v0.9.3` or later.
- **Five checks could report success without having checked anything.** The
  KLEE target linked the symbolic harness without the shipping
  `src/bypass_pure.c` bitcode, so unresolved core calls stood in for a proof of
  the real firmware. A missing CBMC or cppcheck became a silent skip under
  `STRICT_TOOLS=1`. A soak passed with a liveness interval longer than the run
  itself, so no responsiveness round-trip ever happened. PIC fault injection
  reported PASS without confirming register write-back, simulator progress,
  per-variant completion counts or restored negative controls. Release
  reproduction could compare a committed directory against itself. Each now
  fails closed.
- **Tap-timing documentation now scopes its numbers to what they describe.**
  The 33 ms minimum applies to the pure model, the ISR-driven AVR shells and
  the simple PIC variant; the polled PIC variants carry qualification budgets
  of 38 ms mute and 45 ms relay, and a pending timer can shorten the ideal path
  by roughly one tick.
- **Image generation, flash-budget acceptance, gpsim wrappers and PIC variant
  aggregates fail closed** on missing, stale, partial, malformed, over-budget or
  duplicate input instead of proceeding on it.
- **Long release runs re-check provenance immediately before staging.** The
  recorded source `HEAD` and worktree cleanliness are confirmed after
  validation, so artifacts and evidence cannot attach to stale provenance. The
  dirty-tree exception is restricted to non-publishable dry runs.

## [0.9.4] - 2026-07-11

### Added
- `make pic-test-lockstep`: a libgpsim PIC10F322 gate that runs the XC8-built
  HEX and compares live `_ctx_` SRAM against the shared pure-model state after
  each completed main-loop iteration.
- `make pic-test-io`: a libgpsim PIC10F322 GPIO/timing gate that checks real
  TRISA/ANSELA/LATA/PORTA transitions, relay coil exclusion, and analog-switch /
  relay pulse widths from the built HEX.
- `make pic-test-target-variants`: a fail-closed aggregate for the PIC
  target-level gates (`pic-test-fault`, `pic-test-lockstep`, and `pic-test-io`)
  across every PIC variant. Component targets may still skip cleanly on a local
  host without PIC tools; this aggregate requires every PASS marker.
- PIC gpsim register-level coverage now includes a mid-debounce `PRESS1_EARLY`
  sample and full BYPASS `LATA` assertions, catching a collapsed tick gate and
  checking all settled analog-switch control bits in both directions.
- Mutation coverage for exact `WPUA`, TMR2IF cadence, ANSELA output masks,
  muted-CD4053 startup ordering, mute-window duration, and relay pulse duration.

### Changed
- CI and release now run `make pic-test-target-variants STRICT_TOOLS=1`, so
  target-level PIC fault, lock-step, and GPIO/timing validation are required.
- Release creation runs mutation testing in strict mode so PIC mutants cannot
  disappear behind skipped target tooling.

### Fixed
- **PIC10F322 weak-pull-up validation now requires the exact RA3-only state.**
  Extra enabled `WPUA` bits on output pins are treated as configuration damage
  and force watchdog recovery.
- **Muted CD4053 startup no longer traverses ENGAGED before settling BYPASS.**
  The driver asserts the bypass-side control first, waits the mute window, then
  releases the second control line.
- Lock-step stimulus is applied at a fresh loop boundary, avoiding relay phase
  lag and startup phase skew.

## [0.9.3] - 2026-07-11

### Added
- ATtiny202 development support: an AVR-XT firmware shell, avrxmega3 build and
  flash-budget gate, cppcheck/MISRA analysis, UPDI programming targets, and
  pinned ATtiny_DFP acquisition.
- A yasimavr functional, fault-injection, and soak harness for ATtiny202, plus a
  dedicated CI lane. The spare PA6 pin is actively driven low.

### Changed
- Build, coverage, mutation, and release gates now fail closed when required
  tools, outputs, percentages, or exact release image sets are missing.
- Release reproduction uses fresh build outputs and validates complete image
  sets instead of relying on committed artifacts alone.

### Fixed
- **TMUX4053 control-pin polarity was inverted on the direct-drive variants.**
  The MCU now uses one fail-safe polarity (BYPASS = pin low) for both CD4053 and
  TMUX4053 boards; the TMUX board's swapped analog throws already compensate for
  the CD4053 board's MOSFET inversion.

### Removed
- The redundant `cd4053_tmux` and `mute_tmux` variants and the
  `BYPASS_X4053_DIRECT_DRIVE` flag. The supported release matrix is now three
  variants (`cd4053`, `mute`, and `relay`) per MCU.

## [0.9.2] - 2026-07-09

### Added

- **The PIC10F322 per-tick sanity gate now checks `ANSELA`.** An SEU or EMI flip
  that re-selects an output pin as analog leaves `TRISA` unchanged while the LED
  goes dark or a control pin goes dead. That now forces a watchdog reset.
- **`test/README.md` records the two PIC properties gpsim cannot faithfully
  assert**, both of them bench guarantees: watchdog timing with brown-out
  behaviour, and the TMR2 prescaler select clamp, which gpsim models as 1:16
  where the datasheet says 1:64. The second hid the defect below.
- **`CHANGELOG.md`.**

### Changed

- **PIC10F322 core clock reduced from 16 MHz to 2 MHz** on HFINTOSC, roughly
  halving supply current from about 0.85 mA to about 0.43 mA at 5 V and emitting
  less high-frequency switching noise into the analog audio path. Low power is
  not a project goal. The reliability architecture is untouched: the busy-wait
  tick, the per-tick sanity gate and the LFINTOSC watchdog are unchanged, the
  1 ms tick is re-derived on the 1:4 Timer2 prescaler (`T2CON = 0x05`,
  `PR2 = 124`), and pulse widths and the watchdog margin are unaffected.
- **The PIC shell is renamed `pic10f32x` to `pic10f322`,** since the project
  targets that part specifically. Source files, include guards, the
  `BYPASS_MCU_PIC10F322` build macro and every build, test and documentation
  reference follow.
- **PIC `ctx_` fault injection is now deterministic.** The driver parks the core
  at the main-loop `CLRWDT`, located by opcode rather than a fixed address,
  before injecting, so no variant lands in the window where the integrator would
  overwrite the injected field before the gate reads it. At 2 MHz the previous
  settle produced intermittent false passes.
- **Design documents carry as-built banners and corrected Timer2 and oscillator
  descriptions**, including a `T2CKPS` table that listed 1, 4 and 16 and dropped
  the 1:64 code. `src/` license headers are normalized to
  `SPDX-License-Identifier: MIT`.

### Fixed

- **The PIC10F322 1 ms system tick ran about four times slow, at roughly 4 ms.**
  `init()` programmed `T2CON = 0x07`, selecting a 1:64 prescale where 1:16 was
  intended, stretching every debounce interval fourfold: press-confirm from
  about 8 ms to about 32 ms, release-lockout from about 25 ms to about 100 ms.
  Every simulation-based test masked it, because gpsim mis-models that prescaler
  code and the host and equivalence layers count ticks rather than elapsed time.
  Cross-checking the programmed register against the datasheet caught it. The
  behaviour was serviceable and not a safety regression, the watchdog margin
  being unaffected, but it is off-spec in the `v0.9.0` and `v0.9.1` prebuilt
  images.

> These PIC10F322 changes brought the shell to parity with the then-separate
> [pic10f320-bypass-firmware](https://github.com/matt-garman/pic10f320-bypass-firmware)
> project, which landed the same TMR2, 2 MHz and `ANSELA` work after the fork.
> The pure debounce core, the output drivers and the AVR targets are unaffected.
> That project is no longer separate; its target was merged into this repository
> at `0.9.6`.

## [0.9.1] - 2026-07-04

### Added
- **Per-tick configuration-SFR sanity gate on the PIC10F322 (SEU/EMI
  hardening).** Every main-loop tick now verifies the critical
  clock/watchdog/timer configuration registers (`OSCCON.IRCF`, `WDTCON.WDTPS`,
  `PR2`, `T2CON`); a corrupted value forces a watchdog reset that re-runs
  `init()`.
- `make pic-test-fault` (`test/pic/test_fault_pic.cc`): gpsim critical-SFR
  fault-injection test that corrupts each gate-guarded SFR — extended to the
  `nWPUEN` pull-up and the `ctx_` SRAM fields — and asserts recovery via a real
  watchdog reset. Wired into the release gate.

### Changed
- CI/build no longer degrades silently: a missing/misconfigured analyzer now
  fails loudly instead of skipping, and PIC fault injection is gated in CI.
- Refreshed the stale PIC TMR2 mutation pattern after the named-constant
  refactor so it kills again.
- Design-doc updates: TMUX4053 wiring and toolchain notes.

### Fixed
- Assorted documentation and comment typos.

## [0.9.0] - 2026-06-30

### Added
- Initial release: reference-quality footswitch **bypass firmware** (switch
  debounce → bypass/engage state → status LED) across three MCU families from
  one shared, formally-verified debounce core —
  - **ATtiny13a** (AVR classic, 1.2 MHz),
  - **ATtiny45 / ATtiny85** (AVR tinyx5, 1.0 MHz),
  - **PIC10F322** (16 MHz INTOSC).
- Functional-core / hardware-shell architecture: a pure, MCU-independent
  debounce core (`bypass_pure.c`) driven by thin per-MCU shells that apply the
  result to real hardware, so the same verified logic ships on every target.
- Five output variants per MCU: `cd4053`, `cd4053_tmux`, `mute`, `mute_tmux`,
  and `relay` (analog-switch, TMUX4053 direct-drive, muted, and TQ2-relay
  drives).
- Two-layer validation: a reference model plus a firmware↔model equivalence
  test that pins each shipping binary to the model tick-for-tick.
- Formal verification (bounded model check, symbolic single-step, and CBMC),
  a fault-injection harness with a firmware line-coverage gate, per-variant
  actuation-sequence checks, mutation testing, and a clean MISRA-C:2012 posture.
- Simulation soak testing: 24-hour parallel soaks of every release soak
  combination — simavr for the ATtiny45/85 combinations, gpsim / libgpsim for
  the PIC combinations — plus a PIC CONFIG-word check. The ATtiny13a images were
  covered by the full test suite and the core-identical tinyx5 soaks, but were
  not soaked directly because simavr cannot model their watchdog reset; see the
  [historical soak wording erratum](release/README.md#historical-soak-wording-erratum-v090-v094).
- Reproducible, fully-validated prebuilt-firmware release pipeline: pinned
  toolchain, SHA256-checksummed images, per-release `MANIFEST.md` provenance and
  evidence, and a tag-triggered CI job that rebuilds on a clean runner and fails
  the release on any hash mismatch.

[Unreleased]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.14...HEAD
[0.9.14]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.13...v0.9.14
[0.9.13]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.12...v0.9.13
[0.9.12]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.11...v0.9.12
[0.9.11]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.10...v0.9.11
[0.9.10]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.9...v0.9.10
[0.9.9]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.8...v0.9.9
[0.9.8]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.7...v0.9.8
[0.9.7]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.6...v0.9.7
[0.9.6]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.5...v0.9.6
[0.9.5]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.4...v0.9.5
[0.9.4]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.3...v0.9.4
[0.9.3]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.2...v0.9.3
[0.9.2]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/matt-garman/mcu-bypass-firmware/releases/tag/v0.9.0
