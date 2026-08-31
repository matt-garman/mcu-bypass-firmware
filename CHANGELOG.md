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
design, test, and release records instead. Existing release sections are
historical records and are not retroactively compacted by this policy.

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

- **`make test-reference-contract`: every citation in the live tree still
  resolves.** The PIC10F320 merge plan was cited by section number from 43
  places in the Makefile, the release scripts, the CI workflows and the test
  suite. It was deleted once its normative content had moved into
  `DESIGN_DOCUMENTATION.adoc`, and every one of those citations became a
  pointer to nothing -- silently, because a comment cannot fail to compile.
  Two stale line-number citations and one dead Markdown link in this file had
  the same shape. All 46 are repaired: each comment keeps the reasoning it
  carried and loses only the pointer a reader could not follow. The gate
  reserves the section glyph for external documents, whose publishers renumber
  them rather than we do, and requires every relative link and anchor in a
  durable document to resolve.

- **Releases publish the resource measurements they were already taking.**
  `MANIFEST.md` gains a **Resources** section with static RAM, the deepest
  observed Classic AVR stack, the AVR-XT per-frame compiler bound, PIC12F675
  Data space and PIC return-stack depth, each beside the reviewed ceiling that
  bounds it and the margin left. The images table's flash column now reads
  `used / reviewed ceiling (free)` for every image, including the three
  PIC10F322 images that published `n/a` while sitting closest to their limit,
  and the ATtiny13a images whose reviewed budget is tighter than the silicon.
  A downloaded release previously stated no RAM or stack figure for any part.

  Every figure comes from one machine record in the signed
  `evidence/resource-tables.log`, and the qualification verifier re-derives each
  published row from those records; the release script no longer derives flash
  usage of its own, so the figure that is checked and the figure that is
  published are the same figure. The AVR-XT entry is labelled a per-frame static
  bound and is rejected if it carries a high-water field, because
  `-fstack-usage` does not measure the deepest path through the frames it
  bounds.

### Changed

- **Current resource measurements are no longer restated in development
  documentation.** Each part's capacity, its reviewed ceiling and the gate that
  enforces it stay in `DESIGN_DOCUMENTATION.adoc`; the exact per-image flash,
  static-data and stack figures belong to the release record that binds them to
  a source commit and a pinned toolchain. A firmware size change no longer
  requires a documentation edit before release. `make test-resource-tables`
  reads every ceiling from the Makefile that declares it, measures each built
  image against it, and refuses a ceiling wider than the silicon it bounds; the
  release-time evidence checks validate each retained record against its own
  arithmetic and the limit it reports rather than against a remembered figure.
  Release resource measurement remains fail-closed at 21 of 21 images with
  complete RAM and stack evidence.

- **Normal hosted CI now runs the full mutation driver once per applicable
  event.** The fully provisioned PIC job remains the fail-closed mutation gate;
  hosted `stress` keeps every exhaustive non-mutation workload without repeating
  the skip-capable partial run. Release and local qualification retain
  `make test-long` as the exhaustive-plus-mutation aggregate.

### Removed

- **Retired the flashing-simplicity design journal.** The 678-line
  `docs/flashing_simplicity.md` recorded a v0.9.9 design discussion in the
  present tense of the branch it was argued on, so every section had to be read
  as a proposal unless an update paragraph said otherwise. Both proposals it
  recorded as shipped are stated where they are enforced -- the AVR
  build-before-hardware repair by `make test-avr-program-order`, the PIC12F675
  no-compiler path by `scripts/flash-pic12f675.py` and `FLASHING.md` -- and the
  command-shape and pasteability defects it described are fixed above. What
  remains open moved to `TODO.md` as three actionable items and two declined
  ones. Its `release_validate_flashing_simplicity_status` preflight contract
  goes with it: the contract existed to stop a preserved proposal from denying
  the implementation its own body recorded, and a document that no longer
  exists cannot mislead a reader.

- **Retired the one-shot v0.9.8 rename-identity lane.** The signed v0.9.8 tag
  retains the historical verifier and its 17-identical/one-changed report.
  Current releases continue to require exact canonical image reproduction,
  expected-image identity, signed checksums, and a frozen publication inventory
  without carrying inapplicable rename-report state.

### Fixed

- **Every programming command a release publishes now runs as written.** Of the
  eighteen per-image commands in the v0.9.11 manifest, three were pasteable. Six
  carried the source-checkout alternative as parenthesised prose inside the
  fenced block and are not valid shell; nine carried a bare `-c <prog>`, which a
  shell reads as a redirection rather than a placeholder, so the option left the
  command line silently. The two `make ...` forms named a Makefile no downloaded
  release contains and asked for a `VARIANT=<v>` the image basename beside them
  already fixed. Commands are now complete -- the project's default programmer
  and port are published inside them, a programmer-profile table names the only
  substitutions and the power assumption, and the source-checkout equivalents
  moved to their own section with their variants resolved. Nothing had ever
  checked this section: a release now fails if a published command is not valid
  shell, does not name the image it is filed under, omits a fuse byte its own
  images row publishes, writes a PIC without reading it back, or leaves a
  released image with no command at all, and the qualification verifier
  re-derives all of it from the staged manifest. Release metadata queries also
  no longer inherit the host's `AVR_PROGRAMMER`, `XT_PROGRAMMER` or
  `XT_UPDI_PORT`, so a release host's local programmer preference can no longer
  change the instructions a source tag publishes. PIC12F675 is unchanged: it
  still has no per-image command, and both the producer and the verifier now
  reject a manifest that gives it one.

- **The retained logs nothing was reading are now bound to the run that
  produced them.** Thirteen of the thirty-six retained evidence files -- seven
  build logs and six PIC/ATtiny202 target-test logs, 62% of the evidence tree by
  bytes -- were checked only for having the right name and being non-empty. No
  gate read a byte of their content, and `test/published_release_digests.txt`
  then froze whatever had been staged, so a log kept from an earlier run became
  a permanent part of the qualification record instead of failing anything: it
  is an immutability gate, and this was the qualification gate it cannot be.
  Each now carries an `EVIDENCE_RESULT format=1` record binding the log to the
  released commit, to its own name and to its own length, so a log from another
  run, a log substituted for its neighbour, a truncated log and a padded log all
  stop matching. A new `evidence/INDEX` lists every retained file by role, size
  and terminal record, bound from `QUALIFICATION` as `evidence_index_sha256`
  (`format=6`). Roles are declared in the Makefile and never inferred from
  filenames, so the index cannot be its own authority for what a member is, and
  the verifier checks it against that declaration in both directions. The index
  deliberately carries **no digest column**: `published_release_digests.txt`
  already records every published evidence file by digest, and a second record
  of the same fact would have no rule about which one wins.

- **The manifest's toolchain table is evidence now, not prose.** Fifteen rows
  of compiler, simulator and analyzer versions were printed into `MANIFEST.md`
  from shell captures, with no machine authority behind them and nothing
  checking them, so a wrong version there was a provenance error that passed
  every gate -- on the one table a reader consults to decide whether a released
  image was built with the toolchain it claims. The captures are now written
  once to `evidence/toolchain.txt`, that file's digest is bound from
  `QUALIFICATION` as `toolchain_sha256` (moving it to `format=5`, the same
  mechanism already used for the PIC12F675 matrix and the resource tables), and
  the table is *rendered from* the record instead of printed alongside it.
  `verify-release-qualification.sh` then holds the rendered table back to the
  record in both directions: every recorded tool must appear as a row, and the
  table may carry no row the record does not justify. The now-redundant
  `release_render_pic_toolchain_rows` renderer is deleted rather than left as a
  second producer of the same four rows.

- **A release signature now covers where the release came from, not just the
  firmware.** Through v0.9.11 `SHA256SUMS` listed the images and the required
  programming helper and nothing else, so `gpg --verify SHA256SUMS.asc
  SHA256SUMS` followed by `sha256sum -c SHA256SUMS` -- the two commands
  `release/README.md` gives a recipient -- authenticated the firmware and
  nothing about its origin: not the source commit, not whether qualification
  was production or express, not the soak duration, not the PIC12F675
  raw-write hazard text. `QUALIFICATION`, `MANIFEST.md` and `README.md` sat
  outside the signature and could be replaced with no verification failing.
  From v0.9.12 they are inside it, declared in one place as
  `RELEASE_PROVENANCE_FILES`, published as release assets so the checksum list
  and the published set stay the same set, and held by
  `verify-release-images.sh` as a third exactly-declared set beside the images
  and the helpers. `QUALIFICATION` moves to `format=4` to mark the new
  contract, and the two verifiers treat it differently because they see
  different inputs. `verify-release-qualification.sh` requires `format=4`: it
  only ever runs on a directory being staged or a tag being published, so a
  branch for an older format would be unreachable. `verify-release-images.sh`
  accepts all three published eras -- no `QUALIFICATION` at all
  (v0.9.0-v0.9.5), `format=1` (v0.9.6-v0.9.9) and `format=3`
  (v0.9.10-v0.9.11) -- because every PIC12F675 field programming runs it
  against a published directory through
  `scripts/verify-release-program-image.sh`, and those signatures cannot be
  reissued. A pre-`format=4` release is held to the old contract rather than
  merely tolerated: it must not list provenance in its checksum file either,
  so a half-adopted contract cannot leave a recipient unable to tell which era
  they are verifying. The per-release `README.md`, which no verifier had ever read, is
  now bound to `QUALIFICATION` for its version heading and its qualification
  banner in both directions, exactly as `MANIFEST.md` already was. Releases
  through v0.9.11 are left as published -- bringing their provenance inside
  their signatures would invalidate a published signature -- and are covered
  instead by `make test-published-release-immutability` and their signed tags.

- **Published releases are now held to what was published.** Every release
  directory ships `SHA256SUMS` over its images and programming helpers, so
  those stay verifiable by a recipient holding only that directory. That list
  covers 215 of the 576 published files; the other 361 -- the evidence logs,
  `QUALIFICATION`, the manifests and the detached signatures themselves -- are
  the account of what was actually run, are not rebuildable from source, and
  were covered by nothing. `make test-published-release-immutability`
  re-verifies each release's own list, holds the remainder to
  `test/published_release_digests.txt`, requires the two to partition each
  directory exactly so a newly added file cannot fall between them, rejects
  symbolic links because every content check reads through the path, and
  compares against the release tag wherever the clone has one. The record is an
  ordinary `sha256sum -c` file, so `sha256sum -c
  test/published_release_digests.txt` reproduces its central claim with
  coreutils alone. The safety errata added to `v0.9.0`-`v0.9.2` after the
  TMUX4053 polarity defect is registered as the one amendment ever made to a
  published release, with the check that it touched no file any verifier reads.
  No release content changed.

- **Folding a deliberate duplication no longer passes silently.** Several facts
  in this tree are decided twice on purpose, by routes able to disagree: the
  PIC10F320 shell is a second implementation compiled by a different compiler
  for a 256-word part, each part states its own pin ordinals and its own four
  watchdog terms, the AVR shells are interrupt-driven where the PIC shells are
  polled, the clock is stated by the build and re-derived by a firmware guard,
  the PIC harnesses keep their register facts literal, and the PIC return stack
  is bounded twice -- once over generated assembly, once over the shipped HEX.
  In each case the pair is the evidence, not either half. Merging one into a
  shared definition left every gate green, because the survivor still agreed
  with itself and there was nothing left to disagree with. `make test` now runs
  `test-deliberate-duplication`, a register in which each row names the
  independent opinion a merge destroys and asserts a structural witness that
  fails when it does, so the reason is read at the moment of the merge rather
  than found afterwards. It is lexical -- no compiler, no device pack -- because
  the loss it detects is a source edit, and it also holds every verification
  layer (BFS, two symbolic engines, CBMC, mutation, coverage, both instruction
  simulators, hardware qualification) to a subject and target of its own. The
  firmware is unchanged.

- **The compile-time guards in the AVR-XT and PIC shells are now proven to
  fire.** 52 of the firmware's 79 `static_assert` guards live in the four MCU
  shells that need a target toolchain, and nothing compiled a mutated input
  against any of them; the guard census did not count them either, so a deleted
  guard was equally invisible. These are the guards no shared proof can stand in
  for -- a pin assert resolves against the part's device pack, a clock assert
  against the `-D` only that part's build passes, a watchdog assert against that
  part's own de-rated floor, tick and ISR duty. `make test` now runs
  `test-attiny202-guard-mutations` (avr-gcc + ATtiny device pack) and
  `test-pic-guard-mutations` (XC8), each breaking one input to a guard in a
  throwaway copy of `src/` and requiring the build to fail with that guard's own
  message: wrong pin, wrong clock, wrong part selector, enum width, and every
  part's watchdog pet-to-pet budget pinned to its exact millisecond by a
  reject/accept pair. Both skip cleanly without their toolchain and fail closed
  under `STRICT_TOOLS=1`; the census is deliberately left outside them so it
  covers all 79 guards on a host with no XC8. Three configurations the firmware
  still accepts in silence -- two output selectors on one shell, a driver built
  under a foreign selector, and the PIC10F320's dual-scheme rejection that comes
  from undeclared identifiers rather than a guard -- are recorded as fixtures
  that fail when the guard closing them lands. The firmware is unchanged.

