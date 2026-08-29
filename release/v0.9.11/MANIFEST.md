# Firmware release v0.9.11

> **EXPRESS QUALIFICATION -- SHORTENED SOAK.** Every gate below ran in full; the parallel soak ran 1.0 h per combination instead of 24 h.

Prebuilt firmware images; every release gate passed, with the shortened soak
recorded above and in QUALIFICATION. Verify integrity with
`sha256sum -c SHA256SUMS`; reproduce from source per "Reproducing" below.

This bundle also ships `flash-pic12f675.py`, covered by the same checksum
file and signature. The PIC12F675 is not a raw write target: pass its image
to that helper, never straight to a programmer. See "PIC12F675 programming".

Release scope: AVR Classic (ATtiny13a/45/85), ATtiny202 (AVR-XT),
PIC10F322, PIC10F320, and PIC12F675.

## PIC10F320 -- the constrained target

The PIC10F320 has 256 words of flash, half the PIC10F322. The pure/result-struct
architecture every other target compiles into its shipping image does not fit, so
its firmware inlines the debounce algorithm into `main()` by hand. It is fully
release-gated -- firmware-to-core equivalence against the same verified
`src/bypass_pure.c`, real-HEX lock-step, host and target fault injection, exact
firmware line coverage, and its own 1.0-h soak per output stage -- but the
inlining seam means its architecture is not identical to the other targets.
It is the constrained exception, not evidence that the reference architecture
fits 256 words.

