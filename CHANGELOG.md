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

- **`GOVERNANCE.md`**, a new top-level document owning how this project's
  documentation is authored, owned, retired and enforced. It carries the
  documentation authority map, the document lifecycle table, the standing rules,
  the branch-only working-document contract, an enforcement register naming every
  gated claim and the defect that motivated it, and the proof obligations a
  proposed gate must discharge in writing before it is written. That material was
  previously split between `README.md` and comments inside the release validator,
  where a rule's purpose was not readable by the author who hit it.

### Changed

- **`README.md` addresses its two audiences separately.** Flashing a released
  image and building from source are peer sections, the governance material has
  moved out to `GOVERNANCE.md`, and the file closes with a signpost naming every
  other document and what it is for.

- **Release topology is declared once and derived rather than restated.** How
  many parts, images, soak combinations, modular targets and shell source files a
  release contains is stated only in `release/README.md`'s bounded declaration.
  The gate protecting that ownership now derives those values from the Makefile's
  canonical sets instead of carrying hand-written copies, so it refuses any
  spelling of a restatement rather than the ones someone thought to list. Other
  documents point at the declaration.

- **`CHANGELOG.md` states where its concise-entry policy begins.** `0.9.11` is
  the first section written under it; earlier sections vary in depth because of
  the practice of their time rather than the size of the release.

### Fixed

- **A root-level AsciiDoc working document could reach a release unseen.** The
  branch-only working-document banner was recognized only in Markdown, so an
  AsciiDoc note at the repository root escaped the root-document allowlist while
  the live-tree sweeps still held it to the very bans a working document exists
  to be exempt from. The banner is now read in either documentation markup and in
  either emphasis spelling.

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
  `CHANGELOG.md` and `release/README.md` -- the dated heading, the
  `[Unreleased]` section that must survive the rename, both comparison links,
  the bounded contract line and the pre-tag transition line -- until the
  validator stopped objecting. Each is a pure function of the version being
  cut, the version before it and the date, and none records a decision.
  `scripts/release-prepare.sh` renders them through the same `release_render_*`
  functions the validator compares against, so writer and checker cannot
  disagree about a format and a mismatch has one repair. It writes structure,
  never prose: it refuses when `[Unreleased]` says nothing about the release,
  and refuses outright for a version already tagged or already holding a
  retained record. Every existing check stays; what goes away is the hand
  authoring, not the verification.

- **A release must now prove the commit the tag will name before the tag
  exists.** `scripts/make-release.sh` qualifies the source tree and stages
  `release/vX.Y.Z/` without touching Git, so until now no gate had ever run
  against the tree a tag actually carries -- the one that *contains* the
  release directory and the publication-registry append. That window cost
  `v0.9.12`, which passed every local gate, reproduced all 21 images bit for
  bit on the clean runner, and then failed re-running the gates on the tag's
  own tree. `scripts/verify-release-artifact-commit.sh` closes it: run after
  the artifact commit, it repeats the two checks tag CI makes before it builds
  and runs every gate whose verdict that commit can change
  (`RELEASE_ARTIFACT_GATES`), and it is now the only thing that prints the tag
  and push commands -- on success. A release that has not proved itself yields
  no command to paste. `docs/ci_parity.md` records the design and the remaining
  work; the script mutates nothing, as the rest of the release path does not.

### Changed

- **Documentation gates hold claims to their terms, not to their sentences.**
  Roughly seventeen places pinned the maintainer's own prose byte for byte, and
  the cost was not theoretical: capitalizing one letter of a README heading
  produced five test failures, and changing a period to a semicolon in a
  sentence that altered no claim, no number and no part failed a safety gate. A
  rule an author cannot satisfy by writing correctly eventually gets satisfied
  by deleting it. Nine fenced claims replace those pinned sentences. A claim is
  now bound by a named marker pair and held to the terms it must still state, so
  deleting the fence, emptying it, leaving it unclosed, inverting the claim, or
  keeping a denial while dropping what it denies each fail with the marker
  named -- and every rule carries an accept case that rewrites the same
  commitment in another voice. No property is dropped; only the technique
  changes.

- **`DESIGN_DOCUMENTATION.adoc` no longer carries a date or a source
  revision.** The PIC10F320 modular-build overrun was the last byte-pinned
  passage, mitigated by pinning its provenance because a measurement sat in
  durable prose. The measurement is gone -- it restated a conclusion the same
  sentence already drew -- and what remains is fenced as the overrun it records.
  A current-fact rule now refuses ISO dates and commit bindings in that
  document, so the mitigation cannot return in place of moving a measurement
  out. Git records when a thing was written and against what.

### Fixed

- **`v0.9.12` was tagged and never published: its own release-history gate
  refused it.** Tag CI rebuilt every image from the tagged source and confirmed
  all 21 reproduced bit for bit, then failed re-running `make test-long`.
  `test-release-history` requires a superseded release to declare what it did to
  the images it inherited, and a release's artifact commit is the one commit in
  which that declaration cannot land -- see the fixture defect below.
  `Publish GitHub Release` never ran. The signed tag and `release/v0.9.12/` are
  retained as the record of that cut rather than rewritten, so its
  `CHANGELOG.md` section and comparison link stay resolvable.

- **The release-history suite no longer holds a release to a declaration no
  tagged tree can carry.** `test-release-history` appends a synthetic future
  prerelease to the real published set, which moved the image-continuity gate's
  newest-release exemption off the release being cut. Every release therefore
  failed the suite from its own artifact commit onward, for a debt that commit
  cannot pay: it may change only `release/<version>/` and the publication
  registry append, and a declaration written any earlier names a version that is
  not yet published. The fixture now writes that declaration itself, in the
  source commit of the release it appends, with the gate's own release ordering
  and signed-list parse rather than a second copy of either. The register also
  records what `v0.9.12` did to the images it inherited.

## [0.9.12] - 2026-09-03

### Added

- **Release manifests now publish qualification-bound resource use.** Each image
  reports flash use against its reviewed ceiling, and the Resources section
  reports applicable static RAM, observed Classic AVR stack high-water,
  AVR-XT per-frame compiler bound, PIC12F675 Data-space and PIC return-stack
  results with their ceilings and margins. The AVR-XT figure is a per-frame
  bound, not an observed whole-path high-water mark.

- **Focused documentation and safety contracts now run under `make test`.**
  Durable links and anchors are checked, deliberately independent safety
  definitions remain structurally separate, and selected high-consequence
  AVR-XT and PIC guards are exercised under their target toolchains. Modular
  shells now reject missing or conflicting MCU/output selectors, and shared
  output drivers reject a foreign variant selector. Guard mutations are
  representative rather than exhaustive. Valid firmware behavior is unchanged.

- **`make pic10f320-program` flashes a built PIC10F320.** It mirrors
  `pic10f322-program` with its own `PIC10F320_PROG*` variables, and selects the
  output stage with `PIC10F320_VARIANT` -- the name its build goal reads, so the
  image flashed is the image built. Release manifests publish a source-checkout
  command for this part too, and each published PIC10F32x command is now pinned
  byte for byte to the Makefile command it names. No PIC10F32x programming
  command has been run against silicon under a written procedure.

### Changed

- **Changing measurements and inventories now stay with their executable or
  per-release authorities.** Maintained design documentation keeps stable
  capacities, reviewed ceilings and their enforcing gates, while exact resource
  results come from source- and toolchain-bound release evidence. Reader guides
  no longer duplicate release target, image, profile, evidence or soak
  inventories. Transient simavr watchdog timing, PIC loop-cycle/current and XC8
  optimization results are no longer maintained as current design/toolchain
  facts; the historical PIC10F320 fit experiment remains with its exact source
  commit, compiler and device-pack binding. The live documentation contract
  rejects representative unbound measurements and numeric topology copies.
  PIC12F675 source-checkout transaction semantics now have one maintained home
  in the release policy; the toolchain guide retains only tool-support facts.

- **Retained qualification evidence is now bound to what each operation
  produced.** Build and target-test logs bind their payload, source commit, role
  and identity through the qualification index. Manifest toolchain rows are
  rendered from qualification-bound toolchain evidence rather than parallel
  prose. Classic AVR clean-build and post-soak final-image phases now carry
  distinct roles rather than two generic build claims.

- **Release-state documentation now fails closed between releases.** A declared
  release must carry the pre-tag transition disclosure until a nonempty regular,
  non-symlinked qualification record exists. Root-level branch-only working
  documents must declare that status in their opening blockquote.

### Removed

- **Retired the flashing-simplicity design journal.** Shipped instructions stay
  in `FLASHING.md` and their executable checks; unresolved work stays in
  `TODO.md`, while historical reasoning remains in Git history.

- **Retired the one-shot v0.9.8 rename-identity lane from current
  qualification.** The signed v0.9.8 tag and report remain the historical
  authority, while current releases retain canonical image reproduction,
  expected-image identity, checksum and publication-inventory checks.

### Fixed

- **Newly generated release manifests now contain validated, shell-valid,
  image-specific programming commands.** Project defaults, supported
  substitutions and power assumptions are explicit; PIC writes require
  readback, and PIC12F675 continues to use its dedicated flashing helper rather
  than a per-image command. The published v0.9.11 manifest is unchanged and most
  of its commands are templates rather than pasteable shell; users of that
  release should follow `FLASHING.md` and its PIC12F675 helper requirements.

- **PIC context sidecars now prove the guarded context is in reviewed SRAM.**
  The pinned XC8 resolver accepts `_ctx_` only in `BANK0`; program,
  configuration, EEPROM, alternate-bank and unknown classes fail closed.

- **Beginning with v0.9.12, the release signature covers provenance as well as
  firmware.** Signed checksums now include `QUALIFICATION`, `MANIFEST.md` and
  `README.md`. Releases through v0.9.11 remain unchanged, so their provenance is
  outside their checksum signatures; signed tags and the repository's
  immutability gate are separate historical controls, not retroactive signature
  coverage. The immutability baseline also records the prior safety-errata
  amendment to v0.9.0-v0.9.2 rather than claiming published files never changed.
  Release policy now distinguishes the immutable tag and signed payload from an
  explicitly registered amendment to a current-tree result record, and assigns
  each durable documentation authority one non-overlapping lifecycle.

- **The Makefile's `ipecmd` route now reads the device back.** Under
  `PIC10F322_PROG=ipecmd`, and its new PIC10F320 equivalent, the command
  programmed the device without verifying it and left the part in reset. It is
  now `-F<hex> -M -Y -OL`, matching both `FLASHING.md`'s published PICkit 3
  procedure and the PIC12F675 helper's validated write. `PIC10F322_PROG_TOOL`
  defaults to `PK3` rather than `PK4` for the same reason. Releases publish no
  `ipecmd` command line, before or after this change.

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

### Added

- **A release-shipped PIC12F675 flashing helper, and the retirement of the raw
  command sequence that preceded it.** `FLASHING.md` existed for a real use
  case: program a downloaded release on a machine that has the programmer but
  no build toolchain and no checkout. For six of the seven parts that is
  genuinely a command. For the PIC12F675 it is not, because a bulk erase
  destroys two per-device factory-trimmed values the image cannot supply -- the
  `RETLW` oscillator calibration word at `0x3FF` and the `BG<1:0>` bandgap field
  in CONFIG -- and a device that loses either **still appears to work**, running
  at the wrong tick cadence, the wrong relay coil-pulse widths, or the wrong
  brown-out threshold.

  The block that shipped through `v0.9.9` had the right stages -- archive, note
  the two values, write, compare -- but parsing and comparison were manual, the
  write was not mechanically conditional on a valid baseline, no durable record
  existed before the hardware mutation, and it contradicted `README.md` and
  `release/README.md`, which prohibited exactly the raw write it published. The
  suite was green through that contradiction because only the *generated*
  per-release guidance was contract-tested.

  Every release from `v0.9.10` now also ships `flash-pic12f675.py`, listed in
  the same signed `SHA256SUMS` as the images and reproduced from its tracked
  source byte for byte. It needs Python 3 and MPLAB X 6.20 `ipecmd` -- no Make,
  Git, XC8, device pack, simulator, checkout or rebuild -- and runs the write as
  a transaction: validate the image against the signed checksum, refuse one that
  programs `0x3FF` or moves the CONFIG BG field, pin part, tool and MPLAB X
  version, read the device, read it again to prove nothing moved, publish a
  durable `reservation.json`, perform exactly one write, then read the whole
  device back and publish one immutable PASS/FAIL `result.json`. An interruption
  is PENDING, never an implicit success, and is resolved by a read-only
  finalization mode that never constructs a writer argument. The complete
  factory export is retained whatever the outcome, so a first bad attempt does
  not leave an operator without the only copy of that chip is trim.

  `test-pic12f675-flash-helper` proves the ordering against a stateful fake
  programmer, proves that every refusal happens before an erase argument is
  constructed, and proves that each way a writer can damage this part produces a
  published FAIL rather than a PASS. A durable documentation contract now rejects
  a raw PIC12F675 writer command in any current document -- including one written
  tomorrow -- a missing helper requirement, the retired universal "only a
  programmer and its CLI" claim, and a helper no release bundles.

  What this does not do is make the write safe by assertion. It DETECTS trim
  damage after the fact; whether a real PICkit 3 preserves the trim across an
  erase is still a bench question, and until that controlled run is retained in
  `HARDWARE_VALIDATION_LOG.md` a PASS means "no damage was observed on this
  device", not "this writer is known to be safe".

### Fixed

- **A writer that skipped its bulk erase could publish `PASS` over half the
  previous firmware.** The PIC12F675 flashing helper's post-write comparison
  walked only the addresses the release image supplies, and the current images
  occupy 495, 521 and 523 of this part's 1023 program words. A writer that
  never erased, wrote every requested word correctly and preserved both factory
  trim values would therefore satisfy every check the transaction made, leave
  hundreds of stale instructions behind in the image's holes -- still reachable
  by a computed jump or a runaway program counter -- and publish `PASS`. The
  fake programmer could not reveal this, because its normal write
  unconditionally erased every program word before overlaying the image.

  The comparison now runs against one complete expected post-write device: the
  image's value where the image supplies one, and the erased `0x3FFF`
  everywhere else, for every word from `0x000` through `0x3FE`. Word `0x3FF`
  remains per-device OSCCAL, compared against the two pre-write reads rather
  than the image, and CONFIG remains compared outside the factory `BG<1:0>`
  field. `result.json` now records `verified_program_words` beside the
  `required_program_words` total it has to equal, so a comparison that covered
  less than the whole device cannot report a positive count and an empty
  failure list at the same time. The fake programmer gained a no-erase mode
  that leaves one stale word at an address the selected image does not supply,
  and a second corruption at the LAST word the image represents rather than at
  word zero; the regression proves both are `FAIL` after exactly one write.

- **The pinned `ipecmd` and the pinned image were re-opened by name at the
  instant they were used.** The helper held descriptors for the tool, any Java
  runtime and the JAR, and re-hashed them immediately before each command --
  but then handed `subprocess.run()` a pathname, which the operating system
  resolves again. The retained image had a longer version of the same window:
  it was published to `image.hex`, its descriptor closed, and the PATH given to
  `ipecmd`, so a process running as the operator could unlink and replace that
  file, or rename the evidence directory and recreate its name over another
  one, after `reservation.json` appeared and before the erase. Every checksum,
  Intel HEX, CONFIG, EEPROM and OSCCAL guard would have been bypassed, and the
  post-write comparison could only have reported the damage afterwards.

  The child is now handed `/proc/self/fd/<n>` for everything it must execute or
  read: the kernel resolves that through the descriptor this process already
  holds, to the inode the helper validated, whatever the name refers to by
  then. The image is pinned harder still -- a sealed anonymous copy of the
  validated bytes, which has no name to replace and no writable path at all --
  and the reservation records which pinning was in force. That makes the
  guarded transaction a Linux procedure: elsewhere it refuses to touch a device
  rather than run a check it cannot honour, and `FLASHING.md`,
  `release/README.md` and the generated release guidance say so.
  `test/pic/flash_hook.py` drives the helper as a module and replaces the
  executable, the Java runtime, the JAR, the retained image (with one that
  programs the calibration word) and the evidence directory itself inside the
  window between the final identity proof and the child, reading back out of
  the device model what the writer actually ran and opened.

- **Neither the evidence reservation nor the published result was
  crash-atomic.** `Evidence.create()` created the evidence directory and opened
  it, but never flushed the PARENT directory that holds the entry naming it, so
  a crash after the reservation was announced and the write had begun could
  lose the directory that was supposed to make that reservation durable.
  `Evidence.publish()` created `result.json` under its final immutable name and
  then wrote into it, so a power loss, a `SIGKILL`, a short write or an I/O
  error could leave an empty or truncated final file -- and `finalize` refuses
  recovery on the existence of that name alone, leaving a transaction that was
  neither a valid result nor a recoverable PENDING.

  The parent directory is now opened, the evidence directory is created
  relative to it, and its entry is flushed before any device command; a
  directory entry that cannot be made durable removes itself and fails the
  transaction while nothing has been touched. Every evidence file is now
  written to a private temporary name in the same directory, written in full,
  flushed, and only then installed under its final name by an atomic
  no-replace `link()`. An interrupted publication leaves an inert remnant no
  reader looks for; a completed one leaves a record that still cannot be
  replaced. The regression fails and then `SIGKILL`s each of the five durable
  steps and requires every outcome to be either one complete immutable result
  or a PENDING transaction a read-only finalization still resolves without a
  second write.

