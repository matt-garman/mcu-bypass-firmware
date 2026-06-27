# Prebuilt firmware images

This directory holds **prebuilt, ready-to-flash firmware images** so you can use
this firmware without installing a cross-compiler or building anything. Each
release lives in its own `vX.Y.Z/` subdirectory and is also published as a
[GitHub Release](../../releases).

If you would rather build from source, ignore this directory and see the
top-level [README](../README.md) and [TOOLCHAIN.adoc](../TOOLCHAIN.adoc).

## Why you can trust these binaries

The same philosophy that backs the source — an extensive, multi-engine test and
validation suite — backs these binaries, through two mechanisms:

1. **Provenance.** Every release carries a `MANIFEST.md` recording the exact
   source commit, the pinned toolchain versions, the per-image fuse bytes /
   CONFIG word, and the validation evidence: `make test-long` (the exhaustive
   AVR suite + mutation testing), `make pic-test` (PIC CONFIG-word + static
   analysis + gpsim functional), and a **24-hour soak of every variant on every
   MCU** (logs under `evidence/`).

2. **Reproducibility.** The Intel-HEX images are byte-deterministic for a fixed
   toolchain — `objcopy` ihex output contains only the program's code/data
   bytes, with no embedded timestamps or build paths. `SHA256SUMS` pins those
   bytes. When the release tag is pushed, CI
   ([`.github/workflows/release.yml`](../.github/workflows/release.yml)) rebuilds
   the images from the tagged source on a clean runner and **fails the release
   unless they reproduce these exact hashes**. That check is the public
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
| `_pic10f322` | Microchip PIC10F322, 16 MHz |

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

```sh
git checkout vX.Y.Z
# install the pinned toolchain (see TOOLCHAIN.adoc), then:
make clean && make all13 all85 all45 && make pic
sha256sum -c release/vX.Y.Z/SHA256SUMS
```

A matching `sha256sum -c` proves your locally built images are identical to the
published ones. (Byte-exact reproduction requires the *same* `avr-gcc` **and**
`binutils-avr` versions recorded in the manifest; a different toolchain may
produce functionally identical but not byte-identical images.)