- **The single declaration of the release contract is now checked between
  releases, not only on release day.** `release/README.md`'s bounded block is
  the one place the version, part, image and soak counts are declared, and the
  validator that holds it to the build was reachable only through
  `scripts/make-release.sh`, which supplies both the version and the counts. In
  between, the declaration could name any version, any counts and any retained
  record with nothing to disagree. `make test` now runs the same validator
  against the working tree, taking the version from the declaration and the
  counts from the Makefile that builds the images, and additionally requires a
  tree that declares `vX.Y.Z` while `release/vX.Y.Z/QUALIFICATION` is absent to
  carry the exact pre-tag transition line. That disclosure was previously owed
  only by a block that happened to name the directory, so the pre-tag window --
  and an abandoned finalization commit left standing in it -- could pass
  unmentioned. `test-release-preflight`: 221 -> 230 checks.

- **A branch-only working document is now recognized by the declaration it
  carries rather than by its name.** The release documentation gate had been
  taught one name family at a time, each after a document the previous pattern
  could not see had already been written; the third such document was reported
  as durable-document-set drift instead, which failed the release preflight for
  a file the branch legitimately carries. A root-level Markdown file that
  declares itself a branch-only working document in its opening blockquote is
  now refused as one whatever it is named, and the live-tree documentation
  sweeps prune it on the same terms. The declaration never decides acceptance:
  every root-level document outside the durable set is still refused, so a
  working document that omits its banner fails closed as drift with the
  corrective action named, and a durable document that merely describes the
  convention has not declared itself.

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

- **An unexpectedly energized relay coil is now a fault, and recovery
  resynchronizes the relay.** Earlier `0.9.x` builds re-asserted both coils low
  at every serviced loop top and let the loop continue. That cleared the coil,
  but the stray pulse it permitted -- roughly one tick -- is only *below* the
  Panasonic TQ2-L2-5V 4 ms minimum for guaranteed actuation, which is not the
  same as proven mechanically harmless. The firmware therefore could not know
  whether the latching relay had moved, and if it had, the audio route was left
  permanently disagreeing with the effect state and the LED.

  The loop-top re-assert is gone. An energized coil is now caught by each
  shell's existing output-state integrity check and escalated:
  `hw_force_wdt_reset()` drives both coils to their de-energized idle *before*
  it spins, so no fault holds a coil energized for a watchdog period, and the
  recovery re-runs `init()`, whose complete 12 ms RESET-coil actuation restores
  agreement between logical state, LED and physical relay in the known BYPASS
  state. The price, accepted deliberately, is that a stray coil upset now costs
  an audible interruption and a return to BYPASS even when the pulse would not
  have moved the relay.

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

### Added
- **Release step 0 is now independently runnable and regression-tested.**
  `make release-preflight` runs every release capability check and executable
  version probe, then exits before `make clean`, any build goal, or staging.
  It needs no version and is deliberately usable from a dirty working branch;
  `VERSION=vX.Y.Z` is optional when the maintainer also wants local/remote tag
  and output-state warnings. `--preflight` and `--dry-run` are distinct and
  mutually exclusive: the former finishes in seconds and writes no release,
  while the latter rehearses the complete pipeline.

  New gate `test-release-preflight` supplies every selected release input from a
  synthetic toolchain while retaining the real base host utilities and real
  `print-<VAR>` interface. It proves section 0 reaches its final Python version
  probe, records 74 variable queries and zero clean/build invocations, leaves
  tracked/nonignored worktree content and the prospective output unchanged on
  every tested path, and covers the negative paths below rather than merely
  asserting the early exit exists.

  The audit that motivated the mode found several live precondition defects,
  all fixed with it. An absolute `YASIMAVR_VENV` is preserved through mutation,
  target tests and generated soak wrappers instead of becoming
  `<repo>/<absolute path>`;
  preflight checks the independently selected `PIC_SOAK_CXX` and
  `PIC10F320_SOAK_CXX` commands rather than literal `c++`; and a yasimavr
  interpreter must be executable before step 0 can pass. PATH-selected XC8
  commands and executable XC8 paths are both accepted, matching the build. The
  selected `objdump`, `readelf`, file-valued IHEX validator, AWK, analysis
  command, AVR symbol resolver, mutation Make and PIC10F320 host compiler;
  `timeout`, `tar` and `pkg-config`; both XC8/DFP analysis include pairs and
  device-geometry INIs; the complete simavr/gpsim header sets; and all four
  fetched ATtiny202 DFP files are checked before success. Required files must be
  regular and nonempty. Live probes additionally exercise avr-libc preprocessing,
  simavr/libelf and both gpsim C++ link paths, complete yasimavr target-module
  imports, PyYAML and the selected AWK. Selected repository-relative paths are
  normalized before preflight, builds and mutation consume them.

  Make no longer interpolates `VERSION` or `RELEASE_ARGS` into release recipe
  shell syntax. GNU Make exports those values and the release script validates or
  splits them without `eval`, so malformed values cannot execute before semantic
  version validation. Git status, local-tag, origin-configuration and remote-tag
  failures are distinguished from clean/absent state, and the preflight gate's
  fake Git rejects every modifying operation.

- **`DESIGN_DOCUMENTATION.adoc` traces its load-bearing decisions to vendor
  documentation.** A new **Datasheet References** section: each decision against
  its DS40001585 / ATtiny13A reference *and* against its in-tree implementation
  or evidence. The final column labels the evidence strength: configured values
  may be machine-gated, runtime-checked or read from a built artifact, while
  physical silicon properties are documented vendor inputs rather than claims
  of software enforcement.

  Eight rows, all from sources already confirmed in-tree rather than re-derived:
  WDT time base (**OS09**, LFINTOSC 31 kHz ±25%), WDT period tolerance (**param
  31**, −37%/+69%), WDT period (`WDTCON`, **Register 5-1**), oscillator
  (`OSCCON`, `IRCF` = `0b100` → 2 MHz), the 1 ms Timer2 tick, brown-out
  (`BORV`), quiescent current (**D017–D019**), and the ATtiny13A sleep wake-up
  ordering (**§7.3**).

  The AVR Classic and AVR-XT *electrical* parameters — BOD fuse levels, the
  ~16 ms post-reset watchdog window, `WDTON`, the internal-RC ±10% tolerance and
  the Timer0 CTC divisor — are **not** cited, because no citation for them exists
  anywhere in this repository and a guessed section number in a reference-grade
  document is worse than an absent one. Fuse selections and timing constants are
  machine-gated, but the resulting BOD voltages, watchdog window and oscillator
  tolerance remain vendor physical specifications. This distinction and the
  remaining citation work are recorded explicitly rather than presenting every
  row as build-enforced; the remainder is tracked in `TODO.md`.

  Settled while writing it: the two in-tree descriptions of the `IRCF` field
  disagreed on notation (`IRCF<2:0>` in `docs/phase2_pic_shell.md` §2,
  `IRCF<6:4>` in `src/bypass_mcu_pic10f322.c`). The DFP header is authoritative —
  `_OSCCON_IRCF_POSN` = 0x4, `_SIZE` = 3, `_MASK` = 0x70 — so it is a 3-bit field
  at register bits 6:4 and both spellings are correct in their own notation. The
  table records that rather than silently picking one.

- **`make test` now fails if the Makefile sets environment for a child process
  that no longer reads it.** Axis E of the name-contract family, and the only
  one of the five with a defect already behind it rather than a review: the
  PIC10F320 gpsim lanes simulated a PIC10F322 for an entire release because a
  shared wrapper's `PIC_GPSIM_PROC` read was re-spelled for one part while all
  four Makefile writers kept the old name. The assignment stayed legal, silent
  and inert, and the child fell back to its own default. 98 channels over 154
  write sites, every one verified to reach a reader; 44 checks total, 2.3 s.

  Checked per **link**, not per name — every `NAME=value <child>` site must
  reach a file that reads `NAME`. Per-name is measurably too weak:
  `ATTINY202_FUSE_WDTCFG` is written at five sites, and the one pointing at the
  fuse reader's own unit test (which names it literally) covers the four real
  consumers being severed at once. Verified — the per-name form passes that
  mutation, the per-link form fails it.

  The reader search is **transitive**, which is required rather than a
  refinement: a direct-read check reports two *correct* channels as severed,
  because `AWK` is written for a wrapper whose read lives in the gate it runs
  and `BYPASS_MODEL_FFI` for a Python driver whose read lives in a module it
  imports. A child inherits the environment, so the reader is anywhere
  downstream.

  Two shapes the obvious implementation misses, both live in this tree. A
  channel can hide behind a make variable — `$(XT_FUSE_ENV)` expands to seven
  `ATTINY202_FUSE_*` assignments that appear nowhere in the recipe text. And a
  reader can *build* the name rather than write it: `attiny202_fuses.py`
  computes `"ATTINY202_FUSE_" + name` over a table, so no literal spelling of
  any of the seven exists in the file that reads them. Both are resolved, and
  the computed reads are counted separately rather than blessed.

  Separating a channel from a shell local turned out to need a real recipe
  tokenizer, not a word split: `NAME=$(MAKEVAR)` — the shape of every channel
  here, including the severed one — reads as a command substitution to a naive
  splitter and vanishes from the harvest, while `rc=$$?` and `out=$$(…)` read as
  channels. The distinction is structural, not conventional: a prefix is an
  assignment *followed by a command*; a local is the whole statement. On this
  Makefile that rule alone separates them perfectly — 98 channels, none
  lowercase, and every lowercase name among the 40-odd locals it drops.

  A channel whose consumer cannot be resolved **fails** rather than being
  skipped, since a skipped check reporting as a pass is this gate's own defect
  class. The two genuine external consumers (`PYTHONPATH`, `PYTHONWARNINGS`,
  both read by CPython at startup) are listed with their reasons and expire like
  every other exemption. The reverse direction — a script reading a name nothing
  sets — is deliberately not bundled: a script legitimately reads names an
  operator sets by hand.

  Verified against seven mutations, including a re-creation of the original
  defect: renaming the sourced wrapper's read while leaving the Makefile writes
  reports `PIC_GPSIM_PROC` severed with the write line and the child named.

- **`make test` now fails if any `NAME=value` handed to make names a variable
  the Makefile does not know.** A make override naming no existing variable is
  legal and silent — the value is ignored and the default applies — which is how
  a renamed `SOAK_*` left one mutant asking for 2 s of simulated soak and
  getting the 24 h default for an entire release. New gate
  `test-makefile-name-contract` (`test/test_makefile_name_contract.py`), axis C
  of the four-axis name-contract item in `TODO.md`; 74 overrides verified.

  The Makefile gains an `origin-%` rule beside `print-%`, plus a bulk
  `make origins NAMES="…"` form that resolves a whole harvest in one invocation.
  `$(origin)` is the oracle because non-emptiness cannot work here:
  `XT_SOAK_COMBINATION_NAME` and `AVR_STACK_BUILD_DIR` are defined-but-empty by
  design. The contract is *defined **or** consumed*: `$(origin)` alone reports
  a command-line-only input such as `VERSION` as `undefined`, so the Makefile's
  own `make release VERSION=v1.0.0` usage line would otherwise read as severed.

  The gate is verified by reproducing the defect it exists to prevent: reverting
  the mutation row to its pre-rename spellings makes it name all four severed
  overrides and fail. That check matters because the specification this gate was
  built from would **not** have caught that defect — it called for harvesting
  "lines invoking make", and the row in question is a data row in a mutation
  table with no `make` token on it at all. The mutation tables are enumerated as
  their own source, and the gate asserts it found overrides there.

  Harvesting only what follows the make word — assignments *before* it are
  environment for make's children, not claims about the Makefile — cut the
  expected allowlist from seven-plus names to one (`MUTATION_ALLOW_SKIP`), and
  every exemption must still be reached by the harvest, so exemptions expire
  rather than accumulate.

  **Documents are in scope too**, which they were not when this axis was first
  built. The original harvest read `test/`, `scripts/`, `.github/` and the
  Makefile — where the *machine-facing* overrides live — and that scope left the
  human-facing half of the same defect unchecked by any of the four axes.
  `MISRA_COMPLIANCE.md` tells a maintainer to run `make analyze-misra
  VARIANTS="…" STRICT_TOOLS=1`; `README.md` documents `make attiny202-program
  VARIANT=<v>`. Axis D reads doc prose, but only for names inside the project's
  variable *prefixes*, and `VARIANTS`, `VARIANT`, `STRICT_TOOLS`, `VERSION` and
  `PIC10F322_PROG` are all unprefixed — so nine names in six live documents were
  reachable by no axis at all. Anchoring on the make word, which this axis
  already did, is what let the scope widen without needing a vocabulary list to
  keep the false-positive rate survivable: two lines needed an exemption marker,
  both of them in `TODO.md`'s specification of this very item. The gate now
  fails if it stops finding overrides in documents, for the same reason it fails
  if it stops finding them in the mutation tables.

  This is the fifth widening, and — like the four before it — it was found by
  looking rather than by a gate, in the place the *previous* scope did not
  reach.

