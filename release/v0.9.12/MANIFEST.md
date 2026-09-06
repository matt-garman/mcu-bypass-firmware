# Firmware release v0.9.12

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

Full detail: [DESIGN_DOCUMENTATION.adoc](https://github.com/matt-garman/mcu-bypass-firmware/blob/v0.9.12/DESIGN_DOCUMENTATION.adoc#pic10f320-architecture).

Its images follow the same `bypass-<mcu>-<output stage>.hex` scheme as every
other target (`bypass-pic10f320-<output stage>.hex`); the imported `bypass_mcu_` prefix
it shipped with through v0.9.7 is gone as of v0.9.8.

## Provenance

- **Version / tag:** v0.9.12
- **Release mode:** production
- **Source commit:** `df72700c8404913d96a057535c537a4964160ce1`
- **Soak duration per combination:** 86400000 ms
- **Soak combinations:** 18
- **PIC12F675 qualified matrix:** `evidence/pic12f675-qualified-matrix.json` (SHA-256 `b552a3b2d6ee50d091d45def06404db176c4a70d7b3fe8a51524f4a62d1bf65b`)
- **Final resource evidence:** `evidence/resource-tables.log` (SHA-256 `596ac782c199b53c948f42435e69c269a6647f7a45d0d338f15b3109e1f46b98`)
- **Evidence index:** `evidence/INDEX` (SHA-256 `d778f5e1e7d52a840a86a942a7414d9cc17d057c5e03943324746fc044f1f19e`), 36 retained files by role and terminal record
- **Built:** 2026-09-05T19:01:55Z by `matt` on `Linux 6.12.33-production+truenas x86_64`
- **Validation:** `make test-long` + `make attiny202-test` + `make attiny202-test-target` + `make pic10f322-test` + `make pic10f322-test-target-variants` + `make pic10f320-test` + `make pic10f320-test-target-variants` + `make pic12f675-test pic12f675-test-target-variants` (one retained matrix) (real-image fault handling, firmware/model ctx_ lock-step, and modeled-pin output checks across AVR-XT and all three PIC parts) + 24.0-h parallel soak of every release soak combination (see evidence/).
- **`test-long` retention:** `evidence/test-long.summary.txt` retains one source-bound `TEST_LONG_RESULT` PASS record; the complete transcript is transient diagnostic output, is not a release asset, and is not required after verification. Tag CI reruns the gate independently, but its hosted job log is subject to platform retention and is not release evidence.
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

| image | MCU | clock | flash used / reviewed ceiling | fuses / config | sha256 |
|---|---|---|---|---|---|
| `bypass-attiny13a-cd4053_simple.hex` | ATtiny13a | 1.2 MHz | 838 / 921 B (83 free) | lfuse=0x4a hfuse=0xf9 | `abeba77476f55ed3b3f9c15f962a9254daec201363e23fc78cd747a376fc2225` |
| `bypass-attiny13a-cd4053_with_mute.hex` | ATtiny13a | 1.2 MHz | 878 / 921 B (43 free) | lfuse=0x4a hfuse=0xf9 | `adeb527852ef691d62279aefa81937ba047e02a59e920125174b9a659ea38319` |
| `bypass-attiny13a-tq2_l2_5v_relay.hex` | ATtiny13a | 1.2 MHz | 868 / 921 B (53 free) | lfuse=0x4a hfuse=0xf9 | `62cb4fdc06768d06ea10978c7b2ff7f626679c48c278691b31a7673fe5246a18` |
| `bypass-attiny85-cd4053_simple.hex` | ATtiny85 | 1.0 MHz | 864 / 8192 B (7328 free) | lfuse=0x62 hfuse=0xcc | `a63d6ece1d1a920de50bd9011a3984c69a49b16b57bbc34cca671a092c5efb2f` |
| `bypass-attiny45-cd4053_simple.hex` | ATtiny45 | 1.0 MHz | 864 / 4096 B (3232 free) | lfuse=0x62 hfuse=0xcc | `5950fa70b0e5b3740768256aeb53be9e271f4c7fc8bdbd79817f2d30b15b2d8a` |
| `bypass-attiny85-cd4053_with_mute.hex` | ATtiny85 | 1.0 MHz | 904 / 8192 B (7288 free) | lfuse=0x62 hfuse=0xcc | `f1e79c083620046de27da8ae7dce4f58264f03a925745168036751ae1e87f8a9` |
| `bypass-attiny45-cd4053_with_mute.hex` | ATtiny45 | 1.0 MHz | 904 / 4096 B (3192 free) | lfuse=0x62 hfuse=0xcc | `6e923e39d5a9f80d4196583d043390aa745b1639b76a001c8c784f470368df81` |
| `bypass-attiny85-tq2_l2_5v_relay.hex` | ATtiny85 | 1.0 MHz | 894 / 8192 B (7298 free) | lfuse=0x62 hfuse=0xcc | `6bcfd32cd1bf931b7559b32d6e3b26ab88f243dce05ddc7c459e10c27993e695` |
| `bypass-attiny45-tq2_l2_5v_relay.hex` | ATtiny45 | 1.0 MHz | 894 / 4096 B (3202 free) | lfuse=0x62 hfuse=0xcc | `0e2eb07af46b341f13d044be982261244f84e2caad795c16da9277aaf22d2a04` |
| `bypass-attiny202-cd4053_simple.hex` | ATtiny202 | 2 MHz (internal, OSCCFG 16 MHz / 8) | 968 / 2048 B (1080 free) | wdtcfg=0x06 bodcfg=0xE5 osccfg=0x01 syscfg0=0xF6 syscfg1=0x07 append=0x00 bootend=0x00 | `c6aeda8bdafaaea94857d4075da4bddc0cb10b84972ee510153416f065acf822` |
| `bypass-attiny202-cd4053_with_mute.hex` | ATtiny202 | 2 MHz (internal, OSCCFG 16 MHz / 8) | 1008 / 2048 B (1040 free) | wdtcfg=0x06 bodcfg=0xE5 osccfg=0x01 syscfg0=0xF6 syscfg1=0x07 append=0x00 bootend=0x00 | `9d4d0185e726fb0053ea6ba5bf74080a20f05dee7fbde91f32de9342f1f29fc8` |
| `bypass-attiny202-tq2_l2_5v_relay.hex` | ATtiny202 | 2 MHz (internal, OSCCFG 16 MHz / 8) | 1040 / 2048 B (1008 free) | wdtcfg=0x06 bodcfg=0xE5 osccfg=0x01 syscfg0=0xF6 syscfg1=0x07 append=0x00 bootend=0x00 | `f917575bb7c522dbf0094e07b4881da64a2ebb259d7b190d5ba13487d5e1fdaf` |
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
release_tag=v0.9.12 &&
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
  PIC12F675_RELEASE_TAG=v0.9.12 \
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
| attiny85_cd4053_simple | SOAK PASS: 86400000 ms (24.0 h) simulated. |
| attiny45_cd4053_simple | SOAK PASS: 86400000 ms (24.0 h) simulated. |
| attiny85_cd4053_with_mute | SOAK PASS: 86400000 ms (24.0 h) simulated. |
| attiny45_cd4053_with_mute | SOAK PASS: 86400000 ms (24.0 h) simulated. |
| attiny85_tq2_l2_5v_relay | SOAK PASS: 86400000 ms (24.0 h) simulated. |
| attiny45_tq2_l2_5v_relay | SOAK PASS: 86400000 ms (24.0 h) simulated. |
| attiny202_cd4053_simple | SOAK PASS: 86400000 ms (24.00 h) simulated. resets=0 liveness_fails=0 checks=1440 witness_checks=92160 in 1140.5s wall. |
| attiny202_cd4053_with_mute | SOAK PASS: 86400000 ms (24.00 h) simulated. resets=0 liveness_fails=0 checks=1440 witness_checks=92160 in 1135.5s wall. |
| attiny202_tq2_l2_5v_relay | SOAK PASS: 86400000 ms (24.00 h) simulated. resets=0 liveness_fails=0 checks=1440 witness_checks=92160 in 1142.5s wall. |
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
git checkout v0.9.12
# install the pinned toolchain (see TOOLCHAIN.adoc), then:
make clean AVR_BUILD_DIR=build_avr_classic XT_BUILD_DIR=build_avr_xt PIC10F322_BUILD_DIR=build_pic10f322 PIC10F320_BUILD_DIR=build_pic10f320 PIC12F675_BUILD_DIR=build_pic12f675
make attiny13a attiny85 attiny45 AVR_BUILD_DIR=build_avr_classic
make attiny202 XT_BUILD_DIR=build_avr_xt STRICT_TOOLS=1
make pic10f322 PIC10F322_BUILD_DIR=build_pic10f322 PIC_CC=/opt/microchip/xc8/v3.10/bin/xc8-cc PIC_DFP=/opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8
make pic10f320-variants PIC10F320_BUILD_DIR=build_pic10f320 PIC10F320_CC=/opt/microchip/xc8/v3.10/bin/xc8-cc PIC10F320_DFP=/opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8
make pic12f675 PIC12F675_BUILD_DIR=build_pic12f675 PIC_CC=/opt/microchip/xc8/v3.10/bin/xc8-cc PIC_DFP=/opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8
scripts/verify-release-images.sh release/v0.9.12 build_avr_classic build_avr_xt build_pic10f322 build_pic10f320 build_pic12f675
```
A passing verifier proves four things agree: the committed files, the checksum
entries, the freshly built files, and the canonical `RELEASE_IMAGES` set the
Makefile declares. The fourth is what makes the first three mean something --
three sets derived by globbing the same directories agree perfectly on a
release that is missing an entire MCU.
The tag-triggered CI (.github/workflows/release.yml) runs this exact check on a
clean runner and fails the release on any mismatch.
