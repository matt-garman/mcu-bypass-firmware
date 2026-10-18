# Firmware release v0.9.18

Prebuilt, fully-validated firmware images. Verify integrity with
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
firmware line coverage, and its own 24.0-h soak per output stage -- but the
inlining seam means its architecture is not identical to the other targets.
It is the constrained exception, not evidence that the reference architecture
fits 256 words.

Full detail: [DESIGN_DOCUMENTATION.adoc](https://github.com/matt-garman/mcu-bypass-firmware/blob/v0.9.18/DESIGN_DOCUMENTATION.adoc#pic10f320-architecture).

Its images follow the same `bypass-<mcu>-<output stage>.hex` scheme as every
other target (`bypass-pic10f320-<output stage>.hex`); the imported `bypass_mcu_` prefix
it shipped with through v0.9.7 is gone as of v0.9.8.

## Provenance

- **Version / tag:** v0.9.18
- **Release mode:** production
- **Source commit:** `3e3a13294782022baf27555c81c09595b217ec85`
- **Soak duration per combination:** 86400000 ms
- **Soak combinations:** 18
- **PIC12F675 qualified matrix:** `evidence/pic12f675-qualified-matrix.json` (SHA-256 `c44a5d8296af710fbd3e3c0e5e59dd7f709bbcb15162d82df41778e167615cd1`)
- **Final resource evidence:** `evidence/resource-tables.log` (SHA-256 `005d6ea73cfa711f8abe5530ada6a1a898cea1949711b60bd97b9268a86b9320`)
- **Evidence index:** `evidence/INDEX` (SHA-256 `b944bb949453695e919cfb791a7e0efb65bc0949b03f7a026b2e02cbb9f4561b`), 36 retained files by role and terminal record
- **Soak input key:** `SOAK_KEY` (SHA-256 `afc6978a35f7c0f90b8001b7a07a6af825c6f3c2ef74c7040cbaf277d2b3f0c2`), 18 combinations over 28 driver sources and 6 harnesses
- **Soak provenance:** the recorded soak of these exact inputs, run at commit `e500065babca`
- **Built:** 2026-10-18T05:26:04Z by `matt` on `Linux 6.12.33-production+truenas x86_64`
- **Validation:** `make test-long` + `make attiny202-test` + `make attiny202-test-target` + `make pic10f322-test` + `make pic10f322-test-target-variants` + `make pic10f320-test` + `make pic10f320-test-target-variants` + `make pic12f675-test pic12f675-test-target-variants` (one retained matrix) (real-image fault handling, firmware/model ctx_ lock-step, and modeled-pin output checks across AVR-XT and all three PIC parts) + 24.0-h parallel soak of every release soak combination (see evidence/).
- **`test-long` retention:** `evidence/test-long.summary.txt` retains one source-bound `TEST_LONG_RESULT` PASS record; the complete transcript is transient diagnostic output, is not a release asset, and is not required after verification. Tag CI reruns the gate independently, but its hosted job log is subject to platform retention and is not release evidence.
- **Release set:** 21 images, checked against the canonical `RELEASE_IMAGES` set declared in the Makefile -- not against whatever the build happened to produce.

## Toolchain

| tool | version |
|---|---|
| avr-gcc (`CC=/usr/bin/avr-gcc`) | avr-gcc (GCC) 14.3.0 |
| AVR objcopy (`OBJCOPY=/usr/bin/avr-objcopy`) | GNU objcopy (GNU Binutils) 2.45.50.20251209 |
| avr-libc (`<avr/version.h>` via CC) | 2.2.1 (/usr/lib/avr/include/avr/version.h, dpkg avr-libc 1:2.2.1-1build1) |
| host cc | cc (Ubuntu 15.2.0-16ubuntu1) 15.2.0 |
| PIC10F322/PIC12F675 XC8 (`PIC_CC=/opt/microchip/xc8/v3.10/bin/xc8-cc`) | Microchip MPLAB XC8 C Compiler V3.10 |
| PIC10F320 XC8 (`PIC10F320_CC=/opt/microchip/xc8/v3.10/bin/xc8-cc`) | Microchip MPLAB XC8 C Compiler V3.10 |
| PIC10F322/PIC12F675 DFP (`PIC_DFP`) | /opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8 |
| PIC10F320 DFP (`PIC10F320_DFP`) | /opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8 |
| gpsim | gpsim-0.32.1 # (Feb  3 2026) |
| libsimavr-dev (pkg) | 1.6+dfsg-3build2 |
| yasimavr (patched venv: version sdist patchset) | 0.1.6 3742dae364a8d65ff7d4180d00b40c0901656dafcea6e53e94db1127b7ec6285 6c4c034ea39ef1d26e429b751a803c224b18547ff72d4ca45523c3d1c0132923 e14b66201bc6da330760ba2529396728091530a8a71e03876c14dfaa98860b27 |
| cppcheck | Cppcheck 2.19.0 |
| cbmc | 6.6.0 (cbmc-6.6.0) |
| clang | Ubuntu clang version 21.1.8 (6ubuntu1) |
| python3 | Python 3.14.4 |
| PIC12F675 Python | Python 3.14.4 |

## Images

| image | MCU | clock | flash used / reviewed ceiling | fuses / config | sha256 |
|---|---|---|---|---|---|
| `bypass-attiny13a-cd4053_simple.hex` | ATtiny13a | 1.2 MHz | 818 / 921 B (103 free) | lfuse=0x4a hfuse=0xf9 | `16d263cc5a02dbe8da58086933e32387869242277655c6d69b8f8532d1d9fcab` |
| `bypass-attiny13a-cd4053_with_mute.hex` | ATtiny13a | 1.2 MHz | 858 / 921 B (63 free) | lfuse=0x4a hfuse=0xf9 | `7b846015f88f2c6837a30834774be8c2513e9458b5c8c6f310485c1f9c2a09db` |
| `bypass-attiny13a-tq2_l2_5v_relay.hex` | ATtiny13a | 1.2 MHz | 848 / 921 B (73 free) | lfuse=0x4a hfuse=0xf9 | `4d90a2222499daca1c04f9845b1413eeb64b829dd1fea0d2a5a77745262dd81f` |
| `bypass-attiny85-cd4053_simple.hex` | ATtiny85 | 1.0 MHz | 844 / 8192 B (7348 free) | lfuse=0x62 hfuse=0xcc | `feb5dfaa36a891e59df90bbcefa1e09a265af7f6428a8b8e217da63e5760d56e` |
| `bypass-attiny45-cd4053_simple.hex` | ATtiny45 | 1.0 MHz | 844 / 4096 B (3252 free) | lfuse=0x62 hfuse=0xcc | `25c7978f90007b4607643bd3ff42969bbc70ddf265aa107d562c00729f81dacc` |
| `bypass-attiny85-cd4053_with_mute.hex` | ATtiny85 | 1.0 MHz | 884 / 8192 B (7308 free) | lfuse=0x62 hfuse=0xcc | `0d807ad8d38e5cb386bfd34a2cc24d724246576be5343441533a2b52ebd62817` |
| `bypass-attiny45-cd4053_with_mute.hex` | ATtiny45 | 1.0 MHz | 884 / 4096 B (3212 free) | lfuse=0x62 hfuse=0xcc | `010190ebbc3d3254c53bde326ddedcf693440a806dd61c2d5892f0545f942f83` |
| `bypass-attiny85-tq2_l2_5v_relay.hex` | ATtiny85 | 1.0 MHz | 874 / 8192 B (7318 free) | lfuse=0x62 hfuse=0xcc | `14307053f64e056ef8d057067547b7d191ebe802e8d25b2918a60cd305b087e3` |
| `bypass-attiny45-tq2_l2_5v_relay.hex` | ATtiny45 | 1.0 MHz | 874 / 4096 B (3222 free) | lfuse=0x62 hfuse=0xcc | `26b1cd95ad901e435b17a892da14f062c58b8579d0f536bf6f9869c5e00cd764` |
| `bypass-attiny202-cd4053_simple.hex` | ATtiny202 | 2 MHz (internal, OSCCFG 16 MHz / 8) | 940 / 2048 B (1108 free) | wdtcfg=0x06 bodcfg=0xE5 osccfg=0x01 syscfg0=0xF6 syscfg1=0x07 append=0x00 bootend=0x00 | `bf6671cc91c5bd37e5d1a06f205692382494af617ab6782fc3a045c6616be320` |
| `bypass-attiny202-cd4053_with_mute.hex` | ATtiny202 | 2 MHz (internal, OSCCFG 16 MHz / 8) | 980 / 2048 B (1068 free) | wdtcfg=0x06 bodcfg=0xE5 osccfg=0x01 syscfg0=0xF6 syscfg1=0x07 append=0x00 bootend=0x00 | `ccff1bc49206a44e5b70ae0641c80e376ca50bf7ae5553ae81065bddc8d2eac6` |
| `bypass-attiny202-tq2_l2_5v_relay.hex` | ATtiny202 | 2 MHz (internal, OSCCFG 16 MHz / 8) | 996 / 2048 B (1052 free) | wdtcfg=0x06 bodcfg=0xE5 osccfg=0x01 syscfg0=0xF6 syscfg1=0x07 append=0x00 bootend=0x00 | `7a48f931cd361e7056ae97af742c4a9de16eabc55ceb601e9c3237fde5b03b39` |
| `bypass-pic10f322-cd4053_simple.hex` | PIC10F322 | 2 MHz (HFINTOSC) | 476 / 512 words (36 free) | CONFIG word embedded in HEX | `c88ff08fc94ca068bd25ba0bbcf1da74bddda5b5a19c9452141edfb425923555` |
| `bypass-pic10f322-cd4053_with_mute.hex` | PIC10F322 | 2 MHz (HFINTOSC) | 502 / 512 words (10 free) | CONFIG word embedded in HEX | `2320c237e6564b47449104acfda59e9592a2a653e1b222add3ddfdcf120f7d5b` |
| `bypass-pic10f322-tq2_l2_5v_relay.hex` | PIC10F322 | 2 MHz (HFINTOSC) | 493 / 512 words (19 free) | CONFIG word embedded in HEX | `ca0ba0708e33d7b27a2b6973594bbd9c272053e5820041847bc6a8910c83b770` |
| `bypass-pic10f320-cd4053_simple.hex` | PIC10F320 | 2 MHz (HFINTOSC) | 220 / 256 words (36 free) | CONFIG word embedded in HEX | `e48ed8e50e89a7f2c2e145603d16c25099925269ea0b29b31becc9c02eb2143f` |
| `bypass-pic10f320-cd4053_with_mute.hex` | PIC10F320 | 2 MHz (HFINTOSC) | 241 / 256 words (15 free) | CONFIG word embedded in HEX | `1cc2cbf6572a876b1a0a5d19e2e3179a41c7a46bd1b7419d2b5e72aa2aec27a7` |
| `bypass-pic10f320-tq2_l2_5v_relay.hex` | PIC10F320 | 2 MHz (HFINTOSC) | 242 / 256 words (14 free) | CONFIG word embedded in HEX | `8193aa0db4bc4839e1d4304dac7dd91e313b73bc93b0401732613e6f5f9f2e86` |
| `bypass-pic12f675-cd4053_simple.hex` | PIC12F675 | 4 MHz (INTOSC, factory OSCCAL) | 548 / 1024 words (476 free) | CONFIG word embedded in HEX | `8405c24723448d47504545411aff139626399476e332cc5f46e5b7bba3a202b1` |
| `bypass-pic12f675-cd4053_with_mute.hex` | PIC12F675 | 4 MHz (INTOSC, factory OSCCAL) | 574 / 1024 words (450 free) | CONFIG word embedded in HEX | `655fd28fe8075389ab571218393c0cececf215d4a4a8aac5fa85452863e16c45` |
| `bypass-pic12f675-tq2_l2_5v_relay.hex` | PIC12F675 | 4 MHz (INTOSC, factory OSCCAL) | 585 / 1024 words (439 free) | CONFIG word embedded in HEX | `30757b9429a91bfb90160ad2997c2cb9a50c69b7d22444f018a8d601ac3eb2fe` |

> The ATtiny13a images are not soak-tested directly (simavr cannot model
> its watchdog reset); they are covered by the full test-long suite and by
> the soak of the core-identical tinyx5 family. See DESIGN_DOCUMENTATION.adoc.

## Resources

Every figure below is measured during the release run by
`test/test_resource_tables.py`, checked there against the reviewed ceiling
that bounds it, and retained as one machine record per figure in
`evidence/resource-tables.log` -- which `SHA256SUMS` signs and
`evidence/INDEX` records. The flash column in the Images table above is
rendered from those same records, so no number on this page is derived
twice.

### Static RAM (AVR)

Statically allocated data-space bytes, summed from each ELF and confirmed
against the SRAM map the simulated canary gate derives independently. One
row per part: the variants of a part are required to agree before a single
figure is published for it.

| part | static data | reviewed ceiling | free | images |
|---|---|---|---|---|
| `attiny13a` | 5 B | 16 B | 11 B | 3 |
| `attiny202` | 5 B | 16 B | 11 B | 3 |
| `attiny45` | 5 B | 16 B | 11 B | 3 |
| `attiny85` | 5 B | 16 B | 11 B | 3 |

### Stack (Classic AVR)

The deepest stack the canary gate observed on each part, across its three
variant runs. The canary record does not name the variant it came from, so
the deepest of the observations is published rather than an attribution the
evidence does not carry. Static, stack and free account for the whole
device SRAM in every row.

| part | deepest SP | stack used | free | static | device SRAM | canary floor | observations |
|---|---|---|---|---|---|---|---|
| `attiny13a` | 0x07F | 33 B | 26 B | 5 B | 64 B | 8 B | 3 |
| `attiny45` | 0x13F | 33 B | 218 B | 5 B | 256 B | 8 B | 3 |
| `attiny85` | 0x23F | 33 B | 474 B | 5 B | 512 B | 8 B | 3 |

### Stack bound (AVR-XT)

This one is a compiler bound, not a measurement of a run: `-fstack-usage`
bounds each frame on its own and says nothing about the deepest path
through them. It is reported as the ceiling every frame was checked
against, and no high-water figure is claimed for this part.

| part | method | reports | bound |
|---|---|---|---|
| `attiny202` | gcc-stack-usage-per-frame | 3 | every frame <= 32 B |

### Data space (PIC12F675)

Reported by XC8 for the qualified build and again for the reproducibility
rebuild; the two must agree before one figure is published per variant.

| part | variant | used | reviewed ceiling | device | free |
|---|---|---|---|---|---|
| `pic12f675` | cd4053_simple | 40 B | 48 B | 64 B | 8 B |
| `pic12f675` | cd4053_with_mute | 40 B | 48 B | 64 B | 8 B |
| `pic12f675` | tq2_l2_5v_relay | 40 B | 48 B | 64 B | 8 B |

### Return stack (PIC)

Peak call depth on the hardware return stack, with the levels held in
reserve and the levels left spare. Peak, reserve and spare account for the
whole hardware stack in every row.

| part | variant | peak | reserve | spare | hardware levels |
|---|---|---|---|---|---|
| `pic10f320` | cd4053_simple | 3 | 2 | 3 | 8 |
| `pic10f320` | cd4053_with_mute | 3 | 2 | 3 | 8 |
| `pic10f320` | tq2_l2_5v_relay | 3 | 2 | 3 | 8 |
| `pic10f322` | cd4053_simple | 3 | 2 | 3 | 8 |
| `pic10f322` | cd4053_with_mute | 3 | 2 | 3 | 8 |
| `pic10f322` | tq2_l2_5v_relay | 4 | 2 | 2 | 8 |
| `pic12f675` | cd4053_simple | 3 | 2 | 3 | 8 |
| `pic12f675` | cd4053_with_mute | 3 | 2 | 3 | 8 |
| `pic12f675` | tq2_l2_5v_relay | 5 | 2 | 1 | 8 |

## Flashing

Every command in this section is complete. It names one released image,
carries the fuse or configuration bytes that image was qualified with, and
runs as written from the directory holding the download.

AVR images need their fuse bytes in addition to the flash write (the Images
table above lists them per image, and the commands below carry the same
bytes). PIC images embed their configuration word in the HEX. PIC12F675 has
no per-image command at all: every write to that part goes through the
guarded transaction below -- pass its HEX to the `flash-pic12f675.py`
shipped in this release, never directly to a programmer.

### Programmer profiles

The programmer and port in the commands below are this project's defaults.
They are the only values here a reader may have to change, and changing one
is a substitution into an otherwise complete command.

| images | interface | tool | this release publishes | if yours differs |
|---|---|---|---|---|
| ATtiny13a, ATtiny45, ATtiny85 | ISP | `avrdude` | `-c usbtiny` | `avrdude -c ?` lists every programmer name your avrdude supports |
| ATtiny202 | UPDI | `avrdude` | `-c serialupdi -P /dev/ttyUSB0` | your UPDI adapter's device node; ISP programmers cannot drive UPDI |
| PIC10F320, PIC10F322 | ICSP | `pk2cmd` (PICkit 2) | an externally powered target | add `-T` to have the PICkit supply power |
| PIC12F675 | ICSP | `flash-pic12f675.py` | the guarded transaction below | never a raw writer |

PICkit 3/4/5 program the PIC10F32x parts through MPLAB IPE's `ipecmd` rather
than `pk2cmd`. Every command published here is pinned, byte for byte, to the
programming command this project's Makefile defines by default, and that
default is `pk2cmd`. The `ipecmd` form is a non-default override of the same
goals and writes and verifies the same way, but its reset-release flag and
part-name spelling have not been confirmed against a part; that procedure
therefore stays in the source tree's `FLASHING.md`, which carries the caveat
with it, rather than being published here as a complete command.

### Per-image commands

```sh
# bypass-attiny13a-cd4053_simple.hex
avrdude -c usbtiny -p t13 -U lfuse:w:0x4a:m -U hfuse:w:0xf9:m -U flash:w:bypass-attiny13a-cd4053_simple.hex:i

# bypass-attiny13a-cd4053_with_mute.hex
avrdude -c usbtiny -p t13 -U lfuse:w:0x4a:m -U hfuse:w:0xf9:m -U flash:w:bypass-attiny13a-cd4053_with_mute.hex:i

# bypass-attiny13a-tq2_l2_5v_relay.hex
avrdude -c usbtiny -p t13 -U lfuse:w:0x4a:m -U hfuse:w:0xf9:m -U flash:w:bypass-attiny13a-tq2_l2_5v_relay.hex:i

# bypass-attiny202-cd4053_simple.hex
avrdude -c serialupdi -P /dev/ttyUSB0 -p t202 -U wdtcfg:w:0x06:m -U bodcfg:w:0xE5:m -U osccfg:w:0x01:m -U syscfg0:w:0xF6:m -U syscfg1:w:0x07:m -U append:w:0x00:m -U bootend:w:0x00:m -U flash:w:bypass-attiny202-cd4053_simple.hex:i

# bypass-attiny202-cd4053_with_mute.hex
avrdude -c serialupdi -P /dev/ttyUSB0 -p t202 -U wdtcfg:w:0x06:m -U bodcfg:w:0xE5:m -U osccfg:w:0x01:m -U syscfg0:w:0xF6:m -U syscfg1:w:0x07:m -U append:w:0x00:m -U bootend:w:0x00:m -U flash:w:bypass-attiny202-cd4053_with_mute.hex:i

# bypass-attiny202-tq2_l2_5v_relay.hex
avrdude -c serialupdi -P /dev/ttyUSB0 -p t202 -U wdtcfg:w:0x06:m -U bodcfg:w:0xE5:m -U osccfg:w:0x01:m -U syscfg0:w:0xF6:m -U syscfg1:w:0x07:m -U append:w:0x00:m -U bootend:w:0x00:m -U flash:w:bypass-attiny202-tq2_l2_5v_relay.hex:i

# bypass-attiny45-cd4053_simple.hex
avrdude -c usbtiny -p t45 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass-attiny45-cd4053_simple.hex:i

# bypass-attiny45-cd4053_with_mute.hex
avrdude -c usbtiny -p t45 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass-attiny45-cd4053_with_mute.hex:i

# bypass-attiny45-tq2_l2_5v_relay.hex
avrdude -c usbtiny -p t45 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass-attiny45-tq2_l2_5v_relay.hex:i

# bypass-attiny85-cd4053_simple.hex
avrdude -c usbtiny -p t85 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass-attiny85-cd4053_simple.hex:i

# bypass-attiny85-cd4053_with_mute.hex
avrdude -c usbtiny -p t85 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass-attiny85-cd4053_with_mute.hex:i

# bypass-attiny85-tq2_l2_5v_relay.hex
avrdude -c usbtiny -p t85 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass-attiny85-tq2_l2_5v_relay.hex:i

# bypass-pic10f320-cd4053_simple.hex
pk2cmd -PPIC10F320 -Fbypass-pic10f320-cd4053_simple.hex -M -Y -R

# bypass-pic10f320-cd4053_with_mute.hex
pk2cmd -PPIC10F320 -Fbypass-pic10f320-cd4053_with_mute.hex -M -Y -R

# bypass-pic10f320-tq2_l2_5v_relay.hex
pk2cmd -PPIC10F320 -Fbypass-pic10f320-tq2_l2_5v_relay.hex -M -Y -R

# bypass-pic10f322-cd4053_simple.hex
pk2cmd -PPIC10F322 -Fbypass-pic10f322-cd4053_simple.hex -M -Y -R

# bypass-pic10f322-cd4053_with_mute.hex
pk2cmd -PPIC10F322 -Fbypass-pic10f322-cd4053_with_mute.hex -M -Y -R

# bypass-pic10f322-tq2_l2_5v_relay.hex
pk2cmd -PPIC10F322 -Fbypass-pic10f322-tq2_l2_5v_relay.hex -M -Y -R

```

### Source-checkout equivalents

These need a checkout of this tag, not this download: the release bundle
ships no Makefile. They select the same image by its variant, and are
listed for provenance, not as an alternative for a reader who downloaded
the images.

```sh
# bypass-attiny202-cd4053_simple.hex
make attiny202-program VARIANT=cd4053_simple XT_UPDI_PORT=/dev/ttyUSB0

# bypass-attiny202-cd4053_with_mute.hex
make attiny202-program VARIANT=cd4053_with_mute XT_UPDI_PORT=/dev/ttyUSB0

# bypass-attiny202-tq2_l2_5v_relay.hex
make attiny202-program VARIANT=tq2_l2_5v_relay XT_UPDI_PORT=/dev/ttyUSB0

# bypass-pic10f320-cd4053_simple.hex
make pic10f320-program PIC10F320_VARIANT=cd4053_simple

# bypass-pic10f320-cd4053_with_mute.hex
make pic10f320-program PIC10F320_VARIANT=cd4053_with_mute

# bypass-pic10f320-tq2_l2_5v_relay.hex
make pic10f320-program PIC10F320_VARIANT=tq2_l2_5v_relay

# bypass-pic10f322-cd4053_simple.hex
make pic10f322-program VARIANT=cd4053_simple

# bypass-pic10f322-cd4053_with_mute.hex
make pic10f322-program VARIANT=cd4053_with_mute

# bypass-pic10f322-tq2_l2_5v_relay.hex
make pic10f322-program VARIANT=tq2_l2_5v_relay

```

### PIC12F675 programming

This part is NOT a raw write target. Its per-device factory OSCCAL word and
CONFIG `BG<1:0>` trim live in memory a programmer erases, and a device that
loses either still appears to work. Every write therefore goes through the
guarded transaction of the release helper; no Make goal programs this part.

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

## Soak evidence

| combo | result |
|---|---|
| attiny85_cd4053_simple | SOAK PASS: 86400000 ms (24.0 h) simulated. |
| attiny45_cd4053_simple | SOAK PASS: 86400000 ms (24.0 h) simulated. |
| attiny85_cd4053_with_mute | SOAK PASS: 86400000 ms (24.0 h) simulated. |
| attiny45_cd4053_with_mute | SOAK PASS: 86400000 ms (24.0 h) simulated. |
| attiny85_tq2_l2_5v_relay | SOAK PASS: 86400000 ms (24.0 h) simulated. |
| attiny45_tq2_l2_5v_relay | SOAK PASS: 86400000 ms (24.0 h) simulated. |
| attiny202_cd4053_simple | SOAK PASS: 86400000 ms (24.00 h) simulated. resets=0 liveness_fails=0 checks=1440 witness_checks=92160 in 1018.8s wall. |
| attiny202_cd4053_with_mute | SOAK PASS: 86400000 ms (24.00 h) simulated. resets=0 liveness_fails=0 checks=1440 witness_checks=92160 in 1057.1s wall. |
| attiny202_tq2_l2_5v_relay | SOAK PASS: 86400000 ms (24.00 h) simulated. resets=0 liveness_fails=0 checks=1440 witness_checks=92160 in 1050.8s wall. |
| pic10f322_cd4053_simple | SOAK PASS: 86400000 ms (24.00 h) simulated. 43388125545 cycles (86776251.090 ms) advanced; wdt_resets=0 liveness_fails=0 checks=1440 |
| pic10f322_cd4053_with_mute | SOAK PASS: 86400000 ms (24.00 h) simulated. 43406161545 cycles (86812323.090 ms) advanced; wdt_resets=0 liveness_fails=0 checks=1440 |
| pic10f322_tq2_l2_5v_relay | SOAK PASS: 86400000 ms (24.00 h) simulated. 43431411945 cycles (86862823.890 ms) advanced; wdt_resets=0 liveness_fails=0 checks=1440 |
| pic10f320_cd4053_simple | SOAK PASS: 86400000 ms (24.00 h) simulated. 43388125545 cycles (86776251.090 ms) advanced; wdt_resets=0 liveness_fails=0 checks=1440 |
| pic10f320_cd4053_with_mute | SOAK PASS: 86400000 ms (24.00 h) simulated. 43406161545 cycles (86812323.090 ms) advanced; wdt_resets=0 liveness_fails=0 checks=1440 |
| pic10f320_tq2_l2_5v_relay | SOAK PASS: 86400000 ms (24.00 h) simulated. 43431411945 cycles (86862823.890 ms) advanced; wdt_resets=0 liveness_fails=0 checks=1440 |
| pic12f675_cd4053_simple | SOAK PASS: 86400000 ms (24.00 h) simulated. 86696855245 cycles (86696855.245 ms) advanced; wdt_resets=0 liveness_fails=0 checks=1440 |
| pic12f675_cd4053_with_mute | SOAK PASS: 86400000 ms (24.00 h) simulated. 86732891245 cycles (86732891.245 ms) advanced; wdt_resets=0 liveness_fails=0 checks=1440 |
| pic12f675_tq2_l2_5v_relay | SOAK PASS: 86400000 ms (24.00 h) simulated. 86783341645 cycles (86783341.645 ms) advanced; wdt_resets=0 liveness_fails=0 checks=1440 |

## Reproducing these images

Check the images this tag *builds* against the committed checksums. A
freshly built HEX lands under `build_avr_classic/` `build_avr_xt/` `build_pic10f322/` `build_pic10f320/` `build_pic12f675/`, not
in this release directory, so the checksum list must be run against those
fresh bytes (running it from the repo root would just re-verify the
committed copies against themselves).

```
git checkout v0.9.18
# install the pinned toolchain (see TOOLCHAIN.adoc), then:
make clean AVR_BUILD_DIR=build_avr_classic XT_BUILD_DIR=build_avr_xt PIC10F322_BUILD_DIR=build_pic10f322 PIC10F320_BUILD_DIR=build_pic10f320 PIC12F675_BUILD_DIR=build_pic12f675
make attiny13a attiny85 attiny45 AVR_BUILD_DIR=build_avr_classic
make attiny202 XT_BUILD_DIR=build_avr_xt STRICT_TOOLS=1
make pic10f322 PIC10F322_BUILD_DIR=build_pic10f322 PIC_CC=/opt/microchip/xc8/v3.10/bin/xc8-cc PIC_DFP=/opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8
make pic10f320-variants PIC10F320_BUILD_DIR=build_pic10f320 PIC10F320_CC=/opt/microchip/xc8/v3.10/bin/xc8-cc PIC10F320_DFP=/opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8
make pic12f675 PIC12F675_BUILD_DIR=build_pic12f675 PIC_CC=/opt/microchip/xc8/v3.10/bin/xc8-cc PIC_DFP=/opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8
scripts/verify-release-images.sh release/v0.9.18 build_avr_classic build_avr_xt build_pic10f322 build_pic10f320 build_pic12f675
```
A passing verifier proves four things agree: the committed files, the checksum
entries, the freshly built files, and the canonical `RELEASE_IMAGES` set the
Makefile declares. The fourth is what makes the first three mean something --
three sets derived by globbing the same directories agree perfectly on a
release that is missing an entire MCU.
The tag-triggered CI (.github/workflows/release.yml) runs this exact check on a
clean runner and fails the release on any mismatch.
