# PIC10F320 Bypass Firmware

[![CI](https://github.com/matt-garman/pic10f320-bypass-firmware/actions/workflows/ci.yml/badge.svg)](https://github.com/matt-garman/pic10f320-bypass-firmware/actions/workflows/ci.yml)

Scaled-down, single-file bypass/debounce firmware for the
**PIC10F320**, supporting all three of the parent project's output
stages — **analog-switch simple**, **analog-switch with mute**, and
the **TQ2 latching relay** — in **three build variants**:
**cd4053-simple / cd4053-mute / tq2-relay**.  The two analog-switch
variants drive their control pins with a single, unified polarity that
is correct for both an inverting **CD4053** (driven through a MOSFET
inverter at 9–18 V) and the pin-compatible logic-level **TMUX4053**
(driven directly) — one image serves both boards.  The output scheme is
selected at compile time with one `OUTPUT_*` macro (see the Build
section). It responds to a footswitch, debounces it, toggles effect
bypass/engage, and drives a status LED.


## Design Documentation

Except for the necessary structural differences noted here, the overall design
and hardware implementation of the PIC10F320 is the same as it is for the
parent PIC10F322.  See the parent's
[DESIGN_DOCUMENTATION.adoc](https://github.com/matt-garman/mcu-bypass-firmware/blob/main/DESIGN_DOCUMENTATION.adoc) for details.


## Relationship to the parent project

This is intentionally a separate child project of
[mcu-bypass-firmware](https://github.com/matt-garman/mcu-bypass-firmware).

- The parent is the textbook-grade, fully-validated reference firmware (AVR
  Classic and PIC10F322). Its design is built around a *pure*,
  host- and formally-verified debounce core (`bypass_pure.c`): the algorithm
  is written as side-effect-free functions returning result structs, which is
  what makes it unit- and model-checkable on a host.
- The PIC10F320 is a smaller device with only **256 words of program flash** (half the
  PIC10F322's 512). The parent's pure/result-struct architecture does not fit that
  budget, so this project takes a different route: the debounce logic is **inlined
  into `main()`**, mutating a file-global context and driving the hardware directly.
  The assurance the parent gets *for free* by compiling its verified core straight
  into the firmware is instead **recovered here by proving the inlined firmware
  behaviourally identical to that same verified core** (see Validation).
- Current footprint, per output stage (all fit the 256-word budget):
  **cd4053-simple 219 (85.5%)**, **cd4053-mute 240 (93.8%)**,
  **tq2-relay 243 (94.9%)**; 10 / 64 bytes RAM. Each `cd4053-*` image
  drives both the CD4053 and the pin-compatible TMUX4053 board.

**Validation:** because the firmware inlines its logic, it is
validated in layers (see `test/README.md`): the parent's pure
debounce core is vendored as a **reference model** and run through
the full host + formal suite (unit/property/ fuzz, exhaustive
state-space, symbolic, and CBMC); the **real firmware** is then
proven behaviorally identical to that model: tick-for-tick over
exhaustive + random stimulus on the host (comparing the status-LED
bit RA0 — the one output that means the same thing for every variant —
*and* the firmware's internal debounce state, with a gate that the
stimulus visits *every* reachable model state).
The per-variant control pins (RA1/RA2) are pinned by a host
**actuation-sequence** test that asserts each variant's full *settled*
`LATA` at every tick; so even cd4053-simple's lone control pin, which
has no blocking pulse for a snapshot to catch, is verified on the host;
plus the mute/relay drivers' *mid-actuation* sequencing and pulse width
that neither the RA0 trace nor a settled snapshot can see. Both the host
actuation check and the gpsim test assert each variant's full BYPASS
*and* ENGAGED control-pin pattern, catching a wrong drive polarity. The real HEX is
independently re-checked on a simulated core in gpsim. A built-HEX target-I/O
test additionally requires exact `TRISA=0x08`, verifies physical `PORTA` follows
every `LATA` transition, checks each variant's complete startup/engage/bypass
transition sequence, and measures mute/relay pulses from simulator cycles; and
the real firmware's **defensive layer** (the SEU/EMI sanity gate and
watchdog-reset path, which valid stimulus never reaches) is
exercised by a host **fault-injection** harness — and re-verified on a
simulated core (`test-fault-gpsim`), where corrupting every guarded
SFR/`ctx_`-SRAM location and required `TRISA` output direction in the real HEX
forces exactly one real
watchdog reset. Static analysis
(cppcheck + MISRA-C:2012, zero deviations), CONFIG-word
verification, mutation testing, and model + firmware coverage gates
round it out. `make test` runs the per-variant development suite;
`make test-variants` sweeps all three. Regular CI also runs the fail-closed
`make test-target-variants` aggregate, requiring target fault recovery,
firmware/model lock-step, and target-I/O PASS evidence for every variant. A
long-run `make test-soak` (libgpsim) and an optional KLEE pass
(`make test-symbolic-klee`) remain standalone targets.

**The one structural difference:** the parent compiles its formally-verified pure
core *directly into* the shipping firmware: the tested code and the flashed code
are the same translation unit. The 10F320's flash can't fit that, so this project
vendors that exact core as a reference model, runs the full host and formal suite
against it, and proves the hand-inlined firmware behaviourally identical to it
(every output pin checked at every settled tick, the mute/relay mid-actuation
sequencing pinned separately, and the real HEX re-checked in gpsim). That
*bridges* the inlining seam rather than *eliminating* it: a single,
heavily-mitigated trust assumption the parent doesn't carry. On the remaining
axes the two are at parity, including the hardware-bench gaps, since WDT timing
and brown-out *behaviour* are equally unsimulable in gpsim for the parent's
PIC10F322 build (gpsim's WDT calibration differs from silicon and it has no analog
BOR model; the CONFIG check proves those features are *enabled*, not their
real-time timing; see *Known gaps* in `test/README.md`).

**When to use which:** the parent remains the authoritative,
preferred project: it is the canonical home of the verified core and
supports more parts (AVR Classic and PIC10F322), so prefer it
whenever you can choose the part. Use this firmware when the
PIC10F320 is a hard requirement (it targets the same robustness
level by a different (but not lesser) validation strategy).


## Provenance

The debounce algorithm here is a **manual instantiation** of the parent's
verified pure core — byte-for-byte identical arithmetic and state transitions,
merely re-packaged (inlined, global-mutating) to fit flash. The three output
drivers are likewise instantiations of the parent's per-variant output stages
(`bypass_output_*.c`), inlined into the firmware's `#if defined(OUTPUT_*)` blocks.
The two analog-switch stages drive their control pins with a single unified
polarity — BYPASS = MCU pin low (the pulled-down, MCU-absent fail-safe state),
ENGAGE = high — that is correct for both the CD4053 (MOSFET-inverter drive) and
the pin-compatible logic-level TMUX4053, because the CD4053's inversion and the
TMUX4053 board's swapped analog throws cancel; one image serves both boards.

- **Derived from:** `mcu-bypass-firmware` @ commit
  `bf6a6c1` (`bf6a6c15071bdc56bc96de740eec83e8a87cd78b`) — the commit the
  vendored reference model is pinned to (see `test/model/README.md`). The
  analog-switch control-pin polarity now follows the parent's later correction,
  which unified the drive for both boards and removed the earlier
  `BYPASS_X4053_DIRECT_DRIVE` split (`bypass_output_x4053_polarity.h`) as a latent
  polarity bug; the vendored debounce model is unaffected and stays pinned to
  `bf6a6c1`.
- **Correctness is inherited by derivation** from that core's host + formal
  verification; it is *not* independently re-proven in this repository.
- This is a **frozen one-off**. It is *not* automatically kept in sync with
  the parent; the parent may advance without this project following.


## Manual-sync contract

If the parent's debounce behavior ever changes, it must be mirrored here **by
hand**. The shared surface is small, finite, and auditable — nothing else is
shared at the source level:

| Item                      | Parent source                              | Here                              |
| ------------------------- | ------------------------------------------ | -------------------------------- |
| Press threshold           | `PRESSED_THRESH` (8) in `bypass_config.h`  | `PRESSED_THRESH`                 |
| Release/lockout threshold | `RELEASE_THRESH` (25) in `bypass_config.h` | `RELEASE_THRESH`                 |
| Saturating integrator     | `debounce_integrate()` in `bypass_pure.c`  | inlined in the `main()` loop     |
| State machine             | `debounce_step()` in `bypass_pure.c`       | inlined `switch` in `main()`     |
| Power-on init             | `debounce_init_context()` in `bypass_pure.c` | inlined in `init()`            |
| Output stages             | `bypass_output_{cd4053_simple,cd4053_with_mute,tq2_l2_5v_relay}.c` | inlined `#if defined(OUTPUT_*)` blocks |
| Analog-switch polarity    | unified drive in `bypass_output_{cd4053_simple,cd4053_with_mute}.c` (BYPASS = pin low, ENGAGE = high) | inlined `hw_x4053_ctl_high/low` functions |

The pin map (RA3 footswitch, RA0 LED, RA1/RA2 control) and the CONFIG word are
PIC-local and are *not* shared with the parent.


## Build

Requires Microchip XC8 v3.10 and the PIC10-12Fxxx DFP (see
[TOOLCHAIN.adoc](TOOLCHAIN.adoc) for the full pinned toolchain).

```sh
make          # build the .hex (default variant) and check the 256-word budget
make size     # print XC8's full program/data memory summary
make help     # the full annotated target list (build / test / release / clean)
make clean    # remove the build directory
```

Select the output variant with `PIC_VARIANT` (default `cd4053-simple`):

```sh
make PIC_VARIANT=cd4053-simple    # LED(RA0) + analog-switch control(RA1)
make PIC_VARIANT=cd4053-mute      # LED(RA0) + CTL1(RA1) + CTL2(RA2), pre-switch mute
make PIC_VARIANT=tq2-relay        # LED(RA0) + RESET(RA1) + SET(RA2), latching relay
```

The two `cd4053-*` images drive their analog-switch control pins with a single
unified polarity (BYPASS = pin low, ENGAGE = high) that is correct for both a
CD4053 (driven through a MOSFET inverter at 9–18 V) and the pin-compatible
logic-level TMUX4053 — one image serves both boards.

Override the toolchain paths on the command line if your install differs:

```sh
make PIC_CC=/path/to/xc8-cc PIC_DFP=/path/to/DFP/x.y.z/xc8
```

The build lands in `build_pic/bypass_mcu_<variant>_pic10f320.hex` (e.g.
`build_pic/bypass_mcu_cd4053-simple_pic10f320.hex`).


## Power / current draw

The core runs at **2 MHz** (HFINTOSC) on a **polled 1 ms tick** — a busy-wait on
`TMR2IF`, never asleep. The PIC10F320 has no idle mode, and its only Sleep-capable
periodic wake is the coarse WDT (TMR0/TMR2 are FOSC/4-clocked and stop in Sleep),
so a *precise* 1 ms tick necessarily means staying awake. The design spends that
power deliberately, to buy a precise tick and a high-margin, independent watchdog;
a deep-sleep scheme would have to give up one or both (see *Known gaps* in
`test/README.md`).

Given that the loop is always awake, the clock frequency sets the current draw. The
core is clocked at 2 MHz rather than the part's 16 MHz maximum: the debounce +
per-tick sanity work is only ~210 instruction-cycles, so 2 MHz (500 cycles/ms)
runs it at ~42 % utilisation — comfortable headroom — while roughly **halving**
the supply current:

| FOSC | active IDD @ 5 V (typ) | ≈ power | per-tick headroom |
| ---- | --------------------- | ------- | ----------------- |
| 16 MHz | ~0.85 mA | ~4.25 mW | 19× |
| **2 MHz** | **~0.43 mA** | **~2.1 mW** | **2.4×** |

(IDD interpolated from DS40001585 D017–D019; 16 MHz is the tabulated figure.) A
lower clock also emits less high-frequency switching noise into the analog audio
path. Note this firmware is **not** battery-optimised — in a typical pedal the
always-on status LED and the analog signal path dominate the supply, so the MCU's
sub-milliamp draw is usually negligible; the 2 MHz choice is simply "no reason to
burn 4 mW when 2 does the same job."


## Prebuilt releases

If you just want to flash a chip without installing XC8, prebuilt, fully
validated images are published under [`release/`](release/) and as
[GitHub Releases](https://github.com/matt-garman/pic10f320-bypass-firmware/releases).
Each release pins the image bytes with a `SHA256SUMS` manifest, and the
tag-triggered CI rebuilds from source on a clean runner and **fails the release
unless the expected, committed, checksummed, and freshly-built image sets match
exactly and reproduce those hashes bit-for-bit** — so no extra or omitted binary
can bypass the reproduction gate. See
[`release/README.md`](release/README.md) for the trust model and verification
steps. Maintainers stage a release with `make release VERSION=vX.Y.Z` (see
`scripts/make-release.sh`).
