# Firmware release v0.9.7

Prebuilt, fully-validated firmware images. Verify integrity with
`sha256sum -c SHA256SUMS`; reproduce from source per "Reproducing" below.

Release scope: AVR Classic (ATtiny13a/45/85), ATtiny202 (AVR-XT),
PIC10F322 and PIC10F320.

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

Full detail: [docs/pic10f320_special_case.md](https://github.com/matt-garman/mcu-bypass-firmware/blob/v0.9.7/docs/pic10f320_special_case.md).

Its images use a different basename prefix from every other target
(`bypass_mcu_<variant>_pic10f320.hex`), inherited from the project it was merged
from and deliberately not renamed. Match images to MCUs by the table below,
not by prefix.

## Provenance

- **Version / tag:** v0.9.7
- **Release mode:** production
- **Source commit:** `1d2fc8777f3fc845e95df83ab8af8825f8f987e1`
- **Soak duration per combination:** 86400000 ms
- **Soak combinations:** 15
- **Built:** 2026-08-02T00:15:13Z by `matt` on `Linux 6.12.33-production+truenas x86_64`
- **Validation:** `make test-long` + `make attiny202-test` + `make attiny202-test-target` + `make pic-test` + `make pic-test-target-variants` + `make pic320-test` + `make pic320-test-target-variants` (real-image fault handling, firmware/model ctx_ lock-step, and physical-output checks across AVR-XT and both PIC parts) + 24.0-h parallel soak of every release soak combination (see evidence/).
- **Release set:** 18 images, checked against the canonical `RELEASE_IMAGES` set declared in the Makefile -- not against whatever the build happened to produce.

## Toolchain

| tool | version |
|---|---|
| avr-gcc | avr-gcc (GCC) 7.3.0 |
| binutils-avr (objcopy) | GNU objcopy (AVR_8_bit_GNU_Toolchain_3.6.7_635) 2.26.20160125 |
| avr-libc (pkg) | 1:2.0.0+Atmel3.7.0-1 |
| host cc | cc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0 |
| PIC10F322 XC8 (`PIC_CC=/opt/microchip/xc8/v3.10/bin/xc8-cc`) | Microchip MPLAB XC8 C Compiler V3.10 |
| PIC10F320 XC8 (`PIC320_CC=/opt/microchip/xc8/v3.10/bin/xc8-cc`) | Microchip MPLAB XC8 C Compiler V3.10 |
| PIC10F322 DFP | /opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8 |
| PIC10F320 DFP | /opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8 |
| gpsim | gpsim-0.32.1 # (Mar 31 2024) |
| libsimavr-dev (pkg) | 1.6+dfsg-3build2 |
| cppcheck | Cppcheck 2.13.0 |
| cbmc | 5.95.1 (cbmc-5.95.1) |
| clang | Ubuntu clang version 18.1.3 (1ubuntu1) |
| python3 | Python 3.12.3 |

## Images

| image | MCU | clock | flash used | fuses / config | sha256 |
|---|---|---|---|---|---|
| `bypass_cd4053.hex` | ATtiny13a | 1.2 MHz | 716 B | lfuse=0x4a hfuse=0xf9 | `ba85f52857e114c443022ebf446a887b290be4a6a8d325a08e388a67a51797e8` |
| `bypass_mute.hex` | ATtiny13a | 1.2 MHz | 756 B | lfuse=0x4a hfuse=0xf9 | `298bc5f19e1202cf955d015249f55350990332d82ee0382458d5881eac8e2c8b` |
| `bypass_relay.hex` | ATtiny13a | 1.2 MHz | 756 B | lfuse=0x4a hfuse=0xf9 | `a2eedf49a0f62073cfa62e3bc11619294cfbb4f630799bc20b54bbbe14ff943c` |
| `bypass_cd4053_t85.hex` | ATtiny85 | 1.0 MHz | 742 B | lfuse=0x62 hfuse=0xcc | `5ceda46ba94566ef13cf086f1cafd36151e9e9c725ee59fb819e3cb5dfae67e2` |
| `bypass_cd4053_t45.hex` | ATtiny45 | 1.0 MHz | 742 B | lfuse=0x62 hfuse=0xcc | `2fb5437e6c0561e41ceb6a5c6069185545dd03992639756f8b5ae4e61ca5f675` |
| `bypass_mute_t85.hex` | ATtiny85 | 1.0 MHz | 782 B | lfuse=0x62 hfuse=0xcc | `28cdf3b574f0d9f7498bea3c3d9415bd43152a540594c46c38063de20911fead` |
| `bypass_mute_t45.hex` | ATtiny45 | 1.0 MHz | 782 B | lfuse=0x62 hfuse=0xcc | `2d0aa3cdc8e03e30eadf04ba3bbcbdff5e8f048e557c9ead5158d6a30189de88` |
| `bypass_relay_t85.hex` | ATtiny85 | 1.0 MHz | 782 B | lfuse=0x62 hfuse=0xcc | `26bfff00d759ff1d796b5dac9928dac217901164c85481507d4b0ce60e1f0503` |
| `bypass_relay_t45.hex` | ATtiny45 | 1.0 MHz | 782 B | lfuse=0x62 hfuse=0xcc | `abc340ce2ae16c9a116861c4eff823f60ea822dcb8fc9e361836abb345564c25` |
| `bypass_cd4053_attiny202.hex` | ATtiny202 | 2 MHz (internal, OSCCFG 16 MHz / 8) | 848 B | wdtcfg=0x06 bodcfg=0xE5 osccfg=0x01 syscfg0=0xF6 syscfg1=0x07 append=0x00 bootend=0x00 | `5d600a243b38ed3a62e009dd3302795d8effa3d13316d868841b3df31150ad3f` |
| `bypass_mute_attiny202.hex` | ATtiny202 | 2 MHz (internal, OSCCFG 16 MHz / 8) | 888 B | wdtcfg=0x06 bodcfg=0xE5 osccfg=0x01 syscfg0=0xF6 syscfg1=0x07 append=0x00 bootend=0x00 | `8835bfe29da3cf8e98d53e501aa8fd19cb2d3df09441f9b94bde70c3238abba6` |
| `bypass_relay_attiny202.hex` | ATtiny202 | 2 MHz (internal, OSCCFG 16 MHz / 8) | 888 B | wdtcfg=0x06 bodcfg=0xE5 osccfg=0x01 syscfg0=0xF6 syscfg1=0x07 append=0x00 bootend=0x00 | `370bbd192129da862a02fd4fee24a5fe3130af96dc165917d0b9bf63477efbcb` |
| `bypass_cd4053_pic10f322.hex` | PIC10F322 | 2 MHz (HFINTOSC) | n/a | CONFIG word embedded in HEX | `c0a16d96d89d2f44352aa6bb831f5db85c17858aede1f639cf3079f70f8f70ae` |
| `bypass_mute_pic10f322.hex` | PIC10F322 | 2 MHz (HFINTOSC) | n/a | CONFIG word embedded in HEX | `01d7b27bfe04a99dbbfc91ca64fab048a017e24b4a3c7185e32623d11c95940c` |
| `bypass_relay_pic10f322.hex` | PIC10F322 | 2 MHz (HFINTOSC) | n/a | CONFIG word embedded in HEX | `2a0a0ccd0b159797b2a090a2e7f5b6d48bd827eef5408772df95d1a604f4215b` |
| `bypass_mcu_cd4053-simple_pic10f320.hex` | PIC10F320 | 2 MHz (HFINTOSC) | 220 / 256 words | CONFIG word embedded in HEX | `e48ed8e50e89a7f2c2e145603d16c25099925269ea0b29b31becc9c02eb2143f` |
| `bypass_mcu_cd4053-mute_pic10f320.hex` | PIC10F320 | 2 MHz (HFINTOSC) | 241 / 256 words | CONFIG word embedded in HEX | `1cc2cbf6572a876b1a0a5d19e2e3179a41c7a46bd1b7419d2b5e72aa2aec27a7` |
| `bypass_mcu_tq2-relay_pic10f320.hex` | PIC10F320 | 2 MHz (HFINTOSC) | 244 / 256 words | CONFIG word embedded in HEX | `b30783d20e1ef088b3fa612cb7c41755b48ba1060395e01cf7360ea664d1e50f` |

> The ATtiny13a images are not soak-tested directly (simavr cannot model
> its watchdog reset); they are covered by the full test-long suite and by
> the soak of the core-identical tinyx5 family. See DESIGN_DOCUMENTATION.adoc.

## Flashing

AVR images require the design fuse bytes in addition to the flash write
(the table above lists them per image). PIC images embed their CONFIG word.

```
# bypass_cd4053_attiny202.hex
avrdude -c serialupdi -P <port> -p t202 -U wdtcfg:w:0x06:m -U bodcfg:w:0xE5:m -U osccfg:w:0x01:m -U syscfg0:w:0xF6:m -U syscfg1:w:0x07:m -U append:w:0x00:m -U bootend:w:0x00:m -U flash:w:bypass_cd4053_attiny202.hex:i   (or: make attiny202-program VARIANT=<v> XT_UPDI_PORT=<port>)

# bypass_cd4053.hex
avrdude -c <prog> -p t13 -U lfuse:w:0x4a:m -U hfuse:w:0xf9:m -U flash:w:bypass_cd4053.hex:i

# bypass_cd4053_pic10f322.hex
pk2cmd -PPIC10F322 -Fbypass_cd4053_pic10f322.hex -M -Y -R   (or: make program-pic VARIANT=<v>)

# bypass_cd4053_t45.hex
avrdude -c <prog> -p t45 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass_cd4053_t45.hex:i

# bypass_cd4053_t85.hex
avrdude -c <prog> -p t85 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass_cd4053_t85.hex:i

# bypass_mcu_cd4053-mute_pic10f320.hex
pk2cmd -PPIC10F320 -Fbypass_mcu_cd4053-mute_pic10f320.hex -M -Y -R

# bypass_mcu_cd4053-simple_pic10f320.hex
pk2cmd -PPIC10F320 -Fbypass_mcu_cd4053-simple_pic10f320.hex -M -Y -R

# bypass_mcu_tq2-relay_pic10f320.hex
pk2cmd -PPIC10F320 -Fbypass_mcu_tq2-relay_pic10f320.hex -M -Y -R

# bypass_mute_attiny202.hex
avrdude -c serialupdi -P <port> -p t202 -U wdtcfg:w:0x06:m -U bodcfg:w:0xE5:m -U osccfg:w:0x01:m -U syscfg0:w:0xF6:m -U syscfg1:w:0x07:m -U append:w:0x00:m -U bootend:w:0x00:m -U flash:w:bypass_mute_attiny202.hex:i   (or: make attiny202-program VARIANT=<v> XT_UPDI_PORT=<port>)

# bypass_mute.hex
avrdude -c <prog> -p t13 -U lfuse:w:0x4a:m -U hfuse:w:0xf9:m -U flash:w:bypass_mute.hex:i

# bypass_mute_pic10f322.hex
pk2cmd -PPIC10F322 -Fbypass_mute_pic10f322.hex -M -Y -R   (or: make program-pic VARIANT=<v>)

# bypass_mute_t45.hex
avrdude -c <prog> -p t45 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass_mute_t45.hex:i

# bypass_mute_t85.hex
avrdude -c <prog> -p t85 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass_mute_t85.hex:i

# bypass_relay_attiny202.hex
avrdude -c serialupdi -P <port> -p t202 -U wdtcfg:w:0x06:m -U bodcfg:w:0xE5:m -U osccfg:w:0x01:m -U syscfg0:w:0xF6:m -U syscfg1:w:0x07:m -U append:w:0x00:m -U bootend:w:0x00:m -U flash:w:bypass_relay_attiny202.hex:i   (or: make attiny202-program VARIANT=<v> XT_UPDI_PORT=<port>)

# bypass_relay.hex
avrdude -c <prog> -p t13 -U lfuse:w:0x4a:m -U hfuse:w:0xf9:m -U flash:w:bypass_relay.hex:i

# bypass_relay_pic10f322.hex
pk2cmd -PPIC10F322 -Fbypass_relay_pic10f322.hex -M -Y -R   (or: make program-pic VARIANT=<v>)

# bypass_relay_t45.hex
avrdude -c <prog> -p t45 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass_relay_t45.hex:i

# bypass_relay_t85.hex
avrdude -c <prog> -p t85 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass_relay_t85.hex:i

```

## Soak evidence

| combo | result |
|---|---|
| avr_cd4053_t85 | SOAK PASS: 86400000 ms (24.0 h) simulated. |
| avr_cd4053_t45 | SOAK PASS: 86400000 ms (24.0 h) simulated. |
| avr_mute_t85 | SOAK PASS: 86400000 ms (24.0 h) simulated. |
| avr_mute_t45 | SOAK PASS: 86400000 ms (24.0 h) simulated. |
| avr_relay_t85 | SOAK PASS: 86400000 ms (24.0 h) simulated. |
| avr_relay_t45 | SOAK PASS: 86400000 ms (24.0 h) simulated. |
| attiny202_cd4053 | SOAK PASS: 86400000 ms (24.00 h) simulated. resets=0 liveness_fails=0 checks=1440 witness_checks=92160 in 612.7s wall. |
| attiny202_mute | SOAK PASS: 86400000 ms (24.00 h) simulated. resets=0 liveness_fails=0 checks=1440 witness_checks=92160 in 623.5s wall. |
| attiny202_relay | SOAK PASS: 86400000 ms (24.00 h) simulated. resets=0 liveness_fails=0 checks=1440 witness_checks=92160 in 622.6s wall. |
| pic_cd4053 | SOAK PASS: 86400000 ms (24.00 h) simulated. wdt_resets=0 liveness_fails=0 checks=1440 |
| pic_mute | SOAK PASS: 86400000 ms (24.00 h) simulated. wdt_resets=0 liveness_fails=0 checks=1440 |
| pic_relay | SOAK PASS: 86400000 ms (24.00 h) simulated. wdt_resets=0 liveness_fails=0 checks=1440 |
| pic320_cd4053-simple | SOAK PASS: 86400000 ms (24.00 h) simulated. wdt_resets=0 liveness_fails=0 checks=1440 |
| pic320_cd4053-mute | SOAK PASS: 86400000 ms (24.00 h) simulated. wdt_resets=0 liveness_fails=0 checks=1440 |
| pic320_tq2-relay | SOAK PASS: 86400000 ms (24.00 h) simulated. wdt_resets=0 liveness_fails=0 checks=1440 |

## Reproducing these images

Check the images this tag *builds* against the committed checksums. A
freshly built HEX lands under `build_avr_classic/` `build_avr_xt/` `build_pic/` `build_pic10f320/`, not
in this release directory, so the checksum list must be run against those
fresh bytes (running it from the repo root would just re-verify the
committed copies against themselves).

```
git checkout v0.9.7
# install the pinned toolchain (see TOOLCHAIN.adoc), then:
make clean && make all13 all85 all45 && make attiny202
make pic && make pic320-variants
scripts/verify-release-images.sh release/v0.9.7 build_avr_classic build_avr_xt build_pic build_pic10f320
```
A passing verifier proves four things agree: the committed files, the checksum
entries, the freshly built files, and the canonical `RELEASE_IMAGES` set the
Makefile declares. The fourth is what makes the first three mean something --
three sets derived by globbing the same directories agree perfectly on a
release that is missing an entire MCU.
The tag-triggered CI (.github/workflows/release.yml) runs this exact check on a
clean runner and fails the release on any mismatch.