- **The durable documents disagreed about what the PIC12F675 flashing helper
  is.** `FLASHING.md` published the helper's MPLAB X 6.20 `ipecmd` procedure
  while `README.md` twice and `TOOLCHAIN.adoc` once said no `ipecmd` procedure
  was published at all -- a reader who believed either was misled about the
  other, and only `release/README.md` drew the distinction the repository
  actually holds. The selected policy is published now, software-tested, not
  hardware-qualified, and every publisher now says exactly that in one
  sentence. The Make-based development and release-provenance route keeps its
  own, separate statement: it offers no operator `ipecmd` procedure, because
  the pk2cmd reads it would need immediately before and after the IPE write
  have no validated dual-programmer handoff. Three further claims are
  corrected with it. The helper's `--power` diagnostic called the externally
  powered arrangement "validated" while `HARDWARE_VALIDATION_LOG.md` listed
  that same arrangement among the outstanding controlled checks; it now says
  supported, and says the validation is still outstanding. `FLASHING.md` said
  a helper "fetched from somewhere else" is refused, when the implemented
  binding is released name plus released bytes and is deliberately
  location-independent -- an edited copy inside the bundle is refused and a
  byte-identical copy anywhere is accepted. And the signed `MANIFEST.md`,
  published verbatim as the GitHub Release body, described simulator lanes as
  "physical-output checks"; it now says modeled-pin output checks, which is
  what yasimavr and gpsim observe.

  Both halves are gated. Every helper publisher must carry the exact
  published/software-tested/not-hardware-qualified sentence, and no current
  `.md` or `.adoc` may carry the blanket denial in any of its forms, while a
  claim scoped to the Make route -- and the accurate statement that no
  `ipecmd` hardware procedure is QUALIFIED -- stay sayable. The rendered
  release evidence is exercised for the modeled-pin wording and rejected for
  the retired one.

- **A design document said nothing in it was implemented while its own body
  said otherwise.** `docs/flashing_simplicity.md` is deliberately frozen in
  the present tense of the branch it was argued on, and two of its proposals
  then shipped: the AVR build-before-hardware repair and the PIC12F675
  no-compiler path. Its status banner still opened with "Nothing here is
  implemented", and the section describing a failed build leaving changed AVR
  fuses with no matching firmware still read as an open hardware-safety defect
  after that defect was repaired. The banner now states what shipped and how
  to read an un-updated section, and both build-before-hardware statements
  carry their `v0.9.10` acknowledgement. A new preflight contract,
  `release_validate_flashing_simplicity_status`, keeps the three in agreement:
  a body that records an implementation update forces the banner to name that
  version, and deleting either statement fails rather than satisfying it.

- **Two current figures were checked by eye and had drifted.**
  `DESIGN_DOCUMENTATION.adoc` summarized ATtiny202 occupancy as 47-49% of
  flash while its own table reached 50.8%, understating the tightest image --
  the direction that matters when a reader is deciding whether a change fits.
  The sentence now gives both ranges to one decimal and
  `test-resource-tables` recomputes each from its own part's table (219 ->
  222 checks). `test/README.md` called its target-result row authoritative and
  reported 46 PIC12F675 relay fault checks where the reviewed count table, the
  Makefile count map, the mutation records and the adapter all use 43;
  `test-pic-target-result-records` now reads the row's three triples back out
  of the document and requires them to equal `pic12f675_target_count_table()`
  (18 -> 24 checks).

- **The PIC12F675 flashing helper binds the tool that runs, not the tool that
  ships.** A review of the helper found four ways the transaction could still
  be entered with something other than what it believed it was using, and each
  was reachable before a device write rather than after it.

  The helper checked its own bytes against the release `SHA256SUMS` only when
  it was executed from inside the bundle directory. Run from anywhere else it
  skipped that check entirely, so an EDITED copy could program a correctly
  signed image -- and the regression that was meant to cover this asserted the
  skip was intended. The binding is now on bytes rather than location: the
  running helper's digest must appear in the selected bundle's manifest under
  its released name, wherever the file sits. A byte-identical copy outside a
  bundle is still the published tool and still works; an edited copy, a
  renamed copy and a copy this release never published each get their own
  refusal. Restoring the old rule lets all three reach a write, which is what
  the new negative controls measure.

  `ipecmd` was hashed by pathname and then executed by pathname, with the
  whole transaction in between. The resolved file is now held open: the
  recorded digest is read through that descriptor, and immediately before
  every command the pathname in the argv is re-stat'd and required to still
  name the same inode, whose bytes are re-hashed through the same descriptor.
  A tool swapped in behind its name, or edited in place, stops the transaction
  with zero writer invocations. The jar form's Java runtime is pinned,
  reserved and re-proved the same way, because it is half of what actually
  runs; `finalize` now requires it to be the reserved one too. The evidence
  directory is likewise opened once and addressed by descriptor, so replacing
  the directory behind its name cannot redirect a publication or make a later
  read observe a different file than the one `ipecmd` produced. Where `dir_fd`
  is unavailable the pathname discipline stands in and the reservation records
  which of the two was in force.

  Device exports were parsed leniently enough to hide two ways a reader can
  lie. A repeated address was folded last-one-wins even when the two records
  disagreed about its value, and an export that returned only part of program
  memory was accepted as a trim baseline. Both are now refused before the
  write, on both pre-write reads: the retained baseline is the only copy of
  what was on the chip, and an incomplete one is incomplete for exactly the
  memory the next command erases. After the write the same observations are
  the result, so they are published as named failures instead of aborting the
  readback that found them. That the export command returns complete data in
  the form the helper parses is the first property the outstanding bench run
  has to establish, and it is now checked rather than assumed.

  The fail-closed matrix grew from 175 to 257 checks, adding the `java -jar`
  invocation end to end against a fake runtime, malformed trim, unsafe
  evidence and input paths, the interruption boundaries that were not covered
  (after the second read, inside the post-write read, and inside a
  finalization), and the two tool-replacement windows above -- the fake
  programmer moves its own pathname on cue, which is the only way to reach
  them at the right instant.

- **The documents disagreed about whether this part has a no-compiler path.**
  `release/README.md` opened by saying the PIC12F675 guarded workflow needs a
  clean tagged checkout and the pinned XC8/DFP toolchain, and that no path yet
  admits a downloaded image to it -- then said the opposite twice further
  down, where it documents the helper that does exactly that.
  `docs/flashing_simplicity.md` still argued in the present tense that the
  part had no qualified direct-from-download path, and its §5.5 sketch of one
  predicted the first improvement would land at "needs a clone plus common
  development tools", not "download and run one command". Both are reconciled:
  the opening states the helper path, and the analysis keeps its reasoning
  with marked updates saying which of it the helper settled, including that
  the dependency prediction was wrong in the good direction and that its step
  2 was deliberately narrowed -- a tool shipped inside a bundle cannot verify
  that bundle's signature without also shipping the trust root.

  The durable-document detector that should have caught the contradiction was
  narrower than the commands it was written to forbid. It only looked inside
  fenced Markdown blocks, only at `.md` files, only recognised a writer as the
  FIRST word of a line from a list of five names, and only treated a bare `-M`
  as destructive. It now recognises a writer by the basename of any token --
  so a full install path, a `sudo` prefix, a `$IPECMD` variable and
  `ipecmd.sh` are the same command -- treats `-MP` and an erase as
  destructive, and searches AsciiDoc listing blocks, indented blocks and
  inline code spans as well as fenced blocks, in `.adoc` as well as `.md`. It
  requires a writer, this part and a mutating option together, so a read-only
  `-GF` export, the helper's own invocation, another part's one-liner and
  prose naming the retired form in order to forbid it all stay publishable. A
  companion sweep rejects the three superseded sentences about this part in
  any current document, matched case-insensitively and named exactly, so
  recording in the past tense how they were retired is not itself a violation.
  `test-release-preflight` went from 144 to 158 checks.

- **The simulator and toolchain descriptions match what the harness and the
  fetcher actually do.** Four current documents still described a yasimavr
  harness that stopped existing when the ATtiny202 output tracer moved to
  signal hooks. `DESIGN_DOCUMENTATION.adoc` listed "one unpatched
  cycle-accounting defect that stops the harness measuring busy-delay widths
  in-simulation" among the AVR-XT trade-offs, and counted it as one of "three
  local fixes" although it is not a fix and is not local. `TOOLCHAIN.adoc`
  enumerated what `attiny202-sim` asserts -- ordering, polarity, coil
  exclusion, complete-pulse presence -- and omitted the width it now also
  asserts. `TODO.md` carried the caveat's retirement as future work that
  "disappears when that tracer moves to the signal-hook pattern" -- written
  in the very commit that moved it. Only `test/README.md`, corrected in that
  commit and again under D2, was right.

  The distinction all four now draw is the one that makes the claims
  compatible. The COMPILED width is a property of the image:
  `attiny202-delay-oracle` reads the `_delay_ms` loop count out of the
  disassembly, which is simulator-independent, tighter than any trace, and
  what pins the absolute design width. The DELIVERED width is what the pin
  held: `attiny202-sim` free-runs in millisecond budgets, timestamps each
  edge from a pin signal hook, and measures it -- a few percent longer,
  because the 1 ms tick ISR preempts the busy loop, which a compile-time
  count structurally cannot show. The unpatched `SimLoop.run(n)` cycle rewind
  is still real and still unreleased upstream, and it now reaches no timing
  assertion at all; the one deliberate `run(1)` caller left is the fault
  driver's non-timing transaction-seam probe. `TODO.md` accordingly describes
  only what re-pinning still buys: retiring the two vendored patches and the
  derived-work notice, not closing a measurement gap.

  One place did have to keep a bound from the image, and now says why rather
  than distrusting the simulator wholesale: the watchdog pet-to-pet interval
  is measured between consecutive `wdr` executions, which needs cycle-granular
  instruction stepping -- precisely the mode the rewind corrupts -- so the
  ATtiny202's ISR term is derived from the built image while the AVR classic
  parts are measured in simavr.

  Simulator lanes are also no longer called physical evidence. The workflow
  and release-script comments describing `attiny202-sim` as "physical output
  timing" and "physical PA2/PA3 output trace", the ATtiny202 row of the
  relay-correction evidence table -- the only row saying "physical" where the
  three gpsim rows say "modeled" -- and its mutation-resistance controls now
  say modeled pin levels. Datasheet uses of "physical" for the pin-versus-latch
  distinction are unchanged, because there the word names a register semantic
  that holds on any substrate.

  Finally, `TOOLCHAIN.adoc` promised the yasimavr build was portable "across a
  stripped-ensurepip host (creates the venv `--without-pip` and bootstraps
  get-pip)". That path was deliberately deleted for fetching and running an
  unhashed script, and two tests keep it deleted; the prose outlived it, so a
  reader provisioning a host would have expected a recovery the script fails
  closed on. The entry now states the enforced rule -- pip comes from
  `python3-venv`, there is no download fallback -- and `test-supply-chain`
  holds the two together: every pip-bootstrap mechanism the yasimavr entry's
  prose describes must exist in `scripts/fetch_yasimavr.sh`, and both must
  name `python3-venv` as the pip source. Code spans are blanked before
  matching, so naming the retired `get-pip.py` fallback in order to say it is
  gone is not promising it.

- **Current resource documentation is checked continuously, and final resource
  evidence can no longer pass vacuously.** The flash and RAM numbers for
  the seven release parts are restated in four current documents --
  `DESIGN_DOCUMENTATION.adoc`'s four utilization tables and the sentences
  derived from them, `docs/context_seu_detection.md`'s resource-qualification
  table, `docs/pic12f675_feasibility.md`'s bounded current-status block, and
  this file -- and nothing compared them with each other or with a build. They
  had drifted. The AVR Classic table still carried the pre-F1 ATtiny13a images
  (834/874/864 against a real 838/878/868), the ATtiny202 table was several
  changes behind (964/1004/994 against 968/1008/1040), the PIC12F675 tables were
  two behind (546/572/563 against 548/574/583), the ATtiny45 and ATtiny85 rows
  were absent altogether, and two derived sentences -- the utilization span and
  the ATtiny13a's distance from its 90% flash ceiling -- had been computed from
  the stale numbers. These are the figures a reader uses to decide whether a
  change fits.

  The working tables were regenerated from the latest fully provisioned
  candidate build. The
  ATtiny45 and ATtiny85 rows are published rather than omitted: each of those
  images is the size of its counterpart on the other part and 26 bytes larger
  than the corresponding ATtiny13a image, so the family's span now runs from
  10.5% of an ATtiny85 to 85.7% of an ATtiny13a. PIC12F675's gated XC8
  Data-space total is stated as 40 of 64 bytes in every variant. Exact
  whole-program Data-space totals for PIC10F322 and PIC10F320 are no longer
  published: their release logs do not retain the records needed to support
  those claims. What remains genuinely unmeasured is named as such: no
  AVR-XT lane measures a call-chain-plus-interrupt stack high-water mark, so the
  ATtiny202's peak stack is still an unretained figure rather than one derived
  from the ATtiny13a's.

  `make test-resource-tables` is the ordinary, tool-independent documentation
  regression. The four
  tables must cover exactly the canonical 21 images with every percentage and
  free-space cell recomputed from its own size and the datasheet capacity; the
  four documents must agree digit for digit, with each derived sentence
  recomputed rather than string-matched -- the span, the binding image's 10 free
  words, the PIC10F320's 14, the ATtiny13a's distance from the 90%-of-1024 limit
  `test/check_flash_budget.sh` actually enforces, and the 90-word PIC12F675
  shell premium over the PIC10F322 on the same relay driver; and every
  documented image present in a build directory is measured and must match. It
  also pins every current static-RAM/Data-space/stack statement and catches the
  stale PIC10F320 3/3/4 row that contradicted the current 3/3/3 result. The
  optional image layer needs no AVR or PIC toolchain: program size is read out of the ELF
  section headers and the Intel HEX records directly, which reproduces
  `avr-size`'s `Program:` and XC8's "Program space used" exactly, so it
  measures whatever the tree has already built and reports how many of the 21 it
  reached without representing a zero-image run as final evidence.

  Production qualification uses the strict mode after final image regeneration.
  It requires 21 of 21 regular, non-symlinked images, measures static data in all
  12 AVR ELFs, and requires the complete Classic-AVR high-water, AVR-XT frame,
  PIC12F675 Data-space, and PIC return-stack records from that run. Its retained
  result names the exact source commit and is itself hash-bound into
  `QUALIFICATION`; missing, partial, substituted, or edited evidence prevents
  staging or publication.

- **The release date is no longer coupled to the source commit date.** The
  `0.9.10` heading previously read 2026-08-21 and then 2026-08-27 while
  candidate commits were still landing, after which the release gate required
  the selected date to equal Git's date for the qualified source commit. That
  rejected a valid release whenever its publication date differed from its
  source commit date. Versioned preflight still accepts an explicit
  `Unreleased` draft, and production still requires an ISO-dated heading, but
  the date itself is release metadata rather than commit metadata.

- **Mutation result classification now prefers complete behavioral evidence.**
  The PIC12F675 atomic-clear mutant produced its exact three-variant failure
  record but could still be reported as a compile error when unrelated
  compiler-shaped text appeared elsewhere in the Make log. The exact complete
  verdict now wins; a real compile failure still cannot produce that record and
  remains an error, now with its first compiler diagnostic in the summary.
  Mutation cleanup also reads procfs ownership tokens without
  trusting permissive mode bits, silently skipping unrelated processes whose
  `environ` is protected by the host's ptrace policy instead of printing
  misleading permission-denied diagnostics.

- **Every AVR `*-program` goal now builds and validates its image before it
  writes a fuse byte.** `attiny13a-program`, `attiny45-program`,
  `attiny85-program` and `attiny202-program` were each defined as
  `*-program: *-fuses *-flash`. That reads like "fuses, then flash", and under
  the repo's forced `-j1` it ran exactly that way -- with the selected firmware
  image only a prerequisite of the *later* flash goal. A compile, link, size or
  Intel HEX failure therefore landed **after** the device's clock, watchdog and
  BOD fuses had already been rewritten, leaving a part configured for firmware
  that does not exist. On a fresh chip the window is not academic: the fuse
  write is what moves it off its factory clock, so the failed state is a device
  no longer running at the speed its previous firmware assumed. The quickstart
  and flashing documentation recommended these goals.

  Each `*-program` goal is now one ordered transaction. The per-part build --
  which compiles, reports sizes, and rejects an image that fails Intel HEX
  validation -- is a real prerequisite of the goal, so a build failure keeps
  Make out of the recipe and no `avrdude` runs at all; the recipe then confirms
  the selected image exists and the programmer is usable while the device is
  still untouched, and only then writes the fuses and flashes, in that order.
  The two hardware commands are single-sourced per part, so the single-step
  `*-fuses` and `*-flash` goals cannot drift from what the transaction performs;
  those keep their single-step meaning and stay ungated, because asking for one
  of them is asking for exactly one hardware action. The programmer check uses
  the same `-x` rule as the Intel HEX validator, since dash's `command -v`
  succeeds on a merely existing file when the value contains a slash.

  `make test-avr-program-order` is the regression: fake compiler, objcopy and
  `avrdude` write into one shared event log, so the order is read off the real
  recipe's real execution rather than from `make -n` text. It pins, for all four
  parts, that the image is built and converted before the first programmer
  invocation, that there is exactly one fuse write and exactly one flash write,
  and that the fuse write comes first; and that a failed compile, an image
  rejected by HEX validation, a build that legitimately produces nothing (the
  ATtiny202 skip with no device pack), and an unusable programmer path each
  reach the programmer zero times. Against the previous Makefile it fails 12 of
  its 19 checks.

