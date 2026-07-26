# Firmware release v0.9.0

Prebuilt, fully-validated PIC10F320 firmware images. Verify integrity with
`sha256sum -c SHA256SUMS`; reproduce from source per "Reproducing" below.

## Provenance

- **Version / tag:** v0.9.0
- **Source commit:** `cf892daf2baddef451751753547301ef13211075`
- **Built:** 2026-06-30T05:06:10Z by `matt` on `Linux 6.12.33-production+truenas x86_64`
- **Validation:** `make test-variants` + `make test-mutation` + 24.0-h parallel soak of every variant (see evidence/).

## Toolchain

| tool | version |
|---|---|
| XC8 | Microchip MPLAB XC8 C Compiler V3.10 |
| PIC DFP | /opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8 |
| gpsim | gpsim-0.32.1 # (Mar 31 2024) |
| host cc | cc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0 |
| host c++ | c++ (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0 |
| cppcheck | Cppcheck 2.13.0 |
| cbmc | 5.95.1 (cbmc-5.95.1) |
| python3 | Python 3.14.5 |

## Images

| image | MCU | clock | flash used | config | sha256 |
|---|---|---|---|---|---|
| `bypass_mcu_cd4053-simple_pic10f320.hex` | PIC10F320 | 16 MHz (INTOSC) | 208 words / 256 | CONFIG word embedded in HEX | `fd2b7c039d0ec7a6df15859c6e2da2064a47b62a5da8d3978a5e09f1eed991dc` |
| `bypass_mcu_tmux4053-simple_pic10f320.hex` | PIC10F320 | 16 MHz (INTOSC) | 208 words / 256 | CONFIG word embedded in HEX | `f003bfc366aa43388b68e1c97d82b98a36cd33dec893ebd3aa7a8c9304d772d0` |
| `bypass_mcu_cd4053-mute_pic10f320.hex` | PIC10F320 | 16 MHz (INTOSC) | 238 words / 256 | CONFIG word embedded in HEX | `d1abf0606629ee5a37ff96bcccabcd670720de0b14e679c0d181182036349aa7` |
| `bypass_mcu_tmux4053-mute_pic10f320.hex` | PIC10F320 | 16 MHz (INTOSC) | 238 words / 256 | CONFIG word embedded in HEX | `8124c76ed54936263fe36ca9bf2ea5cf8981e06f134968fbd2cb1026784a0546` |
| `bypass_mcu_tq2-relay_pic10f320.hex` | PIC10F320 | 16 MHz (INTOSC) | 233 words / 256 | CONFIG word embedded in HEX | `e8a67d49c3c37a30aeb9bf7d674ca1d368cc205d624dcf18a2cd22e644b32b0a` |

## Flashing

The PIC10F320 CONFIG word is embedded in the HEX, so writing the HEX
configures the device -- there is no separate fuse step.

```
# bypass_mcu_cd4053-mute_pic10f320.hex
pk2cmd -PPIC10F320 -Fbypass_mcu_cd4053-mute_pic10f320.hex -M -Y -R

# bypass_mcu_cd4053-simple_pic10f320.hex
pk2cmd -PPIC10F320 -Fbypass_mcu_cd4053-simple_pic10f320.hex -M -Y -R

# bypass_mcu_tmux4053-mute_pic10f320.hex
pk2cmd -PPIC10F320 -Fbypass_mcu_tmux4053-mute_pic10f320.hex -M -Y -R

# bypass_mcu_tmux4053-simple_pic10f320.hex
pk2cmd -PPIC10F320 -Fbypass_mcu_tmux4053-simple_pic10f320.hex -M -Y -R

# bypass_mcu_tq2-relay_pic10f320.hex
pk2cmd -PPIC10F320 -Fbypass_mcu_tq2-relay_pic10f320.hex -M -Y -R

```

## Soak evidence

| variant | result |
|---|---|
| cd4053-simple | SOAK PASS: 24.00 h simulated. wdt_resets=0 liveness_fails=0 checks=1440 |
| tmux4053-simple | SOAK PASS: 24.00 h simulated. wdt_resets=0 liveness_fails=0 checks=1440 |
| cd4053-mute | SOAK PASS: 24.00 h simulated. wdt_resets=0 liveness_fails=0 checks=1440 |
| tmux4053-mute | SOAK PASS: 24.00 h simulated. wdt_resets=0 liveness_fails=0 checks=1440 |
| tq2-relay | SOAK PASS: 24.00 h simulated. wdt_resets=0 liveness_fails=0 checks=1440 |

## Reproducing these images

```
git checkout v0.9.0
# install the pinned toolchain (see TOOLCHAIN.adoc), then build every variant:
make clean
make all PIC_VARIANT=cd4053-simple
make all PIC_VARIANT=tmux4053-simple
make all PIC_VARIANT=cd4053-mute
make all PIC_VARIANT=tmux4053-mute
make all PIC_VARIANT=tq2-relay
sha256sum -c release/v0.9.0/SHA256SUMS
```
The tag-triggered CI (.github/workflows/release.yml) performs exactly this
check on a clean runner and fails the release on any mismatch.
