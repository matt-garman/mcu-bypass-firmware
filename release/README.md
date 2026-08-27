# Prebuilt firmware images

This directory holds **prebuilt firmware images** so you can use this firmware
without installing a cross-compiler or building anything. Images are
ready-to-flash unless a historical safety warning here or in their per-release
documentation marks them as superseded. Each release lives in its own
`vX.Y.Z/` subdirectory and is also published as a
[GitHub Release](https://github.com/matt-garman/mcu-bypass-firmware/releases).

PIC12F675 is the safety exception: do not pass its downloaded HEX directly to a
writer. Its per-device factory OSCCAL word and CONFIG `BG<1:0>` trim live in
memory a programmer erases, so every write goes through a guarded transaction.
From `v0.9.10` that transaction has a no-compiler path: each bundle also ships
`flash-pic12f675.py`, covered by the same signed `SHA256SUMS` as the images, and
it runs the whole transaction on Python 3 plus MPLAB X 6.20 `ipecmd` -- no
source checkout, no XC8, no device pack. Pass the downloaded HEX to that helper,
never to `ipecmd`. `make pic12f675-release-program` remains the development and
release-provenance path, and it is the one that needs the toolchain and a clean
tagged checkout, because it binds a private fresh build to a signed tag.

From `v0.9.10`, PIC12F675 release qualification runs its pre-hardware and target
aggregates in one Make graph against one retained matrix. The release evidence
keeps the combined aggregate log and the complete twelve-artifact matrix JSON;
`QUALIFICATION` and `MANIFEST.md` bind that JSON's digest to the final three
shipped HEX files and their `SHA256SUMS` entries.

<!-- current-release:start -->
> **Current release contract:** `v0.9.10`; seven release parts; 21 images; 18 soak combinations; six modular targets; four shell source files.
> The images cover three output stages; PIC10F320 is the self-contained target.
<!-- current-release:end -->

`v0.9.6` was the first unified 18-image release and introduced the first
ATtiny202 and PIC10F320 images in this release line.

## v0.9.9 tag-local documentation erratum

The immutable signed `v0.9.9` tag's `MANIFEST.md` links to the tag-local
`docs/pic10f320_special_case.md`, whose opening current-status prose still names
`v0.9.8` and the pre-PIC12F675 topology. The signed release metadata itself
correctly records 21 images and 18 soak combinations. The tag and its release
artifacts remain unchanged; this HEAD documentation corrects the live status
without moving or rewriting the signed tag.

## v0.9.9 retained fault-evidence watchdog-note erratum

The retained PIC12F675 fault evidence
(`release/v0.9.9/evidence/pic12f675-test-target-variants.log`) prints the
PIC10F32x watchdog note (`gpsim WDT@WDTPS=0x08 ~1.057s ... 256ms silicon`) for
the PIC12F675 lane. That part has no `WDTCON`; at `OPTION_REG=0x0C` gpsim models
an approximately 288 ms watchdog and the datasheet floor is 160 ms. The note is
descriptive only -- the fault gate asserts that a recovery reset occurs within a
deliberately generous window, never a watchdog period -- so the recorded PASS is
unaffected. HEAD corrects the live harness to emit each part's own note; the
signed `v0.9.9` tag and its retained evidence remain unchanged and are not
rewritten.

## Safety warning: v0.9.0-v0.9.2 TMUX images

The `bypass_cd4053_tmux*.hex` and `bypass_mute_tmux*.hex` images in releases
`v0.9.0`, `v0.9.1`, and `v0.9.2` encode an incorrect direct-drive control
polarity. With the associated TMUX4053 board pull-down contract, an absent or
undriven MCU therefore selects ENGAGED instead of the intended fail-safe
BYPASS state.

These images are retained only for historical integrity and reproducibility.
**Do not select or flash them for new TMUX4053 hardware.** Use release `v0.9.3`
or later and choose the standard CD4053 image for the target MCU, without
`_tmux` in the filename (`bypass_cd4053*.hex` / `bypass_mute*.hex` in the
`v0.9.3`-`v0.9.7` naming; `bypass-<mcu>-cd4053_simple.hex` /
`bypass-<mcu>-cd4053_with_mute.hex` from `v0.9.8`). Those unified images
support both CD4053 and TMUX4053 boards with fail-safe BYPASS polarity. See the
[`v0.9.3` correction](../CHANGELOG.md#093---2026-07-11).

## Historical soak wording erratum: v0.9.0-v0.9.4

The provenance summary in each of these historical manifests says "24.0-h
parallel soak of every variant x MCU." That wording is broader than the retained
evidence and should be read as "24.0-h parallel soak of every release soak
combination." The historical release snapshots remain unchanged.

In particular, the ATtiny13a images were not soaked directly because simavr
cannot model their watchdog reset. They were covered by `make test-long` and the
soaks of the core-identical tinyx5 family, as each manifest's limitation note
below its image table explains: [`v0.9.0`](v0.9.0/MANIFEST.md#images),
[`v0.9.1`](v0.9.1/MANIFEST.md#images), [`v0.9.2`](v0.9.2/MANIFEST.md#images),
[`v0.9.3`](v0.9.3/MANIFEST.md#images), and
[`v0.9.4`](v0.9.4/MANIFEST.md#images).

The current Makefile's canonical product set is AVR Classic (ATtiny13a/45/85),
ATtiny202 (AVR-XT), PIC10F322, PIC10F320 and — release-supported from `v0.9.9` —
PIC12F675. Unified releases `v0.9.6`–`v0.9.8` shipped the six pre-PIC12F675
targets only.

That set is not a description of whatever a build happened to produce — it is
declared once in the Makefile as `RELEASE_IMAGES` and enforced. The verifier
below fails unless the committed directory, the `SHA256SUMS` entries, and the
freshly built images each match it exactly, so a release missing an entire MCU
cannot pass by having three internally consistent but incomplete sets.

If you would rather build from source, ignore this directory and see the
top-level [README](../README.md) and [TOOLCHAIN.adoc](../TOOLCHAIN.adoc).

## Why you can trust these binaries

The same philosophy that backs the source — an extensive, multi-engine test and
validation suite — backs these binaries, through two mechanisms:

1. **Provenance.** Every release carries a `MANIFEST.md` recording the exact
   source commit, pinned toolchain versions, per-image fuse bytes / CONFIG word,
   and its validation evidence. Beginning with `v0.9.6`, a machine-readable
   `QUALIFICATION` record is checked
   against that release's exact retained-evidence inventory (35 files from
   `v0.9.10`, 34 in `v0.9.9`, 28 in `v0.9.6`–`v0.9.8`) and every one of its soak logs (18 from
   `v0.9.9`, 15 before the PIC12F675 graduated) before publication; each log must
   identify its canonical
   combination and report the configured duration, expected nonzero
   liveness-check count, and zero failure counters. The current unified pipeline
   requires `make test-long`, both ATtiny202 gates (`make attiny202-test` and
   `make attiny202-test-target`), both PIC10F322 gates (`make pic10f322-test` and
   `make pic10f322-test-target-variants`), both PIC10F320 gates (`make pic10f320-test` and
   `make pic10f320-test-target-variants`), both PIC12F675 gates (`make pic12f675-test` and
   `make pic12f675-test-target-variants`), and a **24-hour soak of every release
   soak combination**. Releases `v0.9.0` through `v0.9.5` predate
   `QUALIFICATION` and use the manifest/evidence contract recorded in their own
   tags; they must not be judged against the later `QUALIFICATION` inventories.
   Because the gates are long-running, release orchestration
   rechecks both the recorded source `HEAD` and worktree cleanliness immediately
   before staging artifacts. Only explicitly non-publishable dry runs may proceed
   from a dirty tree.

   The signed version tag points to a dedicated release-artifact commit. Tag CI
   fetches the exact remote annotated-tag object and verifies its OpenPGP
   signature against [`release/signing-key.asc`](signing-key.asc) and the pinned
   full fingerprint `6184219C6670945D7174F2B0149F042FCC3D3AEC`. It also requires
   that commit to have exactly one parent, equal to the source commit in
   `QUALIFICATION`, and to change only `release/<version>/`. Changelog and status
   documentation must therefore be finalized and committed before starting the
   production qualification run.

   Release tags must be protected from update and deletion by the repository's
   tag rules. The workflow compares the remote tag's peeled target with the
   verified release commit immediately before publication; protection closes the
   unavoidable interval between that check and GitHub's separate create-release
   API operation.

2. **Reproducibility.** The Intel-HEX images are byte-deterministic for a fixed
   toolchain — `objcopy` ihex output contains only the program's code/data
   bytes, with no embedded timestamps or build paths. `SHA256SUMS` pins those
   bytes. When the release tag is pushed, CI
   ([`.github/workflows/release.yml`](../.github/workflows/release.yml)) rebuilds
   the images from the tagged source on a clean runner and **fails the release
   unless the image sets and exact hashes reproduce**. That check is the public
   attestation that *these binaries are exactly what the tested source compiles
   to* — you do not have to take the maintainer's word for it, and you can run
   the same check yourself (see "Reproduce" below).

`SHA256SUMS` is also signed (`SHA256SUMS.asc`), and the release tag is a signed
git tag, so you can additionally verify the maintainer vouched for the bytes.
Publication fails if either signature is absent, invalid, or made by another
key; verification uses an isolated keyring containing only the pinned key rather
than trusting whatever keys happen to be installed on the CI runner.

## How a release is sequenced

A release is not one commit. Four steps produce it, in this order, and the
separation between the first and the third is enforced rather than conventional.

1. **Source finalization.** One ordinary commit on `main` finalizes
   [`CHANGELOG.md`](../CHANGELOG.md) and the four bounded current-release
   declarations — this file, [`TODO.md`](../TODO.md),
   [`docs/pic10f320_special_case.md`](../docs/pic10f320_special_case.md) and
   [`docs/pic10f320_validation.md`](../docs/pic10f320_validation.md) — for
   `vX.Y.Z`. This commit is the **source contract**, and it is the commit the
   qualification run measures.
2. **Production staging.** `scripts/make-release.sh vX.Y.Z` builds every image,
   runs every gate, soaks every combination for 24 hours, and stages
   `release/vX.Y.Z/`. It refuses to start unless step 1 is already committed,
   and it stages without committing anything. Before handing off it re-checks
   the bounded declarations against the inventory it actually staged, so "21
   images; 18 soak combinations" is verified against 21 files and 18 soak
   records rather than against the Makefile that predicted them.
3. **Artifact commit.** One commit whose sole parent is the qualified source
   commit and which changes only `release/vX.Y.Z/`.
4. **Signed tag and push.** The annotated tag names the artifact commit; tag CI
   rebuilds from it and publishes only if the image bytes reproduce. A bare
   `vX.Y.Z` tag publishes as an ordinary GitHub release; an accepted suffixed
   tag (`vX.Y.Z-rc.1`) publishes as a **prerelease**, so a candidate can never
   become the latest release. A tag outside that grammar is rejected before any
   build, and again before publication.

Steps 1 and 3 cannot be collapsed into one commit:
`scripts/verify-release-history.sh` rejects a release whose qualified source
commit already contains `release/vX.Y.Z/QUALIFICATION`. The source tree that
*declares* a release therefore never contains that release's retained evidence,
and the two identities stay distinct: the **source commit** is what was
qualified, the **artifact commit** is what the tag publishes.

**The pre-tag window.** Between steps 1 and 4, `main` carries the `vX.Y.Z`
contract while `release/vX.Y.Z/` is unpublished. That window is intended and is
bounded by the qualification run. Two things keep it honest:

- The bounded declarations are written to be true throughout it. They state the
  source contract, and where they name the release directory they carry a fixed
  pre-tag transition line recording that the release cut creates it. Release
  preflight rejects a declaration that names any *other* release directory this
  tree does not contain.
- **If the release is abandoned or postponed, the source-finalization commit is
  reverted or corrected on `main`.** A `vX.Y.Z` declaration must never stand on
  `main` with no `vX.Y.Z` tag in prospect.

## Which image do I want?

**From `v0.9.8` onward** every image is named the same way, with three
hyphen-separated fields (words inside a field use underscores):

```
bypass-<mcu>-<output stage>.hex
bypass-attiny85-cd4053_with_mute.hex
```

| `<mcu>` | target MCU |
|---|---|
| `attiny13a` | ATtiny13a (primary), 1.2 MHz |
| `attiny85` | ATtiny85, 1.0 MHz |
| `attiny45` | ATtiny45, 1.0 MHz |
| `attiny202` | ATtiny202, 2 MHz (AVR-XT, UPDI) |
| `pic10f322` | Microchip PIC10F322, 2 MHz (HFINTOSC) |
| `pic10f320` | Microchip PIC10F320, 2 MHz (HFINTOSC) |
| `pic12f675` | Microchip PIC12F675, 4 MHz (INTOSC, factory OSCCAL) |

| `<output stage>` | switching hardware |
|---|---|
| `cd4053_simple` | CD4053 / TMUX4053 analog switch, simple (2 sections) |
| `cd4053_with_mute` | CD4053 / TMUX4053 with mute-before-switch (3 sections) |
| `tq2_l2_5v_relay` | Panasonic TQ2-L2-5V latching relay |

From `v0.9.9`, every combination exists, so a release is exactly 7 x 3 = 21
images. `v0.9.8` uses the same naming scheme for its six targets and 18 images.

ATtiny202 images are the only AVR images **not** programmed over ISP: the
ATtiny202 uses UPDI, and its fuses are seven individually named AVR8X memories
rather than the classic `lfuse`/`hfuse` pair. `MANIFEST.md` lists all seven per
image and gives the exact `avrdude` command.

**PIC12F675 — use the guarded transaction below for every write.** Unlike every
other part here, the PIC12F675 carries two per-device factory-trimmed values that
its firmware and reset behaviour depend on and that a careless programming step
can destroy silently: the oscillator calibration word (a `RETLW` at the top of
flash, word `0x3FF`) and the `BG<1:0>` bandgap bits in the CONFIG word. A device
that loses either **still appears to work** — it just runs at the wrong clock
(wrong tick cadence, wrong relay coil-pulse widths) or with the wrong
brown-out/POR trip voltages.

The shipping image leaves word `0x3FF` unprogrammed and requires the BG field to
remain erased. That is necessary but does not prove what a real programmer does
during erase/write. The guarded workflow captures a read-only baseline, compares
the live device immediately before writing, and records mandatory post-write
OSCCAL, BG, identity, CONFIG, and programmed-byte results. A failure is detected
only after the write and may already have damaged the device. Do not substitute
a raw `pk2cmd` or `ipecmd` writer command. Real preservation and actual ipecmd
operation remain hardware-unvalidated until the `1.x.y` bench pass; see
`docs/pic12f675_feasibility.md` section 8, items 1 and 2.

There are **two** guarded paths, and which one applies depends on what you have.
Programming a downloaded release needs neither a source checkout nor the
firmware development toolchain: from `v0.9.10` every release bundle also ships
`flash-pic12f675.py`, listed in that release's signed `SHA256SUMS` like an
image, and it runs the same transaction using only Python 3 and MPLAB X 6.20
`ipecmd`. The `make pic12f675-release-program` transaction further down is the
developer and release-provenance path: it rebuilds the image privately and binds
it to a signed tag, which is why it needs the toolchain, a clean tagged checkout,
and a pk2cmd reader.

### Renamed in v0.9.8 (`v0.9.7` and earlier used different names)

<!-- name-contract: exempt-begin (old->new upgrade guidance and redirect tables;
     old names deliberately no longer exist) -->
**Upgrading an existing checkout:** If this worktree was used to build `v0.9.7`
or earlier, after updating to `v0.9.8` or later run `make clean` once before
building. If the old build used custom build directories, reuse each old path
under the current variable name: `AVR_BUILD_DIR` and `XT_BUILD_DIR` are unchanged;
the path formerly passed as `PIC_BUILD_DIR` is now passed as
`PIC10F322_BUILD_DIR`, and the old `PIC320_BUILD_DIR` path is now passed as
`PIC10F320_BUILD_DIR`. The renamed build targets create the current image names
but do not remove differently named images left by an older build; without the
one-time clean, retired and current image names can coexist in the same build
directory.

Releases up to and including `v0.9.7` used three inconsistent conventions, and
the ATtiny13a images carried **no MCU field at all** — a bare `bypass_cd4053.hex`
was the ATtiny13a image. Nothing in that filename stopped it being flashed onto
an ATtiny85 at the wrong clock. The MCU field is now mandatory on every image.

Historical release directories are **not** renamed: their `SHA256SUMS` names the
files and is covered by a detached signature, so renaming them would invalidate
the published signatures. Use this table to map an old name to its replacement.

| up to `v0.9.7` | from `v0.9.8` |
|---|---|
| `bypass_cd4053.hex` | `bypass-attiny13a-cd4053_simple.hex` |
| `bypass_mute.hex` | `bypass-attiny13a-cd4053_with_mute.hex` |
| `bypass_relay.hex` | `bypass-attiny13a-tq2_l2_5v_relay.hex` |
| `bypass_<v>_t85.hex` | `bypass-attiny85-<stage>.hex` |
| `bypass_<v>_t45.hex` | `bypass-attiny45-<stage>.hex` |
| `bypass_<v>_attiny202.hex` | `bypass-attiny202-<stage>.hex` |
| `bypass_<v>_pic10f322.hex` | `bypass-pic10f322-<stage>.hex` |
| `bypass_mcu_cd4053-simple_pic10f320.hex` | `bypass-pic10f320-cd4053_simple.hex` |
| `bypass_mcu_cd4053-mute_pic10f320.hex` | `bypass-pic10f320-cd4053_with_mute.hex` |
| `bypass_mcu_tq2-relay_pic10f320.hex` | `bypass-pic10f320-tq2_l2_5v_relay.hex` |

where old `<v>` `cd4053`/`mute`/`relay` maps to `<stage>`
`cd4053_simple`/`cd4053_with_mute`/`tq2_l2_5v_relay`. The rename itself does not
change image contents. Seventeen `v0.9.8` images are therefore required to be
bit-identical to their `v0.9.7` counterparts. The one exception is the
PIC10F320 relay image, which also adds the `v0.9.8` idle coil-latch safety
correction and is required to differ:

`bypass-pic10f320-tq2_l2_5v_relay.hex` reasserts both relay-coil outputs low on
every serviced iteration. The exact new bytes remain pinned by the PIC10F320
expected-image manifest and the release checksum manifest.

The historical release retains the checked result in
`release/v0.9.8/RENAME_IDENTITY.md`, listing both digests and the verdict for
every image. Its tag-local one-shot verifier required exactly 17 identities and
the named relay-image difference, with no missing, added, or other changed
image. The signed `v0.9.8` tag preserves that verifier and contract; current
releases use the standing canonical reproduction and expected-image checks.

**The build commands moved too.** Every make goal that acts on one part now
carries that part's name, in the same vocabulary as the image field, so an
older `MANIFEST.md` may name a goal that no longer exists:

| up to `v0.9.7` | from `v0.9.8` |
|---|---|
| `make all13` / `all85` / `all45` | `make attiny13a` / `attiny85` / `attiny45` |
| `make size` / `size85` | `make attiny13a-size` / `attiny85-size` |
| `make fuses` / `flash` / `program` | `make attiny13a-fuses` / `-flash` / `-program` |
| `make program85` | `make attiny85-program` |
| `make pic` / `pic-test` | `make pic10f322` / `pic10f322-test` |
| `make program-pic` | `make pic10f322-program` |
| `make pic320-*` | `make pic10f320-*` |
| `make test-sim` / `test-sim-t85` | `make test-sim-attiny13a` / `test-sim-attiny85` |
<!-- name-contract: exempt-end -->

`make all` also changed meaning: it used to build the ATtiny13a images only,
and now builds every part (lanes whose cross-toolchain is not installed skip
with a message). `attiny202-*` goals were already part-named and did not move.

The per-release `MANIFEST.md` lists every image with its MCU, clock, flash usage,
and fuse/config bytes. It gives exact per-image commands where a direct write is
qualified; PIC12F675 instead carries the mandatory guarded transaction below.

## Verify a download

```sh
# import the checked-in key, then compare the full fingerprint with the value
# printed above through an independently trusted copy of this documentation
gpg --import release/signing-key.asc
gpg --fingerprint 6184219C6670945D7174F2B0149F042FCC3D3AEC

# from the repository root, enforce the same pinned-key policy as release CI
scripts/verify-release-signature.sh detached \
    release/vX.Y.Z/SHA256SUMS.asc release/vX.Y.Z/SHA256SUMS

cd release/vX.Y.Z

# (recommended) verify the maintainer's signature over the checksums
gpg --verify SHA256SUMS.asc SHA256SUMS

# verify the image bytes
sha256sum -c SHA256SUMS
```

## Flash a chip

**AVR (ATtiny13a / 45 / 85)** — the design requires the correct *fuse bytes* in
addition to the flash write; both are in `MANIFEST.md` per image. With an ISP
programmer (e.g. USBtiny/USBasp) and `avrdude`:

```sh
# ATtiny13a example (fuse bytes from MANIFEST.md): lfuse=0x4a hfuse=0xf9
avrdude -c usbtiny -p t13 \
        -U lfuse:w:0x4a:m -U hfuse:w:0xf9:m \
        -U flash:w:bypass-attiny13a-cd4053_simple.hex:i
```

If you have the source tree, the Makefile does both steps for you, in one
ordered transaction — it builds and validates the image first, then writes the
fuses, then flashes, so a failed build reaches no programmer at all:
`make attiny13a-program VARIANT=<variant>` (ATtiny13a) or
`make attiny85-program VARIANT=<variant>` (ATtiny85), etc. `<variant>` is the output-stage name from the table above —
`cd4053_simple`, `cd4053_with_mute` or `tq2_l2_5v_relay` — the same string that
appears in the image filename. (Through `v0.9.7` these were spelled `cd4053`,
`mute` and `relay`, and the PIC10F320 lane used `cd4053-simple`, `cd4053-mute`
and `tq2-relay`; all six spellings were retired in `v0.9.8`.)

**PIC10F322** — the CONFIG word is embedded in the HEX, so writing the HEX
configures the device; there is no separate fuse step:

```sh
pk2cmd -PPIC10F322 -Fbypass-pic10f322-cd4053_simple.hex -M -Y -R   # PICkit 2
# or, from the source tree: make pic10f322-program VARIANT=<variant>
```

**PIC10F320** — same story; the CONFIG word is embedded in the HEX:

```sh
pk2cmd -PPIC10F320 -Fbypass-pic10f320-cd4053_simple.hex -M -Y -R   # PICkit 2
```

There is no `make pic10f320-program` convenience target yet; <!-- name-contract: exempt (documents an absent goal) --> flash it with the
programmer command above.

**PIC12F675** — do not issue a raw writer command; this part is not a raw write
target. The board must be externally powered in both paths below.

*Programming the downloaded image* (no source checkout, no build toolchain):
pass the release HEX to this release's `flash-pic12f675.py`, never to `ipecmd`.
The helper is identified by its released name and its bytes in the signed
`SHA256SUMS`, not by where the file sits, so a byte-identical copy works from
anywhere and an edited or renamed one is refused wherever it lives. It needs
Linux, Python 3 and MPLAB X 6.20 `ipecmd`, and a NEW evidence directory per
device. Linux is required because the helper hands `ipecmd` its own open
descriptors rather than pathnames a third process could re-point between the
check and the write. Images, JARs and script launchers use private sealed copies
of the validated bytes. Native ELF launchers preserve origin-relative library
lookup by using the retained source descriptor only when the operator neither
owns nor can write that inode; an operator-mutable native launcher is refused.
Thus rewriting an existing operator-owned source inode cannot change what the
child consumes. If the required descriptor paths, immutable source, sealable
anonymous files or seals are unavailable, the helper fails closed.
The helper's `ipecmd` route is published and software-tested, but it is not
hardware-qualified.

```sh
python3 flash-pic12f675.py program \
  --image bypass-pic12f675-cd4053_simple.hex \
  --ipecmd /opt/microchip/mplabx/v6.20/mplab_platform/mplab_ipe/ipecmd.jar \
  --evidence-dir ./pic12f675-device-001
```

It validates the image against this directory's signed `SHA256SUMS`, refuses an
image that programs word `0x3FF` or moves the CONFIG BG field, pins the tool to
MPLAB X 6.20, reads the device twice before reserving the write, performs exactly
one write, and compares the WHOLE device afterwards -- every word the image does
not supply has to read back erased, so a writer that skipped its bulk erase is a
FAIL rather than a PASS. It then publishes one immutable `result.json`, written
under a temporary name and installed atomically. Evidence creation, attachment,
cleanup, parent flush and device exports all use retained directory descriptors,
so parent-path replacement cannot redirect or make the transaction durable in a
different directory. An interruption leaves a recoverable PENDING transaction
rather than a truncated record. A PENDING directory
(reservation, no result) is resolved read-only with
`python3 flash-pic12f675.py finalize --evidence-dir ... --ipecmd ...`, which
never constructs a writer argument. Full details are in `FLASHING.md`.

*Programming from a source checkout of this release's tag* (the development and
release-provenance path). For each device, choose new baseline and result paths
whose parent directory already exists. `pic12f675-preflight` is read-only and
does not take `VARIANT`; only program after it succeeds, using the same baseline:

```sh
# Replace with the intended release tag containing pic12f675-release-program.
release_tag=vX.Y.Z &&
repo=$(git rev-parse --show-toplevel) &&
head_commit=$(git -C "$repo" rev-parse --verify "HEAD^{commit}") &&
tag_commit=$(git -C "$repo" rev-parse --verify \
  "refs/tags/$release_tag^{commit}") &&
worktree_status=$(git -C "$repo" status --porcelain=v1 --untracked-files=normal) &&
test "$head_commit" = "$tag_commit" && test -z "$worktree_status" &&
evidence_root=$(dirname "$repo") &&
baseline="$evidence_root/pic12f675-factory-baseline.json" &&
result="$evidence_root/pic12f675-program-result" &&
test ! -e "$baseline" && test ! -e "$result" &&
make -C "$repo" pic12f675-preflight \
  PIC12F675_READ_PROG=pk2cmd \
  PIC12F675_TRIM_EVIDENCE="$baseline" &&
make -C "$repo" pic12f675-release-program \
  VARIANT=cd4053_simple \
  PIC12F675_RELEASE_TAG="$release_tag" \
  PIC12F675_PROG=pk2cmd PIC12F675_PROG_KIND=pk2cmd \
  PIC12F675_READ_PROG=pk2cmd \
  PIC12F675_TRIM_EVIDENCE="$baseline" \
  PIC12F675_BENCH_RESULT="$result"
```

If an interruption leaves `reservation.json` but no `result.json`, the
transaction is **PENDING**. Keep physical custody of the same attached device;
do not write, reflash, capture a new baseline, or reuse the result path. From the
same release checkout, resolve it with the same release identity, variant, and
tool identities:

```sh
make -C "$repo" pic12f675-finalize \
  VARIANT=cd4053_simple \
  PIC12F675_RELEASE_TAG="$release_tag" \
  PIC12F675_PROG=pk2cmd PIC12F675_PROG_KIND=pk2cmd \
  PIC12F675_READ_PROG=pk2cmd \
  PIC12F675_TRIM_EVIDENCE="$baseline" \
  PIC12F675_BENCH_RESULT="$result"
```

Finalization never invokes writer arguments. It revalidates the selected release
identity, the reservation, and the separately retained image first, verifies the
reader version before a full-device read, and exclusively publishes the recovered
PASS/FAIL `result.json`. Private read attempts are retry-safe after interruption.
A FAIL is a resolved forensic record, not permission to retry the write. An
existing result is immutable.

Replace `cd4053_simple` with `cd4053_with_mute` or `tq2_l2_5v_relay` when
needed. A baseline belongs to one device before its first write; do not reuse it
for another device or a later reflash.

The immutable `v0.9.9` tag predates `pic12f675-release-program`; this target
protects release tags that contain it and is generated into their manifests.

Transient full-device reads and the private programming build use `TMPDIR` when
set, otherwise `XDG_RUNTIME_DIR`, otherwise `HOME`. The selected root must
already exist, be owned by the current user, grant no group/other access, and
have only current-user- or root-owned, non-group/other-writable ancestors;
shared `/tmp` and `/var/tmp` roots are rejected. Its path may contain letters,
digits, spaces, `/`, `.`, `_`, and `-`. Only the explicitly requested baseline
and result paths survive normal, failed, or handled-interruption cleanup.

Run the transaction from a clean checkout of this release's annotated tag with
the pinned XC8/DFP toolchain. The release target verifies the pinned tag and
`SHA256SUMS` signatures, validates the complete signed release image set, and
requires the private fresh-build snapshot to match the selected signed digest.
It does not consume the downloaded HEX in this directory. Baseline and result
paths are outside the worktree so the target can recheck exact source cleanliness
immediately before and after the build. The retained PASS/FAIL result checks and
records the before/after values; it does not convert untested programmer behavior
into a preservation guarantee.

No ipecmd hardware procedure is qualified. The software-tested route requires
pk2cmd reads immediately before and after the IPE write, but no safe
dual-programmer attachment or handoff has been validated. Do not infer one from
the internal `PIC12F675_PROG_KIND=ipecmd` routing until the `1.x.y` bench pass
publishes the required hardware setup and retained result.

## Reproduce the images bit-for-bit

### Unified releases (v0.9.9 or later)

A freshly built release HEX lands under `build_avr_classic/`, `build_avr_xt/`,
`build_pic10f322/`, `build_pic10f320/`, and `build_pic12f675/`, not in the release
directory, so run the checksum list against those fresh bytes — running it from
the repo root would only re-verify the committed copies against themselves.

```sh
git checkout vX.Y.Z
# install the pinned toolchain (see TOOLCHAIN.adoc), then:
scripts/verify-release-qualification.sh release/vX.Y.Z vX.Y.Z
make clean && make attiny13a attiny85 attiny45 && make attiny202
make pic10f322 && make pic10f320-variants && make pic12f675
scripts/verify-release-images.sh release/vX.Y.Z $(make -s print-RELEASE_IMAGE_DIRS)
```

The qualification verifier checks the retained local validation and 24-hour
soak evidence. The image verifier resolves symlink aliases to physical directory paths and rejects
both committed-as-fresh reuse and duplicate fresh directories. It copies
`SHA256SUMS`, the committed images, and all fresh images into private storage
before comparing sets or bytes, so later source mutations cannot contaminate
the checksum phase. A passing verifier proves those three private snapshots are
the same set with byte-identical contents **and** that the set is the canonical
`RELEASE_IMAGES` one — the fourth comparison is what makes the other three mean
"complete" rather than merely "consistent".

Byte-exact reproduction requires the same `avr-gcc` and `binutils-avr` versions,
plus the target-qualified XC8 compiler and DFP recorded for each PIC family in
the manifest. A different toolchain may produce functionally identical but not
byte-identical images.

### Unified release v0.9.8

The same naming and verifier contract applies, but this historical release has
the six-target, 18-image set and no PIC12F675 build directory. Use its tree's
four fresh roots and build commands:

```sh
git checkout v0.9.8
scripts/verify-release-qualification.sh release/v0.9.8 v0.9.8
make clean && make attiny13a attiny85 attiny45 && make attiny202
make pic10f322 && make pic10f320-variants
scripts/verify-release-images.sh release/v0.9.8 $(make -s print-RELEASE_IMAGE_DIRS)
```

### Unified releases v0.9.6 and v0.9.7

Same 18-image contract and the same two verifiers; only the build goals are
spelled differently, because `v0.9.8` renamed them (see
[Renamed in v0.9.8](#renamed-in-v098-v097-and-earlier-used-different-names)).
Use the names that exist in the tree you check out:

```sh
git checkout vX.Y.Z          # v0.9.6 or v0.9.7
# name-contract: exempt-begin (pinned to an older tag: these goals are
# correct in THAT tree and deliberately absent from this one)
# install the pinned toolchain (see TOOLCHAIN.adoc), then:
scripts/verify-release-qualification.sh release/vX.Y.Z vX.Y.Z
make clean && make all13 all85 all45 && make attiny202
make pic && make pic320-variants
# name-contract: exempt-end
scripts/verify-release-images.sh release/vX.Y.Z $(make -s print-RELEASE_IMAGE_DIRS)
```

`git checkout` moves the whole tree together — Makefile, `RELEASE_IMAGES`,
`SHA256SUMS` and both verifier scripts — so nothing here is a workaround and
the guarantees are exactly those described above.

Do **not** mix trees. Running the *current* `scripts/verify-release-images.sh`
against `release/v0.9.6/` or `release/v0.9.7/` reports a canonical-set mismatch,
because those directories name their images under the pre-`v0.9.8` scheme while
the current Makefile's `RELEASE_IMAGES` names them under the new one. That is the
naming boundary reporting itself, not a defect in either release — the same
situation, and the same correct answer, as the `v0.9.4` case described next.

### Historical releases (v0.9.0 through v0.9.5)

These releases have no `QUALIFICATION`, and their image matrices and Make targets
predate the unified 18-image command above. Do not run the current qualification
verifier or append `pic10f320-variants` to a historical build command. For
`v0.9.3` through `v0.9.5`, check out the release's own tag and follow the
**Reproducing these images** section in that release's `MANIFEST.md`. Running the
current verifier against, for example, `release/v0.9.4/` correctly reports a
mismatch. That describes which contract the release used, not a defect in the
old release.

The `v0.9.0` through `v0.9.2` manifests predate
`scripts/verify-release-images.sh`, and their final checksum command has a broken
repository-root-relative path. Use their documented build command, then replace
their checksum command with this corrected isolated check:

```sh
repo=$PWD
tmp=$(mktemp -d)
cp build_avr_classic/*.hex build_pic10f322/*.hex "$tmp"/
( cd "$tmp" && sha256sum -c "$repo/release/vX.Y.Z/SHA256SUMS" )
```