- **A production release can no longer be staged under a development
  override.** `RELEASE_IMAGES` is the canonical statement of what a complete
  release contains, and `scripts/make-release.sh` enumerates the same set
  independently and cross-checks the two -- but both are composed from the very
  variables a caller can move. `make release FW_BASE=other` reached the script
  through `MAKEOVERRIDES`, so every `print-<VAR>` query answered with the
  overridden value, both opinions agreed, and a complete, internally consistent,
  never-reviewed set of images staged and published. An exported
  `PIC12F675_TAG`, `PIC10F322_CHIP` or `XT_MCU` did the same thing without
  appearing in any command anyone typed: the per-part MCU tags and die selectors
  are `?=`, and the environment wins those.

  The Makefile now pins the reviewed identity as literal `override` text --
  seven parts, 21 images, 18 soak combinations, one basename convention --
  covering the image basename, the tinyx5 membership, every MCU tag, every die
  and clock selector, and the variant sets. A `make release` or
  `make release-preflight` goal fails at parse time against that pin, before the
  worktree lock; `scripts/make-release.sh` repeats the comparison for its own
  account, because it is also run directly, and stops before the documentation
  validators, the scratch directory, and any clean, build, soak or staged byte.
  The diagnostic names each drifted field, its pinned and selected values, and
  the Make origin it arrived on. `scripts/verify-release-images.sh` gained the
  same cross-check, which closes the reproduction leg: it already discarded
  inherited command-line assignments, but not the environment.

  Build-directory and tool-path overrides are unaffected and stay available:
  they do not change what an artifact IS, and the release already asserts and
  records the tool it actually selected. Clock selectors are pinned because the
  classic-AVR manifest spells "1.2 MHz" and "1.0 MHz" as literals rather than
  reading `F_CPU`, so a re-clocked image would have shipped under a canonical
  name and an undisturbed provenance record.

  The production boundary now also rejects non-allowlisted, release-relevant
  Make overrides, so `CFLAGS`, `XT_CFLAGS`, `CORE_SRC`, their per-target
  source/flag counterparts, validation controls inherited through ordinary
  `?=` precedence, assignment-bearing Make flags, `--eval`, alternate/injected
  makefiles, and dollar-bearing values stop before the recipe, selected
  toolchain, scratch state, or build. Developer targets retain those override
  surfaces. Both the selected and pinned image and soak inventories must also
  contain exactly 21/18 unique members before set equality is considered,
  preventing sorting from erasing duplicate canonical entries. Relocated
  `PIC12F675_PYTHON` is now preflight-checked, exported to qualification, and
  recorded separately in the manifest.

  `test-release-images` (103 -> 233 checks) holds the real Makefile to the
  pinned identity on both channels -- they are not equivalent, since a command
  line beats a plain `=` assignment and only the environment reaches a `?=` --
  and proves the pin itself unreachable from either. `test-release-preflight`
  (118 -> 160) drives the real step 0 into each refusal and requires it to leave
  no scratch directory or output path behind.

- **The XC8 cache manifest can no longer be frozen from a partial scan.** The
  installer records a SHA-256 inventory of every readable file in the
  just-installed compiler and device pack, and the restored-cache verifier
  regenerates it and requires an exact match -- that manifest is what stands
  between a corrupted CI cache restore and a build, because a restore never
  re-runs the digest-verified installer. Both computed it as one
  `find | sort | xargs sha256sum` pipeline under `/bin/sh`, which reports only
  the LAST stage's status: a `find` that emitted part of the tree and then died
  was masked by the `sha256sum` that succeeded over that fragment. Measured on a
  synthetic install, the old installer exited 0 having recorded 1 of 9 files.

  The walk, the ordering and the hashing are now three separately
  status-checked stages in both scripts, NUL-delimited end to end, and neither
  will record or accept an empty inventory. The dangerous case was never the
  loud one: a partial record is not caught at restore time if the condition that
  truncated the install-time walk truncates the verify-time walk the same way,
  and the two fragments then agree. For the same reason the verifier now reports
  a scan/order/hash failure by name rather than as a cache mismatch -- they are
  not the same finding, and only one of them means the cache is bad.

  `test-supply-chain` fails each stage independently, in both scripts, against a
  `find` stub that emits a genuine readable path before failing exactly as a
  real one does over an unreadable subtree; installation must leave neither
  stamp nor manifest behind, and verification must name the stage. Eight fixture
  files whose names carry spaces, both quote characters, a backslash, shell
  metacharacters, a leading dash, UTF-8 and an embedded newline are inventoried,
  compared and caught when tampered with -- the same eight reduce to 2 entries
  and an error under a newline-delimited pipeline (30 -> 46 checks). Manifest
  content is unchanged: over the 3603 files of a real XC8 3.10 + PIC10-12Fxxx
  DFP 1.9.189 install, the staged form reproduces the pipeline's output byte for
  byte.

- **Suffixed release tags now publish as prereleases.**
  `scripts/make-release.sh` and every release verifier have accepted
  `vX.Y.Z-suffix` since the producer and verifier grammars were aligned, and the
  workflow's `on:` trigger matches that shape -- but `gh release create` was
  never told, so a `v1.0.0-rc.1` would have been published as an ordinary
  release and could have taken latest-release selection away from the newest
  stable version. The publication step now decides the kind from the tag alone:
  a bare `vX.Y.Z` publishes exactly as before, every accepted suffix adds
  `--prerelease`, and a shape outside the version grammar aborts before `gh` is
  reached rather than defaulting to either kind. That last branch is not
  redundant with the existing gate, it is the alarm on it: malformed tags are
  already rejected in the locate step before any build, so one arriving at
  publication means that gate was bypassed.

  Both halves are proved by execution rather than by inspection.
  `test-release-provenance` runs the workflow's own publication shell against a
  recording `gh` stub and requires the flag absent for `v0.9.8`, present exactly
  once for `v0.9.8-rc.1`, and `gh` never reached for six malformed shapes --
  including the `v0.9.8-` that the trigger globs admit and the grammar does not
  (86 -> 94 checks). `test-workflow-syntax` extracts both classification
  patterns from the YAML and requires that together they accept exactly what
  `scripts/make-release.sh` accepts, that they do not overlap, and that they
  split that grammar stable-versus-suffixed, so this additional copy of the
  version grammar cannot drift away from the producer's (375 -> 381 checks).

- **PIC10F320 de-energizes both relay coils in one write.** The
  space-constrained shell's `set_relay_coils_low()` cleared RESET and then SET
  through two separate `LATA` read-modify-writes. Both orders settle in the same
  place; they differ in the transient, and with *both* coil bits high -- the
  latch upset the sanity gate escalates on -- the per-bit clear left the second
  coil driven for the whole of the first write, on the one path whose purpose is
  to stop driving them. This was an instruction-scale exposure, not a
  watchdog-scale one, but it was weaker than the single masked write the four
  modular shells reach through `hw_pin_mask_set_low()`, and project-wide parity
  language did not say so.

  The clear is now one constant-mask `LATA` write. The two per-bit low helpers
  it replaced had no other caller, so the stronger form is also the cheaper one:
  the relay image went from 248 to **242** of 256 program words and its
  worst-case return-stack depth from 4 to **3** of 8. Both CD4053 images are
  byte-identical to the previous release. The write sequence itself is now
  asserted rather than assumed, by two oracles that fail on a return to the
  per-bit form -- the host fault harness (which sees every firmware `LATA`
  access) and the gpsim resynchronization cases (which step the real image one
  instruction at a time). Both are load-bearing on the both-coils injection, and
  that is the whole of what is observable: with a single coil energized, a
  per-bit clear delays the useful de-energization by one write without passing
  through a distinct state.

- **The watchdog margin is now asserted against wall-clock execution, not
  against the delay constant alone.** Every shell used to assert only
  `TICK_PERIOD_MS + blocking_delay < WDT_MIN_PERIOD_MS`. That sum omits two real
  costs: the bounded loop work between a tick and the pet that follows it, and
  -- on the interrupt-driven AVRs -- the tick ISR preempting the busy-wait
  inside a blocking actuation, which makes the actuation longer in wall time
  than the delay body it compiles to. Shipped margins were wide enough that
  neither omission mattered, but a future near-bound configuration could have
  satisfied the assertion while violating the real pet-to-pet bound.

  Each pin map now declares its own `WDT_LOOP_WORK_MS` and
  `WDT_ISR_STRETCH_PCT`, and the shared `WDT_PET_TO_PET_MAX_MS()` in
  `bypass_output_common.h` combines them with the blocking delay and one tick of
  scheduling latency into a conservative wall-clock upper bound, asserted
  against the de-rated watchdog floor. The percentage is explicitly wall-time
  ISR duty: foreground delay work receives only `100-p`, so its additive
  overhead is `ceil(blocking_ms * p / (100-p))`. Values at or above 100% are
  rejected, and 32-bit quotient-plus-remainder arithmetic keeps the ceiling
  valid over every supported delay. The boot path -- `init()` arms the
  watchdog and then performs the same blocking actuation before `main()` reaches
  its first pet -- is inside that bound rather than beside it. The simple CD4053
  variant, which blocks nowhere and previously carried no watchdog assertion at
  all, is now covered too: the floor has to clear the loop itself, not just a
  pulse. The self-contained PIC10F320 carries its own copy, as it does for every
  other shared invariant. The arithmetic is consumed only by compile-time
  assertions, so no instruction is intended to change; the final-candidate
  21-image byte comparison remains the release gate for that claim.

  Two gates hold the budget to something real. `test-static-assert-guards`
  independently calculates the conversion, pins each variant's bound to its
  exact millisecond, proves the ISR, tick and loop-work terms are load-bearing,
  and rejects a negative control restoring the old mixed formula. Equality is
  unsafe: the AVR relay's 18 ms bound fails against an 18 ms watchdog floor and
  first compiles at 19 ms. The classic-AVR simavr suite then measures the real
  image, recording the longest interval between `wdr` executions across boot and
  toggles in both directions and requiring it to fit the same budget the
  firmware compiled against. Worst measured: 14.002 ms of an 18 ms budget on
  the ATtiny13A relay build, 15.003 ms of 18 ms on the ATtiny85, against a 100 ms
  de-rated floor. AVR-XT uses its compiled ISR and delay-body bounds because the
  pinned simulator's cycle-stepping defect precludes a trusted full-interval
  measurement.

- **PIC12F675 relay coil clears now commit through one whole-port write.** The
  shared relay driver clears both coil bits with one masked hardware-interface
  operation. On PIC12F675, that operation removes both bits from the SRAM output
  shadow before writing `GPIO` once, so a SET or both-coil shadow upset cannot be
  replayed as an intermediate physical high while RESET is cleared first. Three
  shipping-source cases cover RESET, SET, and both shadow bits, preserve the
  all-port refresh, and kill a mutant restoring the sequential writes. The other
  modular shells implement the same interface as one masked latch/OUTCLR
  operation; PIC10F320 remains unchanged because it has no independent shadow
  replay path.

  Because that write publishes the whole shadow byte, the PIC12F675 relay
  emergency path also canonicalizes the parked spare output GP4 in the shadow
  before calling it. Otherwise an upset that set only `gpio_shadow_`'s GP4 bit --
  inert until something writes the port -- would be published to the pad by the
  escalation itself and held there for the watchdog period, on a pin the board
  contract permits only while it is low. It is the same single write, not a
  second one: two sequential whole-port writes would reintroduce the coil replay
  the one-write rule prevents. Both the host shipping-source lane and the
  libgpsim relay fault lane now observe GP4 *before* the watchdog spin (the reset
  is what ends the unsafe interval), and a mutant that drops only GP4 from the
  canonicalization is killed there while the reset and coil assertions stay
  green. Cost: two program words on the PIC12F675 relay image; the CD4053
  images are byte-identical.

- **An unexpectedly energized relay coil is now a fault, and recovery issues a
  corrective RESET command.** Earlier `0.9.x` builds re-asserted both coils low
  at every serviced loop top and let the loop continue. That cleared the coil,
  but the stray pulse it permitted -- roughly one tick -- is only *below* the
  Panasonic TQ2-L2-5V 4 ms minimum for guaranteed actuation, which is not the
  same as proven mechanically harmless. The firmware therefore could not know
  whether the latching relay had moved, and if it had, the audio route was left
  permanently disagreeing with the effect state and the LED.

  The loop-top re-assert is gone. An energized coil is now caught by each
  shell's existing output-state integrity check and escalated:
  `hw_force_wdt_reset()` commands both coil-control outputs idle *before* it
  spins, so no fault holds an output active for a watchdog period, and the
  recovery re-runs `init()`, which sets logical state and LED to BYPASS and
  commands a nominal 12 ms RESET-coil pulse with SET inactive. Physical return
  to BYPASS additionally depends on the validated board, driver, supply and
  relay satisfying the documented actuation assumptions.

  PIC10F322, PIC12F675, AVR classic and AVR-XT needed no new detection code.
  PIC10F320 cannot afford a general output-latch comparison in 256 words and
  instead guards exactly the two coil latch bits, giving it full parity on the
  coil guarantee while keeping its documented gap for other latch upsets. Flash
  cost is zero on all three PIC parts except three words on PIC10F320, and four
  bytes on each AVR image. As a side effect PIC12F675's port-follows-shadow
  clause becomes load-bearing at the settled seam, where the old whole-port
  refresh used to pre-empt it.

  AVR-XT and PIC12F675 now add shell-specific emergency pin quiescence around
  the shared latch clear. AVR-XT removes coil pull-ups, disconnects the output
  drivers, clears `PINnCTRL` inversion and stale `OUT`, and restores direction
  only after both latches are low. PIC12F675 removes coil pull-ups, makes the
  pins inputs, disables analog/comparator ownership, clears shadow/GPIO, and
  then restores output direction. This closes cases where `INVEN` makes a low
  AVR latch drive high or comparator `COUT` owns PIC GP2 and ignores GPIO
  writes.

  Fault tests on all six substrates now assert the two halves separately --
  de-energization before the spin, and a measured full-width recovery pulse
  where the simulator models the reset. Directional coil-output faults cover
  both settled-state hazards: BYPASS with an unintended SET and ENGAGED with an
  unintended RESET. The blocking actuation sequence remains excluded from every guarantee:
  shipping-source tests characterize active-coil-low and inactive-coil-high
  faults at actual recorded offsets of 1, 6, and 11 ms inside both SET and RESET
  delays, but do not cover every instruction boundary and prove modeled
  persistence and final low output state, not that an external output accepts
  the command or that mechanical behavior is safe. The CD4053 variants retain an
  explicit no-op. Design:
  `docs/relay_coil_fault_correction.md`.

  The AVR-XT relay fault matrix observes modeled PA2/PA3 pin levels, not only
  `OUT`, under inversion, pull-up, direction, combined stale-register, and
  ordinary latch faults. The PIC12F675 matrix enumerates all comparator modes
  one bit from off and directly measures modeled GP1/GP2 voltage for both
  `COUT` states in the reachable GP2-output mode. Latch-only negative controls fail on both targets.
  These simulator checks are electrical pin-model evidence, not hardware or
  relay-mechanical evidence.

  Resource gates now cover the two affected shells explicitly. ATtiny202 builds
  require one exact `Program:` and `Data:` record, enforce 2048 bytes of flash
  and at most 16 of 128 bytes of static RAM, and compile the AVR-XT shell under
  all three production selectors with a 32-byte per-frame `-fstack-usage` limit.
  PIC12F675 builds require one internally consistent XC8 Data-space summary per
  variant and enforce an inclusive 48-of-64-byte limit. Toolchain-free
  regressions reject missing, duplicate, malformed, stale, dynamic,
  inconsistent, and over-limit evidence before release qualification can rely
  on either gate.

- **A single-bit upset of the debounce context is now detected while it is still
  in range.** The per-tick sanity gate previously rejected only out-of-range
  context, so an in-range flip passed unnoticed: with `PRESSED_THRESH = 8` and
  `RELEASE_THRESH = 25`, an idle `debounce_counter` whose bit 3 or bit 4 flips
  becomes 8 or 16 — both inside the accepted range, and both enough to make the
  next `debounce_step()` toggle the effect. That is a phantom bypass or engage
  with nobody touching the footswitch. Each enabled shell now treats persisted
  context use as a transaction: snapshot `ctx_`, validate the snapshot against
  a complemented XOR-fold shadow byte, compute only from that local value, then
  publish the successor and its check. A single-bit flip confined to persisted
  `ctx_` or `ctx_check_` therefore forces recovery, is safely overwritten by a
  previously validated transaction, or remains a mismatch for the next check;
  it cannot be consumed and then legitimized by folding the live corrupt value.
  This guarantee deliberately excludes automatic locals, registers, code and
  control flow. The fold is the pure
  function `debounce_ctx_check_word()` in `src/bypass_pure.c`, proved by CBMC
  over the full byte domain of every member: single-bit detection (C8), and the
  fold definition plus its all-zeros stuck-at guard (C9) — the latter being why
  the fold is complemented at all. Enabled by `BYPASS_CTX_CHECK` on the
  PIC12F675, PIC10F322, classic-AVR and AVR-XT shells. **The PIC10F320 is
  excluded**: it links no pure core, and even the cheapest fold overflows its
  256 words of flash, so its range-only gate stays — documented and statically
  asserted. On AVR the integrator stays in the ISR, so both the ISR and
  `main()` perform complete local transactions; main's snapshot-through-publish
  sequence is one `ATOMIC_BLOCK`, which is the source of MISRA deviation D-5.
  XC8 v3.10 measured the `0.9.10` PIC10F322 images at 476/502/493 of 512
  words for the simple/mute/relay variants. Design:
  `docs/context_seu_detection.md`.

- **The watchdog-margin invariant is now enforced at compile time on every
  shell.** Previously only `src/bypass_mcu_pic10f320.c` static_asserted `(tick +
  longest blocking pulse) < de-rated WDT floor`; the other four shells carried
  the argument in comments only. Each part now defines a datasheet-derived
  `WDT_MIN_PERIOD_MS` (PIC12F675 and PIC10F322 160 ms, classic-AVR 100 ms,
  ATtiny202 128 ms) and a `TICK_PERIOD_MS` in its pin map, and the shared
  blocking output drivers assert the bound against them — so a future prescaler,
  tick, or coil/mute-pulse change that erodes the margin now fails the build
  rather than eroding it silently. A focused static-assert regression mutates
  the floor below the bound and confirms the guard fires. This closes the
  deferred `TODO.md` T25-wdt-margin-assert across all shells.

- **PIC fault injection now proves post-reset liveness, not just the reset.**
  After each expected watchdog recovery the harness requires the restarted image
  to reach its main-loop `CLRWDT` again before the case passes. Earlier cases had
  this only implicitly — the next case's setup would have stalled on a dead
  recovery — but the final injection had no successor, so a reset-then-wedge
  recovery on the last case would have scored as a pass. Every case, the final
  one included, now carries the same explicit liveness guarantee.

