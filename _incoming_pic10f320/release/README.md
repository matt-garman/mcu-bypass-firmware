# Prebuilt firmware images

This directory holds **prebuilt, ready-to-flash PIC10F320 firmware images** so you
can use this firmware without installing the XC8 cross-compiler or building
anything. Each release lives in its own `vX.Y.Z/` subdirectory and is also
published as a [GitHub Release](../../releases).

If you would rather build from source, ignore this directory and see the
top-level [README](../README.md) and [TOOLCHAIN.adoc](../TOOLCHAIN.adoc).

## Why you can trust these binaries

The same philosophy that backs the source — a layered, multi-engine test and
validation suite — backs these binaries, through two mechanisms:

1. **Provenance.** Every release carries a `MANIFEST.md` recording the exact
   source commit, the pinned toolchain versions, the per-image flash usage /
   CONFIG word, and the validation evidence: `make test-variants` (the full
   per-variant gate — static analysis + the reference-model host/formal suite +
   the firmware↔model equivalence trace + the per-variant actuation-sequence
   check + the fault-injection harness + CONFIG-word + gpsim functional +
   coverage), `make test-mutation` (inject firmware/model faults and confirm the
   suite kills them), `make test-target-variants` (real-HEX TRISA/SFR/SRAM fault
   recovery, firmware/model lock-step, and exact GPIO transition/pulse timing),
   and a **24-hour
   libgpsim soak of every output variant** — 24 h of *simulated* MCU operation
   per variant (gpsim runs the core faster than real time, so the wall-clock
   cost is correspondingly shorter); logs under `evidence/`.

2. **Reproducibility.** The Intel-HEX images are byte-deterministic for a fixed
   toolchain — XC8's ihex output contains only the program's code/config bytes,
   with no embedded timestamps or build paths. `SHA256SUMS` pins those bytes.
   When the release tag is pushed, CI
   ([`.github/workflows/release.yml`](../.github/workflows/release.yml)) rebuilds
   the images from the tagged source on a clean runner and **fails the release
   unless they reproduce these exact hashes**. CI also requires exact filename-set
   equality among the tagged Makefile's variants, committed HEX files,
   `SHA256SUMS`, and the fresh build, so no missing, extra, duplicate, or
   unchecksummed image can be published. Together those checks attest that the
   complete release set is exactly what the tested source compiles to; you can
   run the same hash check yourself (see "Reproduce" below).

`SHA256SUMS` is also signed (`SHA256SUMS.asc`), and the release tag is a signed
git tag, so you can additionally verify the maintainer vouched for the bytes.

## Which image do I want?

Images are named `bypass_mcu_<variant>_pic10f320.hex`. There are **three**, one
per output stage:

| variant         | switching hardware                                     |
|-----------------|--------------------------------------------------------|
| `cd4053-simple` | CD4053 / TMUX4053 analog switch, simple — 2 sections   |
| `cd4053-mute`   | CD4053 / TMUX4053 with mute-before-switch — 3 sections |
| `tq2-relay`     | Panasonic TQ2-L2-5V latching relay                     |

Each `cd4053-*` image drives its analog-switch control pins with a single unified
polarity that is correct for **both** an inverting **CD4053** (driven through a
MOSFET inverter, as used for a 9–18 V switch rail) and the pin-compatible
logic-level **TMUX4053** (driven directly at logic level) — one image serves both
boards. All three target the **PIC10F320** on its internal oscillator (INTOSC);
the core is clocked at **2 MHz** as of v0.9.3 (v0.9.0–v0.9.2 ran at 16 MHz). The
per-release `MANIFEST.md` records each image's core clock, flash-word usage, and
exact flashing command.

## Verify a download

```sh
cd release/vX.Y.Z

# (recommended) verify the maintainer's signature over the checksums
gpg --verify SHA256SUMS.asc SHA256SUMS

# verify the image bytes
sha256sum -c SHA256SUMS
```

## Flash a chip

The PIC10F320 CONFIG word is embedded in the HEX, so writing the HEX configures
the device — there is no separate fuse step. With a PICkit and `pk2cmd`:

```sh
pk2cmd -PPIC10F320 -Fbypass_mcu_cd4053-simple_pic10f320.hex -M -Y -R   # PICkit 2
```

(or use MPLAB X / `ipecmd` with a PICkit 3/4/5).

## Reproduce the images bit-for-bit

```sh
repo="$PWD"
tmp="$(mktemp -d)"
src="$tmp/source"
git worktree add --detach "$src" vX.Y.Z
(
  cd "$src"
  # install the tag's pinned toolchain (see TOOLCHAIN.adoc), then:
  make clean
  for v in $(make -s print-PIC_VARIANTS_ALL); do
    make all PIC_VARIANT="$v"
  done
  "$repo/scripts/verify-release-images.sh" "release/vX.Y.Z" build_pic
)
git worktree remove "$src"
rmdir "$tmp"
```

The verifier requires exact filename-set equality among committed images,
`SHA256SUMS`, and a private snapshot of the fresh `build_pic/` images before
checking both committed and fresh bytes. The detached worktree keeps the current
verifier available even for older tags that predate it, and each tag supplies its
own historical variant list. A pass therefore cannot accidentally recheck the
committed release copies. Byte-exact reproduction requires the same XC8 and DFP
versions recorded in the manifest; a different toolchain may produce functionally
identical but not byte-identical images.