- **The same gate now also fails if any `make print-<VAR>` query asks for a
  variable the Makefile does not define.** `print-%` is a pattern rule, so it
  matches *any* name: ask it for a variable that no longer exists and it prints
  an empty line and exits 0. The `v0.9.8` rename left three such reads in
  `scripts/make-release.sh` pointed at removed names, and nothing failed — the
  effect would have surfaced only in the published artifact, at the end of a
  24-hour release run, as a `MANIFEST.md` with empty ATtiny13a and tinyx5 fuse
  bytes and one image path composed as `bypass--<stage>.hex`. Axis A of the
  same four-axis item; 65 queries verified.

  Both spellings are harvested — direct `print-<VAR>`, and the `mkv` wrapper in
  `scripts/make-release.sh`, which passes the name as a bare word — and it
  fails if either stops producing hits, because the historical defect was in
  the wrapper form only. Computed names (`mkv part_"$n"`) are expanded over the Makefile
  variable supplying their keys and checked; a computed name the gate cannot
  expand is a failure rather than a skip.

  A read is held to a **stricter** contract than an override: it must be
  *defined*, not merely defined-or-consumed. A command-line-only input such as
  `VERSION` is legitimate to set but useless to ask for, since the query returns
  an empty line.

  Historical documents are exempt by **self-declaration** rather than by a
  hardcoded list: nine markdown files already open with a banner calling
  themselves historical records, and that banner is what the gate keys on — so a
  new historical document is exempt the day it is written, and deleting the
  banner puts the document back under the contract. Only `CHANGELOG.md` is
  exempt by name, because naming a variable that no longer exists is a changelog
  working correctly. Verified by restoring the `v0.9.7` spellings in
  `scripts/make-release.sh`: the gate names all five severed reads with their
  line numbers and fails.

- **The same gate now also fails if any documented `make <goal>` names a goal
  that does not exist, or if any prose or diagnostic names a variable that does
  not.** Axes B and D, closing the four-axis name-contract item. 36 checks in
  total, 0.6 s: 66 variable queries, 356 documented commands, 74 overrides and
  68 variable mentions. Each new axis found a live defect on its first clean
  run — `.gitignore` named `make pic-test-soak`, a goal the `v0.9.8` rename
  removed, in the comment explaining which goal produces the file it ignores;
  and a `Makefile` comment described the PIC soak's knobs as a family no
  variable belongs to.

  Axis B is the only one of the four whose failure is loud — `No rule to make
  target` — which is exactly why it has to be caught before a reader is the one
  who finds it. The `v0.9.8` rename left 15 dead goals in
  `docs/pic10f320_validation.md` alone, a document framed as *current*
  qualification evidence, including its entire "Reproducing any of this"
  section, where four of six commands failed.

  Goals resolve against `make -rRn --print-data-base`, parsed once. Reading
  make's own inventory rather than grepping rule heads is what makes the
  generated families resolvable at all: `attiny85-program` and
  `test-sim-cd4053_simple-attiny13a` exist only after `$(eval $(call ...))`
  expansion. Goal *schemas* are expanded rather than skipped — `make
  test-sim-<variant>` is resolved over `$(VARIANTS)` and every expansion must
  exist, which is the check that catches the sharpest `v0.9.8` casualty, a
  documented goal identified by the *omission* of its MCU field.

  Precision was the whole problem on axis B and is worth recording: English
  follows the word "make" constantly, so a harvest reading every line containing
  it reported **881** distinct tokens ("sure", "the", "a") against about a dozen
  real ones. Three rules take that to zero — read only command contexts, require
  the make word to *open* its fragment (`apt-get install -y make util-linux`
  installs a package), and take only the first goal word.

  Axis D reads prose only, never executable lines: this tree has over 150 shell
  locals, C macros and CI keys sharing the project's variable prefixes, so a
  prefix alone cannot identify a Makefile variable. Family references are
  checked as prefixes — `PIC320_*` asks whether any known variable begins with
  `PIC320_` — because testing the stem as a name reports correct references like
  `AVR_SOAK_*` as severed.

  Live documents legitimately name retired names: redirect tables, recipes
  pinned to an older tag, quoted transcripts, and sentences whose point is that
  a name is gone. Those carry a per-line or per-block `name-contract: exempt`
  marker with a reason; published release artifacts under `release/v*/` are
  exempt by path, since they are immutable records nobody should edit. Every one
  of the 21 markers must still suppress something or the gate fails, so
  exemptions expire rather than accumulate.

- **Every static-analysis target now rejects an unrecognised `VARIANTS=`
  instead of quietly analyzing less.** `analyze-tidy`, `analyze-cppcheck`,
  `analyze-deep`, `analyze-misra` and `analyze-misra-report` all analyze
  `$(FW_SOURCES)`, which maps `$(VARIANTS)` through `src_<variant>` — and an
  unrecognised name maps to *nothing*. A typo therefore did not fail: it shrank
  the subject and the analyzer honestly reported the smaller set clean. All five
  now carry `classic-variant-request-valid`, the same guard the build targets
  (`attiny13a`, `attiny85`, …) already had. Recognised **subsets** remain valid —
  analyzing one driver is a normal development request.

  This is the class behind the `MISRA_COMPLIANCE.md` defect under *Fixed*
  below, where the documented compliance command analyzed zero of the three
  output drivers and exited 0. Fixing the document removed the instance; the
  guard removes the class, which matters most for exactly these targets: an
  analyzer is believed, so an analyzer reporting on a set nobody chose is worse
  than one that does not run.

  New gate `test-analyze-variant-guard`
  (`test/test_analyze_variant_guard.sh`, in `make test`), 19 checks in 0.3 s,
  built in two halves because either alone leaves the hole open. The
  behavioural half proves all five reject the empty, unknown and duplicate
  requests, and reject *before* analyzing — a partial analysis that stops early
  still prints findings a reader could mistake for a verdict. The contract half
  walks the Makefile's rules and requires the guard on **every** target that
  consumes `$(FW_SOURCES)`, including ones added later; a guard that needs a
  human to remember to extend it has the same failure mode as the thing it
  guards.

  One subtlety the gate had to be built around, since it is what made the first
  version of it measure nothing: the serialization wrapper re-execs make under
  `flock` and hands the inner invocation its request's verdict through the
  *environment*, because it also sanitises `VARIANTS` on the way down. Correct
  for its own recursion — by then the bad names are gone and only the inherited
  flags still remember they were typed — but wrong for an independent nested
  make started by a test, which inherits `make test`'s verdict ("clean") and
  applies it to a request make never saw. Left set, every rejection became an
  acceptance. The gate clears those flags by *harvesting* their names from the
  Makefile, pins the lock-held condition so a standalone run and a `make test`
  run exercise the same thing, and carries a control proving the clearing is
  load-bearing rather than decorative.

  Verified by reproducing the original defect: with the guard removed,
  `make analyze-misra VARIANTS="cd4053 mute relay"` checks 2 files, reports
  `MISRA-C:2012: clean` and exits 0. With it, nothing is analyzed and it exits
  2.

- **Every lane that selects *one* output stage now rejects an unrecognised
  selector instead of skipping.** `VARIANTS` is a list and has been guarded for
  releases. The sixteen variables that pick a single stage or chip for a single
  lane — `PIC10F322_SOAK_VARIANT`, `PIC10F320_IO_VARIANT`, `AVR_SOAK_VARIANT`,
  `AVR_SOAK_CHIP`, `VARIANT` and the rest — had no guard at all, and an
  unrecognised value there composes a path to a file nothing builds, which the
  lane reports as a *missing toolchain*:

  ```
  $ make pic10f322-test-soak PIC10F322_SOAK_VARIANT=relay
  no build_pic10f322/bypass-pic10f322-relay.hex (XC8 absent?); skipping ...
  $ echo $?
  0
  ```

  XC8 was installed; the request was a typo carrying the pre-`v0.9.8` stage
  vocabulary. `STRICT_TOOLS=1` (CI, release) turns that skip into a failure with
  the same wrong diagnosis, so it moved the cost rather than removing it. Same
  class as the analyzers above — and the same shape as the PIC10F322 soak driver
  under *Fixed*, which "degraded to a skip, not a failure" for a whole release.
  A skip is the dangerous outcome precisely because it is indistinguishable from
  an honest one.

  New `variant-selectors-valid` guard, wired as the **first** prerequisite of
  all 30 consuming rules (order-only for the one file target, so a phony
  prerequisite cannot make it look perpetually out of date). It validates every
  selector on every invocation, not just the one the requested goal reads: an
  override naming a value no lane supports is inert wherever it lands, and inert
  overrides are the defect class. `XT_SIM_VARIANT` stays out of the table —
  empty means "every supported variant" there, so it is list-or-empty and
  already validates itself in each of its four recipes.

  New gate `test-variant-selector-guard`
  (`test/test_variant_selector_guard.py`, in `make test`), 14 checks in 1.5 s,
  in the same two halves as its analyzer sibling: the behavioural half proves
  all three malformed shapes are rejected (unknown, empty, more-than-one) and
  that the real lane above now fails naming the selector and never prints the
  skip; the contract half proves the guard is still attached to every rule that
  consumes a selector.

  The contract half needs a **transitive closure**, and that is the whole
  difficulty: almost no rule mentions a selector directly. `pic10f322-test-soak`
  reads `$(PIC10F322_SOAK_HEX)`, composed from the selector three definitions
  away. A harvest keyed on the selector names alone finds 17 of the 31 rules
  that actually depend on one — and the fourteen it misses include every
  PIC10F320 lane. It also has to join backslash continuations before parsing
  rule heads, which the first draft did not: `test-soak-reset-witness` carries
  its prerequisites on a continued line and was classified as consuming no
  selector at all, the same physical-line mistake axis C of the name contract
  made.

  It found a live one on its first clean run:
  `test/test_target_lane_markers.sh` defaulted `LM_VARIANT` to `mute`, a
  pre-`v0.9.8` stage token passed to the *real* make, inert only because nothing
  had ever checked it.

  Adding a second guard to `analyze-misra` also broke the analyzer gate's
  negative fixture, which pinned the guard to the *first* prerequisite position
  by exact text — it reported the spelling change as a missing guard, correctly
  and unhelpfully. That fixture is now position-independent, so the next guard
  added to that rule does not fail it.

- **The firmware's compile-time guards are now proven to actually fire.** Every
  build checks the `static_assert`s in the config headers and MCU shells, but
  only in the sense that they stay silent — and a guard still enforcing its
  invariant is indistinguishable from one that has been defused, because both
  are silent and both build green. Reorder a header so the constants arrive
  after the check, drop an `#include`, weaken `>` to `>=`, comment one out
  during a debugging session: nothing notices. New gate
  `test-static-assert-guards` (`test/test_static_assert_guards.sh`, in `make
  test`), 33 checks — 24 guards counted, 9 mutations proven to trip one, plus
  three modular-shell include omissions each proven to change its fixture and
  identify the exact missing shell. The firmware itself is never modified;
  mutations are applied to a throwaway copy of `src/`.

  The guards' **inputs** are broken, never the guards: a mutation editing a
  `static_assert` line would prove only that the compiler implements
  `static_assert`. Breaking a threshold, a pin ordinal, the Timer0 constant or a
  build flag is what a real regression looks like. One mutation is not a source
  edit at all — dropping `-fshort-enums` is how the enum-width guards actually
  get defeated, and no edit to `src/` can express it.

  Mutations alone cannot catch a **deleted** guard, and the first version of
  this gate demonstrated that by missing one: guards come in families sharing a
  diagnostic (three enum-size asserts all say `use -fshort-enums`, seven pin
  asserts all fail the same build), so deleting one leaves a sibling to trip the
  mutation. A per-file guard census closes it — a deletion fails, and so does an
  addition, which forces a decision about whether the new guard needs a
  mutation.

  Three preconditions are checked rather than assumed, since without them the
  whole exercise measures nothing: the unmutated tree must compile, each
  mutation must actually change its file (`TIMER0_OCR0A_1MS` is defined with
  leading whitespace inside an `#if`, and the first draft's pattern silently
  matched nothing), and the failure must carry the guard's own message.

