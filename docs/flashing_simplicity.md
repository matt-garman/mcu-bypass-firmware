# Flashing simplicity — getting a release image onto hardware

**Status:** analysis and proposal. **Nothing here is implemented.** This
document records a design discussion held on 2026-08-21 on branch
`v0.9.9-polish`, so that the reasoning survives the conversation and does not
have to be rebuilt from scratch.

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

They do **not** have, and must not be required to obtain:

- `avr-gcc`, `binutils-avr`, or the vendored ATtiny device pack,
- Microchip XC8 or a PIC device pack,
- `simavr`, `gpsim`, `yasimavr`, `cppcheck`, `cbmc`, or any test dependency,
- necessarily even a clone of this repository.

For this person, "painless" has a concrete definition worth holding the design
to: **read one file, run one command per chip, with no substitutions to work
out for themselves.** Every placeholder they must resolve — `<prog>`, `<port>`,
which of 21 images is theirs — is friction, and friction here is measured
against a hobbyist at a bench with a soldering iron in the other hand.

The existing per-part `-program` goals do not serve this person. They are
developer conveniences: `attiny13a-program` (`Makefile:2762`),
`pic10f322-program` (`Makefile:1967`) and `attiny202-program`
(`Makefile:2489`) all *build first*, which pulls in the entire cross-toolchain
for that part. That is correct for a developer at a bench and useless for
someone who only wants the bytes on the chip.

## 2. Current state, measured

The good news is that the architecture for solving this is already in the tree,
and it is the right one.

`scripts/make-release.sh:1585-1664` generates a per-image **Flashing** section
into each release's `MANIFEST.md` at release time. Critically, it does not
hand-copy the values: `mkv()` at `scripts/make-release.sh:272` is
`make -s --no-print-directory print-<VAR>`, so the fuse bytes
(`ATTINY13A_LFUSE`, `ATTINY13A_HFUSE`, `TINYX5_LFUSE`, `TINYX5_HFUSE`, and the
seven ATtiny202 memories from `XT_FUSE_WDTCFG` through `XT_FUSE_BOOTEND`), the
avrdude part names, the default programmer, and the image basenames all come
from Makefile truth at generation time. The result is visible at
`release/v0.9.9/MANIFEST.md:87-150`.

So "generate a per-release programming document from the Makefile at release
time" is not a new idea to propose. It is the established pattern, and
extending it is far cheaper and lower-risk than adding a hand-maintained
document that would immediately become a duplicate.