- **A branch-only working document can no longer slip into a release.** The
  release now refuses to stage if the tree still contains a root-level
  `v*-polish.md` working document, or still references one by name, machine-
  enforcing the previously manual "delete before merge" and "no references
  remain" steps. The gate runs on the actual release-staging path — not the
  preflight capability probe, which legitimately validates a live polish branch
  — so a release started from an un-merged polish branch fails fast, while the
  retained `docs/*_post_release_polish.md` history is unaffected.

- **PIC12F675 release programming is bound to the signed release bytes.** The
  guarded release target verifies the annotated tag and checksum signature,
  requires a clean checkout at that exact tag, and admits the private fresh
  build to the device transaction only when it matches the selected digest in
  the complete 21-image signed release set.

- **The PIC12F675 CONFIG gate no longer consumes a stale ignored executable.**
  Each programming transaction builds the tracked checker privately, pins its
  identity, and requires an exact image-bound CONFIG verdict before hardware is
  reachable.

- **Interrupted PIC12F675 writes now have a read-only finalization path.** A
  retained PENDING transaction validates its baseline, part, variant, tools, and
  independently retained image before one device read publishes an exclusive,
  sealed PASS/FAIL result. Recovery never invokes writer arguments, and
  interrupted private attempts remain safely retryable.

- **PIC12F675 release evidence now binds both aggregate suites to one retained
  matrix.** Local staging and clean-runner attestation request the pre-hardware
  and all-variant target aggregates in one Make graph, so their shared qualifier
  runs once. The retained format-2 JSON identifies all six shipping/simulator
  images and six consumed assembly/symbol sidecars; its digest is recorded in
  `QUALIFICATION` and `MANIFEST.md`, and publication verification requires every
  aggregate PASS, final shipped HEX, and corresponding `SHA256SUMS` entry to
  match it. Soak-harness compilation reuses rather than rebuilds that matrix.

- **Current release documentation now identifies v0.9.10 consistently.** The
  changelog, release availability, TODO status, and PIC10F320 qualification
  documents agree on seven release parts, 21 images, 18 soak combinations, and
  the six-target/four-shell modular topology. Versioned release preflight now
  rejects a missing requested-version changelog section or stale bounded
  current-release declarations before creating scratch space or building.

- **The release workflow now revalidates every frozen publication asset
  immediately before upload.** The canonical image set plus fixed and optional
  metadata are installed into a root-owned read-only bundle and recorded in a
  canonical descriptor-based inventory whose digest is carried independently.
  Publication rechecks the exact file set, types, sizes, identities, and hashes;
  re-verifies the detached checksum signature and strict image checksums from
  that same directory; rechecks the inventory again; and then invokes `gh`
  without an intervening command. Added, removed, renamed, empty, symlinked,
  non-regular, or byte-modified assets fail before upload.

- **Release-environment pinning is now described factually.** `ubuntu-24.04` is
  a moving hosted-runner label and the apt-installed tools carry no version
  constraint, so the runner image and that part of the toolchain are recorded,
  not pinned — the workflow header and `TOOLCHAIN.adoc` now say exactly that
  rather than implying otherwise. Both also state what the release does enforce:
  every published image is rebuilt and compared byte-for-byte against the signed
  `SHA256SUMS`; the compilers that define those bytes are version-pinned and
  checked before anything is built (XC8 V3.10 and PIC10-12Fxxx_DFP 1.9.189 by
  digest, avr-gcc 7.3.0 by `scripts/make-release.sh`, with a hard failure on
  drift); and the XC8/DFP cache is integrity-verified on every restore by the
  new `scripts/verify_pic_toolchain_cache.sh`, closing a path where a restored
  cache bypassed the SHA-verified installer entirely. Analyzer and simulator
  versions ride the runner and are recorded in each release `MANIFEST.md`.

- **The image-defining compiler pins are now exact.** The three preflight checks
  that enforce avr-gcc 7.3.0 and XC8 V3.10 were shell substring patterns, so any
  banner *containing* the pin satisfied them: `avr-gcc (GCC) 17.3.0` passed the
  7.3.0 check, and XC8 `V3.100` passed the V3.10 check, as would `7.3.0.1`. A
  neighbouring version is exactly what a drifting host has, and every published
  image byte is gated on the exact compiler, so the enforcement `TOOLCHAIN.adoc`
  and the release workflow header promised was wider than the code delivered.
  Each check now parses a whole version token out of the selected tool's own
  banner and compares it for equality, and fails on a banner carrying no version
  token or more than one. GCC's parenthesised distributor blob is discarded
  first, so `avr-gcc (Ubuntu 7.3.0-16ubuntu3) 7.3.0` is still the pinned
  compiler. The checks continue to read the commands `CC`, `PIC_CC` and
  `PIC10F320_CC` actually select — PIC12F675 shares `PIC_CC` with the
  PIC10F322 — and to run before any scratch tree, build or soak; a rejection
  names the selected tool, the observed banner, the expected version and the
  corrective action.

- **The published PIC12F675 recovery instructions can now finalize the
  transaction they describe.** `make pic12f675-finalize` passes the
  caller-selected release identity to the recovery oracle, which compares it
  against the identity the reservation recorded. Both static examples --
  `README.md` and `release/README.md` -- omitted `PIC12F675_RELEASE_TAG`, so
  following either one rejected a valid PENDING signed-release transaction
  instead of resolving it, at the worst possible moment: after an interrupted
  write, holding a device whose factory trim is already at stake. The generated
  per-release documentation carried the argument, which is how the two drifted
  apart unnoticed. Both examples now carry it, `make help` no longer describes
  the variable as programming-only, and a new documentation contract holds every
  published finalization command -- static and generated, by the same oracle --
  to the identity of the transaction it recovers: every reserved argument must
  repeat the preceding command's value, not merely its name, and the release tag
  is required after a `pic12f675-release-program` command and refused after a
  `pic12f675-program` one, since a development reservation records no release
  identity. Documents that publish the command are discovered rather than
  enumerated, so a new one is covered when it is written; shipped
  `release/<version>/` directories are excluded as immutable artifacts.

- **The host C compiler now has a published, enforced minimum: GCC 10, or any
  Clang.** GCC 9 and older report a false narrowing on the PIC shells' OR-folded
  integrity checks -- they fold an explicit `(uint8_t)` cast away whenever the
  operand provably fits in eight bits (a narrow bitfield read, or a read masked
  with a small constant) and then blame the compound assignment that writes the
  folded result back. Every host gate compiles firmware with `-Werror
  -Wconversion`, so on those compilers `pic10f322-coverage-check-fw` failed over
  correct firmware; measured here, GCC 9.5.0 reports four such errors and GCC
  10.5.0 none, on identical sources. Rewriting the casts to satisfy GCC 9 was
  measured at four PIC10F322 words, which the 512-word `cd4053_with_mute`
  variant cannot spare, so the floor is enforced instead of paid for. The new
  `host-compiler-valid` gate runs second in every aggregate, right after
  `python-version-valid`, and is a prerequisite of all three
  `*-coverage-check-fw` targets and of the local-CI preflight; it probes the
  construct itself rather than parsing a version banner, so a compiler is judged
  by what it accepts. `README.md`, `TOOLCHAIN.adoc`, and `test/README.md`
  publish the floor, and a contract test holds all three in agreement with the
  enforced constant.

- **`make test` now runs both PIC shipping-source coverage gates.**
  `pic10f322-coverage-check-fw` and `pic12f675-coverage-check-fw` compile the
  real PIC shells, the shared pure core and all three output drivers under gcov
  and gate the annotations exactly. Neither needs XC8, the device pack, gpsim or
  a built HEX -- only the host compiler, gcov and Bash that `make test` already
  requires -- yet both were reachable only through `pic10f322-test` and
  `pic12f675-test`, standalone aggregates whose *other* lanes do need those
  tools. `pic12f675-test` is worse than merely standalone: it skips its entire
  matrix when XC8 has qualified nothing, so on a host without a PIC toolchain
  that coverage gate did not run at all.

  The cost of that routing was already paid once. A stale host fault oracle, a
  compile configuration that was not the shipping one (the gate never defined
  `BYPASS_CTX_CHECK`, leaving `debounce_ctx_check_word()` dead), and a coverage
  anchor matching zero lines all coexisted with a green `make test` for the
  length of a polish branch. Both gates now sit in the one shared gate
  inventory, so `test` and `test-long` pick them up together; the standalone
  aggregates still run them. Measured cost is about 8 s and 12 s.

  `test-workload-rebuild` gained the routing assertions that keep this true:
  `test` and `test-long` must resolve to the same gate set apart from
  `test-mutation`, neither aggregate may name a gate twice, and both coverage
  gates must appear exactly once. The comparison is made against Make's own
  prerequisite sets rather than the text of the two lists.

- **Field-use reports and controlled hardware qualification are now separate
  claims.** `HARDWARE_VALIDATION_LOG.md` described its table of community build
  reports as "which firmware has been flashed-to and tested on actual hardware",
  while this file, `DESIGN_DOCUMENTATION.adoc`, `TODO.md`, the Makefile and two
  design documents simultaneously said no part had ever run on a chip. Both were
  wrong, in opposite directions: builders really have flashed released images
  onto ATtiny13a and PIC10F320 parts and reported them working, and none of
  those reports retains the source/image identity, board revision,
  programmer, configuration bytes, procedure, measurements or acceptance result
  that a qualification record needs.

  The log now carries two bounded sections. Section 1 keeps the field reports,
  labelled as self-reported and uncorroborated -- the linked threads were not
  opened or independently assessed here. Section 2 defines the eleven fields a
  controlled record must retain and states that no part has one. The `1.x.y`
  criterion is restated across the project as *controlled hardware
  qualification* rather than "has run on silicon", which is the phrasing that
  could not be true and false at once. `T3-hw-procedure` is now recorded as
  gating section 2 for every part, since the **Procedure** field has nothing to
  reference until it exists.

  The unqualified "same pinout, can be used interchangeably" notes are replaced
  by the actual constraint: a shared pinout is a *board* property. The AVR
  classic trio needs a different image and different fuse bytes per part
  (ATtiny13a at 1.2 MHz, ATtiny45/85 at 1.0 MHz) or the device runs on the wrong
  clock and still appears to work; the PIC10F32x pair needs each part's own
  image with its own CONFIG word and a matching programmer part name.

  `release_validate_hardware_claims` enforces all of this from `--preflight`, so
  it runs on the live tree inside `make test`: the sections must exist exactly
  once in order with no part row outside them, section 2 must define every field
  and then either declare that no record exists or hold records carrying all of
  them, the pin-compatibility qualification must name both families and both
  mechanisms, and no durable document may assert the retired idiom or the
  retired interchangeability sentence. Naming a retired phrase is not using it,
  so code spans and quoted spans are blanked before matching -- this paragraph
  and `test/README.md` both have to quote both forms in order to retire them --
  while a bare assertion sharing a line with a quotation is still caught. Shipped
  `release/<version>/` artifacts and root-level branch-only working documents are
  pruned outright. `test-release-preflight`: 85 -> 101 checks.

- **Four stale evidence and simulator claims are corrected.**
  `docs/context_seu_detection.md` opened by calling target-toolchain
  qualification "still pending" while its own evidence section recorded a fully
  provisioned run that passed the AVR/XC8 builds and resource gates, the
  simavr/yasimavr/gpsim lanes, CBMC, static analysis and the complete mutation
  suite. Those are statements about two different things and neither said which:
  the run is complete, and it is *local*. What does not exist yet is retained
  release evidence -- a signed `v0.9.10` MANIFEST binding those gates to one
  published commit. The record now draws that line in both places, and points at
  `HARDWARE_VALIDATION_LOG.md` for the third claim it does not make either.

  `test/README.md`'s mutation-mapping section still said the ATtiny202 output
  tracer calls `SimLoop.run(1)`, and repeated the superseded "one cycle per
  instruction" explanation that the same file corrects 450 lines earlier. The
  tracer free-runs in millisecond budgets and timestamps pin edges from a signal
  hook, so it asserts delivered width as well as ordering, polarity, exclusion
  and presence, and the pinned yasimavr's cycle rewind reaches no timing
  assertion; the fault driver's non-timing transaction-seam probe is the one
  deliberate `run(1)` caller left. The delay oracle's role is restated
  accurately too: it is the tightest absolute-width witness because it recovers
  the *compiled* width from the disassembled image, which makes it
  simulator-independent -- not because it is the only route to a width.

  Simulator observations are no longer described as physical-hardware ones.
  `docs/pic10f320_special_case.md` said its target-I/O lane asserted "physical
  `PORTA`" and that "the output lanes do observe real pin state"; both are gpsim
  or host-compiled observations, and they now say modeled `PORTA` and name what
  they are. The same correction is applied to the PIC12F675 I/O and fault-lane
  descriptions in the Makefile and to the built-image lane list in
  `docs/non-blocking_output_schemes_feasibility.md`. Where "physical port" names
  the *register* semantics that classic mid-range and PIC10F32x parts have --
  `GPIO`/`PORTA` reading pins where a shadow or `LATA` holds the latch -- it is
  left alone: that is a datasheet distinction, not an evidence claim.

  `.github/workflows/ci.yml`'s header called the runner "pinned to ubuntu-24.04"
  -- a moving hosted-runner label whose apt packages carry no version constraint
  -- and listed a `make test` matrix that predated the ATtiny202 host oracles and
  both PIC shipping-source coverage gates. It now matches `release.yml`: the
  runner and its apt toolchain are recorded, not pinned, and what *is* pinned is
  named (every third-party action by commit SHA; XC8 V3.10 +
  PIC10-12Fxxx_DFP 1.9.189, SHA-verified on install and integrity-checked on
  every cache restore). Its inventory and the `verify` job's now cover the
  host-side lanes of all seven parts. `release.yml`'s header needed no change --
  the PIC12F675 additions and the moving-runner note landed with the release
  provenance and compiler-pin work earlier in this cycle.

- **The pre-release metadata window is now explicit and bounded.** Release
  documentation identified `v0.9.10` as released and pointed at
  `release/v0.9.10/` for its authoritative evidence, in a tree that contained
  neither. That is not a slip in one sentence: source finalization and the
  artifact commit are necessarily *different* commits, because
  `scripts/verify-release-history.sh` rejects a release whose qualified source
  commit already contains `release/<version>/QUALIFICATION`. The tree that
  declares a release therefore never contains it, and the declaration has to be
  written to be true across that window.

  `release/README.md` now documents the four-step sequence -- source
  finalization, production staging, artifact commit, signed tag -- says which
  identity each step fixes, and states the rollback rule: if a release is
  abandoned or postponed, the source-finalization commit is reverted or
  corrected on `main` rather than left standing. `scripts/make-release.sh`
  carries the same sequence in its header and in the hand-off it prints.

  The declarations themselves are now checked rather than trusted. A bounded
  current-release block may not name a release directory the tree does not
  contain; the one exception is the version being released, and naming it
  requires the exact pre-tag transition line recording that the release cut
  creates it. `TODO.md` and `docs/pic10f320_validation.md` carry that line and
  state the source contract they are, where the earlier wording asserted
  retained evidence.

  After staging, the same declarations are re-validated against the inventory
  actually staged rather than against the canonical set the Makefile predicted:
  images counted as files, soak combinations counted as machine records so a
  build log sharing the soak naming cannot pad the count. That is the last
  documentation check before the artifact commit and the tag, and its position
  is pinned. `test-release-preflight`: 101 -> 113 checks;
  `test-release-history`: 88 -> 89, adding a release commit that restates a
  bounded declaration to the paths it already refuses.

- **The release gate no longer chases working-document names.** The
  branch-only-document guard refused a root-level `v*-polish.md` and nothing
  else, so a root-level pre-release fix list -- a working document of exactly
  the same kind, kept on a branch and deleted before merge -- was invisible to
  it, and so would be the next such document under any other name. Release
  staging now governs the whole root-level Markdown set as an allowlist: the
  durable documents ship, both branch-only families are recognized by name for a
  diagnostic that identifies them, and any other root-level document fails the
  release until it is deleted or deliberately added to the durable set. The
  reference half, which must search by name because a deleted document leaves
  nothing else to search for, covers both families, so no durable file is left
  pointing at a document the release removed.

  Release preflight is unchanged and stays usable on a live branch, where the
  working document legitimately exists: this gate runs only on the real
  release-staging path, after the preflight capability probe exits.
  `test-release-preflight`: 113 -> 118 checks, including the live tree held to
  the same durable set so the allowlist cannot drift unnoticed until release
  day.

## [0.9.9] - 2026-08-15

### Fixed

- Local CI mutation skips are now authorized per substrate: `--skip-pic` cannot
  hide a missing ATtiny202 lane, and `--skip-attiny202` cannot hide missing PIC
  coverage. Partial runs no longer claim they are safe-to-push reproductions.
  Workflow validation independently pins the six PIC aggregates, their five
  exact Make invocations, strict/tool arguments, enabled state, uniqueness, and
  all four downstream `needs: pic` edges. The shared PIC installer now rejects a
  DFP missing `pic12f675.h`, with an offline supply-chain regression.

- The Makefile name contract now walks every shell statement produced by a lone
  Make-variable expansion instead of inspecting only its first statement. A
  shell-local prefix in the first statement stays local, while real environment
  channels in later statements are checked against their own child commands.
  Prefix and suffix tokens surrounding the expansion attach only where the
  reconstructed shell text permits. Boundary fixtures plus a later-statement
  `PIC_GPSIM_PROC` severance probe move the gate from 45 to 48 checks.

- PIC12F675 mutation results now fail closed by reason. Each of its 20 rows must
  produce a named gpsim, fault-injection, lock-step, target-I/O, or soak failure
  before receiving kill credit; XC8 compile failures, timeouts, incomplete
  checker output, and unrelated nonzero exits are errors. Broken unmutated
  simulator-image or kill-target baselines remain fatal even in partial mode,
  while genuine tool absence remains skippable. Six new rows pin T0IF re-arming,
  exact OPTION_REG and ADC/global-pull-up guards, and both previously uncovered
  context write-backs, taking the complete mutation inventory from 112 to 118.