- **A mechanically stuck footswitch is now an enforced guarantee rather than a
  documented intention.** `DESIGN_DOCUMENTATION.adoc` states under Caveats and
  Limitations that "by design, no recovery is currently provided for a
  mechanically stuck switch" — a promise in both directions, since it also means
  no spontaneous *second* toggle while the fault persists. Only the first half
  was ever framed as intentional, and the second half is the one a player would
  notice. `test_stuck_switch_no_recovery()` drives the input low for six
  simulated hours in each of the two ways a switch sticks closed — after a
  normal press (one toggle, parked `ENGAGED`) and already stuck at power-on (no
  toggle at all, parked `BYPASS`) — then asserts recovery once the fault clears.

  Recorded because the obvious reading is wrong: the duration is *not* where the
  strength comes from. The model is finite-state with a counter bounded at
  `RELEASE_THRESH`, so a held-low input reaches its fixed point within
  `RELEASE_THRESH` ticks. Deleting the integrator's saturation — the counter
  wrap this looks like it exists to catch — is already caught by sixteen other
  assertions in the file. What is new is the shape: the power-on-stuck case is
  driven over time at all (`test_power_on_pressed` checked the instant after
  `init()` and nothing after), invariants are checked every tick rather than at
  the end, the counter is pinned to its saturated value, and recovery is
  asserted so "no recovery" cannot decay into "left corrupt". The six hours cost
  0.2 s and buy a standing guard against a future unbounded accumulator, the one
  defect class a long run sees and a short one cannot.

  Subject is the golden model — the *oracle*, not the firmware. The shipping
  integrator is covered more strongly than any run can manage: `test_cbmc.c`
  (C1) proves `debounce_integrate()` saturates for every admitted input. The gap
  was that the simavr tests judge the firmware by comparing it against this
  model, so a model that drifted would make a firmware that drifted look right.

- **The fuse checker can no longer pass without reading the Makefile.**
  `test/avr/test_fuses.c` decodes the exact fuse bytes this Makefile burns and
  is the only thing standing between a fat-fingered fuse edit and a bench
  session. It declared itself the single source of truth for those bytes and
  then defined `#ifndef` fallbacks for all eleven — **ten of them exactly the
  current values**. Compiling with the real `-D` set minus `-DT85_LFUSE`, which
  is what renaming a macro on either side produces, printed `fuse checks: 46
  checks, 0 failures` and exited 0. Only `T13_LFUSE` failed, and only because
  its fallback had gone stale (`0x6a` against a current `0x4a`); nothing
  designed that.

  `-D<MACRO>=$(VAR)` is a name contract the four axes above deliberately do not
  cover — the C macro names are the tests' own interface and were not renamed
  with the Make variables in this release — so nothing joined its two halves.
  The eleven fallbacks are now `#error`s, each naming the Makefile variable its
  byte comes from, which is the fail-closed rule the ATtiny202 half of the same
  gate already followed (`attiny202_fuses.py` raises rather than defaulting on a
  missing `ATTINY202_FUSE_*`).

  New gate `test-fuse-injection-contract`
  (`test/test_fuse_injection_contract.py`, 18 checks) follows each byte the
  whole way: the variables the avrdude recipes burn to silicon must be exactly
  the variables the checker is compiled with; the compile line and the C file
  must name the same macros, with each `#error` naming the variable the Makefile
  really pairs it with and no macro carrying a default; every injected byte must
  reach the program's output, one for one; and each printed byte must equal
  `make -s print-<VAR>`.

  Two of those links exist for reasons worth recording. *Burned == injected*
  because proving the checker reads the Makefile is not the same as proving it
  reads the byte anyone flashes — a checker verifying a byte no flash target
  burns is decoration and looks identical from the inside. *Printed == the
  Makefile's value* because it is the only link that catches a value drift as
  well as a name one, and it is not redundant with the checker's own assertions:
  `T13_LFUSE` bit 6 is EESAVE, which no assertion in the file reads, so an lfuse
  that disagrees with the Makefile in that bit alone passes all 46 checks. The
  gate builds exactly that binary and requires the round trip to catch it.

- **The release's image-change claim is checked exactly, and the check is
  retained.** The filename migration itself preserves all image bytes, while the
  later PIC10F320 relay safety correction intentionally changes one image. The
  release contract is therefore exact: seventeen renamed images must remain
  bit-identical to `v0.9.7`, and the one published relay exception must differ.
  Every other claim under `release/` is backed by a retained artifact; this one
  now is too.

  `scripts/verify-rename-identity.sh` first verifies that the pinned release key
  signed the exact `release/v0.9.7/SHA256SUMS` bytes, then hashes every image this
  release builds against the entry for its old name through the published
  old-to-new table and exact intentional-change declaration in
  `release/README.md`, and emits the per-image table as the evidence document.
  Missing, empty, symlinked, malformed, wrong-key, or stale signatures all fail
  before any baseline hash is parsed.
  `scripts/make-release.sh` runs it in step 1 — before the 24-hour soak, so a
  changed byte costs seconds rather than a day — and stages the result as
  `release/v0.9.8/RENAME_IDENTITY.md`. The required final result is **17
  identical, 1 intentional change, 0 unexpected differences, 0 missing, 0
  added**. An unchanged declared exception, a second changed image, or a wrong
  exception name all fail.

  Tag CI does not trust that retained report on sight. After rebuilding all
  release images from the tagged source, it regenerates the report from those
  exact clean-build paths and requires a byte-for-byte match with the committed
  `RENAME_IDENTITY.md`. Missing, empty, non-regular, stale or altered evidence
  fails publication; once the rename table no longer applies, the same check
  requires no report and rejects a stale one.

  The verifier retains its exact regenerated bytes directly in the frozen
  publication directory and reports their SHA-256 through the workflow's step
  outputs. Immediately before `gh release create`, CI rechecks that digest and
  conditionally adds `RENAME_IDENTITY.md` to the asset array. Later releases
  route an explicit inapplicable state and continue to publish without it.

  Three decisions are what keep this from becoming a liability later. It is
  **not a standing gate**: pinning current images to a *previous* release's
  hashes and one published exception is correct for exactly this release, and
  turns into a false alarm on the next one (the standing form of the check is
  per-release and already exists). It **holds no version of its own**,
  reading both from the rename table's own header, so it reports "not
  applicable" and does nothing for any other release and needs no maintenance to
  retire. And it **restates no part of the mapping**, parsing the table users
  actually follow, so the rows that were verified cannot drift from the rows a
  reader is given.

  It is also deliberately not retained under `evidence/`, whose contents are
  pinned exactly by `RELEASE_EVIDENCE_FILES` for *every* release: a file only
  one release produces would fail the next release's qualification verifier.

- **Three more places still spelled a name this release moved.** The published
  `MANIFEST.md` took the ATtiny85/45 programmer name from a literal (`t85` /
  `t45`) while `make-release.sh` read `part_85` / `part_45` from the Makefile
  into an array nobody used — the `mkv` preamble validating a value it then
  discarded. The array is now wired into the manifest arm, indexed by the part
  number the arm already computes.

  `test/run_mutation_tests.sh` composed the PIC10F322 image path from three
  restated defaults (`FW_BASE`, `PIC10F322_TAG`, `PIC10F322_BUILD_DIR`); it now
  resolves the path once from `PIC10F322_BUILD_DIR` +
  `PIC10F322_RELEASE_IMAGES`, so an output stage that no longer exists fails at
  startup by name rather than as a missing file per mutant — which is the
  dangerous shape, since a missing image makes each PIC mutant return the
  infrastructure-error status and the lane degrade to a skip.

  And `make clean` now removes a pre-rename `build_pic/`, which `.gitignore` no
  longer covered either: XC8's `.p1`/`.d`/`.sdb`/`.sym`/`.cmf` intermediates
  match none of its global patterns, so a worktree upgraded from `v0.9.7` would
  offer them to `git add -A` forever.

### Changed
- **The ATtiny202 output tracer now watches pin edges the way yasimavr's author
  recommends, and asserts the delivered coil-pulse width.** It used to advance
  the simulation one cycle at a time and re-read `pin.state()`. Asked directly,
  upstream recommended a `CallableSignalHook` connected to `pin.signal()`,
  filtered by signal id, while the simulation free-runs — so the tracer now does
  that (`sim_attiny202.PinEdgeRecorder`), filtering `StateChange` rather than
  `DigitalChange` because only the former keeps a floating pin distinguishable
  from one driven low, and only the former fires when the shell first takes a
  floating control pin low.

  Three consequences. Every transition now carries its exact cycle, so
  `attiny202-sim` asserts the pulse *width* it delivers and not only its
  structure: the relay coil measures 12.014–12.669 ms and the mute window
  5.28 ms against a band of the design width less the delay oracle's compile
  rounding, plus 10% for tick-ISR preemption. The compiled design width stays
  owned by `attiny202-delay-oracle`, which reads it from the image independently
  of any simulator; what the trace adds is the ~5.5% the tick ISR stretches a
  busy loop by, which a compile-time count cannot show. Second, the upstream
  `SimLoop.run()` cycle-rewind defect no longer reaches any measurement this
  project makes — that defect is what made a 12 ms pulse trace as ~6 ms, and it
  only ever applied to single-cycle stepping. Third, the traced segments run
  about 5× faster.

  Edges that share a cycle are folded before the combined PA2/PA3 state is
  judged, so one instruction changing both pins cannot fabricate an intermediate
  state — for the relay that would have been a spurious both-coils-high report.
  The stall check moved from a cycle delta, which `SimLoop.run()` pins to the
  full budget even when the device halts early, to the device reaching its
  terminal state, which is the condition that actually means it stopped.
  `test_attiny202_output_oracle.py` gained host-side cases for the folding rule
  and for width faults at both the checker and the orchestration level.
- **A `-D` macro a test harness must be told is now a build error when it is not
  told, instead of a plausible default.** The C-side twin of the name-contract
  axes: the Makefile injects 56 macros, 26 of which had `#ifndef` fallbacks that
  a severed injection would reach silently. Every such fallback was a correct
  value for *some* combination, which is exactly what made them dangerous —
  `test/avr/test_soak.c` would have answered a severed `-DSOAK_DURATION_MS` with
  24 h, the same 43,200× overrun this release already fixed on the make side,
  and a severed `-DFW_PATH` with a real ELF that is simply not the one the run
  reported soaking.

  Now 15, each in a category with a stated reason. Hardened to `#error`, every
  one naming the Makefile variable its value comes from: `FW_PATH` (6 sites),
  `F_CPU_HZ` (4), `MCU_NAME` (2), `PROC_NAME` in the shared PIC soak,
  `PIC_DEVICE_NAME`, and all four soak knobs. The `PIC_*_DEFAULT_FW_PATH`
  adapter macros went with them — an image path is an output-stage fact the
  Makefile selects, not a part fact the adapter owns, and defaulting it looked
  like the second only because it sat next to `PROC_NAME`, which genuinely is.

  **Two more instances of the shared-source shape** that produced the
  `PIC_GPSIM_PROC` defect above turned up here and are the reason this landed in
  the same release: `test_soak_pic.cc` is compiled for BOTH PIC parts and
  defaulted `PROC_NAME` to `p10f322`, so a severed injection would have soaked a
  PIC10F320 image on a p10f322 model for 24 hours; `test_config_pic.c` serves
  both lanes and defaulted its device label to `PIC10F322`. The per-part
  harnesses keep their adapter default for `PROC_NAME` precisely because they
  have one adapter per part — one source with two callers must have no fallback,
  one source per part may.

  **`test_sim.c`'s ATtiny13a lane was the last place a part was identified by
  the omission of a field.** The tinyx5 rules injected `MCU_NAME` and
  `F_CPU_HZ`; the ATtiny13a rules injected neither and let the file's own
  defaults answer — and that `MCU_NAME` default was `attiny13`, a spelling the
  rest of the tree retired, which simavr happens to accept. Both ATtiny13a rules
  now pass `ATTINY13A_MCU` and `ATTINY13A_F_CPU`; check counts are unchanged.

  **Two groups deliberately keep their fallbacks, and now say why.** The 13
  `SIM_*` / `MODEL_FUZZ_*` workload knobs are load-bearing: `FULL_SIM_DEFS` and
  `FULL_HOST_DEFS` are empty, so `make test-long` reaches the exhaustive
  workload by *not* overriding them, and an `#error` would have failed the
  release gate. And `PB0`/`PB1`/`PB2`/`F_CPU` turned out not to be severable
  injections at all — `CBMC_DEFS` is their only injector, so the hazard is the
  reverse one: the pin map exists in two or three copies and nothing compared
  them, which would let cbmc go on proving the firmware against a map the shim
  no longer holds and report it as a pass. Closed in C rather than with a new
  gate — the canonical value is named once and `_Static_assert`ed against
  whatever was injected. Verified by drifting `CBMC_DEFS` `PB1` from 1 to 3:
  `test-cbmc` fails by name.

