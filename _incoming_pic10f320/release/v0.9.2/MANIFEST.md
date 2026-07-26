# Firmware release v0.9.2

Prebuilt, fully-validated PIC10F320 firmware images. Verify integrity with
`sha256sum -c SHA256SUMS`; reproduce from source per "Reproducing" below.

## Provenance

- **Version / tag:** v0.9.2
- **Source commit:** `3d4a104d1d9f123bfad7747f995a3552aa9f4b6f`
- **Built:** 2026-07-01T03:48:28Z by `matt` on `Linux 6.12.33-production+truenas x86_64`
- **Validation:** `make test-variants` + `make test-mutation` + a 24.0-h *simulated-time* parallel libgpsim soak of every variant (see evidence/).

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
| `bypass_mcu_cd4053-simple_pic10f320.hex` | PIC10F320 | 16 MHz (INTOSC) | 202 words / 256 | CONFIG word embedded in HEX | `663478b3d5cb99de62135729df42db18a58c9b2b57bd871385f72d8d13d51ea9` |
| `bypass_mcu_tmux4053-simple_pic10f320.hex` | PIC10F320 | 16 MHz (INTOSC) | 202 words / 256 | CONFIG word embedded in HEX | `2f1166eb1ab154990e7fa92fd04cd03ecb26e3a6ac619a54daa5ce22cc9b430d` |
| `bypass_mcu_cd4053-mute_pic10f320.hex` | PIC10F320 | 16 MHz (INTOSC) | 225 words / 256 | CONFIG word embedded in HEX | `070c56eee4cacf512a74e93376aaea0e843b851970d80973f9b96e8dfbec2005` |
| `bypass_mcu_tmux4053-mute_pic10f320.hex` | PIC10F320 | 16 MHz (INTOSC) | 225 words / 256 | CONFIG word embedded in HEX | `ce72144b01fe7db9c1b463353d7c9c354d7de0477dc83ad0bd7b4a0897b0e952` |
| `bypass_mcu_tq2-relay_pic10f320.hex` | PIC10F320 | 16 MHz (INTOSC) | 225 words / 256 | CONFIG word embedded in HEX | `ccdc8c291bca3364cad66d9af2c3c3f5badcd98952fdb1b9d62988e9870f63f0` |

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
git checkout v0.9.2
# install the pinned toolchain (see TOOLCHAIN.adoc), then build every variant:
make clean
make all PIC_VARIANT=cd4053-simple
make all PIC_VARIANT=tmux4053-simple
make all PIC_VARIANT=cd4053-mute
make all PIC_VARIANT=tmux4053-mute
make all PIC_VARIANT=tq2-relay
sha256sum -c release/v0.9.2/SHA256SUMS
```
The tag-triggered CI (.github/workflows/release.yml) performs exactly this
check on a clean runner and fails the release on any mismatch.