There is also good prose in `release/README.md` ("Flash a chip", "Which image
do I want?", "Verify a download") and a short per-release `README.md` carrying
the `sha256sum -c` step.

## 3. What blocks "painless" today

### G1 — The audience never receives the document written for them

`.github/workflows/release.yml:348` fixes the published asset set to the image
files plus `SHA256SUMS`, `SHA256SUMS.asc`, `MANIFEST.md` and `QUALIFICATION`
(and `RENAME_IDENTITY.md` where applicable). The copy into the publish stage
(`:357`) and the final asset array (`:453`) match it.

Neither `release/README.md` nor the per-release `release/vX.Y.Z/README.md` is
in that set. **Someone who downloads from GitHub Releases — the exact person
this document is about — receives a 17 KB provenance document and no
instruction to verify the bytes before writing them.** This is the single
largest gap, and it is also the cheapest to close.

### G2 — Flashing is buried inside a provenance document

`MANIFEST.md` is organised around proving where the bytes came from: source
commit, pinned toolchain versions, image table with digests, soak evidence,
reproduction instructions. Flashing is one section in the middle. That ordering
is right for an auditor and wrong for the flash-only user, who wants the
opposite emphasis.

### G3 — The command *shape* is duplicated, even though the values are not

The fuse bytes are single-sourced. The argv structure is not. Compare:

- `Makefile:1955-1959` defines `PIC10F322_PROG_CMD`.
- `scripts/make-release.sh:1612` independently writes
  `pk2cmd -PPIC10F322 -F$base -M -Y -R`.
- `release/README.md`'s "Flash a chip" section writes it a third time.

Change the recipe's flags and the manifest keeps confidently publishing the old
shape. Nothing detects it. The same applies to the ATtiny202 arm
(`make-release.sh:1636-1640` vs `Makefile:2475-2489`) and both classic-AVR arms.

This is the duplication that actually matters, and it is worth being precise
about it: the risk is not that a *value* goes stale — that is already solved —
but that a *command* does.

### G4 — Coverage is not uniform, and cannot be made so

- **PIC10F320** has no `-program` goal at all. `release/README.md` documents
  the raw `pk2cmd` line and carries a name-contract exemption marker saying so.
- **PIC12F675** cannot be flashed from a downloaded HEX at all, by design.
  This is not an oversight and is not something the flashing-simplicity work
  should try to paper over. Section 5 covers it in full.

Six of the seven parts can be made genuinely one-command. The seventh cannot,
today. A document that hides that distinction would be optimising the metric
instead of the goal.

## 4. Proposal

### 4.1 Fix the direction of truth: let the Makefile emit the argv

Rather than have `make-release.sh` reconstruct commands, add command-printing
emitters to the Makefile that print exactly the argv the corresponding recipe
would execute, accepting an image-path parameter so the release generator can
point them at release basenames instead of `build_*` paths. The recipe and the
generated document then consume one emitter.

Proposed goal spellings, which deliberately **do not exist yet** — this
document is the proposal for them:

<!-- name-contract: exempt-begin (proposed goals; they deliberately do not
     exist yet, and this document is the proposal to create them) -->
```
make attiny13a-program-command
make pic10f322-program-command
make pic10f320-program
```
<!-- name-contract: exempt-end -->

This also delivers, for free, the "Makefile targets that just print the
command" idea considered as a standalone option — but as a *byproduct* of
single-sourcing rather than as a fourth place to keep the same string.

### 4.2 Generate a per-release `PROGRAMMING.md`, and publish it

Promote the flashing content out of `MANIFEST.md` into a dedicated generated
file, ordered for the flash-only user:

1. **Verify first.** `gpg --verify SHA256SUMS.asc SHA256SUMS`, then
   `sha256sum -c SHA256SUMS`. Currently this instruction reaches nobody who
   downloads assets.
2. **Which image is mine?** The MCU × output-stage table, reproduced from
   `RELEASE_IMAGES` rather than retyped.
3. **One command per image**, emitted per section 4.1.
4. **Resolve the placeholders for them.** `-c <prog>` is currently unexplained.
   List the common programmer values (`usbtiny`, `usbasp`, `avrisp2`,
   `stk500v1`) and, for the ATtiny202, what `XT_UPDI_PORT` looks like on Linux,
   macOS and Windows. This is a small change with a large share of the
   real-world friction behind it.
5. **The PIC12F675 exception**, stated plainly and early enough that nobody
   reaches for a raw writer command.

Then add it to all three asset lists in `.github/workflows/release.yml` (`:348`,
`:357`, `:453`). Leave a pointer in `MANIFEST.md` so the auditor path still
works.

The dependency question the discussion started from resolves itself here. The
*generated artifact* has zero dependencies — it is plain text sitting beside
the hex files. GNU Make is a dependency only for the maintainer, at release
time, on a host that by definition already has the full toolchain installed.

### 4.3 Gate it, or it is only a nicer copy

Two checks turn this from a convenience into something that fits the project's
stated bar:

- At release time, assert every filename appearing in a generated command is a
  member of `RELEASE_IMAGES`, and every make goal named in the document exists.
- As a host test, compare each emitter's output against a `make -n` dry run of
  the corresponding program target, so the printed command and the executed
  command cannot diverge.

`test/test_makefile_name_contract.py` already polices goal names appearing in
documents; the exemption marker sitting over the absent `pic10f320-program` in
`release/README.md` is exactly the kind of drift that should be repaired rather
than annotated.

### 4.4 Considered and rejected

**A static "typical programming commands" section in the top-level `README.md`.**
It cannot be per-release-accurate, and nothing gates it. The `v0.9.8` rename
invalidated every image name and most goal names in one release; a static
section would have silently survived that.

**Shipping a generated `flash.sh` in the release.** More convenient, and
tempting against a simplicity goal. Rejected on two grounds: it places an
executable inside a signed artifact set, and it runs against the posture the
PIC12F675 work established, which is that a human should see the command before
silicon is touched. A printed command that the user copies keeps the operator in
the loop. This is a genuine cost to the simplicity goal, accepted knowingly.

**A single downloadable archive per release** (one `.tar.gz` instead of
picking assets individually) is *not* rejected — it is unevaluated. It would
measurably reduce steps for the flash-only user, but it changes what the
detached signature covers, so it needs its own analysis before adoption.

## 5. The PIC12F675 caveat

This part is the one place where flashing simplicity is not achievable today,
and where pursuing it carelessly can destroy a user's device. The full
reasoning follows, because "just use the guarded workflow" is not a rationale
anyone can act on or challenge.

### 5.1 What is physically different about this part

The PIC12F675 carries **two per-device factory-trimmed values that live in the
memory a programmer erases**:

- **The oscillator calibration word** — a `RETLW` at word `0x3FF`, the last
  word of flash. The device pack declares it as the `.oscval` CalDataZone, and
  XC8's startup code emits a literal `call 0x3ff` expecting it to be present.
  `docs/pic12f675_feasibility.md:700` (§4.5) records what happens without it,
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

It is silent. A device that loses its calibration word still boots and still
switches — it simply runs at an untrimmed oscillator, which on this design
means the wrong tick cadence and the wrong `__delay_ms()` relay coil-pulse
widths. Losing `BG<1:0>` means the wrong brown-out and power-on-reset
thresholds. Nothing announces itself; the pedal appears to work.

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
`scripts/verify-release-program-image.sh image` does not bless the downloaded
HEX. It takes the *freshly built candidate* and proves it reproduces the signed
release set — tag signature, detached `SHA256SUMS.asc` signature, and a full
canonical-set match. The signed digest confirms that the local build reproduces
the release; it is not an admission ticket for a download.

So the position is **not** "the prebuilt PIC12F675 HEX is suspect". It is
byte-identical and reproducible, and release CI proves that on every release.
The position is that no *no-compiler path into the transaction* has been
designed or gated yet, which is what `release/README.md`'s safety-exception
paragraph says.

### 5.4 The honest limit of what the guarded workflow proves

None of this establishes that `pk2cmd` or `ipecmd` actually preserves the trim.
That is items 1 and 2 of `docs/pic12f675_feasibility.md:1094` (§8), both still
open, both silicon-only, tracked for the `1.x.y` hardware pass as `TODO.md`
`T3-pic12f675-bench`. The transaction *measures and retains* the programmer's
behaviour; it does not guarantee the outcome. A FAIL is detected only after the
write, and may already have damaged the device. No `ipecmd` hardware procedure
is qualified at all: its software-tested route would additionally require a
`pk2cmd` reader before and after the write, and no safe dual-programmer
attachment or handoff has been validated.

### 5.5 A no-compiler path may be reachable

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

1. Verify `SHA256SUMS.asc` against the pinned key, via the existing
   `scripts/verify-release-signature.sh`.
2. Verify the downloaded HEX's digest against the verified `SHA256SUMS`.
3. Snapshot to a private read-only file and hash it, as the current target does.
4. Run the calibration checker and CONFIG checker against the snapshot.
5. Proceed into the unchanged baseline / pre-write compare / write / readback
   transaction.

**Be honest about what this does and does not buy.** It removes by far the
heaviest dependency — a Microchip compiler and device pack — but it does not
reach zero dependencies: `git`, `gpg`, `python3` and GNU Make are all still
required, because the checkers and the signature policy live in the repository.
So the PIC12F675 would move from "needs the full PIC toolchain" to "needs a
clone plus common tools", not to "download and run one command".

That is still a large improvement, and it would let the part appear in the
generated programming document as a real procedure rather than an exception.
It has not been designed or gated, and it must not be attempted by loosening
the existing guards piecemeal — the custody chain in §5.3 is the property that
has to be preserved end to end.

## 6. The tension, resolved

Six parts can be made genuinely one-command. The seventh cannot. The temptation
in either direction should be named so it can be refused:

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

Smallest useful change first; each step is independently shippable.

1. **Publish what already exists.** Add the per-release `README.md` (or a
   pointer to `release/README.md`'s flashing prose) to the asset lists in
   `.github/workflows/release.yml`. Closes G1, the largest gap, at near-zero
   cost and with no new generator.
2. **Resolve the placeholders.** Add the programmer-name and UPDI-port guidance
   to the generated flashing section. Highest friction reduction per line
   changed.
3. **Add the argv emitters** (§4.1) and switch `make-release.sh` to consume
   them. Closes G3.
4. **Split out `PROGRAMMING.md`** and publish it (§4.2). Closes G2.
5. **Add the drift gates** (§4.3).
6. **Close G4's first half:** add a `pic10f320` programming goal so the
   name-contract exemption can be removed.
7. **Evaluate the PIC12F675 no-compiler path** (§5.5) as a separate `TODO.md`
   item. It is the largest piece of work here and the only one that touches a
   safety-critical transaction.

## 8. Open questions

- **GUI programmers.** A meaningful share of hobbyists use MPLAB IPE,
  Microchip Studio or avrdudess rather than a CLI. A document containing only
  Linux command lines is not "painless" for them. Does the goal extend to
  screenshot-level GUI guidance, or is CLI the declared scope?
- **Single-archive downloads** (§4.4) — worth the signing-scope analysis?
- **Where should `PROGRAMMING.md` live in the repository** between releases:
  generated only into `release/vX.Y.Z/`, or also rendered at HEAD so that the
  content is reviewable on `main` without cutting a release?
- **Does step 1 alone satisfy the goal well enough** to defer steps 3-5? The
  project's standing preference at a fork like this — take the smallest change
  that works now and file the clean redesign as a `TODO.md` item — argues for
  shipping 1 and 2, then re-measuring the friction before building the
  generator.
