# Firmware release v0.9.0

Prebuilt, fully-validated firmware images. Verify integrity with
`sha256sum -c SHA256SUMS`; reproduce from source per "Reproducing" below.

## Provenance

- **Version / tag:** v0.9.0
- **Source commit:** `91cd962df6c709a71c4bf4682ee45db1cb287f5f`
- **Built:** 2026-07-01T00:21:27Z by `matt` on `Linux 6.12.33-production+truenas x86_64`
- **Validation:** `make test-long` + `make pic-test` + 24.0-h parallel soak of every variant x MCU (see evidence/).

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
| `bypass_cd4053.hex` | ATtiny13a | 1.2 MHz | 628 B | lfuse=0x4a hfuse=0xf9 | `a446bf3a667dbc42187a2013026a37cf0e628bd4eb91d6276301b9db4e2cdd49` |
| `bypass_cd4053_tmux.hex` | ATtiny13a | 1.2 MHz | 628 B | lfuse=0x4a hfuse=0xf9 | `c5b93baea68cbd1d053be3b1abd7a5a9ef5ad13ebd80b23999c6ceb30b5e63bb` |
| `bypass_mute.hex` | ATtiny13a | 1.2 MHz | 676 B | lfuse=0x4a hfuse=0xf9 | `3dbee2ea06646aad50690b1863ad1ab2f317c221a5926493523cf10a4b0f6463` |
| `bypass_mute_tmux.hex` | ATtiny13a | 1.2 MHz | 676 B | lfuse=0x4a hfuse=0xf9 | `feecdb59987a8eae0b68e27f56ab3c2d835041861cde34faee54b83d0e35605b` |
| `bypass_relay.hex` | ATtiny13a | 1.2 MHz | 668 B | lfuse=0x4a hfuse=0xf9 | `053f193a7076b2c8678811ad186beb895cdf0d89598176c302aaa2e92ea10c59` |
| `bypass_cd4053_t85.hex` | ATtiny85 | 1.0 MHz | 654 B | lfuse=0x62 hfuse=0xcc | `383eee8540a1874d98516720e25f869cdfb899a49e386f612f98d4d1fd230b18` |
| `bypass_cd4053_t45.hex` | ATtiny45 | 1.0 MHz | 654 B | lfuse=0x62 hfuse=0xcc | `c0411363d614583dc8a493aff07a5fbe5ceff98c39f2dd62cf75bd2378f7a9c8` |
| `bypass_cd4053_tmux_t85.hex` | ATtiny85 | 1.0 MHz | 654 B | lfuse=0x62 hfuse=0xcc | `b6ef198f8cc1d83019e5b7cc7d6adcf718ceca7ac39b283cb9744220105e57a4` |
| `bypass_cd4053_tmux_t45.hex` | ATtiny45 | 1.0 MHz | 654 B | lfuse=0x62 hfuse=0xcc | `ea143b4780edfced76bb4e060134dafa95f3ed0531ddebd4a32142879f7367aa` |
| `bypass_mute_t85.hex` | ATtiny85 | 1.0 MHz | 702 B | lfuse=0x62 hfuse=0xcc | `9ed3d15ea128950ccd0d288beedd48865c4d8864e0b396164d7dc9f44c9b8dff` |
| `bypass_mute_t45.hex` | ATtiny45 | 1.0 MHz | 702 B | lfuse=0x62 hfuse=0xcc | `746a78f15d4a070ac2887872201fc156f4baacede4ff8bd610741d3a97052322` |
| `bypass_mute_tmux_t85.hex` | ATtiny85 | 1.0 MHz | 702 B | lfuse=0x62 hfuse=0xcc | `79fb653c109ad594fc6b1bfeca64f9cbeaec182b63cfb1974168cdbb64c7362e` |
| `bypass_mute_tmux_t45.hex` | ATtiny45 | 1.0 MHz | 702 B | lfuse=0x62 hfuse=0xcc | `f0e76a9209551d84a8c9f634162f3e868bc0cfe47c21ceed715974fa83004da7` |
| `bypass_relay_t85.hex` | ATtiny85 | 1.0 MHz | 694 B | lfuse=0x62 hfuse=0xcc | `09990e409329fe07ec7c59fa06a7fe62bc4f9bb3a7419592fbbceb6fd052f40f` |
| `bypass_relay_t45.hex` | ATtiny45 | 1.0 MHz | 694 B | lfuse=0x62 hfuse=0xcc | `ab408acefd42197562f06e503d0006f683cb8b64da4623a680ccc487d55acac6` |
| `bypass_cd4053_pic10f322.hex` | PIC10F322 | 16 MHz (INTOSC) | n/a | CONFIG word embedded in HEX | `b0217c057aeff182b7b21edfb1dd286a1e79a6ccffe9d8c7ebb19c4e34eece68` |
| `bypass_cd4053_tmux_pic10f322.hex` | PIC10F322 | 16 MHz (INTOSC) | n/a | CONFIG word embedded in HEX | `5bf3976a6153d6e987bf81bf034d4733757ffe1d57b3820dbc998568ad46b40d` |
| `bypass_mute_pic10f322.hex` | PIC10F322 | 16 MHz (INTOSC) | n/a | CONFIG word embedded in HEX | `5d42c7199f5a105f489efa81c1826c9e9329decd25ff06e557423782163230c2` |
| `bypass_mute_tmux_pic10f322.hex` | PIC10F322 | 16 MHz (INTOSC) | n/a | CONFIG word embedded in HEX | `a130c42735710d2c0d304a629b17ae2890a3c1a7f7371dd3287ed559ed1bc3bc` |
| `bypass_relay_pic10f322.hex` | PIC10F322 | 16 MHz (INTOSC) | n/a | CONFIG word embedded in HEX | `407e1e7d4c6c88e07d5969ad222f8f6b34e1397b8d59049632ab66d6a4b98053` |

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
git checkout v0.9.0
# install the pinned toolchain (see TOOLCHAIN.adoc), then:
make clean && make all13 all85 all45 && make pic
sha256sum -c release/v0.9.0/SHA256SUMS
```
The tag-triggered CI (.github/workflows/release.yml) performs exactly this
check on a clean runner and fails the release on any mismatch.
