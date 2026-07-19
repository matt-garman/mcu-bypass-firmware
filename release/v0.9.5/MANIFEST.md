# Firmware release v0.9.5

Prebuilt, fully-validated firmware images. Verify integrity with
`sha256sum -c SHA256SUMS`; reproduce from source per "Reproducing" below.

Release scope: AVR Classic (ATtiny13a/45/85) and PIC10F322. ATtiny202
is development-only and is intentionally excluded from this release.

## Provenance

- **Version / tag:** v0.9.5
- **Source commit:** `2214a78c526819df3380bb0617b7b7bba2ef38ba`
- **Built:** 2026-07-18T01:32:49Z by `matt` on `Linux 6.12.33-production+truenas x86_64`
- **Validation:** `make test-long` + `make pic-test` + `make pic-test-target-variants` (real-HEX SFR/SRAM fault recovery, firmware/model ctx_ lock-step, and GPIO transition/pulse timing) + 24.0-h parallel soak of every release soak combination (see evidence/).

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
| `bypass_cd4053.hex` | ATtiny13a | 1.2 MHz | 716 B | lfuse=0x4a hfuse=0xf9 | `ba85f52857e114c443022ebf446a887b290be4a6a8d325a08e388a67a51797e8` |
| `bypass_mute.hex` | ATtiny13a | 1.2 MHz | 756 B | lfuse=0x4a hfuse=0xf9 | `298bc5f19e1202cf955d015249f55350990332d82ee0382458d5881eac8e2c8b` |
| `bypass_relay.hex` | ATtiny13a | 1.2 MHz | 756 B | lfuse=0x4a hfuse=0xf9 | `a2eedf49a0f62073cfa62e3bc11619294cfbb4f630799bc20b54bbbe14ff943c` |
| `bypass_cd4053_t85.hex` | ATtiny85 | 1.0 MHz | 742 B | lfuse=0x62 hfuse=0xcc | `5ceda46ba94566ef13cf086f1cafd36151e9e9c725ee59fb819e3cb5dfae67e2` |
| `bypass_cd4053_t45.hex` | ATtiny45 | 1.0 MHz | 742 B | lfuse=0x62 hfuse=0xcc | `2fb5437e6c0561e41ceb6a5c6069185545dd03992639756f8b5ae4e61ca5f675` |
| `bypass_mute_t85.hex` | ATtiny85 | 1.0 MHz | 782 B | lfuse=0x62 hfuse=0xcc | `28cdf3b574f0d9f7498bea3c3d9415bd43152a540594c46c38063de20911fead` |
| `bypass_mute_t45.hex` | ATtiny45 | 1.0 MHz | 782 B | lfuse=0x62 hfuse=0xcc | `2d0aa3cdc8e03e30eadf04ba3bbcbdff5e8f048e557c9ead5158d6a30189de88` |
| `bypass_relay_t85.hex` | ATtiny85 | 1.0 MHz | 782 B | lfuse=0x62 hfuse=0xcc | `26bfff00d759ff1d796b5dac9928dac217901164c85481507d4b0ce60e1f0503` |
| `bypass_relay_t45.hex` | ATtiny45 | 1.0 MHz | 782 B | lfuse=0x62 hfuse=0xcc | `abc340ce2ae16c9a116861c4eff823f60ea822dcb8fc9e361836abb345564c25` |
| `bypass_cd4053_pic10f322.hex` | PIC10F322 | 2 MHz (HFINTOSC) | n/a | CONFIG word embedded in HEX | `c0a16d96d89d2f44352aa6bb831f5db85c17858aede1f639cf3079f70f8f70ae` |
| `bypass_mute_pic10f322.hex` | PIC10F322 | 2 MHz (HFINTOSC) | n/a | CONFIG word embedded in HEX | `01d7b27bfe04a99dbbfc91ca64fab048a017e24b4a3c7185e32623d11c95940c` |
| `bypass_relay_pic10f322.hex` | PIC10F322 | 2 MHz (HFINTOSC) | n/a | CONFIG word embedded in HEX | `2a0a0ccd0b159797b2a090a2e7f5b6d48bd827eef5408772df95d1a604f4215b` |

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
committed copies against themselves). `build_avr_xt/` is intentionally
absent because ATtiny202 is not release-supported.

```
git checkout v0.9.5
# install the pinned toolchain (see TOOLCHAIN.adoc), then:
make clean && make all13 all85 all45 && make pic
scripts/verify-release-images.sh release/v0.9.5 build_avr_classic build_pic
```
A passing verifier proves the committed files, checksum entries, and freshly
built files are the same complete release set with byte-identical contents.
The tag-triggered CI (.github/workflows/release.yml) runs this exact check on a
clean runner and fails the release on any mismatch.
