# Flashing simplicity — getting a release image onto hardware

**Status:** analysis and proposal, **partly implemented in `v0.9.10`.** This
document records a design discussion held on 2026-08-21 on branch
`v0.9.9-polish`, so that the reasoning survives the conversation and does not
have to be rebuilt from scratch. Its body is preserved as it was argued, in the
present tense of `v0.9.9`; where `v0.9.10` went on to build what a section
proposed, an italic ***Update (v0.9.10)*** paragraph says so at that section and
is the current statement. Two proposals shipped — the build-before-hardware
repair of §1 and §7.2, and the PIC12F675 no-compiler path of §5.5 and §7.7 — and
nothing else here has been. Read an un-updated section as a proposal, not as a
description of the tree.

**The goal, stated once and plainly: make it as quick, easy and painless as
possible for someone to flash a release image to their hardware.** That is the
primary objective. Everything else in this document — provenance, signatures,
generated documentation, drift gates — is subordinate to it and is justified
only insofar as it serves it or protects the person doing the flashing from a
silent hardware failure.

## 1. Who this is for

The **flash-only user**. They have:

- a chip (or a finished pedal board with one on it),
- a programmer (USBtiny, USBasp, PICkit 2/3/4/5, a serial-UPDI adapter),
- `avrdude` or `pk2cmd`/`ipecmd` installed,
- a downloaded release from
  [GitHub Releases](https://github.com/matt-garman/mcu-bypass-firmware/releases).

If signature verification is a required pre-flash step, then `gpg` and the
platform's SHA-256 tool are also user prerequisites unless the release bundle
provides a separately qualified helper. The design must state those
dependencies explicitly rather than introduce them halfway through the guide.

They do **not** have, and must not be required to obtain:

- `avr-gcc`, `binutils-avr`, or the vendored ATtiny device pack,
- Microchip XC8 or a PIC device pack,
- `simavr`, `gpsim`, `yasimavr`, `cppcheck`, `cbmc`, or any test dependency,
- necessarily even a clone of this repository.

For this person, "painless" has a concrete definition worth holding the design
to: **read one file, select one clearly labelled hardware profile, and paste one
complete programming command per chip without editing it.** Every placeholder
they must resolve — `<prog>`, `<port>`, which of 21 images is theirs — is
friction, and friction here is measured against a hobbyist at a bench with a
soldering iron in the other hand.

That definition needs one honest qualification. A static release document
cannot know which serial port exists on the reader's machine, whether a bare
chip is powered by the programmer, or which of several attached programmers is
the intended one. Literal zero-input operation therefore requires an
interactive helper that discovers or asks for those facts. The practical
static-document target is narrower: the user chooses a row that already matches
their MCU, output stage, programmer, operating system and power arrangement,
then copies its command unchanged. If even that one profile-selection step is
too much, a wrapper is not optional; it is the next design.

"One command" here means one shell command line for the programming operation.
Download verification remains a separate prerequisite. A command line may be a
fail-stop sequence such as `fuse-command && flash-command`; it need not be one
process or one argv vector.

The existing per-part `-program` goals still do not serve this person. They are
developer conveniences that require a source checkout and the cross-toolchain.
There is also a correctness issue to repair before treating those goals as the
programming oracle: `pic10f322-program` (`Makefile:1967`) builds before its
writer recipe, but the AVR goals express fuses and flash as separate
prerequisites (`Makefile:2475-2489`, `Makefile:2752-2777`). Under the Makefile's
serialized `-j1` invocation, the fuse prerequisite runs before the flash
prerequisite performs its build. A failed build can therefore leave changed
fuses and no matching firmware. The source-tree convenience path must build and
validate before either hardware side effect.

***Update (v0.9.10).*** *Repaired. Every AVR `*-program` goal is now one ordered
transaction rather than a two-prerequisite alias: the per-part build goal is a
real prerequisite, the recipe re-confirms the VARIANT-selected image and the
programmer while the device is still untouched, and only then writes fuses and
then flash. A failed build, size gate or IHEX validation reaches zero `avrdude`
invocations, and the ATtiny202 case that used to write seven fuse bytes after a
device-pack SKIP is a refusal. `make test-avr-program-order` gates the ordering
and the refusals. The paragraph above stands as the reason the change was made,
not as a current defect.*

## 2. Current state, measured

The good news is that much of the architecture for solving this is already in
the tree, and extending it is the right direction.

`scripts/make-release.sh:1585-1664` generates a per-image **Flashing** section
into each release's `MANIFEST.md` at release time. Most of its device values
are not hand-copied: `mkv()` at `scripts/make-release.sh:272` is
`make -s --no-print-directory print-<VAR>`, so the fuse bytes
(`ATTINY13A_LFUSE`, `ATTINY13A_HFUSE`, `TINYX5_LFUSE`, `TINYX5_HFUSE`, and the
seven ATtiny202 memories from `XT_FUSE_WDTCFG` through `XT_FUSE_BOOTEND`) and
the avrdude part names come from Makefile truth at generation time. The script
also deliberately composes an independent image inventory and cross-checks it
against `RELEASE_IMAGES`, rather than deriving both sides of the completeness
check from one list. The result is visible at
`release/v0.9.9/MANIFEST.md:87-150`.

So "generate a per-release programming document from the Makefile at release
time" is not a new idea to propose. It is the established pattern, and
extending it is far cheaper and lower-risk than adding a hand-maintained
document that would immediately become a duplicate.

There is also good prose in `release/README.md` ("Flash a chip", "Which image
do I want?", "Verify a download") and a short per-release `README.md` carrying
the `sha256sum -c` step. The published `MANIFEST.md` itself opens with that
basic checksum instruction and is used as the GitHub Release body. What the
asset-only user does not receive is the complete signature bootstrap,
selection-first presentation, or copyable profile-specific commands.

## 3. What blocks "painless" today

### G1 — The release landing page is written for an auditor

`.github/workflows/release.yml` fixes the published asset set to the canonical
images, required non-image helpers, `SHA256SUMS`, `SHA256SUMS.asc`,
`MANIFEST.md`, and `QUALIFICATION`. The frozen inventory and final asset array
must match exactly.

Neither `release/README.md` nor the per-release `release/vX.Y.Z/README.md` is
in that set. More importantly, `.github/workflows/release.yml:453-455` and
`:496-499` make `MANIFEST.md` the rendered GitHub Release body. **Someone who
opens the release — the exact person this document is about — lands on a 17 KB
provenance document rather than a start-here flashing procedure.** They do see
the basic `sha256sum` instruction, but not the signed-checksum trust bootstrap
or the selection and programming guidance from `release/README.md`.

### G2 — Flashing is buried inside a provenance document

`MANIFEST.md` is organised around proving where the bytes came from: source
commit, pinned toolchain versions, image table with digests, soak evidence,
reproduction instructions. Flashing is one section in the middle. That ordering
is right for an auditor and wrong for the flash-only user, who wants the
opposite emphasis.

### G3 — The command *shape* is duplicated and not yet defined consistently

The fuse bytes are single-sourced. The argv structure is not. Compare:

- `Makefile:1955-1959` defines `PIC10F322_PROG_CMD`.
- `scripts/make-release.sh:1612` independently writes
  `pk2cmd -PPIC10F322 -F$base -M -Y -R`.
- `release/README.md`'s "Flash a chip" section writes it a third time.

Change the recipe's flags and the manifest keeps confidently publishing the old
shape. Nothing detects it. The same applies to the ATtiny202 arm
(`make-release.sh:1636-1640` vs `Makefile:2475-2489`) and both classic-AVR arms.
For AVR the two paths are not merely duplicated: the Makefile executes separate
fuse and flash invocations, while the manifest prints one combined `avrdude`
invocation. There is no single argv to expose until the intended programming
operation is defined.

This is the duplication that actually matters, and it is worth being precise
about it: the risk is not that a *value* goes stale — that is already solved —
but that a *command* does.

### G4 — Published commands are templates, not pasteable commands

The current generated commands contain `<prog>`, `<port>` and `<v>`, and some
append literal `(or: make ...)` prose to the executable line. Angle brackets
are shell metacharacters and the parenthetical is shell syntax, not a comment.
Those lines are references for an informed developer, not safe copy/paste
instructions for the stated audience.

The missing inputs are real configuration, not only documentation omissions:

- USBtiny and USBasp can have complete classic-AVR profiles, but serial ISP
  programmers may also need a port and baud rate.
- A serial-UPDI adapter necessarily has a host-specific Linux, macOS or Windows
  port, and selecting the first detected serial device would be unsafe.
- PICkit 2 `pk2cmd` and PICkit 3/4/5 `ipecmd` use different command dialects.
- The default PIC10F322 command deliberately does not source target Vdd
  (`Makefile:1948-1950`), while the audience includes both bare chips and
  externally powered finished boards.

The guide must name the qualified profiles and their power assumptions rather
than imply that changing only `-c` makes every programmer interchangeable.

### G5 — The safety-critical guide would not be authenticated

`scripts/make-release.sh:1519-1529` writes `SHA256SUMS` over the HEX images
only, and `scripts/verify-release-images.sh:49-50` deliberately accepts only
`.hex` records. Adding `PROGRAMMING.md` to the publication array would not bind
its fuse values or commands to `SHA256SUMS.asc`. A substituted guide could
prescribe wrong fuse bytes while the selected image still verifies correctly.

Verification also does not match the one-image download path. `SHA256SUMS`
names all 21 images, so `sha256sum -c SHA256SUMS` reports the other 20 files as
missing when the user downloads only one HEX. `gpg --verify` additionally needs
the signing key, which is not in the current published asset set, and plain
signature validity does not itself enforce the documented pinned fingerprint.
macOS and Windows do not necessarily provide GNU `sha256sum` either.

### G6 — Coverage is not uniform, and cannot be made so

- **PIC10F320** has no `-program` goal at all. `release/README.md` documents
  the raw `pk2cmd` line and carries a name-contract exemption marker saying so.
- **PIC12F675** has no qualified direct-from-download workflow. This is not an
  oversight and is not something the flashing-simplicity work should try to
  paper over. Section 5 covers it in full.

Six of the seven parts can have a one-command path within supported programmer,
platform and power profiles. The seventh cannot today. A document that hides
that distinction would be optimising the metric instead of the goal.

## 4. Refined proposal

### 4.1 Define the supported profiles before generating commands

The first deliverable is a small, explicit support matrix, not code. For every
advertised profile it must state:

- MCU and programmer/backend;
- operating-system shell and any required port policy;
- whether the target must be externally powered or may be programmer-powered;
- the programmer/tool versions against which the command has been qualified;
- whether the command writes configuration/fuses as well as flash.

The first version should stay within the CLI audience already declared in §1.
USBtiny and USBasp for classic AVR and qualified `pk2cmd`/`ipecmd` PIC paths are
reasonable candidates; a profile should not be published merely because a tool
appears to support it. Serialupdi can claim a complete static profile only if
the OS-specific command discovers exactly one eligible port and fails on zero
or multiple matches. Otherwise ATtiny202 retains one explicit local input until
the interactive-helper phase. GUI screenshots for MPLAB IPE, Microchip Studio
and avrdudess are a separate documentation project, not a prerequisite for
improving the existing CLI path.

### 4.2 Fix the direction of truth: share a programming specification

First repair the AVR source-tree goals so the selected image is built and
validated before fuses or flash are touched. Then define shared Makefile
constructors for the programming operation: executable, common arguments,
part, port policy, fuse operations, image operand and verification flags. The
hardware recipe and release renderer should consume those constructors
directly. Neither should execute text printed by the other through `eval`.

Expose one bulk, machine-readable release record rather than a family of
arbitrary-path emitters. A record should be keyed by canonical release image and
programmer profile and should distinguish `direct` from `guarded`. One possible
interface, deliberately **not implemented yet**, is:

<!-- name-contract: exempt-begin (proposed goals; they deliberately do not
     exist yet, and this document is the proposal to create them) -->
```
make release-programming-records
make pic10f320-program
```
<!-- name-contract: exempt-end -->

The first goal is part of the release architecture. The second is only a
separate developer-convenience symmetry fix; because it would build from
source, it does not improve the flash-only path.

The release record must use immutable canonical profile defaults, distinct
from developer-overridable bench variables such as `AVR_PROGRAMMER` and
`XT_PROGRAMMER`. Release metadata queries must clear inherited `MAKEFLAGS`,
`MAKEFILES`, `MAKEOVERRIDES` and related ambient state, following the pattern in
`scripts/verify-release-images.sh:62-70`. A clean source tree must not produce
different published instructions because the release host exported a local
programmer preference.

For AVR, call the result a programming *operation* or shell command line, not a
single argv. Keeping fuse and flash operations separate and joining them with
`&&` is compatible with the one-command user goal and makes fail-stop ordering
explicit.

### 4.3 Generate `PROGRAMMING.md` as the release landing page

Promote the flashing content out of `MANIFEST.md` into a dedicated generated
file ordered for the flash-only user:

1. **Start here and stop conditions.** State the supported CLI/tool/power scope
   and put the PIC12F675 guarded-workflow warning before any generic matrix.
2. **Verify the download or bundle.** Provide complete Linux, macOS and Windows
   instructions, including key import, pinned-fingerprint policy and the exact
   selected-file or bundle check.
3. **Which image is mine?** Ask only for the exact MCU and switching circuit,
   then map that pair to one exact basename and release-asset link.
4. **Choose the programmer profile.** Each supported row contains a complete,
   pasteable command and a clear power assumption. No executable block may
   contain `<prog>`, `<port>`, `<v>` or appended prose.
5. **PIC12F675 guarded procedure.** Keep it visibly separate and publish no raw
   writer shortcut.

Generate the image matrix from `RELEASE_IMAGES`, but do not pretend that a list
of filenames contains the human meaning of `cd4053_simple`,
`cd4053_with_mute` and `tq2_l2_5v_relay`. Maintain a small keyed description
table and gate its MCU and output-stage keys for exact equality with the
supported sets.

Publish the frozen `PROGRAMMING.md` bytes as both an asset and the GitHub
Release body (`--notes-file`). Keep `MANIFEST.md` as the provenance asset and
link to it from the guide; leave a reciprocal pointer in the manifest. The user
should not have to discover the guide in a collapsed asset list.

The generated artifact itself is plain text and needs no build tool to read.
GNU Make and the cross-toolchains remain maintainer dependencies at release
generation time, not flash-only-user dependencies.

### 4.4 Authenticate and package the complete user payload

The programming guide is safety-critical release content and must be covered by
an independently verifiable signature. The cleanest user contract is one signed
checksum manifest covering every user-consumed payload while the release
verifier separately enforces that its `.hex` subset equals `RELEASE_IMAGES`.
That preserves the existing four-way image-set guarantee without leaving the
commands unauthenticated. It requires a two-phase generator: compute an
internal image hash map for rendering, render the documents, then write and
sign the final payload checksum list.

The release must also provide the public key and pinned full fingerprint
instructions. Supplying the key beside the signature helps installation but is
not an independent trust path; the guide must say that the fingerprint needs a
separately trusted source.

Make a deterministic cross-platform ZIP the primary download. It should contain
`PROGRAMMING.md`, all images, the signed checksum material and the public key.
One bundle removes asset-picking friction and makes a full checksum pass
meaningful because all 21 images are present. ZIP is preferable to `.tar.gz`
for this audience because Linux, macOS and Windows can all open it without an
additional archive tool. Keep raw HEX and metadata assets for advanced users
and auditors.

The archive does not remove the need to define its authentication boundary. Its
contents must either be covered by the signed internal payload inventory, with
an exact-content check, or the archive itself must have a detached signature.
That analysis belongs in the implementation design, but it is no longer a
reason to leave the archive unevaluated: the bundle directly advances the
primary objective and fixes the all-images checksum mismatch.

### 4.5 Gate behavior, not rendered text alone

The generated record and staged guide should have exact, fail-closed checks:

- the projection of direct records onto image keys equals `RELEASE_IMAGES`
  minus `PIC12F675_RELEASE_IMAGES`, with each required `(image, profile)` pair
  present exactly once;
- guarded keys equal `PIC12F675_RELEASE_IMAGES`, with no raw writer command;
- each command's image operand equals its record key rather than merely naming
  some member of `RELEASE_IMAGES`;
- no executable command contains an angle-bracket placeholder, developer
  `VARIANT` placeholder or un-commented prose;
- every generated goal reference exists in the Makefile used for that release;
- poisoned Make environment variables cannot change canonical release records;
- a failed source build reaches no hardware tool.

Do not use `make -n` as the principal command-equivalence oracle. The program
targets include build prerequisites, validation recipes, recursive Make output
and, for AVR, multiple programmer invocations; dry-run text also depends on
which artifacts already exist. Instead, put fake `avrdude`, `pk2cmd` and
`ipecmd` executables on `PATH`, execute the real programming surface against
them, capture the actual argument vector, and compare it with the canonical
record. This tests what the operating system receives rather than Make's
diagnostic rendering.

`test/test_makefile_name_contract.py` remains useful for live documents, but it
deliberately excludes immutable `release/vX.Y.Z/` artifacts
(`test/test_makefile_name_contract.py:873-877`). The release generator must
therefore validate goal references in the staged guide directly.

### 4.6 Alternatives and scope decisions

**A static "typical programming commands" section in the top-level `README.md`**
remains rejected. It cannot be per-release-accurate, and nothing gates it. The
`v0.9.8` rename invalidated every image name and most goal names in one release;
a static section would have silently survived that.

**Publishing the existing per-release README as an interim fix** is also not
worth doing. It points to a repository-relative parent document that is absent
when downloaded alone, presents checksum verification before later saying the
signature is required first, and contains no image-selection or programming
procedure. Making `PROGRAMMING.md` the release body solves the actual
discoverability problem rather than adding another pointer.

**A generated flashing helper** was deferred here, not categorically rejected.
An executable being signed is not itself a defect, and a helper can print the
exact command and require confirmation before touching silicon. The real costs
are downloaded-code trust, Bash/PowerShell portability, dependency burden, port
and programmer detection ambiguity, and a larger test matrix. Never select the
first serial device silently. If literal zero-substitution remains the
acceptance criterion after the static profile guide ships, a fail-closed,
display-and-confirm helper is the only realistic next step.

**Update (v0.9.10).** One shipped, for exactly one part, and the scope is what
kept the costs above bounded. `scripts/flash-pic12f675.py` is staged into every
release bundle and listed in its signed `SHA256SUMS`, so downloaded-code trust
rides on the same signature as the images; it is Python 3 standard library only,
so there is no portability fork and no dependency burden; and it detects nothing
— part, tool and power arrangement are fixed constants it REFUSES to have moved,
and the programmer path is an explicit argument. The test matrix is one gate,
`test-pic12f675-flash-helper`, driven against a stateful fake `ipecmd`. It is
not the general-purpose helper this section deferred: it exists because §5 makes
this one part a case where a command is the wrong instruction, and the same
reasoning does not extend to the other six.

**GUI programming instructions** are deferred. The audience in §1 already has
the CLI programming tool installed. Screenshot-level GUI guidance can be added
later without blocking the narrower path.

## 5. The PIC12F675 caveat

This part is the one place where pursuing a direct-from-download path carelessly
can destroy a user's device. The full reasoning follows, because "just use the
guarded workflow" is not a rationale anyone can act on or challenge.

**Read this section as the analysis that produced the answer, not as the current
state.** It was written while there was no qualified no-compiler path at all, so
its present tense describes `v0.9.9`. From `v0.9.10` there is one:
`scripts/flash-pic12f675.py`, §5.5's sketch built as a standalone
transaction. The marked updates below say which reasoning each part of it
settles.
What has NOT changed is the hazard in 5.1 or the honest limit in 5.4: the
programmer's real erase behaviour is still unqualified on silicon.

### 5.1 What is physically different about this part

The PIC12F675 carries **two per-device factory-trimmed values that live in the
memory a programmer erases**:

- **The oscillator calibration word** — a `RETLW` at word `0x3FF`, the last
  word of flash. The device pack declares it as the `.oscval` CalDataZone, and
  XC8's startup code emits a literal `call 0x3ff` expecting it to be present.
  `docs/pic12f675_feasibility.md` §4.5, "Fixed 4 MHz INTOSC, and the OSCCAL
  calibration word", records what happens without it,
  observed during the port spike: the program counter ran off the end of flash
  (`increment PC=0x400 == memory size 0x400`), the part watchdog-reset, and did
  so *in a loop* — `main()` was never reached.
- **`BG<1:0>` in the CONFIG word** — factory-calibrated bandgap bits setting the
  BOD/POR trip voltages. The shipping image emits the erased `0b11` encoding
  (CONFIG `0x31CC`), deliberately leaving the field alone rather than writing a
  value of its own over the factory one.

Every other part in this repository has a fully compile-time-known
configuration, so a correct HEX plus a writer is sufficient. Here the correct
HEX is necessary but **not** sufficient, because the write operation itself can
destroy device state the firmware depends on.

### 5.2 Why the failure mode is uniquely dangerous

The outcomes depend on how the trim is damaged, and both are unacceptable. An
erased or malformed calibration word can produce the observed run-off and
watchdog-reset loop before `main()`. A wrong but syntactically valid `RETLW`
value can allow startup to return and load an incorrect oscillator calibration;
the device may then appear to switch while running with the wrong tick cadence
and wrong `__delay_ms()` relay coil-pulse widths. Losing `BG<1:0>` can likewise
leave an apparently functional device with the wrong brown-out and
power-on-reset thresholds. The dangerous cases are either immediate failure or
plausible operation with a silent hardware error, not one universal symptom.

That is why the workflow is a **transaction** — read-only baseline, compare the
live device immediately before the write, mandatory post-write readback — and
not a command. `pic12f675-preflight` captures the baseline; the program targets
require the same values immediately before and after.

### 5.3 Why the downloaded HEX specifically is not admitted

Three separate reasons, and only the first concerns the file's trustworthiness.

**1. A lookalike hazard this port created itself.** The gpsim lanes cannot run
the shipping image at all, for the same `call 0x3ff` reason. The build
therefore produces *derived* images with a fabricated calibration word injected
at `0x3FF` (`test/pic/inject_calibration_word.py`), landing under
`PIC12F675_SIMCAL_DIR` (`Makefile:6104`). Those are same-family filenames one
directory below the shipping images, and writing one destroys the factory trim
*by construction*. Every image entering the writer must therefore pass
`--assert-preserves-calibration` (`Makefile:7213`) — word `0x3FF` unprogrammed
**and** the startup call present — plus a CONFIG decode that must emit exactly
`word=0x31CC`.

**2. Chain of custody between "checked" and "written".** The guarantee the
target makes is that the bytes it verified are the bytes the programmer
consumed. It builds into a private temporary directory (`Makefile:7178`),
snapshots to a `chmod 400` file, hashes it, runs the calibration and CONFIG
checkers against *that snapshot*, re-verifies the digest is unchanged, and hands
that same path to the writer. The guarded workflow also rejects the two
override names a user would reach for first — an image path and a whole
programmer command — because either could separate checked bytes from consumed
bytes (`Makefile:6970`). An arbitrary downloaded file has no binding into that
chain.

**3. What the release check actually proves.**
`scripts/verify-release-program-image.sh image` accepts a candidate path and
proves that candidate matches the signed release set — tag signature, detached
`SHA256SUMS.asc` signature, and a full canonical-set match. The verifier does
not itself know whether the candidate came from a build or a download. The
current Make target supplies a freshly built private snapshot, and that caller
establishes the build provenance and custody chain. No current caller admits a
downloaded file into the programming transaction.

So the position is **not** "the prebuilt PIC12F675 HEX is suspect". It is
byte-identical and reproducible, and release CI proves that on every release.
The position was that no *no-compiler path into the transaction* had been
designed or gated yet.

**Update (v0.9.10).** One has been. `scripts/flash-pic12f675.py` ships inside
the release bundle and admits the downloaded HEX by binding it to that bundle
rather than to a build: the image must be listed in the signed `SHA256SUMS`
beside it with a matching digest, and the accepted bytes are snapshotted into
the evidence directory and hashed before any check runs, so the same custody
property reason 2 describes is established without a compiler. Reason 1 is
answered by the helper carrying its own copy of the calibration and CONFIG
policy — an image programming word `0x3FF`, writing EEPROM, a user ID or the
device ID word, or carrying a CONFIG word other than `0x31CC` is refused before
an erase argument exists — which is what makes the derived `PIC12F675_SIMCAL_DIR`
images unwritable through it. The `make pic12f675-release-program` transaction
described above keeps its own, stronger job: binding a PRIVATE FRESH BUILD to a
signed tag, which is a provenance claim a downloaded file cannot make and the
helper does not attempt.

### 5.4 The honest limit of what the guarded workflow proves

None of this establishes that `pk2cmd` or `ipecmd` actually preserves the trim.
That is items 1 and 2 of `docs/pic12f675_feasibility.md` §8, "Open risks and
unknowns", both still
open, both silicon-only, tracked for the `1.x.y` hardware pass as `TODO.md`
`T3-pic12f675-bench`. The transaction *measures and retains* the programmer's
behaviour; it does not guarantee the outcome. A FAIL is detected only after the
write, and may already have damaged the device. No `ipecmd` hardware procedure
is qualified at all: its software-tested route would additionally require a
`pk2cmd` reader before and after the write, and no safe dual-programmer
attachment or handoff has been validated.

### 5.5 A no-compiler path may be reachable

*(Written before one existed. It does now; the update at the end of this section
records what the sketch got right and what it got wrong.)*

Worth recording, because it bears directly on the primary goal.

Examining what the checks actually need: the calibration check and the CONFIG
check both operate on the HEX bytes themselves and would work identically on a
downloaded file. The only thing the rebuild supplies is the assurance that the
bytes came from tested source — which a verified signature over `SHA256SUMS`
plus a digest match arguably supplies just as strongly, and which is exactly
what release CI already attests.

A transaction that admitted a downloaded HEX by verifying it against the signed
checksum list *inside* the same snapshot / hash / custody discipline would drop
XC8 and the device pack entirely. Sketch:

1. Snapshot the selected download immediately to a private read-only file, as
   the current target does; every subsequent check and the writer use that path.
2. Verify `SHA256SUMS.asc` against the pinned key, via the existing
   `scripts/verify-release-signature.sh`.
3. Verify the snapshot's digest against the verified `SHA256SUMS`.
4. Run the calibration checker and CONFIG checker against the snapshot.
5. Re-verify the snapshot hash, then proceed into the unchanged baseline /
   pre-write compare / write / readback transaction.

**Be honest about what this does and does not buy.** It removes by far the
heaviest dependency — a Microchip compiler and device pack — but the current
repository-local pieces still require `git`, `gpg`, `python3`, `sha256sum`, GNU
Make, the programmer/reader tools, and a host C compiler for the CONFIG checker.
So the first PIC12F675 improvement would move from "needs the full PIC
toolchain" to "needs a clone plus common development tools", not to "download
and run one command". A later packaged transaction helper could remove some of
those organisational dependencies, but only after preserving and testing the
same end-to-end custody properties.

That is still a large improvement, and it would let the part appear in the
generated programming document as a real procedure rather than an exception.
It has not been designed or gated, and it must not be attempted by loosening
the existing guards piecemeal — the custody chain in §5.3 is the property that
has to be preserved end to end.

**Update (v0.9.10): designed, gated, and shipped — as a program, not a Make
target.** `scripts/flash-pic12f675.py` implements steps 1, 3, 4 and 5 of the
sketch above directly, and it did preserve the custody chain rather than loosen
it: the accepted bytes are snapshotted into the evidence directory before any
check runs, and the writer consumes that snapshot. Two things the sketch
predicted turned out differently.

*The dependency estimate was wrong, and in the good direction.* The sketch
concluded the first improvement would move from "needs the full PIC toolchain"
to "needs a clone plus common development tools", not to "download and run one
command", because it assumed the transaction would stay a Make target reusing
repository-local checkers. Rewriting the calibration and CONFIG policy as ~40
lines of Python inside the tool removed `git`, GNU Make, `sha256sum`, a host C
compiler and the clone along with XC8 and the device pack. What remains is
Python 3 and the operator's own `ipecmd`. So the part does now appear in the
generated programming document as a real procedure.

*Step 2 is not what the helper does.* The sketch had the transaction verify
`SHA256SUMS.asc` itself with `scripts/verify-release-signature.sh`, which is
repository-local and pins a key. A tool that ships inside the bundle cannot
verify that bundle's signature without also shipping the trust root, and a trust
root distributed with the thing it authenticates proves nothing. The helper
therefore REQUIRES the detached signature to be present beside the manifest --
so the instruction "verify it first" is actionable and its absence is a refusal
-- and leaves verifying it to the operator and `gpg`. That is a deliberate
narrowing of the sketch, not an omission.

The part of §5.4 that this does not touch is the whole of it: none of this
establishes what a real PICkit 3 erase does to the trim.

## 6. The tension, resolved

Six parts can have a one-command direct path within each explicitly supported
programmer, platform and power profile. The seventh has one command too, from
`v0.9.10`, but it is a different command: a guarded transaction with an evidence
directory, not a writer invocation. That distinction is the whole point, and the
temptation in either direction should still be named so it can be refused:

- **Do not degrade the six to match the seventh.** Wrapping every part in a
  guarded transaction because one part needs it would spend the whole
  simplicity budget on a hazard six parts do not have.
- **Do not dress the seventh up to match the six.** Publishing a plausible
  `pk2cmd` one-liner for the PIC12F675 would optimise the appearance of the
  goal while exposing users to a silent, permanent device fault.

The generated document should therefore be structured so that the easy path is
genuinely easy and the exception is unmissable — which is roughly what
`make-release.sh:1622` already does by emitting an empty `flashcmd` for the
part rather than inventing one.

## 7. Suggested sequencing

Use the smallest *safe* increments. The command source and its behavioral gate
land together; the guide and its authentication land together.

1. **Define the acceptance contract and support matrix.** Decide the exact
   programmer/backend, operating-system and power profiles that may claim a
   pasteable command. State that GUI instructions are out of initial scope.
2. **Repair build-before-hardware semantics.** Make every source-tree program
   target build and validate before either fuse or flash side effects, and
   choose the canonical AVR operation shape. *Done in `v0.9.10` for the AVR
   goals, gated by `make test-avr-program-order`; see the update in §1. The
   canonical AVR operation shape is still an open choice — the repair kept fuses
   and flash as two ordered `avrdude` invocations rather than settling it.*
3. **Add shared command constructors and the bulk release record.** Add the
   exact-set, environment-poisoning and fake-programmer argv tests in the same
   change. Do not publish a new command surface before its gate exists.
4. **Generate and authenticate `PROGRAMMING.md`.** Validate the staged result,
   include it in the signed payload boundary, publish it as an asset, and use
   the same frozen bytes as the GitHub Release body.
5. **Publish the deterministic ZIP as the primary download.** Keep raw assets,
   test archive reproducibility and exact contents, and give each supported OS
   a complete verification path.
6. **Add `pic10f320-program` if desired.** This removes a developer-interface
   asymmetry and the live-document name exemption, but is not on the critical
   path for the flash-only user.
7. **Evaluate the PIC12F675 no-compiler path** (§5.5) as a separate `TODO.md`
   item. It is the only item here that changes a safety-critical transaction and
   must remain subordinate to hardware qualification. *Done in `v0.9.10` as
   `scripts/flash-pic12f675.py`, and it stayed subordinate: the bench run it
   needs is an outstanding controlled run in `HARDWARE_VALIDATION_LOG.md`, and
   the tool, `FLASHING.md` and this document all say a PASS means "no damage was
   observed on this device", not "this writer preserves calibration".*

## 8. Decisions and remaining questions

The analysis resolves several earlier questions:

- **Initial scope is CLI.** GUI documentation can follow independently.
- **A deterministic ZIP is worth doing.** It directly reduces downloads and
  fixes whole-list verification for a user who would otherwise choose one HEX.
- **`PROGRAMMING.md` is generated only into `release/vX.Y.Z/`.** Keep the
  renderer, a deterministic preview command and rendered-output tests at HEAD;
  do not commit a second mutable "current release" copy that can drift.
- **Publishing the existing README alone is not a useful stopping point.** It
  does not solve discoverability, pasteability, authentication or selection.
- **A helper is deferred, not forbidden.** Revisit it only if the profile-based
  static guide fails the measured simplicity goal or literal zero-substitution
  remains mandatory. *Revisited for one part in `v0.9.10` on neither of those
  triggers: §5 makes the PIC12F675 a case where a command is the wrong
  instruction regardless of how simple the guide gets. The general-purpose,
  detecting, multi-part helper this bullet defers is still deferred; nothing in
  `flash-pic12f675.py` detects anything or serves another part.*

Implementation still has concrete decisions to make: the exact qualified tool
versions and programmer/power profiles, the machine-readable record format,
whether the signed boundary is a complete payload checksum list or an archive
signature, and the cross-platform verification commands. Those decisions
should be made against real programmer behavior and testability, not by adding
more placeholders to the generated prose.