- **Every released firmware image is renamed to one consistent scheme.** All
  eighteen images on all six MCUs are now
  `bypass-<mcu>-<output stage>.hex` — three hyphen-separated fields, with
  underscores between words inside a field:

  ```
  bypass-attiny85-cd4053_with_mute.hex
  bypass-pic10f320-tq2_l2_5v_relay.hex
  ```

  `<mcu>` is one of `attiny13a`, `attiny45`, `attiny85`, `attiny202`,
  `pic10f320`, `pic10f322`; `<output stage>` is one of `cd4053_simple`,
  `cd4053_with_mute`, `tq2_l2_5v_relay`, matching the driver source basenames.
  The mixed delimiter is deliberate: stage tokens are multi-word, so an
  all-hyphen name could not be split back into fields without hardcoding the
  MCU vocabulary.

  This replaces three coexisting conventions — the `bypass_` vs `bypass_mcu_`
  prefix split, the `cd4053`/`mute`/`relay` vs
  `cd4053-simple`/`cd4053-mute`/`tq2-relay` stage-token split, and a part suffix
  that was `_t45`/`_t85`/`_attiny202`/`_pic10f322`/`_pic10f320` **or absent**.
  That last case is what motivated the change: a bare `bypass_cd4053.hex` *was*
  the ATtiny13a image, identified by omission, and nothing in the filename
  stopped a builder flashing the 1.2 MHz ATtiny13a build onto an ATtiny85. The
  MCU field is now mandatory on every image, so the 6 × 3 product matrix is
  visible in a plain directory listing.

  **The filename change itself does not change image contents.** The later
  PIC10F320 relay idle-latch correction intentionally changes that one image;
  the other seventeen remain bit-identical to `v0.9.7`. `release/README.md`
  carries the full old→new mapping and the exact exception.

  Historical `release/vX.Y.Z/` directories are **not** renamed. Their
  `SHA256SUMS` names the files and is covered by a detached signature, so
  renaming them would invalidate published signatures.

  An existing source worktree is different: current build targets create the
  new names but do not remove differently named images from an older build.
  Builders upgrading a checkout that built `v0.9.7` or earlier are therefore
  told, in both Quickstart and the published rename section, to run `make clean`
  once before the first new build. `test-clean-contract` pins the exact four
  current default build directories plus retired `build_pic/` that cleanup
  removes; the guidance also maps paths supplied through renamed PIC
  build-directory variables onto their current cleanup variables.

  Internals: the spelling is composed in exactly one place, the Makefile's
  `$(call fw_image,<variant>,<mcu-tag>)`, backed by an `IMAGE_STAGE_*` map with
  a parse-time completeness check over both supported variant sets — a supported
  variant with no mapping is now a Makefile error rather than a release image
  that goes missing after a 24-hour soak. `PIC320_FW_BASE` (`bypass_mcu`) is
  retired; that lane shares the one `FW_BASE` and is told apart by its MCU
  field. `scripts/make-release.sh` keeps its own independent restatement of the
  scheme on purpose, because it is cross-checked against the Makefile's
  `RELEASE_IMAGES` and a derived copy could not disagree.

  The `MANIFEST.md` generator's per-image dispatch was order-dependent and ended
  in a bare `*.hex` ATtiny13a fallback, so an unrecognized name produced a row
  confidently labelling foreign firmware as an ATtiny13a with AVR fuse bytes. It
  now matches on the mandatory MCU field, making the arms mutually exclusive,
  and an unrecognized image is a hard error.

- **One output-stage vocabulary everywhere, replacing three.** The variant
  names themselves are now `cd4053_simple`, `cd4053_with_mute` and
  `tq2_l2_5v_relay` — the same strings the driver sources and the published
  image field use. Two internal vocabularies are retired: the classic-AVR and
  AVR-XT lanes' `cd4053`/`mute`/`relay`, and the PIC10F320 lane's inherited
  `cd4053-simple`/`cd4053-mute`/`tq2-relay`, which named the same three output
  stages in different words.

  This is a **breaking change to command lines and make goals**:

  | before | after (see also the prefix change below) |
  |---|---|
  | `make VARIANT=relay program` | `make VARIANT=tq2_l2_5v_relay attiny13a-program` |
  | `make PIC320_VARIANT=cd4053-mute pic320` | `make PIC10F320_VARIANT=cd4053_with_mute pic10f320` |
  | `make test-sim-mute` | `make test-sim-cd4053_with_mute-attiny13a` |
  | `SOAK_VARIANT=relay` | `AVR_SOAK_VARIANT=tq2_l2_5v_relay` |

  Release soak combination names change with it, and so therefore do the
  retained evidence filenames: `evidence/soak-avr_cd4053_t85.log` becomes
  `evidence/soak-attiny85_cd4053_simple.log`, `soak-pic320_tq2-relay.log`
  becomes `soak-pic10f320_tq2_l2_5v_relay.log`, and so on for all fifteen.
  Evidence already committed under `release/v0.9.7/` and earlier is untouched.

  The longer tokens cost more typing, once per command line. What they buy is
  that a variant name cannot be valid in one lane and meaningless in another,
  which is what `cd4053-mute` versus `mute` was.

  The `IMAGE_STAGE_*` map added earlier in this release is **deleted**: with
  the vocabularies unified it was the identity function. So are its two
  downstream copies — `stage_of()` in `scripts/make-release.sh` and `pb_image()`
  in `test/test_pic_build.sh` — and the stage-to-variant table in the ATtiny202
  delay oracle. A translation table is a place where two names can disagree;
  removing the need for one is a stronger guarantee than maintaining it
  correctly. What replaces it as the parse-time guard is a completeness check
  that every supported variant, in every lane, has a `macro_<v>` selector and a
  `src_<v>` driver. That check deliberately does *not* require the three lanes'
  supported sets to be equal — a future output stage that fits the ATtiny13a but
  not the 11-free-words PIC10F320 is a legitimate divergence.

  This vocabulary-only step changes no image byte. The later relay safety fix is
  the release's sole intentional image difference from `v0.9.7`.

- **Every make goal that acts on one part is named after that part.** The goal
  vocabulary now matches the image field exactly: `attiny13a`, `attiny45`,
  `attiny85`, `attiny202`, `pic10f322`, `pic10f320`.

  | before | after |
  |---|---|
  | `make all13` / `all85` / `all45` | `make attiny13a` / `attiny85` / `attiny45` |
  | `make size` / `size85` | `make attiny13a-size` / `attiny85-size` |
  | `make fuses` / `flash` / `program` | `make attiny13a-fuses` / `-flash` / `-program` |
  | `make readfuses` / `trace` | `make attiny13a-readfuses` / `-trace` |
  | `make program85` | `make attiny85-program` |
  | `make pic` / `pic-test` | `make pic10f322` / `pic10f322-test` |
  | `make pic-analyze` | `make pic10f322-analyze` |
  | `make program-pic` | `make pic10f322-program` |
  | `make pic320-*` | `make pic10f320-*` |
  | `make test-sim` / `test-sim-t85` | `make test-sim-attiny13a` / `test-sim-attiny85` |
  | `make test-sim-secondary` | `make test-sim-tinyx5` |

  Two defects motivated this, and they are the same defect at different ages.
  `pic-` meant PIC10F322 only because that part arrived first, so `pic-test-soak`
  and `pic320-test-soak` sat one near-name apart with nothing in either name
  saying which silicon it drove — the residual risk the PIC10F320 merge recorded
  and deferred (`docs/pic10f320_merge_plan.md` §15, D1). The classic AVR lane had
  the same shape one layer down: `flash`, `size` and `test-sim` were the
  ATtiny13a because it got there first, while every other part carried a name.

  A `pic-*` goal now means **both** PIC parts, which is what `test-pic-build`,
  `test-lockstep-progress` and `test-stack-bound-pic-regression` already did;
  they keep their names and are now accurate rather than ambiguous.
  `attiny202-*` was already part-named and did not move, and the `test-<mcu>-*`
  goals keep their word order: `attiny202-delay-oracle` runs the oracle against
  firmware while `test-attiny202-delay-oracle` runs the oracle's own selftest,
  a distinction the ordering carries.

  **`make all` now builds every part**, not just the ATtiny13a. A lane whose
  cross-toolchain is absent (XC8 for either PIC, the ATtiny_DFP for the
  ATtiny202) prints a named skip and does not fail, so a bare `make` still works
  on an AVR-only machine; `STRICT_TOOLS=1` turns each of those skips into an
  error, which is what release and CI use. Because the PIC lanes require the
  complete output-stage matrix, `make all VARIANTS=<subset>` is now rejected up
  front with the single-part command to use instead, rather than failing forty
  lines into the PIC lane's own matrix check.

  Release evidence filenames follow the goals: `build-avr.log` and
  `build-pic.log` become `build-avr-classic.log` and `build-pic10f322.log`,
  `pic-test.log` becomes `pic10f322-test.log`, and the fifteen soak combination
  names become one `<mcu>_<output stage>` pair each — `attiny85_cd4053_simple`
  rather than `avr_cd4053_simple_t85`, which had spelled the chip at both ends.

- **Chip-scoped Makefile variables carry their chip's name.** `PIC_*` names that
  held a PIC10F322 fact are now `PIC10F322_*`, and `PIC320_*` is `PIC10F320_*`.
  The cautionary case is the one the deferred TODO item named: `PIC_FLASH_WORDS`
  was 512, a 322 fact under a family name, and a variable mis-scoped that way
  produces no compile error and no failing test — it produces a *passing* one,
  because a 256-word image gated at 512 words passes.

  The rule is now stated in the Makefile and is two-tier rather than uniform: a
  `PIC_*` name with no part in it means **shared by both PIC parts**, and there
  are exactly nine of them plus four wrapper-script env parameters — one XC8
  (`PIC_CC`, `PIC_DFP`, `PIC_XC8_INCLUDE`), one C++ and gpsim header set, one
  soak driver source. Those are correct as they stand. `AVR_*` and `XT_*` are
  left alone for the same reason: they name the `avr_classic` and `avr_xt`
  families their shells are named for, and renaming `XT_*` to `ATTINY202_*`
  would break that correspondence rather than fix anything.

  The classic AVR lane had the unmarked-default problem here too, since
  `XT_SOAK_*`, `PIC10F322_SOAK_*` and `PIC10F320_SOAK_*` were all qualified
  while plain `SOAK_*` silently meant the AVR one. Renamed accordingly:
  `MCU`/`F_CPU`/`HFUSE`/`LFUSE`/`AVRDUDE_PART`/`AVRDUDE_FLAGS` →
  `ATTINY13A_*`; `F_CPU_X5`/`HFUSE_X5`/`LFUSE_X5` → `TINYX5_*`;
  `FLASH_T13_*` → `ATTINY13A_FLASH_*`; `SOAK_*` → `AVR_SOAK_*`;
  `PROGRAMMER` → `AVR_PROGRAMMER`; `STACK_SOURCES`/`STACK_MAX_FRAME`/
  `STACK_BUILD_DIR` → `AVR_STACK_*`; and `STACK_DEPTH_GATE`, which serves both
  PIC parts, → `PIC_STACK_DEPTH_GATE`. The PIC10F322 build directory moves from
  `build_pic/` to `build_pic10f322/`, matching `build_pic10f320/`.

  Names that are *not* chip facts keep their spelling — `SIM_DEFS`, `HOST_DEFS`,
  `COVERAGE_*`, `STRICT_TOOLS`, `VARIANT(S)` and the tool variables name a tool,
  a host facility or a project-wide policy, not a part.

  C-side contracts deliberately did **not** move: the compiler macros
  `-DF_CPU`, `-DSOAK_DURATION_MS`, `-DSOAK_COMBINATION_NAME` and the rest keep
  their names, because those are the firmware's and the test drivers' interface,
  not the build system's. Renaming a Make variable is nevertheless an external
  interface change — `scripts/make-release.sh` and `scripts/ci-local.sh` read
  Makefile truth through `make -s print-<VAR>` — so every `print-` consumer was
  swept with the rename and re-checked to resolve.

  This goal/variable rename also changes no image byte. The later relay safety
  fix remains the release's sole intentional image difference.

- **The tinyx5 soak selectors take a part name, not a chip number.**
  `AVR_SOAK_CHIP` and `AVR_SOAK_WITNESS_CHIP` were the last user-facing
  selectors that named a part by a fragment:

  | before | after |
  |---|---|
  | `make test-soak AVR_SOAK_CHIP=45` | `make test-soak AVR_SOAK_CHIP=attiny45` |
  | `make test-soak-reset-witness AVR_SOAK_WITNESS_CHIP=85` | `... AVR_SOAK_WITNESS_CHIP=attiny85` |

  The distinction the change draws is between the family's *internal* indexing
  and what a *request* may name. `TINYX5` remains `85 45`, because that is what
  indexes `mmcu_<n>`/`part_<n>` and generates the `attiny<n>`,
  `attiny<n>-size` and `attiny<n>-flash` goals. The new `TINYX5_PARTS` is that
  same family expressed as parts, derived (`$(foreach n,$(TINYX5),$(mmcu_$(n)))`)
  rather than restated, so a third sibling cannot enter one list and not the
  other — and it is what both selectors now validate against.

  A command line carrying the old spelling is told so, by the single-variant
  selector guard added earlier in this release, and the guard's own test asserts
  that message so the claim cannot quietly stop being true:

  ```
  $ make test-soak AVR_SOAK_CHIP=85
  FAIL: AVR_SOAK_CHIP=85 is not supported; expected one of: attiny85 attiny45
  ```

  Nothing published moves: the six soak binary paths, the fifteen release soak
  combination names and the retained evidence filenames are byte-for-byte what
  they were before this change. Only the request vocabulary moved.