- The direct PIC12F675 soak-binary target now builds and validates its simulator
  image and `.sym` inputs before deriving `PIC_SHADOW_ADDR`, so it works from a
  clean tree. Its 1.024 ms tick and per-variant 0/5/12 ms blocking times are
  derived from constants consumed by the firmware and pinned to exact physical
  hold budgets. `pic12f675-simcal` now classifies a zero-XC8 image tree before
  requiring Python, while still failing if images exist and Python is absent.

- PIC libgpsim soaks now propagate a core-advance failure through startup,
  liveness holds, and the duration loop instead of discarding it and repeatedly
  retrying a wedged simulator. A wedge stops at the resume cap, reports completed
  requested milliseconds plus actual advanced cycles/time, and cannot emit a
  full-duration result record. The host fake-gpsim progress regression exercises
  this contract through all three PIC routes.

### Added

- **PIC12F675 support, release-supported from `v0.9.9`.** A fourth core
  generation (Microchip *classic* mid-range, beside AVR Classic, AVR-XT and the
  enhanced mid-range PIC10F32x) and a fourth modular shell,
  `src/bypass_mcu_pic12f675.c`, over the same compiled `src/bypass_pure.c`
  core. 1024 program words, ~51% used by the largest variant.

  The part needs its own shell rather than a PIC10F32x rename because the
  classic core lacks four things the 32x has, each with a design consequence:

  - **No `LATx`.** Reading `GPIO` returns physical pin levels, so the 322's
    read-modify-write idiom would be a read-modify-write *on the pins*. Every
    output write goes through an SRAM shadow instead, and the shadow guards
    itself — the per-tick integrity check compares it against both the expected
    mask and the physical port, so an upset in either direction forces a reset.
    That comparison is strictly stronger than anything the 322 can do, where
    latch and port are two views of one register.
  - **No period register and one shared prescaler.** `OPTION_REG.PSA` assigns
    the single prescaler to the timer *or* the watchdog, never both. It goes to
    the watchdog (1:16, ~288 ms nominal, 160 ms characterized minimum), leaving
    TMR0 unprescaled at F_OSC/4; four 256 us rollovers counted in software make
    a **1.024 ms** tick. The 2.4% stretch changes nothing in the debounce core,
    which counts samples, but it moves every physical timing figure.
  - **No `OSCCON`.** The 4 MHz INTOSC is fixed by `FOSC=INTRCIO` and trimmed by
    a factory `OSCCAL` value in the last program word. The runtime guard
    therefore compares against a value captured at init, not a constant.
  - **A comparator holding GP0 and GP1 out of reset** — `CM<2:0> = 000` makes
    them analog inputs, and an analog input reads back 0 whatever the pin is
    driving, so the port-follows-shadow check would fail every tick. Three of
    the eight modes additionally put `COUT` on GP2. All three are active output
    pins here, so `CMCON` and `ADCON0` are part of bring-up and part of the
    per-tick guard set.

  The footswitch is on GP5, not on the input-only pin the 322 uses: `WPU`
  implements bits 0,1,2,4,5, so GP3 has no internal weak pull-up and siting the
  switch there would delete the pull-up integrity check from this target.

  Validation is the full pre-hardware set: build and 1024-word budget, CONFIG
  decode, cppcheck + MISRA, host-gcov shipping-source coverage, the 8-level
  hardware return-stack bound, gpsim CLI functional tests, and libgpsim
  target-I/O, lock-step, fault-injection and long-duration soak lanes, behind
  the fail-closed `pic12f675-test` and `pic12f675-test-target-variants`
  aggregates. 20 mutants with their own toolchain probe take the mutation
  inventory to 118. Both aggregates run in CI and in `scripts/ci-local.sh`.

  One thing is structurally unusual, and one is deferred. Simulator images are
  **derived**: an oscillator calibration word is injected into a *copy*, because
  an erased image never reaches `main()` in gpsim — and `pic12f675-test-calibration`
  proves the injection leaves the shipping images byte-identical, which is what
  lets the release soak run the derived image and still bind to the shipped HEX.
  And like every other part in this repository, the PIC12F675 has **not** run on
  silicon: its release rests on simulation, formal proof and static analysis,
  and its three silicon-only residual risks (programmer OSCCAL/BG preservation,
  and GP2's Schmitt-Trigger readback margin) are the `1.x.y` hardware-validation
  pass, tracked as `T3-pic12f675-bench`, not `0.9.x` release blockers. See
  `docs/pic12f675_feasibility.md` section 8.

- **`make pic12f675-program`**, so the part can be put on real silicon. Same
  shape as `pic10f322-program` — one `VARIANT`, the CONFIG word carried inside
  the HEX, and a conservative no-Vdd default — with one gate the 10F32x parts
  have no need of. `PIC12F675_PROG` names the executable and
  `PIC12F675_PROG_KIND=pk2cmd|ipecmd` selects its argument dialect when a
  path-qualified or renamed executable cannot identify itself.

  Every simulator lane for this part runs a *derived* image carrying a
  fabricated oscillator calibration word. Writing one to a device would
  overwrite that device's factory trim irreversibly, and silently, because the
  part still runs afterwards at the wrong clock. So the target rebuilds the
  complete matrix, derives the image only from validated `VARIANT`, and checks a
  private read-only snapshot through the injector's inverse mode
  (`--assert-preserves-calibration`). The image must leave the calibration word
  unprogrammed and prove it fetches that word, so the answer cannot be vacuously
  true of another part's HEX. The target decodes CONFIG from that same snapshot
  and requires its SHA-256 digest unchanged before passing the path directly to
  validated pk2cmd/ipecmd argv. External image and whole-command overrides are
  rejected. Without `python3` it refuses to program rather than flash unchecked.

  The programmer's erase behaviour is now a fail-closed bench transaction rather
  than a warning. `pic12f675-preflight` uses pk2cmd's read-only export to retain
  the reader binary/version, target Device ID/revision, full read-HEX digest,
  word `0x3FF`, CONFIG and `BG<1:0>`. `pic12f675-program` requires that baseline
  and a new result-directory path, repeats the read immediately before writing, compares
  device identity/OSCCAL/BG, and reads again after programming. A successful
  result retains exact before/after values and raw transcripts; a changed trim,
  failed write, or failed post-read retains FAIL evidence and fails the target.
  The directory is exclusively reserved with the intended image and pre-write
  evidence before programming; writer/post-read logs are written there directly,
  so even interruption leaves a `PENDING` account. The post-read must also match
  every requested image byte outside the factory BG field, preventing a
  zero-exit no-op writer from producing PASS. Evidence is never overwritten.

  pk2cmd is the only pinned readback dialect. ipecmd remains available for the
  write, but must be paired with `PIC12F675_READ_PROG=<pk2cmd>` for the baseline
  and before/after reads; the Makefile does not guess an untested IPE read argv.
  Fake-tool coverage exercises the transaction, not silicon preservation, so it
  enables the `1.x.y` bench check without standing in for it.

- **The PIC12F675 is fully integrated into the release pipeline.** Its three
  shipped HEXes join `RELEASE_IMAGES` (18 → 21) and `RELEASE_IMAGE_DIRS`, its
  three soak combinations join `RELEASE_SOAK_NAMES` (15 → 18), and its build and
  both aggregate logs initially took the retained-evidence inventory from 28 to
  34 files; the source-bound resource record added later in this release makes
  the final inventory 35.
  `scripts/make-release.sh` gains a full arm — preflight device/analysis
  assertions, a build step, both qualification gates, a soak loop, and a
  manifest generator arm — and `.github/workflows/release.yml` rebuilds the part
  and re-runs its lanes on the pinned runner. Because the release soak drives the
  part's **derived** simcal image rather than the shipped HEX, the part is
  threaded like the ATtiny202 (whose soak drives the ELF, not the HEX): the
  shipped image is bound to what its gates validated — including
  `pic12f675-test-calibration`, which pins the simcal to the shipped HEX modulo
  word `0x3FF` — and the simcal image is pinned unchanged across the soak.

  The staging apparatus that had withheld the part (`RELEASE_STAGED_IMAGES` and
  its parse-time disjoint-with-`RELEASE_IMAGES` guard) is retired with the
  graduation; `test-release-images` continues to cross-check the manifest
  generator's arms against the canonical set in both directions — every released
  image has an arm, every arm describes a released image — so a future part added
  without its manifest arm still fails the release instead of publishing a PIC
  labelled as an ATtiny with AVR fuse bytes.

- **The PIC12F675 output-integrity predicate is now exercised one clause at a
  time.** The target fault harness changes a valid settled context from BYPASS to
  ENGAGED while leaving the BYPASS shadow and physical GPIO untouched and
  matching. The context range check accepts the value and port-versus-shadow
  remains true, so the resulting watchdog reset independently witnesses
  shadow-versus-expected for all three output variants. Target fault coverage
  moves from 36 to 37 checks per variant; host predicate coverage moves from 84
  to 85.

  A dedicated mutant tautologizes only shadow-versus-expected while retaining
  both operands; later fail-closed mutation-result work took the PIC12F675
  category to 20 and the complete mutation inventory to 118. The pulled shell
  refactor moved main-loop source lines
  without changing executable-line coverage; the gcov oracle and its negative
  probe were re-pointed from the old 556-589 anchors to 569-602 so they stopped
  rejecting live HEAD. They no longer carry line numbers at all -- see below.

- **The PIC12F675 target OSCCAL fault is now physically realizable.** The target
  matrix formerly XORed `0x01`, but this part implements `CAL5:CAL0` only in
  OSCCAL bits 7:2; bits 1:0 read zero on silicon. The case now flips implemented
  `CAL0` with `0x04`, producing the intended one-step `0x80 -> 0x84` trim change
  with the canonical simulator value while retaining the write-stick check and
  exact-one-reset verdict. The
  independent host fault lane already used the implemented bit. Fault counts do
  not change.

- **PIC12F675 aggregate evidence now binds every lane to one retained image
  matrix.** A repository-owned oracle exclusively records SHA-256 for all three
  shipping images, all three derived simulator images, and the assembly/symbol
  sidecars consumed by stack, fault, lock-step and I/O. Qualification stages that
  record, compares a discarded private shipping build to reject compiler
  nondeterminism, reuses the calibration contract's private probes to reject
  injector nondeterminism, and only then promotes the final qualified manifest.

  Pre-hardware and target wrappers suppress only their producer prerequisites,
  verify the retained manifest after every consumer, invalidate it on any byte
  change, and include the same six-image hash record in every aggregate PASS.
  CI and `ci-local.sh` request both public aggregates in one Make graph, so the
  common qualifier runs once rather than the target sweep republishing nine
  matrices. Fake-tool coverage rejects nondeterministic compiler/injector output,
  symlinked roots, stale or overwritten evidence, and a failing lane that mutates
  a retained image, moving PIC12F675 build validation from 82 to 86 checks.

- **PIC12F675 target aggregates now require exact lane verdicts.** Fault,
  lock-step and target-I/O emit a terminal `PIC_TARGET_RESULT format=1` record
  binding the device, lane, selected variant, status, canonical check count and
  failure count. The per-variant aggregate requires exactly one byte-exact
  record and one matching human PASS summary, rejects contradictory FAIL output
  or trailing diagnostics, and independently pins 37 fault, 3005 lock-step and
  25/26/36 target-I/O checks. The all-variant wrapper validates even an otherwise
  overwritten caller selector before qualification, while the central selector
  guard classifies literal values without evaluating hostile Make or shell text.
  Host regressions cover empty/multi/unknown selectors, every malformed-result
  shape, the relay record producer and temporary paths containing spaces.

- **The PIC12F675's three datasheet-read risks are closed** (DS41190G, read
  2026-08-11). They never needed silicon, only the datasheet:

  - **Watchdog period** (Table 12-4 param 31 `TWDT`): 10 ms min / 17 ms typ /
    25 ms max, 30 ms max at extended temperature. The risk item had *assumed*
    the spread was no worse than the PIC10F32x's −37%/+69%; measured, it is
    −41%/+47% and +76% extended — worse at both ends. The assumption was the
    defect, not the design: the prescaler stays at 1:16 because the argument
    rests on the **minimum** (10 ms × 16 = 160 ms) against the conservative
    16 ms compile-time pet bound, a factor of 10. The earlier 13.024 ms figure
    was a rough pulse-plus-tick estimate, not the formal upper bound. The shell's
    citation of the watchdog minimum was exact. Note the two nominals are both
    the datasheet's: §9.6.1 states
    an 18 ms nominal in prose (the figure gpsim models), Table 12-4 gives a
    17 ms characterized typical, and nothing depends on either.
  - **Brown-out** (Table 12-4 `BVDD`): trips at 2.025–2.175 V, with a 100 µs
    minimum excursion. Against peripherals that want >4 V, `BOREN=ON` is
    therefore **not** the protection it looks like, and this part has no `BORV`
    field to raise it — a hardware-design constraint, now recorded with numbers.
  - **INTOSC accuracy** (Table 12-2 param F10): ±1% at 3.5 V/25 °C, ±2% over
    0–85 °C, **±5%** over the industrial and extended ranges. At the −5% corner
    the relay coil pulse degrades from a 3× to a 2.85× margin over the TQ-L2's
    4 ms minimum. The rough physical pet estimate becomes 13.68 ms and remains
    inside the conservative 16 ms compile-time bound, whose margin against the
    independent watchdog floor is 10×. Debounce is unaffected in the way that
    matters — the core counts samples, not milliseconds.

- **`TODO.md` T25-wdt-margin-assert.** Found while checking whether the margin
  above is enforced anywhere: `src/bypass_mcu_pic10f320.c` static_asserts
  `(TICK_PERIOD_MS + pulse) < WDT_MIN_PERIOD_MS` per blocking variant, and the
  other four shells carry the same invariant in comments only. No shell is near
  its floor today; the gap is that a future timing change erodes the margin
  silently.

- **`make test-todo-index`.** TODO.md states an index invariant — "the stable ID
  in each row matches exactly one open section above" — that nothing checked,
  and it had drifted: the 2026-08-10 MISRA-review entry added a section with no
  summary row. The new gate pins the correspondence both ways, checks each row's
  tier column against the section it indexes, and checks that an ID's prefix
  matches the tier it is filed under (`T2` → Tier 2, `T25` → Tier 2.5). Both
  missing rows were added.

- **`make test-pinout-alignment`.** The ASCII package-pinout diagrams are
  transcribed from each device pack's own pinout data and are what somebody
  wires a board from, and nothing checked them. The PIC12F675 DIP-8 diagram had
  shipped with one extra leading space on its `V_DD` row, putting that row's
  package walls one column right of the corner rows and of every other pin row.
  It rendered visibly stepped and survived review, because that is the class of
  defect a reader's eye completes for them. The gate reads each box's wall
  columns from its corner rows and requires every row between them to carry a
  wall character in both, across every tracked `.md`/`.adoc` outside the frozen
  `release/v*/` artifacts. It asserts a floor on the number of diagrams found,
  so a checker that has stopped recognizing them fails rather than passing
  quietly, and it runs six synthetic probes on every invocation — one of them
  the real historical defect, which it reports by file, line, column and the
  character actually found. The diagram itself was corrected, and a sweep of
  the other three found no second instance.

- **Authored-header MISRA findings now fail closed.** The 2026-08-10
  suppression review measured that cppcheck 2.13.0 leaves `--error-exitcode`
  unset for some findings located in an included header, so such a finding was
  printed and then ignored. (Which ones is rule-dependent rather than purely
  location-dependent: re-measured 2026-08-11 against real cppcheck 2.13.0, a
  Rule 2.5 finding in an authored header leaves the status 0 while a Rule 20.7
  finding in one sets it to 2. The parser exists so the project does not have
  to know which.) All five MISRA recipes now force a structured diagnostic
  format and pass captured output through a repository-owned parser that
  normalizes paths and fails every unwaived record in authored `src/*.c` or
  `src/*.h`, independently of cppcheck's status. Malformed output and analyzer
  failure also fail closed.

  `make test-misra-output-contract` supplies all five recipes with a fake
  cppcheck that returns zero while emitting a Required-rule finding in an
  authored header. Every lane must reject it, and only the exact `rule:file`
  suppression may restore clean; direct probes cover absolute paths, authored C,
  adopted and test paths, unattributed/malformed records, tool failure, and a
  severed parser call. PIC10F322 and PIC12F675 no longer suppress `misra-config`
  invocation-wide: exactly three `misra-config` accommodations are pinned to the
  three PIC shell source paths, and the same ID in an authored header remains
  failing.

- **The PIC shipping-source coverage oracle no longer takes source line numbers
  as input.** `test/pic/fw_coverage/check_fw_coverage.sh` asserted five required
  constructs and one allow-listed one by literal line number, so an edit that
  merely moved the shell reported the guards themselves as missing. The main-loop
  refactor above shifted the PIC12F675 loop by thirteen lines and fired six
  violations against a shell whose behaviour and executable-line count were
  unchanged; the message named the guard, the defect was in the gate. The same
  breakage sat latent in the PIC10F322 arm, four violations deep, unfired only
  because nothing had moved that file yet.

  Every anchor is now located by the source text gcov already carries on each
  record, and the line number is reported as observed evidence instead of
  required as input. Location is fail-closed: an anchor matching zero lines, or
  several, is a failure, so a guarded construct cannot be renamed, deleted or
  duplicated and quietly stop being checked. `hw_force_wdt_reset();` is
  deliberately not unique -- it is the live sanity-gate call and the res.fault
  call, character for character -- so those two are separated by file order under
  a requirement that exactly two exist. Matching them by text alone would accept
  an annotation in which the live call went uncovered while the structurally
  unreachable one became reachable, which is the precise regression the gate
  exists to catch. `test/pic10f320/fault/check_fw_coverage.sh` was already text
  anchored and is unchanged; it accepts that weaker separation knowingly, with
  its own fault harness as the compensating control, and its header says so.

  The negative probe in `run_fw_coverage.sh` locates its target the same way,
  so a renumbering cannot leave it flipping a line that no longer holds the
  res.fault call and passing vacuously against a gate it is no longer testing.

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
> items were tracked individually, most of them compressed to a sentence below.
> The completed work journal remains available from Git history at commit
> `69f8bbf`.