Full detail: [docs/pic10f320_special_case.md](https://github.com/matt-garman/mcu-bypass-firmware/blob/v0.9.11/docs/pic10f320_special_case.md).

Its images follow the same `bypass-<mcu>-<output stage>.hex` scheme as every
other target (`bypass-pic10f320-<output stage>.hex`); the imported `bypass_mcu_` prefix
it shipped with through v0.9.7 is gone as of v0.9.8.

## Provenance

- **Version / tag:** v0.9.11
- **Release mode:** express
- **Source commit:** `e93401eb5556217bd544b8038aaf7144dceaf23b`
- **Soak duration per combination:** 3600000 ms
- **Soak combinations:** 18
- **PIC12F675 qualified matrix:** `evidence/pic12f675-qualified-matrix.json` (SHA-256 `f6620ab289d5dae466990119160f4084e3389cbe318cd7e031401139709ea40f`)
- **Final resource evidence:** `evidence/resource-tables.log` (SHA-256 `4e26dc85a6697bc2c6486c3849b61d3288beb0aa4e45547d0579ccba400a2359`)
- **Built:** 2026-08-29T16:36:11Z by `matt` on `Linux 6.12.33-production+truenas x86_64`
- **Validation:** `make test-long` + `make attiny202-test` + `make attiny202-test-target` + `make pic10f322-test` + `make pic10f322-test-target-variants` + `make pic10f320-test` + `make pic10f320-test-target-variants` + `make pic12f675-test pic12f675-test-target-variants` (one retained matrix) (real-image fault handling, firmware/model ctx_ lock-step, and modeled-pin output checks across AVR-XT and all three PIC parts) + 1.0-h parallel soak of every release soak combination (see evidence/).
- **Release set:** 21 images, checked against the canonical `RELEASE_IMAGES` set declared in the Makefile -- not against whatever the build happened to produce.

## Toolchain

| tool | version |
|---|---|
| avr-gcc | avr-gcc (GCC) 7.3.0 |
| binutils-avr (objcopy) | GNU objcopy (AVR_8_bit_GNU_Toolchain_3.6.7_635) 2.26.20160125 |
| avr-libc (pkg) | 1:2.0.0+Atmel3.7.0-1 |
| host cc | cc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0 |
| PIC10F322/PIC12F675 XC8 (`PIC_CC=/opt/microchip/xc8/v3.10/bin/xc8-cc`) | Microchip MPLAB XC8 C Compiler V3.10 |
| PIC10F320 XC8 (`PIC10F320_CC=/opt/microchip/xc8/v3.10/bin/xc8-cc`) | Microchip MPLAB XC8 C Compiler V3.10 |
| PIC10F322/PIC12F675 DFP (`PIC_DFP`) | /opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8 |
| PIC10F320 DFP (`PIC10F320_DFP`) | /opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8 |
| gpsim | gpsim-0.32.1 # (Mar 31 2024) |
| libsimavr-dev (pkg) | 1.6+dfsg-3build2 |
| cppcheck | Cppcheck 2.13.0 |
| cbmc | 5.95.1 (cbmc-5.95.1) |
| clang | Ubuntu clang version 18.1.3 (1ubuntu1) |
| python3 | Python 3.12.3 |
| PIC12F675 Python | Python 3.12.3 |

## Images

| image | MCU | clock | flash used | fuses / config | sha256 |
|---|---|---|---|---|---|
| `bypass-attiny13a-cd4053_simple.hex` | ATtiny13a | 1.2 MHz | 838 B | lfuse=0x4a hfuse=0xf9 | `abeba77476f55ed3b3f9c15f962a9254daec201363e23fc78cd747a376fc2225` |
| `bypass-attiny13a-cd4053_with_mute.hex` | ATtiny13a | 1.2 MHz | 878 B | lfuse=0x4a hfuse=0xf9 | `adeb527852ef691d62279aefa81937ba047e02a59e920125174b9a659ea38319` |
| `bypass-attiny13a-tq2_l2_5v_relay.hex` | ATtiny13a | 1.2 MHz | 868 B | lfuse=0x4a hfuse=0xf9 | `62cb4fdc06768d06ea10978c7b2ff7f626679c48c278691b31a7673fe5246a18` |
| `bypass-attiny85-cd4053_simple.hex` | ATtiny85 | 1.0 MHz | 864 B | lfuse=0x62 hfuse=0xcc | `a63d6ece1d1a920de50bd9011a3984c69a49b16b57bbc34cca671a092c5efb2f` |
| `bypass-attiny45-cd4053_simple.hex` | ATtiny45 | 1.0 MHz | 864 B | lfuse=0x62 hfuse=0xcc | `5950fa70b0e5b3740768256aeb53be9e271f4c7fc8bdbd79817f2d30b15b2d8a` |
| `bypass-attiny85-cd4053_with_mute.hex` | ATtiny85 | 1.0 MHz | 904 B | lfuse=0x62 hfuse=0xcc | `f1e79c083620046de27da8ae7dce4f58264f03a925745168036751ae1e87f8a9` |
| `bypass-attiny45-cd4053_with_mute.hex` | ATtiny45 | 1.0 MHz | 904 B | lfuse=0x62 hfuse=0xcc | `6e923e39d5a9f80d4196583d043390aa745b1639b76a001c8c784f470368df81` |
| `bypass-attiny85-tq2_l2_5v_relay.hex` | ATtiny85 | 1.0 MHz | 894 B | lfuse=0x62 hfuse=0xcc | `6bcfd32cd1bf931b7559b32d6e3b26ab88f243dce05ddc7c459e10c27993e695` |
| `bypass-attiny45-tq2_l2_5v_relay.hex` | ATtiny45 | 1.0 MHz | 894 B | lfuse=0x62 hfuse=0xcc | `0e2eb07af46b341f13d044be982261244f84e2caad795c16da9277aaf22d2a04` |
| `bypass-attiny202-cd4053_simple.hex` | ATtiny202 | 2 MHz (internal, OSCCFG 16 MHz / 8) | 968 B | wdtcfg=0x06 bodcfg=0xE5 osccfg=0x01 syscfg0=0xF6 syscfg1=0x07 append=0x00 bootend=0x00 | `c6aeda8bdafaaea94857d4075da4bddc0cb10b84972ee510153416f065acf822` |
| `bypass-attiny202-cd4053_with_mute.hex` | ATtiny202 | 2 MHz (internal, OSCCFG 16 MHz / 8) | 1008 B | wdtcfg=0x06 bodcfg=0xE5 osccfg=0x01 syscfg0=0xF6 syscfg1=0x07 append=0x00 bootend=0x00 | `9d4d0185e726fb0053ea6ba5bf74080a20f05dee7fbde91f32de9342f1f29fc8` |
| `bypass-attiny202-tq2_l2_5v_relay.hex` | ATtiny202 | 2 MHz (internal, OSCCFG 16 MHz / 8) | 1040 B | wdtcfg=0x06 bodcfg=0xE5 osccfg=0x01 syscfg0=0xF6 syscfg1=0x07 append=0x00 bootend=0x00 | `f917575bb7c522dbf0094e07b4881da64a2ebb259d7b190d5ba13487d5e1fdaf` |
| `bypass-pic10f322-cd4053_simple.hex` | PIC10F322 | 2 MHz (HFINTOSC) | n/a | CONFIG word embedded in HEX | `c88ff08fc94ca068bd25ba0bbcf1da74bddda5b5a19c9452141edfb425923555` |
| `bypass-pic10f322-cd4053_with_mute.hex` | PIC10F322 | 2 MHz (HFINTOSC) | n/a | CONFIG word embedded in HEX | `2320c237e6564b47449104acfda59e9592a2a653e1b222add3ddfdcf120f7d5b` |
| `bypass-pic10f322-tq2_l2_5v_relay.hex` | PIC10F322 | 2 MHz (HFINTOSC) | n/a | CONFIG word embedded in HEX | `ca0ba0708e33d7b27a2b6973594bbd9c272053e5820041847bc6a8910c83b770` |
| `bypass-pic10f320-cd4053_simple.hex` | PIC10F320 | 2 MHz (HFINTOSC) | 220 / 256 words | CONFIG word embedded in HEX | `e48ed8e50e89a7f2c2e145603d16c25099925269ea0b29b31becc9c02eb2143f` |
| `bypass-pic10f320-cd4053_with_mute.hex` | PIC10F320 | 2 MHz (HFINTOSC) | 241 / 256 words | CONFIG word embedded in HEX | `1cc2cbf6572a876b1a0a5d19e2e3179a41c7a46bd1b7419d2b5e72aa2aec27a7` |
| `bypass-pic10f320-tq2_l2_5v_relay.hex` | PIC10F320 | 2 MHz (HFINTOSC) | 242 / 256 words | CONFIG word embedded in HEX | `8193aa0db4bc4839e1d4304dac7dd91e313b73bc93b0401732613e6f5f9f2e86` |
| `bypass-pic12f675-cd4053_simple.hex` | PIC12F675 | 4 MHz (INTOSC, factory OSCCAL) | 548 / 1024 words | CONFIG word embedded in HEX | `8405c24723448d47504545411aff139626399476e332cc5f46e5b7bba3a202b1` |
| `bypass-pic12f675-cd4053_with_mute.hex` | PIC12F675 | 4 MHz (INTOSC, factory OSCCAL) | 574 / 1024 words | CONFIG word embedded in HEX | `655fd28fe8075389ab571218393c0cececf215d4a4a8aac5fa85452863e16c45` |
| `bypass-pic12f675-tq2_l2_5v_relay.hex` | PIC12F675 | 4 MHz (INTOSC, factory OSCCAL) | 585 / 1024 words | CONFIG word embedded in HEX | `30757b9429a91bfb90160ad2997c2cb9a50c69b7d22444f018a8d601ac3eb2fe` |

> The ATtiny13a images are not soak-tested directly (simavr cannot model
> its watchdog reset); they are covered by the full test-long suite and by
> the soak of the core-identical tinyx5 family. See DESIGN_DOCUMENTATION.adoc.

## Flashing

AVR images require the design fuse bytes in addition to the flash write
(the table above lists them per image). PIC images embed their CONFIG word.
PIC12F675 has no per-image shortcut because every write requires the guarded
device-specific transaction below -- pass its HEX to the
`flash-pic12f675.py` shipped in this release, never directly to a programmer.

```
# bypass-attiny13a-cd4053_simple.hex
avrdude -c <prog> -p t13 -U lfuse:w:0x4a:m -U hfuse:w:0xf9:m -U flash:w:bypass-attiny13a-cd4053_simple.hex:i

# bypass-attiny13a-cd4053_with_mute.hex
avrdude -c <prog> -p t13 -U lfuse:w:0x4a:m -U hfuse:w:0xf9:m -U flash:w:bypass-attiny13a-cd4053_with_mute.hex:i

# bypass-attiny13a-tq2_l2_5v_relay.hex
avrdude -c <prog> -p t13 -U lfuse:w:0x4a:m -U hfuse:w:0xf9:m -U flash:w:bypass-attiny13a-tq2_l2_5v_relay.hex:i

# bypass-attiny202-cd4053_simple.hex
avrdude -c serialupdi -P <port> -p t202 -U wdtcfg:w:0x06:m -U bodcfg:w:0xE5:m -U osccfg:w:0x01:m -U syscfg0:w:0xF6:m -U syscfg1:w:0x07:m -U append:w:0x00:m -U bootend:w:0x00:m -U flash:w:bypass-attiny202-cd4053_simple.hex:i   (or: make attiny202-program VARIANT=<v> XT_UPDI_PORT=<port>)

# bypass-attiny202-cd4053_with_mute.hex
avrdude -c serialupdi -P <port> -p t202 -U wdtcfg:w:0x06:m -U bodcfg:w:0xE5:m -U osccfg:w:0x01:m -U syscfg0:w:0xF6:m -U syscfg1:w:0x07:m -U append:w:0x00:m -U bootend:w:0x00:m -U flash:w:bypass-attiny202-cd4053_with_mute.hex:i   (or: make attiny202-program VARIANT=<v> XT_UPDI_PORT=<port>)

# bypass-attiny202-tq2_l2_5v_relay.hex
avrdude -c serialupdi -P <port> -p t202 -U wdtcfg:w:0x06:m -U bodcfg:w:0xE5:m -U osccfg:w:0x01:m -U syscfg0:w:0xF6:m -U syscfg1:w:0x07:m -U append:w:0x00:m -U bootend:w:0x00:m -U flash:w:bypass-attiny202-tq2_l2_5v_relay.hex:i   (or: make attiny202-program VARIANT=<v> XT_UPDI_PORT=<port>)

# bypass-attiny45-cd4053_simple.hex
avrdude -c <prog> -p t45 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass-attiny45-cd4053_simple.hex:i

# bypass-attiny45-cd4053_with_mute.hex
avrdude -c <prog> -p t45 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass-attiny45-cd4053_with_mute.hex:i

# bypass-attiny45-tq2_l2_5v_relay.hex
avrdude -c <prog> -p t45 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass-attiny45-tq2_l2_5v_relay.hex:i

# bypass-attiny85-cd4053_simple.hex
avrdude -c <prog> -p t85 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass-attiny85-cd4053_simple.hex:i

# bypass-attiny85-cd4053_with_mute.hex
avrdude -c <prog> -p t85 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass-attiny85-cd4053_with_mute.hex:i

# bypass-attiny85-tq2_l2_5v_relay.hex
avrdude -c <prog> -p t85 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass-attiny85-tq2_l2_5v_relay.hex:i

# bypass-pic10f320-cd4053_simple.hex
pk2cmd -PPIC10F320 -Fbypass-pic10f320-cd4053_simple.hex -M -Y -R

# bypass-pic10f320-cd4053_with_mute.hex
pk2cmd -PPIC10F320 -Fbypass-pic10f320-cd4053_with_mute.hex -M -Y -R

# bypass-pic10f320-tq2_l2_5v_relay.hex
pk2cmd -PPIC10F320 -Fbypass-pic10f320-tq2_l2_5v_relay.hex -M -Y -R

# bypass-pic10f322-cd4053_simple.hex
pk2cmd -PPIC10F322 -Fbypass-pic10f322-cd4053_simple.hex -M -Y -R   (or: make pic10f322-program VARIANT=<v>)

# bypass-pic10f322-cd4053_with_mute.hex
pk2cmd -PPIC10F322 -Fbypass-pic10f322-cd4053_with_mute.hex -M -Y -R   (or: make pic10f322-program VARIANT=<v>)

# bypass-pic10f322-tq2_l2_5v_relay.hex
pk2cmd -PPIC10F322 -Fbypass-pic10f322-tq2_l2_5v_relay.hex -M -Y -R   (or: make pic10f322-program VARIANT=<v>)

```

### PIC12F675 programming

This part is NOT a raw write target. Its per-device factory OSCCAL word and
CONFIG `BG<1:0>` trim live in memory a programmer erases, and a device that
loses either still appears to work. Every write therefore goes through a
guarded transaction, and there are two of them.

**Programming these downloaded images** needs no source checkout and no
firmware development toolchain -- only Linux, Python 3 and MPLAB X 6.20
`ipecmd`. Linux is required because the helper hands the programmer its own
open descriptors instead of pathnames another process could re-point between
the last check and the write; elsewhere it refuses to touch a device.
Pass the release HEX to `flash-pic12f675.py`, which ships beside the images
and is covered by the signed `SHA256SUMS` in this release. Externally power the
board; the helper never requests programmer-supplied Vdd. Choose a NEW
evidence directory per device.

```sh
python3 flash-pic12f675.py program \
  --image bypass-pic12f675-cd4053_simple.hex \
  --ipecmd /opt/microchip/mplabx/v6.20/mplab_platform/mplab_ipe/ipecmd.jar \
  --evidence-dir ./pic12f675-device-001
```

It checks the image against the signed checksum, refuses an image that programs
word `0x3FF` or moves the CONFIG BG field, pins the tool version, reads the
device twice, reserves the write durably, writes exactly once, compares the
WHOLE device afterwards -- every word the image does not supply has to read
back erased -- and publishes one atomically installed, immutable PASS/FAIL
`result.json`. A PENDING directory -- a reservation with no
result -- is resolved read-only, and that mode never constructs a writer
argument:

```sh
python3 flash-pic12f675.py finalize \
  --evidence-dir ./pic12f675-device-001 \
  --ipecmd /opt/microchip/mplabx/v6.20/mplab_platform/mplab_ipe/ipecmd.jar
```

A PASS means no trim damage was OBSERVED on that device. It is not proof that
the writer preserves calibration: that remains hardware-unvalidated until the
`1.x.y` bench pass, and the helper detects damage only after the write. The
helper's `ipecmd` route is published and software-tested, but it is not
hardware-qualified.

#### From a source checkout of this tag (development and release provenance)

Externally power the board; this workflow does not request programmer-supplied Vdd.
Do not invoke a raw programmer write for this part. For each device, choose
new baseline and result paths whose parent directory already exists, then run
the read-only preflight and program steps as one fail-stop transaction. Replace
`cd4053_simple` with one supported output stage when needed:
`cd4053_simple`, `cd4053_with_mute`, or `tq2_l2_5v_relay`.

```sh
release_tag=v0.9.11 &&
repo=$(git rev-parse --show-toplevel) &&
head_commit=$(git -C "$repo" rev-parse --verify "HEAD^{commit}") &&
tag_commit=$(git -C "$repo" rev-parse --verify "refs/tags/$release_tag^{commit}") &&
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
  PIC12F675_PROG=pk2cmd \
  PIC12F675_PROG_KIND=pk2cmd \
  PIC12F675_READ_PROG=pk2cmd \
  PIC12F675_TRIM_EVIDENCE="$baseline" \
  PIC12F675_BENCH_RESULT="$result"
```

If an interruption leaves `reservation.json` but no `result.json`, the
transaction is **PENDING**. Keep physical custody of the same attached device.
Do not write, reflash, capture a new baseline, or reuse the result path. From
this same release checkout, resolve it with the same release identity, variant,
and tool identities:

```sh
make -C "$repo" pic12f675-finalize \
  VARIANT=cd4053_simple \
  PIC12F675_RELEASE_TAG=v0.9.11 \
  PIC12F675_PROG=pk2cmd PIC12F675_PROG_KIND=pk2cmd \
  PIC12F675_READ_PROG=pk2cmd \
  PIC12F675_TRIM_EVIDENCE="$baseline" \
  PIC12F675_BENCH_RESULT="$result"
```

Finalization revalidates the same signed release tag and image, every reserved
identity, and the separately retained image
before hardware access and never invokes writer arguments. It verifies the reader
version before a full-device read, uses retry-safe private attempts, and exclusively
publishes the recovered PASS/FAIL `result.json`; FAIL is a
resolved forensic record, not permission to retry the write, and an existing result
is immutable.

The guarded workflow rejects an image that explicitly programs OSCCAL word
`0x3FF`, requires the image BG field to remain erased, compares the live device
with the baseline immediately before writing.
Post-write identity, OSCCAL, BG, CONFIG, and programmed bytes are checked and recorded
as mandatory evidence.
This does not prove that a real pk2cmd or ipecmd erase/program operation preserves
factory trim: preservation remains hardware-unvalidated until the `1.x.y` bench
pass. A failure is detected only after the write and may already have damaged the device.
The device may still appear to work with wrong timing or BOR/POR thresholds.
The release target rechecks a clean checkout of this exact annotated release tag,
verifies the pinned tag and checksum signatures, and requires the private fresh
build to match the selected digest in the complete signed release image set.
It does not consume a downloaded release HEX. Baseline and result evidence stay
outside the worktree so those checks remain exact. Transient reads and the private build use `TMPDIR` when set,
otherwise `XDG_RUNTIME_DIR`, otherwise `HOME`. The selected root must exist, be
current-user-private, and have only root/current-user-owned non-writable ancestors.
Shared `/tmp` and `/var/tmp` roots are rejected; the path is limited to letters,
digits, spaces, `/`, `.`, `_`, and `-`.
Handled exits remove the transient directories. No ipecmd hardware
procedure is qualified: its software-tested write route would also require a
pk2cmd reader before and after the write, and no safe attachment/handoff has been
validated.

## Soak evidence

| combo | result |
|---|---|
| attiny85_cd4053_simple | SOAK PASS: 3600000 ms (1.0 h) simulated. |
| attiny45_cd4053_simple | SOAK PASS: 3600000 ms (1.0 h) simulated. |
| attiny85_cd4053_with_mute | SOAK PASS: 3600000 ms (1.0 h) simulated. |
| attiny45_cd4053_with_mute | SOAK PASS: 3600000 ms (1.0 h) simulated. |
| attiny85_tq2_l2_5v_relay | SOAK PASS: 3600000 ms (1.0 h) simulated. |
| attiny45_tq2_l2_5v_relay | SOAK PASS: 3600000 ms (1.0 h) simulated. |
| attiny202_cd4053_simple | SOAK PASS: 3600000 ms (1.00 h) simulated. resets=0 liveness_fails=0 checks=60 witness_checks=3840 in 43.6s wall. |
| attiny202_cd4053_with_mute | SOAK PASS: 3600000 ms (1.00 h) simulated. resets=0 liveness_fails=0 checks=60 witness_checks=3840 in 42.4s wall. |
| attiny202_tq2_l2_5v_relay | SOAK PASS: 3600000 ms (1.00 h) simulated. resets=0 liveness_fails=0 checks=60 witness_checks=3840 in 45.9s wall. |
| pic10f322_cd4053_simple | SOAK PASS: 3600000 ms (1.00 h) simulated. 1807840965 cycles (3615681.930 ms) advanced; wdt_resets=0 liveness_fails=0 checks=60 |
| pic10f322_cd4053_with_mute | SOAK PASS: 3600000 ms (1.00 h) simulated. 1808592465 cycles (3617184.930 ms) advanced; wdt_resets=0 liveness_fails=0 checks=60 |
| pic10f322_tq2_l2_5v_relay | SOAK PASS: 3600000 ms (1.00 h) simulated. 1809644565 cycles (3619289.130 ms) advanced; wdt_resets=0 liveness_fails=0 checks=60 |
| pic10f320_cd4053_simple | SOAK PASS: 3600000 ms (1.00 h) simulated. 1807840965 cycles (3615681.930 ms) advanced; wdt_resets=0 liveness_fails=0 checks=60 |
| pic10f320_cd4053_with_mute | SOAK PASS: 3600000 ms (1.00 h) simulated. 1808592465 cycles (3617184.930 ms) advanced; wdt_resets=0 liveness_fails=0 checks=60 |
| pic10f320_tq2_l2_5v_relay | SOAK PASS: 3600000 ms (1.00 h) simulated. 1809644565 cycles (3619289.130 ms) advanced; wdt_resets=0 liveness_fails=0 checks=60 |
| pic12f675_cd4053_simple | SOAK PASS: 3600000 ms (1.00 h) simulated. 3612373765 cycles (3612373.765 ms) advanced; wdt_resets=0 liveness_fails=0 checks=60 |
| pic12f675_cd4053_with_mute | SOAK PASS: 3600000 ms (1.00 h) simulated. 3613875265 cycles (3613875.265 ms) advanced; wdt_resets=0 liveness_fails=0 checks=60 |
| pic12f675_tq2_l2_5v_relay | SOAK PASS: 3600000 ms (1.00 h) simulated. 3615977365 cycles (3615977.365 ms) advanced; wdt_resets=0 liveness_fails=0 checks=60 |

## Reproducing these images

Check the images this tag *builds* against the committed checksums. A
freshly built HEX lands under `build_avr_classic/` `build_avr_xt/` `build_pic10f322/` `build_pic10f320/` `build_pic12f675/`, not
in this release directory, so the checksum list must be run against those
fresh bytes (running it from the repo root would just re-verify the
committed copies against themselves).

```
git checkout v0.9.11
# install the pinned toolchain (see TOOLCHAIN.adoc), then:
make clean AVR_BUILD_DIR=build_avr_classic XT_BUILD_DIR=build_avr_xt PIC10F322_BUILD_DIR=build_pic10f322 PIC10F320_BUILD_DIR=build_pic10f320 PIC12F675_BUILD_DIR=build_pic12f675
make attiny13a attiny85 attiny45 AVR_BUILD_DIR=build_avr_classic
make attiny202 XT_BUILD_DIR=build_avr_xt STRICT_TOOLS=1
make pic10f322 PIC10F322_BUILD_DIR=build_pic10f322 PIC_CC=/opt/microchip/xc8/v3.10/bin/xc8-cc PIC_DFP=/opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8
make pic10f320-variants PIC10F320_BUILD_DIR=build_pic10f320 PIC10F320_CC=/opt/microchip/xc8/v3.10/bin/xc8-cc PIC10F320_DFP=/opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8
make pic12f675 PIC12F675_BUILD_DIR=build_pic12f675 PIC_CC=/opt/microchip/xc8/v3.10/bin/xc8-cc PIC_DFP=/opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8
scripts/verify-release-images.sh release/v0.9.11 build_avr_classic build_avr_xt build_pic10f322 build_pic10f320 build_pic12f675
```
A passing verifier proves four things agree: the committed files, the checksum
entries, the freshly built files, and the canonical `RELEASE_IMAGES` set the
Makefile declares. The fourth is what makes the first three mean something --
three sets derived by globbing the same directories agree perfectly on a
release that is missing an entire MCU.
The tag-triggered CI (.github/workflows/release.yml) runs this exact check on a
clean runner and fails the release on any mismatch.