### Fixed
- **The fuse-injection contract no longer interprets Make stderr as fuse
  values.** Its helper concatenated stdout and stderr before the bulk
  `print-<VAR>` query required exactly one line per fuse variable. Unrelated
  parse-time diagnostics, including missing-`avr-gcc` discovery noise, therefore
  made a valid contract fail before any value was checked.

  Make stdout is now the sole value and dry-run recipe protocol. Stderr remains
  separately captured and is included, with stdout, when Make fails or stdout
  has the wrong cardinality or value syntax. Four stream regressions accept
  valid values beside stderr noise and reject extra blank stdout, nonzero Make
  status, and malformed fuse values with both channels preserved in diagnostics.

- **The ATtiny202 delay oracle no longer discards recognized loops with
  undecodable seeds.** A complete `sbiw` plus back-targeting `brne` signature
  previously emitted a warning and disappeared when either seed-register LDI
  could not be recovered. That let `cd4053_simple` pass as having no delays and
  let a timed variant hide an undecodable extra loop beside its valid pulses.

  Recognized candidates now require a provable 16-bit iteration seed or produce
  one normal per-image oracle failure. The host self-test drives the production
  parse/check path for both false-pass shapes: an undecodable candidate in the
  simple variant, and two valid 5 ms mute loops plus an undecodable extra.

- **Mutation timeout and interruption controls now fail closed.** An explicitly
  empty `MUTATION_TIMEOUT_S` previously became the 900-second default, zero
  disabled GNU `timeout`, and malformed values reached the tool unchecked. The
  control now accepts only representable `0.001..86400` second values with at
  most three fractional digits; unset still means 900, while empty, zero,
  negative, malformed, under-resolution, and over-limit values fail before any
  Make or optional-tool probe. The outer mutation deadline is also inherited by
  nested gpsim wrappers, so their earlier timeout cannot collapse infrastructure
  expiry into an ordinary mutation-kill status.

  Every bounded checker now runs in a registered, token-owned process session.
  Normal completion and signal cleanup enumerate every process group in that
  session, covering nested GNU `timeout`, Make, compiler, and simulator
  descendants; TERM is followed by a rescan and KILL for non-cooperative
  processes. Cleanup discovers jobs in the interrupted shell itself, repeatedly
  scans for late session registrations, refuses to signal a reused SID without
  its private ownership token, and keeps all mutation scratch trees below the
  run-owned result root. The 62-check host regression uses real fractional
  expiry, nested timeout groups, a TERM-ignoring descendant, and a stopped
  launch-gap worker with inherited ownership, then proves no owned process
  survives interruption.

- **The shared compile-check reach gate accepted commented-out includes.** Its
  unanchored substring search treated
  `// #include "bypass_compile_checks.h"` as proof that the threshold contract
  reached an MCU shell. The semantic guard mutations compile only the Classic
  AVR shell, so removing the include from AVR-XT or PIC10F322 could leave the
  gate green while those shells silently lost all five shared assertions.

  Reach verification now requires an anchored, uncommented direct preprocessing
  directive with the exact header name. Fresh negative fixtures comment out the
  include in Classic AVR, AVR-XT, and PIC10F322 one at a time, prove the source
  changed, and require the common detector to report exactly that shell.
  PIC10F320 remains the sole explicit exception because it carries its
  constrained local copy.

- **Ambient environment state could replace the release verifier's independent
  canonical image set.** `RELEASE_EXPECTED_IMAGES` existed for synthetic tests,
  but the production verifier also honored it. A stale exported value naming a
  valid subset could therefore make identically incomplete committed,
  `SHA256SUMS`, and fresh-build sets pass the four-way comparison.

  Production now pins the repository Makefile, clears inherited GNU Make option,
  assignment and injected-makefile channels, and reads `RELEASE_IMAGES` with no
  alternate fixture option or environment oracle. Synthetic empty, malformed,
  duplicate and incomplete canonical sets use an unchanged verifier copy beside
  a test-only Makefile. Regressions recreate the one-image exploit through
  `RELEASE_EXPECTED_IMAGES`, `MAKEFLAGS`, `GNUMAKEFLAGS`, `MAKEFILES`, and Make's
  environment-precedence mode; the full 18-image provenance fixture also passes
  with a hostile reduced value.

- **Staged classic-AVR HEX bytes were not bound to the ELFs exercised by release
  qualification.** The nine ELFs retained hash continuity through validation,
  soak preparation and final HEX regeneration, but staging checked only that
  each regenerated HEX existed. Unlike PIC and AVR-XT, a changed classic image
  at the copy boundary could therefore be recorded as its own truth in
  `SHA256SUMS` rather than rejected against the validated artifact chain.

  The release now hashes all nine final regenerated classic HEX files by
  basename, copies them through a source-loaded staging helper, reconstructs the
  staged paths, and re-reads every destination byte. Classic AVR, AVR-XT and PIC
  staged comparisons all complete before `SHA256SUMS` is written or evidence is
  retained. The release-preflight contract independently mutates one classic
  source immediately before `cp` and one destination immediately after `cp`;
  both fail before checksum acceptance, while an unmodified control passes.

- **A PIC10F320 relay-coil latch upset can no longer remain energized
  indefinitely while healthy firmware pets the watchdog.** The constrained
  target still cannot afford the PIC10F322's general expected-mask latch check,
  but its relay variant now reasserts both coil outputs low immediately after
  every accepted timer event, before the sanity decision and watchdog pet. The
  blocking 12 ms actuation is unaffected: the loop cannot execute during its
  delay, and the existing pre/post-pulse clears remain in place.

  Host fault injection forces RESET, SET and both coil bits high after one clean
  iteration and requires both outputs to be low in each of the three cases at
  the next completed iteration, without a footswitch event or reset. Its relay
  count grows from 41 to 59 while
  the two analog variants remain at 41. The real-HEX libgpsim lane repeats the
  three cases against physical `PORTA`, rejects an opposite-coil transient, and
  grows only the relay count from 22 to 25. Exact host actuation (115 checks),
  target I/O (36), and lock-step (3,005) retain their prior counts and no new
  normal-path edge. At the test's deterministic loop-boundary injection seam,
  the emitted image clears the physical outputs in 364-366 instruction cycles
  (0.728-0.732 ms nominal), versus measured 12.024-12.036 ms intentional pulses.
  An arbitrary idle-phase upset is bounded by one actual timer period plus
  rewrite overhead; an upset during blocking actuation is cleared by the
  existing post-pulse clear. This bounds per-channel coil/driver energy; it does
  not claim that a short accidental pulse cannot mechanically switch the relay.

  The pinned XC8 V3.10 / DFP 1.9.189 build prices the fix at one word: the relay
  grows from 244 to 245 of 256 words, leaves 11 free, and retains a 4/8 maximum
  return-stack depth. Both analog image hashes remain unchanged; only the relay
  baseline moves to
  `00e1d3ac37ed1857f5e1b3047e921ac22bd9705a728f7c77c9c9daae31d34cd8`.
  Four mutations remove the rewrite or reduce it to one coil across the host and
  real-image planes, taking the pinned total from 94 to 98.

- **Datasheet traceability conflated machine enforcement with documentary
  evidence.** The design table now labels each row as machine-gated,
  runtime-checked, build-derived or documented, and separates enforced register
  selections from vendor physical properties such as tolerance, trip voltage and
  current draw. The matching changelog and TODO summaries no longer claim every
  row can fail a build or test.

- **Release preflight used Git and Make before checking that they existed.**
  Minimal bootstrap checks now diagnose either missing prerequisite before tag,
  repository or `print-<VAR>` operations, while section 0 retains both commands
  in its complete required-tool inventory. Isolated-PATH regressions cover both
  failures and the successful preflight still reaches its terminal version probe
  without cleaning, building or staging.

- **The PIC phase-2 notes said blocking actuation affected tests but not firmware
  timing.** The initial toggle has already been accepted before the block, but an
  immediate release cannot drain the lockout counter during the 5 ms mute or
  12 ms relay actuation. The notes now account for the one normally latched
  pending timer sample and use the conservative 33/38/45 ms simple/mute/relay
  press-to-re-arm budgets from the design document.

- **The mutation guide attributed yasimavr's half-width pulse traces to flat
  instruction timing.** The core models multi-cycle instructions; the pinned
  release loses their overshoot because the output tracer repeatedly calls
  `SimLoop.run(1)`, which rewinds the cycle counter on return. The mutation
  section now matches the detailed known-gap analysis and still routes absolute
  pulse-width checks to the image-based delay oracle.

- **The AVR lock-step comments called their per-tick oracle independent even
  though it executes the shipping pure core.** The simulated AVR image and the
  host `model_step.h` adapter both run `src/bypass_pure.c`; the symbolic harness
  and the model checker's principal state graph call that adapter too. The
  comments now distinguish this target-compilation and shell-integration
  comparison from the model checker's handwritten scheduling submodel and the
  broad independent reimplementation in `test/host/test_logic_host.c`. They also
  scope the lock-step lane's handwritten initialization anchor to the released
  startup state it actually exercises.

- **The AVR simulator still described a retired per-build TMUX4053 polarity.**
  The separate direct-drive variants no longer exist: the current CD4053 images
  use one control-pin polarity for both CD4053 and pin-compatible TMUX4053 board
  wiring, LOW in BYPASS and HIGH when ENGAGED. Comments now state that invariant
  consistently; simulator logic and assertions are unchanged.

- **Five active surfaces still used pre-v0.9.8 image or variant vocabulary.** The
  two gpsim wrapper usage blocks now show canonical MCU-qualified basenames; the
  PIC10F320 special-case and PIC shell notes use `cd4053_simple`; and ATtiny202 CI
  now correctly says the output-stage field is exactly the variant name while
  still deriving complete basenames from the Makefile. Historical release
  evidence, migration tables and old feasibility records remain unchanged.

- **The non-blocking feasibility headline said the PIC10F320 spike was measured
  "end to end", overstating its evidence.** The spike was compiled, linked,
  flash-budgeted and stack-gated, but no actuation, lock-step, I/O, fault, soak or
  release-qualification lane ran against it. The executive summary now states
  that exact boundary and points to the existing §6.8 scope record.

- **The PIC hardware-stack gate rejected every real image after it started
  reading `psect` directives.** Tracking "inside a function psect" ended the
  current function at *any* `psect` directive, but XC8 re-selects a function's
  own psect inside its body — once immediately after the `;psect for function`
  marker, and again to restore the psect after each inline-asm escape (`clrwdt`
  in the PIC shell). Every function body therefore parsed as being outside any
  function psect, and `pic10f322-test-stack-bound` failed all three variants
  with `call to annotated function _hw_set_bypass_state occurs outside any
  function psect`. The measurement itself was never wrong — the gate refused to
  produce one.

  Each function is now bound to the psect it was declared in; re-selecting that
  psect stays inside the body, while any other psect still ends it, and an
  operandless `psect` is a structural error rather than a silent no-op. A marker
  with no declaration of its own binds nothing instead of inheriting the
  preceding one, so it keeps the conservative behaviour.

  The synthetic fixtures missed this because they emitted a bare marker with no
  psect scaffolding, so the regression suite passed against a gate that could
  not read a single real image. The fixture builders now emit the full
  declaration / marker / re-selection sequence XC8 produces — every case
  exercises it — plus dedicated cases for the inline-asm restore, a genuine
  mid-body psect switch, a marker that would otherwise inherit the preceding
  psect, and a malformed directive.

- **The PIC12F675 feasibility assessment recommended an ISR model whose return
  stack had never been measured.** Its flash/RAM builds and one gpsim trajectory
  succeeded, but both PIC parts have the same 8-level hardware stack and the
  throwaway PIC12F675 ISR source and assembly were not retained. The historical
  parser diagnostic survives, but no numeric current-gate result or complete
  supporting output does.
  The document also described a historical `i1_` lexer failure as a current
  inability to represent interrupt trees, even though the gate now handles them.

  The assessment now establishes Model B as feasible and treats ISR as a
  candidate pending a reproducible three-variant stack result with the required
  reserve. Summary, verdict, resource table, gate description, risks,
  recommendation, validation lanes, sequencing and reproduction notes all make
  the same distinction: the current gate can compute the result; the inputs and
  result do not exist. Measurement provenance remains pinned to `0cfc72e`, while
  the correction records the later gate changes without implying a remeasurement.
  The non-blocking feasibility document now marks its corresponding correction
  as applied rather than correcting a live contradiction elsewhere.