### Fixed
- **A non-executable Intel HEX validator passed the build's presence check.**
  `make pic`, `make attiny202` and `make pic320-size` guarded
  `IHEX_VALIDATOR` with `[ ! -x "$V" ] && ! command -v "$V"`, and for a value
  containing a slash dash's `command -v` succeeds on a file that merely
  *exists*. A validator present but not executable therefore passed the guard
  and failed later with "Permission denied" — after the compiler had already
  produced the image the validator was supposed to check. The guard now requires
  the executable bit whenever the value names a path and falls back to a `PATH`
  lookup only for a bare command name, and it is defined once
  (`IHEX_VALIDATOR_CHECK`) instead of copied into each recipe. Found by the new
  ATtiny202 regression below rather than in the field.
- **The Classic AVR soak was watching a signal simavr never raises for a
  watchdog reset.** `test/avr/test_soak.c` recorded a watchdog failure only when
  `avr_run()` returned `cpu_Crashed`, but simavr 1.6 sets that state solely from
  `avr_sadly_crashed()` (illegal opcode / stack crash); its watchdog path resets
  the core in place and leaves it `cpu_Running`. The six Classic AVR release
  soak combinations could therefore run a full 24 h and report
  `watchdog_failures=0` without ever having been able to observe one. The soak
  now installs simavr's `avr->reset` callback — the same positive witness
  `test/avr/test_sim.c` has used since `9957a00` — counts every invocation, and
  charges each reset to `watchdog_failures`. A `cpu_Crashed` remains tracked as
  its own separate anomaly. `test_watchdog_not_tripped_normally` in
  `test_sim.c` now asserts the reset count rather than the crash flag, which is
  the only one of the two that can witness the fault the test is named for.
  Both harnesses chain the MCU model's own reset callback instead of replacing
  it.
- **`attiny202-soak` could report success having soaked nothing.** It was the
  only one of the four AVR-XT harness targets missing the guards its three
  siblings share — `XT_SIM_VARIANT` validated against both the supported list
  and `VARIANTS`, an ATtiny_DFP device-file guard, a missing image treated as a
  failure, and a failure when the loop covered zero images — while its own
  header comment claimed the "same guard / skip / variant-selection as the
  others". `make attiny202-soak XT_SIM_VARIANT=bogus` exited 0 where all three
  siblings exit 2, printing "no ATtiny202 images built; nothing to soak" and
  blaming an absent DFP in a run that had just built and budget-checked all
  three images. The target is a release-qualification input —
  `RELEASE_SOAK_NAMES` carries `attiny202_relay`, and each soak log is published
  evidence — so "soaked nothing" must never read as "soak passed". The recipe
  now mirrors its siblings verbatim; nothing that passed before behaves
  differently.
- **Three layers of the ATtiny202 matrix could go green having exercised part
  of it.** Every `attiny202-*` harness target iterates `VARIANTS`, and a variant
  that is skipped rather than run still leaves the target at exit 0, so exit
  status alone never proved coverage. CI compensated by counting PASS markers
  but sized the expected count from `make -s print-VARIANTS` — the AVR Classic
  list, which is user-overridable, so a single override shrank the build and the
  expectation together: `VARIANTS=cd4053` produced one `SIM PASS`, which the job
  expected and accepted. The count now comes from `XT_VARIANTS_SUPPORTED`, which
  is the ATtiny202's own list and is declared `override`. `ci-local.sh` ran the
  same five targets with none of those assertions, despite opening with the
  promise that "a clean pass here means the CI matrix will be green"; it now
  applies all five through an `xt_gate` helper mirroring `ci.yml` step for step.
  And `attiny202-test-target` did not enforce the matrix itself, so it now
  rejects incomplete, empty, duplicate and unsupported variant requests before
  running any simulator lane, and requires exact per-variant PASS counts from
  sim, fault and lock-step plus both lock-step boot scenarios. The fault gate's
  hardcoded `n=3` is deliberately left unconverted: if all five counts read one
  variable, a wrong edit to that variable makes all five agree on the wrong
  answer at once, so one independently pinned count is a cross-check on the
  variable itself — the same reasoning that gives `RELEASE_IMAGES` its value.
- **`ci-local.sh --skip-attiny202` could not pass.** Push mode set
  `MUTATION_ALLOW_SKIP=1` for `--skip-pic` only, so skipping the ATtiny202
  toolchain removed its lane and then failed `test-long` for the very mutants
  the skip had intentionally removed. Either explicit toolchain skip now selects
  partial mutation mode; only a complete target-toolchain run receives `0`, and
  PR mode still runs the non-mutation path. The routing regression had codified
  the defect by supplying `--skip-attiny202` to every invocation while expecting
  `0`, so it no longer does.
- **Both soak families could hold a liveness verdict open across the event it
  was watching for.** The PIC soak sampled LED state only at the endpoints of a
  multi-millisecond hold, so a rapid even-numbered retrigger sequence collapsed
  into an unchanged endpoint and read as no activity at all; it now samples
  after every simulated millisecond. The AVR-XT soak checked its reset and
  terminal force-reset witnesses on a schedule that could miss the final
  round-trip before the verdict; it now checks after every liveness hold,
  including that last one.
- **The release orchestrator had four fail-open edges.** `scripts/make-release.sh`
  could stage production output outside the canonical version directory, accepted
  an unvalidated soak-concurrency value, and proceeded from a failed or empty
  executable version probe. Soak workers now run in isolated process groups and
  every exit path terminates and reaps them without stale-PID, launch-window,
  descendant or repeated-signal gaps; direct `flock` execution stays
  signal-transparent, and a failed run's evidence is preserved for diagnosis
  rather than cleaned away.
- **`scripts/fetch_yasimavr.sh` could recursively delete a caller-named
  destination.** `VENV_DIR` is documented as caller-selectable and was assigned
  straight to `VENV`, which `rm -rf "$VENV"` then consumed twice — so a typo, the
  repository root, a shared directory or any existing non-venv directory could
  take unrelated data with it. The fetcher now rejects extra and empty
  arguments, canonicalizes physical paths, and refuses filesystem and repository
  roots, destination symlinks, non-directories, missing parents and existing
  directories without a schema-valid private stamp. It builds and verifies in a
  randomized sibling, installs with a no-clobber rename, and restores the prior
  stamped venv after an install failure or a signal, retaining it as a rollback
  backup rather than recursively deleting any caller-derived path.
- **Git line-ending conversion could invalidate release bytes and signatures.**
  With no `.gitattributes`, a checkout under `core.autocrlf=true` — the setting
  Git for Windows recommends — rewrote release artifacts, so images no longer
  matched `SHA256SUMS` and the detached signature over it no longer verified.
  Firmware images, checksums, signatures, qualification records and expected
  hashes are now marked non-text. The same pass then found that the two records
  `scripts/verify-release-qualification.sh` reads by exact whole-line match were
  still convertible: it matches the `MANIFEST.md` heading with `grep -Fxq` and
  compares each soak log's `SOAK_RESULT` record for string equality, so a CRLF
  checkout made the verifier reject a correct release — fail-closed, but on the
  command `release/README.md` tells auditors to run. Both classes are now pinned
  to LF, and because an extension allowlist is what let them be missed in the
  first place, a `* text=auto eol=lf` default now backstops it so a class nobody
  has named yet cannot inherit the platform default. `make test-release-history`
  asserts the policy on a representative path per class, verifies mixed-EOL
  historical artifacts byte-for-byte under `autocrlf`, and pins the catch-all.
- **The stack high-water-mark gate overstated free SRAM by four bytes.**
  `test_stack_high_water_mark()` asserted a margin "between the deepest SP and
  BSS" but measured down to `0x60`, the first SRAM byte — below BSS, so the four
  static bytes living there were counted as free. The error ran optimistic
  inside a gate: at the 8-byte floor the stack could reach within 4 free bytes
  of BSS while the message announced 8. The floor now comes from the firmware
  ELF's `__bss_end`, read from the ELF rather than derived, so a static added
  later tightens the gate by itself; a missing symbol is a failure, not a
  fallback to the looser reference point. Margins now read 29 B (relay, mute)
  and 31 B (cd4053), matching the figures `DESIGN_DOCUMENTATION.adoc` already
  stated and which the gate's own output had contradicted by 4.
- **The default host suite failed in an extracted source archive.** The
  PIC10F320 coverage checker's mode validation inspected the file's Git index
  mode unconditionally, which no source tarball has. It now requires the checker
  to be locally executable everywhere but inspects the index mode only inside a
  worktree, keeping clone and CI validation without rejecting archives.
- **`MANIFEST.md` carried a repo-relative link that does not resolve as release
  notes.** The file is committed at `release/<version>/MANIFEST.md`, where the
  relative path to the PIC10F320 special-case document is correct, but
  `release.yml` also passes it verbatim to `gh release create --notes-file`, and
  on the release page that path 404s. The link is now absolute and pinned to the
  release tag, so it is correct in both contexts and points at the matching
  source revision rather than a moving `main`. The repository URL is a literal
  constant rather than being read from `git remote`, which varies with the
  operator's SSH-versus-HTTPS clone and would silently change published notes.
- **Three resource tables and the BOD/BOR failsafe list had drifted from the
  build.** The AVR Classic flash table was stale on all nine rows (716/756/756
  bytes on the ATtiny13a and 742/782/782 on the ATtiny45/85, against
  684/724/732 and 710/750/758), and the PIC10F322 program-space column on all
  three (445/473/471 words at 86.9/92.4/92.0%, against 404/431/434). In both
  cases the relay and mute variants are now byte-identical or reordered, so the
  tables' implied size ordering was wrong as well. Neither drift originated in
  the build: `release/v0.9.5/MANIFEST.md` already published the correct AVR
  figures and that release's `build-pic.log` the correct PIC ones, so the
  shipped evidence has been right throughout and only the design document was
  wrong — and nothing in the Makefile, scripts, tests or CI reads these tables,
  so no gate could have caught it. Percentages now use `avr-size`'s own
  one-decimal values, making the table reproducible by the command in its
  caption. Separately, the BOD/BOR failsafe list covered two of the six release
  parts while its framing promised per-part coverage; the ATtiny202 (BODCFG
  0xE5 → BODLEVEL7 at 4.2 V, enabled in active and sleep) and PIC10F320
  (BOREN=ON, LPBOR=OFF, BORV=HI, the same ~2.4/2.7 V trip points as the
  PIC10F322) entries are added, and the shared hardware-design caveat now names
  both PIC parts instead of generalising from the 322.
- **Four resource claims survived their own measurements.** The Resource
  Utilization section opened by claiming large headroom on every supported part,
  which the document's own PIC10F320 table contradicts two screens later at
  95.3% of 256 words and 12 free — the entire reason that target is built
  differently. It now states the measured span, 9.1% of an ATtiny85's flash
  through 95.3% of a PIC10F320's. The paragraph under the AVR Classic table
  still claimed room for future features "without approaching any resource
  limit" while the ATtiny13a above it sits at 73.8% of a 90% ceiling; it is now
  split per resource, the SRAM half naming the gate that enforces it
  (`test_stack_high_water_mark()`, which fails `make test-sim` below an 8-byte
  floor — never a build failure, as the old text implied). The PIC10F322 prose
  claim of "comfortable headroom" is replaced with the real 39-of-512-word
  margin, and corrected again in `docs/pic10f320_feasibility.md`, which asserted
  it as still true. Both Makefile resource-gate comments were stale in the same
  way: the ATtiny13a flash comment said ~46% where the firmware is at 73.8%, and
  the `STACK_MAX_FRAME` comment claimed a ~10 B full-path high-water mark where
  it is 29–31 B, while conflating per-frame and total-depth bounds. Neither
  ceiling moved; both comments now name the target that reproduces their
  figures, and a documented `STACK_MAX_FRAME=16` override example that exits 2
  against the 19 B timer ISR frame is corrected to 24.
- **The ATtiny202 shell shipped an unresolved `CONFIRM` note on its BOD fuse.**
  A bring-up instruction to the reader — confirm the BODCFG level encoding and
  that the level is characterised rather than reserved — was published on a
  release-supported part, on the fuse that establishes the peripheral-safe
  voltage floor. It is answered in place from the pinned device pack so the
  evidence travels with the code, and the note pins down the trap that makes the
  question worth asking: the pack carries two BOD level enums, one for `BOD.CTRLB`
  at bit 0 and one for the fuse at bit 5, and decoding a BODCFG byte with the
  register enum yields a confident wrong answer. The PIC10F320 shell carried the
  same ten CONFIG bits as the PIC10F322 with no explanation, so a maintainer
  reading only the 320 got the safety-relevant configuration without the
  reasoning; it now points at the 322's rationale block rather than copying it.
  Both are comment-only: all six images are byte-identical, and no `CONFIRM`,
  `TODO` or `FIXME` marker remains under `src/`.
- **The debounce documentation confused eight samples with eight milliseconds.**
  `PRESSED_THRESH` was described as a fixed 8 ms duration when it counts eight
  sample instants; clean press latency and isolated-pulse rejection are now
  derived from those instants, arbitrary edge phase and the stated oscillator
  tolerance. The timing example is redrawn to show the seven intervals between
  eight low samples and 24 intervals between 25 high samples.
- **The live PIC10F320 documentation contradicted itself.** Its expected-image
  check is now described as the standing SHA-256 gate it is, with its
  compiler-reproducibility limitation retained; blocking actuation timing is
  scoped to both polled PIC implementations and both ISR-driven AVR generations
  rather than one part; the target topology is stated as five shared-core
  targets through three shell files plus one self-contained target; and direct
  core comparisons are separated from the other PIC10F320 evidence lanes.
- **The MISRA compliance record's scope and its deviations disagreed.** Genuine
  AVR register-access deviations were not distinguished from
  cross-translation-unit artifacts or PIC10F320 analyzer accommodations. The
  record now documents the eight-source/fourteen-header analysis boundary, each
  target's direct cppcheck inputs, the Classic-only report scope and the
  PIC10F320 variant sweep, with the suppression-file comments aligned to match.
  No waiver changed.
- **Historical release provenance overclaimed the soak matrix.** Manifests for
  `v0.9.0`–`v0.9.4` say "24.0-h parallel soak of every variant × MCU", which is
  broader than the retained evidence: the ATtiny13a images were not soaked
  directly, because simavr cannot model their watchdog reset, and were covered
  by the full suite and the core-identical tinyx5 soaks — as each manifest's own
  limitation note already said. `release/README.md` now carries a live erratum
  linking each affected release's note, and this file's claims are narrowed to
  the canonical release soak combinations. The historical snapshots are
  unchanged.
- **The toolchain record said KLEE was absent.** It now names the validated
  Linuxbrew KLEE 3.2 and matching LLVM 16.0.6 tools with their configured paths
  and measured real-core result, keeps the host enumerator fallback, and
  distinguishes that local solver run from the still-absent KLEE execution in
  CI.
- **Two firmware comments contradicted the code they describe.** The PIC10F320
  bypass and engage call sites named the physical MCU pin levels backwards, and
  an adjacent branch comment cited a pure-core state member that does not exist.
  Comment-only: pinned before-and-after builds produced all 18 images
  byte-identically.
- **Imported PIC10F320 harnesses named the standalone project's make targets.**
  Comments carried over from the pre-merge repository directed readers to
  unprefixed targets that do not exist here; they now name the integrated
  `pic320-*` targets, and the gpsim script's supported output-variant count is
  corrected from five to three.
- **Strict CI and release environments omitted prerequisites they assume.** Git,
  GnuPG and PyYAML are now installed and asserted before the strict suites and
  before release signature, qualification or history verification, with the same
  checks in `ci-local.sh`'s unconditional host preflight. The Ubuntu and Docker
  toolchain recipes are updated to match, and workflow validation now enforces
  real apt arguments, executable assertions and placement before first use
  rather than accepting whatever the runner image happens to contain.
- **Assorted live-documentation and shell defects.** The top-level simulator
  summary omitted the ATtiny202 lock-step gate; `test/README.md` omitted nine
  tracked validation scripts and AVR-XT tests, and did not call out the
  exact-pin helper shared by both PIC harness families; a release link,
  validation table, tool label, target count and several fragile source-line
  references were wrong across the live documentation; and the two `.gitignore`
  files contradicted each other about `commit_msg.txt` — both now state the same
  policy under which these disposable working notes are ignored. The yasimavr
  fetcher now uses POSIX signal 0 for its cleanup trap and passes ShellCheck,
  with no change to its path or replacement-safety behaviour.

### Changed
- **`test` and `test-long` now share one gate inventory.** The two aggregates
  ran the same 46 gates in the same order, differing only in workload sizing and
  in `test-long` additionally running `test-mutation` — but each carried its own
  hand-maintained prerequisite line, so a new gate could land in only one of
  them, and the one it would miss is `test-long`, the release gate. Both are now
  built from a single `TEST_GATES_EARLY`/`TEST_GATES_LATE` inventory
  (`TEST_GATES` and `TEST_LONG_GATES`); the expansions are byte-identical to the
  lines they replace, order included. The ATtiny202 build's own 30-line Intel
  HEX parser is likewise gone, replaced by the `scripts/validate-ihex.sh` that
  the Classic AVR `.hex` rules and both PIC builds already use — with all six
  ATtiny202 images verified byte-identical across the swap.
- **The two throwaway-repository builders now share one walk.**
  `make test-mutation` builds a sandbox per mutant and `test-pic-build-rebuild`
  builds one for the PIC soak file rules; both copy the tree into a `mktemp`
  directory and run Make inside it, but they learned about a new file by
  different means — an extension-allowlist `find` walk versus a hand-enumerated
  prerequisite list. `test/pic/find_pin_exact.h`, made a prerequisite of both
  chips' soak binaries by `b4da21c`, broke each of them in turn. The mutation
  runner is where that costs most, because there the omission is silent: a
  missing file fails the baseline probe, a failed baseline is recorded as a
  *skip*, and 18 mutants went unenforced while the run reported every mutant it
  did evaluate as killed. Both harnesses now source `test/scratch_tree.sh`. The
  walk itself is unchanged — the sandbox it produces is byte-identical to the
  one the mutation runner built before — and `test_pic_rebuild.sh` keeps only
  its own step, blanking the named prerequisites, since the property under test
  is Make's staleness decision and not compilation. That list can no longer omit
  a file and stop Make short of the property; what it still does is assert those
  files *are* prerequisites, so a rename is reported in one line instead of
  quietly shrinking the fixture (9 → 14 checks).
