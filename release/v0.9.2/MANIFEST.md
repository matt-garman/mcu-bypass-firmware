# Firmware release v0.9.2

> [!WARNING]
> The `bypass_cd4053_tmux*.hex` and `bypass_mute_tmux*.hex` images in this
> release use an incorrect direct-drive polarity: the TMUX4053 board's
> absent/undriven-MCU pull-down state selects ENGAGED instead of fail-safe
> BYPASS. They are retained only for historical reproducibility. **Do not flash
> them for new TMUX4053 hardware.** Use `v0.9.3` or later and select the
> corresponding image without `_tmux` in its filename. See the
> [top-level safety warning](../README.md#safety-warning-v090-v092-tmux-images).

Prebuilt historical firmware images. Verify integrity with
`sha256sum -c SHA256SUMS`; reproduce from source per "Reproducing" below.

## Provenance

- **Version / tag:** v0.9.2
- **Source commit:** `9cd7df3bc0a343ad06af335c46dc7eb8657ee49e`
- **Built:** 2026-07-09T15:21:07Z by `matt` on `Linux 6.12.33-production+truenas x86_64`
- **Validation:** `make test-long` + `make pic-test` + `make pic-test-fault` (gpsim SFR/pull-up/ctx_ fault injection) + 24.0-h parallel soak of every variant x MCU (see evidence/).

## Toolchain

| tool | version |
|---|---|
| avr-gcc | avr-gcc (GCC) 7.3.0 |
| binutils-avr (objcopy) | GNU objcopy (GNU Binutils) 2.26.20160125 |
| avr-libc (pkg) | 1:2.0.0+Atmel3.7.0-1 |
| host cc | cc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0 |
| XC8 | Microchip MPLAB XC8 C Compiler V3.10 |
| PIC DFP | /opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8 |
| gpsim | gpsim-0.32.1 # (Mar 31 2024) |
| libsimavr-dev (pkg) | 1.6+dfsg-3build2 |
| cppcheck | Cppcheck 2.13.0 |
| cbmc | 5.95.1 (cbmc-5.95.1) |
| clang | Ubuntu clang version 18.1.3 (1ubuntu1) |
| python3 | Python 3.14.5 |

## Images

| image | MCU | clock | flash used | fuses / config | sha256 |
|---|---|---|---|---|---|
| `bypass_cd4053.hex` | ATtiny13a | 1.2 MHz | 684 B | lfuse=0x4a hfuse=0xf9 | `f1240a8cb03456a1e7e273d85f11a54e7b50e6ffa84f3f2c8921e7001479c08f` |
| `bypass_cd4053_tmux.hex` | ATtiny13a | 1.2 MHz | 684 B | lfuse=0x4a hfuse=0xf9 | `46fa34da8f20acc5a51bf0deec938b942efe6b5a7aeb6054371da34f6487f8e7` |
| `bypass_mute.hex` | ATtiny13a | 1.2 MHz | 732 B | lfuse=0x4a hfuse=0xf9 | `1d9e7b2462bc467077d6276ca005b2b9ef16036f4179b699a5c94c045d00ecb1` |
| `bypass_mute_tmux.hex` | ATtiny13a | 1.2 MHz | 732 B | lfuse=0x4a hfuse=0xf9 | `bacd4bbc805e02f05b9b16d492c715d351e89da1d77c7e90d91413ac725bc05f` |
| `bypass_relay.hex` | ATtiny13a | 1.2 MHz | 724 B | lfuse=0x4a hfuse=0xf9 | `3308d5d09eafd01f431765cdf8ced4475607b82c962375126d43a0e6e28efb53` |
| `bypass_cd4053_t85.hex` | ATtiny85 | 1.0 MHz | 710 B | lfuse=0x62 hfuse=0xcc | `7378e78de94d443cf3718cc879ba8baa557fe7acd3edad28f5d40a9304d2c674` |
| `bypass_cd4053_t45.hex` | ATtiny45 | 1.0 MHz | 710 B | lfuse=0x62 hfuse=0xcc | `e1a47fa115078a7a6794e63d7aae513d64b90f3f694b16671ec2548d8078fda7` |
| `bypass_cd4053_tmux_t85.hex` | ATtiny85 | 1.0 MHz | 710 B | lfuse=0x62 hfuse=0xcc | `fc524a529a5d6103702894dbdba49f501d53a02607ac35852be6aece885a4161` |
| `bypass_cd4053_tmux_t45.hex` | ATtiny45 | 1.0 MHz | 710 B | lfuse=0x62 hfuse=0xcc | `d4ecbde708c7acaf8748ae1b3744e58e527efa9c26deadc0964aa71cb400dbd1` |
| `bypass_mute_t85.hex` | ATtiny85 | 1.0 MHz | 758 B | lfuse=0x62 hfuse=0xcc | `a31ce7ba9c0719bbdbf3a3ee4402b0ef90691059ebe53228da3779e1fe9b0b9b` |
| `bypass_mute_t45.hex` | ATtiny45 | 1.0 MHz | 758 B | lfuse=0x62 hfuse=0xcc | `7265d37ea0a94562225c02578b7a19e51ba781f203319adf870fc1d97089e3ba` |
| `bypass_mute_tmux_t85.hex` | ATtiny85 | 1.0 MHz | 758 B | lfuse=0x62 hfuse=0xcc | `a5c1f21483ab856fcb122896ed09f21f20a8c8452a93de2da312c7d893c542c6` |
| `bypass_mute_tmux_t45.hex` | ATtiny45 | 1.0 MHz | 758 B | lfuse=0x62 hfuse=0xcc | `a7bf0d8f0ae58ee592ad4465ff279819f8756b452f232f71003f204407ec3820` |
| `bypass_relay_t85.hex` | ATtiny85 | 1.0 MHz | 750 B | lfuse=0x62 hfuse=0xcc | `faefac600abb7ef73473fe30664c75b2680830e783abb2752afe8fde88c86f48` |
| `bypass_relay_t45.hex` | ATtiny45 | 1.0 MHz | 750 B | lfuse=0x62 hfuse=0xcc | `ea494c60cb214e6f1088d606f3be77e53617f7446560cace1810c85caf249043` |
| `bypass_cd4053_pic10f322.hex` | PIC10F322 | 16 MHz (INTOSC) | n/a | CONFIG word embedded in HEX | `42ac9799ff5abe7977a05b866f894f41f37f259643a7608e0d5a274ad73220b8` |
| `bypass_cd4053_tmux_pic10f322.hex` | PIC10F322 | 16 MHz (INTOSC) | n/a | CONFIG word embedded in HEX | `30f70da34c85f4f35ecd44e518d9e937c8a393cc0ab22b568f9a68b490967389` |
| `bypass_mute_pic10f322.hex` | PIC10F322 | 16 MHz (INTOSC) | n/a | CONFIG word embedded in HEX | `bc1c4367666988b001eef920d728e69d28639bffedbb0e6260b65f29d4b0c93e` |
| `bypass_mute_tmux_pic10f322.hex` | PIC10F322 | 16 MHz (INTOSC) | n/a | CONFIG word embedded in HEX | `774fbe4b0c3eb6fa101b80e5f9b537798a4d935e051de5d809238e7c8d71ec52` |
| `bypass_relay_pic10f322.hex` | PIC10F322 | 16 MHz (INTOSC) | n/a | CONFIG word embedded in HEX | `bf2c7dedb4b80df10cd7a434037a0b5501fa7736fbb197eef29682e749995a07` |

> The ATtiny13a images are not soak-tested directly (simavr cannot model
> its watchdog reset); they are covered by the full test-long suite and by
> the soak of the core-identical tinyx5 family. See DESIGN_DOCUMENTATION.adoc.

## Flashing

AVR images require the design fuse bytes in addition to the flash write
(the table above lists them per image). PIC images embed their CONFIG word.

```
# bypass_cd4053.hex
avrdude -c <prog> -p t13 -U lfuse:w:0x4a:m -U hfuse:w:0xf9:m -U flash:w:bypass_cd4053.hex:i

# bypass_cd4053_pic10f322.hex
pk2cmd -PPIC10F322 -Fbypass_cd4053_pic10f322.hex -M -Y -R   (or: make program-pic VARIANT=<v>)

# bypass_cd4053_t45.hex
avrdude -c <prog> -p t45 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass_cd4053_t45.hex:i

# bypass_cd4053_t85.hex
avrdude -c <prog> -p t85 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass_cd4053_t85.hex:i

# bypass_cd4053_tmux.hex
avrdude -c <prog> -p t13 -U lfuse:w:0x4a:m -U hfuse:w:0xf9:m -U flash:w:bypass_cd4053_tmux.hex:i

# bypass_cd4053_tmux_pic10f322.hex
pk2cmd -PPIC10F322 -Fbypass_cd4053_tmux_pic10f322.hex -M -Y -R   (or: make program-pic VARIANT=<v>)

# bypass_cd4053_tmux_t45.hex
avrdude -c <prog> -p t45 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass_cd4053_tmux_t45.hex:i

# bypass_cd4053_tmux_t85.hex
avrdude -c <prog> -p t85 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass_cd4053_tmux_t85.hex:i

# bypass_mute.hex
avrdude -c <prog> -p t13 -U lfuse:w:0x4a:m -U hfuse:w:0xf9:m -U flash:w:bypass_mute.hex:i

# bypass_mute_pic10f322.hex
pk2cmd -PPIC10F322 -Fbypass_mute_pic10f322.hex -M -Y -R   (or: make program-pic VARIANT=<v>)

# bypass_mute_t45.hex
avrdude -c <prog> -p t45 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass_mute_t45.hex:i

# bypass_mute_t85.hex
avrdude -c <prog> -p t85 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass_mute_t85.hex:i

# bypass_mute_tmux.hex
avrdude -c <prog> -p t13 -U lfuse:w:0x4a:m -U hfuse:w:0xf9:m -U flash:w:bypass_mute_tmux.hex:i

# bypass_mute_tmux_pic10f322.hex
pk2cmd -PPIC10F322 -Fbypass_mute_tmux_pic10f322.hex -M -Y -R   (or: make program-pic VARIANT=<v>)

# bypass_mute_tmux_t45.hex
avrdude -c <prog> -p t45 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass_mute_tmux_t45.hex:i

# bypass_mute_tmux_t85.hex
avrdude -c <prog> -p t85 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass_mute_tmux_t85.hex:i

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
| avr_cd4053_tmux_t85 | SOAK PASS: 86400000 ms (24.0 h) simulated. |
| avr_cd4053_tmux_t45 | SOAK PASS: 86400000 ms (24.0 h) simulated. |
| avr_mute_t85 | SOAK PASS: 86400000 ms (24.0 h) simulated. |
| avr_mute_t45 | SOAK PASS: 86400000 ms (24.0 h) simulated. |
| avr_mute_tmux_t85 | SOAK PASS: 86400000 ms (24.0 h) simulated. |
| avr_mute_tmux_t45 | SOAK PASS: 86400000 ms (24.0 h) simulated. |
| avr_relay_t85 | SOAK PASS: 86400000 ms (24.0 h) simulated. |
| avr_relay_t45 | SOAK PASS: 86400000 ms (24.0 h) simulated. |
| pic_cd4053 | SOAK PASS: 24.00 h simulated. wdt_resets=0 liveness_fails=0 checks=1440 |
| pic_cd4053_tmux | SOAK PASS: 24.00 h simulated. wdt_resets=0 liveness_fails=0 checks=1440 |
| pic_mute | SOAK PASS: 24.00 h simulated. wdt_resets=0 liveness_fails=0 checks=1440 |
| pic_mute_tmux | SOAK PASS: 24.00 h simulated. wdt_resets=0 liveness_fails=0 checks=1440 |
| pic_relay | SOAK PASS: 24.00 h simulated. wdt_resets=0 liveness_fails=0 checks=1440 |

## Reproducing these images

```
git checkout v0.9.2
# install the pinned toolchain (see TOOLCHAIN.adoc), then:
make clean && make all13 all85 all45 && make pic
sha256sum -c release/v0.9.2/SHA256SUMS
```
The tag-triggered CI (.github/workflows/release.yml) performs exactly this
check on a clean runner and fails the release on any mismatch.
