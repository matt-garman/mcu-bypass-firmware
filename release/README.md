# Prebuilt firmware images

This directory holds **prebuilt firmware images** so you can use this firmware
without installing a cross-compiler or building anything. Images are
ready-to-flash unless a historical safety warning here or in their per-release
documentation marks them as superseded. Each release lives in its own
`vX.Y.Z/` subdirectory and is also published as a
[GitHub Release](../../releases).

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

The release product set covers AVR Classic (ATtiny13a/45/85) and PIC10F322.
ATtiny202 is a development-only target: its normal CI artifacts are not
ready-to-flash release assets and are intentionally absent here.

If you would rather build from source, ignore this directory and see the
top-level [README](../README.md) and [TOOLCHAIN.adoc](../TOOLCHAIN.adoc).

## Why you can trust these binaries

The same philosophy that backs the source — an extensive, multi-engine test and
validation suite — backs these binaries, through two mechanisms:

1. **Provenance.** Every release carries a `MANIFEST.md` recording the exact
   source commit, the pinned toolchain versions, the per-image fuse bytes /
   CONFIG word, and the validation evidence: `make test-long` (the exhaustive
   AVR suite + mutation testing), `make pic-test` (PIC CONFIG-word + static
   analysis + gpsim functional), `make pic-test-target-variants` (fail-closed
   PIC libgpsim fault, lock-step, and target-I/O validation), and a **24-hour
   soak of every release soak combination** (logs under `evidence/`). Because
   those gates are long-running, release orchestration rechecks both the recorded
   source `HEAD` and worktree cleanliness immediately before staging artifacts.
   Only explicitly non-publishable dry runs may proceed from a dirty tree.

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

## Reproduce the images bit-for-bit

A freshly built release HEX lands under `build_avr_classic/` and `build_pic/`,
not in the release directory, so run the checksum list against those fresh
bytes — running it from the repo root would only re-verify the committed copies
against themselves. The omission of `build_avr_xt/` is intentional because
ATtiny202 is not release-supported.

```sh
git checkout vX.Y.Z
# install the pinned toolchain (see TOOLCHAIN.adoc), then:
make clean && make all13 all85 all45 && make pic
scripts/verify-release-images.sh release/vX.Y.Z build_avr_classic build_pic
```

The verifier resolves symlink aliases to physical directory paths and rejects
both committed-as-fresh reuse and duplicate fresh directories. It copies
`SHA256SUMS`, the committed images, and all fresh images into private storage
before comparing sets or bytes, so later source mutations cannot contaminate
the checksum phase. A passing verifier proves those three private snapshots are
the same complete set with byte-identical contents.

Byte-exact reproduction requires the *same* `avr-gcc` **and**
`binutils-avr` versions recorded in the manifest; a different toolchain may
produce functionally identical but not byte-identical images.

For tags predating `scripts/verify-release-images.sh`, use their original
hash-only check with an absolute checksum path:

```sh
repo=$PWD
tmp=$(mktemp -d)
cp build_avr_classic/*.hex build_pic/*.hex "$tmp"/
( cd "$tmp" && sha256sum -c "$repo/release/vX.Y.Z/SHA256SUMS" )
```