- **The PIC10F320 documentation set now has one owner per kind of claim.** Its
  lane inventory, assurance argument and mutation mechanics were repeated across
  `docs/pic10f320_special_case.md`, `docs/pic10f320_validation.md` and
  `test/README.md`, with every change-prone count living in two places at once.
  They agreed at the time of writing, but a stale emitted-byte statement fixed
  earlier in this cycle shows what that costs. The split is now explicit and
  stated in `DESIGN_DOCUMENTATION.adoc`: `special_case` owns the architectural
  difference and the assurance argument, `validation` owns execution evidence and
  the scope of what each result does and does not establish, and `test/README.md`
  owns the current inventory — Make targets, substrates, mechanics and check
  counts. Duplicated inventories became links: the assurance table dropped its
  Make-target column, and the validation record's copies of the return-stack
  oracle's decoder rules, the rebuild regression's assertions and the mutation
  category/accounting contract were replaced by pointers, keeping the historical
  measurements and scope caveats that are its own. No count moved; the two
  mechanics details that existed only in the validation record moved to
  `test/README.md` rather than being dropped.
- **The copyright notice names one holder.** `LICENSE` read
  `Copyright (c) 2026 matt-garman` while all 55 project-authored source headers
  read `Copyright (c) Matthew Garman`, and the release signing key carried a
  third form. MIT grants *from* the named holder, so the notice is what a
  downstream license review reads to identify who could grant a relicense or be
  party to an assignment — a role a GitHub handle does not fill. `LICENSE` now
  reads `Copyright (c) 2026 Matthew Garman <matthew.garman@gmail.com>`, matching
  the source headers and adding a contact path that travels with the notice into
  every downstream copy. `2026` is confirmed as the year of first publication.
  Source headers are unchanged, and published releases are untouched: they ship
  `.hex` images and provenance records, not `LICENSE`, so no signed artifact
  contains the superseded string.
- **External supply-chain inputs are now pinned and integrity-checked.** The
  reviewed XC8 and PIC DFP hashes are verified in one shared installer before
  either download executes; every workflow action is pinned to a full commit
  SHA; checkout credential persistence is disabled and `GH_TOKEN` scoped to
  publication; the complete yasimavr build and runtime environment is
  hash-locked without build isolation or dependency resolution; and the exact
  ATtiny_DFP cache tree is re-hashed on every use rather than trusted once.
- **The PIC10F320 lane now reuses the PIC10F322 harnesses instead of duplicating
  them.** The merge left separate fault, lock-step and target-I/O
  implementations carrying over a thousand duplicated lines. Each is now an
  include-only shared core behind a thin per-part adapter, with processor and
  image defaults, output-macro vocabularies, program-space limits, fault counts
  and the PIC10F322-only LATA injections kept explicit at the adapter boundary.
  A second pass removed what that one left: all four harnesses — the soak
  included, which the first pass did not touch — now share one `gpsim_bootstrap.h`
  for the ~30-line libgpsim bring-up, and the two gpsim CLI wrappers share the
  75 byte-identical lines of tool discovery, timeout validation, `STRICT_TOOLS`
  skip-vs-fail contract, invocation, snapshot extraction and verdict. Bring-up
  is split across two functions rather than one so that every harness keeps the
  work it does between loading the processor and attaching the footswitch, and
  not one simulator operation is reordered in any of the four. Consolidating
  exposed a real defect: `footsw_set(1)` drives RA3 low — PRESSED — while the
  fault core and the soak both documented it as "1 = released", so two of the
  four described their footswitch backwards. One correct comment now lives in
  the shared header. Because a shared file the mutation sandbox does not require
  degrades the PIC10F320 lane silently, both new files are required entries in
  `validate_pic320_sandbox()`.
- **Post-release status language now reflects what shipped.** ATtiny202 and
  PIC10F320 are marked released in the unified `v0.9.6` image set, and the
  PIC10F320 is promoted to release-supported while keeping its constrained-target
  architecture and assurance caveat; the validation narrative points at the
  retained production evidence.
- **The completed PIC10F320 merge plan is marked historical.** It remains useful
  as a section-numbered decision record and is cited throughout the
  implementation, but its paths, targets, scope and status describe the merge
  rather than the tree. A banner now records the merge as complete, preserves
  the body and section anchors, and directs current architecture and validation
  questions to the maintained PIC10F320 documents.
- **The third-party yasimavr patches carry their licensing.** The two
  modified-source patches now identify the pinned yasimavr 0.1.6 source, its
  upstream copyright holder and GPL-3.0-or-later terms, alongside upstream's
  verbatim GPLv3 text, with each patch marked with its license and modification
  date. The root MIT grant is clarified to exclude third-party material carrying
  its own license.

### Added
- **Two ATtiny202 build regressions** covering an absent and a non-executable
  Intel HEX validator; the second is what exposed the guard hole fixed above.
  `test-workload-rebuild`'s "no `clean-tests` in `test-long`" check now reads
  the aggregate's real prerequisites through `make print-TEST_LONG_GATES`
  instead of grepping the recipe line, which the shared inventory would
  otherwise have made blind, plus a check that the query itself resolves so it
  cannot pass vacuously.
- **`make test-soak-reset-witness`** proves that fix stays true. It builds the
  soak driver twice against the same healthy ATtiny85 image — untouched, and
  with a compile-time fixture that disables the timer interrupt mid-run so the
  main loop stops petting the dog — and requires the first to pass with
  `watchdog_failures=0` and the second to fail with a nonzero one. The control
  half is what stops a permanently broken soak from satisfying the failing half
  on its own. Part of `make test` and `make test-long`.
- **A Classic AVR soak-lane mutant**, giving that family the coverage the
  PIC10F322, PIC10F320 and ATtiny202 families already had. It empties
  `hw_wdt_pet()` at its definition — so the call site remains and the build
  stays clean — and is killed by the soak's reset witness. This raises the
  pinned mutation inventory from **93 to 94** (24 core/AVR, was 23); the counts
  quoted in the `0.9.6` entries below are the historical figures for that
  release and are unchanged.

  The two pre-existing watchdog-handshake mutants keep their kill targets but
  had their descriptions corrected: both run on the ATtiny13a lane, where simavr
  models no WDT system reset at all, so neither was killed by the watchdog.
  Deleting the `hw_wdt_pet()` call site leaves the function unused and fails the
  build under `-Werror=unused-function`; breaking the ISR handshake stops the
  debounce state machine and fails the functional, noise-count and lock-step
  assertions.
- **`make test-supply-chain`**, pinning the integrity contract for every
  external input: offline corruption, cache reuse, workflow action pinning and
  token-scope regressions.
- **`make test-fetch-yasimavr`**, an offline regression set for the venv
  fetcher's safety properties — sentinel handling, failed builds and failed
  verification, rename and signal rollback, path aliases, and destinations that
  change late.
- **`make test-pic320-coverage-archive`**, which runs the real coverage target
  and checker against a source-archive fixture with deterministic tool
  stand-ins, and proves that local-mode or index-mode failures stop before
  compilation.
- **Fail-closed regressions for the gates the fixes above touched.** The shared
  target-matrix regression gained AVR-XT whole-matrix lane and missing-marker
  fixtures; `test-ci-local-routing` exercises all four push skip combinations
  through a complete fake AVR-XT preflight and PASS-count route, so the
  ATtiny202-only case cannot regress unnoticed; `test-release-history` gained
  the `autocrlf` artifact fixtures and the line-ending policy assertions; and
  the PIC soak liveness work added synthetic transition, reset and force-reset
  fixtures with complete rebuild dependency wiring.

## [0.9.6] - 2026-07-30

### Added
- **The GitHub workflow files are now validated locally** (`make
  test-workflow-syntax`, and a `ci-local.sh` preflight that runs it first).
  Nothing in the repo had ever parsed them: the release regressions `grep`
  `release.yml` for fixed strings, which succeeds on a file GitHub cannot load,
  and `ci-local.sh` reproduces the job order from a comment header rather than
  from `ci.yml`. An unquoted job `name:` containing `": "` therefore took the
  entire CI matrix down with "Invalid workflow file" after a full clean
  `ci-local.sh` pass. Both workflows must now parse, every job must have a
  runner and steps, every `needs:` must resolve to a declared job, every action
  must be version-pinned, and `ci.yml`'s job list must agree with
  `ci-local.sh`'s CI-JOB MAPPING in both directions -- so a job added, renamed
  or dropped can no longer silently stop being mirrored locally.
- **ATtiny202 (AVR-XT) promoted from development-only to a release-supported
  target**, bringing the release product set to six parts and 18 images. It was
  classified development-only on 2026-07-14, in the middle of the week its
  harness was being hardened; the classification recorded a scoping decision, not
  a technical blocker, and the lane has since caught up with its peers. Its three
  images are now built, qualified, staged and reproduced, and all three ATtiny202
  release soak combinations are run directly.
- ATtiny202 firmware/model **lock-step co-simulation** (`make attiny202-lockstep`),
  the AVR-XT counterpart of the classic simavr co-sim and `pic-test-lockstep`.
  After every settled 1 ms tick it reads the shell's `ctx_` out of simulated SRAM
  and requires all three bytes to equal the shipping core's state after the same
  tick, over both power-on scenarios. This closed the last structural verification
  gap: the harness previously asserted observable behaviour only, so a shell that
  reached the right LED state by the wrong internal trajectory passed.
- A ctypes bridge (`test/avr/model_step_ffi.c`/`.py`) letting the Python drivers
  call the **shipping** `src/bypass_pure.c` through `test/model_step.h`. Python
  cannot include a C header, and re-implementing the algorithm there would
  recreate exactly the drift hazard `model_step.h` exists to eliminate. Its own
  host gate (`make test-attiny202-model-ffi`) asserts independent hard-coded
  algorithm properties, since lock-step mutates model and firmware together.
- An **ATtiny202 mutation lane**: 19 mutants against the AVR-XT shell and the two
  shared coil-pulse widths, each mapped to the gate that observes what the fault
  actually perturbs. Nothing previously established that this lane's suite would
  fail on a defect in the shell it exists to test. One mutant weakens the PA7
  pin-control guard to its pre-hardening bit test rather than defeating it, which
  is what proves the fault matrix's `PIN7CTRL=0x88` injection is load-bearing:
  that value keeps `PULLUPEN` set, so only the exact comparison can reject it.
  Gated on the ATtiny_DFP and the patched yasimavr venv both resolving *and*
  every kill target passing on the unmutated tree, since each `attiny202-*`
  target exits 0 on a missing input and would otherwise report 19 survivors as a
  clean run.
- `make attiny202-test-target`, the fail-closed AVR-XT aggregate (sim + fault +
  lock-step, every variant) that release qualification and release CI run with
  `STRICT_TOOLS=1`.
- ATtiny202 documentation to match its peers: a rationale section, the SOIC-8
  pinout and pin roles, resource utilization, its place in the multi-MCU
  architecture chapter, a full target-validation-layers table, and an explicit
  "Known gaps (AVR-XT — hardware-bench only)" section covering yasimavr's flat
  instruction timing, the unobservable force-reset completion, the two vendored
  simulator patches, the missing shell stack bound, and untested UPDI programming.
- **PIC10F320 integrated as a release-supported target** — the first whose
  firmware does not compile the verified core but implements the debounce
  algorithm directly, because 256 words of flash cannot hold the shared-core
  architecture. Merged from a separate repository with its full history
  preserved. See `docs/pic10f320_special_case.md` for what that difference does
  and does not buy, and `docs/pic10f320_merge_plan.md` for every decision taken.
- PIC10F320 validation lanes: firmware-to-core equivalence against
  `src/bypass_pure.c` itself (266,144 sequences, all 66 reachable model states),
  per-variant actuation-sequence checks, host fault injection, an exact-line
  firmware coverage gate, real-HEX lock-step, target fault injection, target I/O
  timing, CONFIG-word verification, cppcheck + MISRA across all three variants,
  and a libgpsim soak. The host subset needs only a C compiler and gcov, so it
  runs inside `make test` on every push.
- A dependency-free PIC10F320 final-HEX return-stack oracle now strictly parses
  Intel HEX and explores reachable classic mid-range PIC14 control flow with the
  exact abstract hardware stack. Its host fixtures are in `make test`; the
  fail-closed base `pic320` recipe checks every generated image before marking it
  complete, while `pic320-test-return-stack` rebuilds and rechecks the supported
  three-image matrix against the architectural eight-entry limit as part of
  `pic320-test`.
  Its state and return stack preserve the 9-bit architectural PC; instruction
  fetch alone aliases through the low eight bits to 256 physical words.
- The shared fake-tool PIC build regression now has a PIC10F320-only
  rebuild-trigger lane. Exact output-specific compiler logs prove identical
  `pic320` and host-test requests rebuild, and that changed/restored clock,
  output-variant and host flags reach the current invocation. Canonical target
  counts make activation fail closed; same-name target sentinels enforce
  `.PHONY`, and exact fake-binary execution counts enforce each host run recipe.
  This proves fresh triggering, not byte-for-byte XC8 reproducibility.
- A standing PIC10F320 expected-image regression now pins the complete
  three-variant HEX matrix to the reviewed XC8 V3.10 / DFP 1.9.189 SHA-256
  baseline. Its dependency-free parser and fixtures run in `make test`, while
  `pic320-test-build` performs the real comparison through CI/release
  qualification. The hash gate stays outside mutation kill targets so byte drift
  cannot mask whether each behavioural lane catches its assigned defect.
- A **canonical release product set** (`RELEASE_IMAGES` in the Makefile),
  enforced by the release script, the image verifier and its regression alike.
  Previously the committed directory, the `SHA256SUMS` entries and the fresh
  build were all derived by globbing, so three "independent" checks agreed
  perfectly on a release with an entire MCU missing. They no longer can.
- Three PIC10F320 full-duration soak combinations are required by the release
  pipeline. `v0.9.6` is the first unified release to publish those images as
  release assets; normal CI also publishes its separate development artifact.
- `make pic320-*` targets, `make help` entries for them, and a
  `docs/pic10f320_special_case.md` linked from the README, the design
  documentation, the release documentation and the generated release manifest.

### Changed
- The ATtiny202 soak now emits the same `SOAK_RESULT format=1 ...` machine record
  and `SOAK PASS: <duration> ms ...` line the AVR Classic and PIC soaks do, so all
  three substrates are interchangeable to the release orchestrator. Its schedule
  moved onto a soak clock that excludes the time a liveness round-trip itself
  consumes — the classic loop's semantics — because scheduling on raw simulated
  time lets each round-trip's ~120 ms eat the schedule: invisible over an hour,
  but enough to silently drop the last two or three checks at the release's 24 h
  and fail an otherwise perfect run. `checks` in that record means liveness
  checks, matching the peers; the finer-grained reset-witness sampling is counted
  and reported separately.
- The one fail-closed mutation run (the `pic` CI job) now provisions the ATtiny202
  toolchain too, so a single authoritative run still covers every substrate rather
  than splitting into partial per-job gates. Skip accounting counts PIC and
  ATtiny202 separately, so a partial run always names which substrate went
  unexercised.
- The final-HEX return-stack oracle no longer hardcodes the device geometry.
  `--program-words` supplies the implemented program memory from the device
  pack's `ROMSIZE`, is validated as a power of two inside the 9-bit PC space
  (both supported parts declare `PCBITS=0x9`), and an image carrying program
  data above the declared size is now **rejected outright**. Under-declaring was
  the dangerous direction — the fetch alias would fold a high PC onto a
  different instruction and could report a *lower* depth than the truth — and it
  previously surfaced only as a confusing downstream error about a computed
  `PCL` write at an aliased address. Ten selftest checks pin the alias in both
  directions; the regression is now 149 checks.
- The strict-tools inventory now covers optional-tool recipes for **both** PIC
  chips, not just the two host analyzers it started with.
- MISRA documentation is now a per-target statement rather than a comparison
  against another project, and records deviation **D-4** (the PIC10F320
  analyzer symbol-resolution waiver) that the suppressions file already cited.
- The `pic` CI job covers both PIC parts; `scripts/ci-local.sh` mirrors it and
  documents that `--skip-pic` skips both chips.
- Simulator "known gaps" documentation is now shared PIC content covering both
  parts, rather than two per-repository copies that had already drifted.

### Fixed
- Current release documentation, Make help, source comments, and generated
  manifest wording now consistently describe ATtiny202 as release-supported and
  use the 18-image, 15-soak, 28-evidence-file, 93-mutant contract. Dated
  rehearsal records retain their historical 15-image, 12-soak, and 74-mutant
  results.
- The Classic AVR `timer_isr_called_` fault injection no longer treats an
  already-dark BYPASS LED after roughly 7 ms as proof of watchdog recovery. It
  starts ENGAGED, single-steps to the ISR's handshake write, corrupts it before
  main can read it, and requires both a device-reset witness (simavr's
  `avr->reset` hook, which its watchdog reset path calls) and fail-safe dark
  output after reset. A dedicated mutant removes only that sanity term.
- The ATtiny202 fault matrix now covers `PORTA.PINnCTRL.INVEN` on the LED,
  control/relay, parked-spare, and footswitch pins. The PA7 case preserves its
  pull-up while reversing input polarity, proving the firmware's exact PA7
  control check rather than the old pull-up-only predicate. Exact zero control
  checks similarly protect the four output pins, and the per-variant matrix
  expands from 17 injections / 18 results to 22 / 23.
- Qualification documentation now distinguishes historical phase evidence, the
  clean but non-publishable `4b28210` full-tool rehearsal, and retained
  final-source production evidence. It no longer claims that corrected 74/74
  mutation execution and real-image stack gating never occurred, and the release
  guide scopes the `QUALIFICATION` soak/evidence contract to unified releases
  rather than directing `v0.9.0` through `v0.9.5` to files and targets they
  predate.
