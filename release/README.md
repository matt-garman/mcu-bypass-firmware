# Prebuilt firmware images

This directory holds **prebuilt firmware images** so you can use this firmware
without installing a cross-compiler or building anything. Images are
ready-to-flash unless a historical safety warning here or in their per-release
documentation marks them as superseded. Each release lives in its own
`vX.Y.Z/` subdirectory and is also published as a
[GitHub Release](../../releases).

> **Current availability:** committed releases stop at `v0.9.5` and contain no
> PIC10F320 image. The PIC10F320 is integrated in the source tree, but its first
> unified prebuilt release remains pending fresh full-tool qualification and the
> release run.

## Safety warning: v0.9.0-v0.9.2 TMUX images

The `bypass_cd4053_tmux*.hex` and `bypass_mute_tmux*.hex` images in releases
`v0.9.0`, `v0.9.1`, and `v0.9.2` encode an incorrect direct-drive control
polarity. With the associated TMUX4053 board pull-down contract, an absent or
undriven MCU therefore selects ENGAGED instead of the intended fail-safe
BYPASS state.

These images are retained only for historical integrity and reproducibility.
**Do not select or flash them for new TMUX4053 hardware.** Use release `v0.9.3`
or later and choose the standard `bypass_cd4053*.hex` or `bypass_mute*.hex`
image for the target MCU, without `_tmux` in the filename. Those unified images
support both CD4053 and TMUX4053 boards with fail-safe BYPASS polarity. See the
[`v0.9.3` correction](../CHANGELOG.md#093---2026-07-11).

The current Makefile's product set for the pending unified release covers AVR
Classic (ATtiny13a/45/85), PIC10F322 and PIC10F320. ATtiny202 is a
development-only target: its normal CI artifacts are not ready-to-flash release
assets and are intentionally absent here.

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
   and its validation evidence. A machine-readable `QUALIFICATION` record is
   checked against the exact retained-evidence inventory and every soak log
   before publication; each log must identify its canonical combination and
   report the configured duration, expected nonzero liveness-check count, and
   zero failure counters. The current unified pipeline requires
   `make test-long`, both PIC10F322 gates (`make pic-test` and
   `make pic-test-target-variants`), both PIC10F320 gates (`make pic320-test` and
   `make pic320-test-target-variants`), and a **24-hour soak of every release
   soak combination**. Those PIC10F320 requirements begin with its pending first
   unified release; historical manifests describe the smaller target set they
   actually shipped. Because the gates are long-running, release orchestration
   rechecks both the recorded source `HEAD` and worktree cleanliness immediately
   before staging artifacts. Only explicitly non-publishable dry runs may proceed
   from a dirty tree.

   The signed version tag points to a dedicated release-artifact commit. Tag CI
   requires that commit to have exactly one parent, equal to the source commit in
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

## Which image do I want?

Images are named `bypass_<variant>[_<mcu>].hex`:

| variant | switching hardware |
|---|---|
| `cd4053` | CD4053 / TMUX4053 analog switch, simple (2 sections) |
| `mute`   | CD4053 / TMUX4053 with mute-before-switch (3 sections) |
| `relay`  | Panasonic TQ2-L2-5V latching relay |

| name suffix | target MCU |
|---|---|
| *(none)* | ATtiny13a (primary), 1.2 MHz |
| `_t85` | ATtiny85, 1.0 MHz |
| `_t45` | ATtiny45, 1.0 MHz |
| `_pic10f322` | Microchip PIC10F322, 2 MHz (HFINTOSC) |
| `_pic10f320` | Microchip PIC10F320, 2 MHz (HFINTOSC) |

The PIC10F320 images are the one exception to the naming scheme above: they are
called `bypass_mcu_<variant>_pic10f320.hex`, with a different prefix and the
variant names `cd4053-simple`, `cd4053-mute` and `tq2-relay`. Those names are
inherited from the separate project that target was merged from and were kept
deliberately, so previously published image names stay valid. **Match images to
MCUs by the suffix table and by `MANIFEST.md`, never by prefix.**

There is no ATtiny202 suffix because that development-only target is not part
of the prebuilt release set.

The per-release `MANIFEST.md` lists every image with its MCU, clock, flash
usage, fuse bytes, and exact flashing command.

## Verify a download

```sh
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
        -U flash:w:bypass_cd4053.hex:i
```

If you have the source tree, the Makefile does both steps for you:
`make program VARIANT=<variant>` (ATtiny13a) or `make program85 VARIANT=<variant>`
(ATtiny85), etc.

**PIC10F322** — the CONFIG word is embedded in the HEX, so writing the HEX
configures the device; there is no separate fuse step:

```sh
pk2cmd -PPIC10F322 -Fbypass_cd4053_pic10f322.hex -M -Y -R      # PICkit 2
# or, from the source tree: make program-pic VARIANT=<variant>
```

**PIC10F320** — same story; the CONFIG word is embedded in the HEX:

```sh
pk2cmd -PPIC10F320 -Fbypass_mcu_cd4053-simple_pic10f320.hex -M -Y -R   # PICkit 2
```

There is no `make program-pic320` convenience target yet; flash it with the
programmer command above.

## Reproduce the images bit-for-bit

A freshly built release HEX lands under `build_avr_classic/`, `build_pic/` and
`build_pic10f320/`, not in the release directory, so run the checksum list
against those fresh bytes — running it from the repo root would only re-verify the committed copies
against themselves. The omission of `build_avr_xt/` is intentional because
ATtiny202 is not release-supported.

```sh
git checkout vX.Y.Z
# install the pinned toolchain (see TOOLCHAIN.adoc), then:
scripts/verify-release-qualification.sh release/vX.Y.Z vX.Y.Z
make clean && make all13 all85 all45 && make pic && make pic320-variants
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

Note that the canonical set describes **the release you checked out**. Verify an
older release from its own tag, as the block above does — running the current
verifier against, say, `release/v0.9.4/` from a newer checkout correctly reports
a mismatch, because that release predates targets the current set includes. That
is a statement about which release you are looking at, not a defect in the old
one.

For tags predating `scripts/verify-release-images.sh`, use their original
hash-only check with an absolute checksum path:

```sh
repo=$PWD
tmp=$(mktemp -d)
cp build_avr_classic/*.hex build_pic/*.hex "$tmp"/
( cd "$tmp" && sha256sum -c "$repo/release/vX.Y.Z/SHA256SUMS" )
```
