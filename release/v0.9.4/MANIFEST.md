# Firmware release v0.9.4

Prebuilt, fully-validated firmware images. Verify integrity with
`sha256sum -c SHA256SUMS`; reproduce from source per "Reproducing" below.

## Provenance

- **Version / tag:** v0.9.4
- **Source commit:** `03c2f9f8c033a497072d43fd8bfd7d87121f4668`
- **Built:** 2026-07-12T02:03:53Z by `matt` on `Linux 6.12.33-production+truenas x86_64`
- **Validation:** `make test-long` + `make pic-test` + `make pic-test-target-variants` (real-HEX SFR/SRAM fault recovery, firmware/model ctx_ lock-step, and GPIO transition/pulse timing) + 24.0-h parallel soak of every variant x MCU (see evidence/).

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
| `bypass_mute.hex` | ATtiny13a | 1.2 MHz | 724 B | lfuse=0x4a hfuse=0xf9 | `24b8904e5dad2ee1b7b3d1a8cff5a54cef91e90a805395360ad326a51886fd52` |
| `bypass_relay.hex` | ATtiny13a | 1.2 MHz | 724 B | lfuse=0x4a hfuse=0xf9 | `3308d5d09eafd01f431765cdf8ced4475607b82c962375126d43a0e6e28efb53` |
| `bypass_cd4053_t85.hex` | ATtiny85 | 1.0 MHz | 710 B | lfuse=0x62 hfuse=0xcc | `7378e78de94d443cf3718cc879ba8baa557fe7acd3edad28f5d40a9304d2c674` |
| `bypass_cd4053_t45.hex` | ATtiny45 | 1.0 MHz | 710 B | lfuse=0x62 hfuse=0xcc | `e1a47fa115078a7a6794e63d7aae513d64b90f3f694b16671ec2548d8078fda7` |
| `bypass_mute_t85.hex` | ATtiny85 | 1.0 MHz | 750 B | lfuse=0x62 hfuse=0xcc | `a852404cf7cbd3d71011e1aad83f4f33b6096e388f1187f55ecdee30fe8c5ff0` |
| `bypass_mute_t45.hex` | ATtiny45 | 1.0 MHz | 750 B | lfuse=0x62 hfuse=0xcc | `eed74a8ace37d49766d5d92c2d3e1c433650b4656288ef610bcc1c45954c583c` |
| `bypass_relay_t85.hex` | ATtiny85 | 1.0 MHz | 750 B | lfuse=0x62 hfuse=0xcc | `faefac600abb7ef73473fe30664c75b2680830e783abb2752afe8fde88c86f48` |
| `bypass_relay_t45.hex` | ATtiny45 | 1.0 MHz | 750 B | lfuse=0x62 hfuse=0xcc | `ea494c60cb214e6f1088d606f3be77e53617f7446560cace1810c85caf249043` |
| `bypass_cd4053_pic10f322.hex` | PIC10F322 | 2 MHz (HFINTOSC) | n/a | CONFIG word embedded in HEX | `abdde605cb15c3c6202e42bbc55fedcd2e7ffd886e08a01b7c87f30593a7c33c` |
| `bypass_mute_pic10f322.hex` | PIC10F322 | 2 MHz (HFINTOSC) | n/a | CONFIG word embedded in HEX | `a81c5912bbb49bda18234ddc63c9e1b68812ad195d9c176e858e9b2150e3ed64` |
| `bypass_relay_pic10f322.hex` | PIC10F322 | 2 MHz (HFINTOSC) | n/a | CONFIG word embedded in HEX | `adadf0a5ea59badb32fa3f123c502d7d09cd1fb7e2e19cbd528738339a7e434e` |

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

# bypass_mute.hex
avrdude -c <prog> -p t13 -U lfuse:w:0x4a:m -U hfuse:w:0xf9:m -U flash:w:bypass_mute.hex:i

# bypass_mute_pic10f322.hex
pk2cmd -PPIC10F322 -Fbypass_mute_pic10f322.hex -M -Y -R   (or: make program-pic VARIANT=<v>)

# bypass_mute_t45.hex
avrdude -c <prog> -p t45 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass_mute_t45.hex:i

# bypass_mute_t85.hex
avrdude -c <prog> -p t85 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m -U flash:w:bypass_mute_t85.hex:i

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
| pic_cd4053 | SOAK PASS: 24.00 h simulated. wdt_resets=0 liveness_fails=0 checks=1440 |
| pic_mute | SOAK PASS: 24.00 h simulated. wdt_resets=0 liveness_fails=0 checks=1440 |
| pic_relay | SOAK PASS: 24.00 h simulated. wdt_resets=0 liveness_fails=0 checks=1440 |

## Reproducing these images

Check the images this tag *builds* against the committed checksums. A
freshly built HEX lands under `build_avr_classic/` and `build_pic/`, not
in this release directory, so the checksum list must be run against those
fresh bytes (running it from the repo root would just re-verify the
committed copies against themselves).

```
git checkout v0.9.4
# install the pinned toolchain (see TOOLCHAIN.adoc), then:
make clean && make all13 all85 all45 && make pic
tmp=$(mktemp -d)
cp build_avr_classic/*.hex build_pic/*.hex "$tmp"/
( cd "$tmp" && sha256sum -c "$OLDPWD/release/v0.9.4/SHA256SUMS" )
```
A matching `sha256sum -c` proves your freshly built images are byte-identical
to the published ones. The tag-triggered CI (.github/workflows/release.yml)
performs exactly this fresh-build check on a clean runner -- and also asserts
the release image set is complete -- failing the release on any mismatch.