- **The PIC hardware-stack gate could silently ignore a direct call whose target
  used an unrecognized prefix.** Its instruction lexer admitted only `_...` and
  XC8's known `iN_...` interrupt duplicates. An in-function call to `x_helper`
  therefore disappeared before target validation and could turn a real call
  chain into a reported depth of zero.

  The gate now tokenizes every direct `call`, `fcall`, `lcall` and resolved
  `pcall` inside a validated function psect, independent of target spelling, and
  requires every target to resolve to an XC8 function annotation. Each
  annotation must own exactly one matching psect marker; non-function psect
  transitions clear function context; startup/runtime calls remain permitted
  only outside function psects; and indirect or malformed calls still fail
  closed. Synthetic fixtures cover all four direct opcodes, unprefixed known and
  unknown functions, psect ownership, startup/runtime boundaries, indirect
  calls, and the existing main-plus-ISR accounting.

- **Mandatory host Python gates now have an explicit, fail-fast version
  contract.** The system `python3` minimum is 3.7, the first version providing
  the `subprocess.run(capture_output=..., text=...)` APIs those gates already
  use. A shared executable check is the first prerequisite of `make test` and
  `make test-long`, and the three directly affected gates depend on it when run
  alone, so Python 3.6 now gets an actionable version/path diagnostic instead of
  an internal `TypeError`.

  Release preflight runs the same check before probing PyYAML or starting any
  child gate. Its regression accepts the 3.7 boundary, rejects 3.6, permits
  newer host interpreters, and proves an old interpreter cannot reach the
  PyYAML probe. This system-Python contract remains separate from the patched
  yasimavr venv's narrower CPython 3.9-3.13 platform lock.

- **The retained rename-identity report now describes the final images, not an
  earlier build at the same paths.** The fail-fast comparison still runs after
  the initial 18-image build, before any expensive qualification gate. But
  `make test-long`, the target aggregates and final Classic-AVR HEX regeneration
  can all rebuild those paths. The report produced before them was therefore a
  claim about files that no longer necessarily existed by staging time.

  `scripts/make-release.sh` now runs the same comparison again after every final
  image-presence/hash check and immediately before source provenance and
  staging. That second invocation overwrites the provisional report, so the
  retained `RENAME_IDENTITY.md` is computed from the exact image paths copied
  into the release. `test-release-provenance` pins both sides of the ordering and
  reproduces the defect dynamically: the exact 17-identical +
  1-intentional-change set passes, a second image is changed, and the final
  comparison must fail with that image marked `UNEXPECTED DIFFERENCE`.

- **The name-contract gate could not see a file until it was committed, so it
  reported a violation one run late — to the next person rather than to its
  author.** `harvestable_files()` enumerated `git ls-files`, which reads the
  *index*: a newly written file was invisible to all four axes until it was
  added. `make test` therefore passed on the commit that introduced a violation
  and failed on the run after. Filed from an observed instance, not a review —
  `test/test_fuse_injection_contract.py` did exactly this, on two docstring
  lines that reflowed such that a line began with the word `make` followed by an
  English word. The gate's own self-exemption was accidental for the same reason
  until the day the file was first committed.

  The harvest now reads the working **tree**: `git ls-files` plus
  `git ls-files --others --exclude-standard`, so a file is in scope from the
  moment it exists. Both halves of that are load-bearing in opposite directions
  and both are now asserted, against a throwaway fixture repository rather than
  against this one — a clean working directory has no untracked file to
  demonstrate the property with, which is precisely why it went unnoticed.
  Without `--others` the gate silently narrows back to committed files; without
  `--exclude-standard` it silently widens to every generated artifact under
  `build_avr_classic/` and `third_party/`. Each direction was verified to fail.

  Two consequences worth stating rather than discovering. The `PUBLISHED` path
  rule that excludes `release/v*/` is newly load-bearing: a release directory is
  untracked while `make release` is staging it, so what used to be redundant for
  an unadded file is now the only thing keeping a past release's goal names out
  of a check on the current tree — asserted alongside the harvest. And the
  untracked half honours the developer's `core.excludesFile`, so it can see
  slightly less on one machine than another; the tracked half is identical
  everywhere, so CI remains the floor and this half can only ever catch *more*,
  earlier.

  Paths are read `-z`-delimited rather than split on whitespace. The untracked
  half is the one that can hold a name a person typed by hand, and a space in it
  would have split into two nonexistent paths, both dropped by the existing
  `isfile` test — that is, skipped **silently**, which is the defect class the
  gate exists to prevent. 37 → 39 checks, still 0.7 s.

- **The PIC10F320 gpsim lanes simulated a PIC10F322, and the gate written to
  prevent exactly that stayed green.** The variable-prefix rename in this
  release renamed the shared gpsim wrapper's processor selector from
  `PIC_GPSIM_PROC` to `PIC10F322_GPSIM_PROC` in
  `test/pic/gpsim_wrapper_common.sh`, and left all four Makefile recipes
  spelling `PIC_GPSIM_PROC=`. Those assignments became inert environment for a
  name nothing reads, so both wrappers fell through to their `p10f322` fallback:
  `make pic10f320-test-gpsim` ran the 256-word part's HEX on the 512-word part's
  device model and reported `RESULT: PASS`. The PIC10F322 lane was correct only
  by coincidence — its override happens to equal that fallback.

  Introduced on this branch; `v0.9.7` spelled the name the same on both sides,
  so no published release is affected. Both PIC10F320 wrappers pass unchanged on
  the correct model, across all three output stages.

  The rename was also backwards on its own terms. `Makefile` states the rule
  beside the PIC variables — a `PIC_*` name with no part in it is the channel
  each lane passes its OWN part's value through, and names
  `PIC_GPSIM_PROC` as one of four such channels. A shared wrapper whose selector
  carries one part's name severs the other lane by construction, and silently,
  because the fallback is that same part. Fixed by restoring the read.

  **The gate is the more important half.** `test/test_gpsim_wrappers.sh` already
  carried a behavioural check for this, with a comment reading *"If this
  regresses, the PIC10F320 lanes silently simulate a PIC10F322"* — and the same
  commit rewrote that check's own probe to set the new name, so it went on
  proving that the wrapper READS the variable while the Makefile stopped WRITING
  it. A gate that supplies the input it is meant to observe cannot see its
  producer disappear. Both public lanes are now probed end-to-end through a
  `-p`-recording fake gpsim:

  - `pic10f320-test-gpsim` is run with nothing overridden and must reach gpsim
    with `p10f320` twice. Non-vacuous because the shared fallback is `p10f322`,
    which is precisely the value the severed lane produced.
  - `pic10f322-test-gpsim` cannot be checked that way at all — its correct
    processor IS the fallback, so severed and intact are indistinguishable. It
    is handed a probe value that is neither part's and must carry it through.
    Setting it on the make command line does not short-circuit the check: make
    exports command-line variables to the recipe environment, but under
    `PIC10F322_GPSIM_PROC`, which the wrapper does not read.

  Both probes read the wrapper's fallback rather than restating it, fail if that
  value cannot be extracted, and fail if the expected value has drifted to equal
  it. Verified by reintroducing the defect four ways — the 320 prefix severed,
  the 322 prefix severed, the expected value made equal to the fallback, and the
  fallback made unreadable — each reported by its own diagnostic. 44 checks.

  **The name-contract gate's axis D was pointing at this defect**, which is how
  it was found: prose naming `PIC_GPSIM_PROC` reads as severed there, because
  axis D's known-name set was make variables only. A `NAME=value` prefix on a
  recipe line defines no make variable, so the only spellings axis D accepted
  for a shared env channel were part-scoped make-variable names — the rename
  that broke this lane. `env_channel_names()` now unions those prefixes into the
  known set, walking every statement of a recipe rather than only its first
  (recipes are one logical line, and these invocations are the eighth statement
  of theirs — reading only the head finds 44 channels and misses this one). It
  takes the prefix position only, stopping at the first word that is not an
  assignment, so make overrides and `-D` macros stay with axis C and the
  fuse-injection contract respectively. A negative case fails if the harvest
  stops finding `PIC_GPSIM_PROC` or starts reading `-D` macros as environment.

  This closes a false positive, not the class. Nothing yet checks that a child
  still READS the environment its parent sets — the gap this defect came
  through. Filed as axis E in `TODO.md`, with the surface measured (121
  channels, one severed) and the two things that make a naive version wrong.

- **`make release` could not have completed: the AVR soak binary was renamed on
  one side only.** The same rename that moved `test_sim_<v>_t<n>` to
  `_attiny<n>` updated `scripts/make-release.sh`, which composed its own copy of
  the soak binary's path, to ask for `test/avr/test_soak_<v>_attiny<n>` — while
  the Makefile's `AVR_SOAK_BIN` went on saying `_t<n>`. There is no such target:
  `make -n test/avr/test_soak_cd4053_simple_attiny85` answered *"No rule to make
  target"*. A release run would have died in step 3, on the far side of `make
  test-long` and every qualification gate, an hour or more in.

  Filed as cosmetic residue — "the `_t<n>` suffix this release retired
  everywhere else still exists in two places" — and it was not. Nothing builds
  these binaries outside a real release, so no gate ran the composition that
  had severed.

  `AVR_SOAK_BIN` now spells `_attiny<n>`, matching its sibling simulation
  binaries, and `make-release.sh` READS it rather than keeping a second copy.
  The image basenames beside it stay restated on purpose: those are the script's
  independent opinion of the release set, cross-checked against
  `RELEASE_IMAGES`, so restating them is what gives the check meaning. This path
  was cross-checked against nothing and only needed to be right — the
  distinction the copy missed. The retired `_t<n>` binaries join
  `AVR_TEST_BINARIES_RETIRED` so an existing worktree does not keep them.

- **`make clean` stopped removing nine of the binaries it builds, and
  `clean-tests` stopped removing anything at all in the classic-AVR lane.** Both
  targets spell their artifacts as a hand-written list, and the image rename
  earlier in this release moved the simulation binaries from `test_sim_<v>` /
  `test_sim_<v>_t<n>` to `test_sim_<v>_attiny13a` / `_attiny<n>` without either
  list following. Every path they named had stopped existing; all nine binaries
  actually built survived both targets. Nothing failed, because an `rm -f` of a
  file that is not there is a successful `rm -f`.

  `clean-tests` is the sharper half: its stated job is to drop binaries so the
  next run rebuilds them at the currently selected workload sizing, so a
  `clean-tests` that removes nothing means a `make test-long` could run FAST
  workloads while reporting the exhaustive suite. It could not, in fact —
  every affected rule carries `FORCE` and recompiles regardless — but that is an
  accident of an unrelated design decision, not a guarantee, and it would go
  silently the day a `FORCE` came off.

  The list is now spelled **once** (`AVR_SIM_BINARIES` / `AVR_SOAK_BINARIES`)
  rather than twice, and `clean` additionally removes the retired spellings so a
  worktree predating the rename does not keep them forever — the same courtesy it
  already extended to the pre-`src/`-reorganization KLEE paths.

  New gate `test-clean-contract` (`test/test_clean_contract.sh`, in `make
  test`), 11 checks in 0.4 s. Its oracle is `make -rRn --print-data-base`: every
  explicit non-phony target under `test/` that is not a tracked source file is
  something the Makefile builds, and `make -n clean` must remove it. Reading
  Make's own inventory is the point — a second hand-written list would just be a
  third copy of the spelling to drift, and the families that matter
  (`test_sim_<variant>_attiny<n>`) exist only after `$(eval $(call ...))`
  expansion, so a textual harvest of rule heads would not see them at all.
  `clean-tests` has a deliberately narrower scope, so its gap is checked against
  declared exemptions rather than required to be empty; a new build product
  forces a decision. Verified by restoring the pre-rename spellings, which makes
  the gate name all nine binaries and fail.

- **`MISRA_COMPLIANCE.md`'s maintenance procedure told a maintainer to run the
  MISRA sweep over variant names that no longer exist**, and the command did not
  fail — it silently analyzed **zero** output drivers and exited 0.
  `make analyze-misra VARIANTS="cd4053 mute relay"` (and the
  `analyze-misra-report` line beside it) named the pre-`v0.9.8` stage
  vocabulary; `$(FW_SOURCES)` is built by
  `$(foreach v,$(VARIANTS),$(src_$(v)))`, so every unrecognised name
  contributes nothing and the set silently shrank from five files to two.
  Both lines now name the current values, and the command they name can no
  longer behave that way for anyone: the five `analyze-*` targets now validate
  their variant request (see *Added*).

  This is the *value* twin of the four name-contract axes and is not covered by
  any of them: `VARIANTS` exists, so axis C is satisfied; only its contents were
  stale. It is also the failure mode the `Makefile` warns about in its own
  words — "a mis-scoped chip variable produces no compile error and no failing
  test, it produces a PASSING one". Found by hand while building axis D, in the
  same code block whose very next line already used the current spellings.

- **The PIC10F322 soak driver had not compiled since the stage-vocabulary
  rename, silently disabling a mutant and breaking three release soak
  binaries.** `Makefile`'s `pic_soak_block_*` map kept its retired
  `cd4053`/`mute`/`relay` keys while `PIC10F322_SOAK_VARIANT` moved to
  `cd4053_simple`/`cd4053_with_mute`/`tq2_l2_5v_relay`. All three lookups
  expanded empty, so the compile line emitted `-DSOAK_ACTUATION_BLOCK_MS=u` and
  the driver failed with ``error: `u' was not declared in this scope``. The
  PIC10F320 copy of the same map had been renamed correctly, so the two lanes
  disagreed in silence for an entire release.

  It degraded to a *skip*, not a failure: `make pic10f322-test-soak` was broken
  outright, the mutation harness reported its baseline as failed and skipped the
  PIC10F322 WDT mutant, and the run still exited zero as a `PARTIAL`. The
  mutation inventory is back to **94 killed, 0 survived, 0 errored, 0 skipped**
  from 93 killed with one skip. `scripts/make-release.sh` builds the three
  PIC10F322 release soak binaries through the same rule, so this would also have
  failed the `v0.9.8` release soak.

  The parse-time completeness guard added earlier in this release covered
  `macro_<v>` and `src_<v>` only; `pic_soak_block_<v>` was a third per-variant
  map it did not know about, and `pic10f320_soak_block_<v>` a fourth. The guard
  is now a reusable `require_variant_map` contract covering all four, with each
  soak map checked against *its own lane's* supported set so the deliberate
  divergence between lanes stays legal.

  A guard that needs a human to remember to extend it has the failure mode it
  exists to prevent, so a new `test-variant-map-contract` gate (in `make test`)
  asserts every per-variant map is registered. It harvests **dereference** sites
  rather than definitions, because a definition-keyed harvest would not have
  caught this defect — `pic_soak_block_cd4053` matches no current variant name,
  so it was invisible exactly when it was broken.