- Release publication now requires both cryptographic signatures promised by the
  trust model. CI verifies `SHA256SUMS.asc` and the exact remote annotated tag
  object against the checked-in public key and pinned full fingerprint before
  publishing; missing, empty, malformed, wrong-key, lightweight, unsigned,
  same-target-replaced, and moved tags all fail closed. Signing instructions pin
  the same key explicitly instead of relying on the operator's GPG default.
  Producer and verifier version validation now matches the workflow's optional
  hyphen-suffix trigger and rejects malformed or invalid Git tag names before a
  production qualification run.
- Mutation results now conserve an immutable 93-mutant inventory across seven
  pinned categories: dispatched plus skipped must equal 93, and killed plus
  survived plus errored must equal dispatched. Inventory records, baseline Make
  commands, worker exits, sandbox setup, atomic result pairs, exact status/output
  grammar, and unexpected artifacts all fail closed instead of allowing a
  shortened or partially published run to report "all mutants killed."
- The PIC10F322 `pic` producer now requires the complete immutable output-variant
  matrix before invoking XC8, rejecting empty, duplicate, unsupported, and
  incomplete requests. Classic AVR and PIC10F322 entries in `RELEASE_IMAGES` now
  derive from that immutable set, so a `VARIANTS` override cannot weaken the
  independent release contract along with the requested build. Both PIC matrix
  requests are sanitized before recursive Make or shell expansion, and their
  HEX/assembly/symbol cleanup inventories cannot be disabled by command-line
  overrides.
- PIC builds now invalidate XC8's generated `.s` and `.sym` sidecars together
  with each HEX before compiling and remove the same complete product set after
  failure or interruption. The hardware-stack targets skip only when no current
  HEX exists; a current image without fresh, regular, nonempty assembly now fails
  instead of allowing stale evidence or an absent-tool skip.
- Tag CI now binds retained 24-hour qualification to Git history: the tagged
  release commit must be a single-parent, artifact-only child of the exact source
  commit named by `QUALIFICATION`. A scratch-repository regression rejects wrong
  parents, merge commits, mixed source/release changes, sibling-release changes,
  checkout drift, a snapshot differing from the tagged record, and a remote tag
  that moved before publication.
- Release qualification is now machine-verifiable before publication: an
  immutable 15-combination inventory, exact retained-evidence set, strict
  `QUALIFICATION` schema, and one identity/timing/counter-bearing `SOAK_RESULT`
  per log must agree. Tag CI verifies a private snapshot before installing tools
  and publishes the qualification record; PIC images are hash-pinned across soak
  compilation, execution, and staging just like validated AVR ELFs.
- Dry-run release artifacts cannot be staged under the repository's release tree,
  and tag CI requires an explicit production-mode manifest while independently
  rejecting the dry-run banner before any release can be published. The output
  path is revalidated immediately before staging, and tag-derived values reach
  privileged workflow shells through the environment rather than source-text
  interpolation.
- `pic320-variants` now requires the complete supported build matrix, and the
  canonical release set no longer shrinks with a `PIC320_VARIANTS_ALL` override.
- Release provenance now probes both selected XC8 compilers fail-closed and
  records target-qualified compiler paths and versions instead of attributing
  both PIC image families to `PIC_CC`.
- PIC host and real-target "all variants" aggregates now reject proper subsets
  of the supported matrix instead of running one variant and reporting that all
  variants passed.
- PIC gpsim validation now shares one exact pin-name resolver across all
  libgpsim harnesses and tests RA3 against substring decoys; fake CLI gpsim also
  rejects stimuli not attached exactly once to `ra3`.
- The host lock-step progress regression now compiles and stalls both PIC
  adapters. Dropping the byte-identical child script had accidentally retained
  only the PIC10F322 source path and left PIC10F320 stall handling untested.
- The shared fake-XC8 interruption regression now requires proof that SIGTERM
  reached each PIC build recipe; `pic320` exports its recipe PID so a missing
  variable can no longer masquerade as successful cleanup validation.
- `pic320-size` now fails closed on compiler, image-validation, and summary
  failures and removes every temporary XC8 artifact after success, failure, or
  interruption instead of suppressing the probe pipeline's exit status.
- The shared gpsim wrappers and both public PIC functional targets now honor
  `STRICT_TOOLS=1`; a missing simulator cannot become a successful strict run.
- Standalone PIC10F320 target and soak selectors now rebuild the selected
  variant instead of potentially consuming a stale image while rebuilding the
  default `PIC320_VARIANT`.
- `pic320-test-gpsim` now runs the forked PIC10F320 toggle stimulus instead of
  silently using the PIC10F322 cadence checkpoints through the shared wrapper.
- PIC10F320 mutation sandboxes now include the folded gpsim wrappers and stimuli,
  and the tool probe baselines every distinct kill command. A missing harness can
  no longer make the TMR2IF cadence mutant falsely count as killed.
- The mutation sandbox now mirrors every test source at any depth instead of
  four extensions one level down, restoring 18 PIC mutants that had been silently
  skipped: `test/pic/find_pin_exact.h` never reached the sandbox, and it is a
  prerequisite of both chips' soak binaries and all three target lanes. The
  sandbox validator requires that header, and the self-test proves the copy
  reaches three levels deep. The copy stays an extension allowlist by design —
  `test/` also holds build products, and mirroring them with preserved mtimes
  could make Make skip a rebuild and score a mutant against unmutated source.
- The shared PIC gpsim preflight no longer consults the git index outside a work
  tree, where `git ls-files` reports an empty mode that the guard read as a
  failure. This made `pic320-test-gpsim` unrunnable inside the mutation sandbox;
  the PIC10F322 lane had routed around the same obstacle, so only one chip was
  affected. The local executable-bit check is unchanged and still unconditional.
- Mutation skips now report whether a lane was disabled because a tool was
  absent or because its baseline FAILED, and the closing advice no longer tells
  the reader to install a toolchain that is already complete. With both sandbox
  gaps closed, `make test-mutation MUTATION_ALLOW_SKIP=0` completes all 93
  mutants — 93 killed, 0 survived, 0 errored, 0 skipped.
- The PIC10F320 real-HEX target aggregate now requires explicit fault-injection,
  lock-step, and target-I/O completion markers, so a skipped or incomplete lane
  cannot be reported as a successful CI/release gate.
- **`pic320` and `pic320-size` printed "skipping" and then built anyway.**
  `$(SKIP)` is `exit 0` in non-strict mode and exits only its own shell, so a
  guard on its own recipe line skipped nothing. An audit found no other instance
  in the Makefile.
- **The PIC10F320 build left a partial image set** when one variant failed; it
  now removes the whole set.
- The ported flash-budget comparison was weaker than this project's own and
  conflated "not over budget" with "the comparison tool failed".
- **`pic320-test-gpsim` had no gpsim probe at all**, so `make pic320-test
  STRICT_TOOLS=1` on a host without gpsim reported "all PIC10F320 pre-hardware
  checks complete" having run none of its six scenarios — the wrappers exit 0 on
  a missing simulator by design, and nothing above them looked. The port also
  dropped the `GPSIM=` passthrough, so that override was silently ignored on this
  chip and the lane tested whatever `gpsim` was on `PATH`. Both chips' lanes now
  share one preflight definition, and both are registered in the strict-tools
  inventory (18 → 22 checks) rather than excluded from it.
- `pic320-test-config` now skips cleanly when no image was built, instead of
  handing an unexpanded glob to the CONFIG checker and failing where the
  PIC10F322 lane skipped.

## [0.9.5] - 2026-07-18

### Added
- Fail-closed ATtiny202 production-fuse verification for `WDTCFG`, `BODCFG`,
  `OSCCFG`, `SYSCFG0/1`, `APPEND`, and `BOOTEND`, including host regressions
  proving yasimavr receives the same complete Makefile-defined fuse set.
- ATtiny202 built-image target-output coverage for exact physical PA2/PA3
  startup/engage/bypass sequences, pulse presence and ordering, relay-coil
  exclusion, and low parked outputs, backed by a host-only oracle regression
  for positive and fail-closed trace paths.
- Fail-closed ATtiny202 fault execution now requires all 17 independently pinned
  injectable guards, zero skips, exact result counts, witnessed WDT resets,
  phase-swept ISR-handshake corruption, and a long healthy negative control.
- An ATtiny202 disassembly oracle now verifies absolute 5 ms mute and 12 ms
  relay pulse widths directly from each built image, independent of yasimavr's
  non-cycle-accurate delay execution. *(Note added 2026-08-02: the oracle is
  unchanged and still correct, but that stated reason for it was not — yasimavr
  does model multi-cycle instruction timing. See the correction under `0.9.8`.)*
- Host-only regressions now exercise PIC target-matrix validation and lock-step
  simulator stalls without requiring XC8 or libgpsim.

### Changed
- Complete Make and direct release-script invocations now hold one worktree-local
  lock, preventing independent processes from replacing shared firmware, test,
  coverage, or simulator artifacts while preserving explicitly isolated
  recursive test fan-out.
- Classic AVR, AVR-XT, and PIC10F322 sanity gates now verify the complete
  settled output latch against the logical effect state, including low-driven
  spare pins and inactive relay coils.
- Classic AVR and ATtiny202 sanity gates now require the complete GPIO direction
  state configured at startup, detecting footswitch pins becoming strong outputs
  and intended low-driven spare outputs becoming inputs.
- The PIC10F322 sanity gate now requires the complete TRISA direction state
  configured at startup (exact `0x08`), closing the gap where a spare RA2
  direction upset on the simple-CD4053 variant fell outside the required-subset
  check. Fault injection, shipping-source coverage, and mutation coverage now
  exercise the exact predicate on every variant.
- Routine push, scheduled, and manually dispatched CI now runs mutation testing
  in strict mode on the full PIC-toolchain runner; pull requests retain the
  faster non-mutation path.
- ATtiny202 is now explicitly classified as development-only/non-release. Its
  normal build and yasimavr CI lane remains available, while release images,
  reproduction, and long-soak qualification remain scoped to AVR Classic and
  PIC10F322.
- The full-tool ATtiny202 CI job now runs `make attiny202-test STRICT_TOOLS=1`,
  making its cppcheck and MISRA analysis mandatory alongside fuse, build, and
  flash-budget and pulse-width validation.
- PIC shipping-source coverage is now a required gate, and mutation coverage
  explicitly rejects the wrong unified x4053 BYPASS polarity.

### Fixed
- Long release runs now recheck the recorded source `HEAD` and worktree
  cleanliness after validation and immediately before creating the staging
  directory, refusing to attach artifacts or evidence to stale provenance. The
  dirty-tree exception is now restricted to non-publishable dry runs.
- Tap-timing documentation now scopes the 33 ms minimum to the pure model,
  ISR-driven AVR shells, and simple PIC variant, and records conservative polled
  PIC mute/relay qualification budgets of 38 ms/45 ms plus the pending-timer
  nuance that can shorten the ideal path by roughly one tick.
- Symbolic-test documentation now accurately scopes host/KLEE coverage to every
  invariant-valid state/input tuple and identifies CBMC as the separate proof of
  corrupt program-state handling, released-input recovery of out-of-range
  counters, and undefined behavior obligations.
- The optional KLEE target now compiles and links the symbolic harness with the
  shipping `src/bypass_pure.c` bitcode before execution, preventing unresolved
  core calls from masquerading as a proof of the real implementation.
- `scripts/ci-local.sh --skip-pic` now permits unavailable PIC mutants to skip
  during push-mode `test-long` while retaining `STRICT_TOOLS=1` for host/AVR
  gates; full local-CI runs explicitly keep mutation fail-closed.
- Missing CBMC or cppcheck now fails `test-cbmc` and `analyze-cppcheck` under
  `STRICT_TOOLS=1` instead of silently turning required CI analysis into a skip.
- Native Classic AVR and PIC soaks now require the liveness interval to fit
  within the total run, and short release rehearsals clamp and propagate that
  interval so a passing soak includes at least one responsiveness round-trip.
- PIC flash-budget acceptance now requires a positive decimal budget, compares
  arbitrarily long usage counts without fixed-width shell arithmetic, and
  rejects failed comparisons or missing percentage results.
- Release reproduction now rejects committed-as-fresh and duplicate fresh
  directories after physical-path resolution, then verifies `SHA256SUMS`,
  committed images, and fresh images from one immutable set of private snapshots.
- Historical `v0.9.0` through `v0.9.2` release documentation now prominently
  identifies the superseded `*_tmux*` images whose direct-drive polarity maps
  the absent/undriven-MCU pull-down state to ENGAGED instead of fail-safe
  BYPASS, and directs users to the unified images from `v0.9.3` or later.
- Classic AVR, ATtiny202, and PIC image generation now fails closed on missing,
  stale, partial, malformed, over-budget, or unverifiable output. Intel HEX
  structure, stack/flash/fuse evidence, workload rebuilds, model coverage, soak
  timing, and release image sets all have isolated negative-path regressions.
- gpsim wrappers reject non-positive or malformed timeout values before invoking
  the simulator and propagate process failures or kills even after valid
  snapshots, while libgpsim targets remove stale binaries before rebuilding.
- PIC target fault injection now verifies register identity, write-back,
  simulator progress, exact per-variant completion counts, and restoration of
  negative controls before reporting PASS.
- PIC target aggregates reject empty, duplicate, or unsupported variant matrices
  before execution, and PIC lock-step stalls abort immediately during settle,
  calibration, or completion instead of looping on a frozen cycle counter.

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
- Per-tick sanity gate now checks `ANSELA` on the PIC10F322: an SEU/EMI flip
  that re-selects an output pin as analog (dark LED / dead control pin, with the
  `TRISA` direction bit unchanged) now forces a watchdog reset. `ANSELA` is
  masked to `BYPASS_OUTPUT_DDR_MASK` (`RA0|RA1|RA2`) and added as a fifth term
  to `hw_critical_sfrs_intact()`.
- Fault-injection coverage for the new `ANSELA` gate term: three inject cases
  (`ANSELA.RA0/RA1/RA2`) in `test/pic/test_fault_pic.cc`, each independently
  proven to force a reset and to fail if the guard is removed.
- `test/README.md` "Known gaps" now records the two PIC properties gpsim cannot
  faithfully assert: WDT-timing / brown-out behaviour, and the TMR2 prescaler
  *select* clamp (gpsim models `T2CKPS = 0b11` as 1:16 instead of the
  datasheet's 1:64) — both are hardware-bench guarantees.
- `CHANGELOG.md`.
- TODO items for two Tier-3 robustness explorations: a hardware-in-the-loop
  validation rig and complemented (inverted-copy) `ctx_` storage.

### Changed
- **PIC10F322 core clock reduced from 16 MHz to 2 MHz** (HFINTOSC), roughly
  halving MCU supply current (~0.85 mA → ~0.43 mA at 5 V) for no change to the
  reliability architecture — the busy-wait tick, per-tick SEU/EMI sanity gate,
  and LFINTOSC-based watchdog are untouched. The 1 ms tick is re-derived on the
  1:4 Timer2 prescaler (`T2CON = 0x05`, `PR2 = 124`) to land exactly 1 ms; the
  `__delay_ms` pulse widths (which track `_XTAL_FREQ`) and the FOSC-independent
  watchdog margin are unchanged. Low power is not a project goal — this simply
  avoids spending ~4 mW where ~2 mW does the same job, and emits less
  high-frequency switching noise into the analog audio path.
- **Renamed the PIC shell `pic10f32x` → `pic10f322`.** This project targets the
  PIC10F322 specifically, so the family "32x" naming is retired:
  `src/bypass_mcu_pic10f32x.c` → `_pic10f322.c`, `bypass_pins_pic10f32x.h` →
  `_pic10f322.h` (include guards included), and the build macro
  `BYPASS_MCU_PIC10F32X` → `BYPASS_MCU_PIC10F322`; every build/test/doc
  reference follows.
- Made PIC `ctx_` fault injection deterministic: the driver now parks the core
  at the main-loop `CLRWDT` (located by opcode, not a hardcoded address) before
  injecting, so no variant can land in the integrate-before-gate window where
  the integrator would overwrite the injected field before the sanity gate reads
  it. (At 2 MHz the previous ms-based settle produced intermittent false
  passes.)
- Normalized every `src/` license header from the "All rights reserved /
  Licensed under the MIT License" three-liner to the self-describing
  `SPDX-License-Identifier: MIT` form already used by the test sources.
- Refreshed the stale Phase-2 design docs with "as-built (2 MHz)" banners
  pointing at the shipped firmware as the source of truth, and corrected the
  Timer2/oscillator bullets (including a `T2CKPS` register description that
  listed 1/4/16 and dropped the 1:64 code).

### Fixed
- **PIC10F322 1 ms system tick ran ~4× slow (~4 ms) on real silicon.** `init()`
  programmed Timer2 with `T2CON = 0x07` (`T2CKPS = 0b11` = 1:64) while intending
  the 1:16 prescale, stretching every debounce interval 4× (press-confirm
  ~8 ms → ~32 ms, release-lockout ~25 ms → ~100 ms). Every simulation-based test
  masked it because gpsim mis-models the `0b11` code as 1:16, and the host /
  equivalence layers count ticks rather than wall-clock time; the defect was
  caught by cross-checking the programmed register against the datasheet
  (DS40001585D, Register 17-1 / Figure 17-1). Now a true 1 ms tick. The
  behaviour was still serviceable — and not a safety regression, the watchdog
  margin was unaffected — but off-spec in the v0.9.0–v0.9.1 prebuilt images.

> These PIC10F322 changes bring the shell to parity with the sibling
> [pic10f320-bypass-firmware](https://github.com/matt-garman/pic10f320-bypass-firmware)
> child project, which landed the same TMR2 / 2 MHz / `ANSELA` work after the
> fork. The pure debounce core and the output drivers are unchanged; the AVR
> targets are unaffected.
>
> *(Historical note, added at the merge: that project is no longer separate — the
> PIC10F320 target now lives in this repository. This entry is preserved as
> written because it describes the state of the world at v0.9.2.)*

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