- **No mutant, and no CI job, had a wall-clock bound.** Containment for the
  severed-override defect below, which is the same incident from the other end:
  that fix removed the cause, this one removes the blast radius. A single mutant
  ran for over ten hours locally before being killed by hand, and nothing in the
  harness or either workflow would have stopped it.

  Every mutant checker and every toolchain baseline probe now runs under
  `timeout` (`mutation_bounded`, default 900 s, `MUTATION_TIMEOUT_S` to
  override). The bound is deliberately loose: mutant soak windows are 2–2.5 s of
  simulated time, so 900 s is about two orders of magnitude of headroom — enough
  to catch a 43,200× severance immediately without ever becoming a flaky
  failure.

  The load-bearing half is the exit status, not the bound. A mutant is recorded
  as *killed* on any nonzero exit, so a hung mutant terminated at the deadline
  would have been counted as killed — a suite reporting a clean run it never
  finished. `timeout` exits 124 on expiry, which is now classified as an
  infrastructure error in `test/mutation_accounting.sh`, so a hang surfaces as
  `ERROR`. Both properties are covered by new selftest assertions that drive the
  wrapper itself rather than only the classifier, so deleting the bound fails the
  suite.

  All six GitHub Actions jobs gain `timeout-minutes` (previously zero across both
  workflows): `verify`, `pic`, `build-matrix` 45, `attiny202` 60, `stress` 300,
  `release` 60. The `stress` job is the one that matters — it reaches the
  mutation lane and would otherwise have been cancelled at GitHub's six-hour
  default with nothing useful reported.
- **The `v0.9.8` rename left dead variable and goal names on eleven live
  surfaces, two of them instructing a reader to type one.** The same
  silent-severance class as the entries below, found by a meta-review of the
  finished release rather than by any gate. `make -s print-MCU` and
  `make -s print-PIC320_TAG` both returned empty.

  The sharpest was `Makefile`'s `test-flash-budget` guard, which reads
  `$(ATTINY13A_MCU)` but told a user who tripped it that it `requires
  MCU=attiny13a` — advice that, followed, sets an inert override and changes
  nothing. `test/test_flash_budget.sh` asserted that exact text, so the
  regression was defending the dead name; correcting the message alone would have
  turned the gate red. Also fixed: a Makefile comment instructing readers to set
  four removed `PIC320_*_VARIANT` names on the command line, three more `PIC320_*`
  prose references, `README.md`'s claim that the PIC10F320 lane uses `PIC320_*`
  variables, three harnesses passing an inert `MCU=attiny13a`, and
  `test/README.md`'s `make test-sim-<variant>`, which has no rule — the goal
  identified by the *omission* of its MCU field, the exact defect this release's
  rename existed to remove.

  Nothing was mis-built: `ATTINY13A_MCU` is a plain `=` whose default equals the
  value the dead overrides passed. The cost was misdirection, not wrong output,
  which is why no gate would ever have noticed. `TODO.md`'s name-contract item is
  widened to a fourth axis (variables named to human readers) and records why its
  own prototype sweep missed these: it keyed on physical lines, and the overrides
  sat five backslash-continued lines away from the `make` that consumed them.
- **The mutation suite's PIC lane had been silently disabled since the image
  rename earlier in this release.** `test/run_mutation_tests.sh` built its
  PIC10F322 baseline image path from the *old* basename scheme
  (`${FW_BASE}_cd4053_${PIC_TAG}.hex`), which stopped existing when images
  became `bypass-pic10f322-cd4053_simple.hex`. The miss degraded to a skip
  rather than a failure — the missing file left `PIC_GPSIM_OK` unset, so the
  PIC gpsim mutants reported as unavailable instead of failing loudly. Found by
  the prefix sweep, not by a gate: the mutation run is in `test-long`, not
  `make test`. The path is now composed from the canonical fields.
- **A failed PIC10F322 mutation baseline build could admit stale HEX bytes and
  manufacture six clean-looking kills.** The bounded `pic10f322` build's status
  was discarded before the probe checked whether its selected HEX existed. A
  failed or timed-out build that left an apparently usable file could therefore
  enable the gpsim lane; ordinary mutant build failures would then count as
  kills even though the unmutated baseline had never passed.

  The build must now succeed before the probe inspects or executes the HEX. A
  failure disables the complete PIC10F322 lane as `baseline FAILED`, latches the
  existing infrastructure-failure diagnostic, and reaches no simulator or
  mutant dispatch. The host-only mutation self-test recreates the stale-HEX
  path with status 42 and proves that it cannot be reported as a kill.
- **The goal rename left sixteen dead `make` commands in documents that describe
  the current tree.** Same silent-severance class as the mutation-lane miss, on
  the axis pointed at readers rather than at scripts: nothing asserts that a goal
  named in a document still exists, so `make pic320-test` and its siblings
  survived the rename as instructions that now fail with `No rule to make
  target`.

  Fifteen were in `docs/pic10f320_validation.md`, which is framed as *current*
  qualification evidence rather than history — eleven in prose describing
  standing gates, and four in its §7 "Reproducing any of this", where four of
  six commands were dead and `PIC320_SOAK_DURATION_MS` had been renamed too. The
  sixteenth was `make pic-test-config` in `docs/phase2_pic_shell.md`. All now
  carry their `v0.9.8` spellings. Two references are deliberately left in the
  old vocabulary and read correctly as history: a captured
  `make: *** [pic320-test-equiv] Error 1` transcript, and
  `release/v0.9.6/evidence/pic320-test.log`, which is a real file under that
  name.

  `release/README.md`'s reproduce recipe had a related defect that a rename table
  could not fix. Its "Unified releases (v0.9.6 or later)" section says
  `git checkout vX.Y.Z` and then builds with goals that only exist from `v0.9.8`
  on, so it was wrong for two of the three releases it claimed to cover. The
  section is now scoped to `v0.9.8` or later, and a second section carries the
  same recipe for `v0.9.6` and `v0.9.7` in that era's goal names. Checking out a
  tag moves the Makefile, `RELEASE_IMAGES`, `SHA256SUMS` and both verifier
  scripts together, so those releases remain reproducible with exactly the
  guarantees described for the current one; what does not work, and is now stated,
  is pointing the *current* image verifier at an older release directory.

  The `TODO.md` item filed earlier in this release for the `make print-<VAR>`
  contract gate is widened to cover both axes, since one gate closes both. Its
  allowlist is the hard part and is now specified from the real cases: a document
  may legitimately name a retired goal in an old→new redirect table, in a recipe
  pinned to an older tag, or in a quoted transcript — so the exemption has to be
  per-block, not per-file.
- **The variable rename left the classic-AVR WDT mutant running a 24-hour soak
  in place of a 2-second one.** A third axis of the same silent-severance class
  as the two entries above — `make VAR=value` overrides — and the first to cost
  wall-clock time. `test/run_mutation_tests.sh` still passed `SOAK_VARIANT=` /
  `SOAK_CHIP=` / `SOAK_DURATION_MS=` / `SOAK_LIVENESS_INTERVAL_MS=` to
  `make test-soak`, but those became `AVR_SOAK_*` earlier in this release. An
  override naming a variable no recipe reads is legal and silent, so the mutant
  asked for 2 s of simulated time and got `AVR_SOAK_DURATION_MS`'s 24 h default
  — 43,200×. A local `scripts/ci-local.sh` run sat in that single mutant for
  over ten hours before it was killed, and neither CI job that reaches the row
  declares `timeout-minutes`, so both would have been cancelled at GitHub's
  six-hour job limit. Now restored: the mutant is killed in 2.4 s with 127
  watchdog resets, exactly as its recorded rationale describes.

  Four guards missed it, each for a different reason, which is why this axis
  needs a gate of its own: the soak-timing contract's `static_assert` compares
  the *defaults* (`60000 <= 86400000`), so the build stays clean; the mutant is
  still correctly killed, only ~43,000× too slowly, so it presents as a hang
  rather than a wrong answer; the mutation run is in `test-long`, not
  `make test`; and no mutant is wrapped in `timeout`.

  The same rename had also left the Makefile recommending the broken spelling.
  Its soak-override block, `make help` and two header comments documented
  `SOAK_*` and `PROGRAMMER=` instead of `AVR_SOAK_*` and `AVR_PROGRAMMER`, so a
  reader following `make test-soak SOAK_DURATION_MS=3600000` got a silent
  24-hour run. All corrected, and that block now says explicitly that the bare
  `SOAK_*` spellings are the compiled-in C macros rather than make variables. A
  tree-wide sweep of every `NAME=value` passed to make confirms no other
  override is stale; the `TODO.md` gate item is widened again to cover this
  axis, and now recommends building it first, since it is the cheapest of the
  three and the only one with a demonstrated runtime cost.
- **Documentation: the recorded reason the ATtiny202 harness cannot measure
  busy-delay width was wrong, and is corrected everywhere it appeared.** Since
  `0.9.5` the delay oracle, `test_sim_attiny202.py`, `scripts/fetch_yasimavr.sh`,
  the Makefile, `test/README.md`, `TODO.md` and `DESIGN_DOCUMENTATION.adoc` all
  stated that yasimavr charges a flat ~1 cycle per instruction with no
  multi-cycle timing model. It does not; its AVR-XT core models instruction
  timing correctly.

  The real defect is in `SimLoop::run(nbcycles)`, which pins the cycle counter to
  `first_cycle + nbcycles` on return and therefore *rewinds* it whenever the last
  instruction overshoots the budget. A caller loses up to one instruction's worth
  of cycles per call, and at `run(1)` — one instruction per call — every
  instruction is billed exactly 1 cycle. The ATtiny202 output tracer samples pin
  state one cycle at a time, which is why a 12 ms coil pulse traced as ~6 ms. The
  original "flat instruction timing" conclusion was itself measured by
  single-stepping through that same bug.

  Reported upstream; the maintainer confirmed it and produced a fix. Verified
  against a local rebuild of the pinned 0.1.6 carrying that guard: `SBIW` steps
  as 2 cycles, the relay pulse measures 12.669 ms at single-cycle sampling
  instead of 6.186 ms, and `make attiny202-sim` passes unchanged. The pinned
  release does not carry the fix, so no test behaviour changes here and the
  absolute width stays with the disassembly oracle — where it belongs regardless,
  being a compile-time property. Re-pinning is filed as a `TODO.md` Tier 2.5 item.

  Nothing about the shipped firmware changes: the images were always correct for
  real 2 MHz silicon, and tick-driven timing (debounce thresholds, LED
  sequencing, lock-step) was never affected. The `0.9.5` entry adding the delay
  oracle carries this superseded rationale in its justification clause; the
  oracle itself remains correct and is unchanged.

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

[Unreleased]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.11...HEAD
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
